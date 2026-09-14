using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

public sealed class ArtworkStore(
    ServerRuntimeOptions runtime,
    MetadataProviderSettingsStore settings,
    ITmdbClient tmdb)
{
    private readonly string artworkDirectory = Path.Combine(runtime.DataDirectory, "Artwork");

    public async Task<ArtworkAsset?> StoreAsync(
        AureliaDbContext database,
        Guid mediaId,
        ArtworkKind kind,
        string? providerPath,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(providerPath)) return null;
        var configuration = settings.Load();
        if (!configuration.Enabled || configuration.Token is null) return null;

        var existing = await database.ArtworkAssets.SingleOrDefaultAsync(
            asset => asset.MediaItemId == mediaId && asset.Kind == kind
                && (kind == ArtworkKind.Profile ? asset.ProviderPath == providerPath : true),
            cancellationToken);
        if (existing?.ProviderPath == providerPath
            && File.Exists(Path.Combine(artworkDirectory, existing.RelativeFilePath)))
        {
            return existing;
        }

        var currentBytes = await database.ArtworkAssets.SumAsync(asset => (long?)asset.ContentLength, cancellationToken) ?? 0;
        var size = kind switch
        {
            ArtworkKind.Profile => "w342",
            ArtworkKind.Poster => "w780",
            _ => "w1280",
        };
        var bytes = await tmdb.DownloadImageAsync(configuration.Token, providerPath, size, cancellationToken);
        if (currentBytes + bytes.LongLength > configuration.ArtworkLimitBytes)
        {
            throw new MetadataException("artwork_limit_reached", "Artwork storage reached its 1 GiB limit.", StatusCodes.Status507InsufficientStorage);
        }

        var contentType = ArtworkFile.ContentType(bytes);
        PrivateFilePermissions.CreatePrivateDirectory(artworkDirectory);
        var id = existing?.Id ?? Guid.NewGuid();
        var relative = id.ToString("N") + ArtworkFile.Extension(contentType);
        var destination = Path.Combine(artworkDirectory, relative);
        var temporary = destination + ".tmp";
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
            existing = new ArtworkAsset { Id = id, MediaItemId = mediaId };
            database.ArtworkAssets.Add(existing);
        }
        else if (!string.Equals(existing.RelativeFilePath, relative, StringComparison.Ordinal))
        {
            DeleteFile(existing.RelativeFilePath);
        }

        existing.Kind = kind;
        existing.ProviderPath = providerPath;
        existing.RelativeFilePath = relative;
        existing.ContentType = contentType;
        existing.ContentLength = bytes.LongLength;
        existing.CreatedAt = DateTimeOffset.UtcNow;
        return existing;
    }

    public async Task<ArtworkFileResult?> OpenAsync(Guid id, AureliaDbContext database, CancellationToken cancellationToken)
    {
        var asset = await database.ArtworkAssets.AsNoTracking().SingleOrDefaultAsync(item => item.Id == id, cancellationToken);
        if (asset is null || Path.GetFileName(asset.RelativeFilePath) != asset.RelativeFilePath) return null;
        var path = Path.Combine(artworkDirectory, asset.RelativeFilePath);
        if (!File.Exists(path)) return null;
        var info = new FileInfo(path);
        if (info.Length != asset.ContentLength || info.LinkTarget is not null) return null;
        return new ArtworkFileResult(File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read), asset.ContentType, asset.ContentLength, asset.CreatedAt);
    }

    public async Task<long> UsedBytesAsync(AureliaDbContext database, CancellationToken cancellationToken) =>
        await database.ArtworkAssets.SumAsync(asset => (long?)asset.ContentLength, cancellationToken) ?? 0;

    public async Task<int> PruneOrphansAsync(AureliaDbContext database, CancellationToken cancellationToken)
    {
        PrivateFilePermissions.CreatePrivateDirectory(artworkDirectory);
        var referenced = await database.ArtworkAssets.AsNoTracking().Select(asset => asset.RelativeFilePath).ToHashSetAsync(cancellationToken);
        var deleted = 0;
        foreach (var file in Directory.EnumerateFiles(artworkDirectory))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!referenced.Contains(Path.GetFileName(file)))
            {
                File.Delete(file);
                deleted++;
            }
        }
        return deleted;
    }

    private void DeleteFile(string relative)
    {
        if (Path.GetFileName(relative) != relative) return;
        var path = Path.Combine(artworkDirectory, relative);
        if (File.Exists(path)) File.Delete(path);
    }
}

public sealed record ArtworkFileResult(Stream Stream, string ContentType, long ContentLength, DateTimeOffset LastModified);
