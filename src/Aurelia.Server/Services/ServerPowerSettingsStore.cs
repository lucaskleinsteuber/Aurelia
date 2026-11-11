using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Aurelia.Contracts;

namespace Aurelia.Server.Services;

/// <summary>
/// Keeps what a Linux server does when unused in <c>sleep-settings</c> in the data folder, where the
/// package's root-run <c>aurelia-autosleep</c> and the <c>aurelia sleep</c> command read them as
/// plain KEY=value lines. Elsewhere than in the Linux package nothing would act on them, so they
/// are reported as unavailable and cannot be changed. The package's root-run wake script leaves the
/// network card's wake abilities in <c>wake-on-lan-support</c>, so the server needs no network rights.
/// </summary>
public sealed partial class ServerPowerSettingsStore(ServerRuntimeOptions runtime, bool? available = null, string? hosting = null)
{
    public const string FileName = "sleep-settings";
    public const string WakeSupportFileName = "wake-on-lan-support";
    public const int DefaultIdleMinutes = 15;
    public const int MinimumIdleMinutes = 5;
    public const int MaximumIdleMinutes = 24 * 60;
    public static readonly IReadOnlyList<string> Modes = ["off", "stop", "sleep", "shutdown"];
    private readonly object gate = new();

    /// <summary>Where the server runs; a server hosted by the Mac or Linux app only stops after unused minutes.</summary>
    public string Hosting => hosting ?? ServerHosting.Kind(runtime);
    private bool ByApp => ServerHosting.ByApp(Hosting);
    private bool Available => available ?? (LinuxPackage.IsInstalled || ByApp);
    private string SettingsPath => Path.Combine(runtime.DataDirectory, FileName);

    public ServerPowerSettings Read()
    {
        lock (gate)
        {
            var values = ReadValues();
            var idle = values.TryGetValue("IDLE_MINUTES", out var text)
                && int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var minutes)
                && minutes is >= MinimumIdleMinutes and <= MaximumIdleMinutes ? minutes : DefaultIdleMinutes;
            var from = Time(values.GetValueOrDefault("AWAKE_FROM"));
            var until = Time(values.GetValueOrDefault("AWAKE_UNTIL"));
            if (from is null || until is null) from = until = null;
            var mode = values.GetValueOrDefault("MODE") is { } stored && Modes.Contains(stored) ? stored : "off";
            // A host app's server can't sleep or turn off its computer; anything else stored counts as stop.
            if (ByApp && mode is "sleep" or "shutdown") mode = "stop";
            return new(Available, mode, idle, from, until, !ByApp && values.GetValueOrDefault("WAKE_ON_ACCESS") == "on",
                ByApp ? "" : WakeSupport(), Hosting, values.GetValueOrDefault("AFTER_SLEEP_TIMER") != "off");
        }
    }

    public ServerPowerSettings Update(UpdateServerPowerSettingsRequest request)
    {
        if (!Available)
            throw new AccountException("power_settings_unavailable", "Power settings are available on Linux servers installed from the Aurelia package and on servers hosted by Aurelia for Mac or Linux.", 409);
        if (!Modes.Contains(request.Mode))
            throw new AccountException("invalid_power_mode", "Choose off, stop, sleep or shutdown.", 400);
        if (ByApp && request.Mode is "sleep" or "shutdown")
            throw new AccountException("invalid_power_mode", "A server hosted by the Aurelia app can keep running or stop after unused minutes.", 400);
        if (request.IdleMinutes is < MinimumIdleMinutes or > MaximumIdleMinutes)
            throw new AccountException("invalid_idle_minutes", $"Choose between {MinimumIdleMinutes} and {MaximumIdleMinutes} minutes.", 400);
        var from = string.IsNullOrEmpty(request.AwakeFrom) ? null : Time(request.AwakeFrom);
        var until = string.IsNullOrEmpty(request.AwakeUntil) ? null : Time(request.AwakeUntil);
        if ((from is null) != string.IsNullOrEmpty(request.AwakeFrom) || (until is null) != string.IsNullOrEmpty(request.AwakeUntil)
            || (from is null) != (until is null) || (from is not null && from == until))
            throw new AccountException("invalid_awake_hours", "Awake hours need a start and a different end, as HH:MM.", 400);
        var current = Read();
        var wakeOnAccess = request.WakeOnAccess ?? current.WakeOnAccess;
        var afterSleepTimer = request.AfterSleepTimer ?? current.AfterSleepTimer;
        if (request.WakeOnAccess == true && (ByApp || !WakeSupport().Contains('u', StringComparison.Ordinal)))
            throw new AccountException("wake_on_access_unavailable", "This computer's network card can't wake it when a device connects.", 400);

        var content = new StringBuilder()
            .Append("# What Aurelia Server does when unused, changed in the app or with `sudo aurelia sleep`.\n")
            .Append(CultureInfo.InvariantCulture, $"MODE={request.Mode}\n")
            .Append(CultureInfo.InvariantCulture, $"IDLE_MINUTES={request.IdleMinutes}\n")
            .Append(CultureInfo.InvariantCulture, $"AWAKE_FROM={from}\n")
            .Append(CultureInfo.InvariantCulture, $"AWAKE_UNTIL={until}\n")
            .Append(CultureInfo.InvariantCulture, $"WAKE_ON_ACCESS={(wakeOnAccess ? "on" : "off")}\n")
            .Append(CultureInfo.InvariantCulture, $"AFTER_SLEEP_TIMER={(afterSleepTimer ? "on" : "off")}\n")
            .ToString();
        lock (gate)
        {
            PrivateFilePermissions.CreatePrivateDirectory(runtime.DataDirectory);
            var temporary = SettingsPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                using (var file = PrivateFilePermissions.OpenNewPrivateFile(temporary))
                {
                    file.Write(Encoding.ASCII.GetBytes(content));
                    file.Flush(flushToDisk: true);
                }
                File.Move(temporary, SettingsPath, overwrite: true);
                PrivateFilePermissions.ProtectFile(SettingsPath);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        return Read();
    }

    private Dictionary<string, string> ReadValues()
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var info = new FileInfo(SettingsPath);
        if (!info.Exists || info.LinkTarget is not null || info.Length > 4096) return values;
        foreach (var line in File.ReadLines(SettingsPath))
        {
            var match = SettingLine().Match(line);
            if (match.Success) values[match.Groups[1].Value] = match.Groups[2].Value;
        }
        return values;
    }

    /// <summary>The card's wake letters as the wake script found them; anything else in the file is ignored.</summary>
    private string WakeSupport()
    {
        var info = new FileInfo(Path.Combine(runtime.DataDirectory, WakeSupportFileName));
        if (!info.Exists || info.LinkTarget is not null || info.Length > 64) return "";
        var letters = File.ReadAllText(info.FullName).Where(letter => "pumbagsf".Contains(letter, StringComparison.Ordinal));
        return new string(letters.Distinct().ToArray());
    }

    private static string? Time(string? value) => value is not null && TimeOfDay().IsMatch(value) ? value : null;

    [GeneratedRegex(@"^(MODE|IDLE_MINUTES|AWAKE_FROM|AWAKE_UNTIL|WAKE_ON_ACCESS|AFTER_SLEEP_TIMER)=([a-z0-9:]*)\z")]
    private static partial Regex SettingLine();

    [GeneratedRegex(@"^([01][0-9]|2[0-3]):[0-5][0-9]\z")]
    private static partial Regex TimeOfDay();
}
