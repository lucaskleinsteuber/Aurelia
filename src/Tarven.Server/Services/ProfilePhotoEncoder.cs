using Tarven.Contracts;
using SkiaSharp;

namespace Tarven.Server.Services;

/// <summary>
/// Turns an uploaded profile photo (JPEG, PNG or WebP) into a small square JPEG: upright, centered and
/// cropped, <see cref="ProfilePictures.PhotoSize"/> pixels. Nothing of the original file is kept.
/// </summary>
public static class ProfilePhotoEncoder
{
    private static readonly SemaphoreSlim Gate = new(2, 2);

    /// <summary>
    /// PNG and WebP decode at full size; 12 megapixels (48 MB decoded) are plenty for a small square.
    /// JPEGs decode scaled down and may be larger (audit S-L8).
    /// </summary>
    public const long MaximumFullPixels = 12_000_000;

    public static async Task<byte[]> EncodeAsync(byte[] upload, CancellationToken token)
    {
        // Waiting for a free slot no longer holds a request thread (audit S-L8).
        await Gate.WaitAsync(token);
        try
        {
            using var decoded = EditorArtworkStore.Decode(upload, allowProviderWebP: true, minimumWidth: ProfilePictures.PhotoSize,
                maximumFullPixels: MaximumFullPixels);
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
