using System.Text.Json;

namespace Aurelia.Server.Services;

public sealed record ActiveServerNetwork(string ServerName, bool LanAccessEnabled, int LanHttpsPort);
public sealed record ServerConfigurationResponse(ServerHostSettings Stored, ActiveServerNetwork Active, bool RestartRequired);

public sealed class ServerConfigurationStore
{
    private readonly object gate = new();
    private readonly ServerRuntimeOptions runtime;
    private ServerHostSettings current;
    private readonly bool activeBonjourEnabled;
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    public ServerConfigurationStore(ServerRuntimeOptions runtime)
    {
        this.runtime = runtime;
        current = ServerHostSettings.Load(runtime.DataDirectory) ?? new ServerHostSettings(
            2, runtime.ServerName, runtime.LanAccessEnabled, runtime.LanHttpsPort);
        Validate(current);
        activeBonjourEnabled = current.BonjourEnabled;
    }
    public ServerHostSettings Current { get { lock (gate) return current; } }
    public ServerConfigurationResponse Read()
    {
        var stored = Current;
        return new(stored, new(runtime.ServerName, runtime.LanAccessEnabled, runtime.LanHttpsPort),
            stored.ServerName != runtime.ServerName || stored.LanAccessEnabled != runtime.LanAccessEnabled
            || stored.LanHttpsPort != runtime.LanHttpsPort || stored.BonjourEnabled != activeBonjourEnabled);
    }
    public ServerConfigurationResponse Update(ServerHostSettings candidate) => Update(candidate, allowNetworkChange: false);
    internal ServerConfigurationResponse Update(ServerHostSettings candidate, bool allowNetworkChange)
    {
        Validate(candidate);
        lock (gate)
        {
            if (!allowNetworkChange && HostChangePending())
                throw new AccountException("host_operation_active", "Wait for the active host operation to finish before changing settings.", 409);
            if (candidate.Revision != current.Revision)
                throw new AccountException("settings_conflict", "Settings changed on another device. Reload before saving.", 409);
            if (!allowNetworkChange && (candidate.ServerName != current.ServerName || candidate.LanAccessEnabled != current.LanAccessEnabled
                || candidate.LanHttpsPort != current.LanHttpsPort || candidate.BonjourEnabled != current.BonjourEnabled
                || !(candidate.AllowedNetworks ?? []).SequenceEqual(current.AllowedNetworks ?? [], StringComparer.Ordinal)))
                throw new AccountException("network_operation_required", "Network changes require a confirmed host operation. Security settings may be saved independently.", 409);
            candidate = candidate with
            {
                Version = 2,
                Revision = checked(current.Revision + 1),
                AllowedNetworks = candidate.AllowedNetworks?.Distinct(StringComparer.Ordinal).ToArray() ?? []
            };
            PrivateFilePermissions.CreatePrivateDirectory(runtime.DataDirectory);
            var path = Path.Combine(runtime.DataDirectory, ServerHostSettings.FileName);
            var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                using (var file = PrivateFilePermissions.OpenNewPrivateFile(temporary))
                {
                    JsonSerializer.Serialize(file, candidate, Json);
                    file.Flush(flushToDisk: true);
                }
                File.Move(temporary, path, overwrite: true);
                PrivateFilePermissions.ProtectFile(path);
                current = candidate;
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        return Read();
    }
    private bool HostChangePending()
    {
        var path = Path.Combine(runtime.DataDirectory, "host-operation.json");
        if (!File.Exists(path)) return false;
        var info = new FileInfo(path);
        if (info.LinkTarget is not null || info.Length > ServerRequestGuard.MaximumJsonBytes)
            throw new InvalidDataException("Invalid host operation journal.");
        using var file = File.OpenRead(path);
        return JsonSerializer.Deserialize<HostOperationJournal>(file, Json)?.State is "awaitingConfirmation" or "restarting";
    }
    internal static void Validate(ServerHostSettings value)
    {
        if (value.Version is not 1 and not 2 || value.Revision < 1
            || string.IsNullOrWhiteSpace(value.ServerName) || value.ServerName.Length > 128 || value.ServerName.Any(char.IsControl)
            || value.LanHttpsPort is < 1024 or > 65535 || value.DeviceSessionDays is < 1 or > 365
            || value.GlobalStreamLimit is < 1 or > 128 || value.UserStreamLimit is < 1 or > 16
            || value.UserStreamLimit > value.GlobalStreamLimit || value.AllowedNetworks?.Length > 32
            || value.ReconciliationMinutes is < 15 or > 10080 || value.JobQueueLimit is < 10 or > 10000
            || value.MaintenanceStartHour is < 0 or > 23 || value.MaintenanceEndHour is < 1 or > 24
            || value.MaintenanceStartHour == value.MaintenanceEndHour
            || value.BackupIntervalHours is < 1 or > 168 || value.DailyBackupsRetained is < 1 or > 30
            || value.WeeklyBackupsRetained is < 1 or > 12 || value.EventRetentionDays is < 1 or > 90
            || value.MaximumEvents is < 100 or > 10000
            || (value.AllowedNetworks?.Any(network => !System.Net.IPNetwork.TryParse(network, out _)) ?? false))
            throw new AccountException("invalid_settings", "The server settings contain an invalid value.", 400);
    }

    public bool IsMaintenanceWindow(DateTimeOffset now)
    {
        var settings = Current;
        var hour = now.ToLocalTime().Hour;
        return settings.MaintenanceStartHour < settings.MaintenanceEndHour
            ? hour >= settings.MaintenanceStartHour && hour < settings.MaintenanceEndHour
            : hour >= settings.MaintenanceStartHour || hour < settings.MaintenanceEndHour;
    }
}
