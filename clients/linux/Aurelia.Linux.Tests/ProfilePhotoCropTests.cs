using System.Runtime.InteropServices;
using Aurelia.Contracts;
using Aurelia.Linux.Management;
using Avalonia;
using Avalonia.Headless.XUnit;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Xunit;

namespace Aurelia.Linux.Tests;

/// <summary>A chosen profile photo is sent as the square chosen in the crop sheet, also when turned.</summary>
public sealed class ProfilePhotoCropTests
{
    /// <summary>An invented 200 × 100 picture: red on the left half, blue on the right.</summary>
    private static byte[] Picture()
    {
        using var target = new RenderTargetBitmap(new PixelSize(200, 100));
        using (var context = target.CreateDrawingContext())
        {
            context.FillRectangle(Brushes.Red, new Rect(0, 0, 100, 100));
            context.FillRectangle(Brushes.Blue, new Rect(100, 0, 100, 100));
        }
        using var output = new MemoryStream();
        target.Save(output, new PngBitmapEncoderOptions());
        return output.ToArray();
    }

    private static (PixelSize Size, Color Center) Read(byte[] png)
    {
        using var bitmap = new Bitmap(new MemoryStream(png));
        var size = bitmap.PixelSize;
        var stride = size.Width * 4;
        var pixels = new byte[stride * size.Height];
        var handle = GCHandle.Alloc(pixels, GCHandleType.Pinned);
        try
        {
            bitmap.CopyPixels(new PixelRect(size), handle.AddrOfPinnedObject(), pixels.Length, stride);
        }
        finally
        {
            handle.Free();
        }
        var at = (size.Height / 2 * size.Width + size.Width / 2) * 4;
        var rgba = bitmap.Format == PixelFormat.Rgba8888;
        return (size, Color.FromArgb(pixels[at + 3], pixels[rgba ? at : at + 2], pixels[at + 1], pixels[rgba ? at + 2 : at]));
    }

    [AvaloniaFact]
    public void TheChosenSquareIsSentNotTheWholePicture()
    {
        var (size, center) = Read(CropSheet.Render(Picture(), new ArtworkCrop(0.5, 0, 0.5, 1), 1024)!);
        Assert.Equal(new PixelSize(100, 100), size);
        Assert.True(center.B > 200 && center.R < 50, $"Expected blue, got {center}");
    }

    [AvaloniaFact]
    public void AQuarterTurnCropsWhatTheSheetShowed()
    {
        // Turned clockwise the picture is 100 × 200 with the red half on top.
        var (size, center) = Read(CropSheet.Render(Picture(), new ArtworkCrop(0, 0, 1, 0.5, 90), 1024)!);
        Assert.Equal(new PixelSize(100, 100), size);
        Assert.True(center.R > 200 && center.B < 50, $"Expected red, got {center}");
    }

    [AvaloniaFact]
    public void ALargeCropIsShrunkAndAnUnreadableFileGivesNothing()
    {
        Assert.Equal(new PixelSize(50, 50), Read(CropSheet.Render(Picture(), new ArtworkCrop(0, 0, 0.5, 1), 50)!).Size);
        Assert.Null(CropSheet.Render([1, 2, 3], new ArtworkCrop(0, 0, 1, 1), 1024));
    }
}
