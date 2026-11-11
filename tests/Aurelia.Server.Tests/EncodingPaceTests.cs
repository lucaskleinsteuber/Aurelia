using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>How fast the server converts, with invented speeds; no ffmpeg runs.</summary>
public sealed class EncodingPaceTests
{
    [Theory]
    [InlineData(null, 0.0, "veryfast")]
    [InlineData("veryfast", 3.0, "veryfast")]
    [InlineData("veryfast", 1.1, "superfast")]
    [InlineData("superfast", 0.8, "ultrafast")]
    [InlineData("ultrafast", 0.5, "ultrafast")]
    [InlineData("superfast", 1.6, "superfast")]
    [InlineData("superfast", 2.5, "veryfast")]
    public void TheX264PresetGetsFasterWithoutMarginAndBetterWithPlenty(string? preset, double speed, string expected) =>
        Assert.Equal(expected, EncodingPace.NextPreset(preset is null ? null : new EncodingPace.Measure(preset, speed)));

    [Fact]
    public void AQualityTooSlowEvenAtTheFastestPresetIsLeftOutButTheSmallestStays()
    {
        var pace = new EncodingPace();
        var steps = new[]
        {
            new StreamingStep("1080p", 1920, 1080, 8000, 160, "28"),
            new StreamingStep("720p", 1280, 720, 4000, 160, "1F"),
            new StreamingStep("360p", 640, 360, 900, 128, "1E"),
        };
        Assert.Equal(steps, pace.Offered(LiveVideoEncoder.Libx264, steps));
        // Slow at veryfast: still offered, the next run tries a faster preset.
        pace.Record(LiveVideoEncoder.Libx264, "1080p", "veryfast", 0.7);
        Assert.Equal("superfast", pace.Preset(LiveVideoEncoder.Libx264, "1080p"));
        Assert.Equal(3, pace.Offered(LiveVideoEncoder.Libx264, steps).Count);
        pace.Record(LiveVideoEncoder.Libx264, "1080p", "ultrafast", 0.8);
        Assert.Equal(["720p", "360p"], pace.Offered(LiveVideoEncoder.Libx264, steps).Select(step => step.Id));
        // A chip has no preset: below real time it's out at once, and the smallest always stays.
        pace.Record(LiveVideoEncoder.Vaapi, "1080p", null, 0.9);
        pace.Record(LiveVideoEncoder.Vaapi, "720p", null, 0.9);
        pace.Record(LiveVideoEncoder.Vaapi, "360p", null, 0.9);
        Assert.Null(pace.Preset(LiveVideoEncoder.Vaapi, "1080p"));
        Assert.Equal(["360p"], pace.Offered(LiveVideoEncoder.Vaapi, steps).Select(step => step.Id));
        Assert.Equal(steps, pace.Offered(null, steps));
    }

    [Fact]
    public void SpeedsAtOnePresetAreSmoothedAndANewPresetStartsOver()
    {
        var pace = new EncodingPace();
        pace.Record(LiveVideoEncoder.Libx264, "720p", "veryfast", 2.0);
        pace.Record(LiveVideoEncoder.Libx264, "720p", "veryfast", 1.0);
        Assert.Equal(new EncodingPace.Measure("veryfast", 1.5), pace.Last(LiveVideoEncoder.Libx264, "720p"));
        pace.Record(LiveVideoEncoder.Libx264, "720p", "superfast", 3.0);
        Assert.Equal(new EncodingPace.Measure("superfast", 3.0), pace.Last(LiveVideoEncoder.Libx264, "720p"));
        pace.Record(LiveVideoEncoder.Libx264, "720p", "superfast", double.NaN);
        Assert.Equal(3.0, pace.Last(LiveVideoEncoder.Libx264, "720p")!.Speed);
    }

    [Fact]
    public void X264TakesTheChosenPresetAndNothingElse()
    {
        var arguments = HardwareEncoding.EncoderArguments(LiveVideoEncoder.Libx264, 4000, "ultrafast");
        Assert.Equal("ultrafast", arguments[arguments.ToList().IndexOf("-preset") + 1]);
        var unknown = HardwareEncoding.EncoderArguments(LiveVideoEncoder.Libx264, 4000, "placebo; rm");
        Assert.Equal("veryfast", unknown[unknown.ToList().IndexOf("-preset") + 1]);
        Assert.Equal(HardwareEncoding.EncoderArguments(LiveVideoEncoder.Nvenc, 4000), HardwareEncoding.EncoderArguments(LiveVideoEncoder.Nvenc, 4000, "ultrafast"));
    }

    [Fact]
    public void TheOwnerLearnsWhenTheProcessorFallsBehind()
    {
        var pace = new EncodingPace();
        Assert.Null(TranscodingStatus.PaceHint(LiveVideoEncoder.Libx264, pace));
        pace.Record(LiveVideoEncoder.Libx264, "1080p", "veryfast", 0.9);
        Assert.Contains("1080p", TranscodingStatus.PaceHint(LiveVideoEncoder.Libx264, pace), StringComparison.Ordinal);
        Assert.Null(TranscodingStatus.PaceHint(LiveVideoEncoder.Vaapi, pace));
    }
}
