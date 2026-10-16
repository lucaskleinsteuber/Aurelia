using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

// Cached readiness is deliberately independent of liveness. A disconnected
// library or a provider outage must never instruct the native host to restart.
public sealed class ServerReadinessService(
    IServiceScopeFactory scopes,
    IHostApplicationLifetime lifetime,
    ServerRuntimeOptions runtime,
    ServerConfigurationStore configuration,
    DatabaseBackupService backups,
    ServerDiagnosticsStore diagnostics,
    TimeProvider clock) : BackgroundService
{
    private readonly SemaphoreSlim sampleGate = new(1, 1);
    private ReadinessSample sample = new(new("starting", [], clock.GetUtcNow()), 0, 0, null);
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private static readonly HashSet<string> RecoveryCodes = ["host_transport_restart", "host_process_restart", "host_restart_limit", "host_manual_retry"];
    public ServerReadinessSummary Current => Volatile.Read(ref sample).Readiness;

    public ServerStatusResponse Status(ServerTlsIdentity identity, ActiveStreamRegistry streams)
    {
        var current = Volatile.Read(ref sample);
        return new("running", ServerProductVersion.Current,
            (DateTimeOffset.UtcNow - System.Diagnostics.Process.GetCurrentProcess().StartTime.ToUniversalTime()).TotalSeconds,
            streams.Count, DatabaseBytes(), current.Users, current.Libraries, current.FreeDiskBytes,
            identity.Certificate?.NotAfter.ToUniversalTime(), NetworkAddresses(), current.Readiness, RecoveryEvents());
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                if (lifetime.ApplicationStarted.IsCancellationRequested) await RefreshAsync(stoppingToken);
                await Task.Delay(TimeSpan.FromSeconds(Current.State == "starting" ? 1 : 15), clock, stoppingToken);
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    }

    internal async Task RefreshAsync(CancellationToken token)
    {
        await sampleGate.WaitAsync(token);
        try
        {
            var components = new List<ServerComponentStatus>();
            var now = clock.GetUtcNow();
            var users = 0;
            var libraries = 0;
            var freeBytes = AvailableSpace(runtime.DataDirectory);
            components.Add(ProbeStorage(runtime.DataDirectory, freeBytes));
            var operation = ReadOperation();
            components.Add(new("recovery", operation is { Kind: "restore", State: "restarting" } ? "recovering" : "ready",
                operation is { Kind: "restore", State: "restarting" } ? "restore_in_progress" : null));
            await using var scope = scopes.CreateAsyncScope();
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
            timeout.CancelAfter(TimeSpan.FromSeconds(3));
            try
            {
                // The connection timeout and this bounded sample are separate from
                // the HTTP endpoint used by the host's transport watchdog.
                database.Database.SetCommandTimeout(2);
                if (!await database.Database.CanConnectAsync(timeout.Token)) throw new IOException();
                users = await database.Users.IgnoreQueryFilters().CountAsync(timeout.Token);
                libraries = await database.LibraryRoots.IgnoreQueryFilters().CountAsync(timeout.Token);
                components.Add(new("database", "ready"));
                var unavailable = await database.LibraryRoots.IgnoreQueryFilters().AnyAsync(
                    root => root.Availability == LibraryAvailability.Unavailable, timeout.Token);
                var errors = await database.LibraryRoots.IgnoreQueryFilters().AnyAsync(
                    root => root.Availability == LibraryAvailability.Error, timeout.Token);
                components.Add(new("media", unavailable || errors ? "degraded" : "ready",
                    errors ? "media_access_error" : unavailable ? "media_drive_disconnected" : null));
                var cooldowns = await database.MetadataProviderCooldowns.AsNoTracking().Select(value => value.NotBefore).ToListAsync(timeout.Token);
                var providerWaiting = cooldowns.Any(value => value > now);
                var latestJob = await database.MetadataJobs.IgnoreQueryFilters().OrderByDescending(job => job.CreatedAt)
                    .Select(job => (MetadataJobState?)job.State).FirstOrDefaultAsync(timeout.Token);
                var providerFailure = latestJob == MetadataJobState.Failed;
                components.Add(new("metadata", providerWaiting || providerFailure ? "degraded" : "ready",
                    providerFailure ? "metadata_job_failed" : providerWaiting ? "provider_retry_pending" : null));
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
            catch (Exception exception) when (exception is System.Data.Common.DbException or IOException or OperationCanceledException or InvalidOperationException)
            {
                components.RemoveAll(value => value.Id is "database" or "media" or "metadata");
                components.Add(new("database", "unavailable", "database_unavailable"));
                components.Add(new("media", "unknown", "database_unavailable"));
                components.Add(new("metadata", "unknown", "database_unavailable"));
            }
            components.Add(BackupStatus(now));
            var readiness = new ServerReadinessSummary(DeriveState(components), components, now);
            var previous = Volatile.Read(ref sample).Readiness.State;
            Volatile.Write(ref sample, new(readiness, users, libraries, freeBytes));
            if (previous != readiness.State)
                diagnostics.Record("server_readiness_" + readiness.State, readiness.State == "ready" ? "information" : "warning");
        }
        finally { sampleGate.Release(); }
    }

    internal static string DeriveState(IReadOnlyList<ServerComponentStatus> components)
    {
        if (components.Any(value => value.State == "recovering")) return "recovering";
        if (components.Any(value => value.Id is "database" or "storage" && value.State == "unavailable")) return "unavailable";
        return components.Any(value => value.State == "degraded") ? "degraded" : "ready";
    }

    internal static ServerComponentStatus ProbeStorage(string directory, long? freeBytes)
    {
        if (freeBytes is < 1024 * 1024) return new("storage", "unavailable", "server_disk_full");
        var probe = Path.Combine(directory, ".readiness-" + Guid.NewGuid().ToString("N"));
        try
        {
            using (var file = PrivateFilePermissions.OpenNewPrivateFile(probe)) { file.WriteByte(0); file.Flush(); }
            return new("storage", freeBytes is < 256 * 1024 * 1024 ? "degraded" : "ready",
                freeBytes is < 256 * 1024 * 1024 ? "server_disk_low" : null);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        { return new("storage", "unavailable", "server_storage_unwritable"); }
        finally
        {
            try { File.Delete(probe); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        }
    }

    private ServerComponentStatus BackupStatus(DateTimeOffset now)
    {
        if (backups.Health.LastAttemptFailed) return new("backups", "degraded", "backup_attempt_failed");
        if (!configuration.Current.AutomaticBackupsEnabled) return new("backups", "ready", "automatic_backups_disabled");
        try
        {
            var latest = backups.ListBackups().Where(value => value.Kind is DatabaseBackupKind.Daily or DatabaseBackupKind.Manual)
                .Select(value => (DateTimeOffset?)value.CreatedAt).Max();
            return latest is null ? new("backups", "pending", "first_backup_pending")
                : now - latest > TimeSpan.FromHours(configuration.Current.BackupIntervalHours + 1)
                    ? new("backups", "degraded", "scheduled_backup_overdue") : new("backups", "ready");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException)
        { return new("backups", "degraded", "backup_storage_unavailable"); }
    }

    private HostOperationJournal? ReadOperation()
    {
        try
        {
            var path = Path.Combine(runtime.DataDirectory, "host-operation.json");
            var file = new FileInfo(path);
            return file.Exists && file.LinkTarget is null && file.Length <= 64 * 1024
                ? JsonSerializer.Deserialize<HostOperationJournal>(File.ReadAllBytes(path), Json) : null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }

    private ServerRecoveryEvent[] RecoveryEvents()
    {
        try
        {
            var file = new FileInfo(Path.Combine(runtime.DataDirectory, "host-recovery.json"));
            if (!file.Exists || file.LinkTarget is not null || file.Length > 64 * 1024) return [];
            return (JsonSerializer.Deserialize<ServerRecoveryEvent[]>(File.ReadAllBytes(file.FullName), Json) ?? [])
                .Where(value => RecoveryCodes.Contains(value.Code)).OrderByDescending(value => value.At).Take(20).ToArray();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException) { return []; }
    }

    private long DatabaseBytes()
    {
        try { return File.Exists(runtime.DatabasePath) ? new FileInfo(runtime.DatabasePath).Length : 0; }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return 0; }
    }

    private string[] NetworkAddresses()
    {
        try
        {
            return System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()
                .Where(network => network.OperationalStatus == System.Net.NetworkInformation.OperationalStatus.Up)
                .SelectMany(network => network.GetIPProperties().UnicastAddresses).Select(address => address.Address)
                .Where(address => ServerRequestGuard.NetworkAllowed(address, configuration.Current.AllowedNetworks))
                .Select(address => address.ToString()).Distinct().Take(64).ToArray();
        }
        catch (System.Net.NetworkInformation.NetworkInformationException) { return []; }
    }

    private static long? AvailableSpace(string path)
    {
        try { return new DriveInfo(path).AvailableFreeSpace; }
        catch (Exception exception) when (exception is IOException or ArgumentException or UnauthorizedAccessException) { return null; }
    }

    private sealed record ReadinessSample(ServerReadinessSummary Readiness, int Users, int Libraries, long? FreeDiskBytes);
}
