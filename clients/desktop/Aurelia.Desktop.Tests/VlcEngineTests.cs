using Aurelia.Desktop.Core;
using Aurelia.Desktop.Playback;
using Xunit;

namespace Aurelia.Desktop.Tests;

/// <summary>Real VLC with synthetic media: silent (dummy audio), and no window ever opens.</summary>
public sealed class VlcEngineTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "aurelia-desktop-vlc-" + Guid.NewGuid().ToString("N"));

    public VlcEngineTests() => Directory.CreateDirectory(directory);

    public void Dispose() => Directory.Delete(directory, recursive: true);

    [Fact]
    public async Task OpensAtTheResumePositionAndDecodesFramesIntoMemory()
    {
        var video = Path.Combine(directory, "steps.avi");
        SyntheticMedia.WriteAvi(video, [20, 90, 160, 235, 120, 60], secondsPerLevel: 10);
        using var engine = new VlcVideoEngine(nightMode: false, extraOptions: ["--aout=dummy"]);
        var started = DateTimeOffset.UtcNow;
        engine.Open(new Uri(video), startMilliseconds: 32_000);
        long firstClock = 0;
        byte[]? frame = null;
        while (DateTimeOffset.UtcNow - started < TimeSpan.FromSeconds(20))
        {
            if (firstClock == 0 && engine.Time > 0) firstClock = engine.Time;
            if (engine.Time > 33_000 && engine.Frames.Version > 0)
            {
                frame = engine.Frames.Snapshot(out _, out _);
                break;
            }
            await Task.Delay(20, TestContext.Current.CancellationToken);
        }
        TestContext.Current.SendDiagnosticMessage($"first clock {firstClock} ms after {(DateTimeOffset.UtcNow - started).TotalSeconds:0.00} s");
        Assert.InRange(firstClock, 31_000, 35_000);
        Assert.Equal(60_000, engine.Length, tolerance: 1_500);
        Assert.NotNull(frame);
        Assert.Equal(320, engine.Frames.Width);
        // 30–40 s is the fourth gray level.
        Assert.InRange(SyntheticMedia.Brightness(frame), 215, 255);
    }

    /// <summary>
    /// A loud-then-quiet synthetic tone is rendered to a file (nothing is audible); night mode must
    /// bring the two parts much closer, as on the Mac.
    /// </summary>
    [Fact]
    public async Task NightModeNarrowsTheGapBetweenLoudAndQuiet()
    {
        var input = Path.Combine(directory, "tone.wav");
        SyntheticMedia.WriteWav(input, loudSeconds: 2, quietSeconds: 2);
        var plain = await GapAsync(input, nightMode: false);
        var night = await GapAsync(input, nightMode: true);
        TestContext.Current.SendDiagnosticMessage($"plain {plain:0.0} dB, night {night:0.0} dB");
        Assert.True(plain > 28, $"plain {plain} dB");
        Assert.True(night < plain - 10, $"plain {plain} dB, night {night} dB");
    }

    [Fact]
    public async Task TimelinePreviewsArePreparedInTheBackgroundAndShowTheRightPicture()
    {
        var video = Path.Combine(directory, "steps.avi");
        byte[] levels = [20, 90, 160, 235, 120, 60];
        SyntheticMedia.WriteAvi(video, levels, secondsPerLevel: 10);
        using var previews = new Aurelia.Desktop.Playback.ScrubPreviews(new Uri(video), 60_000, parallel: true, TimeSpan.Zero);
        var started = DateTimeOffset.UtcNow;
        previews.Start();
        while (previews.PreparedCount < 6 && DateTimeOffset.UtcNow - started < TimeSpan.FromSeconds(30))
            await Task.Delay(50, TestContext.Current.CancellationToken);
        TestContext.Current.SendDiagnosticMessage($"6 frames in {(DateTimeOffset.UtcNow - started).TotalSeconds:0.0} s");
        Assert.Equal(6, previews.PreparedCount);
        for (var step = 0; step < levels.Length; step++)
        {
            var jpeg = previews.Frame(step * 10_000 + 4_000);
            Assert.NotNull(jpeg);
            using var bitmap = SkiaSharp.SKBitmap.Decode(jpeg);
            var pixel = bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2);
            Assert.InRange(pixel.Green, levels[step] - 20, levels[step] + 20);
        }
    }

    private async Task<double> GapAsync(string input, bool nightMode)
    {
        var output = Path.Combine(directory, $"out-{nightMode}.wav");
        var finished = new TaskCompletionSource();
        using (var engine = new VlcVideoEngine(nightMode,
            extraOptions: ["--aout=afile", $"--audiofile-file={output}", "--audiofile-wav", "--audiofile-format=s16", "--no-video"],
            audioOutput: "afile"))
        {
            engine.Finished += _ => finished.TrySetResult();
            engine.Open(new Uri(input), 0);
            await finished.Task.WaitAsync(TimeSpan.FromSeconds(30), TestContext.Current.CancellationToken);
        }
        var samples = SyntheticMedia.ReadWav(output);
        var frames = samples.Length / 2;
        double Level(int from, int to)
        {
            double sum = 0;
            for (var index = from * 2; index < to * 2; index++) sum += (double)samples[index] * samples[index] / (32768.0 * 32768.0);
            return 10 * Math.Log10(Math.Max(sum / Math.Max(1, (to - from) * 2), 1e-12));
        }
        // Skip the compressor's attack and release around each change.
        return Level(frames / 10, frames * 2 / 5) - Level(frames * 13 / 20, frames * 9 / 10);
    }
}
