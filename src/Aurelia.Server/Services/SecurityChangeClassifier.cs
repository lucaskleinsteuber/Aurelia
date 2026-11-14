using System.Text.RegularExpressions;

namespace Aurelia.Server.Services;

/// <summary>What a request changes, for the security log: a fixed kind and, when it names one, its target.</summary>
public enum SecurityTarget { None, Profile, Library, Title, Device }

public sealed record SecurityChange(string Kind, string Outcome, SecurityTarget Target = SecurityTarget.None, Guid? TargetId = null);

/// <summary>
/// Maps the server's sign-in and administration requests to security log entries. Requests that
/// only read, play or change a profile's own viewing state are not listed. The security endpoints
/// write their own entries.
/// </summary>
public static partial class SecurityChangeClassifier
{
    private const string Id = "([0-9a-fA-F-]{36})";

    private static readonly (string Method, Regex Path, string Kind, string Outcome, SecurityTarget Target)[] Rules =
    [
        ("POST", Route($"^/api/v1/(?:web/)?profiles/{Id}/unlock$"), "profile_opened", SecurityLog.Succeeded, SecurityTarget.Profile),
        ("POST", Route("^/api/v1/management/unlock$"), "management_unlocked", SecurityLog.Succeeded, SecurityTarget.None),
        ("POST", Route("^/api/v1/libraries$"), "library_added", SecurityLog.Changed, SecurityTarget.None),
        ("DELETE", Route($"^/api/v1/libraries/{Id}$"), "library_removed", SecurityLog.Changed, SecurityTarget.Library),
        ("POST", Route("^/api/v1/libraries/reset$"), "library_reset", SecurityLog.Changed, SecurityTarget.None),
        ("DELETE", Route($"^/api/v1/media/{Id}$"), "title_removed", SecurityLog.Changed, SecurityTarget.Title),
        ("POST", Route("^/api/v1/users$"), "profile_created", SecurityLog.Changed, SecurityTarget.None),
        ("DELETE", Route($"^/api/v1/users/{Id}$"), "profile_deleted", SecurityLog.Changed, SecurityTarget.Profile),
        ("PUT", Route($"^/api/v1/users/{Id}/pin$"), "pin_reset", SecurityLog.Changed, SecurityTarget.Profile),
        ("PUT", Route($"^/api/v1/users/{Id}/password$"), "password_reset", SecurityLog.Changed, SecurityTarget.Profile),
        ("PUT", Route($"^/api/v1/users/{Id}/role$"), "role_changed", SecurityLog.Changed, SecurityTarget.Profile),
        ("PUT", Route($"^/api/v1/users/{Id}/(?:screen-time|screen-time/today)$"), "screen_time_changed", SecurityLog.Changed, SecurityTarget.Profile),
        ("POST", Route($"^/api/v1/users/{Id}/screen-time/today$"), "screen_time_changed", SecurityLog.Changed, SecurityTarget.Profile),
        ("PUT", Route($"^/api/v1/users/{Id}/(?:profile|name|picture|picture/photo|access|enabled|age-limit|titles)$"), "profile_changed", SecurityLog.Changed, SecurityTarget.Profile),
        ("DELETE", Route($"^/api/v1/users/{Id}/sessions$"), "devices_signed_out", SecurityLog.Changed, SecurityTarget.Profile),
        ("DELETE", Route($"^/api/v1/(?:server|auth)/sessions/{Id}$"), "device_signed_out", SecurityLog.Changed, SecurityTarget.Device),
        ("POST", Route("^/api/v1/auth/pairings$"), "device_code_created", SecurityLog.Changed, SecurityTarget.None),
        ("POST", Route($"^/api/v1/server/device-pairings/{Id}/approve$"), "device_approved", SecurityLog.Changed, SecurityTarget.None),
        ("PUT", Route("^/api/v1/server/settings$"), "settings_changed", SecurityLog.Changed, SecurityTarget.None),
        ("POST", Route("^/api/v1/server/operations/network$"), "network_changed", SecurityLog.Changed, SecurityTarget.None),
        ("POST", Route("^/api/v1/server/operations/hosting$"), "settings_changed", SecurityLog.Changed, SecurityTarget.None),
        ("POST", Route("^/api/v1/server/operations/restart$"), "server_restarted", SecurityLog.Changed, SecurityTarget.None),
        ("PUT", Route("^/api/v1/server/power$"), "power_changed", SecurityLog.Changed, SecurityTarget.None),
        ("POST", Route($"^/api/v1/server/backups/restore/{Id}/apply$"), "backup_restored", SecurityLog.Changed, SecurityTarget.None),
        ("POST", Route("^/api/v1/server/backups/export$"), "backup_exported", SecurityLog.Changed, SecurityTarget.None),
        ("POST", Route("^/api/v1/server/updates/install$"), "update_installed", SecurityLog.Changed, SecurityTarget.None),
        ("PUT", Route("^/api/v1/metadata/provider$"), "metadata_changed", SecurityLog.Changed, SecurityTarget.None),
        ("DELETE", Route("^/api/v1/metadata/provider/token$"), "metadata_changed", SecurityLog.Changed, SecurityTarget.None),
        ("PUT", Route("^/api/v1/metadata/subtitles$"), "metadata_changed", SecurityLog.Changed, SecurityTarget.None),
        ("POST", Route("^/api/v1/server/automation/webhooks$"), "webhook_added", SecurityLog.Changed, SecurityTarget.None),
        ("PUT", Route($"^/api/v1/server/automation/webhooks/{Id}$"), "webhook_changed", SecurityLog.Changed, SecurityTarget.None),
        ("DELETE", Route($"^/api/v1/server/automation/webhooks/{Id}$"), "webhook_removed", SecurityLog.Changed, SecurityTarget.None),
        ("POST", Route($"^/api/v1/server/automation/webhooks/{Id}/secret$"), "webhook_secret_changed", SecurityLog.Changed, SecurityTarget.None),
        ("POST", Route("^/api/v1/server/automation/tokens$"), "integration_key_created", SecurityLog.Changed, SecurityTarget.None),
        ("DELETE", Route($"^/api/v1/server/automation/tokens/{Id}$"), "integration_key_removed", SecurityLog.Changed, SecurityTarget.None),
        ("POST", Route("^/api/v1/server/power/now$"), "power_now", SecurityLog.Changed, SecurityTarget.None),
    ];

    private static Regex Route(string pattern) => new(pattern, RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

    public static SecurityChange? Classify(string method, string? path)
    {
        if (string.IsNullOrEmpty(path)) return null;
        var trimmed = path.Length > 1 ? path.TrimEnd('/') : path;
        foreach (var rule in Rules)
        {
            if (!string.Equals(rule.Method, method, StringComparison.OrdinalIgnoreCase)) continue;
            var match = rule.Path.Match(trimmed);
            if (!match.Success) continue;
            Guid? target = match.Groups.Count > 1 && Guid.TryParse(match.Groups[1].Value, out var id) ? id : null;
            return new SecurityChange(rule.Kind, rule.Outcome, rule.Target, target);
        }
        return null;
    }

    /// <summary>The failed attempt an error stands for, or null when it is not a security event.</summary>
    public static string? FailureKind(string code) => code switch
    {
        "invalid_credentials" => "wrong_password",
        "invalid_profile_pin" => "wrong_pin",
        "invalid_pairing_code" or "invalid_device_pairing_code" => "wrong_code",
        "credential_locked" or "profile_pin_locked" or "pairing_locked" => "locked_out",
        "device_blocked" => "blocked_device_refused",
        "passkey_invalid" => "passkey_failed",
        "passkey_required" => "password_refused",
        _ => null,
    };
}
