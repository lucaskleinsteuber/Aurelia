using System.Text.Json;
using System.Threading.Channels;

namespace Aurelia.Server.Services;

public sealed record ServerEvent(DateTimeOffset At, string Code, string Severity, Guid? UserId = null, int? Status = null);

// Deliberately accepts codes, not arbitrary log messages, URLs, headers, or request bodies.
public sealed class ServerDiagnosticsStore(
    ServerRuntimeOptions runtime,
    ServerConfigurationStore configuration,
    TimeProvider? timeProvider = null) : BackgroundService
{
    private readonly Channel<ServerEvent> pending = Channel.CreateBounded<ServerEvent>(new BoundedChannelOptions(256)
    { FullMode = BoundedChannelFullMode.DropWrite, SingleReader = true });
    private readonly object gate = new();
    private readonly List<ServerEvent> events = [];
    private readonly SemaphoreSlim flushGate = new(1, 1);
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private bool needsPersistence;
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private string PathName => Path.Combine(runtime.DataDirectory, "server-events.json");

    public void Record(string code, string severity, Guid? userId = null, int? status = null)
    {
        if (code.Length > 80 || code.Any(character => !char.IsAsciiLetterOrDigit(character) && character != '_'))
            throw new ArgumentException("Use a fixed diagnostic event code.", nameof(code));
        pending.Writer.TryWrite(new(clock.GetUtcNow(), code, severity, userId, status));
    }
    public IReadOnlyList<ServerEvent> Read()
    { lock (gate) return events.OrderByDescending(value => value.At).Take(500).ToArray(); }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            if (File.Exists(PathName) && new FileInfo(PathName).Length <= 4 * 1024 * 1024 && new FileInfo(PathName).LinkTarget is null)
            {
                var previous = JsonSerializer.Deserialize<ServerEvent[]>(await File.ReadAllTextAsync(PathName, stoppingToken), Json) ?? [];
                lock (gate) events.AddRange(previous.TakeLast(10000));
            }
        }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException) { Record("diagnostics_history_unavailable", "warning"); }
        Record("server_started", "information");
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                // Sleep until an event arrives (or hourly for retention); a failed write retries soon.
                if (!needsPersistence)
                {
                    using var idle = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
                    idle.CancelAfter(TimeSpan.FromHours(1));
                    try { await pending.Reader.WaitToReadAsync(idle.Token); }
                    catch (OperationCanceledException) when (!stoppingToken.IsCancellationRequested) { }
                }
                await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken);
                await FlushAsync(stoppingToken);
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
        finally { await FlushAsync(CancellationToken.None); }
    }
    internal async Task FlushAsync(CancellationToken token)
    {
        await flushGate.WaitAsync(token);
        try { await FlushCoreAsync(token); }
        finally { flushGate.Release(); }
    }

    private async Task FlushCoreAsync(CancellationToken token)
    {
        var settings = configuration.Current;
        var oldestAllowed = clock.GetUtcNow().AddDays(-settings.EventRetentionDays);
        ServerEvent[] snapshot;
        lock (gate)
        {
            while (pending.Reader.TryRead(out var entry))
            {
                events.Add(entry);
                needsPersistence = true;
            }
            needsPersistence |= events.RemoveAll(value => value.At < oldestAllowed) > 0;
            if (events.Count > settings.MaximumEvents)
            {
                events.RemoveRange(0, events.Count - settings.MaximumEvents);
                needsPersistence = true;
            }
            if (!needsPersistence) return;
            snapshot = events.ToArray();
        }
        var temporary = PathName + "." + Guid.NewGuid().ToString("N") + ".pending";
        try
        {
            await using (var file = PrivateFilePermissions.OpenNewPrivateFile(temporary))
                await JsonSerializer.SerializeAsync(file, snapshot, Json, token);
            File.Move(temporary, PathName, true);
            // A failed write remains dirty and is retried even if no new event arrives.
            needsPersistence = false;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { /* Diagnostics must not stop playback on a full disk. */ }
        finally { try { if (File.Exists(temporary)) File.Delete(temporary); } catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { } }
    }
}
