using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;
using SkiaSharp;

namespace Aurelia.Server.Services;

public sealed record CollectionImageResult(
    Stream? Stream,
    byte[]? Bytes,
    string ContentType,
    long ContentLength,
    DateTimeOffset LastModified,
    long Revision,
    Guid EntityId);

/// <summary>
/// Manages uploaded, TMDB-fetched, and SkiaSharp-generated mosaic artwork for Box Set collections.
/// Files live privately under <c>{DataDirectory}/Artwork/Collections</c>.
/// </summary>
public sealed class CollectionArtworkService(
    ServerRuntimeOptions runtime,
    EditorArtworkStore images,
    MetadataProviderSettingsStore metadataSettings,
    ITmdbClient tmdb,
    ArtworkStore artworkStore,
    ArtworkVariantStore variants,
    TimeProvider? clock = null) : IDisposable
{
    // Generated covers are small JPEGs kept only in memory, never on disk, and capped in size.
    private const long MaximumMosaicCacheBytes = 24L * 1024 * 1024;
    private const string MosaicContentType = "image/jpeg";
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private readonly string directory = Path.Combine(runtime.DataDirectory, "Artwork", "Collections");
    private readonly TimeProvider timeProvider = clock ?? TimeProvider.System;
    private readonly ConcurrentDictionary<string, (byte[] Bytes, DateTimeOffset CreatedAt)> mosaicCache = new(StringComparer.Ordinal);
    private readonly SemaphoreSlim mosaicLock = new(1, 1);

    public async Task<ArtworkSummary> SaveManualAsync(
        AureliaDbContext database,
        MediaCollectionRecord collection,
        Guid userId,
        Guid sessionId,
        ArtworkKind kind,
        Stream? rawStream,
        SaveCollectionArtworkRequest? jsonRequest,
        ArtworkCrop? queryCrop,
        CancellationToken token)
    {
        ValidateKind(kind);
        var existingAssets = await database.CollectionArtworkAssets
            .Where(asset => asset.CollectionId == collection.Id && asset.Kind == kind)
            .ToListAsync(token);
        var manualAssets = existingAssets.Where(asset => asset.IsManual).ToList();
        var nextRevision = existingAssets.Count == 0 ? 1L : checked(existingAssets.Max(asset => asset.Revision) + 1);

        ArtworkCrop? crop = jsonRequest?.Crop ?? queryCrop;
        (byte[] Original, byte[] Rendered) encoded;
        if (jsonRequest is { UploadId: { } uploadId })
        {
            var draftPath = images.DraftPath(uploadId, collection.Id, userId, sessionId);
            encoded = await images.RenderFromFileAsync(draftPath, kind, crop, allowProviderWebP: false, token);
        }
        else if (jsonRequest is not null)
        {
            var previous = manualAssets.OrderByDescending(asset => asset.Revision).FirstOrDefault()
                ?? existingAssets.OrderByDescending(asset => asset.Revision).FirstOrDefault()
                ?? throw new AccountException("artwork_not_found", "Upload an image before cropping.", 404);
            var sourcePath = EditorArtworkStore.SafeImagePath(directory, previous.OriginalFilePath ?? previous.RelativeFilePath);
            encoded = await images.RenderFromFileAsync(sourcePath, kind, crop, allowProviderWebP: !previous.IsManual, token);
        }
        else if (rawStream is not null)
        {
            var rawBytes = await EditorArtworkStore.ReadUploadBytesAsync(rawStream, token);
            encoded = await images.RenderFromBytesAsync(rawBytes, kind, crop, allowProviderWebP: false, token);
        }
        else
        {
            throw new AccountException("invalid_artwork", "Provide an image file or an uploaded image draft.", 400);
        }

        var id = Guid.NewGuid();
        var originalName = id.ToString("N") + "-original.png";
        var renderedName = id.ToString("N") + ".png";
        PrivateFilePermissions.CreatePrivateDirectory(directory);
        await EditorArtworkStore.WriteAsync(Path.Combine(directory, originalName), encoded.Original, token);
        try
        {
            await EditorArtworkStore.WriteAsync(Path.Combine(directory, renderedName), encoded.Rendered, token);
        }
        catch
        {
            TryDeleteFile(originalName);
            throw;
        }

        var asset = new CollectionArtworkAsset
        {
            Id = id,
            CollectionId = collection.Id,
            Kind = kind,
            IsManual = true,
            ProviderPath = "manual/" + id.ToString("N"),
            RelativeFilePath = renderedName,
            OriginalFilePath = originalName,
            CropJson = JsonSerializer.Serialize(crop, Json),
            ContentType = "image/png",
            ContentLength = encoded.Rendered.LongLength,
            Revision = nextRevision,
            CreatedAt = timeProvider.GetUtcNow(),
        };
        database.CollectionArtworkAssets.Add(asset);

        if (kind == ArtworkKind.Poster) collection.PosterAssetId = asset.Id;
        else collection.BackdropAssetId = asset.Id;
        collection.UpdatedAt = timeProvider.GetUtcNow();

        if (manualAssets.Count > 0) database.CollectionArtworkAssets.RemoveRange(manualAssets);
        await database.SaveChangesAsync(token);

        DeleteAssetFiles(manualAssets);
        InvalidateCollectionCache(collection.Id);
        return ToSummary(collection.Id, asset);
    }

    public async Task RemoveManualAsync(
        AureliaDbContext database,
        MediaCollectionRecord collection,
        ArtworkKind kind,
        CancellationToken token)
    {
        ValidateKind(kind);
        var assets = await database.CollectionArtworkAssets
            .Where(asset => asset.CollectionId == collection.Id && asset.Kind == kind)
            .ToListAsync(token);
        var manualAssets = assets.Where(asset => asset.IsManual).ToList();
        var fallback = assets.Where(asset => !asset.IsManual).OrderByDescending(asset => asset.Revision).FirstOrDefault();

        if (manualAssets.Count > 0)
        {
            database.CollectionArtworkAssets.RemoveRange(manualAssets);
        }

        if (kind == ArtworkKind.Poster) collection.PosterAssetId = fallback?.Id;
        else collection.BackdropAssetId = fallback?.Id;
        collection.UpdatedAt = timeProvider.GetUtcNow();

        await database.SaveChangesAsync(token);
        DeleteAssetFiles(manualAssets);
        InvalidateCollectionCache(collection.Id);
    }

    public async Task<CollectionArtworkAsset?> StoreProviderArtworkAsync(
        AureliaDbContext database,
        MediaCollectionRecord collection,
        ArtworkKind kind,
        string? providerPath,
        CancellationToken cancellationToken)
    {
        ValidateKind(kind);
        if (string.IsNullOrWhiteSpace(providerPath)) return null;
        var configuration = metadataSettings.Load();
        if (!configuration.Enabled || configuration.Token is null) return null;

        var existing = await database.CollectionArtworkAssets
            .SingleOrDefaultAsync(asset => asset.CollectionId == collection.Id && asset.Kind == kind && !asset.IsManual, cancellationToken);
        if (existing?.ProviderPath == providerPath && File.Exists(Path.Combine(directory, existing.RelativeFilePath)))
        {
            return existing;
        }

        var size = kind == ArtworkKind.Poster ? "w780" : "w1280";
        byte[] bytes;
        try
        {
            bytes = await tmdb.DownloadImageAsync(configuration.Token, providerPath, size, cancellationToken);
        }
        catch (Exception error) when (error is MetadataException or MetadataProviderException or HttpRequestException or OperationCanceledException && !cancellationToken.IsCancellationRequested)
        {
            return existing;
        }

        var contentType = ArtworkFile.ContentType(bytes);
        var existingAssets = await database.CollectionArtworkAssets.AsNoTracking()
            .Where(asset => asset.CollectionId == collection.Id && asset.Kind == kind)
            .Select(asset => asset.Revision)
            .ToListAsync(cancellationToken);
        var revision = existingAssets.Count == 0 ? 1L : checked(existingAssets.Max() + 1);
        var id = existing?.Id ?? Guid.NewGuid();
        var relative = $"{id:N}-r{revision:x}" + ArtworkFile.Extension(contentType);
        var oldRelative = existing?.RelativeFilePath;
        var destination = Path.Combine(directory, relative);
        var temporary = destination + ".tmp";

        PrivateFilePermissions.CreatePrivateDirectory(directory);
        try
        {
            await File.WriteAllBytesAsync(temporary, bytes, cancellationToken);
            PrivateFilePermissions.ProtectFile(temporary);
            File.Move(temporary, destination, overwrite: true);
            PrivateFilePermissions.ProtectFile(destination);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }

        if (existing is null)
        {
            existing = new CollectionArtworkAsset { Id = id, CollectionId = collection.Id, Kind = kind, IsManual = false };
            database.CollectionArtworkAssets.Add(existing);
        }

        existing.ProviderPath = providerPath;
        existing.RelativeFilePath = relative;
        existing.ContentType = contentType;
        existing.ContentLength = bytes.LongLength;
        existing.Revision = revision;
        existing.CreatedAt = timeProvider.GetUtcNow();

        if (kind == ArtworkKind.Poster && collection.PosterAssetId is null) collection.PosterAssetId = existing.Id;
        if (kind == ArtworkKind.Backdrop && collection.BackdropAssetId is null) collection.BackdropAssetId = existing.Id;

        if (!string.IsNullOrEmpty(oldRelative) && oldRelative != relative) TryDeleteFile(oldRelative);
        InvalidateCollectionCache(collection.Id);
        return existing;
    }

    public async Task CopyAssetsAsync(
        AureliaDbContext database,
        MediaCollectionRecord source,
        MediaCollectionRecord destination,
        CancellationToken cancellationToken)
    {
        var sourceAssets = source.Artwork
            .Where(asset => asset.Kind is ArtworkKind.Poster or ArtworkKind.Backdrop)
            .GroupBy(asset => asset.Kind)
            .Select(group => group.OrderByDescending(asset => asset.Revision).First())
            .ToList();
        if (sourceAssets.Count == 0) return;

        PrivateFilePermissions.CreatePrivateDirectory(directory);
        foreach (var srcAsset in sourceAssets)
        {
            string sourcePath;
            try
            {
                sourcePath = EditorArtworkStore.SafeImagePath(directory, srcAsset.OriginalFilePath ?? srcAsset.RelativeFilePath);
            }
            catch (AccountException)
            {
                continue;
            }
            if (!File.Exists(sourcePath)) continue;

            var bytes = await File.ReadAllBytesAsync(sourcePath, cancellationToken);
            var id = Guid.NewGuid();
            var ext = ArtworkFile.Extension(srcAsset.ContentType);
            var relative = $"{id:N}-r1{ext}";
            await EditorArtworkStore.WriteAsync(Path.Combine(directory, relative), bytes, cancellationToken);

            var copied = new CollectionArtworkAsset
            {
                Id = id,
                CollectionId = destination.Id,
                Kind = srcAsset.Kind,
                IsManual = true,
                ProviderPath = "manual/" + id.ToString("N"),
                RelativeFilePath = relative,
                ContentType = srcAsset.ContentType,
                ContentLength = bytes.LongLength,
                Revision = 1,
                CreatedAt = timeProvider.GetUtcNow(),
            };
            database.CollectionArtworkAssets.Add(copied);
            if (copied.Kind == ArtworkKind.Poster) destination.PosterAssetId = copied.Id;
            else destination.BackdropAssetId = copied.Id;
        }
    }

    public async Task<IReadOnlyList<string>> FileNamesForCollectionsAsync(
        AureliaDbContext database,
        IReadOnlyCollection<Guid> collectionIds,
        CancellationToken token)
    {
        if (collectionIds.Count == 0) return [];
        var assets = await database.CollectionArtworkAssets.IgnoreQueryFilters()
            .AsNoTracking()
            .Where(asset => collectionIds.Contains(asset.CollectionId))
            .Select(asset => new { asset.RelativeFilePath, asset.OriginalFilePath })
            .ToListAsync(token);
        return assets.SelectMany(asset => new[] { asset.RelativeFilePath, asset.OriginalFilePath })
            .OfType<string>()
            .Distinct(StringComparer.Ordinal)
            .ToArray();
    }

    public void DeleteAssetFiles(IEnumerable<CollectionArtworkAsset> assets)
    {
        foreach (var path in assets.SelectMany(asset => new[] { asset.RelativeFilePath, asset.OriginalFilePath }).OfType<string>().Distinct(StringComparer.Ordinal))
        {
            TryDeleteFile(path);
        }
    }

    public void DeleteFileNames(IEnumerable<string> relativeNames)
    {
        foreach (var name in relativeNames.Distinct(StringComparer.Ordinal)) TryDeleteFile(name);
    }

    public void InvalidateCollectionCache(Guid collectionId)
    {
        var prefix = collectionId.ToString("N") + ":";
        foreach (var key in mosaicCache.Keys.Where(key => key.StartsWith(prefix, StringComparison.Ordinal)).ToArray())
        {
            mosaicCache.TryRemove(key, out _);
        }
    }

    public static ArtworkSummary ToSummary(Guid collectionId, CollectionArtworkAsset asset) => new(
        asset.Id,
        asset.Kind,
        $"/api/v1/artwork/collection/{collectionId}?kind={(asset.Kind == ArtworkKind.Poster ? "poster" : "backdrop")}",
        asset.ContentType,
        asset.ContentLength,
        asset.Revision);

    public async Task<CollectionImageResult?> ResolveImageAsync(
        AureliaDbContext database,
        MediaCollectionRecord collection,
        ArtworkKind kind,
        int? width,
        IReadOnlyList<MediaItem> visibleMembers,
        CancellationToken cancellationToken)
    {
        ValidateKind(kind);
        if (width.HasValue && !ArtworkVariantStore.IsSupportedWidth(width.Value))
        {
            throw new AccountException("invalid_artwork_width", "Choose an artwork width of 320, 640, 1280 or 1920.", 400);
        }

        // Priority 1: Explicit collection artwork (manual upload takes precedence over TMDB collection asset).
        var preferredId = kind == ArtworkKind.Poster ? collection.PosterAssetId : collection.BackdropAssetId;
        var stored = collection.Artwork
            .Where(asset => asset.Kind == kind)
            .OrderByDescending(asset => asset.Id == preferredId)
            .ThenByDescending(asset => asset.IsManual)
            .ThenByDescending(asset => asset.Revision)
            .FirstOrDefault();

        if (stored is not null)
        {
            try
            {
                var path = EditorArtworkStore.SafeImagePath(directory, stored.RelativeFilePath);
                var raw = await File.ReadAllBytesAsync(path, cancellationToken);
                var bytes = width.HasValue ? ResizeToWidth(raw, width.Value) ?? raw : raw;
                var type = width.HasValue && bytes != raw ? "image/jpeg" : stored.ContentType;
                return new(null, bytes, type, bytes.LongLength, stored.CreatedAt, stored.Revision, stored.Id);
            }
            catch (IOException)
            {
                // Fall back to member artwork if managed asset is missing on disk.
            }
        }

        // Priority 2: Backdrop falls back to first member's backdrop (or series still/backdrop).
        if (kind == ArtworkKind.Backdrop)
        {
            var backdropAsset = visibleMembers
                .Select(item => SelectMemberAsset(item, ArtworkKind.Backdrop))
                .FirstOrDefault(asset => asset is not null);
            if (backdropAsset is null) return null;
            return await OpenMemberAssetAsync(database, backdropAsset, width, cancellationToken);
        }

        // Priority 3: Poster falls back to 1 poster directly, or a SkiaSharp mosaic of up to 4 unique posters.
        var posters = visibleMembers
            .Select(item => SelectMemberAsset(item, ArtworkKind.Poster))
            .OfType<ArtworkAsset>()
            .DistinctBy(asset => asset.Id)
            .Take(4)
            .ToList();

        if (posters.Count == 0) return null;
        if (posters.Count == 1) return await OpenMemberAssetAsync(database, posters[0], width, cancellationToken);

        var targetWidth = width ?? 640;
        var revision = ComputeFallbackRevision(collection.UpdatedAt, posters.Select(p => (p.Id, p.Revision)));
        var cacheKey = $"{collection.Id:N}:{targetWidth}:{string.Join(',', posters.Select(p => $"{p.Id:N}-{p.Revision}"))}";

        if (mosaicCache.TryGetValue(cacheKey, out var cached))
        {
            return new(null, cached.Bytes, MosaicContentType, cached.Bytes.LongLength, cached.CreatedAt, revision, collection.Id);
        }

        await mosaicLock.WaitAsync(cancellationToken);
        try
        {
            if (mosaicCache.TryGetValue(cacheKey, out cached))
            {
                return new(null, cached.Bytes, MosaicContentType, cached.Bytes.LongLength, cached.CreatedAt, revision, collection.Id);
            }

            var bitmaps = new List<SKBitmap>();
            try
            {
                foreach (var asset in posters)
                {
                    var file = await artworkStore.OpenAsync(asset.Id, database, cancellationToken);
                    if (file is null) continue;
                    await using (file.Stream)
                    {
                        using var mem = new MemoryStream();
                        await file.Stream.CopyToAsync(mem, cancellationToken);
                        using var decoded = EditorArtworkStore.Decode(mem.ToArray(), allowProviderWebP: true, minimumWidth: Math.Max(320, targetWidth / 2));
                        bitmaps.Add(EditorArtworkStore.Orient(decoded.Image, decoded.Origin));
                    }
                }

                if (bitmaps.Count == 0) return null;
                if (bitmaps.Count == 1)
                {
                    return await OpenMemberAssetAsync(database, posters[0], width, cancellationToken);
                }

                var mosaic = RenderMosaic(bitmaps, targetWidth);
                var now = timeProvider.GetUtcNow();
                var cachedBytes = mosaicCache.Values.Sum(value => (long)value.Bytes.Length);
                foreach (var (oldKey, oldValue) in mosaicCache.OrderBy(pair => pair.Value.CreatedAt).ToArray())
                {
                    if (cachedBytes + mosaic.Length <= MaximumMosaicCacheBytes) break;
                    if (mosaicCache.TryRemove(oldKey, out _)) cachedBytes -= oldValue.Bytes.Length;
                }
                if (mosaic.Length <= MaximumMosaicCacheBytes) mosaicCache[cacheKey] = (mosaic, now);
                return new(null, mosaic, MosaicContentType, mosaic.LongLength, now, revision, collection.Id);
            }
            finally
            {
                foreach (var bitmap in bitmaps) bitmap.Dispose();
            }
        }
        finally
        {
            mosaicLock.Release();
        }
    }

    public static long ComputeFallbackRevision(DateTimeOffset updatedAt, IEnumerable<(Guid Id, long Revision)> assets)
    {
        // Stable across restarts (HashCode is seeded per process), so clients keep cached covers.
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(BitConverter.GetBytes(updatedAt.ToUnixTimeMilliseconds()));
        foreach (var (id, revision) in assets)
        {
            hash.AppendData(id.ToByteArray());
            hash.AppendData(BitConverter.GetBytes(revision));
        }
        var digest = hash.GetHashAndReset();
        return (long)(BitConverter.ToUInt64(digest, 0) % 1_000_000_000UL) + 1L;
    }

    public static ArtworkAsset? SelectMemberAsset(MediaItem item, ArtworkKind kind)
    {
        ArtworkAsset? FromMetadata(MediaMetadata? meta, ArtworkKind requested)
        {
            if (meta is null) return null;
            var manual = EditorManualId(meta, requested);
            if (manual.HasValue)
            {
                return meta.Artwork.FirstOrDefault(asset => asset.Id == manual.Value);
            }
            return meta.Artwork.FirstOrDefault(asset => !asset.IsManual && asset.Kind == requested);
        }

        if (kind == ArtworkKind.Backdrop)
        {
            var targetKind = item.Kind == MediaKind.Episode ? ArtworkKind.Still : ArtworkKind.Backdrop;
            return FromMetadata(item.Metadata, targetKind)
                ?? (item.Kind == MediaKind.Episode ? FromMetadata(item.Parent?.Metadata, ArtworkKind.Backdrop) : null);
        }

        return FromMetadata(item.Metadata, ArtworkKind.Poster)
            ?? (item.Kind == MediaKind.Episode ? FromMetadata(item.Parent?.Metadata, ArtworkKind.Poster) : null);
    }

    private static Guid? EditorManualId(MediaMetadata meta, ArtworkKind kind)
    {
        var fields = MetadataPresentation.ManualFields(meta);
        return kind switch
        {
            ArtworkKind.Poster when fields.Contains("poster") => meta.ManualPosterId,
            ArtworkKind.Backdrop or ArtworkKind.Still when fields.Contains("backdrop") => meta.ManualBackdropId,
            _ => null,
        };
    }

    private async Task<CollectionImageResult?> OpenMemberAssetAsync(
        AureliaDbContext database,
        ArtworkAsset asset,
        int? width,
        CancellationToken cancellationToken)
    {
        var described = await artworkStore.DescribeAsync(asset.Id, database, cancellationToken);
        if (described is null) return null;

        if (width.HasValue && variants.OpenCached(asset.Id, described.Revision, width.Value, described.LastModified) is { } cached)
        {
            return new(cached.Stream, null, cached.ContentType, cached.ContentLength, cached.LastModified, cached.Revision, asset.Id);
        }

        var source = ArtworkStore.Open(described);
        if (source is null) return null;
        if (width.HasValue)
        {
            try
            {
                var variant = await variants.OpenAsync(asset.Id, described.Revision, width.Value, source, database, cancellationToken);
                if (variant is not null)
                {
                    await source.Stream.DisposeAsync();
                    source = variant;
                }
            }
            catch
            {
                await source.Stream.DisposeAsync();
                throw;
            }
        }
        return new(source.Stream, null, source.ContentType, source.ContentLength, source.LastModified, source.Revision, asset.Id);
    }

    private static byte[] RenderMosaic(List<SKBitmap> tiles, int targetWidth)
    {
        var width = Math.Clamp(targetWidth, 160, 1920);
        var height = (int)Math.Round(width * 1.5);
        var gap = Math.Max(2f, width * 0.01f);

        using var canvasBitmap = new SKBitmap(new SKImageInfo(width, height, SKColorType.Rgba8888, SKAlphaType.Premul));
        using (var canvas = new SKCanvas(canvasBitmap))
        {
            canvas.Clear(new SKColor(0x18, 0x1A, 0x1D));
            if (tiles.Count == 2)
            {
                var halfW = (width - gap) / 2f;
                DrawCover(canvas, tiles[0], new SKRect(0, 0, halfW, height));
                DrawCover(canvas, tiles[1], new SKRect(halfW + gap, 0, width, height));
            }
            else if (tiles.Count == 3)
            {
                var leftW = (width - gap) * 0.54f;
                var rightX = leftW + gap;
                var halfH = (height - gap) / 2f;
                DrawCover(canvas, tiles[0], new SKRect(0, 0, leftW, height));
                DrawCover(canvas, tiles[1], new SKRect(rightX, 0, width, halfH));
                DrawCover(canvas, tiles[2], new SKRect(rightX, halfH + gap, width, height));
            }
            else
            {
                var halfW = (width - gap) / 2f;
                var halfH = (height - gap) / 2f;
                DrawCover(canvas, tiles[0], new SKRect(0, 0, halfW, halfH));
                DrawCover(canvas, tiles[1], new SKRect(halfW + gap, 0, width, halfH));
                DrawCover(canvas, tiles[2], new SKRect(0, halfH + gap, halfW, height));
                DrawCover(canvas, tiles[3], new SKRect(halfW + gap, halfH + gap, width, height));
            }
        }

        using var image = SKImage.FromBitmap(canvasBitmap);
        using var data = image.Encode(SKEncodedImageFormat.Jpeg, 88);
        return data.ToArray();
    }

    private static void DrawCover(SKCanvas canvas, SKBitmap source, SKRect destination)
    {
        if (source.Width <= 0 || source.Height <= 0) return;
        var targetRatio = destination.Width / destination.Height;
        var sourceRatio = (float)source.Width / source.Height;
        SKRect src;
        if (sourceRatio > targetRatio)
        {
            var cropW = source.Height * targetRatio;
            var left = (source.Width - cropW) / 2f;
            src = new SKRect(left, 0, left + cropW, source.Height);
        }
        else
        {
            var cropH = source.Width / targetRatio;
            var top = (source.Height - cropH) / 2f;
            src = new SKRect(0, top, source.Width, top + cropH);
        }
        canvas.DrawBitmap(source, src, destination, new SKSamplingOptions(SKFilterMode.Linear));
    }

    private static byte[]? ResizeToWidth(byte[] sourceBytes, int targetWidth)
    {
        using var decoded = EditorArtworkStore.Decode(sourceBytes, allowProviderWebP: true, minimumWidth: targetWidth);
        using var oriented = EditorArtworkStore.Orient(decoded.Image, decoded.Origin);
        if (oriented.Width <= targetWidth) return null;
        var targetHeight = Math.Max(1, (int)Math.Round(oriented.Height * (targetWidth / (double)oriented.Width)));
        using var resized = new SKBitmap(new SKImageInfo(targetWidth, targetHeight, SKColorType.Rgba8888, SKAlphaType.Premul));
        using (var canvas = new SKCanvas(resized))
        {
            canvas.DrawBitmap(oriented, new SKRect(0, 0, oriented.Width, oriented.Height), new SKRect(0, 0, targetWidth, targetHeight), new SKSamplingOptions(SKFilterMode.Linear));
        }
        using var image = SKImage.FromBitmap(resized);
        using var encoded = image.Encode(SKEncodedImageFormat.Jpeg, 88);
        return encoded.ToArray();
    }

    private void TryDeleteFile(string relative)
    {
        if (string.IsNullOrWhiteSpace(relative) || Path.GetFileName(relative) != relative) return;
        var path = Path.Combine(directory, relative);
        try { if (File.Exists(path)) File.Delete(path); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    private static void ValidateKind(ArtworkKind kind)
    {
        if (kind is not ArtworkKind.Poster and not ArtworkKind.Backdrop)
        {
            throw new AccountException("invalid_artwork_kind", "Collections only support poster or backdrop artwork.", 400);
        }
    }

    public void Dispose() => mosaicLock.Dispose();
}
