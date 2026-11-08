using Aurelia.Contracts;
using SkiaSharp;

namespace Aurelia.Server.Services;

/// <summary>
/// Turns an uploaded profile photo (JPEG, PNG or WebP) into a small square JPEG: upright, centered and
/// cropped, <see cref="ProfilePictures.PhotoSize"/> pixels. Nothing of the original file is kept.
/// </summary>
public static class ProfilePhotoEncoder
{
    private static readonly SemaphoreSlim Gate = new(2, 2);

    public static byte[] Encode(byte[] upload)
    {
        Gate.Wait();
        try
        {
            using var decoded = EditorArtworkStore.Decode(upload, allowProviderWebP: true, minimumWidth: ProfilePictures.PhotoSize);
            using var upright = EditorArtworkStore.Orient(decoded.Image, decoded.Origin);
            var side = Math.Min(upright.Width, upright.Height);
            var source = new SKRect((upright.Width - side) / 2f, (upright.Height - side) / 2f,
                (upright.Width + side) / 2f, (upright.Height + side) / 2f);
            var size = Math.Min(ProfilePictures.PhotoSize, side);
            using var square = new SKBitmap(new SKImageInfo(size, size, SKColorType.Rgba8888, SKAlphaType.Premul));
            using (var canvas = new SKCanvas(square))
            {
                canvas.Clear(SKColors.Black);
                using var image = SKImage.FromBitmap(upright);
                canvas.DrawImage(image, source, new SKRect(0, 0, size, size), new SKSamplingOptions(SKCubicResampler.Mitchell));
            }
            using var result = SKImage.FromBitmap(square);
            using var encoded = result.Encode(SKEncodedImageFormat.Jpeg, 86);
            return encoded.ToArray();
        }
        finally { Gate.Release(); }
    }
}
