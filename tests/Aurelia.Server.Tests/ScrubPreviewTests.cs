using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace Aurelia.Server.Tests;

[Collection(LiveConversionRuns.Name)]
public sealed class ScrubPreviewTests
{
    [Fact]
    public async Task OffModeExtractsInMemoryAndWritesNothingToDataTempOrMediaFolders()
    {
        if (Installed() is not { } maker) return;
        var ffmpeg = Tools() ?? maker;
        var root = Path.Combine(TestPaths.CreateDataDirectory(), "Scrub Preview Off");
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "Invented Film.mkv");
        try
        {
            await MakeMediaAsync(maker, path);
            var before = (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length);
            using var factory = Factory(ffmpeg);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var mediaId = await AddMediaAsync(factory, root, path);

            using (var capabilities = await client.GetAsync("/api/v1/capabilities"))
            {
                var reported = await ApiTestClient.ReadAsync<ClientCapabilitiesResponse>(capabilities);
                Assert.Contains(ServerFeatures.ScrubPreviews, reported.Capabilities);
            }

            using (var getSettings = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/scrub-previews", owner.Token))
            using (var settingsResponse = await ApiTestClient.SendAsync(client, getSettings))
            {
                settingsResponse.EnsureSuccessStatusCode();
                var settings = await ApiTestClient.ReadAsync<ScrubPreviewSettingsResponse>(settingsResponse);
                Assert.Equal("off", settings.Mode);
                Assert.Equal(15, settings.IntervalSeconds);
                Assert.Equal(500, settings.StorageCapMegabytes);
                Assert.Equal(0, settings.StoredTitleCount);
                Assert.Equal(0, settings.StoredBytes);
                Assert.True(settings.Available);
            }

            var dataFiles = Files(factory.DataDirectory);
            var temporaryFiles = TemporaryVideoFiles();

            // Request a scrub frame at 15s (using profile cookie auth like browser <img> tags do).
            using (var frameRequest = new HttpRequestMessage(HttpMethod.Get, $"/api/v1/media/{mediaId}/scrub-previews/15"))
            {
                frameRequest.Headers.Add("Cookie", $"aurelia_profile={owner.Token}");
                using var frameResponse = await client.SendAsync(frameRequest);
                Assert.Equal(HttpStatusCode.OK, frameResponse.StatusCode);
                Assert.Equal("image/jpeg", frameResponse.Content.Headers.ContentType?.MediaType);
                Assert.Contains("max-age=86400", frameResponse.Headers.CacheControl?.ToString(), StringComparison.Ordinal);
                var etag = frameResponse.Headers.ETag?.Tag;
                Assert.False(string.IsNullOrWhiteSpace(etag));

                var bytes = await frameResponse.Content.ReadAsByteArrayAsync();
                Assert.True(bytes.Length > 100);
                Assert.Equal((byte)0xFF, bytes[0]);
                Assert.Equal((byte)0xD8, bytes[1]);
                Assert.Equal((byte)0xFF, bytes[^2]);
                Assert.Equal((byte)0xD9, bytes[^1]);

                // If-None-Match returns 304 Not Modified without re-extracting.
                using var cachedRequest = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/media/{mediaId}/scrub-previews/15", owner.Token);
                cachedRequest.Headers.IfNoneMatch.Add(new EntityTagHeaderValue(etag!));
                using var cachedResponse = await client.SendAsync(cachedRequest);
                Assert.Equal(HttpStatusCode.NotModified, cachedResponse.StatusCode);
            }

            // In Off mode, zero files may be written to ScrubPreviews, data, temp, or media folders.
            var scrubDir = Path.Combine(factory.DataDirectory, "ScrubPreviews");
            Assert.True(!Directory.Exists(scrubDir) || !Directory.EnumerateFileSystemEntries(scrubDir).Any());
            var newDataFiles = Files(factory.DataDirectory).Except(dataFiles).Where(file => !ServerBookkeeping(factory.DataDirectory, file)).ToList();
            Assert.True(newDataFiles.Count == 0, string.Join(", ", newDataFiles));
            Assert.Empty(TemporaryVideoFiles().Except(temporaryFiles));
            Assert.Equal([path], Directory.GetFiles(root));
            Assert.Equal(before, (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length));
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(root)!, recursive: true);
        }
    }

    [Fact]
    public async Task OnOpenModeStoresOnlyStillImageStripsInDataFolderRespectsCapInvalidatesOnSourceChangeAndDeletesAll()
    {
        if (Installed() is not { } maker) return;
        var ffmpeg = Tools() ?? maker;
        var root = Path.Combine(TestPaths.CreateDataDirectory(), "Scrub Preview Strips");
        Directory.CreateDirectory(root);
        var path1 = Path.Combine(root, "Invented One.mkv");
        var path2 = Path.Combine(root, "Invented Two.mkv");
        try
        {
            await MakeMediaAsync(maker, path1);
            File.Copy(path1, path2);
            var before1 = (File.GetLastWriteTimeUtc(path1), new FileInfo(path1).Length);
            var before2 = (File.GetLastWriteTimeUtc(path2), new FileInfo(path2).Length);

            using var factory = Factory(ffmpeg);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var media1 = await AddMediaAsync(factory, root, path1, "Invented One");
            var media2 = await AddMediaAsync(factory, root, path2, "Invented Two");
            var service = factory.Services.GetRequiredService<ScrubPreviewService>();

            var temporaryFiles = TemporaryVideoFiles();

            // Enable onOpenOrPlay mode with 10s interval.
            using (var updateRequest = ApiTestClient.Authorized(
                HttpMethod.Put,
                "/api/v1/server/scrub-previews",
                owner.Token,
                new UpdateScrubPreviewSettingsRequest("onOpenOrPlay", 10, 50)))
            using (var updateResponse = await ApiTestClient.SendAsync(client, updateRequest))
            {
                updateResponse.EnsureSuccessStatusCode();
                var updated = await ApiTestClient.ReadAsync<ScrubPreviewSettingsResponse>(updateResponse);
                Assert.Equal("onOpenOrPlay", updated.Mode);
                Assert.Equal(10, updated.IntervalSeconds);
                Assert.Equal(50, updated.StorageCapMegabytes);
            }

            // Generate strip for media1 and media2.
            Assert.True(await service.GenerateTitleStripAsync(media1, TimeSpan.Zero, CancellationToken.None));
            Assert.True(await service.GenerateTitleStripAsync(media2, TimeSpan.Zero, CancellationToken.None));

            var scrubDir = Path.Combine(factory.DataDirectory, "ScrubPreviews");
            var stripFiles = Directory.GetFiles(scrubDir, "*.strip", SearchOption.TopDirectoryOnly);
            Assert.Equal(2, stripFiles.Length);

            // Inspect every stored file: only .strip files with AUSTPV01 magic + still JPEG frames, never converted video/MP4/MKV boxes.
            foreach (var stripFile in Directory.EnumerateFiles(scrubDir, "*", SearchOption.AllDirectories))
            {
                Assert.EndsWith(".strip", stripFile, StringComparison.Ordinal);
                var raw = await File.ReadAllBytesAsync(stripFile);
                Assert.Equal("AUSTPV01", Encoding.ASCII.GetString(raw, 0, 8));
                var text = Encoding.Latin1.GetString(raw);
                Assert.DoesNotContain("ftyp", text, StringComparison.Ordinal);
                Assert.DoesNotContain("moov", text, StringComparison.Ordinal);
                Assert.DoesNotContain("moof", text, StringComparison.Ordinal);
            }

            // No video files in temp or media folder, and media files untouched.
            Assert.Empty(TemporaryVideoFiles().Except(temporaryFiles));
            Assert.Equal(
                new[] { path1, path2 }.OrderBy(p => p, StringComparer.Ordinal),
                Directory.GetFiles(root).OrderBy(p => p, StringComparer.Ordinal));
            Assert.Equal(before1, (File.GetLastWriteTimeUtc(path1), new FileInfo(path1).Length));
            Assert.Equal(before2, (File.GetLastWriteTimeUtc(path2), new FileInfo(path2).Length));

            // Manifest and frame endpoint serve from the stored strip.
            using (var manifestReq = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/media/{media1}/scrub-previews", owner.Token))
            using (var manifestRes = await client.SendAsync(manifestReq))
            {
                manifestRes.EnsureSuccessStatusCode();
                var manifest = await ApiTestClient.ReadAsync<ScrubPreviewManifestResponse>(manifestRes);
                Assert.Equal(10, manifest.IntervalSeconds);
                Assert.Contains(0, manifest.ReadySeconds);
                Assert.Contains(10, manifest.ReadySeconds);
            }

            // Pause check: when a stream is active and a title is queued, PausedForPlayback is true.
            var streams = factory.Services.GetRequiredService<ActiveStreamRegistry>();
            service.EnqueuePriority(Guid.NewGuid());
            using (streams.Enter(owner.User.Id, owner.SessionId, 10, 10, CancellationToken.None))
            {
                var busySettings = await service.ReadSettingsAsync();
                Assert.True(busySettings.PausedForPlayback);
            }

            // Invalidation check: when source file mtime changes on disk, requesting the manifest invalidates the old strip.
            File.SetLastWriteTimeUtc(path1, before1.Item1.AddMinutes(5));
            try
            {
                using (var manifestReq = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/media/{media1}/scrub-previews", owner.Token))
                using (var manifestRes = await client.SendAsync(manifestReq))
                {
                    manifestRes.EnsureSuccessStatusCode();
                }

                // Delete All Previews removes all strips and resets count/bytes to 0.
                using (var deleteReq = ApiTestClient.Authorized(HttpMethod.Delete, "/api/v1/server/scrub-previews", owner.Token))
                using (var deleteRes = await ApiTestClient.SendAsync(client, deleteReq))
                {
                    deleteRes.EnsureSuccessStatusCode();
                    var cleared = await ApiTestClient.ReadAsync<ScrubPreviewSettingsResponse>(deleteRes);
                    Assert.Equal(0, cleared.StoredTitleCount);
                    Assert.Equal(0, cleared.StoredBytes);
                }
                Assert.Empty(Directory.GetFiles(scrubDir, "*.strip", SearchOption.TopDirectoryOnly));
            }
            finally
            {
                File.SetLastWriteTimeUtc(path1, before1.Item1);
            }
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(root)!, recursive: true);
        }
    }

    private static string? Tools() =>
        Environment.GetEnvironmentVariable("AURELIA_TEST_FFMPEG") is { Length: > 0 } chosen ? chosen : null;

    private static string? Installed()
    {
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

    private static async Task MakeMediaAsync(string ffmpeg, string path)
    {
        var start = new ProcessStartInfo(ffmpeg) { RedirectStandardError = true, UseShellExecute = false };
        foreach (var argument in new[]
        {
            "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24", "-f", "lavfi",
            "-i", "sine=frequency=440:sample_rate=48000", "-t", "20", "-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high", "-g", "48",
            "-pix_fmt", "yuv420p", "-c:a", "ac3", "-metadata:s:a:0", "language=eng", path,
        }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var errors = await process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        Assert.True(process.ExitCode == 0, errors);
    }

    private static async Task<Guid> AddMediaAsync(AureliaServerFactory factory, string root, string path, string title = "Invented Film")
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = DateTimeOffset.UtcNow;
        var normalizedRoot = MediaPath.Normalize(root);
        var library = database.LibraryRoots.FirstOrDefault(item => item.NormalizedPath == normalizedRoot) ?? new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Invented Library",
            Path = root,
            NormalizedPath = normalizedRoot,
            Kind = LibraryKind.Movies,
            Availability = LibraryAvailability.Available,
            CreatedAt = now,
        };
        var media = new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRoot = library,
            LibraryRootId = library.Id,
            Kind = MediaKind.Movie,
            SourcePath = path,
            NormalizedSourcePath = MediaPath.Normalize(path),
            DetectedTitle = title,
            Category = string.Empty,
            Extension = Path.GetExtension(path),
            FileSize = new FileInfo(path).Length,
            FileModifiedAt = new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero),
            Availability = MediaAvailability.Available,
            CreatedAt = now,
            UpdatedAt = now,
        };
        database.MediaItems.Add(media);
        await database.SaveChangesAsync();
        return media.Id;
    }

    private static HashSet<string> Files(string directory) =>
        Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories).ToHashSet(StringComparer.Ordinal);

    private static bool ServerBookkeeping(string dataDirectory, string file)
    {
        var relative = Path.GetRelativePath(dataDirectory, file);
        return relative.StartsWith("Backups" + Path.DirectorySeparatorChar, StringComparison.Ordinal)
            || relative.StartsWith("DataProtectionKeys" + Path.DirectorySeparatorChar, StringComparison.Ordinal)
            || relative.StartsWith("aurelia.db", StringComparison.Ordinal)
            || relative is "server-events.json" or "server.lock";
    }

    private static HashSet<string> TemporaryVideoFiles() =>
        new[] { Path.GetTempPath(), "/tmp" }.Where(Directory.Exists)
            .SelectMany(directory => Directory.EnumerateFiles(directory))
            .Where(file => System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(file),
                @"ffmpeg|ffprobe|\.(mp4|m4s|m4v|mov|mkv|ts|aac|h264|hevc)$", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
            .ToHashSet(StringComparer.Ordinal);
}
