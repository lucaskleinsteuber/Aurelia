using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;

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
    IReadOnlyList<OfflineSubtitle> Subtitles)
{
    /// <summary>A catalog card for the player, built from what was saved.</summary>
    public CatalogItemSummary Item() => new(Id, Kind, Title, null, null, null, [], null, null, MediaAvailability.Available, false,
        new PlaybackProgressResponse(Id, PositionMilliseconds, DurationMilliseconds, IsCompleted, null, null), DownloadedAt);
}

/// <summary>The downloads on this computer, their files and the ones still loading.</summary>
public sealed class OfflineDownloads
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private readonly object gate = new();
    private readonly Dictionary<Guid, CancellationTokenSource> running = [];
    private List<OfflineTitle> titles = [];
    private readonly Dictionary<Guid, double> active = [];

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

    public long TotalBytes => Titles.Sum(title => title.Bytes);

    public OfflineTitle? Find(Guid id) => Titles.FirstOrDefault(title => title.Id == id);

    public IReadOnlyList<OfflineTitle> For(Guid serverId, Guid userId) =>
        [.. Titles.Where(title => title.ServerId == serverId && title.UserId == userId).OrderByDescending(title => title.DownloadedAt)];

    public string Folder(Guid id) => Path.Combine(Root, id.ToString("N"));

    public string FileOf(OfflineTitle title) => Path.Combine(Folder(title.Id), title.FileName);

    /// <summary>Downloads a movie or episode with the playback client of the open profile.</summary>
    public async Task DownloadAsync(PlaybackClient client, CatalogItemSummary item, string? subtitle)
    {
        if (item.Kind is not (MediaKind.Movie or MediaKind.Episode) || Find(item.Id) is not null) return;
        var cancel = new CancellationTokenSource();
        lock (gate)
        {
            if (!running.TryAdd(item.Id, cancel))
            {
                cancel.Dispose();
                return;
            }
            active[item.Id] = 0;
            Error = null;
        }
        Changed?.Invoke();
        var folder = Folder(item.Id);
        try
        {
            var ticket = await client.StartAsync(item.Id, cancel.Token);
            try
            {
                var free = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(Root)) ?? "/").AvailableFreeSpace;
                if (ticket.ContentLength > 0 && ticket.ContentLength + 1_000_000_000 > free)
                    throw new IOException("There isn't enough free space on this computer.");
                Directory.CreateDirectory(folder);
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
                    await using var target = File.Create(partial);
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
                        await File.WriteAllBytesAsync(Path.Combine(folder, name), await http.GetByteArrayAsync(relay.SubtitleUrl(track.Index), cancel.Token), cancel.Token);
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
                    progress?.PositionMilliseconds ?? 0, progress?.DurationMilliseconds ?? 0, progress?.IsCompleted ?? false, null, false, subtitles);
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
            if (Find(item.Id) is null && Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
            if (failure is not OperationCanceledException) Error = $"{item.Title} could not be downloaded. {failure.Message}";
        }
        finally
        {
            lock (gate)
            {
                active.Remove(item.Id);
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
        if (Directory.Exists(Folder(id))) Directory.Delete(Folder(id), recursive: true);
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
                if (server.UpdatedAt is not { } updated || updated < title.ProgressSavedAt)
                    await client.SaveProgressAsync(title.Id, new UpdatePlaybackProgressRequest(title.PositionMilliseconds, title.DurationMilliseconds,
                        title.IsCompleted, Guid.NewGuid(), EnforceRevision: true, ExpectedRevision: server.Revision), CancellationToken.None);
                lock (gate)
                {
                    var index = titles.FindIndex(each => each.Id == title.Id);
                    if (index >= 0) titles[index] = titles[index] with { ProgressDirty = false };
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

    private void Save()
    {
        Directory.CreateDirectory(Root);
        var temporary = IndexPath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(Titles, Json));
        File.Move(temporary, IndexPath, overwrite: true);
    }
}
