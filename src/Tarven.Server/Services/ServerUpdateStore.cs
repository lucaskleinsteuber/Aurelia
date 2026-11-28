using System.Globalization;
using System.Text.RegularExpressions;
using Tarven.Contracts;

namespace Tarven.Server.Services;

/// <summary>
/// Updates of a Linux server installed from the package, started from the app. The server cannot
/// install anything itself: it leaves <c>update-requested</c> or <c>update-check-requested</c> in its
/// data folder, where the package's root-run <c>tarven-update-request.path</c> notices it and runs
/// <c>tarven update</c>. That command reports back in <c>update-status</c> as plain KEY=value lines,
/// which are only parsed here, never trusted beyond their expected form.
/// </summary>
public sealed partial class ServerUpdateStore(ServerRuntimeOptions runtime, TimeProvider clock, bool? available = null,
    string? installedVersion = null, int? installedBuild = null)
{
    public const string StatusFileName = "update-status";
    public const string InstallRequestFileName = "update-requested";
    public const string CheckRequestFileName = "update-check-requested";
    // An installation that has not finished by then has failed; a check answers within seconds.
    private static readonly TimeSpan InstallTimeout = TimeSpan.FromMinutes(15);
    private static readonly TimeSpan CheckTimeout = TimeSpan.FromMinutes(2);
    private readonly object gate = new();

    private bool Available => available ?? LinuxPackage.IsInstalled;
    private string InstalledVersion => installedVersion ?? ServerProductVersion.Current;
    private int InstalledBuild => installedBuild ?? ServerProductVersion.Build;
    private string PathOf(string name) => Path.Combine(runtime.DataDirectory, name);

    public ServerUpdateStatus Read()
    {
        lock (gate)
        {
            var installed = $"{InstalledVersion} ({InstalledBuild})";
            if (!Available) return new(false, installed, null, false, "idle", null, null);
            var values = ReadValues();
            var now = clock.GetUtcNow();
            var checkedAt = Seconds(values.GetValueOrDefault("CHECKED_AT"));
            var newestBuild = Number(values.GetValueOrDefault("NEWEST_BUILD"));
            var newestVersion = values.GetValueOrDefault("NEWEST_VERSION") is { Length: > 0 } version ? version : null;
            var newest = newestBuild is { } build && newestVersion is not null ? $"{newestVersion} ({build})" : null;
            var updateAvailable = newestBuild > InstalledBuild;
            var changedAt = Seconds(values.GetValueOrDefault("CHANGED_AT")) ?? checkedAt;
            var state = values.GetValueOrDefault("STATE") ?? "idle";
            string? message = values.GetValueOrDefault("MESSAGE") is { Length: > 0 } text ? text : null;
            var progress = Percent(values.GetValueOrDefault("PROGRESS"));
            string? phase = values.GetValueOrDefault("PHASE") is { Length: > 0 } currentPhase ? currentPhase : null;

            if (File.Exists(PathOf(InstallRequestFileName)))
                (state, message, progress, phase) = ("installing", null, 2, "starting");
            else if (File.Exists(PathOf(CheckRequestFileName)))
                (state, message, progress, phase) = ("checking", null, 5, "checking");
            else if (state == "installing")
            {
                if (Number(values.GetValueOrDefault("TARGET_BUILD")) is { } target && InstalledBuild >= target)
                    (state, message, updateAvailable, progress, phase) = ("idle", null, newestBuild > InstalledBuild, null, null);
                else if (changedAt is null || now - changedAt > InstallTimeout)
                    (state, message, progress, phase) = ("failed", message ?? "The update did not finish. Tarven Server keeps its previous version.", null, null);
            }
            else if (state == "checking" && (changedAt is null || now - changedAt > CheckTimeout))
                (state, progress, phase) = ("idle", null, null);
            else if (state is not ("idle" or "failed"))
                (state, progress, phase) = ("idle", null, null);

            if (state is "idle" or "failed")
                (progress, phase) = (null, null);
            return new(true, installed, newest, updateAvailable, state, checkedAt, message, progress, phase);
        }
    }

    public ServerUpdateStatus RequestCheck()
    {
        RequireAvailable();
        lock (gate) Touch(CheckRequestFileName);
        return Read();
    }

    public ServerUpdateStatus RequestInstall()
    {
        RequireAvailable();
        var status = Read();
        if (status.State == "installing")
            throw new AccountException("update_in_progress", "An update is already being installed.", 409);
        if (!status.UpdateAvailable)
            throw new AccountException("no_update", "Tarven Server is already up to date. Check for updates first.", 409);
        lock (gate) Touch(InstallRequestFileName);
        return Read();
    }

    private void RequireAvailable()
    {
        if (!Available)
            throw new AccountException("updates_unavailable", "Updates from the app are available on Linux servers installed from the Tarven package.", 409);
    }

    private void Touch(string name)
    {
        PrivateFilePermissions.CreatePrivateDirectory(runtime.DataDirectory);
        var path = PathOf(name);
        if (File.Exists(path)) return;
        using (PrivateFilePermissions.OpenNewPrivateFile(path)) { }
    }

    private Dictionary<string, string> ReadValues()
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var info = new FileInfo(PathOf(StatusFileName));
        if (!info.Exists || info.LinkTarget is not null || info.Length > 4096) return values;
        foreach (var line in File.ReadLines(info.FullName))
        {
            var match = StatusLine().Match(line);
            if (match.Success && IsValid(match.Groups[1].Value, match.Groups[2].Value))
                values[match.Groups[1].Value] = match.Groups[2].Value;
        }
        return values;
    }

    // Values are what tarven update writes: a state, numbers, a version and a short plain message.
    private static bool IsValid(string key, string value) => key switch
    {
        "STATE" => value is "idle" or "checking" or "installing" or "failed",
        "PHASE" => value is "starting" or "checking" or "verifying" or "downloading" or "unpacking" or "restarting",
        "NEWEST_VERSION" => VersionText().IsMatch(value),
        "MESSAGE" => value.Length <= 200 && value.All(character => character is >= ' ' and <= '~'),
        _ => value.Length <= 12 && value.All(char.IsAsciiDigit),
    };

    private static int? Number(string? value) =>
        int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var number) && number > 0 ? number : null;

    private static int? Percent(string? value) =>
        int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var number) && number is >= 0 and <= 100 ? number : null;

    private static DateTimeOffset? Seconds(string? value) =>
        long.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var seconds) && seconds > 0
            ? DateTimeOffset.FromUnixTimeSeconds(seconds) : null;

    [GeneratedRegex(@"^(STATE|CHECKED_AT|CHANGED_AT|NEWEST_BUILD|TARGET_BUILD|NEWEST_VERSION|PROGRESS|PHASE|MESSAGE)=(.*)\z")]
    private static partial Regex StatusLine();

    [GeneratedRegex(@"^[0-9]+(\.[0-9]+){1,3}\z")]
    private static partial Regex VersionText();
}
