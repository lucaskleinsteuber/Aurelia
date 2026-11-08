using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Settings;

namespace Aurelia.Linux.Core.Playback;

/// <summary>A downloaded subtitle file beside a downloaded title.</summary>
public sealed record OfflineSubtitle(int Index, string? Language, string? Title, bool IsForced, bool IsSdh, string FileName);

/// <summary>
/// A title downloaded to this computer to watch without the server (owner's decision,
/// 07.11.2026): the original file, streamed once through a normal playback ticket and kept in
/// this app's data folder until someone removes it. Progress watched offline goes back later.
/// </summary>
public sealed record OfflineTitle(
    Guid Id,
    Guid ServerId,
    Guid UserId,
    string Title,
    string? Subtitle,
    MediaKind Kind,
    string FileName,
    string ContentType,
    long Bytes,
    DateTimeOffset DownloadedAt,
    long PositionMilliseconds,
    long DurationMilliseconds,
    bool IsCompleted,
    DateTimeOffset? ProgressSavedAt,
    bool ProgressDirty,
    IReadOnlyList<OfflineSubtitle> Subtitles,
    long? ServerRevision = null,
    // What the Downloads page shows besides the file, as on the Mac. Downloads made before these
    // existed get them the next time their profile opens Downloads while the server answers.
    string? Overview = null,
    int? Year = null,
    IReadOnlyList<string>? Genres = null,
    Guid? ParentId = null,
    string? ParentTitle = null,
    int? SeasonNumber = null,
    int? EpisodeNumber = null,
    string? PosterFile = null,
    string? BackdropFile = null,
    string? SeriesPosterFile = null)
{
    public bool HasArtwork => PosterFile is not null || BackdropFile is not null;

    /// <summary>A catalog card for the player, built from what was saved.</summary>
    public CatalogItemSummary Item() => new(Id, Kind, Title, null, Year, Overview, Genres ?? [], null, null, MediaAvailability.Available, false,
        new PlaybackProgressResponse(Id, PositionMilliseconds, DurationMilliseconds, IsCompleted, null, null), DownloadedAt,
        ParentTitle, SeasonNumber, EpisodeNumber, ParentId);

    /// <summary>This title with the description and artwork of <paramref name="details"/>, keeping its own progress.</summary>
    internal OfflineTitle WithDetailsOf(OfflineTitle details) => this with
    {
        Overview = details.Overview,
        Year = details.Year,
        Genres = details.Genres,
        ParentId = details.ParentId,
        ParentTitle = details.ParentTitle,
        SeasonNumber = details.SeasonNumber,
        EpisodeNumber = details.EpisodeNumber,
        PosterFile = details.PosterFile ?? PosterFile,
        BackdropFile = details.BackdropFile ?? BackdropFile,
        SeriesPosterFile = details.SeriesPosterFile ?? SeriesPosterFile,
    };
}

/// <summary>The downloads on this computer, their files and the ones still loading.</summary>
public sealed class OfflineDownloads
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private readonly object gate = new();
    private readonly Dictionary<Guid, CancellationTokenSource> running = [];
    private List<OfflineTitle> titles = [];
    private readonly Dictionary<Guid, double> active = [];
    private readonly Dictionary<Guid, string> activeNames = [];

    public OfflineDownloads(string root)
    {
        Root = root;
        Load();
    }

    public string Root { get; }

    /// <summary>Raised (on any thread) when titles or download progress change.</summary>
    public event Action? Changed;

    public string? Error { get; private set; }

    public IReadOnlyList<OfflineTitle> Titles { get { lock (gate) return [.. titles]; } }

    public IReadOnlyDictionary<Guid, double> Active { get { lock (gate) return new Dictionary<Guid, double>(active); } }

    /// <summary>The name of a title downloading now, for the Downloads page.</summary>
    public string? ActiveName(Guid id) { lock (gate) return activeNames.GetValueOrDefault(id); }

    public long TotalBytes => Titles.Sum(title => title.Bytes);

    public OfflineTitle? Find(Guid id) => Titles.FirstOrDefault(title => title.Id == id);

    public IReadOnlyList<OfflineTitle> For(Guid serverId, Guid userId) =>
        [.. Titles.Where(title => title.ServerId == serverId && title.UserId == userId).OrderByDescending(title => title.DownloadedAt)];

    public string Folder(Guid id) => Path.Combine(Root, id.ToString("N"));

    public string FileOf(OfflineTitle title) => Path.Combine(Folder(title.Id), title.FileName);

    /// <summary>Downloads a movie or episode with the playback client of the open profile.</summary>
    public async Task DownloadAsync(PlaybackClient client, CatalogItemSummary item, string? subtitle, CatalogItemSummary? series = null)
    {
        if (item.Kind is not (MediaKind.Movie or MediaKind.Episode)) return;
        if (Find(item.Id) is { } existing)
        {
            // One copy per title on this computer: say so, rather than doing nothing.
            if (existing.UserId != client.Library.Profile.User.Id)
            {
                Error = $"{item.Title} is already downloaded on this computer by another profile.";
                Changed?.Invoke();
            }
            return;
        }
        var cancel = new CancellationTokenSource();
        lock (gate)
        {
            if (!running.TryAdd(item.Id, cancel))
            {
                cancel.Dispose();
                return;
            }
            active[item.Id] = 0;
            activeNames[item.Id] = subtitle is null ? item.Title : $"{item.Title} · {subtitle}";
            Error = null;
        }
        Changed?.Invoke();
        var folder = Folder(item.Id);
        try
        {
            var ticket = await client.StartAsync(item.Id, cancel.Token);
            try
            {
                if (ticket.ContentLength > 0 && ticket.ContentLength + 1_000_000_000 > FreeSpace(Root))
                    throw new IOException("There isn't enough free space on this computer.");
                PrivateFiles.CreateDirectory(Root);
                PrivateFiles.CreateDirectory(folder);
                var fileName = "title." + Extension(ticket.ContentType);
                await using var relay = new LoopbackStreamRelay(client.StreamConnection, client.StreamToken, client.StreamUri(ticket));
                var local = relay.Start();
                using var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
                var partial = Path.Combine(folder, fileName + ".part");
                using (var response = await http.GetAsync(local, HttpCompletionOption.ResponseHeadersRead, cancel.Token))
                {
                    response.EnsureSuccessStatusCode();
                    var total = response.Content.Headers.ContentLength ?? ticket.ContentLength;
                    await using var source = await response.Content.ReadAsStreamAsync(cancel.Token);
                    await using var target = PrivateFile(partial);
                    var buffer = new byte[1 << 20];
                    long written = 0;
                    var reported = DateTimeOffset.MinValue;
                    int read;
                    while ((read = await source.ReadAsync(buffer, cancel.Token)) > 0)
                    {
                        await target.WriteAsync(buffer.AsMemory(0, read), cancel.Token);
                        written += read;
                        if (total > 0 && DateTimeOffset.UtcNow - reported > TimeSpan.FromMilliseconds(300))
                        {
                            reported = DateTimeOffset.UtcNow;
                            lock (gate) active[item.Id] = (double)written / total;
                            Changed?.Invoke();
                        }
                    }
                }
                File.Move(partial, Path.Combine(folder, fileName), overwrite: true);
                var subtitles = new List<OfflineSubtitle>();
                try
                {
                    foreach (var track in (await client.SubtitlesAsync(ticket, cancel.Token)).Where(track => track.IsSidecar && track.Supported))
                    {
                        var name = $"subtitle-{track.Index}.vtt";
                        var bytes = await http.GetByteArrayAsync(relay.SubtitleUrl(track.Index), cancel.Token);
                        await using (var file = PrivateFile(Path.Combine(folder, name))) await file.WriteAsync(bytes, cancel.Token);
                        subtitles.Add(new OfflineSubtitle(track.Index, track.Language, track.Title, track.IsForced, track.IsSdh, name));
                    }
                }
                catch (Exception failure) when (failure is AureliaApiException or HttpRequestException)
                {
                    // The title still plays without its subtitle files.
                }
                var progress = item.Progress;
                var title = new OfflineTitle(item.Id, client.Library.Server.ServerId, client.Library.Profile.User.Id, item.Title, subtitle, item.Kind,
                    fileName, ticket.ContentType, new FileInfo(Path.Combine(folder, fileName)).Length, DateTimeOffset.UtcNow,
                    progress?.PositionMilliseconds ?? 0, progress?.DurationMilliseconds ?? 0, progress?.IsCompleted ?? false, null, false, subtitles,
                    progress?.Revision);
                title = await WithDetailsAsync(title, client.Library, item, series, folder, cancel.Token);
                lock (gate) titles.Add(title);
                Save();
            }
            finally
            {
                try { await client.RevokeAsync(ticket.Id, CancellationToken.None); }
                catch (Exception failure) when (failure is AureliaApiException or HttpRequestException or TaskCanceledException) { }
            }
        }
        catch (Exception failure) when (failure is OperationCanceledException or AureliaApiException or HttpRequestException or IOException or UnauthorizedAccessException)
        {
            if (Find(item.Id) is null) TryDelete(folder);
            if (failure is not OperationCanceledException) Error = $"{item.Title} could not be downloaded. {failure.Message}";
        }
        finally
        {
            lock (gate)
            {
                active.Remove(item.Id);
                activeNames.Remove(item.Id);
                running.Remove(item.Id);
            }
            cancel.Dispose();
            Changed?.Invoke();
        }
    }

    public void Cancel(Guid id)
    {
        lock (gate)
        {
            if (running.TryGetValue(id, out var cancel)) cancel.Cancel();
        }
    }

    public void Remove(Guid id)
    {
        Cancel(id);
        lock (gate) titles.RemoveAll(title => title.Id == id);
        TryDelete(Folder(id));
        Save();
        Changed?.Invoke();
    }

    /// <summary>Progress watched offline, sent to the server once it answers again.</summary>
    public void SaveProgress(Guid id, long position, long duration, bool completed)
    {
        lock (gate)
        {
            var index = titles.FindIndex(title => title.Id == id);
            if (index < 0) return;
            titles[index] = titles[index] with
            {
                PositionMilliseconds = position,
                DurationMilliseconds = Math.Max(duration, titles[index].DurationMilliseconds),
                IsCompleted = completed,
                ProgressSavedAt = DateTimeOffset.UtcNow,
                ProgressDirty = true,
            };
        }
        Save();
        Changed?.Invoke();
    }

    /// <summary>Sends offline progress of this profile when it is newer than what the server has.</summary>
    public async Task SyncProgressAsync(PlaybackClient client)
    {
        var serverId = client.Library.Server.ServerId;
        var userId = client.Library.Profile.User.Id;
        foreach (var title in Titles.Where(title => title.ProgressDirty && title.ServerId == serverId && title.UserId == userId))
        {
            try
            {
                var server = await client.ProgressAsync(title.Id, CancellationToken.None);
                var revision = server.Revision;
                if (OfflineIsNewer(title, server))
                    revision = (await client.SaveProgressAsync(title.Id, new UpdatePlaybackProgressRequest(title.PositionMilliseconds, title.DurationMilliseconds,
                        title.IsCompleted, Guid.NewGuid(), EnforceRevision: true, ExpectedRevision: server.Revision), CancellationToken.None)).Revision;
                lock (gate)
                {
                    var index = titles.FindIndex(each => each.Id == title.Id);
                    if (index >= 0) titles[index] = titles[index] with { ProgressDirty = false, ServerRevision = revision };
                }
            }
            catch (Exception failure) when (failure is AureliaApiException or HttpRequestException or TaskCanceledException)
            {
                // Tried again at the next refresh.
            }
        }
        Save();
        Changed?.Invoke();
    }

    /// <summary>
    /// Gives this profile's downloads made before artwork and descriptions were kept their poster,
    /// backdrop and description, from the library it sees.
    /// </summary>
    public async Task CompleteDetailsAsync(LibraryClient library, IReadOnlyList<CatalogItemSummary> catalog)
    {
        var serverId = library.Server.ServerId;
        var userId = library.Profile.User.Id;
        var missing = Titles.Where(title => !title.HasArtwork && title.ServerId == serverId && title.UserId == userId).ToList();
        var changed = false;
        foreach (var title in missing)
        {
            if (catalog.FirstOrDefault(item => item.Id == title.Id) is not { } item) continue;
            var series = item.ParentId is { } parent ? catalog.FirstOrDefault(each => each.Id == parent) : null;
            var completed = await WithDetailsAsync(title, library, item, series, Folder(title.Id), CancellationToken.None);
            lock (gate)
            {
                var index = titles.FindIndex(each => each.Id == title.Id);
                if (index < 0) continue;
                titles[index] = titles[index].WithDetailsOf(completed);
                changed = true;
            }
        }
        if (!changed) return;
        Save();
        Changed?.Invoke();
    }

    /// <summary>
    /// A title's description and artwork, written next to its file. Artwork that fails to load is
    /// left out; the Downloads page then draws a placeholder.
    /// </summary>
    private static async Task<OfflineTitle> WithDetailsAsync(OfflineTitle title, LibraryClient library, CatalogItemSummary item,
        CatalogItemSummary? series, string folder, CancellationToken cancellation)
    {
        async Task<string?> Keep(ArtworkSummary? artwork, int width, string name)
        {
            if (artwork is null) return null;
            try
            {
                var bytes = await library.ArtworkAsync(artwork, width, cancellation);
                if (bytes.Length == 0) return null;
                await using (var file = PrivateFile(Path.Combine(folder, name))) await file.WriteAsync(bytes, cancellation);
                return name;
            }
            catch (Exception failure) when (failure is AureliaApiException or HttpRequestException or IOException or UnauthorizedAccessException
                || (failure is OperationCanceledException && !cancellation.IsCancellationRequested))
            {
                return null;
            }
        }
        return title.WithDetailsOf(title with
        {
            Overview = item.Overview,
            Year = item.Year,
            Genres = item.Genres,
            ParentId = item.ParentId,
            ParentTitle = item.ParentTitle ?? series?.Title,
            SeasonNumber = item.SeasonNumber,
            EpisodeNumber = item.EpisodeNumber,
            PosterFile = await Keep(item.Poster, 640, "poster.image"),
            BackdropFile = await Keep(item.Backdrop, 1920, "backdrop.image"),
            SeriesPosterFile = await Keep(series?.Poster, 640, "series-poster.image"),
        });
    }

    /// <summary>
    /// Whether progress watched offline should replace the server's. Unchanged since the download
    /// (same revision) it always does, whatever this computer's clock says; only when the server's
    /// progress changed meanwhile do the times decide, and then the later one wins.
    /// </summary>
    internal static bool OfflineIsNewer(OfflineTitle title, PlaybackProgressResponse server)
    {
        if (title.ServerRevision is { } known && server.Revision == known) return true;
        return server.UpdatedAt is not { } updated || updated < title.ProgressSavedAt;
    }

    /// <summary>
    /// Free space where <paramref name="path"/> is stored: the drive mounted deepest above it, so a
    /// separate /home partition counts rather than the root partition.
    /// </summary>
    public static long FreeSpace(string path)
    {
        try
        {
            var full = Path.GetFullPath(path).TrimEnd('/') + "/";
            var drive = DriveInfo.GetDrives()
                .Where(each => each.IsReady && full.StartsWith(each.RootDirectory.FullName.TrimEnd('/') + "/", StringComparison.Ordinal))
                .OrderByDescending(each => each.RootDirectory.FullName.Length)
                .FirstOrDefault();
            return drive?.AvailableFreeSpace ?? long.MaxValue;
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException)
        {
            return long.MaxValue;
        }
    }

    public static string Extension(string contentType) => contentType.ToLowerInvariant() switch
    {
        "video/mp4" => "mp4",
        "video/quicktime" => "mov",
        "video/x-m4v" => "m4v",
        "video/x-msvideo" => "avi",
        "video/webm" => "webm",
        _ => "mkv",
    };

    private string IndexPath => Path.Combine(Root, "index.json");

    private void Load()
    {
        try
        {
            if (!File.Exists(IndexPath)) return;
            var stored = JsonSerializer.Deserialize<List<OfflineTitle>>(File.ReadAllText(IndexPath), Json) ?? [];
            // A title whose file is gone (removed by hand) is forgotten.
            titles = [.. stored.Where(title => File.Exists(FileOf(title)))];
        }
        catch (Exception failure) when (failure is JsonException or IOException or UnauthorizedAccessException)
        {
            titles = [];
        }
    }

    /// <summary>The list of downloads; a full or read-only disk is reported, never thrown to the player.</summary>
    private void Save()
    {
        try
        {
            PrivateFiles.CreateDirectory(Root);
            var temporary = IndexPath + ".tmp";
            PrivateFiles.WriteAllText(temporary, JsonSerializer.Serialize(Titles, Json));
            File.Move(temporary, IndexPath, overwrite: true);
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException)
        {
            Error = "The list of downloads could not be saved. " + failure.Message;
        }
    }

    /// <summary>Downloaded titles are readable only by this user, like the app's other private files.</summary>
    private static FileStream PrivateFile(string path)
    {
        var options = new FileStreamOptions { Mode = FileMode.Create, Access = FileAccess.Write };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        return new FileStream(path, options);
    }

    private void TryDelete(string folder)
    {
        try
        {
            if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException)
        {
            Error = "A download could not be removed from this computer. " + failure.Message;
        }
    }
}
