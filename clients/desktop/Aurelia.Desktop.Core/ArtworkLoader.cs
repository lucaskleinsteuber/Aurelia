using System.Collections.Concurrent;
using Aurelia.Contracts;

namespace Aurelia.Desktop.Core;

/// <summary>
/// Artwork bytes for posters and backdrops: from this computer's cache when present, else from
/// the server, then kept for the next start. Requests for the same picture share one download.
/// </summary>
public sealed class ArtworkLoader(ILibraryApi api, ArtworkDiskCache? disk) : IDisposable
{
    private readonly ConcurrentDictionary<string, Task<byte[]?>> inFlight = new(StringComparer.Ordinal);
    private readonly SemaphoreSlim downloads = new(6);

    public void Dispose() => downloads.Dispose();

    public static string Key(ArtworkSummary artwork, int width) =>
        $"{artwork.Id:N}-r{artwork.Revision ?? 0}-w{LibraryClient.ArtworkWidth(width)}";

    public Task<byte[]?> LoadAsync(ArtworkSummary artwork, int width, CancellationToken cancellation = default)
    {
        var key = Key(artwork, width);
        return inFlight.GetOrAdd(key, _ => LoadUncachedAsync(artwork, width, key, cancellation));
    }

    private async Task<byte[]?> LoadUncachedAsync(ArtworkSummary artwork, int width, string key, CancellationToken cancellation)
    {
        try
        {
            if (disk?.Read(key) is { } cached) return cached;
            await downloads.WaitAsync(cancellation);
            try
            {
                var bytes = await api.ArtworkAsync(artwork, width, cancellation);
                disk?.Write(key, bytes);
                return bytes;
            }
            finally
            {
                downloads.Release();
            }
        }
        catch (Exception error) when (error is AureliaApiException or OperationCanceledException or IOException)
        {
            return null;
        }
        finally
        {
            inFlight.TryRemove(key, out _);
        }
    }
}

/// <summary>Artwork files in this app's data folder, oldest removed first beyond the size limit.</summary>
public sealed class ArtworkDiskCache
{
    private readonly string directory;
    private readonly long limitBytes;
    private int writesSincePrune;

    public ArtworkDiskCache(string directory, long limitBytes = 400L * 1024 * 1024)
    {
        this.directory = directory;
        this.limitBytes = limitBytes;
    }

    public static ArtworkDiskCache ForServer(Guid serverId) =>
        new(Path.Combine(DesktopPaths.DataDirectory, "Artwork", serverId.ToString("N")));

    public byte[]? Read(string key)
    {
        var path = PathFor(key);
        try
        {
            if (!File.Exists(path)) return null;
            File.SetLastAccessTimeUtc(path, DateTime.UtcNow);
            return File.ReadAllBytes(path);
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }

    public void Write(string key, byte[] bytes)
    {
        try
        {
            SecretFiles.WriteAtomically(PathFor(key), bytes);
            if (Interlocked.Increment(ref writesSincePrune) % 50 == 0) Prune();
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    public void Prune()
    {
        if (!Directory.Exists(directory)) return;
        var files = new DirectoryInfo(directory).GetFiles("*.img").OrderByDescending(file => file.LastAccessTimeUtc).ToList();
        long total = 0;
        foreach (var file in files)
        {
            total += file.Length;
            if (total > limitBytes)
            {
                try { file.Delete(); }
                catch (IOException) { }
            }
        }
    }

    private string PathFor(string key)
    {
        if (key.Length > 120 || key.Any(character => !(char.IsAsciiLetterOrDigit(character) || character == '-')))
            throw new ArgumentException("Invalid artwork key.", nameof(key));
        return Path.Combine(directory, key + ".img");
    }
}
