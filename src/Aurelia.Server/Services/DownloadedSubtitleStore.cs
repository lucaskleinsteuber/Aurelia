using System.Globalization;
using System.Text.Json;
using Aurelia.Contracts;

namespace Aurelia.Server.Services;

public sealed record StoredSubtitle(
    Guid Id,
    string Language,
    bool HearingImpaired,
    bool Forced,
    string Provider,
    string ProviderFileId,
    string? Release,
    DateTimeOffset DownloadedAt,
    bool Automatic)
{
    public DownloadedSubtitle Describe() => new(Id, Language, DownloadedSubtitleStore.TrackTitle(this), HearingImpaired, Forced, Provider, Release, DownloadedAt, Automatic);
}

/// <summary>
/// Downloaded subtitles in the server's data folder (<c>Subtitles/&lt;title&gt;/</c>), never in
/// the media folder: an index per title plus one SubRip file per subtitle. The automatic download
/// remembers which titles and languages it already looked at in <c>Subtitles/automatic.json</c>.
/// </summary>
public sealed class DownloadedSubtitleStore(ServerRuntimeOptions runtime)
{
    public const int MaximumPerTitle = 12;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly object gate = new();

    private string Root => Path.Combine(runtime.DataDirectory, "Subtitles");
    private string Folder(Guid mediaId) => Path.Combine(Root, mediaId.ToString("N"));
    private string IndexPath(Guid mediaId) => Path.Combine(Folder(mediaId), "index.json");
    private string FilePath(Guid mediaId, Guid id) => Path.Combine(Folder(mediaId), id.ToString("N") + ".srt");
    private string CheckedPath => Path.Combine(Root, "automatic.json");

    public IReadOnlyList<StoredSubtitle> List(Guid mediaId)
    {
        lock (gate) return ReadIndex(mediaId);
    }

    public int Count()
    {
        lock (gate)
        {
            if (!Directory.Exists(Root)) return 0;
            return Directory.EnumerateDirectories(Root).Sum(folder => Directory.EnumerateFiles(folder, "*.srt").Count());
        }
    }

    public StoredSubtitle Add(Guid mediaId, StoredSubtitle subtitle, byte[] content)
    {
        lock (gate)
        {
            var entries = ReadIndex(mediaId).ToList();
            var same = entries.FirstOrDefault(entry => entry.Provider == subtitle.Provider && entry.ProviderFileId == subtitle.ProviderFileId);
            if (same is not null) return same;
            if (entries.Count >= MaximumPerTitle)
                throw new MetadataException("too_many_subtitles", $"A title can keep at most {MaximumPerTitle} downloaded subtitles. Remove one first.", StatusCodes.Status409Conflict);
            PrivateFilePermissions.CreatePrivateDirectory(Root);
            PrivateFilePermissions.CreatePrivateDirectory(Folder(mediaId));
            var path = FilePath(mediaId, subtitle.Id);
            using (var file = PrivateFilePermissions.OpenNewPrivateFile(path))
            {
                file.Write(content);
                file.Flush(flushToDisk: true);
            }
            entries.Add(subtitle);
            WriteIndex(mediaId, entries);
            return subtitle;
        }
    }

    /// <summary>Puts subtitles written from speech in place of earlier ones in the same language.</summary>
    public StoredSubtitle Replace(Guid mediaId, StoredSubtitle subtitle, byte[] content)
    {
        lock (gate)
        {
            foreach (var old in ReadIndex(mediaId).Where(entry => entry.Provider == subtitle.Provider && entry.Language == subtitle.Language))
                Remove(mediaId, old.Id);
            return Add(mediaId, subtitle, content);
        }
    }

    public bool Remove(Guid mediaId, Guid id)
    {
        lock (gate)
        {
            var entries = ReadIndex(mediaId).ToList();
            if (entries.RemoveAll(entry => entry.Id == id) == 0) return false;
            var path = FilePath(mediaId, id);
            if (File.Exists(path)) File.Delete(path);
            if (entries.Count == 0) Directory.Delete(Folder(mediaId), recursive: true);
            else WriteIndex(mediaId, entries);
            return true;
        }
    }

    /// <summary>The SubRip file of one downloaded subtitle, or null when it is gone.</summary>
    public string? SubtitlePath(Guid mediaId, Guid id)
    {
        lock (gate)
        {
            var path = FilePath(mediaId, id);
            return ReadIndex(mediaId).Any(entry => entry.Id == id) && File.Exists(path) ? path : null;
        }
    }

    /// <summary>Removes the subtitles of titles that are no longer in the library.</summary>
    public int Prune(IReadOnlySet<Guid> known)
    {
        lock (gate)
        {
            if (!Directory.Exists(Root)) return 0;
            var removed = 0;
            foreach (var folder in Directory.EnumerateDirectories(Root))
            {
                if (Guid.TryParseExact(Path.GetFileName(folder), "N", out var id) && known.Contains(id)) continue;
                if (new DirectoryInfo(folder).LinkTarget is not null) continue;
                Directory.Delete(folder, recursive: true);
                removed++;
            }
            var checkedTitles = ReadChecked();
            if (checkedTitles.Keys.Any(id => !known.Contains(id)))
                WriteChecked(checkedTitles.Where(pair => known.Contains(pair.Key)).ToDictionary());
            return removed;
        }
    }

    /// <summary>When the automatic download last looked for this language, for this exact file.</summary>
    public DateTimeOffset? LastChecked(Guid mediaId, string fileKey, string language)
    {
        lock (gate)
        {
            return ReadChecked().TryGetValue(mediaId, out var entry) && entry.FileKey == fileKey
                && entry.Languages.TryGetValue(language, out var at) ? at : null;
        }
    }

    public void MarkChecked(Guid mediaId, string fileKey, string language, DateTimeOffset at)
    {
        lock (gate)
        {
            var all = ReadChecked();
            var entry = all.TryGetValue(mediaId, out var current) && current.FileKey == fileKey
                ? current : new CheckedTitle(fileKey, []);
            entry.Languages[language] = at;
            all[mediaId] = entry;
            WriteChecked(all);
        }
    }

    public static string TrackTitle(StoredSubtitle subtitle)
    {
        string name;
        try { name = CultureInfo.GetCultureInfo(subtitle.Language).EnglishName; }
        catch (CultureNotFoundException) { name = subtitle.Language; }
        if (subtitle.Forced) name += " (Forced)";
        if (subtitle.HearingImpaired) name += " (SDH)";
        return name + (subtitle.Provider == SubtitleDownloadService.SpeechProviderName ? " · From Speech" : " · Downloaded");
    }

    private List<StoredSubtitle> ReadIndex(Guid mediaId)
    {
        var path = IndexPath(mediaId);
        if (!File.Exists(path)) return [];
        try { return JsonSerializer.Deserialize<List<StoredSubtitle>>(File.ReadAllText(path), JsonOptions) ?? []; }
        catch (JsonException) { return []; }
    }

    private void WriteIndex(Guid mediaId, List<StoredSubtitle> entries) =>
        SubtitleProviderSettingsStore.AtomicWrite(IndexPath(mediaId), JsonSerializer.Serialize(entries, JsonOptions));

    private Dictionary<Guid, CheckedTitle> ReadChecked()
    {
        if (!File.Exists(CheckedPath)) return [];
        try { return JsonSerializer.Deserialize<Dictionary<Guid, CheckedTitle>>(File.ReadAllText(CheckedPath), JsonOptions) ?? []; }
        catch (JsonException) { return []; }
    }

    private void WriteChecked(Dictionary<Guid, CheckedTitle> all) =>
        SubtitleProviderSettingsStore.AtomicWrite(CheckedPath, JsonSerializer.Serialize(all, JsonOptions));

    private sealed record CheckedTitle(string FileKey, Dictionary<string, DateTimeOffset> Languages);
}
