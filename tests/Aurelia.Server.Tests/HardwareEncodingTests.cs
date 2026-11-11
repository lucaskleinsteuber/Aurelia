using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>
/// Video chips for live conversion: which chip is found, which arguments ffmpeg gets for it and
/// when the processor steps in. Everything here uses canned ffmpeg answers; the real chips are
/// checked by the HardwareEncoding category on a computer that has them.
/// </summary>
public sealed class HardwareEncodingTests
{
    private const string AllEncoders = """
        Encoders:
         V....D libx264              libx264 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (codec h264)
         V....D h264_nvenc           NVIDIA NVENC H.264 encoder (codec h264)
         V..... h264_qsv             H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (Intel Quick Sync Video acceleration) (codec h264)
         V....D h264_vaapi           H.264/AVC (VAAPI) (codec h264)
         A....D aac                  AAC (Advanced Audio Coding)
        """;

    private const string Accelerations = "Hardware acceleration methods:\nvdpau\ncuda\nvaapi\nqsv\n";

    private static readonly ProbedVideo FullHd = new(0, "hevc", "Main", 120, 1920, 1080, "yuv420p", 8);

    [Fact]
    public void TheFirstChipThatPassesItsTrialIsChosenInTheOrderNvidiaIntelVaapi()
    {
        var tried = new List<string>();
        string? Run(IReadOnlyList<string> arguments)
        {
            var encoder = arguments[arguments.ToList().IndexOf("-c:v") + 1];
            var device = arguments.FirstOrDefault(argument => argument.Contains("/dev/dri/", StringComparison.Ordinal)) ?? "-";
            tried.Add($"{encoder} {device}");
            // The Nvidia card is missing its driver; Quick Sync works only on the second node.
            return encoder == "h264_qsv" && device.EndsWith("renderD129", StringComparison.Ordinal) ? string.Empty : null;
        }

        var chip = HardwareEncoding.Detect(Run, AllEncoders, Accelerations, null, ["/dev/dri/renderD128", "/dev/dri/renderD129"]);

        Assert.Equal(new HardwareEncoder(LiveVideoEncoder.Qsv, "/dev/dri/renderD129", Decodes: true), chip);
        Assert.Equal(["h264_nvenc -", "h264_qsv vaapi=va:/dev/dri/renderD128", "h264_qsv vaapi=va:/dev/dri/renderD129"], tried);
    }

    [Fact]
    public void ChipsFfmpegDoesNotListAreNeverTriedAndNoWorkingChipMeansTheProcessor()
    {
        var tried = 0;
        var onlyVaapi = "Encoders:\n V....D libx264  libx264\n V....D h264_vaapi  H.264/AVC (VAAPI)\n";
        Assert.Null(HardwareEncoding.Detect(_ => { tried++; return null; }, onlyVaapi, null, null, ["/dev/dri/renderD128"]));
        Assert.Equal(1, tried);
        // A render node is needed for VAAPI, and without one nothing runs.
        Assert.Null(HardwareEncoding.Detect(_ => throw new InvalidOperationException("must not run"), onlyVaapi, null, null, []));
    }

    [Theory]
    [InlineData("off", null)]
    [InlineData("software", null)]
    [InlineData("something odd", null)]
    [InlineData("vaapi", LiveVideoEncoder.Vaapi)]
    [InlineData("NVENC", LiveVideoEncoder.Nvenc)]
    [InlineData("auto", LiveVideoEncoder.Nvenc)]
    [InlineData(null, LiveVideoEncoder.Nvenc)]
    public void TheOwnersSettingTurnsChipsOffOrPicksOne(string? setting, LiveVideoEncoder? expected)
    {
        var chip = HardwareEncoding.Detect(_ => string.Empty, AllEncoders, Accelerations, setting, ["/dev/dri/renderD128"]);
        Assert.Equal(expected, chip?.Kind);
    }

    [Fact]
    public void DecodingOnTheChipNeedsItsMethodInFfmpegsList()
    {
        var chip = HardwareEncoding.Detect(_ => string.Empty, AllEncoders, "Hardware acceleration methods:\nvdpau\n", "nvenc", []);
        Assert.Equal(new HardwareEncoder(LiveVideoEncoder.Nvenc, null, Decodes: false), chip);
        Assert.True(HardwareEncoding.Lists(Accelerations, "cuda"));
        Assert.False(HardwareEncoding.Lists(Accelerations, "cud"));
        Assert.True(HardwareEncoding.Lists(AllEncoders, "h264_vaapi"));
        Assert.False(HardwareEncoding.Lists(AllEncoders, "hevc_vaapi"));
    }

    [Fact]
    public void OnlyRenderNodesCountAsDevices()
    {
        var directory = Path.Combine(Path.GetTempPath(), "aurelia-dri-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            foreach (var name in new[] { "renderD130", "card0", "renderD128", "renderD200", "renderD12", "by-path" })
                File.WriteAllText(Path.Combine(directory, name), string.Empty);
            Assert.Equal(["renderD128", "renderD130"], HardwareEncoding.RenderDevices(directory).Select(Path.GetFileName));
            Assert.Empty(HardwareEncoding.RenderDevices(Path.Combine(directory, "missing")));
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    [Fact]
    public void TheTrialEncodesAnInventedPictureToNothing()
    {
        var trial = HardwareEncoding.TrialArguments(new HardwareEncoder(LiveVideoEncoder.Vaapi, "/dev/dri/renderD128", false));
        Assert.Equal(["-f", "null", "-"], trial.TakeLast(3));
        Assert.Contains("testsrc2=size=320x180:rate=25", trial);
        Assert.DoesNotContain(trial, argument => argument.StartsWith("file:", StringComparison.Ordinal));
        Assert.Equal(["-vaapi_device", "/dev/dri/renderD128"], trial.SkipWhile(argument => argument != "-vaapi_device").Take(2));
        Assert.Equal("format=yuv420p,format=nv12,hwupload", trial[trial.ToList().IndexOf("-vf") + 1]);
    }

    [Fact]
    public void EachChipGetsItsDeviceDecoderUploadAndRatesAndStillOnlyWritesToStandardOutput()
    {
        var step = StreamingLadder.Find(FullHd, null, "720p")!;
        var audio = new ProbedAudio(1, "ac3", null, 6, "eng", null, true);
        IReadOnlyList<string> For(LiveVideoEncoder kind, HardwareEncoder? chip) => LiveConversionPlanner.Arguments("/proc/1/fd/7",
            new LiveStreamOptions(40, FullHd, kind, audio, false, Hardware: chip, Step: step, SegmentSeconds: 4));

        var nvenc = For(LiveVideoEncoder.Nvenc, new HardwareEncoder(LiveVideoEncoder.Nvenc, null, true));
        Assert.True(nvenc.ToList().IndexOf("-hwaccel") < nvenc.ToList().IndexOf("-i"));
        Assert.Equal(["-hwaccel", "cuda"], nvenc.SkipWhile(argument => argument != "-hwaccel").Take(2));
        Assert.Equal(["-c:v", "h264_nvenc", "-preset", "p4", "-rc", "vbr", "-b:v", "4000k", "-maxrate", "6000k", "-bufsize", "8000k"],
            nvenc.SkipWhile(argument => argument != "-c:v").Take(12));

        var vaapi = For(LiveVideoEncoder.Vaapi, new HardwareEncoder(LiveVideoEncoder.Vaapi, "/dev/dri/renderD128", false));
        Assert.Equal(["-vaapi_device", "/dev/dri/renderD128", "-ss", "40"], vaapi.SkipWhile(argument => argument != "-vaapi_device").Take(4));
        Assert.DoesNotContain("-hwaccel", vaapi);
        var filter = vaapi[vaapi.ToList().IndexOf("-vf") + 1];
        Assert.StartsWith("scale='min(1280,iw)':'min(720,ih)'", filter, StringComparison.Ordinal);
        Assert.EndsWith(",format=yuv420p,format=nv12,hwupload", filter, StringComparison.Ordinal);

        var qsv = For(LiveVideoEncoder.Qsv, new HardwareEncoder(LiveVideoEncoder.Qsv, "/dev/dri/renderD128", true));
        Assert.Equal(["-init_hw_device", "vaapi=va:/dev/dri/renderD128", "-init_hw_device", "qsv=qs@va", "-filter_hw_device", "qs", "-hwaccel", "vaapi"],
            qsv.SkipWhile(argument => argument != "-init_hw_device").Take(8));

        var x264 = For(LiveVideoEncoder.Libx264, null);
        Assert.Equal(["-level:v", "3.1"], x264.SkipWhile(argument => argument != "-level:v").Take(2));
        Assert.Equal(["-sc_threshold", "0"], x264.SkipWhile(argument => argument != "-sc_threshold").Take(2));

        foreach (var arguments in new[] { nvenc, vaapi, qsv, x264 })
        {
            Assert.Equal("pipe:1", arguments[^1]);
            Assert.Equal(["-force_key_frames", "expr:gte(t,n_forced*4)"], arguments.SkipWhile(argument => argument != "-force_key_frames").Take(2));
            Assert.Equal(["-c:a", "aac", "-ac", "2", "-b:a", "160k"], arguments.SkipWhile(argument => argument != "-c:a").Take(6));
            Assert.DoesNotContain("hls", arguments);
            Assert.Single(arguments, argument => argument.StartsWith("file:", StringComparison.Ordinal));
        }
    }

    [Fact]
    public void AChipEncoderWithoutItsChipOrOutsideDevDriIsRefused()
    {
        var options = new LiveStreamOptions(0, FullHd, LiveVideoEncoder.Vaapi, null, false);
        Assert.Throws<InvalidOperationException>(() => LiveConversionPlanner.Arguments("/proc/1/fd/7", options));
        Assert.Throws<InvalidOperationException>(() => LiveConversionPlanner.Arguments("/proc/1/fd/7",
            options with { Hardware = new HardwareEncoder(LiveVideoEncoder.Vaapi, "/tmp/renderD128", false) }));
        Assert.Throws<InvalidOperationException>(() => LiveConversionPlanner.Arguments("/proc/1/fd/7",
            options with { Hardware = new HardwareEncoder(LiveVideoEncoder.Vaapi, "/dev/dri/../../etc/passwd", false) }));
    }

    [Fact]
    public void APlainLiveStreamKeepsItsFormerRates()
    {
        IReadOnlyList<string> For(LiveVideoEncoder kind) => LiveConversionPlanner.Arguments("/x", new LiveStreamOptions(0, FullHd, kind, null, false));
        Assert.Equal(["-maxrate", "8000k", "-bufsize", "16000k", "-profile:v", "high", "-level:v", "4.1"],
            For(LiveVideoEncoder.Libx264).SkipWhile(argument => argument != "-maxrate").Take(8));
        Assert.Equal(["-b:v", "6000k"], For(LiveVideoEncoder.VideoToolbox).SkipWhile(argument => argument != "-b:v").Take(2));
        Assert.Equal(["-g", "48"], For(LiveVideoEncoder.Libx264).SkipWhile(argument => argument != "-g").Take(2));
        Assert.DoesNotContain("-force_key_frames", For(LiveVideoEncoder.Libx264));
    }

    [Fact]
    public void TheProcessorStepsInForAWhileAfterTheChipFailed()
    {
        var chip = new HardwareEncoder(LiveVideoEncoder.Vaapi, "/dev/dri/renderD128", false);
        var both = new FfmpegTools("/f", "/p", LiveVideoEncoder.Vaapi) { Hardware = chip, HasSoftwareEncoder = true };
        var chipOnly = both with { HasSoftwareEncoder = false };
        var software = new FfmpegTools("/f", "/p", LiveVideoEncoder.Libx264) { HasSoftwareEncoder = true };
        var toolbox = new FfmpegTools("/f", "/p", LiveVideoEncoder.VideoToolbox);
        var nothing = new FfmpegTools("/f", "/p", null);

        Assert.Equal((LiveVideoEncoder.Vaapi, chip), LiveConversionService.ChooseEncoder(both, chipResting: false));
        Assert.Equal((LiveVideoEncoder.Libx264, (HardwareEncoder?)null), LiveConversionService.ChooseEncoder(both, chipResting: true));
        Assert.Equal((LiveVideoEncoder.Vaapi, chip), LiveConversionService.ChooseEncoder(chipOnly, chipResting: true));
        Assert.Equal((LiveVideoEncoder.Libx264, (HardwareEncoder?)null), LiveConversionService.ChooseEncoder(software, chipResting: false));
        Assert.Equal((LiveVideoEncoder.VideoToolbox, (HardwareEncoder?)null), LiveConversionService.ChooseEncoder(toolbox, chipResting: false));
        Assert.Null(LiveConversionService.ChooseEncoder(nothing, chipResting: false));

        var clock = new ManualClock();
        var health = new HardwareHealth(clock);
        Assert.False(health.IsResting);
        health.ReportFailure();
        Assert.True(health.IsResting);
        clock.Advance(TimeSpan.FromMinutes(9));
        Assert.True(health.IsResting);
        clock.Advance(TimeSpan.FromMinutes(2));
        Assert.False(health.IsResting);
    }

    [Fact]
    public void AChipConvertsThreeTitlesAtOnceAndTheProcessorOne()
    {
        var chip = new FfmpegTools("/f", "/p", LiveVideoEncoder.Nvenc) { Hardware = new(LiveVideoEncoder.Nvenc, null, true) };
        Assert.Equal(3, LiveConversionService.VideoConversionLimit(chip));
        Assert.Equal(3, LiveConversionService.VideoConversionLimit(new FfmpegTools("/f", "/p", LiveVideoEncoder.VideoToolbox)));
        Assert.Equal(1, LiveConversionService.VideoConversionLimit(new FfmpegTools("/f", "/p", LiveVideoEncoder.Libx264)));
        Assert.Equal(1, LiveConversionService.VideoConversionLimit(null));
        Assert.Equal(5, LiveConversionService.VideoConversionLimit(chip, configured: 5));
    }

    [Fact]
    public void AFullHdTitleGetsFourQualitiesBestFirst()
    {
        var steps = StreamingLadder.For(FullHd);
        Assert.Equal(["1080p", "720p", "480p", "360p"], steps.Select(step => step.Id));
        Assert.Equal([(1920, 1080), (1280, 720), (854, 480), (640, 360)], steps.Select(step => (step.Width, step.Height)));
        Assert.Equal([8000, 4000, 1800, 900], steps.Select(step => step.VideoKilobits));
        Assert.Equal(["avc1.640028", "avc1.64001F", "avc1.64001E", "avc1.64001E"], steps.Select(step => step.VideoCodec));
        Assert.Equal(["4.0", "3.1", "3.0", "3.0"], steps.Select(step => step.LevelName));
        Assert.Equal(12_160_000, steps[0].Bandwidth);
    }

    [Fact]
    public void TheLadderNeverGrowsAPictureAndKeepsItsShape()
    {
        Assert.Equal((1920, 1080), (StreamingLadder.For(FullHd with { Width = 3840, Height = 2160 })[0].Width, StreamingLadder.For(FullHd with { Width = 3840, Height = 2160 })[0].Height));
        Assert.Equal(["720p", "480p", "360p"], StreamingLadder.For(FullHd with { Width = 1280, Height = 720 }).Select(step => step.Id));

        var pal = StreamingLadder.For(FullHd with { Width = 720, Height = 576 });
        Assert.Equal(["576p", "480p", "360p"], pal.Select(step => step.Id));
        Assert.Equal((720, 576, 2000), (pal[0].Width, pal[0].Height, pal[0].VideoKilobits));

        var scope = StreamingLadder.For(FullHd with { Width = 1920, Height = 800 });
        Assert.Equal(["1080p", "720p", "480p", "360p"], scope.Select(step => step.Id));
        Assert.Equal((1280, 534), (scope[1].Width, scope[1].Height));

        var portrait = StreamingLadder.For(FullHd with { Width = 1080, Height = 1920 });
        Assert.Equal((608, 1080), (portrait[0].Width, portrait[0].Height));
        Assert.All(portrait, step => Assert.True(step.Width % 2 == 0 && step.Height % 2 == 0));

        var tiny = StreamingLadder.For(FullHd with { Width = 320, Height = 240 });
        Assert.Equal((320, 240), (Assert.Single(tiny).Width, tiny[0].Height));
        Assert.Empty(StreamingLadder.For(FullHd with { Width = 0 }));
    }

    [Fact]
    public void TheBestQualityStaysAtAboutTheOriginalsBitrate()
    {
        var steps = StreamingLadder.For(FullHd, bitsPerSecond: 3_000_000);
        Assert.Equal([3300, 3300, 1800, 900], steps.Select(step => step.VideoKilobits));
        Assert.Equal(StreamingLadder.MinimumVideoKilobits, StreamingLadder.For(FullHd, bitsPerSecond: 100_000)[0].VideoKilobits);
        Assert.Null(StreamingLadder.Find(FullHd, null, "2160p"));
        Assert.Equal("480p", StreamingLadder.Find(FullHd, null, "480p")!.Id);
    }

    [Fact]
    public void TheOwnerLearnsTheOneStepThatMakesAVideoChipUsable()
    {
        var software = new FfmpegTools("/f", "/p", LiveVideoEncoder.Libx264) { HasSoftwareEncoder = true };
        string? Hint(IReadOnlyList<string> vendors, IReadOnlyList<string> nodes, bool open = true, string? setting = null, FfmpegTools? tools = null) =>
            TranscodingStatus.Hint(tools ?? software, setting, isLinux: true, vendors, nodes, _ => open);
        string[] node = ["/dev/dri/renderD128"];

        Assert.Contains("i965-va-driver", Hint(["0x8086"], node), StringComparison.Ordinal);
        Assert.Contains("mesa-va-drivers", Hint(["0x1002"], node), StringComparison.Ordinal);
        Assert.Contains("Nvidia", Hint(["0x10de"], []), StringComparison.Ordinal);
        Assert.Contains("usermod -aG render,video aurelia", Hint(["0x8086"], node, open: false), StringComparison.Ordinal);
        Assert.Contains("/dev/dri to the container", Hint(["0x8086"], []), StringComparison.Ordinal);
        Assert.Contains("turned off", Hint(["0x8086"], node, setting: "off"), StringComparison.Ordinal);
        Assert.Null(Hint([], []));                                   // no chip: the processor is all there is
        Assert.Null(Hint(["0x8086"], node, tools: software with { Hardware = new(LiveVideoEncoder.Vaapi, node[0], true) }));
        Assert.Null(TranscodingStatus.Hint(new FfmpegTools("/f", "/p", LiveVideoEncoder.VideoToolbox), null, isLinux: false, [], [], _ => true));
        Assert.Contains("sudo apt install ffmpeg", TranscodingStatus.Hint(null, null, isLinux: true, [], [], _ => true), StringComparison.Ordinal);
    }

    [Fact]
    public void GraphicsVendorsComeFromTheCardsLinuxLists()
    {
        var directory = Path.Combine(Path.GetTempPath(), "aurelia-drm-" + Guid.NewGuid().ToString("N"));
        try
        {
            foreach (var (card, vendor) in new[] { ("card0", "0x8086\n"), ("card1", "0x10de"), ("card1-HDMI-A-1", null), ("renderD128", "0x8086") })
            {
                var device = Path.Combine(directory, card, "device");
                Directory.CreateDirectory(device);
                if (vendor is not null) File.WriteAllText(Path.Combine(device, "vendor"), vendor.Replace("\\n", "\n", StringComparison.Ordinal));
            }
            Assert.Equal(["0x10de", "0x8086"], TranscodingStatus.GraphicsVendors(directory).Order(StringComparer.Ordinal));
            Assert.Empty(TranscodingStatus.GraphicsVendors(Path.Combine(directory, "missing")));
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    [Fact]
    public async Task OnlyTheOwnerReadsHowTheServerConverts()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/server/transcoding", owner.Token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        var status = await ApiTestClient.ReadAsync<Aurelia.Contracts.TranscodingStatusResponse>(response);
        Assert.Empty(status.Sessions);
        Assert.Equal(0, status.RunningConversions);
        Assert.InRange(status.VideoLimit, 1, 3);
        using var anonymous = await client.GetAsync("/api/v1/server/transcoding");
        Assert.Equal(System.Net.HttpStatusCode.Unauthorized, anonymous.StatusCode);
    }

    private sealed class ManualClock : TimeProvider
    {
        private DateTimeOffset now = new(2026, 11, 10, 20, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(TimeSpan by) => now += by;
    }
}
