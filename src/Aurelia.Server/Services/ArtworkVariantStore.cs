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
    // Cached variants are served without waiting. Generation runs in parallel up to
    // half the processors (2-4), and striped locks keep one generation per variant.
    private readonly SemaphoreSlim generation = new(Math.Clamp(Environment.ProcessorCount / 2, 2, 4));
    private readonly SemaphoreSlim[] variantLocks = Enumerable.Range(0, 64).Select(_ => new SemaphoreSlim(1, 1)).ToArray();
    private readonly object cacheGate = new();
    private static readonly string[] VariantExtensions = [".jpg", ".png"];
    private readonly string directory = Path.Combine(runtime.DataDirectory, "ArtworkVariants");
    private DateTimeOffset nextPrune;
    private long usedBytes;

    public void Dispose()
    {
        generation.Dispose();
        foreach (var variantLock in variantLocks) variantLock.Dispose();
    }

    public async Task<ArtworkFileResult?> OpenAsync(Guid id, long revision, int width,
        ArtworkFileResult original, AureliaDbContext database, CancellationToken token)
    {
        if (!IsSupportedWidth(width))
            throw new AccountException("invalid_artwork_width", "Choose an artwork width of 320, 640, 1280 or 1920.", 400);
        var stem = $"{id:N}-r{revision:x}-w{width}-v1";
        if (Directory.Exists(directory) && new DirectoryInfo(directory).LinkTarget is not null) return null;
        // Variants are published by an atomic rename, so a hit never sees a partial file.
        if (OpenCached(stem, original.LastModified, revision) is { } hit) return hit;
        var variantLock = variantLocks[(int)((uint)StringComparer.Ordinal.GetHashCode(stem) % (uint)variantLocks.Length)];
        await variantLock.WaitAsync(token);
        try
        {
            if (OpenCached(stem, original.LastModified, revision) is { } concurrent) return concurrent;
            await generation.WaitAsync(token);
            try { return await GenerateAsync(id, revision, width, stem, original, database, token); }
            finally { generation.Release(); }
        }
        finally { variantLock.Release(); }
    }

    /// <summary>Opens an existing variant without touching the original artwork file.</summary>
    public ArtworkFileResult? OpenCached(Guid id, long revision, int width, DateTimeOffset lastModified)
    {
        if (!IsSupportedWidth(width)) return null;
        if (Directory.Exists(directory) && new DirectoryInfo(directory).LinkTarget is not null) return null;
        return OpenCached($"{id:N}-r{revision:x}-w{width}-v1", lastModified, revision);
    }

    internal bool IsCached(Guid id, long revision, int width)
    {
        var stem = $"{id:N}-r{revision:x}-w{width}-v1";
        return VariantExtensions.Any(extension => File.Exists(Path.Combine(directory, stem + extension)));
    }

    internal long MeasureUsedBytes()
    {
        if (!Directory.Exists(directory)) return 0;
        lock (cacheGate)
        {
            usedBytes = Directory.EnumerateFiles(directory).Select(path => new FileInfo(path))
                .Where(file => file.LinkTarget is null).Sum(file => file.Length);
            return usedBytes;
        }
    }

    private ArtworkFileResult? OpenCached(string stem, DateTimeOffset lastModified, long revision)
    {
        foreach (var extension in VariantExtensions)
        {
            var cached = Path.Combine(directory, stem + extension);
            try
            {
                var file = new FileInfo(cached);
                if (!file.Exists || file.LinkTarget is not null) continue;
                if (file.Length <= 0 || file.Length > EditorArtworkStore.MaximumUploadBytes) continue;
                var stream = File.Open(cached, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
                // Refresh the pruning age at most hourly instead of writing on every hit.
                var now = clock.GetUtcNow().UtcDateTime;
                if (file.LastWriteTimeUtc < now.AddHours(-1))
                {
                    try { File.SetLastWriteTimeUtc(cached, now); }
                    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
                }
                return new(stream, extension == ".png" ? "image/png" : "image/jpeg", stream.Length, lastModified, revision);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        return null;
    }

    private async Task<ArtworkFileResult?> GenerateAsync(Guid id, long revision, int width, string stem,
        ArtworkFileResult original, AureliaDbContext database, CancellationToken token)
    {
        try
        {
            if (original.ContentLength is <= 0 or > EditorArtworkStore.MaximumUploadBytes) return null;
            var bytes = new byte[checked((int)original.ContentLength)];
            await original.Stream.ReadExactlyAsync(bytes, token);
            original.Stream.Position = 0;
            using var decoded = EditorArtworkStore.Decode(bytes, allowProviderWebP: true, minimumWidth: width);
            using var oriented = EditorArtworkStore.Orient(decoded.Image, decoded.Origin);
            var targetWidth = Math.Min(width, oriented.Width);
            var targetHeight = Math.Max(1, (int)Math.Round((double)oriented.Height * targetWidth / oriented.Width));
            using var resized = new SKBitmap(new SKImageInfo(targetWidth, targetHeight, SKColorType.Rgba8888, SKAlphaType.Premul));
            if (resized.IsEmpty || resized.GetPixels() == IntPtr.Zero) return null;
            using (var canvas = new SKCanvas(resized))
                canvas.DrawBitmap(oriented, new SKRect(0, 0, targetWidth, targetHeight), new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear));
            // The decoded alpha type alone does not imply transparent pixels. JPEG
            // has no alpha channel, so only other formats need the pixel scan.
            var transparent = false;
            if (!decoded.IsJpeg)
            {
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
                lock (cacheGate)
                {
                    if (nextPrune <= clock.GetUtcNow()) Prune(0);
                    if (usedBytes + data.LongLength > MaximumCacheBytes) Prune(data.LongLength);
                }
                var path = Path.Combine(directory, stem + (transparent ? ".png" : ".jpg"));
                var temporary = path + "." + Guid.NewGuid().ToString("N") + ".pending";
                try
                {
                    await using (var output = PrivateFilePermissions.OpenNewPrivateFile(temporary))
                        await output.WriteAsync(data, token);
                    File.Move(temporary, path, true);
                    lock (cacheGate) usedBytes += data.LongLength;
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
    }

    // Called with cacheGate held.
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
