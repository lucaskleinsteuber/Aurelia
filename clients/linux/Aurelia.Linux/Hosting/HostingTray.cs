using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Imaging;

namespace Aurelia.Linux.Hosting;

/// <summary>
/// The notification-area icon while this computer's server keeps running without the window
/// (StatusNotifierItem where the desktop offers it; never required): open Aurelia, or quit and stop
/// the server.
/// </summary>
internal sealed class HostingTray : IDisposable
{
    private readonly TrayIcon icon;

    public HostingTray(Action open, Action quit)
    {
        var openItem = new NativeMenuItem("Open Aurelia");
        openItem.Click += (_, _) => open();
        var quitItem = new NativeMenuItem("Quit Aurelia and Stop the Server");
        quitItem.Click += (_, _) => quit();
        icon = new TrayIcon
        {
            ToolTipText = "Aurelia · the server is running",
            Icon = Picture(),
            Menu = new NativeMenu { Items = { openItem, new NativeMenuItemSeparator(), quitItem } },
            IsVisible = false,
        };
        icon.Clicked += (_, _) => open();
        if (Application.Current is { } app) TrayIcon.SetIcons(app, [icon]);
    }

    public bool IsVisible
    {
        get => icon.IsVisible;
        set => icon.IsVisible = value;
    }

    public void Dispose()
    {
        icon.IsVisible = false;
        icon.Dispose();
    }

    /// <summary>The Aurelia mark on the accent color, drawn once at start.</summary>
    private static WindowIcon? Picture()
    {
        if (Application.Current?.FindResource("IconAurelia") is not Geometry mark) return null;
        using var bitmap = new RenderTargetBitmap(new PixelSize(64, 64));
        using (var context = bitmap.CreateDrawingContext())
        {
            context.DrawRectangle(new SolidColorBrush(Color.Parse("#0A84FF")), null, new RoundedRect(new Rect(0, 0, 64, 64), 14));
            var bounds = mark.Bounds;
            var scale = 40 / Math.Max(bounds.Width, bounds.Height);
            var matrix = Matrix.CreateTranslation(-bounds.X - bounds.Width / 2, -bounds.Y - bounds.Height / 2) * Matrix.CreateScale(scale, scale) * Matrix.CreateTranslation(32, 32);
            using (context.PushTransform(matrix)) context.DrawGeometry(Brushes.White, null, mark);
        }
        using var stream = new MemoryStream();
        bitmap.Save(stream, PngBitmapEncoderOptions.Default);
        stream.Position = 0;
        return new WindowIcon(stream);
    }
}
