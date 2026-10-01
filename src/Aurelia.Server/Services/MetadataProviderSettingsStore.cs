using System.Text.Json;
using Aurelia.Contracts;

namespace Aurelia.Server.Services;

public sealed class MetadataProviderSettingsStore(ServerRuntimeOptions runtime)
{
    private const long DefaultArtworkLimit = 1024L * 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly object gate = new();
    private readonly string settingsPath = Path.Combine(runtime.DataDirectory, "metadata-settings.json");
    private readonly string tokenPath = Path.Combine(runtime.DataDirectory, "Secrets", "tmdb-token");

    public IReadOnlyDictionary<string, string> BackupSnapshot()
    {
        lock (gate)
        {
            var snapshot = new Dictionary<string, string>();
            if (File.Exists(settingsPath)) snapshot["metadata-settings.json"] = File.ReadAllText(settingsPath);
            if (File.Exists(tokenPath)) snapshot["Secrets/tmdb-token"] = File.ReadAllText(tokenPath);
            return snapshot;
        }
    }

    public MetadataProviderConfiguration Load()
    {
        lock (gate)
        {
            var settings = File.Exists(settingsPath)
                ? JsonSerializer.Deserialize<StoredMetadataSettings>(File.ReadAllText(settingsPath), JsonOptions)
                : null;
            var token = File.Exists(tokenPath) ? File.ReadAllText(tokenPath).Trim() : null;
            return new MetadataProviderConfiguration(
                settings?.Enabled == true && !string.IsNullOrWhiteSpace(token),
                settings?.Language is { Length: > 0 } language ? language : "en-US",
                string.IsNullOrWhiteSpace(token) ? null : token,
                settings?.ArtworkLimitBytes is > 0 ? settings.ArtworkLimitBytes : DefaultArtworkLimit);
        }
    }

    public void Save(UpdateMetadataProviderRequest request)
    {
        var language = NormalizeLanguage(request.Language);
        if (request.Enabled && string.IsNullOrWhiteSpace(request.Token) && !File.Exists(tokenPath))
        {
            throw new MetadataException("metadata_token_required", "Enter a TMDB API Read Access Token before enabling metadata.", StatusCodes.Status400BadRequest);
        }

        lock (gate)
        {
            PrivateFilePermissions.CreatePrivateDirectory(Path.GetDirectoryName(tokenPath)!);
            if (request.Token is not null)
            {
                var token = request.Token.Trim();
                if (token.Length is < 32 or > 4096 || token.Any(char.IsWhiteSpace))
                {
                    throw new MetadataException("invalid_metadata_token", "The TMDB token is not valid.", StatusCodes.Status400BadRequest);
                }

                AtomicWrite(tokenPath, token);
            }

            var current = LoadUnlocked();
            AtomicWrite(settingsPath, JsonSerializer.Serialize(
                new StoredMetadataSettings(1, request.Enabled, language, current.ArtworkLimitBytes),
                JsonOptions));
        }
    }

    public void RemoveToken()
    {
        lock (gate)
        {
            if (File.Exists(tokenPath))
            {
                File.Delete(tokenPath);
            }

            var current = LoadUnlocked();
            AtomicWrite(settingsPath, JsonSerializer.Serialize(
                new StoredMetadataSettings(1, false, current.Language, current.ArtworkLimitBytes),
                JsonOptions));
        }
    }

    private MetadataProviderConfiguration LoadUnlocked()
    {
        var settings = File.Exists(settingsPath)
            ? JsonSerializer.Deserialize<StoredMetadataSettings>(File.ReadAllText(settingsPath), JsonOptions)
            : null;
        var token = File.Exists(tokenPath) ? File.ReadAllText(tokenPath).Trim() : null;
        return new MetadataProviderConfiguration(
            settings?.Enabled == true && !string.IsNullOrWhiteSpace(token),
            settings?.Language ?? "en-US",
            token,
            settings?.ArtworkLimitBytes is > 0 ? settings.ArtworkLimitBytes : DefaultArtworkLimit);
    }

    private static string NormalizeLanguage(string language)
    {
        var normalized = language.Trim();
        if (!string.Equals(normalized, "en", StringComparison.OrdinalIgnoreCase)
            && !string.Equals(normalized, "en-US", StringComparison.OrdinalIgnoreCase))
        {
            throw new MetadataException("unsupported_metadata_language", "Build 9 supports English metadata only.", StatusCodes.Status400BadRequest);
        }

        return "en-US";
    }

    private static void AtomicWrite(string path, string contents)
    {
        PrivateFilePermissions.CreatePrivateDirectory(Path.GetDirectoryName(path)!);
        var temporaryPath = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            using (var file = PrivateFilePermissions.OpenNewPrivateFile(temporaryPath))
            {
                using var writer = new StreamWriter(file, leaveOpen: true);
                writer.Write(contents);
                writer.Flush();
                file.Flush(flushToDisk: true);
            }
            File.Move(temporaryPath, path, overwrite: true);
            PrivateFilePermissions.ProtectFile(path);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private sealed record StoredMetadataSettings(
        int Version,
        bool Enabled,
        string Language,
        long ArtworkLimitBytes);
}

public sealed record MetadataProviderConfiguration(
    bool Enabled,
    string Language,
    string? Token,
    long ArtworkLimitBytes);

public sealed class MetadataException(string code, string message, int statusCode) : Exception(message)
{
    public string Code { get; } = code;
    public int StatusCode { get; } = statusCode;
}
