using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Library;
using Avalonia;
using Avalonia.Animation;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;

namespace Aurelia.Linux.Controls;

/// <summary>
/// Artwork from the server: a quiet gradient until the picture arrives. It starts loading well
/// before it scrolls into view, asks for the smallest size that stays sharp and decodes off the
/// interface thread. Pictures decoded once stay in memory, so they appear at once when a page
/// or card is shown again, without being drawn in front of the viewer.
/// </summary>
public sealed class ArtworkImage : Border
{
    private static readonly IBrush Placeholder = new LinearGradientBrush
    {
        StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
        EndPoint = new RelativePoint(1, 1, RelativeUnit.Relative),
        GradientStops = { new GradientStop(Color.Parse("#2E3338"), 0), new GradientStop(Color.Parse("#22262A"), 1) },
    };

    private readonly Image image = new() { Stretch = Stretch.UniformToFill };
    private readonly ArtworkSummary? artwork;
    private readonly LibraryStore? store;
    private readonly double displayWidth;
    private bool requested;

    public ArtworkImage(LibraryStore? store, ArtworkSummary? artwork, double displayWidth)
    {
        this.store = store;
        this.artwork = artwork;
        this.displayWidth = displayWidth;
        ClipToBounds = true;
        Background = Placeholder;
        Child = image;
        // A picture this window already decoded shows at once.
        if (artwork is not null && DecodedArtwork.Find(artwork.Id, ArtworkCache.WidthFor(displayWidth)) is { } known)
        {
            image.Source = known;
            requested = true;
        }
        else
        {
            image.Opacity = 0;
            image.Transitions = [new DoubleTransition { Property = OpacityProperty, Duration = TimeSpan.FromMilliseconds(160) }];
        }
        EffectiveViewportChanged += (_, e) =>
        {
            if (!requested && IsNearViewport(e.EffectiveViewport, Bounds.Size)) _ = LoadAsync();
        };
    }

    internal bool HasPicture => image.Source is not null;

    /// <summary>
    /// True when the control is on screen or within about two screens of it, so pictures are ready
    /// before they scroll into view.
    /// </summary>
    internal static bool IsNearViewport(Rect viewport, Size size)
    {
        if (viewport.Width <= 0 || viewport.Height <= 0) return false;
        var ahead = viewport.Inflate(new Thickness(viewport.Width * 1.5, viewport.Height * 2));
        return ahead.Intersects(new Rect(0, 0, Math.Max(size.Width, 1), Math.Max(size.Height, 1)));
    }

    private async Task LoadAsync()
    {
        requested = true;
        if (store is null || artwork is null) return;
        var scaling = TopLevel.GetTopLevel(this)?.RenderScaling ?? 1;
        var width = ArtworkCache.WidthFor(displayWidth * scaling);
        try
        {
            if (DecodedArtwork.Find(artwork.Id, width) is not { } bitmap)
            {
                var bytes = await store.Artwork.GetAsync(store.Client, artwork, width, CancellationToken.None);
                bitmap = await Task.Run(() =>
                {
                    using var stream = new MemoryStream(bytes);
                    return Bitmap.DecodeToWidth(stream, Math.Min(width, 4096), BitmapInterpolationMode.HighQuality);
                });
                DecodedArtwork.Add(artwork.Id, width, bitmap);
                DecodedArtwork.Add(artwork.Id, ArtworkCache.WidthFor(displayWidth), bitmap);
            }
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                image.Source = bitmap;
                image.Opacity = 1;
            });
        }
        catch (Exception error) when (error is AureliaApiException or ArgumentException or InvalidOperationException or IOException)
        {
            // The placeholder stays; a missing picture never blocks the page.
        }
    }
}

/// <summary>
/// Pictures decoded for this window, newest last, so a page shown again needs no decoding. The
/// number is bounded; the oldest are dropped (the disk cache still holds their files).
/// </summary>
internal static class DecodedArtwork
{
    public const int Capacity = 400;
    private static readonly object Gate = new();
    private static readonly Dictionary<(Guid, int), LinkedListNode<((Guid, int) Key, Bitmap Bitmap)>> Index = [];
    private static readonly LinkedList<((Guid, int) Key, Bitmap Bitmap)> Order = new();

    public static Bitmap? Find(Guid id, int width)
    {
        lock (Gate)
        {
            if (!Index.TryGetValue((id, width), out var node)) return null;
            Order.Remove(node);
            Order.AddLast(node);
            return node.Value.Bitmap;
        }
    }

    public static void Add(Guid id, int width, Bitmap bitmap)
    {
        lock (Gate)
        {
            if (Index.TryGetValue((id, width), out var existing)) Order.Remove(existing);
            Index[(id, width)] = Order.AddLast(((id, width), bitmap));
            // Bitmaps are not disposed here: a card on screen may still show one.
            while (Order.Count > Capacity && Order.First is { } oldest)
            {
                Order.RemoveFirst();
                Index.Remove(oldest.Value.Key);
            }
        }
    }
}
