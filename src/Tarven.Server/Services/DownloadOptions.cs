using Tarven.Contracts;

namespace Tarven.Server.Services;

/// <summary>
/// The qualities a title can be downloaded in besides its original ("converted-downloads-v1"):
/// the adaptive-streaming qualities that come out clearly smaller than the original, each with
/// its expected size and, once this server measured its speed, how long the conversion takes.
/// Pure, so tests check every number.
/// </summary>
public static class DownloadOptions
{
    /// <summary>MP4 boxes and the audio track's own overhead on top of the picture and sound bitrates.</summary>
    public const double ContainerOverhead = 1.02;

    /// <summary>A quality is offered only when it saves at least this share of the original.</summary>
    public const double SmallestSaving = 0.15;

    public static DownloadOptionsResponse For(MediaProbeResult probe, long originalBytes, bool canConvert,
        Func<StreamingStep, double?> speed)
    {
        ArgumentNullException.ThrowIfNull(probe);
        ArgumentNullException.ThrowIfNull(speed);
        var tracks = probe.Audio.Select(track => new LiveAudioTrack(track.Index, track.Codec, track.Channels, track.Language,
            track.Title, track.IsDefault, "aac", LiveConversionPlanner.ConvertedAudioCodec)).ToList();
        var first = tracks.FirstOrDefault(track => track.IsDefault) ?? tracks.FirstOrDefault();
        var qualities = new List<DownloadQuality>();
        if (canConvert && probe.Video is { Width: > 0, Height: > 0 } video && probe.DurationSeconds is > 0 and var duration)
        {
            foreach (var step in StreamingLadder.For(video, probe.BitRate))
            {
                var bytes = (long)Math.Ceiling((step.VideoKilobits + (tracks.Count > 0 ? step.AudioKilobits : 0)) * 1000.0 / 8 * duration * ContainerOverhead);
                if (originalBytes > 0 && bytes > originalBytes * (1 - SmallestSaving)) continue;
                int? seconds = speed(step) is > 0 and var rate ? (int)Math.Ceiling(duration / rate) : null;
                qualities.Add(new DownloadQuality(step.Id, step.Width, step.Height, bytes, seconds));
            }
        }
        return new DownloadOptionsResponse(originalBytes, probe.DurationSeconds, canConvert && qualities.Count > 0, qualities, tracks, first?.Index);
    }
}
