using System.Collections.Concurrent;
using Aurelia.Desktop.Core;
using LibVLCSharp.Shared;
using SkiaSharp;

namespace Aurelia.Desktop.Playback;

/// <summary>
/// Timeline preview frames decoded live from the playing title through its preview relay. Shortly
/// after a title starts, frames for the whole timeline are prepared in the background, coarse to
/// fine, on several decoders where the server allows it; the hovered position always goes first.
/// Frames stay compressed in memory for the open title only and are never written anywhere.
/// </summary>
public sealed class ScrubPreviews : IDisposable
{
    private static readonly TimeSpan FrameTimeout = TimeSpan.FromSeconds(6);
    private readonly ConcurrentDictionary<long, byte[]> frames = new();
    private readonly ConcurrentDictionary<long, byte> failed = new();
    private readonly ConcurrentDictionary<long, byte> working = new();
    private readonly ConcurrentDictionary<long, byte> retried = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly LibVLC library;
    private readonly Uri source;
    private readonly long duration;
    private readonly IReadOnlyList<long> order;
    private readonly int workers;
    private readonly TimeSpan startDelay;
    private int orderIndex = -1;
    private long requested = -1;
    private int failuresInARow;
    private DateTimeOffset restUntil;

    public ScrubPreviews(Uri source, long duration, bool parallel, TimeSpan? startDelay = null, IEnumerable<string>? extraOptions = null)
    {
        VlcRuntime.EnsureInitialized();
        this.source = source;
        this.duration = duration;
        this.startDelay = startDelay ?? TimeSpan.FromSeconds(4);
        Interval = ScrubPreviewPlan.Interval(duration);
        order = ScrubPreviewPlan.Order(duration, Interval);
        workers = ScrubPreviewPlan.Workers(parallel);
        library = new LibVLC(enableDebugLogs: false, ["--quiet", "--no-audio", "--no-spu", "--aout=dummy", .. extraOptions ?? []]);
    }

    /// <summary>Raised on a background thread when a frame was added.</summary>
    public event Action? FrameAdded;

    public long Interval { get; }
    public int PreparedCount => frames.Count;

    public void Start()
    {
        for (var worker = 0; worker < workers; worker++) _ = Task.Run(() => BackgroundAsync(lifetime.Token));
        _ = Task.Run(() => InteractiveAsync(lifetime.Token));
    }

    public long Bucket(long milliseconds) => ScrubPreviewPlan.Bucket(Math.Min(milliseconds, duration - 1), Interval);

    /// <summary>The JPEG for the hovered position, or a nearby prepared one; the exact one is decoded next.</summary>
    public byte[]? Frame(long milliseconds)
    {
        var bucket = Bucket(milliseconds);
        if (!frames.ContainsKey(bucket)) Interlocked.Exchange(ref requested, bucket);
        var nearest = ScrubPreviewPlan.Nearest(bucket, Interval, frames.ContainsKey);
        return nearest is { } found && frames.TryGetValue(found, out var bytes) ? bytes : null;
    }

    public bool HasExactFrame(long milliseconds) => frames.ContainsKey(Bucket(milliseconds));

    public void Dispose()
    {
        lifetime.Cancel();
        // Decoders stop on their own threads; the library goes once they are done.
        _ = Task.Run(async () =>
        {
            await Task.Delay(FrameTimeout + TimeSpan.FromSeconds(1));
            library.Dispose();
            lifetime.Dispose();
        });
    }

    private async Task BackgroundAsync(CancellationToken token)
    {
        try
        {
            await Task.Delay(startDelay, token);
            while (!token.IsCancellationRequested)
            {
                if (DateTimeOffset.UtcNow < restUntil)
                {
                    await Task.Delay(restUntil - DateTimeOffset.UtcNow, token);
                    continue;
                }
                var index = Interlocked.Increment(ref orderIndex);
                long bucket;
                if (index < order.Count) bucket = order[index];
                else if (RetryCandidate() is { } retry) bucket = retry;
                else return;
                if (frames.ContainsKey(bucket) || (index < order.Count && failed.ContainsKey(bucket)) || !working.TryAdd(bucket, 0)) continue;
                var ok = await DecodeAsync(bucket, token);
                working.TryRemove(bucket, out _);
                if (ok)
                {
                    Interlocked.Exchange(ref failuresInARow, 0);
                }
                else if (Interlocked.Increment(ref failuresInARow) >= 3)
                {
                    // Repeated failures mean a busy server: all background decoders rest together.
                    Interlocked.Exchange(ref failuresInARow, 0);
                    restUntil = DateTimeOffset.UtcNow.AddSeconds(60);
                }
            }
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>Steps that failed once, for example while all decoders were busy, get one more try.</summary>
    private long? RetryCandidate()
    {
        foreach (var bucket in failed.Keys)
        {
            if (retried.TryAdd(bucket, 0) && !working.ContainsKey(bucket)) return bucket;
        }
        return null;
    }

    internal IReadOnlyCollection<long> FailedSteps => [.. failed.Keys.Where(bucket => !frames.ContainsKey(bucket))];

    private async Task InteractiveAsync(CancellationToken token)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                var bucket = Interlocked.Exchange(ref requested, -1);
                if (bucket < 0 || frames.ContainsKey(bucket) || !working.TryAdd(bucket, 0))
                {
                    await Task.Delay(40, token);
                    continue;
                }
                await DecodeAsync(bucket, token);
                working.TryRemove(bucket, out _);
            }
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>Opens the title at the step's position, takes the first frame and stops.</summary>
    private async Task<bool> DecodeAsync(long bucket, CancellationToken token)
    {
        var position = ScrubPreviewPlan.SnapshotPosition(bucket, Interval, duration);
        using var picture = new VideoFrames(maximumWidth: 320);
        using var player = new MediaPlayer(library);
        picture.Attach(player);
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        picture.FrameReady += () => ready.TrySetResult();
        using var media = new Media(library, source, ":no-audio", ":no-spu", ":network-caching=300",
            ":start-time=" + (position / 1000.0).ToString("0.000", System.Globalization.CultureInfo.InvariantCulture));
        player.Media = media;
        player.Play();
        try
        {
            await ready.Task.WaitAsync(FrameTimeout, token);
            var bytes = picture.Snapshot(out var width, out var height);
            if (bytes is null) return false;
            frames[bucket] = Encode(bytes, width, height);
            failed.TryRemove(bucket, out _);
            FrameAdded?.Invoke();
            return true;
        }
        catch (TimeoutException)
        {
            failed[bucket] = 0;
            return false;
        }
        finally
        {
            player.Stop();
        }
    }

    /// <summary>About 15–45 KB per frame instead of 230 KB as pixels.</summary>
    private static byte[] Encode(byte[] bgra, int width, int height)
    {
        var info = new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Opaque);
        using var image = SKImage.FromPixelCopy(info, bgra, width * 4);
        using var data = image.Encode(SKEncodedImageFormat.Jpeg, 72);
        return data.ToArray();
    }
}
