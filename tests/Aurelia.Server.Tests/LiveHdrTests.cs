using System.Diagnostics;
using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Services;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed partial class LiveConversionTests
{
    [Fact]
    public void MapperDiscoveryIsDeferredUntilHdrPictureEncodingAndCachedOnce()
    {
        var discoveries = 0;
        var tools = new FfmpegTools("/invented/ffmpeg", "/invented/ffprobe", LiveVideoEncoder.VideoToolbox, () =>
        {
            discoveries++;
            return HdrToneMapping.PerceptualScale;
        });
        var hdr = Video("hevc", "Main 10", 150, pixelFormat: "yuv420p10le", bitDepth: 10) with { ColorTransfer = "smpte2084" };
        var probe = new MediaProbeResult("matroska", 12, hdr, []);
        var h264Only = new LiveConversionRequest(["h264"], []);
        Assert.NotNull(tools.Encoder);
        Assert.Equal("copy", LiveConversionPlanner.Plan(probe, Browser, true, () => tools.ToneMapping)!.Video);
        Assert.Equal("h264", LiveConversionPlanner.Plan(probe with { Video = hdr with { ColorTransfer = "bt709" } }, h264Only, true, () => tools.ToneMapping)!.Video);
        Assert.Null(LiveConversionPlanner.Plan(probe, h264Only, false, () => tools.ToneMapping));
        Assert.Null(LiveConversionPlanner.Plan(probe with { Video = null }, h264Only, true, () => tools.ToneMapping));
        Assert.Equal(0, discoveries);
        Assert.Equal("h264", LiveConversionPlanner.Plan(probe, h264Only, true, () => tools.ToneMapping)!.Video);
        Assert.Equal("h264", LiveConversionPlanner.Plan(probe, h264Only, true, () => tools.ToneMapping)!.Video);
        Assert.Equal(1, discoveries);
    }

    [Fact]
    public void ConcurrentHdrRequestsShareOneThreadSafeMapperDiscoveryIncludingUnavailableResult()
    {
        var discoveries = 0;
        var tools = new FfmpegTools("/invented/ffmpeg", "/invented/ffprobe", LiveVideoEncoder.Libx264, () =>
        {
            Interlocked.Increment(ref discoveries);
            return HdrToneMapping.Unavailable;
        });
        Parallel.For(0, 32, _ => Assert.Equal(HdrToneMapping.Unavailable, tools.ToneMapping));
        Assert.Equal(1, discoveries);
        Assert.Equal(HdrToneMapping.Unavailable, tools.ToneMapping);
        Assert.Equal(1, discoveries);
    }

    [Theory]
    [InlineData("smpte2084")]
    [InlineData("arib-std-b67")]
    public void ProbeIdentifiesHdrAndPreservesTaggedColorInformation(string transfer)
    {
        var probe = MediaProbe.Parse($$$"""
            {"streams":[{"index":0,"codec_name":"hevc","codec_type":"video","width":3840,"height":2160,
             "pix_fmt":"yuv420p10le","color_transfer":"{{{transfer}}}","color_primaries":"smpte432",
             "color_space":"bt2020nc","color_range":"pc"}],"format":{"duration":"12"}}
            """);
        var video = probe.Video!;
        Assert.True(video.IsHdr);
        Assert.Equal((transfer, "smpte432", "bt2020nc", "pc"),
            (video.ColorTransfer, video.ColorPrimaries, video.ColorSpace, video.ColorRange));
        var filter = LiveHdr.PictureFilter(video, HdrToneMapping.PerceptualScale);
        Assert.Contains(":in_primaries=12:in_color_matrix=9:in_range=2", filter, StringComparison.Ordinal);
        Assert.Contains(":out_transfer=bt709:out_primaries=bt709:out_color_matrix=bt709:out_range=tv:intent=perceptual", filter, StringComparison.Ordinal);
        Assert.Contains("color_transfer", string.Join(' ', MediaProbe.Arguments("/invented.mkv")), StringComparison.Ordinal);
    }

    [Fact]
    public void OnlyHdrPicturesBeingEncodedNeedToneMappingAndMissingTagsUseHdrDefaults()
    {
        var hdr = Video("hevc", "Main 10", 150, pixelFormat: "yuv420p10le", bitDepth: 10) with { ColorTransfer = "smpte2084" };
        var probe = new MediaProbeResult("matroska", 12, hdr, []);
        var copy = LiveConversionPlanner.Plan(probe, Browser, true, HdrToneMapping.Unavailable)!;
        Assert.Equal("copy", copy.Video);
        var copied = LiveConversionPlanner.Arguments("/invented.mkv", new(0, hdr, null, null, false));
        Assert.DoesNotContain("-vf", copied);
        Assert.DoesNotContain("-color_trc", copied);
        var noHevc = new LiveConversionRequest(["h264"], []);
        var unsupported = Assert.Throws<PlaybackException>(() => LiveConversionPlanner.Plan(probe, noHevc, true));
        Assert.Equal(("hdr_conversion_unavailable", 422), (unsupported.Code, unsupported.StatusCode));
        Assert.Equal("h264", LiveConversionPlanner.Plan(probe, noHevc, true, HdrToneMapping.PerceptualScale)!.Video);
        Assert.Equal("h264", LiveConversionPlanner.Plan(probe, noHevc, true, HdrToneMapping.Zscale)!.Video);
        var native = LiveHdr.PictureFilter(hdr, HdrToneMapping.PerceptualScale);
        Assert.Contains(":in_transfer=16:in_primaries=9:in_color_matrix=9:in_range=1", native, StringComparison.Ordinal);
        var sdr = hdr with { ColorTransfer = "bt709" };
        Assert.False(sdr.IsHdr);
        Assert.Equal("h264", LiveConversionPlanner.Plan(probe with { Video = sdr }, noHevc, true)!.Video);
        var sdrFilter = LiveHdr.PictureFilter(sdr, HdrToneMapping.Unavailable);
        Assert.DoesNotContain("transfer", sdrFilter, StringComparison.Ordinal);
        Assert.DoesNotContain("tonemap", sdrFilter, StringComparison.Ordinal);
        Assert.Equal(sdrFilter, LiveHdr.PictureFilter(sdr, HdrToneMapping.PerceptualScale));
        var fallback = LiveHdr.PictureFilter(hdr with { ColorPrimaries = "smpte432" }, HdrToneMapping.Zscale);
        Assert.StartsWith("zscale=w=1920:h=1080:", fallback, StringComparison.Ordinal);
        Assert.Contains("format=yuv420p10le,zscale=transferin=16:primariesin=12", fallback, StringComparison.Ordinal);
        Assert.Contains("matrixin=9:rangein=limited", fallback, StringComparison.Ordinal);
        Assert.Contains("matrixin=9:rangein=full", LiveHdr.PictureFilter(hdr with { ColorRange = "pc" }, HdrToneMapping.Zscale), StringComparison.Ordinal);
        Assert.Contains("transfer=linear:npl=100,format=gbrpf32le", fallback, StringComparison.Ordinal);
        Assert.Contains("tonemap=mobius:desat=0:peak=100,", fallback, StringComparison.Ordinal);
        Assert.Contains("tonemap=mobius:desat=0:peak=10,", LiveHdr.PictureFilter(hdr with { ColorTransfer = "arib-std-b67" }, HdrToneMapping.Zscale), StringComparison.Ordinal);
        Assert.DoesNotContain("scale=out_transfer=linear", fallback, StringComparison.Ordinal);
        var hostile = LiveHdr.PictureFilter(hdr with { ColorPrimaries = "bt2020,malicious-filter" }, HdrToneMapping.PerceptualScale);
        Assert.DoesNotContain("malicious", hostile, StringComparison.Ordinal);
    }

    [Fact]
    public void HdrCapabilitiesRequireAnActualMapperAndPreferNativePerceptualMapping()
    {
        const string native = "out_transfer out_primaries intent perceptual";
        const string fallback = " .SC zscale V->V\n .S. tonemap V->V\n";
        Assert.Equal(HdrToneMapping.PerceptualScale, LiveHdr.Detect(native, fallback));
        Assert.Equal(HdrToneMapping.Zscale, LiveHdr.Detect("scale without color mapping", fallback));
        Assert.Equal(HdrToneMapping.Unavailable, LiveHdr.Detect("out_transfer out_primaries", " .S. tonemap V->V"));
        Assert.Equal(HdrToneMapping.Unavailable, LiveHdr.Detect(null, " .SC zscale V->V"));
        Assert.Equal(HdrToneMapping.Unavailable, LiveHdr.Detect(null, null));
    }

    [Theory]
    [InlineData("smpte2084")]
    [InlineData("arib-std-b67")]
    public async Task HdrLiveConversionProducesTaggedSdrWithoutWritingConvertedFiles(string transfer)
    {
        if (Installed() is not { } maker) return;
        var ffmpeg = Tools() ?? maker;
        var root = Path.Combine(TestPaths.CreateDataDirectory(), "Invented HDR Library");
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "Invented HDR.mkv");
        try
        {
            var input = HdrRamp(320, 180);
            _ = await HdrToolAsync(maker, [
                "-hide_banner", "-loglevel", "error", "-f", "rawvideo", "-pixel_format", "gbrpf32le", "-video_size", "320x180",
                "-framerate", "1", "-color_primaries", "bt2020", "-color_trc", transfer, "-colorspace", "rgb", "-color_range", "pc",
                "-i", "pipe:0", "-frames:v", "1", "-vf", "scale=out_color_matrix=bt2020nc,format=yuv420p10le",
                "-c:v", "libx264", "-preset", "ultrafast", "-profile:v", "high10", "-qp", "1",
                "-color_primaries", "bt2020", "-color_trc", transfer, "-colorspace", "bt2020nc", "-color_range", "tv", path,
            ], input);
            var before = (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length);
            using var factory = Factory(ffmpeg);
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var mediaId = await AddMediaAsync(factory, root, path);
            var live = factory.Services.GetRequiredService<LiveConversionService>();
            var tools = (await live.ToolsAsync())!;
            Assert.NotEqual(HdrToneMapping.Unavailable, tools.ToneMapping);
            var plan = await PlanAsync(client, owner.Token, mediaId, Browser);
            Assert.Equal(("h264", 320, 180), (plan.Video, plan.Width, plan.Height));
            var playback = await CreatePlaybackAsync(client, owner.Token, mediaId);
            var dataFiles = Files(factory.DataDirectory);
            var temporaryFiles = TemporaryVideoFiles();
            var converted = await ReadStreamAsync(client, owner.Token, $"{playback.StreamPath}/live?video=h264");
            var description = await HdrToolAsync(Path.Combine(Path.GetDirectoryName(maker)!, "ffprobe"), [
                "-hide_banner", "-loglevel", "error", "-show_streams", "-show_format", "-of", "json", "pipe:0",
            ], converted);
            var output = MediaProbe.Parse(Encoding.UTF8.GetString(description)).Video!;
            Assert.Equal(("h264", 8, "bt709", "bt709", "bt709", "tv"),
                (output.Codec, output.BitDepth, output.ColorTransfer, output.ColorPrimaries, output.ColorSpace, output.ColorRange));
            Assert.False(output.IsHdr);
            if (tools.ToneMapping == HdrToneMapping.PerceptualScale)
            {
                // Decode only the in-memory HTTP response. No converted video or raw frame is saved.
                var pixels = await HdrToolAsync(maker, [
                    "-hide_banner", "-loglevel", "error", "-i", "pipe:0", "-frames:v", "1", "-pix_fmt", "gray", "-f", "rawvideo", "pipe:1",
                ], converted);
                Assert.Equal(320 * 180, pixels.Length);
                var samples = Enumerable.Range(0, 5).Select(index => pixels[90 * 320 + index * 64 + 32]).ToArray();
                for (var index = 1; index < samples.Length; index++)
                    Assert.True(samples[index] > samples[index - 1] + 5,
                        $"HDR highlight levels clipped: {string.Join(',', samples)}");
                Assert.True(samples[^1] - samples[0] > 50);
            }
            Assert.DoesNotContain(Files(factory.DataDirectory).Except(dataFiles), file => !ServerBookkeeping(factory.DataDirectory, file));
            Assert.Empty(TemporaryVideoFiles().Except(temporaryFiles));
            Assert.Empty(Directory.EnumerateFileSystemEntries(Path.Combine(factory.DataDirectory, "Converter")));
            Assert.Equal([path], Directory.GetFiles(root));
            Assert.Equal(before, (File.GetLastWriteTimeUtc(path), new FileInfo(path).Length));
        }
        finally { Directory.Delete(Path.GetDirectoryName(root)!, recursive: true); }
    }

    private static byte[] HdrRamp(int width, int height)
    {
        var input = new byte[width * height * 3 * sizeof(float)];
        var levels = new[] { 0.58f, 0.65f, 0.75f, 0.85f, 0.95f };
        for (var channel = 0; channel < 3; channel++)
            for (var row = 0; row < height; row++)
                for (var column = 0; column < width; column++)
                    BitConverter.TryWriteBytes(input.AsSpan(((channel * height + row) * width + column) * sizeof(float)), levels[column / (width / 5)]);
        return input;
    }

    private static async Task<byte[]> HdrToolAsync(string tool, IReadOnlyList<string> arguments, byte[]? input = null)
    {
        var start = new ProcessStartInfo(tool)
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var errors = process.StandardError.ReadToEndAsync(timeout.Token);
        try
        {
            var output = LiveConversionService.ReadLimitedAsync(process.StandardOutput.BaseStream, 16 * 1024 * 1024, timeout.Token);
            if (input is not null) await process.StandardInput.BaseStream.WriteAsync(input, timeout.Token);
            process.StandardInput.Close();
            var bytes = await output;
            await process.WaitForExitAsync(timeout.Token);
            Assert.True(process.ExitCode == 0, await errors);
            return bytes;
        }
        finally { LiveConversionService.Stop(process); }
    }
}
