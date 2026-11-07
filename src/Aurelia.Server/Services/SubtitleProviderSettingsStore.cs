using System.Text.Json;
using Aurelia.Contracts;

namespace Aurelia.Server.Services;

public sealed record SubtitleProviderConfiguration(
    bool Enabled,
    IReadOnlyList<string> Languages,
    bool Automatic,
    string? ApiKey,
    string? AccountName,
    string? AccountPassword);

/// <summary>
/// The subtitle download settings in <c>subtitle-settings.json</c>; the OpenSubtitles API key and
/// account live in private files under <c>Secrets/</c> and are never sent back to a client.
/// </summary>
public sealed class SubtitleProviderSettingsStore(ServerRuntimeOptions runtime)
{
    public const int MaximumLanguages = 5;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly object gate = new();
    private string SettingsPath => Path.Combine(runtime.DataDirectory, "subtitle-settings.json");
    private string KeyPath => Path.Combine(runtime.DataDirectory, "Secrets", "opensubtitles-key");
    private string AccountPath => Path.Combine(runtime.DataDirectory, "Secrets", "opensubtitles-account");

    public SubtitleProviderConfiguration Load()
    {
        lock (gate)
        {
            var settings = Read<StoredSubtitleSettings>(SettingsPath);
            var key = File.Exists(KeyPath) ? File.ReadAllText(KeyPath).Trim() : null;
            var account = Read<StoredAccount>(AccountPath);
            var hasKey = !string.IsNullOrWhiteSpace(key);
            return new SubtitleProviderConfiguration(
                settings?.Enabled == true && hasKey,
                settings?.Languages is { Count: > 0 } languages ? languages : ["en"],
                settings?.Automatic == true,
                hasKey ? key : null,
                account?.Name,
                account?.Password);
        }
    }

    public void Save(UpdateSubtitleProviderRequest request)
    {
        var languages = NormalizeLanguages(request.Languages);
        lock (gate)
        {
            if (request.ApiKey is not null)
            {
                var key = request.ApiKey.Trim();
                if (key.Length is < 16 or > 256 || key.Any(character => !char.IsAsciiLetterOrDigit(character)))
                    throw new MetadataException("invalid_subtitle_key", "The OpenSubtitles API key is not valid.", StatusCodes.Status400BadRequest);
                AtomicWrite(KeyPath, key);
            }
            if (request.Enabled && !File.Exists(KeyPath))
                throw new MetadataException("subtitle_key_required", "Enter an OpenSubtitles API key before turning on subtitle downloads.", StatusCodes.Status400BadRequest);
            if (request.AccountName is not null || request.AccountPassword is not null)
            {
                var name = request.AccountName?.Trim() ?? "";
                var password = request.AccountPassword ?? "";
                if (name.Length is < 1 or > 100 || password.Length is < 1 or > 256)
                    throw new MetadataException("invalid_subtitle_account", "Enter both the OpenSubtitles user name and password.", StatusCodes.Status400BadRequest);
                AtomicWrite(AccountPath, JsonSerializer.Serialize(new StoredAccount(name, password), JsonOptions));
            }
            AtomicWrite(SettingsPath, JsonSerializer.Serialize(new StoredSubtitleSettings(1, request.Enabled, languages, request.Automatic), JsonOptions));
        }
    }

    public void RemoveKey()
    {
        lock (gate)
        {
            if (File.Exists(KeyPath)) File.Delete(KeyPath);
            var settings = Read<StoredSubtitleSettings>(SettingsPath);
            AtomicWrite(SettingsPath, JsonSerializer.Serialize(
                new StoredSubtitleSettings(1, false, settings?.Languages ?? ["en"], settings?.Automatic == true), JsonOptions));
        }
    }

    public void RemoveAccount()
    {
        lock (gate)
        {
            if (File.Exists(AccountPath)) File.Delete(AccountPath);
        }
    }

    /// <summary>"DE", "de-DE" and "ger" all become "de"; unknown codes are refused.</summary>
    public static IReadOnlyList<string> NormalizeLanguages(IReadOnlyList<string>? languages)
    {
        var result = new List<string>();
        foreach (var raw in languages ?? [])
        {
            var token = (raw ?? "").Trim().Split('-', '_')[0];
            if (!SidecarSubtitles.TryParseLanguage(token, out var language) || language.Length != 2)
                throw new MetadataException("invalid_subtitle_language", $"“{raw}” is not a language code such as de or en.", StatusCodes.Status400BadRequest);
            if (!result.Contains(language)) result.Add(language);
        }
        if (result.Count == 0)
            throw new MetadataException("subtitle_language_required", "Choose at least one subtitle language.", StatusCodes.Status400BadRequest);
        if (result.Count > MaximumLanguages)
            throw new MetadataException("too_many_subtitle_languages", $"Choose at most {MaximumLanguages} subtitle languages.", StatusCodes.Status400BadRequest);
        return result;
    }

    private static T? Read<T>(string path) where T : class
    {
        if (!File.Exists(path)) return null;
        try { return JsonSerializer.Deserialize<T>(File.ReadAllText(path), JsonOptions); }
        catch (JsonException) { return null; }
    }

    internal static void AtomicWrite(string path, string contents)
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
            if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
        }
    }

    private sealed record StoredSubtitleSettings(int Version, bool Enabled, IReadOnlyList<string> Languages, bool Automatic);
    private sealed record StoredAccount(string Name, string Password);
}
