using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text.Json;

namespace Aurelia.Server.Services;

public sealed record BackupManifestFile(string Name, long Length, string Sha256);
public sealed record BackupManifest(int Version, int ChunkBytes, int Iterations, string Salt, string NoncePrefix,
    Guid ServerId, DateTimeOffset CreatedAt, IReadOnlyList<BackupManifestFile> Files, bool IncludesMedia = false, bool IncludesArtwork = false);

public static class EncryptedBackupContainer
{
    private static readonly byte[] Magic = "AURBK001"u8.ToArray();
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    public const long MaximumBytes = 4L * 1024 * 1024 * 1024;
    public const int MaximumEntries = 50_000;
    private const int ChunkBytes = 1024 * 1024;
    private const int Iterations = 600_000;
    // Only the database can be large. Configuration, certificates and keys are
    // deliberately bounded before parsing them during restore validation.
    public static long MaximumEntryBytes(string name) => name == "aurelia.db" ? MaximumBytes
        : name.StartsWith("Artwork/", StringComparison.Ordinal) ? EditorArtworkStore.MaximumUploadBytes : 1_048_576;

    public static bool AllowedName(string? name) => name is "aurelia.db" or "server-settings.json" or "server-certificate.pem"
        or "server-private-key.pem" or "metadata-settings.json" or "Secrets/tmdb-token"
        || (name is not null && name.StartsWith("DataProtectionKeys/key-", StringComparison.Ordinal) && name.EndsWith(".xml", StringComparison.Ordinal)
            && Guid.TryParseExact(name["DataProtectionKeys/key-".Length..^4], "D", out _)) || ArtworkName(name);

    private static bool ArtworkName(string? name)
    {
        if (name is null || !name.StartsWith("Artwork/", StringComparison.Ordinal)) return false;
        var file = name[8..];
        var stem = file.EndsWith(".original.png", StringComparison.Ordinal) ? file[..^13]
            : file.EndsWith(".png", StringComparison.Ordinal) ? file[..^4] : "";
        return Guid.TryParseExact(stem, "N", out _);
    }

    public static async Task<BackupManifest> EncryptAsync(string directory, IReadOnlyList<string> names, Guid serverId,
        Stream destination, string passphrase, CancellationToken token)
    {
        ValidatePassphrase(passphrase);
        var files = new List<BackupManifestFile>();
        foreach (var name in names.Order(StringComparer.Ordinal))
        {
            if (!AllowedName(name)) throw new InvalidDataException("Unsupported backup entry.");
            var path = Path.Combine(directory, name);
            var info = new FileInfo(path);
            if (info.LinkTarget is not null || !info.Exists) throw new InvalidDataException("Unsafe backup entry.");
            if (info.Length > MaximumEntryBytes(name)) throw new InvalidDataException("Backup configuration exceeds the entry limit.");
            await using var input = File.OpenRead(path);
            files.Add(new(name, input.Length, Convert.ToHexString(await SHA256.HashDataAsync(input, token))));
        }
        var manifest = new BackupManifest(2, ChunkBytes, Iterations, Convert.ToBase64String(RandomNumberGenerator.GetBytes(16)),
            Convert.ToBase64String(RandomNumberGenerator.GetBytes(8)), serverId, DateTimeOffset.UtcNow, files, IncludesArtwork: names.Any(ArtworkName));
        ValidateManifest(manifest);
        var header = JsonSerializer.SerializeToUtf8Bytes(manifest, Json);
        if (header.Length > 8 * 1024 * 1024) throw new InvalidDataException("The backup manifest exceeds the format limit.");
        await destination.WriteAsync(Magic, token);
        await WriteIntAsync(destination, header.Length, token);
        await destination.WriteAsync(header, token);
        var key = Derive(passphrase, manifest);
        var plaintext = new byte[ChunkBytes];
        try
        {
            using var aes = new AesGcm(key, 16);
            var headerHash = SHA256.HashData(header);
            uint index = 0;
            var ciphertext = new byte[ChunkBytes];
            var tag = new byte[16];
            foreach (var file in files)
            {
                await using var input = File.OpenRead(Path.Combine(directory, file.Name));
                long remaining = file.Length;
                while (remaining > 0)
                {
                    var count = (int)Math.Min(ChunkBytes, remaining);
                    await input.ReadExactlyAsync(plaintext.AsMemory(0, count), token);
                    aes.Encrypt(Nonce(manifest, index), plaintext.AsSpan(0, count), ciphertext.AsSpan(0, count), tag, Aad(headerHash, index++, count));
                    await WriteIntAsync(destination, count, token);
                    await destination.WriteAsync(tag, token);
                    await destination.WriteAsync(ciphertext.AsMemory(0, count), token);
                    remaining -= count;
                }
            }
            aes.Encrypt(Nonce(manifest, index), ReadOnlySpan<byte>.Empty, Span<byte>.Empty, tag, Aad(headerHash, index, 0));
            await WriteIntAsync(destination, 0, token);
            await destination.WriteAsync(tag, token);
        }
        finally { CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(plaintext); }
        return manifest;
    }

    public static async Task<BackupManifest> DecryptAsync(Stream source, string privateStage, string passphrase, CancellationToken token)
    {
        ValidatePassphrase(passphrase);
        var magic = new byte[8];
        await source.ReadExactlyAsync(magic, token);
        if (!magic.SequenceEqual(Magic)) throw new InvalidDataException("Unsupported backup format.");
        var headerLength = await ReadIntAsync(source, token);
        if (headerLength is < 1 or > 8 * 1024 * 1024) throw new InvalidDataException("Invalid backup header.");
        var header = new byte[headerLength];
        await source.ReadExactlyAsync(header, token);
        var manifest = JsonSerializer.Deserialize<BackupManifest>(header, Json) ?? throw new InvalidDataException("Invalid backup manifest.");
        ValidateManifest(manifest);
        PrivateFilePermissions.CreatePrivateDirectory(privateStage);
        var key = Derive(passphrase, manifest);
        var plaintext = new byte[ChunkBytes];
        try
        {
            using var aes = new AesGcm(key, 16);
            var headerHash = SHA256.HashData(header);
            var ciphertext = new byte[ChunkBytes];
            var tag = new byte[16];
            uint index = 0;
            foreach (var file in manifest.Files)
            {
                var destination = Path.Combine(privateStage, file.Name);
                PrivateFilePermissions.CreatePrivateDirectory(Path.GetDirectoryName(destination)!);
                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                await using (var output = PrivateFilePermissions.OpenNewPrivateFile(destination))
                {
                    long remaining = file.Length;
                    while (remaining > 0)
                    {
                        var count = await ReadIntAsync(source, token);
                        if (count < 1 || count > Math.Min(ChunkBytes, remaining)) throw new InvalidDataException("Invalid backup block length.");
                        await source.ReadExactlyAsync(tag, token);
                        await source.ReadExactlyAsync(ciphertext.AsMemory(0, count), token);
                        aes.Decrypt(Nonce(manifest, index), ciphertext.AsSpan(0, count), tag, plaintext.AsSpan(0, count), Aad(headerHash, index++, count));
                        hash.AppendData(plaintext.AsSpan(0, count));
                        await output.WriteAsync(plaintext.AsMemory(0, count), token);
                        remaining -= count;
                    }
                    await output.FlushAsync(token);
                    output.Flush(flushToDisk: true);
                }
                if (!CryptographicOperations.FixedTimeEquals(hash.GetHashAndReset(), Convert.FromHexString(file.Sha256)))
                    throw new InvalidDataException("Backup entry integrity check failed.");
            }
            if (await ReadIntAsync(source, token) != 0) throw new InvalidDataException("Missing backup completion record.");
            await source.ReadExactlyAsync(tag, token);
            aes.Decrypt(Nonce(manifest, index), ReadOnlySpan<byte>.Empty, tag, Span<byte>.Empty, Aad(headerHash, index, 0));
            var tail = new byte[1];
            if (await source.ReadAsync(tail, token) != 0) throw new InvalidDataException("Unexpected data after backup completion.");
            return manifest;
        }
        finally { CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(plaintext); }
    }
    private static void ValidatePassphrase(string value)
    {
        if (value is null || value.Length is < 12 or > 1024) throw new InvalidDataException("Use a backup passphrase with 12 to 1024 characters.");
    }
    private static void ValidateManifest(BackupManifest value)
    {
        if (value.Version is not 1 and not 2 || value.ChunkBytes != ChunkBytes || value.Iterations != Iterations
            || value.ServerId == Guid.Empty || value.IncludesMedia || value.Version == 1 && value.IncludesArtwork
            || value.Files is null || value.Files.Count < 1 || value.Files.Count > (value.Version == 1 ? 256 : MaximumEntries) || value.Files.Any(file => file is null)
            || !value.Files.Any(file => file.Name == "aurelia.db")
            || value.Files.Select(file => file.Name).Distinct(StringComparer.Ordinal).Count() != value.Files.Count
            || value.Files.Any(file => !AllowedName(file.Name) || file.Length < 0 || file.Length > MaximumEntryBytes(file.Name) || file.Sha256 is null || file.Sha256.Length != 64 || !file.Sha256.All(char.IsAsciiHexDigit))
            || value.Files.Any(file => ArtworkName(file.Name)) != value.IncludesArtwork
            || value.Files.Sum(file => file.Length) > MaximumBytes - 16 * 1024 * 1024
            || value.Salt is null || value.NoncePrefix is null
            || Convert.FromBase64String(value.Salt).Length != 16 || Convert.FromBase64String(value.NoncePrefix).Length != 8)
            throw new InvalidDataException("The backup manifest is incompatible or unsafe.");
    }
    private static byte[] Derive(string password, BackupManifest manifest) => Rfc2898DeriveBytes.Pbkdf2(password,
        Convert.FromBase64String(manifest.Salt), manifest.Iterations, HashAlgorithmName.SHA256, 32);
    private static byte[] Nonce(BackupManifest manifest, uint index)
    {
        var result = new byte[12];
        Convert.FromBase64String(manifest.NoncePrefix).CopyTo(result, 0);
        BinaryPrimitives.WriteUInt32BigEndian(result.AsSpan(8), index);
        return result;
    }
    private static byte[] Aad(byte[] headerHash, uint index, int count)
    {
        var result = new byte[40];
        headerHash.CopyTo(result, 0);
        BinaryPrimitives.WriteUInt32BigEndian(result.AsSpan(32), index);
        BinaryPrimitives.WriteInt32BigEndian(result.AsSpan(36), count);
        return result;
    }
    private static async Task WriteIntAsync(Stream stream, int value, CancellationToken token)
    { var bytes = new byte[4]; BinaryPrimitives.WriteInt32BigEndian(bytes, value); await stream.WriteAsync(bytes, token); }
    private static async Task<int> ReadIntAsync(Stream stream, CancellationToken token)
    { var bytes = new byte[4]; await stream.ReadExactlyAsync(bytes, token); return BinaryPrimitives.ReadInt32BigEndian(bytes); }
}
