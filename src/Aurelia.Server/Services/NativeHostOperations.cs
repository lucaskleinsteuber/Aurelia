using System.Net;
using System.Net.Http.Json;
using System.Text.Json;

namespace Aurelia.Server.Services;

public sealed record NetworkTrialRequest(ServerHostSettings Settings, bool ConfirmRemoteAccessDisabled);
public sealed record HostingChangeRequest(bool BackgroundEnabled, bool StartAtLogin, bool PreventIdleSleep);
public sealed record HostingStatus(bool BackgroundEnabled, bool BackgroundRequested, bool StartAtLogin, bool PreventIdleSleep, string State);
public sealed record HostOperationStatus(Guid Id, string Kind, string State, DateTimeOffset? ConfirmBefore, int? HttpsPort);
public sealed record HostOperationJournal(int Version, Guid Id, string Kind, string State, Guid SessionId,
    DateTimeOffset? ConfirmBefore, ServerHostSettings? PreviousSettings);

public sealed class NativeHostOperations(ServerRuntimeOptions runtime, ServerConfigurationStore configuration) : IDisposable
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    public const string JournalFileName = "host-operation.json";
    private string JournalPath => Path.Combine(runtime.DataDirectory, JournalFileName);
    private static Uri? ControlUrl
    {
        get
        {
            var value = Environment.GetEnvironmentVariable("AURELIA_HOST_CONTROL_URL");
            return Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Scheme == "http"
                && uri.Host == "127.0.0.1" && uri.AbsolutePath.Trim('/').Length >= 32
                && string.IsNullOrEmpty(uri.Query) && string.IsNullOrEmpty(uri.UserInfo) ? uri : null;
        }
    }
    public bool Available => ControlUrl is not null;
    public async Task<HostingStatus> HostingStatusAsync(CancellationToken token)
    {
        var address = ControlUrl ?? throw new AccountException("native_host_required", "The native host control channel is unavailable.", 409);
        using var client = new HttpClient(new SocketsHttpHandler { UseProxy = false, AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(3) };
        try
        {
            return await client.GetFromJsonAsync<HostingStatus>(new Uri(address.AbsoluteUri.TrimEnd('/') + "/hosting-status"), token)
                ?? throw new AccountException("host_unavailable", "Hosting status is unavailable.", 503);
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException && !token.IsCancellationRequested)
        { throw new AccountException("host_unavailable", "The native host did not respond.", 503); }
    }
    public void Dispose() => gate.Dispose();
    public async Task<HostOperationStatus?> StatusAsync(CancellationToken token)
    {
        if (!File.Exists(JournalPath)) return null;
        var value = JsonSerializer.Deserialize<HostOperationJournal>(await File.ReadAllTextAsync(JournalPath, token), Json);
        return value is null ? null : new(value.Id, value.Kind, value.State, value.ConfirmBefore, configuration.Current.LanHttpsPort);
    }
    public async Task<HostOperationStatus> RestartAsync(Guid sessionId, CancellationToken token)
    {
        await gate.WaitAsync(token);
        try
        {
            await RequireNoTrialAsync(token);
            var journal = new HostOperationJournal(1, Guid.NewGuid(), "restart", "restarting", sessionId, null, null);
            await WriteAsync(journal, token);
            try { await SendAsync("restart", null, token); }
            catch { await WriteAsync(journal with { State = "failed" }, CancellationToken.None); throw; }
            return new(journal.Id, journal.Kind, journal.State, null, configuration.Current.LanHttpsPort);
        }
        finally { gate.Release(); }
    }
    public async Task<HostOperationStatus> AuthorizeHostingAsync(Guid sessionId, HostingChangeRequest request, CancellationToken token)
    {
        await gate.WaitAsync(token);
        try
        {
            await RequireNoTrialAsync(token);
            if (!request.BackgroundEnabled && request.StartAtLogin)
                throw new AccountException("invalid_hosting_mode", "Start at login requires background hosting.", 400);
            var journal = new HostOperationJournal(1, Guid.NewGuid(), "hosting", "awaitingMacApproval", sessionId, null, null);
            await WriteAsync(journal, token);
            try { await SendAsync("hosting-authorized", new { id = journal.Id, request.BackgroundEnabled, request.StartAtLogin, request.PreventIdleSleep }, token); }
            catch { await WriteAsync(journal with { State = "failed" }, CancellationToken.None); throw; }
            return new(journal.Id, journal.Kind, journal.State, null, configuration.Current.LanHttpsPort);
        }
        finally { gate.Release(); }
    }
    public async Task<HostOperationStatus> TrialAsync(Guid sessionId, NetworkTrialRequest request, CancellationToken token)
    {
        await gate.WaitAsync(token);
        try
        {
            if (!Available) throw new AccountException("native_host_required", "Network changes require the native Mac host.", 409);
            await RequireNoTrialAsync(token);
            var previous = configuration.Current;
            if (previous.LanAccessEnabled && !request.Settings.LanAccessEnabled && !request.ConfirmRemoteAccessDisabled)
                throw new AccountException("disconnect_confirmation_required", "Explicitly confirm that remote devices will lose access.", 400);
            var journal = new HostOperationJournal(1, Guid.NewGuid(), "network", "awaitingConfirmation", sessionId,
                DateTimeOffset.UtcNow.AddSeconds(60), previous with { Version = 2, Revision = checked(previous.Revision + 2) });
            await WriteAsync(journal, token);
            try
            {
                configuration.Update(request.Settings, allowNetworkChange: true);
                await SendAsync("network-trial", new { id = journal.Id }, token);
            }
            catch
            {
                if (configuration.Current.Revision != previous.Revision)
                    configuration.Update(previous with { Revision = configuration.Current.Revision }, allowNetworkChange: true);
                await WriteAsync(journal with { State = "failed", ConfirmBefore = null }, CancellationToken.None);
                throw;
            }
            return new(journal.Id, journal.Kind, journal.State, journal.ConfirmBefore, request.Settings.LanHttpsPort);
        }
        finally { gate.Release(); }
    }
    public async Task ConfirmAsync(Guid id, Guid sessionId, CancellationToken token)
    {
        await gate.WaitAsync(token);
        try
        {
            var journal = JsonSerializer.Deserialize<HostOperationJournal>(await File.ReadAllTextAsync(JournalPath, token), Json);
            if (journal is null || journal.Id != id || journal.SessionId != sessionId || journal.State != "awaitingConfirmation" || journal.ConfirmBefore <= DateTimeOffset.UtcNow)
                throw new AccountException("network_confirmation_expired", "The network change has expired or belongs to another device.", 409);
            await SendAsync("network-confirm", new { id }, token);
        }
        finally { gate.Release(); }
    }
    /// <param name="linux">A Linux package server restores at its next start, which it asks systemd for.</param>
    public async Task<HostOperationStatus> ApplyRestoreAsync(Guid sessionId, Guid restoreId, CancellationToken token, LinuxServiceRestart? linux = null)
    {
        await gate.WaitAsync(token);
        try
        {
            await RequireNoTrialAsync(token);
            var receipt = Path.Combine(runtime.DataDirectory, "Backups", ".restore-" + restoreId.ToString("N"), "restore-receipt.json");
            if (!File.Exists(receipt) || new FileInfo(receipt).LinkTarget is not null)
                throw new AccountException("restore_not_prepared", "Validate the encrypted backup before applying it.", 409);
            var journal = new HostOperationJournal(1, restoreId, "restore", "restarting", sessionId, null, null);
            if (!Available && linux is not null && LinuxPackage.IsInstalled)
            {
                await FullServerBackupService.RequestOnStartAsync(runtime, restoreId, token);
                await WriteAsync(journal, token);
                return linux.Request() with { Id = restoreId, Kind = "restore" };
            }
            await WriteAsync(journal, token);
            try { await SendAsync("restore-prepared", new { id = restoreId }, token); }
            catch { await WriteAsync(journal with { State = "failed" }, CancellationToken.None); throw; }
            return new(restoreId, "restore", "restarting", null, configuration.Current.LanHttpsPort);
        }
        finally { gate.Release(); }
    }
    private async Task RequireNoTrialAsync(CancellationToken token)
    {
        if ((await StatusAsync(token))?.State is "awaitingConfirmation" or "restarting")
            throw new AccountException("host_operation_active", "Wait for the active host operation to finish or the network trial to roll back first.", 409);
    }
    private async Task WriteAsync(HostOperationJournal journal, CancellationToken token)
    {
        var temporary = JournalPath + "." + Guid.NewGuid().ToString("N");
        try
        {
            await using (var file = PrivateFilePermissions.OpenNewPrivateFile(temporary)) await JsonSerializer.SerializeAsync(file, journal, Json, token);
            File.Move(temporary, JournalPath, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private static async Task SendAsync(string action, object? body, CancellationToken token)
    {
        var address = ControlUrl ?? throw new AccountException("native_host_required", "The native host control channel is unavailable.", 409);
        using var client = new HttpClient(new SocketsHttpHandler { UseProxy = false, AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(3) };
        try
        {
            // The private native HTTP parser accepts bounded Content-Length
            // requests, not chunked encoding used by streaming JsonContent.
            using var content = new ByteArrayContent(JsonSerializer.SerializeToUtf8Bytes(body, Json));
            content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json");
            using var response = await client.PostAsync(new Uri(address.AbsoluteUri.TrimEnd('/') + "/" + action), content, token);
            if (!response.IsSuccessStatusCode) throw new AccountException("host_operation_rejected", "The native host rejected this operation.", 409);
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException && !token.IsCancellationRequested)
        { throw new AccountException("host_unavailable", "The native host did not respond. No host operation was confirmed.", 503); }
    }
}
