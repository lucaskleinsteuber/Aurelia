using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;
using SkiaSharp;

namespace Aurelia.Server.Services;

// Rebuildable images only. The Artwork source directory and backup manifests
// deliberately do not include this cache.
public sealed class ArtworkVariantStore(ServerRuntimeOptions runtime, TimeProvider clock) : IDisposable
{
    public const long MaximumCacheBytes = 256L * 1024 * 1024;
    public static bool IsSupportedWidth(int width) => width is 320 or 640 or 1280 or 1920;
    private readonly SemaphoreSlim generation = new(1, 1);
    private readonly string directory = Path.Combine(runtime.DataDirectory, "ArtworkVariants");
    private DateTimeOffset nextPrune;
    private long usedBytes;

    public void Dispose() => generation.Dispose();

    public async Task<ArtworkFileResult?> OpenAsync(Guid id, long revision, int width,
        ArtworkFileResult original, AureliaDbContext database, CancellationToken token)
    {
        if (!IsSupportedWidth(width))
            throw new AccountException("invalid_artwork_width", "Choose an artwork width of 320, 640, 1280 or 1920.", 400);
        await generation.WaitAsync(token);
        try
        {
            var stem = $"{id:N}-r{revision:x}-w{width}-v1";
            if (Directory.Exists(directory) && new DirectoryInfo(directory).LinkTarget is not null) return null;
            foreach (var extension in new[] { ".jpg", ".png" })
            {
                var cached = Path.Combine(directory, stem + extension);
                if (!File.Exists(cached) || new FileInfo(cached).LinkTarget is not null) continue;
                var file = new FileInfo(cached);
                if (file.Length <= 0 || file.Length > EditorArtworkStore.MaximumUploadBytes) continue;
                var stream = File.Open(cached, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
                try { File.SetLastWriteTimeUtc(cached, clock.GetUtcNow().UtcDateTime); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
                return new(stream, extension == ".png" ? "image/png" : "image/jpeg", stream.Length, original.LastModified, revision);
            }
            if (original.ContentLength is <= 0 or > EditorArtworkStore.MaximumUploadBytes) return null;
            var bytes = new byte[checked((int)original.ContentLength)];
            await original.Stream.ReadExactlyAsync(bytes, token);
            original.Stream.Position = 0;
            using var decoded = EditorArtworkStore.Decode(bytes, allowProviderWebP: true);
            using var oriented = EditorArtworkStore.Orient(decoded.Image, decoded.Origin);
            var targetWidth = Math.Min(width, oriented.Width);
            var targetHeight = Math.Max(1, (int)Math.Round((double)oriented.Height * targetWidth / oriented.Width));
            using var resized = new SKBitmap(new SKImageInfo(targetWidth, targetHeight, SKColorType.Rgba8888, SKAlphaType.Premul));
            if (resized.IsEmpty || resized.GetPixels() == IntPtr.Zero) return null;
            using (var canvas = new SKCanvas(resized))
                canvas.DrawBitmap(oriented, new SKRect(0, 0, targetWidth, targetHeight), new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear));
            // The decoded alpha type alone does not imply transparent pixels.
            var transparent = false;
            unsafe
            {
                var pixels = (byte*)resized.GetPixels();
                for (var y = 0; y < targetHeight && !transparent; y++)
                {
                    token.ThrowIfCancellationRequested();
                    for (var x = 0; x < targetWidth; x++)
                        if (pixels[y * resized.RowBytes + x * 4 + 3] != 255) { transparent = true; break; }
                }
            }
            using var image = SKImage.FromBitmap(resized);
            using var encoded = image.Encode(transparent ? SKEncodedImageFormat.Png : SKEncodedImageFormat.Jpeg, transparent ? 100 : 85);
            if (encoded is null || encoded.Size > EditorArtworkStore.MaximumUploadBytes) return null;
            token.ThrowIfCancellationRequested();
            // Never publish a generation produced from a superseded source.
            if (!await database.ArtworkAssets.AsNoTracking().AnyAsync(asset => asset.Id == id && asset.Revision == revision, token)) return null;
            var data = encoded.ToArray();
            try
            {
                PrivateFilePermissions.CreatePrivateDirectory(directory);
                if (nextPrune <= clock.GetUtcNow()) Prune(0);
                if (usedBytes + data.LongLength > MaximumCacheBytes) Prune(data.LongLength);
                var path = Path.Combine(directory, stem + (transparent ? ".png" : ".jpg"));
                var temporary = path + "." + Guid.NewGuid().ToString("N") + ".pending";
                try
                {
                    await using (var output = PrivateFilePermissions.OpenNewPrivateFile(temporary))
                        await output.WriteAsync(data, token);
                    File.Move(temporary, path, true);
                    usedBytes += data.LongLength;
                }
                finally { if (File.Exists(temporary)) File.Delete(temporary); }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            { /* A cache write failure must not make the source unavailable. */ }
            return new(new MemoryStream(data, writable: false), transparent ? "image/png" : "image/jpeg", data.LongLength, original.LastModified, revision);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or AccountException or InvalidOperationException)
        {
            if (original.Stream.CanSeek) original.Stream.Position = 0;
            return null;
        }
        finally { generation.Release(); }
    }

    private void Prune(long requiredBytes)
    {
        var files = Directory.EnumerateFiles(directory).Select(path => new FileInfo(path))
            .Where(file => file.LinkTarget is null).OrderBy(file => file.LastWriteTimeUtc).ToList();
        usedBytes = files.Sum(file => file.Length);
        foreach (var file in files)
        {
            if (file.Extension == ".pending" || usedBytes + requiredBytes > MaximumCacheBytes)
            {
                var length = file.Length;
                file.Delete();
                usedBytes -= length;
            }
        }
        nextPrune = clock.GetUtcNow().AddMinutes(1);
    }
}
