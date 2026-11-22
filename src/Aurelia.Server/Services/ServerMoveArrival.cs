using System.Net.Http.Json;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <param name="CertificateRenewed">Whether this computer already has a certificate for the moved key.</param>
public sealed record MoveArrivalRecord(int Version, Guid ServerId, string MoveToken, IReadOnlyList<string> Addresses, bool CertificateRenewed);

/// <summary>
/// What a new server that finished a move must still do once it runs with the moved data
/// (docs/SERVER_MOVE.md): make a certificate for this computer with the moved key, and tell the old
/// server where it went. The record lives in the data folder, outside the restored state files, so
/// it survives the restart that applies the move.
/// </summary>
public static class ServerMoveArrival
{
    public const string FileName = "move-arrival.json";
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public static void Write(string dataDirectory, MoveArrivalRecord record) =>
        ServerMoveService.WritePrivate(Path.Combine(dataDirectory, FileName), record);

    public static MoveArrivalRecord? Read(string dataDirectory)
    {
        try
        {
            var info = new FileInfo(Path.Combine(dataDirectory, FileName));
            if (!info.Exists || info.LinkTarget is not null || info.Length > 64 * 1024) return null;
            var record = JsonSerializer.Deserialize<MoveArrivalRecord>(File.ReadAllBytes(info.FullName), Json);
            return record is { Version: 1, MoveToken.Length: > 0 and <= 256, Addresses: not null } && record.ServerId != Guid.Empty ? record : null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }

    public static void Delete(string dataDirectory) => ServerMoveService.TryDelete(Path.Combine(dataDirectory, FileName));

    /// <summary>
    /// Run at start before the TLS identity loads: the moved certificate names the old computer, so
    /// a new one is made for this computer with the same key, which every paired device pins.
    /// </summary>
    public static void PrepareStart(ServerRuntimeOptions runtime)
    {
        var record = Read(runtime.DataDirectory);
        if (record is null || record.CertificateRenewed) return;
        try { ServerTlsIdentity.ReissueForThisComputer(runtime); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or System.Security.Cryptography.CryptographicException or InvalidOperationException)
        { }
        Write(runtime.DataDirectory, record with { CertificateRenewed = true });
    }
}

/// <summary>
/// Tells the old server that the move arrived, a few times in the background: it then stops
/// answering and points devices here. Only the old server's own key (now this server's) is
/// accepted, and only when this server really runs with the moved identity.
/// </summary>
public sealed partial class ServerMoveArrivalReporter(ServerRuntimeOptions runtime, ServerTlsIdentity tls, ServerMoveTransport transport,
    IServiceScopeFactory scopes, ServerConfigurationStore configuration, TimeProvider clock, ILogger<ServerMoveArrivalReporter> logger) : BackgroundService
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    internal static readonly TimeSpan[] Delays =
        [TimeSpan.Zero, TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(20), TimeSpan.FromMinutes(1), TimeSpan.FromMinutes(3)];

    private static readonly Action<ILogger, Exception?> ArrivalReportFailed = LoggerMessage.Define(
        LogLevel.Warning, new EventId(4420, nameof(ArrivalReportFailed)), "Reporting server move arrival stopped after an unexpected failure.");

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var record = ServerMoveArrival.Read(runtime.DataDirectory);
        if (record is null) return;
        try
        {
            await using (var scope = scopes.CreateAsyncScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var identity = await database.ServerIdentities.AsNoTracking().SingleAsync(candidate => candidate.Id == 1, stoppingToken);
                // A move whose data could not be applied left this server as it was: nothing to report.
                if (identity.ServerId != record.ServerId)
                {
                    ServerMoveArrival.Delete(runtime.DataDirectory);
                    return;
                }
            }
            var pinned = tls.PublicKeyFingerprint is { } hex ? Convert.FromHexString(hex) : null;
            var report = new MoveArrivedRequest(record.MoveToken, record.ServerId, configuration.Current.ServerName,
                runtime.LanAccessEnabled ? [.. ServerMoveTransport.LocalAddresses(runtime.LanHttpsPort)] : []);
            foreach (var delay in Delays)
            {
                if (delay > TimeSpan.Zero) await Task.Delay(delay, clock, stoppingToken);
                foreach (var address in record.Addresses)
                {
                    var outcome = await ReportAsync(address, pinned, report, stoppingToken);
                    if (outcome is null) continue;
                    if (outcome.Value) LogReported(logger);
                    else LogRefused(logger);
                    ServerMoveArrival.Delete(runtime.DataDirectory);
                    return;
                }
            }
            LogUnreachable(logger);
            ServerMoveArrival.Delete(runtime.DataDirectory);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            ArrivalReportFailed(logger, exception);
        }
    }

    /// <summary>True when the old server took the report, false when it refused it for good, null to try again.</summary>
    private async Task<bool?> ReportAsync(string address, byte[]? pinned, MoveArrivedRequest report, CancellationToken token)
    {
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps) return null;
        try
        {
            using var client = transport.Create(_ => { }, pinned);
            client.BaseAddress = uri;
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
            timeout.CancelAfter(TimeSpan.FromSeconds(15));
            using var response = await client.PostAsJsonAsync("/api/v1/move/arrived", report, Json, timeout.Token);
            if (response.IsSuccessStatusCode) return true;
            if (response.StatusCode == System.Net.HttpStatusCode.Forbidden) return false;
            if (response.StatusCode == System.Net.HttpStatusCode.Conflict)
            {
                // An older old server that already counts as moved answers server_moved.
                var problem = await response.Content.ReadFromJsonAsync<ApiProblem>(Json, timeout.Token);
                if (problem?.Code == "server_moved") return true;
            }
            return null;
        }
        catch (Exception exception) when (exception is HttpRequestException or JsonException or IOException or NotSupportedException
            || exception is OperationCanceledException && !token.IsCancellationRequested)
        { return null; }
    }

    [LoggerMessage(Level = LogLevel.Warning, Message = "The old server now knows that it moved here; devices switch on their own.")]
    private static partial void LogReported(ILogger logger);

    [LoggerMessage(Level = LogLevel.Warning, Message = "The old server refused the arrival report. Mark the move as finished there.")]
    private static partial void LogRefused(ILogger logger);

    [LoggerMessage(Level = LogLevel.Warning, Message = "The old server could not be reached to report the move. On the old server, choose Mark as Moved.")]
    private static partial void LogUnreachable(ILogger logger);
}
