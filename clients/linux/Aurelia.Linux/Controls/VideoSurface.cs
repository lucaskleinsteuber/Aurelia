using Aurelia.Linux.Playback;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;

namespace Aurelia.Linux.Controls;

/// <summary>
/// Shows the decoder's newest frame, letterboxed on black. Because the picture is drawn like any
/// other control, the player's controls sit on top of it on Wayland and X11 alike.
/// </summary>
public sealed class VideoSurface : Control, IDisposable
{
    private VideoFrames? frames;
    private WriteableBitmap? bitmap;
    private int pending;

    public VideoFrames? Frames
    {
        get => frames;
        set
        {
            if (frames == value) return;
            if (frames is not null) frames.FrameReady -= FrameReady;
            frames = value;
            if (frames is not null) frames.FrameReady += FrameReady;
            bitmap?.Dispose();
            bitmap = null;
            InvalidateVisual();
        }
    }

    public override void Render(DrawingContext context)
    {
        var bounds = new Rect(Bounds.Size);
        context.FillRectangle(Brushes.Black, bounds);
        if (bitmap is null || bounds.Width <= 0 || bounds.Height <= 0) return;
        var source = bitmap.Size;
        var scale = Math.Min(bounds.Width / source.Width, bounds.Height / source.Height);
        var size = new Size(source.Width * scale, source.Height * scale);
        context.DrawImage(bitmap, new Rect(source), new Rect((bounds.Width - size.Width) / 2, (bounds.Height - size.Height) / 2, size.Width, size.Height));
    }

    public void Dispose()
    {
        Frames = null;
        bitmap?.Dispose();
        bitmap = null;
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        Frames = null;
    }

    private void FrameReady()
    {
        // One screen update at a time; newer frames replace older ones that were not drawn yet.
        if (Interlocked.Exchange(ref pending, 1) == 1) return;
        Dispatcher.UIThread.Post(CopyFrame, DispatcherPriority.Render);
    }

    private void CopyFrame()
    {
        Interlocked.Exchange(ref pending, 0);
        if (frames is not { Width: > 0, Height: > 0 } current) return;
        if (bitmap is null || bitmap.PixelSize.Width != current.Width || bitmap.PixelSize.Height != current.Height)
        {
            bitmap?.Dispose();
            bitmap = new WriteableBitmap(new PixelSize(current.Width, current.Height), new Vector(96, 96), PixelFormat.Bgra8888, AlphaFormat.Opaque);
        }
        using (var buffer = bitmap.Lock())
        {
            if (!current.Copy(buffer.Address, buffer.RowBytes)) return;
        }
        InvalidateVisual();
    }
}
