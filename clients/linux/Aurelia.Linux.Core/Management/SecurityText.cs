namespace Aurelia.Linux.Core.Management;

/// <summary>Words for Settings › Security, the same on every Aurelia app.</summary>
public static class SecurityText
{
    private static readonly Dictionary<string, string> Kinds = new(StringComparer.Ordinal)
    {
        ["signed_in"] = "Signed in",
        ["profile_opened"] = "Opened profile",
        ["management_unlocked"] = "Unlocked management",
        ["wrong_password"] = "Wrong Server Password",
        ["wrong_pin"] = "Wrong profile PIN",
        ["wrong_code"] = "Wrong device code",
        ["locked_out"] = "Paused after wrong attempts",
        ["blocked_device_refused"] = "Blocked device refused",
        ["passkey_failed"] = "Face ID or Touch ID not confirmed",
        ["password_refused"] = "Server Password refused (Face ID required)",
        ["library_added"] = "Storage location added",
        ["library_removed"] = "Storage location removed",
        ["library_reset"] = "Library reset",
        ["title_removed"] = "Title removed",
        ["profile_created"] = "Profile created",
        ["profile_changed"] = "Profile changed",
        ["profile_deleted"] = "Profile deleted",
        ["pin_reset"] = "PIN replaced",
        ["password_reset"] = "Password replaced",
        ["role_changed"] = "Role changed",
        ["screen_time_changed"] = "Screen time changed",
        ["devices_signed_out"] = "Devices signed out",
        ["device_signed_out"] = "Device signed out",
        ["device_code_created"] = "Device code created",
        ["device_approved"] = "Device allowed",
        ["device_blocked"] = "Device blocked",
        ["device_unblocked"] = "Device unblocked",
        ["settings_changed"] = "Server settings changed",
        ["network_changed"] = "Network changed",
        ["server_restarted"] = "Server restarted",
        ["power_changed"] = "Power settings changed",
        ["backup_restored"] = "Backup restored",
        ["backup_exported"] = "Encrypted backup saved",
        ["update_installed"] = "Server update installed",
        ["metadata_changed"] = "Metadata settings changed",
        ["passkey_added"] = "Face ID or Touch ID set up",
        ["passkey_removed"] = "Face ID or Touch ID removed",
        ["passkey_requirement_changed"] = "Face ID requirement changed",
        ["security_settings_changed"] = "Security settings changed",
        ["remote_unlock_approved"] = "Unlock confirmed for another device",
        ["remote_unlock_denied"] = "Unlock denied for another device",
    };

    /// <summary>"Storage location removed"; an unknown kind from a newer server is shown, not dropped.</summary>
    public static string Kind(string kind)
    {
        ArgumentNullException.ThrowIfNull(kind);
        if (Kinds.TryGetValue(kind, out var known)) return known;
        return string.Join(' ', kind.Split('_', StringSplitOptions.RemoveEmptyEntries).Select(word => char.ToUpperInvariant(word[0]) + word[1..]));
    }

    /// <summary>"iOS · 192.168.1.40", or "" when the server knows neither.</summary>
    public static string DeviceLine(string? platform, string? ipAddress) =>
        string.Join(" · ", new[] { platform, ipAddress }.Where(part => !string.IsNullOrEmpty(part)));

    /// <summary>"New device signed in: Pixel · Android · 192.168.1.40".</summary>
    public static string NewDevice(string deviceName, string? platform, string? ipAddress)
    {
        var line = DeviceLine(platform, ipAddress);
        return "New device signed in: " + deviceName + (line.Length > 0 ? " · " + line : "");
    }

    public static readonly IReadOnlyList<(string Value, string Label)> Filters =
        [("all", "All"), ("succeeded", "Sign-Ins"), ("failed", "Failed"), ("changed", "Changes")];

    public static bool RemoteUnlockFinished(string state) => state is "approved" or "denied" or "expired";

    public static string RemoteUnlockState(string state) => state switch
    {
        "approved" => "Confirmed. Server management is unlocked for ten minutes.",
        "denied" => "The request was denied on the other device.",
        "expired" => "The request expired. Ask again.",
        _ => "Waiting for confirmation on an iPhone, iPad or Mac with Face ID or Touch ID…",
    };
}
