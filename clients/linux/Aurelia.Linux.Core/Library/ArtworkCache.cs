using System.Security.Cryptography;
using System.Text;
using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Library;

/// <summary>
/// Artwork bytes, as the Mac app keeps them: an in-memory cache (96 MB) and a disk cache in
/// <c>$XDG_CACHE_HOME/aurelia-desktop/artwork</c> (512 MB, oldest first). Only artwork with a
/// revision goes to disk, because those bytes stay valid until the revision changes; the key
/// covers server, profile, artwork, revision and width. Requests for the same picture share one
/// download.
/// </summary>
public sealed class ArtworkCache
{
    public const long MemoryLimit = 96L * 1024 * 1024;
    public const long DiskLimit = 512L * 1024 * 1024;
    public const long LargestFile = 24L * 1024 * 1024;
    public static readonly int[] Widths = [320, 640, 1280, 1920];

    private readonly string? directory;
    private readonly Lock gate = new();
    private readonly LinkedList<(string Key, byte[] Bytes)> order = new();
    private readonly Dictionary<string, LinkedListNode<(string Key, byte[] Bytes)>> memory = [];
    private readonly Dictionary<string, Task<byte[]>> pending = [];
    private long memoryBytes;

    public ArtworkCache(string? directory) => this.directory = directory;

    /// <summary>The smallest artwork width that is at least the shown size in device pixels.</summary>
    public static int WidthFor(double pixels) => Widths.FirstOrDefault(width => width >= pixels, Widths[^1]);

    public Task<byte[]> GetAsync(LibraryClient client, ArtworkSummary artwork, int width, CancellationToken cancellation)
    {
        var key = Key(client, artwork, width);
        lock (gate)
        {
            if (memory.TryGetValue(key, out var node))
            {
                order.Remove(node);
                order.AddFirst(node);
                return Task.FromResult(node.Value.Bytes);
            }
            if (pending.TryGetValue(key, out var running)) return running;
            var load = LoadAsync(client, artwork, width, key);
            pending[key] = load;
            return load.WaitAsync(cancellation);
        }
    }

    private async Task<byte[]> LoadAsync(LibraryClient client, ArtworkSummary artwork, int width, string key)
    {
        try
        {
            var path = artwork.Revision is not null && directory is not null ? Path.Combine(directory, key + ".img") : null;
            byte[]? bytes = null;
            if (path is not null && File.Exists(path))
            {
                try
                {
                    bytes = await File.ReadAllBytesAsync(path);
                    File.SetLastWriteTimeUtc(path, DateTime.UtcNow);
                }
                catch (IOException)
                {
                    bytes = null;
                }
            }
            if (bytes is null)
            {
                bytes = await client.ArtworkAsync(artwork, width, CancellationToken.None);
                if (path is not null && bytes.Length <= LargestFile) Store(path, bytes);
            }
            Remember(key, bytes);
            return bytes;
        }
        finally
        {
            lock (gate) pending.Remove(key);
        }
    }

    private void Remember(string key, byte[] bytes)
    {
        lock (gate)
        {
            if (memory.ContainsKey(key)) return;
            memory[key] = order.AddFirst((key, bytes));
            memoryBytes += bytes.Length;
            while (memoryBytes > MemoryLimit && order.Last is { } oldest)
            {
                order.RemoveLast();
                memory.Remove(oldest.Value.Key);
                memoryBytes -= oldest.Value.Bytes.Length;
            }
        }
    }

    private void Store(string path, byte[] bytes)
    {
        try
        {
            Settings.PrivateFiles.CreateDirectory(directory!);
            var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllBytes(temporary, bytes);
            File.Move(temporary, path, overwrite: true);
            // Pruning costs a directory listing, so it runs on about one store in 64.
            if (Random.Shared.Next(64) == 0) Prune(directory!, DiskLimit);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // A full or read-only disk only costs a download next time.
        }
    }

    /// <summary>Removes the least recently used files until the folder is below 80 % of the limit.</summary>
    public static void Prune(string folder, long limit)
    {
        if (!Directory.Exists(folder)) return;
        var files = new DirectoryInfo(folder).GetFiles("*.img").OrderBy(file => file.LastWriteTimeUtc).ToList();
        var total = files.Sum(file => file.Length);
        if (total <= limit) return;
        foreach (var file in files)
        {
            if (total <= limit * 8 / 10) break;
            total -= file.Length;
            file.Delete();
        }
    }

    private static string Key(LibraryClient client, ArtworkSummary artwork, int width)
    {
        var text = $"{client.Server.ServerId}:{client.Profile.User.Id}:{artwork.Id}:r{artwork.Revision}:w{width}";
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    }
}
