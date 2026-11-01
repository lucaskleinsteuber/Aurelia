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
/// Artwork from the server: a quiet gradient until the picture arrives, then the picture fading in.
/// It loads only once it is on screen, asks for the smallest size that stays sharp, and decodes off
/// the interface thread.
/// </summary>
public sealed class ArtworkImage : Border
{
    private static readonly IBrush Placeholder = new LinearGradientBrush
    {
        StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
        EndPoint = new RelativePoint(1, 1, RelativeUnit.Relative),
        GradientStops = { new GradientStop(Color.Parse("#2E3338"), 0), new GradientStop(Color.Parse("#22262A"), 1) },
    };

    private readonly Image image = new() { Stretch = Stretch.UniformToFill, Opacity = 0 };
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
        image.Transitions = [new DoubleTransition { Property = OpacityProperty, Duration = TimeSpan.FromMilliseconds(280) }];
        Child = image;
        EffectiveViewportChanged += (_, e) =>
        {
            if (!requested && e.EffectiveViewport.Width > 0 && e.EffectiveViewport.Height > 0) _ = LoadAsync();
        };
    }

    internal bool HasPicture => image.Source is not null;

    private async Task LoadAsync()
    {
        requested = true;
        if (store is null || artwork is null) return;
        var scaling = TopLevel.GetTopLevel(this)?.RenderScaling ?? 1;
        var width = ArtworkCache.WidthFor(displayWidth * scaling);
        try
        {
            var bytes = await store.Artwork.GetAsync(store.Client, artwork, width, CancellationToken.None);
            var bitmap = await Task.Run(() =>
            {
                using var stream = new MemoryStream(bytes);
                return Bitmap.DecodeToWidth(stream, Math.Min(width, 4096), BitmapInterpolationMode.HighQuality);
            });
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
