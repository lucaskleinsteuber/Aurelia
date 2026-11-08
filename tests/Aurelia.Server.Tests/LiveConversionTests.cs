using System.Buffers.Binary;
using System.Diagnostics;
using System.Net;
using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>
/// Live conversion: the decisions without ffmpeg, and with an installed ffmpeg the real stream of
/// an invented MKV. Those tests do nothing when no ffmpeg is installed. They convert real video,
/// so they run on their own instead of beside the rest of the suite.
/// </summary>
[Collection(LiveConversionRuns.Name)]
public sealed partial class LiveConversionTests
{
    private static readonly LiveConversionRequest Browser = new(["h264", "hevc"], ["aac", "mp3"]);

    [Fact]
    public void InputPathKeepsTheSameFileWhenOnlyItsStatusChanges()
    {
        if (OperatingSystem.IsWindows()) return;
        var tempDir = Path.Combine(Path.GetTempPath(), "aurelia-identity-status-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDir);
        try
        {
            var file = Path.Combine(tempDir, "title.mkv");
            var link = Path.Combine(tempDir, "same-inode.mkv");
            var copy = Path.Combine(tempDir, "copy.mkv");
            File.WriteAllBytes(file, [1, 2, 3, 4]);
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            // A permission change moves only the status-change time; the file stays the same.
            Thread.Sleep(20);
            File.SetUnixFileMode(file, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead);
            Assert.NotEmpty(LiveConversionService.InputPath(stream, file));
            // A hard link names the same device and inode; a copy is another file.
            CreateHardLink(file, link);
            Assert.NotEmpty(LiveConversionService.InputPath(stream, link));
            File.Copy(file, copy);
            Assert.Throws<IOException>(() => LiveConversionService.InputPath(stream, copy));
        }
        finally
        {
            Directory.Delete(tempDir, true);
        }
    }

    private static void CreateHardLink(string existing, string created)
    {
        // /bin/ln without a shell: the paths are passed as separate arguments.
        var start = new System.Diagnostics.ProcessStartInfo("/bin/ln") { UseShellExecute = false };
        start.ArgumentList.Add(existing);
        start.ArgumentList.Add(created);
        using var process = System.Diagnostics.Process.Start(start)
            ?? throw new IOException("The hard link could not be created.");
        process.WaitForExit();
        if (process.ExitCode != 0) throw new IOException("The hard link could not be created.");
    }

    [Fact]
    public void InputPathFailsClosedWhenIdentityChangesOrIsSymlinked()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), "aurelia-identity-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDir);
        var originalFile = Path.Combine(tempDir, "original.mkv");
        var replacedFile = Path.Combine(tempDir, "replaced.mkv");
        var symlinkFile = Path.Combine(tempDir, "symlink.mkv");

        try
        {
            File.WriteAllBytes(originalFile, [1, 2, 3, 4]);
            File.WriteAllBytes(replacedFile, [5, 6, 7, 8]);

            using var stream = new FileStream(originalFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);

            // Valid file and path match
            var input = LiveConversionService.InputPath(stream, originalFile);
            Assert.NotEmpty(input);

            // Path replaced with a different file
            Assert.Throws<IOException>(() => LiveConversionService.InputPath(stream, replacedFile));

            // Path replaced with a symlink (on Unix)
            if (!OperatingSystem.IsWindows())
            {
                File.CreateSymbolicLink(symlinkFile, originalFile);
                Assert.Throws<IOException>(() => LiveConversionService.InputPath(stream, symlinkFile));

                // Path deleted/missing
                var missingFile = Path.Combine(tempDir, "missing.mkv");
                Assert.Throws<IOException>(() => LiveConversionService.InputPath(stream, missingFile));
            }
        }
        finally
        {
            Directory.Delete(tempDir, recursive: true);
        }
    }

    [Fact]
    public void H264WithDtsIsRepackagedAndItsSoundConverted()
    {
        var probe = new MediaProbeResult("matroska,webm", 5400.5, Video("h264", "High", 41),
            [new ProbedAudio(1, "dts", "DTS", 6, "eng", "Surround", true), new ProbedAudio(2, "aac", "LC", 2, "deu", null, false)]);
        var plan = LiveConversionPlanner.Plan(probe, Browser, canEncodeVideo: true)!;
        Assert.Equal("copy", plan.Video);
        Assert.Equal("avc1.640029", plan.VideoCodec);
        Assert.Equal(5400.5, plan.DurationSeconds);
        Assert.Equal(1, plan.AudioTrack);
        Assert.Equal(("aac", "mp4a.40.2"), (plan.AudioTracks[0].Mode, plan.AudioTracks[0].Codec));
        Assert.Equal(("copy", "mp4a.40.2"), (plan.AudioTracks[1].Mode, plan.AudioTracks[1].Codec));
        Assert.Equal("deu", plan.AudioTracks[1].Language);
    }

    [Fact]
    public void HevcIsOnlyConvertedForPlayersThatCannotDecodeIt()
    {
        var hevc = new MediaProbeResult("matroska,webm", 60, Video("hevc", "Main 10", 150, width: 3840, height: 2160, pixelFormat: "yuv420p10le", bitDepth: 10), []);
        var firefox = LiveConversionPlanner.Plan(hevc, new LiveConversionRequest(["h264"], ["aac"]), canEncodeVideo: true)!;
        Assert.Equal(("h264", LiveConversionPlanner.ConvertedVideoCodec, 1920, 1080), (firefox.Video, firefox.VideoCodec, firefox.Width, firefox.Height));
        Assert.Null(firefox.AudioTrack);

        var safari = LiveConversionPlanner.Plan(hevc, Browser, canEncodeVideo: true)!;
        Assert.Equal(("copy", "hvc1.2.4.L150.B0", 3840), (safari.Video, safari.VideoCodec, safari.Width));
        // Without an encoder, a picture the player cannot decode cannot play.
        Assert.Null(LiveConversionPlanner.Plan(hevc, new LiveConversionRequest(["h264"], ["aac"]), canEncodeVideo: false));
        // 10-bit H.264 never decodes in a browser, whatever it reports.
        var hi10 = new MediaProbeResult("matroska,webm", 60, Video("h264", "High 10", 41, pixelFormat: "yuv420p10le", bitDepth: 10), []);
        Assert.Equal("h264", LiveConversionPlanner.Plan(hi10, Browser, canEncodeVideo: true)!.Video);
        Assert.Equal("h264", LiveConversionPlanner.Plan(hevc with { Video = Video("mpeg4", null, 0) }, Browser, canEncodeVideo: true)!.Video);
        Assert.Null(LiveConversionPlanner.Plan(hevc with { Video = null }, Browser, canEncodeVideo: true));
    }

    [Fact]
    public void CodecStringsAndSizesMatchWhatBrowsersExpect()
    {
        Assert.Equal("avc1.42E01E", LiveConversionPlanner.VideoCodec(Video("h264", "Constrained Baseline", 30)));
        Assert.Equal("avc1.4D401F", LiveConversionPlanner.VideoCodec(Video("h264", "Main", 31)));
        Assert.Equal("hvc1.1.6.L120.B0", LiveConversionPlanner.VideoCodec(Video("hevc", "Main", 120)));
        Assert.Equal("av01.0.08M.10", LiveConversionPlanner.VideoCodec(Video("av1", "Main", 8, bitDepth: 10)));
        Assert.Equal("vp09.00.40.08", LiveConversionPlanner.VideoCodec(Video("vp9", "Profile 0", -99)));
        Assert.Equal("ac-3", LiveConversionPlanner.AudioCodec(new ProbedAudio(1, "ac3", null, 6, null, null, false)));
        Assert.Equal("ec-3", LiveConversionPlanner.AudioCodec(new ProbedAudio(1, "eac3", null, 6, null, null, false)));
        Assert.Equal("mp4a.40.5", LiveConversionPlanner.AudioCodec(new ProbedAudio(1, "aac", "HE-AAC", 2, null, null, false)));
        Assert.Equal((1920, 1080), LiveConversionPlanner.Fit(3840, 2160));
        Assert.Equal((1920, 800), LiveConversionPlanner.Fit(1920, 800));
        Assert.Equal((1440, 1080), LiveConversionPlanner.Fit(1440, 1080));
        Assert.Equal((1920, 1012), LiveConversionPlanner.Fit(4096, 2160));
    }

    [Fact]
    public void ArgumentsAreAFixedListThatOnlyWritesToStandardOutput()
    {
        var copy = LiveConversionPlanner.Arguments("/Media/A Film; rm -rf.mkv",
            new LiveStreamOptions(600.25, Video("hevc", "Main", 120, index: 0), null, new ProbedAudio(3, "dts", null, 6, null, null, true), false));
        Assert.Equal(["-ss", "600.25"], copy.SkipWhile(argument => argument != "-ss").Take(2));
        Assert.Contains("file:/Media/A Film; rm -rf.mkv", copy);
        Assert.Equal("-protocol_whitelist", copy[4]);
        Assert.Equal(["-map", "0:0", "-map", "0:3"], copy.SkipWhile(argument => argument != "-map").Take(4));
        Assert.Equal(["-c:v", "copy", "-tag:v", "hvc1"], copy.SkipWhile(argument => argument != "-c:v").Take(4));
        Assert.Equal(["-c:a", "aac", "-ac", "2", "-b:a", "192k"], copy.SkipWhile(argument => argument != "-c:a").Take(6));
        Assert.Contains("-copyts", copy);
        Assert.Contains("frag_keyframe+delay_moov+default_base_moof+frag_discont+skip_trailer", copy);
        Assert.Equal("pipe:1", copy[^1]);
        Assert.DoesNotContain("-y", copy);

        var x264 = LiveConversionPlanner.Arguments("/m.avi", new LiveStreamOptions(0, Video("mpeg4", null, 0), LiveVideoEncoder.Libx264, null, false));
        Assert.DoesNotContain("-ss", x264);
        Assert.Contains("frag_keyframe+empty_moov+default_base_moof+skip_trailer", x264);
        Assert.Equal(["-c:v", "libx264", "-preset", "veryfast"], x264.SkipWhile(argument => argument != "-c:v").Take(4));
        Assert.Contains(x264, argument => argument.StartsWith("scale='min(1920,iw)':'min(1080,ih)'", StringComparison.Ordinal));
        Assert.DoesNotContain("-c:a", x264);
        var toolbox = LiveConversionPlanner.Arguments("/m.avi", new LiveStreamOptions(0, Video("mpeg4", null, 0), LiveVideoEncoder.VideoToolbox,
            new ProbedAudio(1, "aac", "LC", 2, null, null, true), true));
        Assert.Equal(["-c:v", "h264_videotoolbox"], toolbox.SkipWhile(argument => argument != "-c:v").Take(2));
        Assert.Equal(["-c:a", "copy"], toolbox.SkipWhile(argument => argument != "-c:a").Take(2));
        Assert.Empty(LiveConversionService.Candidates("off"));
        Assert.Equal(["/opt/ffmpeg/bin/ffmpeg"], LiveConversionService.Candidates("/opt/ffmpeg/bin/ffmpeg"));
    }

    [Fact]
    public void ProbeSkipsCoverPicturesAndUnknownLanguages()
    {
        const string json = """
            {"streams":[
              {"index":0,"codec_name":"mjpeg","codec_type":"video","width":600,"height":900,"disposition":{"attached_pic":1}},
              {"index":1,"codec_name":"h264","profile":"High","codec_type":"video","width":1920,"height":1080,"pix_fmt":"yuv420p","level":40,"bits_per_raw_sample":"8","disposition":{"default":1,"attached_pic":0}},
              {"index":2,"codec_name":"dts","profile":"DTS-HD MA","codec_type":"audio","channels":8,"disposition":{"default":1},"tags":{"language":"eng","title":"Surround 7.1"}},
              {"index":3,"codec_name":"ac3","codec_type":"audio","channels":2,"disposition":{"default":0},"tags":{"LANGUAGE":"und"}},
              {"index":4,"codec_name":"subrip","codec_type":"subtitle"}],
             "format":{"format_name":"matroska,webm","duration":"7261.312000"}}
            """;
        var probe = MediaProbe.Parse(json);
        Assert.Equal(("matroska,webm", 7261.312), (probe.Container, probe.DurationSeconds));
        Assert.Equal(new ProbedVideo(1, "h264", "High", 40, 1920, 1080, "yuv420p", 8), probe.Video);
        Assert.Equal(2, probe.Audio.Count);
        Assert.Equal(new ProbedAudio(2, "dts", "DTS-HD MA", 8, "eng", "Surround 7.1", true), probe.Audio[0]);
        Assert.Null(probe.Audio[1].Language);
        Assert.Equal("file:/proc/1/fd/9", MediaProbe.Arguments("/proc/1/fd/9")[^1]);
    }

    [Theory]
    [InlineData("concat")]
    [InlineData("subfile")]
    [InlineData("lavfi")]
    [InlineData("sdp")]
    [InlineData("tty")]
    [InlineData("concat,wav")]
    public void DisallowedContainersAreRejected(string container)
    {
        var json = $"{{\"format\":{{\"format_name\":\"{container}\"}}}}";
        Assert.Throws<System.Text.Json.JsonException>(() => MediaProbe.Parse(json));
    }

    [Fact]
    public void ProbeListsTextAndBitmapSubtitlesAndKeepsRealMotionJpegVideo()
    {
        var probe = MediaProbe.Parse("""
            {"streams":[
              {"index":0,"codec_name":"mjpeg","codec_type":"video","width":640,"height":360,"pix_fmt":"yuvj420p","disposition":{"attached_pic":0}},
              {"index":1,"codec_name":"subrip","codec_type":"subtitle","disposition":{"default":1},"tags":{"language":"eng","title":"Dialogue"}},
              {"index":2,"codec_name":"ass","codec_type":"subtitle","disposition":{"forced":1},"tags":{"language":"und"}},
              {"index":3,"codec_name":"hdmv_pgs_subtitle","codec_type":"subtitle"},
              {"index":4,"codec_name":"dvd_subtitle","codec_type":"subtitle"}],
             "format":{"format_name":"matroska,webm","duration":"12"}}
            """);
        Assert.Equal("mjpeg", probe.Video?.Codec);
        var plan = LiveConversionPlanner.Plan(probe, Browser, canEncodeVideo: true)!;
        Assert.Equal("h264", plan.Video);
        var tracks = plan.SubtitleTracks!;
        Assert.Equal(4, tracks.Count);
        Assert.Equal(new LiveSubtitleTrack(1, "subrip", "eng", "Dialogue", true, false, true), tracks[0]);
        Assert.True(tracks[1].IsForced);
        Assert.Null(tracks[1].Language);
        Assert.False(tracks[2].Supported);
        Assert.False(tracks[3].Supported);
        foreach (var codec in new[] { "subrip", "ass", "ssa", "mov_text" }) Assert.True(LiveSubtitles.CanConvert(codec));
        Assert.False(LiveSubtitles.CanConvert("unknown"));
        var arguments = LiveSubtitles.Arguments("/Invented/Film;title.mkv", 2);
        Assert.Contains("file:/Invented/Film;title.mkv", arguments);
        Assert.Contains("-copyts", arguments);
        Assert.Contains("-start_at_zero", arguments);
        Assert.Equal(["-map", "0:2"], arguments.SkipWhile(argument => argument != "-map").Take(2));
        Assert.Equal("pipe:1", arguments[^1]);
    }

    [Fact]
    public async Task ConverterOutputHasAByteLimitAndHonorsCancellation()
    {
        await using var exact = new MemoryStream(new byte[16]);
        Assert.Equal(16, (await LiveConversionService.ReadLimitedAsync(exact, 16, CancellationToken.None)).Length);
        await using var tooLarge = new MemoryStream(new byte[17]);
        await Assert.ThrowsAsync<InvalidDataException>(() => LiveConversionService.ReadLimitedAsync(tooLarge, 16, CancellationToken.None));
        await using var cancelled = new MemoryStream(new byte[16]);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => LiveConversionService.ReadLimitedAsync(cancelled, 16, new CancellationToken(true)));
        var oversizedMetadata = "{\"streams\":[{\"index\":1,\"codec_name\":\"subrip\",\"codec_type\":\"subtitle\",\"tags\":{\"title\":\"" + new string('x', 1000) + "\"}}]}";
        Assert.Equal(256, Assert.Single(MediaProbe.Parse(oversizedMetadata).Subtitles!).Title!.Length);
    }

    [Theory]
    [InlineData("srt", ".mkv", "subrip")]
    [InlineData("ass", ".mkv", "ass")]
    [InlineData("mov_text", ".mp4", "mov_text")]
    public async Task EmbeddedSubtitlesUseTitleTimeAndTicketRulesWithoutWritingFiles(string codec, string extension, string expectedCodec)
    {
        if (Installed() is not { } maker) return;
        var ffmpeg = Tools() ?? maker;
        var root = Path.Combine(TestPaths.CreateDataDirectory(), "Invented Subtitle Library");
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "Invented Captions" + extension);
        try
        {
            await MakeSubtitleMediaAsync(maker, path, codec);
            var before = (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length);
            using var factory = Factory(ffmpeg);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var mediaId = await AddMediaAsync(factory, root, path);
            var plan = await PlanAsync(client, owner.Token, mediaId, Browser);
            var track = Assert.Single(plan.SubtitleTracks!);
            Assert.Equal(expectedCodec, track.Format);
            Assert.True(track.Supported);
            Assert.Equal("eng", track.Language);
            var playback = await CreatePlaybackAsync(client, owner.Token, mediaId);
            var live = factory.Services.GetRequiredService<LiveConversionService>();
            var tools = (await live.ToolsAsync())!;
            await using (var source = File.OpenRead(path))
            {
                var file = new OpenMediaFile(source, "video/x-matroska", source.Length, new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero));
                await Assert.ThrowsAnyAsync<OperationCanceledException>(() => live.ExtractSubtitlesAsync(
                    tools, file, path, track.Index, new CancellationToken(true)));
            }
            var dataFiles = Files(factory.DataDirectory);
            var temporaryFiles = TemporaryVideoFiles();
            var address = $"{playback.StreamPath}/subtitles/{track.Index}";
            using (var request = ApiTestClient.Authorized(HttpMethod.Get, address, owner.Token))
            using (var response = await client.SendAsync(request))
            {
                Assert.Equal(HttpStatusCode.OK, response.StatusCode);
                Assert.Equal("text/vtt", response.Content.Headers.ContentType?.MediaType);
                Assert.Contains("no-store", response.Headers.CacheControl?.ToString(), StringComparison.Ordinal);
                var vtt = await response.Content.ReadAsStringAsync();
                Assert.StartsWith("WEBVTT", vtt, StringComparison.Ordinal);
                Assert.Contains("00:02.000 --> 00:04.000", vtt, StringComparison.Ordinal);
                Assert.Contains("00:06.000 --> 00:09.000", vtt, StringComparison.Ordinal);
                Assert.Contains("Second cue", vtt, StringComparison.Ordinal);
                Assert.DoesNotContain("00:11.000", vtt, StringComparison.Ordinal);
            }
            // A native <track> request cannot add the app header: its HttpOnly profile cookie
            // must authenticate exactly like the existing native <video> request.
            using (var nativeTrack = new HttpRequestMessage(HttpMethod.Get, address))
            {
                nativeTrack.Headers.Add("Cookie", $"{WebCookies.Profile}={owner.Token}");
                using var response = await client.SendAsync(nativeTrack);
                Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            }
            // The source starts at timestamp five. Resumed picture time must still be title time,
            // matching the complete WebVTT track rather than adding either source or seek offsets.
            var later = await ReadStreamAsync(client, owner.Token, $"{playback.StreamPath}/live?start=6&video=copy");
            Assert.InRange(FirstFragmentSeconds(later), 5.9, 6.1);
            using (var request = ApiTestClient.Authorized(HttpMethod.Get, $"{playback.StreamPath}/subtitles/999", owner.Token))
            using (var response = await client.SendAsync(request)) Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
            using (var anonymous = await client.GetAsync(address)) Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);
            using var login = await ApiTestClient.LoginAsync(client, new LoginRequest("lucas", "correct horse battery staple", "Another Invented Browser"));
            var otherDevice = await ApiTestClient.ReadAsync<AuthenticationResponse>(login);
            using (var foreign = ApiTestClient.Authorized(HttpMethod.Get, address, otherDevice.Token))
            using (var response = await client.SendAsync(foreign)) Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
            using (var revoke = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/playback/{playback.Id}", owner.Token))
            using (var response = await ApiTestClient.SendAsync(client, revoke)) response.EnsureSuccessStatusCode();
            using (var stale = ApiTestClient.Authorized(HttpMethod.Get, address, owner.Token))
            using (var response = await client.SendAsync(stale)) Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);

            Assert.DoesNotContain(Files(factory.DataDirectory).Except(dataFiles), file => !ServerBookkeeping(factory.DataDirectory, file));
            Assert.Empty(TemporaryVideoFiles().Except(temporaryFiles));
            Assert.Equal([path], Directory.GetFiles(root));
            Assert.Empty(Directory.EnumerateFileSystemEntries(Path.Combine(factory.DataDirectory, "Converter")));
            Assert.Equal(before, (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length));
        }
        finally { Directory.Delete(Path.GetDirectoryName(root)!, recursive: true); }
    }

    [Fact]
    public async Task AnInventedMkvStreamsAsFragmentedMp4FromAnyPositionWithoutWritingFiles()
    {
        if (Installed() is not { } maker) return;
        var ffmpeg = Tools() ?? maker;
        var root = Path.Combine(TestPaths.CreateDataDirectory(), "Live Conversion");
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
                Assert.Contains(ServerFeatures.LiveConversion, (await ApiTestClient.ReadAsync<ClientCapabilitiesResponse>(capabilities)).Capabilities);
            var plan = await PlanAsync(client, owner.Token, mediaId, Browser);
            Assert.Equal(("copy", 640, 360), (plan.Video, plan.Width, plan.Height));
            Assert.StartsWith("avc1.64", plan.VideoCodec, StringComparison.Ordinal);
            Assert.InRange(plan.DurationSeconds!.Value, 19.5, 20.5);
            var track = Assert.Single(plan.AudioTracks);
            Assert.Equal(("ac3", "aac", "eng", track.Index), (track.Format, track.Mode, track.Language, plan.AudioTrack!.Value));

            var playback = await CreatePlaybackAsync(client, owner.Token, mediaId);
            var dataFiles = Files(factory.DataDirectory);
            var temporaryFiles = TemporaryVideoFiles();

            var whole = await ReadStreamAsync(client, owner.Token, $"{playback.StreamPath}/live?audio={track.Index}&audioMode=aac&video=copy");
            Assert.Equal(["ftyp", "moov", "moof", "mdat"], TopLevelBoxes(whole).Select(box => box.Type).Distinct());
            Assert.InRange(FirstFragmentSeconds(whole), 0, 0.5);

            var later = await ReadStreamAsync(client, owner.Token, $"{playback.StreamPath}/live?start=10&audio={track.Index}&video=copy");
            // Repackaging starts at the key frame at or before the position.
            Assert.InRange(FirstFragmentSeconds(later), 7.9, 10.1);
            Assert.True(later.Length < whole.Length);

            var converted = await ReadStreamAsync(client, owner.Token, $"{playback.StreamPath}/live?start=5&video=h264");
            Assert.InRange(FirstFragmentSeconds(converted), 4.5, 5.5);

            // The media rule: nothing converted lands in the data folder, the temporary folder or the media folder.
            var newDataFiles = Files(factory.DataDirectory).Except(dataFiles).Where(file => !ServerBookkeeping(factory.DataDirectory, file)).ToList();
            Assert.True(newDataFiles.Count == 0, string.Join(", ", newDataFiles));
            Assert.Empty(TemporaryVideoFiles().Except(temporaryFiles));
            Assert.Equal([path], Directory.GetFiles(root));
            Assert.Empty(Directory.EnumerateFileSystemEntries(Path.Combine(factory.DataDirectory, "Converter")));
            Assert.Equal(before, (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length));
        }
        finally { Directory.Delete(Path.GetDirectoryName(root)!, recursive: true); }
    }

    [Fact]
    public async Task ClosingTheConnectionEndsFfmpegAndStreamsKeepTheirTicketRules()
    {
        if (Installed() is not { } maker) return;
        var ffmpeg = Tools() ?? maker;
        var root = Path.Combine(TestPaths.CreateDataDirectory(), "Live Conversion Rights");
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "Invented Episode.mkv");
        try
        {
            await MakeMediaAsync(maker, path);
            using var factory = Factory(ffmpeg);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var mediaId = await AddMediaAsync(factory, root, path);
            var live = factory.Services.GetRequiredService<LiveConversionService>();
            var playback = await CreatePlaybackAsync(client, owner.Token, mediaId);
            var address = $"{playback.StreamPath}/live?video=h264";

            using (var request = ApiTestClient.Authorized(HttpMethod.Get, address, owner.Token))
            using (var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead))
            {
                Assert.Equal(HttpStatusCode.OK, response.StatusCode);
                Assert.Equal("video/mp4", response.Content.Headers.ContentType?.MediaType);
                Assert.Contains("no-store", response.Headers.CacheControl?.ToString(), StringComparison.Ordinal);
                await using var stream = await response.Content.ReadAsStreamAsync();
                Assert.True(await stream.ReadAsync(new byte[1024]) > 0);
                // The player stopped reading: ffmpeg waits instead of converting ahead.
                await Task.Delay(1000);
                Assert.Equal(1, live.Running);
            }
            await WaitUntilAsync(() => live.Running == 0);

            using var kidRequest = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
                new CreateUserRequest("kid", "another secure password", UserRole.User, ApiTestClient.TestPin));
            using (var created = await ApiTestClient.SendAsync(client, kidRequest)) created.EnsureSuccessStatusCode();
            using var kidLogin = await ApiTestClient.LoginAsync(client, new LoginRequest("kid", "another secure password", "Kid's Browser"));
            var kid = await ApiTestClient.ReadAsync<AuthenticationResponse>(kidLogin);
            using (var foreign = ApiTestClient.Authorized(HttpMethod.Get, address, kid.Token))
            using (var refused = await client.SendAsync(foreign))
                Assert.Equal(HttpStatusCode.NotFound, refused.StatusCode);
            using (var foreignPlan = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/media/{mediaId}/conversion", kid.Token, Browser))
            using (var hidden = await client.SendAsync(foreignPlan))
                Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
            // A viewing profile with access plans like any player, without server management.
            await ApiTestClient.GrantExistingLibrariesAsync(client, owner.Token, kid.User.Id);
            Assert.Equal("h264", (await PlanAsync(client, kid.Token, mediaId, new LiveConversionRequest([], []))).Video);
            using (var anonymous = await client.GetAsync(address))
                Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);
            using (var invalid = ApiTestClient.Authorized(HttpMethod.Get, $"{playback.StreamPath}/live?start=-4", owner.Token))
            using (var rejected = await client.SendAsync(invalid))
                Assert.Equal(HttpStatusCode.BadRequest, rejected.StatusCode);

            using (var revoke = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/playback/{playback.Id}", owner.Token))
            using (var revoked = await ApiTestClient.SendAsync(client, revoke))
                revoked.EnsureSuccessStatusCode();
            using (var stale = ApiTestClient.Authorized(HttpMethod.Get, address, owner.Token))
            using (var gone = await client.SendAsync(stale))
                Assert.Equal(HttpStatusCode.NotFound, gone.StatusCode);
            Assert.Equal(0, live.Running);
        }
        finally { Directory.Delete(Path.GetDirectoryName(root)!, recursive: true); }
    }

    [Fact]
    public async Task WithoutFfmpegTheServerReportsNoConversion()
    {
        using var factory = Factory("off");
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using (var capabilities = await client.GetAsync("/api/v1/capabilities"))
            Assert.DoesNotContain(ServerFeatures.LiveConversion, (await ApiTestClient.ReadAsync<ClientCapabilitiesResponse>(capabilities)).Capabilities);
        using var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/media/{Guid.NewGuid()}/conversion", owner.Token, Browser);
        using var response = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
        Assert.Equal("conversion_unavailable", (await ApiTestClient.ReadAsync<ApiProblem>(response)).Code);
    }

    private static ProbedVideo Video(string codec, string? profile, int level, int width = 1920, int height = 1080,
        string? pixelFormat = "yuv420p", int bitDepth = 8, int index = 0) =>
        new(index, codec, profile, level, width, height, pixelFormat, bitDepth);

    /// <summary>The server's ffmpeg when AURELIA_TEST_FFMPEG picks one, such as the Mac app's own build.</summary>
    private static string? Tools() =>
        Environment.GetEnvironmentVariable("AURELIA_TEST_FFMPEG") is { Length: > 0 } chosen ? chosen : null;

    /// <summary>
    /// An installed full ffmpeg with ffprobe beside it, which also invents the test media, or null
    /// to leave the stream tests out.
    /// </summary>
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

    /// <summary>20 invented seconds: a test picture with a key frame every two seconds and an AC-3 tone.</summary>
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

    private static async Task MakeSubtitleMediaAsync(string ffmpeg, string path, string codec)
    {
        var captions = Path.Combine(Path.GetDirectoryName(Path.GetDirectoryName(path))!, "Invented captions.srt");
        await File.WriteAllTextAsync(captions, "1\n00:00:02,000 --> 00:00:04,000\nFirst cue\n\n2\n00:00:06,000 --> 00:00:09,000\nSecond cue\n");
        var start = new ProcessStartInfo(ffmpeg) { RedirectStandardError = true, UseShellExecute = false };
        foreach (var argument in new[]
        {
            "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=10", "-i", captions,
            "-t", "12", "-map", "0:v", "-map", "1:s", "-c:v", "libx264", "-preset", "ultrafast", "-g", "20",
            "-c:s", codec, "-metadata:s:s:0", "language=eng", "-output_ts_offset", "5", path,
        }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var errors = await process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        Assert.True(process.ExitCode == 0, errors);
    }

    private static async Task<Guid> AddMediaAsync(AureliaServerFactory factory, string root, string path)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = DateTimeOffset.UtcNow;
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Invented Library",
            Path = root,
            NormalizedPath = MediaPath.Normalize(root),
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
            DetectedTitle = "Invented Film",
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

    private static async Task<LiveConversionPlanResponse> PlanAsync(HttpClient client, string token, Guid mediaId, LiveConversionRequest request)
    {
        using var message = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/media/{mediaId}/conversion", token, request);
        using var response = await client.SendAsync(message);
        Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());
        return await ApiTestClient.ReadAsync<LiveConversionPlanResponse>(response);
    }

    private static async Task<PlaybackSourceResponse> CreatePlaybackAsync(HttpClient client, string token, Guid mediaId)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/media/{mediaId}/playback", token);
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<PlaybackSourceResponse>(response);
    }

    private static async Task<byte[]> ReadStreamAsync(HttpClient client, string token, string address)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, address, token);
        using var response = await client.SendAsync(request);
        Assert.True(response.StatusCode == HttpStatusCode.OK, await response.Content.ReadAsStringAsync());
        return await response.Content.ReadAsByteArrayAsync();
    }

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        var watch = Stopwatch.StartNew();
        while (!condition())
        {
            Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10), "The conversion did not end after the connection closed.");
            await Task.Delay(50);
        }
    }

    private static HashSet<string> Files(string directory) =>
        Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories).ToHashSet(StringComparer.Ordinal);

    /// <summary>
    /// Files the server keeps for itself and may start at any time, such as its daily database
    /// backup or its event log. Anything else new in the data folder fails the media rule.
    /// </summary>
    private static bool ServerBookkeeping(string dataDirectory, string file)
    {
        var relative = Path.GetRelativePath(dataDirectory, file);
        return relative.StartsWith("Backups" + Path.DirectorySeparatorChar, StringComparison.Ordinal)
            || relative.StartsWith("DataProtectionKeys" + Path.DirectorySeparatorChar, StringComparison.Ordinal)
            || relative.StartsWith("aurelia.db", StringComparison.Ordinal)
            || relative is "server-events.json" or "server.lock";
    }

    /// <summary>
    /// Video-like files in the system's temporary folders. Other programs on the computer (a
    /// compiler, say) write there too, so only what ffmpeg could have written counts.
    /// </summary>
    private static HashSet<string> TemporaryVideoFiles() =>
        new[] { Path.GetTempPath(), "/tmp" }.Where(Directory.Exists)
            .SelectMany(directory => Directory.EnumerateFiles(directory))
            .Where(file => System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(file),
                @"ffmpeg|ffprobe|\.(mp4|m4s|m4v|mov|mkv|ts|aac|h264|hevc)$", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
            .ToHashSet(StringComparer.Ordinal);

    private sealed record Box(string Type, int Start, int End)
    {
        public int Body => Start + 8;
    }

    private static List<Box> TopLevelBoxes(byte[] data) => Boxes(data, 0, data.Length);

    private static List<Box> Boxes(byte[] data, int start, int end)
    {
        var boxes = new List<Box>();
        for (var offset = start; offset + 8 <= end;)
        {
            var size = (int)BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(offset));
            if (size < 8 || offset + size > end) break;
            boxes.Add(new Box(Encoding.ASCII.GetString(data, offset + 4, 4), offset, offset + size));
            offset += size;
        }
        return boxes;
    }

    private static Box Child(byte[] data, Box parent, string type) =>
        Boxes(data, parent.Body, parent.End).First(box => box.Type == type);

    /// <summary>Where the first fragment starts in the title, from its tfdt and the picture track's timescale.</summary>
    private static double FirstFragmentSeconds(byte[] data)
    {
        var boxes = TopLevelBoxes(data);
        var header = Child(data, Child(data, Child(data, boxes.First(box => box.Type == "moov"), "trak"), "mdia"), "mdhd");
        var timescale = data[header.Body] == 1
            ? BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(header.Body + 20))
            : BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(header.Body + 12));
        var decode = Child(data, Child(data, boxes.First(box => box.Type == "moof"), "traf"), "tfdt");
        var time = data[decode.Body] == 1
            ? BinaryPrimitives.ReadUInt64BigEndian(data.AsSpan(decode.Body + 4))
            : BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(decode.Body + 4));
        return (double)time / timescale;
    }
}

[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class LiveConversionRuns
{
    public const string Name = "Live conversion";
}
