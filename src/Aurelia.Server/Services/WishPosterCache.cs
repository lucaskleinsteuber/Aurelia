using System.Security.Cryptography;
using System.Text;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services;

/// <summary>
/// Downloads and caches TMDB wish posters in a bounded folder under the server data directory.
/// Only paths returned by recent wish searches or stored on saved wishes are served.
/// </summary>
public sealed class WishPosterCache
{
    public const long DefaultMaximumCacheBytes = 64L * 1024 * 1024;
    private const int MaxRecentPaths = 2048;
    private const int MaxPosterBytes = 5 * 1024 * 1024;
    private static readonly string[] Extensions = [".jpg", ".png", ".webp"];

    private readonly string directory;
    private readonly MetadataProviderSettingsStore settings;
    private readonly ITmdbClient tmdb;
    private readonly TimeProvider clock;
    private readonly long maximumCacheBytes;
    private readonly object recentGate = new();
    private readonly Dictionary<string, LinkedListNode<string>> recentMap = new(StringComparer.Ordinal);
    private readonly LinkedList<string> recentOrder = new();
    private readonly object cacheGate = new();
    private long usedBytes;
    private DateTimeOffset nextPrune = DateTimeOffset.MinValue;

    public WishPosterCache(
        ServerRuntimeOptions runtime,
        MetadataProviderSettingsStore settings,
        ITmdbClient tmdb,
        TimeProvider clock)
        : this(runtime, settings, tmdb, clock, DefaultMaximumCacheBytes)
    {
    }

    internal WishPosterCache(
        ServerRuntimeOptions runtime,
        MetadataProviderSettingsStore settings,
        ITmdbClient tmdb,
        TimeProvider clock,
        long maximumCacheBytes)
    {
        directory = Path.Combine(runtime.DataDirectory, "WishPosters");
        this.settings = settings;
        this.tmdb = tmdb;
        this.clock = clock;
        this.maximumCacheBytes = maximumCacheBytes;
    }

    public static bool IsSafePosterPath(string? path) =>
        path is { Length: >= 3 and <= 200 }
        && path.StartsWith('/')
        && !path.Contains("..", StringComparison.Ordinal)
        && !path.Contains("//", StringComparison.Ordinal)
        && path.All(character => char.IsLetterOrDigit(character) || character is '/' or '_' or '-' or '.');

    public static string NormalizeSize(int? width) => width switch
    {
        null or <= 0 => "w342",
        <= 400 => "w342",
        <= 900 => "w780",
        _ => "w1280",
    };

    public static string? BuildPosterUrl(string? path, int width = 342) =>
        IsSafePosterPath(path) ? $"/api/v1/wishes/poster?path={Uri.EscapeDataString(path!)}&width={width}" : null;

    public void AllowRecent(IEnumerable<string?> paths)
    {
        lock (recentGate)
        {
            foreach (var raw in paths)
            {
                if (!IsSafePosterPath(raw)) continue;
                var path = raw!;
                if (recentMap.TryGetValue(path, out var existing))
                {
                    recentOrder.Remove(existing);
                    recentOrder.AddFirst(existing);
                    continue;
                }

                var node = recentOrder.AddFirst(path);
                recentMap[path] = node;
                while (recentOrder.Count > MaxRecentPaths && recentOrder.Last is { } oldest)
                {
                    recentOrder.RemoveLast();
                    recentMap.Remove(oldest.Value);
                }
            }
        }
    }

    public async Task<ArtworkFileResult?> OpenAsync(
        string? rawPath,
        int? width,
        AureliaDbContext database,
        CancellationToken cancellationToken)
    {
        if (!IsSafePosterPath(rawPath)) return null;
        var path = rawPath!;
        if (!IsAllowed(path) && !await database.Wishes.AsNoTracking().AnyAsync(wish => wish.PosterPath == path, cancellationToken))
            return null;

        var size = NormalizeSize(width);
        var stem = Stem(size, path);
        if (OpenCached(stem) is { } cached)
            return cached;

        var configuration = settings.Load();
        if (!configuration.Enabled || string.IsNullOrWhiteSpace(configuration.Token))
            return null;

        byte[] bytes;
        try
        {
            bytes = await tmdb.DownloadImageAsync(configuration.Token, path, size, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception error) when (error is HttpRequestException or MetadataException or TaskCanceledException or InvalidDataException)
        {
            return null;
        }

        if (bytes.Length is <= 0 or > MaxPosterBytes || !ArtworkFile.IsSupported(bytes))
            return null;

        var contentType = ArtworkFile.ContentType(bytes);
        var extension = ArtworkFile.Extension(contentType);
        var now = clock.GetUtcNow();
        Store(stem, extension, bytes, now);
        return new ArtworkFileResult(new MemoryStream(bytes, writable: false), contentType, bytes.LongLength, now);
    }

    private bool IsAllowed(string path)
    {
        lock (recentGate) return recentMap.ContainsKey(path);
    }

    private static string Stem(string size, string path) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes($"{size}:{path}")));

    private ArtworkFileResult? OpenCached(string stem)
    {
        if (!Directory.Exists(directory)) return null;
        var now = clock.GetUtcNow().UtcDateTime;
        foreach (var extension in Extensions)
        {
            var filePath = Path.Combine(directory, stem + extension);
            var info = new FileInfo(filePath);
            if (!info.Exists || info.LinkTarget is not null || info.Length <= 0) continue;
            try
            {
                if (now - info.LastWriteTimeUtc > TimeSpan.FromMinutes(1))
                    info.LastWriteTimeUtc = now;
                var stream = File.Open(filePath, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
                return new ArtworkFileResult(stream, ContentTypeForExtension(extension), info.Length, new DateTimeOffset(info.LastWriteTimeUtc, TimeSpan.Zero));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                return null;
            }
        }
        return null;
    }

    private void Store(string stem, string extension, byte[] bytes, DateTimeOffset now)
    {
        if (bytes.LongLength > maximumCacheBytes) return;
        try
        {
            PrivateFilePermissions.CreatePrivateDirectory(directory);
            var target = Path.Combine(directory, stem + extension);
            var temporary = Path.Combine(directory, $"{stem}.{Guid.NewGuid():N}.pending");
            try
            {
                using (var output = PrivateFilePermissions.OpenNewPrivateFile(temporary))
                    output.Write(bytes);

                lock (cacheGate)
                {
                    if (nextPrune <= now) PruneLocked(0, now);
                    if (usedBytes + bytes.LongLength > maximumCacheBytes) PruneLocked(bytes.LongLength, now);
                    if (usedBytes + bytes.LongLength <= maximumCacheBytes)
                    {
                        var replacedLength = File.Exists(target) ? new FileInfo(target).Length : 0;
                        File.Move(temporary, target, overwrite: true);
                        File.SetLastWriteTimeUtc(target, now.UtcDateTime);
                        usedBytes = Math.Max(0, usedBytes - replacedLength) + bytes.LongLength;
                    }
                }
            }
            finally
            {
                if (File.Exists(temporary)) File.Delete(temporary);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // A cache write error should never fail a wish poster response.
        }
    }

    // Called with cacheGate held.
    private void PruneLocked(long requiredBytes, DateTimeOffset now)
    {
        if (!Directory.Exists(directory))
        {
            usedBytes = 0;
            return;
        }

        var files = Directory.EnumerateFiles(directory)
            .Select(path => new FileInfo(path))
            .Where(file => file.LinkTarget is null)
            .OrderBy(file => file.LastWriteTimeUtc)
            .ToList();
        usedBytes = files.Sum(file => file.Length);
        var stalePendingCutoff = now.UtcDateTime.AddMinutes(-5);
        foreach (var file in files)
        {
            var isStalePending = file.Extension == ".pending" && file.LastWriteTimeUtc < stalePendingCutoff;
            var exceedsCap = file.Extension != ".pending" && usedBytes + requiredBytes > maximumCacheBytes;
            if (!isStalePending && !exceedsCap) continue;
            var length = file.Length;
            file.Delete();
            usedBytes = Math.Max(0, usedBytes - length);
        }
        nextPrune = now.AddMinutes(1);
    }

    private static string ContentTypeForExtension(string extension) => extension switch
    {
        ".png" => "image/png",
        ".webp" => "image/webp",
        _ => "image/jpeg",
    };
}
