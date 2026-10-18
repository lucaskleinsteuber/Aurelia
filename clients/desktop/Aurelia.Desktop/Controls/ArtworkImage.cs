using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Aurelia.Contracts;
using Aurelia.Desktop.Core;

namespace Aurelia.Desktop.Controls;

/// <summary>
/// A poster, backdrop or still: drawn from memory when it was shown before, else loaded from this
/// computer's cache or the server, filling its frame. A quiet placeholder shows until then.
/// </summary>
public sealed class ArtworkImage : Control
{
    public static readonly StyledProperty<ArtworkSummary?> ArtworkProperty =
        AvaloniaProperty.Register<ArtworkImage, ArtworkSummary?>(nameof(Artwork));
    public static readonly StyledProperty<int> DecodeWidthProperty =
        AvaloniaProperty.Register<ArtworkImage, int>(nameof(DecodeWidth), 320);

    private static readonly Dictionary<string, Bitmap> Memory = new(StringComparer.Ordinal);
    private static readonly LinkedList<string> Order = new();
    private const int MemoryLimit = 240;
    private static readonly IBrush Placeholder = new SolidColorBrush(Color.Parse("#2C3034"));
    private Bitmap? bitmap;
    private int generation;

    /// <summary>The loader of the open library; set when a profile opens.</summary>
    public static ArtworkLoader? Loader { get; set; }

    public ArtworkSummary? Artwork { get => GetValue(ArtworkProperty); set => SetValue(ArtworkProperty, value); }
    public int DecodeWidth { get => GetValue(DecodeWidthProperty); set => SetValue(DecodeWidthProperty, value); }

    public static void ClearMemory()
    {
        lock (Memory)
        {
            Memory.Clear();
            Order.Clear();
        }
    }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == ArtworkProperty || change.Property == DecodeWidthProperty) _ = LoadAsync();
    }

    public override void Render(DrawingContext context)
    {
        var bounds = new Rect(Bounds.Size);
        context.FillRectangle(Placeholder, bounds);
        if (bitmap is null || bounds.Width <= 0 || bounds.Height <= 0) return;
        // Fill the frame like UniformToFill, cropping the centre.
        var source = bitmap.Size;
        var scale = Math.Max(bounds.Width / source.Width, bounds.Height / source.Height);
        var cropped = new Size(bounds.Width / scale, bounds.Height / scale);
        var sourceRect = new Rect((source.Width - cropped.Width) / 2, (source.Height - cropped.Height) / 2, cropped.Width, cropped.Height);
        context.DrawImage(bitmap, sourceRect, bounds);
    }

    private async Task LoadAsync()
    {
        var current = ++generation;
        var artwork = Artwork;
        bitmap = null;
        InvalidateVisual();
        if (artwork is null || Loader is not { } loader) return;
        var key = ArtworkLoader.Key(artwork, DecodeWidth);
        lock (Memory)
        {
            if (Memory.TryGetValue(key, out var known))
            {
                bitmap = known;
                Order.Remove(key);
                Order.AddFirst(key);
                InvalidateVisual();
                return;
            }
        }
        var bytes = await loader.LoadAsync(artwork, DecodeWidth);
        if (bytes is null || current != generation) return;
        Bitmap decoded;
        try
        {
            using var stream = new MemoryStream(bytes);
            decoded = Bitmap.DecodeToWidth(stream, LibraryClient.ArtworkWidth(DecodeWidth));
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or IOException)
        {
            return;
        }
        lock (Memory)
        {
            Memory[key] = decoded;
            Order.AddFirst(key);
            while (Order.Count > MemoryLimit)
            {
                Memory.Remove(Order.Last!.Value);
                Order.RemoveLast();
            }
        }
        if (current != generation) return;
        bitmap = decoded;
        InvalidateVisual();
    }
}
