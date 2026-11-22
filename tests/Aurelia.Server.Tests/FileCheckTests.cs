using System.Diagnostics;
using System.Net;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Aurelia.Server.Services.FileChecks;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>
/// The file watch's rules without ffmpeg, the drive tools' answers from invented examples, and the
/// whole watch through the real server and ffmpeg with an invented movie made here (skipped where
/// no ffmpeg is installed).
/// </summary>
[Collection(LiveConversionRuns.Name)]
public sealed class FileCheckTests
{
    private const double MovieSeconds = 60;

    [Fact]
    public void ProgressLinesSetTheTimeAndOtherLinesAreErrorsAtThatTime()
    {
        var output = new FfmpegCheckOutput("/media/Movies/Invented (2020)/Invented.mkv");
        output.Add("out_time_us=12500000");
        output.Add("progress=continue");
        output.Add("[h264 @ 0x7f8e1c0] error while decoding MB 3 4 in /media/Movies/Invented (2020)/Invented.mkv");
        output.Add("[h264 @ 0x7f8e1c0] error while decoding MB 3 4 in /media/Movies/Invented (2020)/Invented.mkv");
        output.Add("out_time_us=40000000");
        output.Add("[null @ 0x1] Application provided invalid, non monotonically increasing dts to muxer");
        output.Add("[matroska,webm @ 0x2] Read error at pos. 123 /var/lib/aurelia/other/place.mkv");

        Assert.Equal(40, output.Seconds);
        Assert.Equal(3, output.ErrorCount);
        Assert.Equal(12.5, output.FirstErrorSeconds);
        Assert.Equal(40, output.LastErrorSeconds);
        // Repeated lines are kept once; no line keeps a path or an address.
        Assert.Equal(2, output.Lines.Count);
        Assert.All(output.Lines, line =>
        {
            Assert.DoesNotContain("/", line, StringComparison.Ordinal);
            Assert.DoesNotContain("0x", line, StringComparison.Ordinal);
        });
        Assert.Equal("[h264] error while decoding MB 3 4 in the file", output.Lines[0]);
    }

    [Fact]
    public void TheRulesTellGoodFilesNoticesDamageAndCutOffFilesApart()
    {
        var good = new FfmpegCheckOutput();
        good.Add("out_time_us=3599000000");
        Assert.Equal(FileCheckState.Ok, FileCheckRules.Inspect(good, 0, 3600).State);

        var start = new FfmpegCheckOutput();
        start.Add("out_time_us=1000000");
        start.Add("[hevc] Could not find ref with POC 7");
        start.Add("out_time_us=3599000000");
        var notice = FileCheckRules.Inspect(start, 0, 3600);
        Assert.Equal((FileCheckState.Notice, 1), (notice.State, notice.ErrorCount));

        var later = new FfmpegCheckOutput();
        later.Add("out_time_us=1800000000");
        later.Add("[h264] corrupt input packet in stream 0");
        later.Add("out_time_us=3599000000");
        var damaged = FileCheckRules.Inspect(later, 0, 3600);
        Assert.Equal((FileCheckState.Damaged, 1800.0), (damaged.State, damaged.ProblemAtSeconds!.Value));
        Assert.Contains("corrupt input packet", damaged.Detail, StringComparison.Ordinal);

        var cut = new FfmpegCheckOutput();
        cut.Add("out_time_us=2000000000");
        var cutOff = FileCheckRules.Inspect(cut, 0, 3600);
        Assert.Equal(FileCheckState.Damaged, cutOff.State);
        Assert.Contains("ends at 33:20 of 1:00:00", cutOff.Detail, StringComparison.Ordinal);

        var unopened = new FfmpegCheckOutput();
        unopened.Add("Invalid data found when processing input");
        Assert.Equal(FileCheckState.Damaged, FileCheckRules.Inspect(unopened, 1, null).State);

        var unreadable = FileCheckRules.Unreadable(500, 1000, 3600, null);
        Assert.Equal((FileCheckState.Unreadable, 1800.0), (unreadable.State, unreadable.ProblemAtSeconds!.Value));
        Assert.Contains("30:00 (50 %)", unreadable.Detail, StringComparison.Ordinal);
    }

    [Fact]
    public void ffmpegReadsPacketsOrDecodesWithTheChipBeforeTheInput()
    {
        var packets = FileCheckService.Arguments("/proc/1/fd/9", FileCheckDepth.Container, []);
        Assert.Equal(["-hide_banner", "-nostdin", "-nostats", "-v", "error", "-progress", "pipe:2", "-stats_period", "0.5",
            "-i", "/proc/1/fd/9", "-map", "0:v?", "-map", "0:a?", "-map", "0:s?", "-c", "copy", "-f", "null", "-"], packets);
        var decode = FileCheckService.Arguments("input", FileCheckDepth.Decode, ["-hwaccel", "videotoolbox"]);
        Assert.True(decode.ToList().IndexOf("-hwaccel") < decode.ToList().IndexOf("-i"));
        Assert.DoesNotContain("copy", decode);
    }

    [Fact]
    public void MountsAndUdisksNamesLeadFromAFolderToItsDrive()
    {
        var mounts = DriveHealthService.ParseMounts([
            "/dev/nvme0n1p2 / ext4 rw,relatime 0 0",
            "/dev/sdb1 /mnt/Media\\040Drive ext4 rw 0 0",
            "//nas/films /mnt/nas cifs rw 0 0",
            "proc /proc proc rw 0 0",
        ]);
        Assert.Equal("/dev/sdb1", DriveHealthService.MountFor("/mnt/Media Drive/Movies", mounts)!.Device);
        Assert.Equal("/dev/nvme0n1p2", DriveHealthService.MountFor("/mnt/Media Drives", mounts)!.Device);
        Assert.Equal("cifs", DriveHealthService.MountFor("/mnt/nas/Series", mounts)!.FileSystem);
        Assert.Equal("dm_2d0", DriveHealthService.UdisksName("dm-0"));
        Assert.Equal("nvme0n1p2", DriveHealthService.UdisksName("nvme0n1p2"));

        Assert.Equal("/org/freedesktop/UDisks2/drives/WDC_WD40", DriveHealthService.ParseProperty("""{"type":"o","data":"/org/freedesktop/UDisks2/drives/WDC_WD40"}"""));
        Assert.Null(DriveHealthService.ParseProperty("not json"));
    }

    [Fact]
    public void DrivesReportGoodWarningsAndFailuresFromTheirOwnValues()
    {
        static Dictionary<string, JsonElement> Values(string json) => DriveHealthService.ParseAll(json)!;

        var good = DriveHealthService.AtaReport("d", "WD Red", Values("""
            {"type":"a{sv}","data":[{"SmartSupported":{"type":"b","data":true},"SmartEnabled":{"type":"b","data":true},
            "SmartUpdated":{"type":"t","data":1763200000000000},"SmartFailing":{"type":"b","data":false},
            "SmartTemperature":{"type":"d","data":308.15},"SmartPowerOnSeconds":{"type":"t","data":36000000},
            "SmartNumBadSectors":{"type":"x","data":0},"SmartNumAttributesFailing":{"type":"i","data":0}}]}
            """));
        Assert.Equal((DriveHealthState.Good, 35.0, 10000L, 0L), (good.State, good.TemperatureCelsius!.Value, good.PowerOnHours!.Value, good.BadSectors!.Value));

        var sectors = DriveHealthService.AtaReport("d", "Old Drive", Values("""
            {"type":"a{sv}","data":[{"SmartSupported":{"type":"b","data":true},"SmartEnabled":{"type":"b","data":true},
            "SmartUpdated":{"type":"t","data":1},"SmartFailing":{"type":"b","data":false},"SmartNumBadSectors":{"type":"x","data":12}}]}
            """));
        Assert.Equal(DriveHealthState.Warning, sectors.State);
        Assert.Contains("12 sectors", sectors.Detail, StringComparison.Ordinal);

        var failing = DriveHealthService.AtaReport("d", "Dying", Values("""
            {"type":"a{sv}","data":[{"SmartSupported":{"type":"b","data":true},"SmartEnabled":{"type":"b","data":true},
            "SmartUpdated":{"type":"t","data":1},"SmartFailing":{"type":"b","data":true}}]}
            """));
        Assert.Equal(DriveHealthState.Failing, failing.State);

        var usb = DriveHealthService.AtaReport("d", "USB", Values("""{"type":"a{sv}","data":[{"SmartSupported":{"type":"b","data":false}}]}"""));
        Assert.Equal(DriveHealthState.Unknown, usb.State);

        var worn = DriveHealthService.NvmeReport("n", "SSD", Values("""
            {"type":"a{sv}","data":[{"SmartUpdated":{"type":"t","data":1},"SmartCriticalWarning":{"type":"as","data":["spare"]},
            "SmartPowerOnHours":{"type":"t","data":900},"SmartTemperature":{"type":"q","data":318}}]}
            """));
        Assert.Equal((DriveHealthState.Failing, 900L), (worn.State, worn.PowerOnHours!.Value));
        var fine = DriveHealthService.NvmeReport("n", "SSD", Values("""
            {"type":"a{sv}","data":[{"SmartUpdated":{"type":"t","data":1},"SmartCriticalWarning":{"type":"as","data":[]}}]}
            """));
        Assert.Equal(DriveHealthState.Good, fine.State);
    }

    [Fact]
    public void diskutilsPropertyListGivesTheSmartStatus()
    {
        var info = DriveHealthService.ParsePlist("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>ParentWholeDisk</key><string>disk4</string>
            <key>SMARTStatus</key><string>Verified</string>
            <key>Internal</key><false/>
            <key>Size</key><integer>4000787030016</integer>
            <key>APFSPhysicalStores</key><array><dict><key>APFSPhysicalStore</key><string>disk4s2</string></dict></array>
            </dict></plist>
            """)!;
        Assert.Equal(("disk4", "Verified", "false"), (info["ParentWholeDisk"], info["SMARTStatus"], info["Internal"]));
        Assert.Equal(DriveHealthState.Good, DriveHealthService.MacReport("k", "Drive", info["SMARTStatus"]).State);
        Assert.Equal(DriveHealthState.Failing, DriveHealthService.MacReport("k", "Drive", "Failing").State);
        Assert.Equal(DriveHealthState.Unknown, DriveHealthService.MacReport("k", "Drive", "Not Supported").State);
        Assert.Null(DriveHealthService.ParsePlist("<plist"));
    }

    [FfmpegFact]
    public async Task TheWatchFindsCutOffAndSilentlyChangedFilesAndOnlyReadsThem()
    {
        var ffmpeg = FfmpegTestTools.RequireInstalled();
        var parent = TestPaths.CreateDataDirectory();
        var root = Path.Combine(parent, "Invented Movies");
        Directory.CreateDirectory(root);
        try
        {
            var good = Path.Combine(root, "Invented Good (2020).mkv");
            var cut = Path.Combine(root, "Invented Cut (2021).mkv");
            var rot = Path.Combine(root, "Invented Rot (2022).mkv");
            await MakeMovieAsync(ffmpeg, good);
            File.Copy(good, rot);
            File.WriteAllBytes(cut, File.ReadAllBytes(good)[..(int)(new FileInfo(good).Length * 0.4)]);
            var files = new[] { good, cut, rot };
            var before = files.Select(path => (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length)).ToArray();

            using var factory = Factory(ffmpeg);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var ids = await AddMoviesAsync(factory, root, files);
            var checks = factory.Services.GetRequiredService<FileCheckService>();

            using (var capabilities = await client.GetAsync("/api/v1/capabilities"))
            {
                Assert.Contains(ServerFeatures.FileChecks, (await ApiTestClient.ReadAsync<ClientCapabilitiesResponse>(capabilities)).Capabilities);
            }
            var status = await SettingsAsync(client, owner.Token);
            Assert.True(status is { Enabled: false, Depth: FileCheckDepth.Container, RecheckDays: 90, CanInspect: true, TotalCount: 3, CheckedCount: 0 });
            // Off until the owner turns it on: nothing is examined.
            Assert.Equal(0, await checks.ProcessPendingAsync(CancellationToken.None));

            using (var invalid = ApiTestClient.Authorized(HttpMethod.Put, "/api/v1/server/file-checks", owner.Token, new UpdateFileCheckSettingsRequest(true, RecheckDays: 7)))
            using (var rejected = await ApiTestClient.SendAsync(client, invalid))
            {
                Assert.Equal(HttpStatusCode.BadRequest, rejected.StatusCode);
            }
            status = await UpdateAsync(client, owner.Token, new UpdateFileCheckSettingsRequest(true, FileCheckDepth.Container, 30));
            Assert.True(status is { Enabled: true, RecheckDays: 30, PendingCount: 3 });

            var dataFiles = Files(factory.DataDirectory);
            Assert.Equal(3, await checks.ProcessPendingAsync(CancellationToken.None));

            // Only the database and the settings changed; the media are as they were.
            var newDataFiles = Files(factory.DataDirectory).Except(dataFiles).Where(file => !Bookkeeping(factory.DataDirectory, file)).ToList();
            Assert.True(newDataFiles.Count == 0, string.Join(", ", newDataFiles));
            Assert.Equal(files.Order(StringComparer.Ordinal), Directory.GetFiles(root).Order(StringComparer.Ordinal));
            Assert.Equal(before, files.Select(path => (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length)).ToArray());

            var problems = await ProblemsAsync(client, owner.Token);
            var cutProblem = Assert.Single(problems);
            Assert.Equal((ids[1], FileCheckState.Damaged, "Invented Cut (2021).mkv"), (cutProblem.MediaId, cutProblem.State, cutProblem.FileName));
            Assert.InRange(cutProblem.ProblemAtSeconds!.Value, MovieSeconds * 0.2, MovieSeconds * 0.6);
            Assert.DoesNotContain(root, cutProblem.Detail, StringComparison.Ordinal);
            status = await SettingsAsync(client, owner.Token);
            Assert.True(status is { CheckedCount: 3, PendingCount: 0, ProblemCount: 1 });
            Assert.Equal(1, (await HealthAsync(client, owner.Token)).FileProblemCount);
            Assert.Equal(0, await checks.ProcessPendingAsync(CancellationToken.None));

            // One byte changes, size and date stay: when the checksum is due, the change is found.
            var originalTime = File.GetLastWriteTimeUtc(rot);
            await using (var stream = new FileStream(rot, FileMode.Open, FileAccess.ReadWrite))
            {
                stream.Seek(stream.Length / 2, SeekOrigin.Begin);
                var value = stream.ReadByte();
                stream.Seek(-1, SeekOrigin.Current);
                stream.WriteByte((byte)(value ^ 0x5A));
            }
            File.SetLastWriteTimeUtc(rot, originalTime);
            await AgeChecksAsync(factory, TimeSpan.FromDays(31));
            Assert.Equal(3, await checks.ProcessPendingAsync(CancellationToken.None));
            problems = await ProblemsAsync(client, owner.Token);
            Assert.Contains(problems, problem => problem.MediaId == ids[2] && problem.State == FileCheckState.ChangedUnexpectedly);
            // A silently changed file is not read again by itself; the cut-off file still is.
            await AgeChecksAsync(factory, TimeSpan.FromDays(31));
            Assert.DoesNotContain(await checks.PlanAsync(CancellationToken.None), work => work.MediaId == ids[2]);
            await AgeChecksAsync(factory, TimeSpan.Zero);

            // Setting a problem aside takes it out of the count; Examine Again makes the file the new reference.
            using (var ignore = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/library/health/files/{ids[1]}/ignore", owner.Token))
            using (var ignored = await ApiTestClient.SendAsync(client, ignore))
            {
                Assert.Equal(HttpStatusCode.NoContent, ignored.StatusCode);
            }
            Assert.DoesNotContain(await ProblemsAsync(client, owner.Token), problem => problem.MediaId == ids[1]);
            Assert.Contains(await ProblemsAsync(client, owner.Token, ignored: true), problem => problem.MediaId == ids[1]);
            using (var recheck = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/library/health/files/{ids[2]}/recheck", owner.Token))
            using (var queued = await ApiTestClient.SendAsync(client, recheck))
            {
                Assert.Equal(HttpStatusCode.NoContent, queued.StatusCode);
            }
            Assert.Equal(1, await checks.ProcessPendingAsync(CancellationToken.None));
            Assert.DoesNotContain(await ProblemsAsync(client, owner.Token), problem => problem.MediaId == ids[2]);

            // A file with a new date is a new version: it is examined again with a new reference.
            File.SetLastWriteTimeUtc(good, originalTime.AddMinutes(5));
            await using (var scope = factory.Services.CreateAsyncScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var item = await database.MediaItems.IgnoreQueryFilters().SingleAsync(media => media.Id == ids[0]);
                item.FileModifiedAt = new DateTimeOffset(File.GetLastWriteTimeUtc(good), TimeSpan.Zero);
                await database.SaveChangesAsync();
            }
            Assert.Contains(await checks.PlanAsync(CancellationToken.None), work => work.MediaId == ids[0] && !work.VerifyOnly);
            Assert.Equal(1, await checks.ProcessPendingAsync(CancellationToken.None));
            Assert.DoesNotContain(await ProblemsAsync(client, owner.Token), problem => problem.MediaId == ids[0]);

            // Only administrators see problems; only the owner changes the watch.
            using (var anonymous = await client.GetAsync("/api/v1/library/health/files"))
            {
                Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);
            }
            using (var drives = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/library/health/drives", owner.Token))
            using (var answer = await ApiTestClient.SendAsync(client, drives))
            {
                answer.EnsureSuccessStatusCode();
                var response = await ApiTestClient.ReadAsync<DriveHealthResponse>(answer);
                Assert.Contains(response.Drives, drive => drive.Libraries.Contains("Invented Movie Library"));
            }
        }
        finally
        {
            Directory.Delete(parent, recursive: true);
        }
    }

    [FfmpegFact]
    public async Task TheWatchWaitsWhileSomeoneWatches()
    {
        var ffmpeg = FfmpegTestTools.RequireInstalled();
        var parent = TestPaths.CreateDataDirectory();
        var root = Path.Combine(parent, "Invented Movies");
        Directory.CreateDirectory(root);
        try
        {
            var path = Path.Combine(root, "Invented Waiting (2020).mkv");
            await MakeMovieAsync(ffmpeg, path);
            using var factory = Factory(ffmpeg);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            await AddMoviesAsync(factory, root, [path]);
            await UpdateAsync(client, owner.Token, new UpdateFileCheckSettingsRequest(true, FileCheckDepth.Container, 90));
            var checks = factory.Services.GetRequiredService<FileCheckService>();
            var streams = factory.Services.GetRequiredService<ActiveStreamRegistry>();

            var lease = streams.Enter(owner.User.Id, Guid.NewGuid(), 10, 10, CancellationToken.None);
            var work = checks.ProcessPendingAsync(CancellationToken.None);
            await Task.Delay(TimeSpan.FromSeconds(3));
            Assert.False(work.IsCompleted);
            Assert.True((await SettingsAsync(client, owner.Token)).PausedForPlayback);
            lease.Dispose();
            Assert.Equal(1, await work.WaitAsync(TimeSpan.FromMinutes(1)));
        }
        finally
        {
            Directory.Delete(parent, recursive: true);
        }
    }

    private static async Task MakeMovieAsync(string ffmpeg, string path)
    {
        var start = new ProcessStartInfo(ffmpeg) { RedirectStandardError = true, RedirectStandardOutput = true, UseShellExecute = false };
        foreach (var argument in new[]
                 {
                     "-hide_banner", "-v", "error", "-f", "lavfi", "-i", $"testsrc2=size=320x180:rate=25:duration={MovieSeconds}",
                     "-f", "lavfi", "-i", $"sine=frequency=440:duration={MovieSeconds}", "-c:v", "mpeg4", "-q:v", "5", "-g", "25",
                     "-c:a", "aac", "-shortest", path,
                 })
            start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var errors = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        Assert.True(process.ExitCode == 0, await errors);
    }

    private static async Task<Guid[]> AddMoviesAsync(AureliaServerFactory factory, string root, string[] paths)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = DateTimeOffset.UtcNow;
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Invented Movie Library",
            Path = root,
            NormalizedPath = MediaPath.Normalize(root),
            Kind = LibraryKind.Movies,
            Availability = LibraryAvailability.Available,
            CreatedAt = now,
        };
        var movies = paths.Select(path => new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRoot = library,
            LibraryRootId = library.Id,
            Kind = MediaKind.Movie,
            SourcePath = path,
            NormalizedSourcePath = MediaPath.Normalize(path),
            DetectedTitle = Path.GetFileNameWithoutExtension(path),
            Category = string.Empty,
            Extension = Path.GetExtension(path),
            FileSize = new FileInfo(path).Length,
            FileModifiedAt = new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero),
            Availability = MediaAvailability.Available,
            CreatedAt = now,
            UpdatedAt = now,
        }).ToArray();
        database.MediaItems.AddRange(movies);
        await database.SaveChangesAsync();
        return [.. movies.Select(movie => movie.Id)];
    }

    private static async Task AgeChecksAsync(AureliaServerFactory factory, TimeSpan age)
    {
        await using var scope = factory.Services.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        foreach (var check in await database.MediaFileChecks.IgnoreQueryFilters().ToListAsync())
            check.VerifiedAt = DateTimeOffset.UtcNow - age;
        await database.SaveChangesAsync();
    }

    private static async Task<FileCheckSettingsResponse> SettingsAsync(HttpClient client, string token)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/file-checks", token);
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<FileCheckSettingsResponse>(response);
    }

    private static async Task<FileCheckSettingsResponse> UpdateAsync(HttpClient client, string token, UpdateFileCheckSettingsRequest body)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Put, "/api/v1/server/file-checks", token, body);
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<FileCheckSettingsResponse>(response);
    }

    private static async Task<IReadOnlyList<FileProblemSummary>> ProblemsAsync(HttpClient client, string token, bool ignored = false)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/library/health/files?ignored={(ignored ? "true" : "false")}", token);
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<List<FileProblemSummary>>(response);
    }

    private static async Task<ServerHealthResponse> HealthAsync(HttpClient client, string token)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/health", token);
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<ServerHealthResponse>(response);
    }

    private static string? Installed()
    {
        if (Environment.GetEnvironmentVariable("AURELIA_TEST_FFMPEG") is { Length: > 0 } chosen) return chosen;
        var directories = (Environment.GetEnvironmentVariable("PATH") ?? string.Empty).Split(Path.PathSeparator)
            .Concat(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]);
        return directories.Where(directory => directory.Length > 0)
            .Select(directory => Path.Combine(directory, "ffmpeg"))
            .FirstOrDefault(candidate => File.Exists(candidate) && File.Exists(Path.Combine(Path.GetDirectoryName(candidate)!, "ffprobe")));
    }

    private static AureliaServerFactory Factory(string ffmpeg) => new(configureServices: services =>
    {
        services.RemoveAll<LiveConversionService>();
        services.AddSingleton(provider => new LiveConversionService(
            new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["Aurelia:Ffmpeg"] = ffmpeg }).Build(),
            provider.GetRequiredService<ServerRuntimeOptions>(),
            NullLogger<LiveConversionService>.Instance));
    });

    private static HashSet<string> Files(string directory) =>
        Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories).ToHashSet(StringComparer.Ordinal);

    private static bool Bookkeeping(string dataDirectory, string file)
    {
        var relative = Path.GetRelativePath(dataDirectory, file);
        return relative.StartsWith("Backups" + Path.DirectorySeparatorChar, StringComparison.Ordinal)
            || relative.StartsWith("DataProtectionKeys" + Path.DirectorySeparatorChar, StringComparison.Ordinal)
            || relative.StartsWith("aurelia.db", StringComparison.Ordinal)
            || relative is "server-events.json" or "server.lock" or FileCheckService.SettingsFileName or ServerWorkSignal.FileName;
    }
}
