using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Xml;
using System.Xml.Linq;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services.Automation;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services.FileChecks;

/// <summary>What one drive reports about itself, before the storage locations on it are added.</summary>
public sealed record DriveReport(string Key, string Name, DriveHealthState State, double? TemperatureCelsius = null,
    long? PowerOnHours = null, long? BadSectors = null, string? Detail = null);

/// <summary>
/// How the drives that hold the storage locations are doing, as they report it themselves
/// (SMART). On Linux the values come from UDisks2 over the system bus (<c>busctl</c>, no root,
/// no shell); on a Mac from <c>diskutil</c>. Only values the system already keeps are read, so a
/// sleeping drive is not woken. Elsewhere, and for network shares, the state is unknown. Asked
/// every six hours; nothing is stored.
/// </summary>
public sealed partial class DriveHealthService(
    IServiceScopeFactory scopes,
    AutomationEventBus events,
    ILogger<DriveHealthService> logger,
    TimeProvider? timeProvider = null) : BackgroundService
{
    private static readonly TimeSpan Interval = TimeSpan.FromHours(6);
    private static readonly TimeSpan CommandTimeout = TimeSpan.FromSeconds(5);
    private const int MaximumOutput = 1 << 20;
    private const double HotCelsius = 60;

    private static readonly HashSet<string> NetworkFileSystems = new(StringComparer.Ordinal)
    {
        "nfs", "nfs4", "cifs", "smb3", "smbfs", "fuse.sshfs", "sshfs", "9p", "afpfs", "fuse.rclone", "davfs", "fuse.davfs2", "glusterfs", "ceph",
    };

    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly SemaphoreSlim refresh = new(1, 1);
    private readonly Dictionary<string, DriveHealthState> earlier = new(StringComparer.Ordinal);
    private DriveHealthResponse? last;

    public override void Dispose()
    {
        base.Dispose();
        refresh.Dispose();
    }

    /// <summary>The drives' state, asked again when the last answer is older than six hours.</summary>
    public async Task<DriveHealthResponse> ReadAsync(CancellationToken cancellationToken)
    {
        if (last is { CheckedAt: { } at } known && clock.GetUtcNow() - at < Interval) return known;
        return await RefreshAsync(cancellationToken);
    }

    /// <summary>How many drives report a warning or failure, for Server Health; never asks the drives itself.</summary>
    public int WarningCount => last?.Drives.Count(drive => drive.State is DriveHealthState.Warning or DriveHealthState.Failing) ?? 0;

    public async Task<DriveHealthResponse> RefreshAsync(CancellationToken cancellationToken)
    {
        await refresh.WaitAsync(cancellationToken);
        try
        {
            List<(string Name, string Path)> roots;
            await using (var scope = scopes.CreateAsyncScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                roots = (await database.LibraryRoots.AsNoTracking().Select(root => new { root.Name, root.Path }).ToListAsync(cancellationToken))
                    .Select(root => (root.Name, root.Path)).ToList();
            }
            var drives = new Dictionary<string, (DriveReport Report, List<string> Libraries)>(StringComparer.Ordinal);
            foreach (var (name, path) in roots)
            {
                DriveReport report;
                try
                {
                    report = await ReportAsync(path, cancellationToken);
                }
                catch (Exception exception) when (exception is not OperationCanceledException)
                {
                    LogProbeFailed(logger, exception);
                    report = new DriveReport("unknown:" + path, "Unknown drive", DriveHealthState.Unknown, Detail: "Its health could not be read.");
                }
                if (!drives.TryGetValue(report.Key, out var entry)) drives[report.Key] = entry = (report, []);
                entry.Libraries.Add(name);
            }
            var now = clock.GetUtcNow();
            var summaries = drives.Values
                .Select(entry => new DriveHealthSummary(entry.Report.Name, [.. entry.Libraries.Order(StringComparer.CurrentCultureIgnoreCase)],
                    entry.Report.State, entry.Report.TemperatureCelsius, entry.Report.PowerOnHours, entry.Report.BadSectors, entry.Report.Detail))
                .OrderBy(drive => drive.State switch { DriveHealthState.Failing => 0, DriveHealthState.Warning => 1, DriveHealthState.Good => 2, _ => 3 })
                .ThenBy(drive => drive.Name, StringComparer.CurrentCultureIgnoreCase)
                .ToList();
            foreach (var (key, entry) in drives)
            {
                var state = entry.Report.State;
                var before = earlier.GetValueOrDefault(key, DriveHealthState.Good);
                if (state is DriveHealthState.Failing or DriveHealthState.Warning && before is not (DriveHealthState.Failing or DriveHealthState.Warning))
                {
                    events.Publish(new AutomationEvent(AutomationEvents.DriveFailing, Guid.NewGuid(), now, Count: 1));
                    LogDriveWarning(logger, entry.Report.Name, state);
                }
                earlier[key] = state;
            }
            last = new DriveHealthResponse(summaries, now);
            return last;
        }
        finally
        {
            refresh.Release();
        }
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            await Task.Delay(TimeSpan.FromMinutes(2), stoppingToken);
            while (!stoppingToken.IsCancellationRequested)
            {
                try { await RefreshAsync(stoppingToken); }
                catch (Exception exception) when (exception is not OperationCanceledException) { LogProbeFailed(logger, exception); }
                await Task.Delay(Interval, stoppingToken);
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    }

    private static async Task<DriveReport> ReportAsync(string path, CancellationToken cancellationToken)
    {
        if (OperatingSystem.IsLinux()) return await LinuxReportAsync(path, cancellationToken);
        if (OperatingSystem.IsMacOS()) return await MacReportAsync(path, cancellationToken);
        return new DriveReport("unknown:" + path, "Unknown drive", DriveHealthState.Unknown, Detail: "This system doesn't report drive health to Aurelia.");
    }

    // Linux ------------------------------------------------------------------------------------

    /// <summary>One line of /proc/self/mounts: the device, where it is mounted, and its file system.</summary>
    public sealed record MountEntry(string Device, string Target, string FileSystem);

    public static IReadOnlyList<MountEntry> ParseMounts(IEnumerable<string> lines)
    {
        ArgumentNullException.ThrowIfNull(lines);
        var entries = new List<MountEntry>();
        foreach (var line in lines)
        {
            var fields = line.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length < 3 || !fields[1].StartsWith('/')) continue;
            entries.Add(new MountEntry(StorageMounts.Unescape(fields[0]), StorageMounts.Unescape(fields[1]), fields[2]));
        }
        return entries;
    }

    /// <summary>The mount that holds a path: the one with the longest target at or above it.</summary>
    public static MountEntry? MountFor(string path, IReadOnlyList<MountEntry> mounts)
    {
        ArgumentNullException.ThrowIfNull(mounts);
        var full = Path.TrimEndingDirectorySeparator(path);
        // A later mount over the same folder hides the earlier one.
        return mounts
            .Select((mount, index) => (Mount: mount, Index: index))
            .Where(entry => entry.Mount.Target == "/" || full == entry.Mount.Target || full.StartsWith(entry.Mount.Target + "/", StringComparison.Ordinal))
            .OrderByDescending(entry => entry.Mount.Target.Length)
            .ThenByDescending(entry => entry.Index)
            .Select(entry => entry.Mount)
            .FirstOrDefault();
    }

    /// <summary>A UDisks2 object name: every character other than a letter or digit becomes "_" and its hex code.</summary>
    public static string UdisksName(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        var result = new StringBuilder(name.Length);
        foreach (var character in name)
        {
            if (char.IsAsciiLetterOrDigit(character)) result.Append(character);
            else foreach (var value in Encoding.UTF8.GetBytes(character.ToString())) result.Append('_').Append(value.ToString("x2", CultureInfo.InvariantCulture));
        }
        return result.ToString();
    }

    private static async Task<DriveReport> LinuxReportAsync(string path, CancellationToken cancellationToken)
    {
        IReadOnlyList<MountEntry> mounts;
        try { mounts = ParseMounts(await File.ReadAllLinesAsync("/proc/self/mounts", cancellationToken)); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { mounts = []; }
        if (MountFor(path, mounts) is not { } mount)
            return new DriveReport("unknown:" + path, "Unknown drive", DriveHealthState.Unknown, Detail: "The drive could not be found.");
        if (NetworkFileSystems.Contains(mount.FileSystem) || mount.Device.StartsWith("//", StringComparison.Ordinal) || mount.Device.Contains(":/", StringComparison.Ordinal))
            return new DriveReport("share:" + mount.Target, "Network share", DriveHealthState.Unknown,
                Detail: "A network share: its drives are checked on the computer that shares it.");
        if (!mount.Device.StartsWith("/dev/", StringComparison.Ordinal))
            return new DriveReport("mount:" + mount.Target, mount.Target == "/" ? "System drive" : Path.GetFileName(mount.Target), DriveHealthState.Unknown,
                Detail: "This drive doesn't report its health here.");

        string device;
        try { device = new FileInfo(mount.Device).ResolveLinkTarget(returnFinalTarget: true)?.FullName ?? mount.Device; }
        catch (IOException) { device = mount.Device; }
        var block = "/org/freedesktop/UDisks2/block_devices/" + UdisksName(Path.GetFileName(device));
        var drive = await PropertyAsync(block, "org.freedesktop.UDisks2.Block", "Drive", cancellationToken);
        if (drive is null)
            return new DriveReport("mount:" + mount.Target, Path.GetFileName(device), DriveHealthState.Unknown,
                Detail: "UDisks is not available here, so the drive's health can't be read (for example in Docker).");
        if (drive is "/" && await PropertyAsync(block, "org.freedesktop.UDisks2.Block", "CryptoBackingDevice", cancellationToken) is { Length: > 1 } backing)
            drive = await PropertyAsync(backing, "org.freedesktop.UDisks2.Block", "Drive", cancellationToken);
        if (drive is null or "/")
            return new DriveReport("mount:" + mount.Target, Path.GetFileName(device), DriveHealthState.Unknown,
                Detail: "This volume spans several drives or a RAID; check their health on the system.");

        var basics = await AllAsync(drive, "org.freedesktop.UDisks2.Drive", cancellationToken) ?? [];
        var name = Text(basics, "Model") is { Length: > 0 } model ? model : Text(basics, "Id") ?? "Drive";
        if (await AllAsync(drive, "org.freedesktop.UDisks2.Drive.Ata", cancellationToken) is { } ata) return AtaReport(drive, name, ata);
        if (await AllAsync(drive, "org.freedesktop.UDisks2.NVMe.Controller", cancellationToken) is { } nvme) return NvmeReport(drive, name, nvme);
        return new DriveReport(drive, name, DriveHealthState.Unknown, Detail: "This drive doesn't report its health over its connection (common for USB cases).");
    }

    /// <summary>The state of a SATA drive from UDisks2's Drive.Ata properties.</summary>
    public static DriveReport AtaReport(string key, string name, IReadOnlyDictionary<string, JsonElement> values)
    {
        ArgumentNullException.ThrowIfNull(values);
        if (Bool(values, "SmartSupported") != true || Bool(values, "SmartEnabled") != true)
            return new DriveReport(key, name, DriveHealthState.Unknown, Detail: "This drive doesn't report its health (SMART is off or not supported).");
        if (Number(values, "SmartUpdated") is not > 0)
            return new DriveReport(key, name, DriveHealthState.Unknown, Detail: "The drive hasn't been measured yet.");
        var temperature = Number(values, "SmartTemperature") is > 0 and var kelvin ? Math.Round(kelvin - 273.15, 1) : (double?)null;
        var hours = Number(values, "SmartPowerOnSeconds") is > 0 and var seconds ? (long)(seconds / 3600) : (long?)null;
        var bad = Number(values, "SmartNumBadSectors") is >= 0 and var sectors ? (long)sectors : (long?)null;
        var failingNow = Number(values, "SmartNumAttributesFailing") is > 0;
        if (Bool(values, "SmartFailing") == true)
            return new DriveReport(key, name, DriveHealthState.Failing, temperature, hours, bad,
                "The drive itself expects to fail soon. Copy what's on it to another drive now.");
        if (bad is > 0 || failingNow)
            return new DriveReport(key, name, DriveHealthState.Warning, temperature, hours, bad,
                bad is > 0 ? $"The drive had to replace or couldn't read {bad} sectors. Keep a backup and watch whether it grows." : "Some of the drive's own health values are below their limit.");
        if (temperature is > HotCelsius)
            return new DriveReport(key, name, DriveHealthState.Warning, temperature, hours, bad, "The drive runs hot. Give it more air.");
        return new DriveReport(key, name, DriveHealthState.Good, temperature, hours, bad, null);
    }

    /// <summary>The state of an NVMe SSD from UDisks2's NVMe.Controller properties.</summary>
    public static DriveReport NvmeReport(string key, string name, IReadOnlyDictionary<string, JsonElement> values)
    {
        ArgumentNullException.ThrowIfNull(values);
        if (Number(values, "SmartUpdated") is not > 0)
            return new DriveReport(key, name, DriveHealthState.Unknown, Detail: "The drive hasn't been measured yet.");
        var temperature = Number(values, "SmartTemperature") is > 0 and var kelvin ? Math.Round(kelvin - 273.15, 1) : (double?)null;
        var hours = Number(values, "SmartPowerOnHours") is > 0 and var value ? (long)value : (long?)null;
        var warnings = values.TryGetValue("SmartCriticalWarning", out var list) && list.ValueKind == JsonValueKind.Array
            ? list.EnumerateArray().Where(item => item.ValueKind == JsonValueKind.String).Select(item => item.GetString()!).ToList()
            : [];
        if (warnings.Any(warning => warning is "reliability" or "readonly" or "spare"))
            return new DriveReport(key, name, DriveHealthState.Failing, temperature, hours, null,
                "The SSD reports that it is wearing out or no longer reliable. Copy what's on it to another drive now.");
        if (warnings.Count > 0)
            return new DriveReport(key, name, DriveHealthState.Warning, temperature, hours, null,
                warnings.Contains("temperature") ? "The SSD runs too hot. Give it more air." : "The SSD reports a warning: " + string.Join(", ", warnings) + ".");
        if (temperature is > 70)
            return new DriveReport(key, name, DriveHealthState.Warning, temperature, hours, null, "The SSD runs hot. Give it more air.");
        return new DriveReport(key, name, DriveHealthState.Good, temperature, hours, null, null);
    }

    /// <summary>Reads busctl's JSON for one property ({"type":"o","data":"/org/…"}) and returns its text.</summary>
    public static string? ParseProperty(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            return document.RootElement.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.String ? data.GetString() : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>Reads busctl's JSON for GetAll ({"type":"a{sv}","data":[{"Name":{"type":"s","data":…}}]}).</summary>
    public static Dictionary<string, JsonElement>? ParseAll(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            if (!document.RootElement.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array || data.GetArrayLength() == 0) return null;
            var values = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
            foreach (var property in data[0].EnumerateObject())
            {
                if (property.Value.ValueKind == JsonValueKind.Object && property.Value.TryGetProperty("data", out var value)) values[property.Name] = value.Clone();
            }
            return values;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static async Task<string?> PropertyAsync(string objectPath, string face, string property, CancellationToken cancellationToken) =>
        await RunAsync("/usr/bin/busctl", ["--system", "--json=short", "get-property", "org.freedesktop.UDisks2", objectPath, face, property], cancellationToken)
            is { } output ? ParseProperty(output) : null;

    private static async Task<Dictionary<string, JsonElement>?> AllAsync(string objectPath, string face, CancellationToken cancellationToken) =>
        await RunAsync("/usr/bin/busctl", ["--system", "--json=short", "call", "org.freedesktop.UDisks2", objectPath,
            "org.freedesktop.DBus.Properties", "GetAll", "s", face], cancellationToken) is { } output ? ParseAll(output) : null;

    // Mac --------------------------------------------------------------------------------------

    private static async Task<DriveReport> MacReportAsync(string path, CancellationToken cancellationToken)
    {
        var volume = DriveInfo.GetDrives()
            .Select(drive => drive.RootDirectory.FullName)
            .Where(root => root == "/" || path == Path.TrimEndingDirectorySeparator(root) || path.StartsWith(Path.TrimEndingDirectorySeparator(root) + "/", StringComparison.Ordinal))
            .OrderByDescending(root => root.Length)
            .FirstOrDefault() ?? "/";
        if (await RunAsync("/usr/sbin/diskutil", ["info", "-plist", volume], cancellationToken) is not { } output || ParsePlist(output) is not { } info)
            return new DriveReport("volume:" + volume, Path.GetFileName(Path.TrimEndingDirectorySeparator(volume)) is { Length: > 0 } label ? label : "Drive",
                DriveHealthState.Unknown, Detail: "A network share or a drive macOS doesn't describe: its health can't be read here.");
        var whole = info.GetValueOrDefault("ParentWholeDisk") ?? info.GetValueOrDefault("DeviceIdentifier") ?? volume;
        var name = info.GetValueOrDefault("VolumeName") ?? "Drive";
        if (await RunAsync("/usr/sbin/diskutil", ["info", "-plist", whole], cancellationToken) is { } disk && ParsePlist(disk) is { } parent
            && parent.GetValueOrDefault("MediaName") is { Length: > 0 } media)
            name = media;
        return MacReport("disk:" + whole, name, info.GetValueOrDefault("SMARTStatus"));
    }

    /// <summary>The state from diskutil's SMARTStatus: "Verified", "Failing" or "Not Supported".</summary>
    public static DriveReport MacReport(string key, string name, string? smart) => smart switch
    {
        "Verified" => new DriveReport(key, name, DriveHealthState.Good),
        "Failing" => new DriveReport(key, name, DriveHealthState.Failing,
            Detail: "The drive itself expects to fail soon. Copy what's on it to another drive now."),
        _ => new DriveReport(key, name, DriveHealthState.Unknown,
            Detail: "This drive doesn't report its health over its connection (common for USB cases)."),
    };

    /// <summary>The text and number values at the top level of a property list, such as diskutil's.</summary>
    public static Dictionary<string, string>? ParsePlist(string xml)
    {
        try
        {
            var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null };
            using var reader = XmlReader.Create(new StringReader(xml), settings);
            var document = XDocument.Load(reader);
            if (document.Root?.Element("dict") is not { } dictionary) return null;
            var values = new Dictionary<string, string>(StringComparer.Ordinal);
            var elements = dictionary.Elements().ToList();
            for (var index = 0; index + 1 < elements.Count; index++)
            {
                if (elements[index].Name != "key") continue;
                var value = elements[index + 1];
                if (value.Name == "string" || value.Name == "integer") values[elements[index].Value] = value.Value;
                else if (value.Name == "true" || value.Name == "false") values[elements[index].Value] = value.Name.LocalName;
            }
            return values;
        }
        catch (XmlException)
        {
            return null;
        }
    }

    // ------------------------------------------------------------------------------------------

    /// <summary>Runs a system tool without a shell and returns its output, or null when it is missing, fails or takes too long.</summary>
    private static async Task<string?> RunAsync(string program, IReadOnlyList<string> arguments, CancellationToken cancellationToken)
    {
        if (!File.Exists(program)) return null;
        var start = new ProcessStartInfo(program)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        start.Environment.Clear();
        start.Environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin";
        start.Environment["LC_ALL"] = "C";
        using var process = Process.Start(start);
        if (process is null) return null;
        process.StandardInput.Close();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(CommandTimeout);
        try
        {
            var output = ReadLimitedAsync(process.StandardOutput, timeout.Token);
            _ = process.StandardError.ReadToEndAsync(timeout.Token);
            await process.WaitForExitAsync(timeout.Token);
            var text = await output;
            return process.ExitCode == 0 ? text : null;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        finally
        {
            if (!process.HasExited)
            {
                try { process.Kill(entireProcessTree: true); }
                catch (InvalidOperationException) { }
            }
        }
    }

    private static async Task<string> ReadLimitedAsync(StreamReader reader, CancellationToken cancellationToken)
    {
        var buffer = new char[8192];
        var text = new StringBuilder();
        int read;
        while ((read = await reader.ReadAsync(buffer, cancellationToken)) > 0)
        {
            if (text.Length + read > MaximumOutput) throw new InvalidDataException("A drive tool answered with too much output.");
            text.Append(buffer, 0, read);
        }
        return text.ToString();
    }

    private static string? Text(Dictionary<string, JsonElement> values, string name) =>
        values.TryGetValue(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()?.Trim() : null;

    private static bool? Bool(IReadOnlyDictionary<string, JsonElement> values, string name) =>
        values.TryGetValue(name, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False ? value.GetBoolean() : null;

    private static double? Number(IReadOnlyDictionary<string, JsonElement> values, string name) =>
        values.TryGetValue(name, out var value) && value.ValueKind == JsonValueKind.Number ? value.GetDouble() : null;

    [LoggerMessage(LogLevel.Debug, "A drive's health could not be read")]
    private static partial void LogProbeFailed(ILogger logger, Exception exception);

    [LoggerMessage(LogLevel.Warning, "Drive {Name} reports {State}")]
    private static partial void LogDriveWarning(ILogger logger, string name, DriveHealthState state);
}
