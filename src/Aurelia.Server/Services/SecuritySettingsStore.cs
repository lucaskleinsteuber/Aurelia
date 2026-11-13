using System.Text.Json;

namespace Aurelia.Server.Services;

public sealed record SecuritySettings(int SecurityLogDays = 90, bool RequirePasskeysForAdministrators = false);

/// <summary>
/// The owner's security settings in <c>security-settings.json</c>. They live apart from
/// server-settings.json so that an older app, which saves the server settings without knowing
/// these fields, can never turn Face ID / Touch ID off by accident.
/// </summary>
public sealed class SecuritySettingsStore
{
    public const int MinimumLogDays = 30;
    public const int MaximumLogDays = 365;
    private const string FileName = "security-settings.json";
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private readonly object gate = new();
    private readonly string path;
    private SecuritySettings current;

    public SecuritySettingsStore(ServerRuntimeOptions runtime)
    {
        path = Path.Combine(runtime.DataDirectory, FileName);
        current = Load(path) ?? new SecuritySettings();
    }

    public SecuritySettings Current { get { lock (gate) return current; } }

    public SecuritySettings Update(SecuritySettings candidate)
    {
        if (candidate.SecurityLogDays is < MinimumLogDays or > MaximumLogDays)
            throw new AccountException("invalid_settings", $"Keep the security log for {MinimumLogDays} to {MaximumLogDays} days.", 400);
        lock (gate)
        {
            var directory = Path.GetDirectoryName(path)!;
            PrivateFilePermissions.CreatePrivateDirectory(directory);
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
            return current;
        }
    }

    private static SecuritySettings? Load(string path)
    {
        try
        {
            var file = new FileInfo(path);
            if (!file.Exists || file.Length > 64 * 1024 || file.LinkTarget is not null) return null;
            var value = JsonSerializer.Deserialize<SecuritySettings>(File.ReadAllText(path), Json);
            return value is null ? null : value with
            {
                SecurityLogDays = Math.Clamp(value.SecurityLogDays, MinimumLogDays, MaximumLogDays),
            };
        }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException) { return null; }
    }
}
