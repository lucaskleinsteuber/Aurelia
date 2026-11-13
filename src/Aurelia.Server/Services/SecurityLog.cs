using System.Security.Claims;
using System.Threading.Channels;
using Aurelia.Server.Authentication;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// The security log: sign-ins, failed attempts and administrators' changes, kept as many days as
/// the owner set (30 to 365, 90 by default). Entries are written in the background with their own
/// database context, so a failed request still leaves its record. Kinds are fixed codes; details
/// are short names, never passwords, PINs, tokens or full paths.
/// </summary>
public sealed class SecurityLog(
    IServiceScopeFactory scopes,
    SecuritySettingsStore settings,
    TimeProvider? timeProvider = null) : BackgroundService
{
    public const string Succeeded = "succeeded";
    public const string Failed = "failed";
    public const string Changed = "changed";
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly Channel<SecurityEvent> pending = Channel.CreateBounded<SecurityEvent>(new BoundedChannelOptions(2048)
    { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true });
    private readonly SemaphoreSlim flushGate = new(1, 1);
    private DateTimeOffset nextPrune = DateTimeOffset.MinValue;

    public void Record(string kind, string outcome, Guid? userId = null, Guid? deviceSessionId = null,
        string? detail = null, ClientIdentity? identity = null, string? deviceName = null)
    {
        if (kind.Length is < 1 or > 48 || kind.Any(character => !char.IsAsciiLetterLower(character) && character != '_'))
            throw new ArgumentException("Use a fixed security event code.", nameof(kind));
        pending.Writer.TryWrite(new SecurityEvent
        {
            Id = Guid.NewGuid(),
            At = clock.GetUtcNow(),
            Kind = kind,
            Outcome = outcome,
            UserId = userId,
            DeviceSessionId = deviceSessionId,
            DeviceName = Short(deviceName, 128),
            Platform = Short(identity?.Platform, 64),
            IpAddress = Short(identity?.IpAddress, 64),
            Detail = Short(detail, 256),
        });
    }

    /// <summary>Records for the signed-in profile and device of this request.</summary>
    public void Record(HttpContext context, string kind, string outcome, string? detail = null, Guid? userId = null)
    {
        var user = context.User;
        Guid? device = user.FindFirstValue(DeviceTokenAuthenticationHandler.SessionIdClaim) is { } text && Guid.TryParse(text, out var id) ? id : null;
        Guid? actor = userId ?? (user.FindFirstValue(ClaimTypes.NameIdentifier) is { } value && Guid.TryParse(value, out var parsed) ? parsed : null);
        Record(kind, outcome, actor, device, detail, ClientIdentity.From(context));
    }

    private static string? Short(string? value, int length)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var text = new string(value.Where(character => !char.IsControl(character)).ToArray()).Trim();
        return text.Length <= length ? text : text[..length];
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                using var idle = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
                idle.CancelAfter(TimeSpan.FromHours(1));
                try { await pending.Reader.WaitToReadAsync(idle.Token); }
                catch (OperationCanceledException) when (!stoppingToken.IsCancellationRequested) { }
                await FlushAsync(stoppingToken);
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
        finally { await FlushAsync(CancellationToken.None); }
    }

    /// <summary>Writes what is waiting and removes entries older than the owner's setting.</summary>
    public async Task FlushAsync(CancellationToken token)
    {
        await flushGate.WaitAsync(token);
        try
        {
            var batch = new List<SecurityEvent>();
            while (batch.Count < 1000 && pending.Reader.TryRead(out var entry)) batch.Add(entry);
            var now = clock.GetUtcNow();
            if (batch.Count == 0 && now < nextPrune) return;
            using var scope = scopes.CreateScope();
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            if (batch.Count > 0)
            {
                var users = batch.Where(entry => entry.UserId is not null).Select(entry => entry.UserId!.Value).Distinct().ToArray();
                var names = await database.Users.AsNoTracking().Where(user => users.Contains(user.Id))
                    .Select(user => new { user.Id, Name = user.DisplayName ?? user.Username }).ToDictionaryAsync(user => user.Id, user => user.Name, token);
                var devices = batch.Where(entry => entry.DeviceSessionId is not null).Select(entry => entry.DeviceSessionId!.Value).Distinct().ToArray();
                var sessions = await database.DeviceSessions.AsNoTracking().Where(session => devices.Contains(session.Id))
                    .Select(session => new { session.Id, session.DeviceName, session.Platform }).ToDictionaryAsync(session => session.Id, token);
                foreach (var entry in batch)
                {
                    if (entry.UserId is { } user && names.TryGetValue(user, out var name)) entry.UserName = Short(name, 128);
                    if (entry.DeviceSessionId is { } device && sessions.TryGetValue(device, out var session))
                    {
                        entry.DeviceName ??= session.DeviceName;
                        entry.Platform ??= session.Platform;
                    }
                }
                database.SecurityEvents.AddRange(batch);
                try { await database.SaveChangesAsync(token); }
                catch (Exception error) when (StorageRecovery.IsRecoverableDatabase(error)) { return; }
            }
            if (now >= nextPrune)
            {
                nextPrune = now.AddHours(6);
                var oldest = now.AddDays(-settings.Current.SecurityLogDays);
                try { await database.SecurityEvents.Where(entry => entry.At < oldest).ExecuteDeleteAsync(token); }
                catch (Exception error) when (StorageRecovery.IsRecoverableDatabase(error)) { }
            }
        }
        finally { flushGate.Release(); }
    }
}

/// <summary>Wakes the owner's waiting alert requests when a device or an unlock request appears.</summary>
public sealed class SecurityAlertSignal
{
    private readonly object gate = new();
    private long version = 1;
    private TaskCompletionSource changed = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public long Version { get { lock (gate) return version; } }

    public void Bump()
    {
        TaskCompletionSource previous;
        lock (gate)
        {
            version++;
            previous = changed;
            changed = new(TaskCreationOptions.RunContinuationsAsynchronously);
        }
        previous.TrySetResult();
    }

    /// <summary>Returns at once when the version moved past <paramref name="seen"/>, else on the next change or the timeout.</summary>
    public async Task WaitAsync(long seen, TimeSpan timeout, CancellationToken token)
    {
        Task next;
        lock (gate)
        {
            if (version != seen || timeout <= TimeSpan.Zero) return;
            next = changed.Task;
        }
        try { await next.WaitAsync(timeout, token); }
        catch (TimeoutException) { }
    }
}
