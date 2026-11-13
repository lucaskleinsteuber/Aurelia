using System.Security.Cryptography;
using System.Text;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Settings;

namespace Aurelia.Linux.Core.Library;

/// <summary>
/// Bounded memory and disk cache for wish posters fetched via the Aurelia server proxy.
/// Keeps raw poster bytes within configurable limits so scrolling many wishes stays fast without unbounded RAM/disk growth.
/// </summary>
public sealed class WishPosterCache
{
    public const long DefaultMemoryLimit = 24L * 1024 * 1024;
    public const long DefaultDiskLimit = 64L * 1024 * 1024;
    public const int MaxMemoryEntries = 150;
    public const int MaxFailedEntries = 128;

    private readonly string? directory;
    private readonly long memoryLimit;
    private readonly long diskLimit;
    private readonly object gate = new();
    private readonly Dictionary<string, byte[]> memory = [];
    private readonly LinkedList<string> lru = new();
    private readonly Dictionary<string, Task<byte[]?>> inflight = [];
    private readonly HashSet<string> failed = [];
    private readonly Queue<string> failedOrder = new();
    private long memoryBytes;
    private long writtenSincePrune;

    public WishPosterCache(string? directory, long memoryLimit = DefaultMemoryLimit, long diskLimit = DefaultDiskLimit)
    {
        this.directory = string.IsNullOrWhiteSpace(directory) ? null : directory;
        this.memoryLimit = Math.Max(1024, memoryLimit);
        this.diskLimit = Math.Max(1024, diskLimit);
    }

    public int MemoryEntryCount
    {
        get { lock (gate) return memory.Count; }
    }

    public long MemoryByteCount
    {
        get { lock (gate) return memoryBytes; }
    }

    public byte[]? TryMemory(LibraryClient client, string? posterPath)
    {
        if (string.IsNullOrWhiteSpace(posterPath)) return null;
        var key = Key(client, posterPath);
        lock (gate)
        {
            if (!memory.TryGetValue(key, out var bytes)) return null;
            TouchLruLocked(key);
            return bytes;
        }
    }

    public Task<byte[]?> LoadAsync(LibraryClient client, string? posterPath, CancellationToken cancellation)
    {
        if (string.IsNullOrWhiteSpace(posterPath)) return Task.FromResult<byte[]?>(null);
        var key = Key(client, posterPath);
        lock (gate)
        {
            if (memory.TryGetValue(key, out var cached))
            {
                TouchLruLocked(key);
                return Task.FromResult<byte[]?>(cached);
            }
            if (failed.Contains(key)) return Task.FromResult<byte[]?>(null);
            if (inflight.TryGetValue(key, out var existing)) return existing;

            var task = FetchAsync(client, posterPath, key, cancellation);
            inflight[key] = task;
            return task;
        }
    }

    public void PruneDiskNow()
    {
        if (directory is null) return;
        ArtworkCache.Prune(directory, diskLimit);
    }

    private async Task<byte[]?> FetchAsync(LibraryClient client, string posterPath, string key, CancellationToken cancellation)
    {
        try
        {
            var disk = ReadFromDisk(key);
            if (disk is { Length: > 0 })
            {
                StoreInMemory(key, disk);
                return disk;
            }
            var bytes = await client.WishPosterAsync(posterPath, cancellation);
            if (bytes is not { Length: > 0 })
            {
                RecordFailure(key);
                return null;
            }
            StoreInMemory(key, bytes);
            WriteToDisk(key, bytes);
            return bytes;
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        catch (AureliaApiException)
        {
            RecordFailure(key);
            return null;
        }
        finally
        {
            lock (gate) inflight.Remove(key);
        }
    }

    private void StoreInMemory(string key, byte[] bytes)
    {
        if (bytes.LongLength > memoryLimit) return;
        lock (gate)
        {
            if (memory.TryGetValue(key, out var previous))
            {
                memoryBytes -= previous.LongLength;
                lru.Remove(key);
            }
            memory[key] = bytes;
            memoryBytes += bytes.LongLength;
            lru.AddFirst(key);
            while ((memoryBytes > memoryLimit || memory.Count > MaxMemoryEntries) && lru.Last is { } oldest)
            {
                var victim = oldest.Value;
                lru.RemoveLast();
                if (memory.Remove(victim, out var removed))
                    memoryBytes -= removed.LongLength;
            }
        }
    }

    private void TouchLruLocked(string key)
    {
        lru.Remove(key);
        lru.AddFirst(key);
    }

    private void RecordFailure(string key)
    {
        lock (gate)
        {
            if (!failed.Add(key)) return;
            failedOrder.Enqueue(key);
            while (failed.Count > MaxFailedEntries && failedOrder.TryDequeue(out var oldest))
                failed.Remove(oldest);
        }
    }

    private byte[]? ReadFromDisk(string key)
    {
        if (directory is null) return null;
        var path = Path.Combine(directory, key + ".img");
        if (!File.Exists(path)) return null;
        try
        {
            var bytes = File.ReadAllBytes(path);
            File.SetLastWriteTimeUtc(path, DateTime.UtcNow);
            return bytes;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private void WriteToDisk(string key, byte[] bytes)
    {
        if (directory is null || bytes.LongLength > diskLimit) return;
        try
        {
            PrivateFiles.CreateDirectory(directory);
            var path = Path.Combine(directory, key + ".img");
            var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllBytes(temporary, bytes);
            File.Move(temporary, path, overwrite: true);
            bool shouldPrune;
            lock (gate)
            {
                writtenSincePrune += bytes.LongLength;
                shouldPrune = writtenSincePrune >= Math.Max(1024, diskLimit / 4);
                if (shouldPrune) writtenSincePrune = 0;
            }
            if (shouldPrune) ArtworkCache.Prune(directory, diskLimit);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
        }
    }

    private static string Key(LibraryClient client, string posterPath)
    {
        var raw = $"{client.Server.ServerId}:{posterPath}";
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(raw)));
    }
}
