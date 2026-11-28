using System.Diagnostics;
using System.Net;
using Tarven.Contracts;
using Tarven.Server.Services;
using Tarven.Server.Services.Hls;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Tarven.Server.Tests;

/// <summary>
/// Smaller downloads ("converted-downloads-v1"): the qualities and their sizes, a download that
/// gives its place to someone who watches, and a real download of an invented MKV that stops in
/// the middle and goes on in a new session, whose pieces must make one valid file.
/// </summary>
public sealed partial class LiveConversionTests
{
    [Fact]
    public void DownloadsOfferTheSmallerQualitiesWithTheirSizeAndTime()
    {
        var video = new ProbedVideo(0, "hevc", "Main 10", 150, 3840, 2160, "yuv420p10le", 10);
        var probe = new MediaProbeResult("matroska,webm", 7200, video, [new ProbedAudio(1, "truehd", null, 8, "eng", "Atmos", true)],
            BitRate: 60_000_000);
        var options = DownloadOptions.For(probe, 54_000_000_000, canConvert: true, step => step.Id == "720p" ? 6.0 : null);
        Assert.True(options.CanConvert);
        Assert.Equal(["1080p", "720p", "480p", "360p"], options.Qualities.Select(quality => quality.Id));
        // 8000 + 160 kbit/s for two hours, with the boxes on top.
        Assert.Equal((long)Math.Ceiling(8160 * 1000.0 / 8 * 7200 * DownloadOptions.ContainerOverhead), options.Qualities[0].EstimatedBytes);
        Assert.Equal((1200, (int?)null), (options.Qualities[1].EstimatedSeconds!.Value, options.Qualities[0].EstimatedSeconds));
        Assert.Equal((1, "aac", 8), (options.AudioTrack!.Value, options.AudioTracks[0].Mode, options.AudioTracks[0].Channels));

        // A small file gains nothing: no quality would be clearly smaller.
        var small = probe with { Video = video with { Width = 640, Height = 360 }, BitRate = 900_000 };
        Assert.Empty(DownloadOptions.For(small, 810_000_000, canConvert: true, _ => null).Qualities);
        Assert.False(DownloadOptions.For(probe, 54_000_000_000, canConvert: false, _ => null).CanConvert);
    }

    [Fact]
    public async Task ADownloadGivesItsPlaceToSomeoneWhoWatchesAndNeverTheOtherWay()
    {
        using var factory = Factory("off");
        var converter = new InventedConverter { SegmentsPerRun = 40 };
        await using var manager = Manager(factory, converter, new SteppingClock());
        var live = factory.Services.GetRequiredService<LiveConversionService>();
        var profileSession = Guid.NewGuid();
        await using var downloadFile = Session(manager, "720p", out var download, profileSession, download: true);
        await using var watchFile = Session(manager, "480p", out var watching, profileSession);
        download = await manager.AddAsync(download);
        watching = await manager.AddAsync(watching);

        // The download converts and holds the only place for pictures.
        converter.Hold = true;
        var downloading = download.SegmentAsync(0, default);
        await WaitUntilAsync(() => download.IsProducing);
        Assert.True(live.VideoPlacesTaken);

        // Someone starts watching: the download's conversion ends and the player gets the place.
        var playing = watching.SegmentAsync(0, default);
        await WaitUntilAsync(() => watching.IsProducing && !download.IsProducing);
        converter.Hold = false;
        Assert.NotNull(await playing);
        // The download waits for a free place and says so; it never takes the player's.
        await Assert.ThrowsAsync<HlsBusyException>(() => downloading);
        Assert.True(watching.IsProducing);
        Assert.False(manager.PlaybackWaiting);
    }

    [FfmpegFact]
    public async Task ADownloadThatStopsInTheMiddleGoesOnAndItsPiecesMakeOneFile()
    {
        var maker = FfmpegTestTools.RequireInstalled();
        var ffmpeg = Tools() ?? maker;
        var baseDir = TestPaths.CreateDataDirectory();
        var root = Path.Combine(baseDir, "Converted Download");
        var verifyDir = Path.Combine(baseDir, "Verify Output");
        Directory.CreateDirectory(root);
        Directory.CreateDirectory(verifyDir);
        var path = Path.Combine(root, "Invented Film.mkv");
        try
        {
            await MakeMediaAsync(maker, path);
            var before = (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length);
            using var factory = Factory(ffmpeg);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var mediaId = await AddMediaAsync(factory, root, path);
            var live = factory.Services.GetRequiredService<LiveConversionService>();
            var sessions = factory.Services.GetRequiredService<HlsSessionManager>();

            using (var capabilities = await client.GetAsync("/api/v1/capabilities"))
                Assert.Contains(ServerFeatures.ConvertedDownloads, (await ApiTestClient.ReadAsync<ClientCapabilitiesResponse>(capabilities)).Capabilities);
            using (var request = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/media/{mediaId}/download-options", owner.Token))
            using (var response = await client.SendAsync(request))
            {
                response.EnsureSuccessStatusCode();
                var options = await ApiTestClient.ReadAsync<DownloadOptionsResponse>(response);
                Assert.Equal(new FileInfo(path).Length, options.OriginalBytes);
                Assert.InRange(options.DurationSeconds!.Value, 19.5, 20.5);
                Assert.Equal(1, Assert.Single(options.AudioTracks).Index);
            }
            using (var anonymous = await client.GetAsync($"/api/v1/media/{mediaId}/download-options"))
                Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);
            using (var unknown = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/media/{Guid.NewGuid()}/download-options", owner.Token))
            using (var missing = await client.SendAsync(unknown))
                Assert.Equal(HttpStatusCode.NotFound, missing.StatusCode);

            var playback = await CreatePlaybackAsync(client, owner.Token, mediaId);
            var hls = $"{playback.StreamPath}/hls/360p";
            var dataFiles = Files(factory.DataDirectory);
            var temporaryFiles = TemporaryVideoFiles();
            using (var odd = ApiTestClient.Authorized(HttpMethod.Get, $"{hls}/init.mp4?audio=1&purpose=keep", owner.Token))
            using (var refused = await client.SendAsync(odd))
                Assert.Equal(HttpStatusCode.BadRequest, refused.StatusCode);

            var init = await ReadStreamAsync(client, owner.Token, $"{hls}/init.mp4?audio=1&purpose=download");
            List<byte> file = [.. init];
            for (var index = 0; index < 2; index++) file.AddRange(await ReadStreamAsync(client, owner.Token, $"{hls}/{index}.m4s?audio=1&purpose=download"));
            var session = Assert.Single(sessions.Sessions);
            Assert.True(session.Key.Download);

            // The app was away long enough for the session to end; the download goes on where it stopped.
            await sessions.EndAsync(session.Key);
            Assert.Equal(init, await ReadStreamAsync(client, owner.Token, $"{hls}/init.mp4?audio=1&purpose=download"));
            for (var index = 2; index < 5; index++) file.AddRange(await ReadStreamAsync(client, owner.Token, $"{hls}/{index}.m4s?audio=1&purpose=download"));

            // Converted downloads obey the media rule too: no converted video in data, temp or media folders (audit SRV-PLAY-010).
            var newDataFiles = Files(factory.DataDirectory).Except(dataFiles).Where(item => !ServerBookkeeping(factory.DataDirectory, item)).ToList();
            Assert.True(newDataFiles.Count == 0, string.Join(", ", newDataFiles));
            Assert.Empty(TemporaryVideoFiles().Except(temporaryFiles));
            Assert.Equal([path], Directory.GetFiles(root));
            Assert.Empty(Directory.EnumerateFileSystemEntries(Path.Combine(factory.DataDirectory, "Converter")));
            Assert.Equal(before, (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length));

            var kept = Path.Combine(verifyDir, "Downloaded.mp4");
            await File.WriteAllBytesAsync(kept, [.. file]);
            var probe = await RunToolAsync(Path.Combine(Path.GetDirectoryName(maker)!, "ffprobe"),
                "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", kept);
            Assert.InRange(double.Parse(probe.Output, System.Globalization.CultureInfo.InvariantCulture), 19.5, 20.5);
            var decode = await RunToolAsync(maker, "-v", "error", "-i", kept, "-f", "null", "-");
            Assert.True(decode.Errors.Length == 0, decode.Errors);
            await sessions.DisposeAsync();
            await WaitUntilAsync(() => live.Running == 0);
            await WaitUntilAsync(() => FfmpegTestTools.ChildFfmpegProcessCount() == 0);
        }
        finally { Directory.Delete(baseDir, recursive: true); }
    }

    private static async Task<(string Output, string Errors)> RunToolAsync(string program, params string[] arguments)
    {
        var start = new ProcessStartInfo(program) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var output = process.StandardOutput.ReadToEndAsync();
        var errors = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        Assert.True(process.ExitCode == 0, await errors);
        return ((await output).Trim(), (await errors).Trim());
    }
}
