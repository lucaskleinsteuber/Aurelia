using System.Diagnostics;
using Aurelia.Server.Services;
using Aurelia.Server.Services.Hls;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>
/// The real video chips of the computer the tests run on, with invented test pictures only. They
/// run when AURELIA_HARDWARE_TESTS=1 is set on Linux (dotnet test --filter Category=HardwareEncoding)
/// and do nothing elsewhere. Each chip ffmpeg lists and the trial accepts converts an invented MKV
/// to 720p HLS segments in memory from a later position.
/// </summary>
public sealed partial class LiveConversionTests
{
    [Fact]
    [Trait("Category", "HardwareEncoding")]
    public async Task EveryUsableVideoChipConvertsSegmentsThatStartOnKeyFramesFasterThanRealTime()
    {
        if (Environment.GetEnvironmentVariable("AURELIA_HARDWARE_TESTS") != "1" || !OperatingSystem.IsLinux()) return;
        var ffmpeg = Installed() ?? throw new InvalidOperationException("The hardware test needs ffmpeg and ffprobe.");
        var root = Path.Combine(TestPaths.CreateDataDirectory(), "Hardware");
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "Invented Film.mkv");
        try
        {
            await MakeMediaAsync(ffmpeg, path);
            var encoders = await RunAsync(ffmpeg, ["-hide_banner", "-encoders"]) ?? "";
            var accelerations = await RunAsync(ffmpeg, ["-hide_banner", "-hwaccels"]);
            var tested = new List<string>();
            foreach (var kind in HardwareEncoding.LinuxOrder)
            {
                var chip = HardwareEncoding.Detect(arguments => RunAsync(ffmpeg, arguments).GetAwaiter().GetResult(), encoders, accelerations,
                    kind.ToString(), HardwareEncoding.RenderDevices());
                if (chip is null) continue;
                var video = new ProbedVideo(0, "h264", "High", 30, 640, 360, "yuv420p", 8);
                var step = new StreamingStep("720p", 640, 360, 1500, 128, "1E");
                var options = new LiveStreamOptions(8, video, kind, null, false, HdrToneMapping.Unavailable, chip, step, HlsPlaylists.SegmentSeconds);
                var watch = Stopwatch.StartNew();
                var output = await RunBytesAsync(ffmpeg, LiveConversionPlanner.Arguments(path, options)) ?? [];
                watch.Stop();
                using var stream = new MemoryStream(output);
                Fmp4Init? init = null;
                byte[]? ftyp = null;
                var starts = new List<double>();
                while (await Fmp4.ReadBoxAsync(stream, default) is { } box)
                {
                    if (box.Type == "ftyp") ftyp = box.Data;
                    else if (box.Type == "moov") init = Fmp4.ParseInit(ftyp ?? [], box.Data);
                    else if (box.Type == "moof" && init is not null && Fmp4.FragmentStart(box.Data, init) is { } start) starts.Add(start);
                }
                Assert.NotNull(init);
                var segments = starts.Select(HlsPlaylists.SegmentFor).Distinct().ToList();
                Assert.Equal([2, 3, 4], segments);
                foreach (var segment in segments)
                    Assert.Contains(starts, start => Math.Abs(start - segment * HlsPlaylists.SegmentSeconds) < 0.1);
                // 12 seconds of title in well under 12 seconds.
                Assert.True(watch.Elapsed < TimeSpan.FromSeconds(12), $"{kind} took {watch.Elapsed}.");
                tested.Add($"{kind} on {chip.Device ?? "the card"} ({watch.Elapsed.TotalSeconds:0.0} s)");
            }
            Assert.True(tested.Count > 0, "No video chip passed its trial.");
            Console.WriteLine("Hardware encoders: " + string.Join(", ", tested));
        }
        finally { Directory.Delete(Path.GetDirectoryName(root)!, recursive: true); }
    }

    private static async Task<string?> RunAsync(string program, IReadOnlyList<string> arguments)
    {
        var bytes = await RunBytesAsync(program, arguments, throwOnFailure: false);
        return bytes is null ? null : System.Text.Encoding.UTF8.GetString(bytes);
    }

    private static async Task<byte[]?> RunBytesAsync(string program, IReadOnlyList<string> arguments, bool throwOnFailure = true)
    {
        var start = new ProcessStartInfo(program) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        using var output = new MemoryStream();
        var errors = process.StandardError.ReadToEndAsync();
        await process.StandardOutput.BaseStream.CopyToAsync(output);
        await process.WaitForExitAsync();
        if (process.ExitCode == 0) return output.ToArray();
        if (throwOnFailure) Assert.Fail(await errors);
        return null;
    }
}
