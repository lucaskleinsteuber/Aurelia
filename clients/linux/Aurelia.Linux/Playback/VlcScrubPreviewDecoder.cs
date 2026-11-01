using System.Globalization;
using Aurelia.Linux.Core.Playback;
using LibVLCSharp.Shared;

namespace Aurelia.Linux.Playback;

/// <summary>A silent VLC player that returns one small still through frame callbacks, with no snapshot or video files.</summary>
internal sealed class VlcScrubPreviewDecoder(LibVLC library) : IScrubPreviewDecoder
{
    private readonly CancellationTokenSource lifetime = new();

    public async Task<ScrubPreviewFrame?> CaptureAsync(Uri loopbackSource, long milliseconds, CancellationToken cancellation)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation, lifetime.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(8));
        using var frames = new VideoFrames(maximumWidth: 320);
        using var player = new MediaPlayer(library) { Mute = true };
        using var media = new Media(library, loopbackSource);
        var completed = new TaskCompletionSource<ScrubPreviewFrame?>(TaskCreationOptions.RunContinuationsAsynchronously);
        frames.Attach(player);
        frames.FrameReady += () =>
        {
            // VLC invokes this on its video thread. Capture only bounded pixels; the view creates its bitmap later.
            if (player.Time + 5_000 >= milliseconds && frames.Snapshot() is { } frame) completed.TrySetResult(frame);
        };
        player.EncounteredError += (_, _) => completed.TrySetResult(null);
        media.AddOption(":no-audio");
        media.AddOption(":no-spu");
        media.AddOption(":avcodec-hw=none");
        media.AddOption(":network-caching=100");
        media.AddOption(":start-time=" + (Math.Max(0, milliseconds) / 1000.0).ToString("0.000", CultureInfo.InvariantCulture));
        try
        {
            await Task.Run(() => player.Play(media), timeout.Token);
            return await completed.Task.WaitAsync(timeout.Token);
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        finally
        {
            await Task.Run(player.Stop, CancellationToken.None);
        }
    }

    public void Dispose()
    {
        lifetime.Cancel();
        lifetime.Dispose();
    }
}
