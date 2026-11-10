using System.Globalization;

namespace Aurelia.Server.Services;

/// <summary>One quality of adaptive streaming: an H.264 picture of this size and bitrate with stereo AAC.</summary>
/// <param name="Id">The name in addresses and menus, such as "720p".</param>
/// <param name="Level">The H.264 level as two hex digits for the codec string, such as "1F" for 3.1.</param>
public sealed record StreamingStep(string Id, int Width, int Height, int VideoKilobits, int AudioKilobits, string Level)
{
    /// <summary>The RFC 6381 codec string of the picture, such as "avc1.64001F".</summary>
    public string VideoCodec => "avc1.6400" + Level;

    /// <summary>The peak bits per second for an HLS variant: picture peak (1.5 × target) plus sound.</summary>
    public long Bandwidth => (VideoKilobits * 3L / 2 + AudioKilobits) * 1000;

    /// <summary>The H.264 level in ffmpeg's notation, such as "3.1".</summary>
    public string LevelName => (int.Parse(Level, NumberStyles.HexNumber, CultureInfo.InvariantCulture) / 10.0).ToString("0.0", CultureInfo.InvariantCulture);
}

/// <summary>
/// The qualities a title is offered in for adaptive streaming: 1080p, 720p, 480p and 360p, never
/// larger than the original and the best one never above the original's bitrate. Pure, so tests
/// check every decision.
/// </summary>
public static class StreamingLadder
{
    private sealed record Box(int Width, int Height, int VideoKilobits, int AudioKilobits);

    private static readonly Box[] Boxes =
    [
        new(1920, 1080, 8000, 160),
        new(1280, 720, 4000, 160),
        new(854, 480, 1800, 128),
        new(640, 360, 900, 128),
    ];

    /// <summary>The lowest picture bitrate any quality gets, in kbit/s.</summary>
    public const int MinimumVideoKilobits = 500;

    /// <summary>The qualities for a picture of this size, best first.</summary>
    /// <param name="bitsPerSecond">The original's whole bitrate when the file tells it.</param>
    public static IReadOnlyList<StreamingStep> For(ProbedVideo video, long? bitsPerSecond = null)
    {
        ArgumentNullException.ThrowIfNull(video);
        if (video.Width <= 0 || video.Height <= 0) return [];
        var steps = new List<StreamingStep>();
        foreach (var box in Boxes)
        {
            var (width, height) = LiveConversionPlanner.Fit(video.Width, video.Height, box.Width, box.Height);
            // A smaller original fits several boxes unchanged; it is offered once, at the smallest box's rate.
            if (steps.Count > 0 && steps[^1].Width == width && steps[^1].Height == height) steps.RemoveAt(steps.Count - 1);
            var share = (double)width * height / (box.Width * box.Height);
            var kilobits = Math.Max(MinimumVideoKilobits, (int)Math.Round(box.VideoKilobits * Math.Max(0.5, Math.Min(1.0, share))));
            // A wide film (1920 × 800) is still "1080p"; only an original smaller than the box keeps its own height.
            var label = width == box.Width || height == box.Height ? box.Height : Math.Min(width, height);
            steps.Add(new StreamingStep($"{label}p", width, height, kilobits, box.AudioKilobits, Level(width, height)));
        }
        if (bitsPerSecond is > 0 and var total)
        {
            // Converting cannot add detail: the best quality stays at about the original's bitrate.
            var cap = Math.Max(MinimumVideoKilobits, (int)Math.Min(int.MaxValue, total * 11 / 10_000));
            steps[0] = steps[0] with { VideoKilobits = Math.Min(steps[0].VideoKilobits, cap) };
            for (var index = 1; index < steps.Count; index++)
                steps[index] = steps[index] with { VideoKilobits = Math.Min(steps[index].VideoKilobits, steps[index - 1].VideoKilobits) };
        }
        return steps;
    }

    /// <summary>A quality of the title by its name, or null.</summary>
    public static StreamingStep? Find(ProbedVideo video, long? bitsPerSecond, string id) =>
        For(video, bitsPerSecond).FirstOrDefault(step => string.Equals(step.Id, id, StringComparison.Ordinal));

    /// <summary>The smallest H.264 level that holds the picture at up to 30 frames a second.</summary>
    public static string Level(int width, int height)
    {
        var macroblocks = (long)((width + 15) / 16) * ((height + 15) / 16);
        return macroblocks switch
        {
            <= 1620 => "1E",  // 3.0: 720 × 576
            <= 3600 => "1F",  // 3.1: 1280 × 720
            <= 8192 => "28",  // 4.0: 1920 × 1088
            <= 8704 => "2A",  // 4.2
            _ => "32",        // 5.0
        };
    }
}
