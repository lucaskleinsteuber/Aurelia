using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Settings;

namespace Aurelia.Linux.Core.Playback;

/// <summary>A position waiting to reach the server. It holds ids and positions only, never credentials.</summary>
public sealed record PendingProgress(
    Guid ServerId,
    Guid UserId,
    Guid MediaId,
    long PositionMilliseconds,
    long DurationMilliseconds,
    bool IsFinished,
    long ExpectedRevision,
    Guid ClientMutationId,
    DateTimeOffset? RecordedAt = null);

public enum ProgressResult
{
    Saved,
    Conflict,
    Waiting,
    Refused,
}

/// <summary>
/// Saves playback positions like the Mac app's outbox: each save carries the revision it builds on
/// and a mutation id that is written to disk before sending, so a retry repeats it exactly. Saves
/// that could not be sent stay in <c>$XDG_STATE_HOME/aurelia-desktop/pending-progress.json</c>
/// (readable only by this user, at most 256 entries) and are sent again later. When the revision
/// is outdated, the later position wins: this computer's while someone watches here (it is sent
/// again on the server's revision), otherwise the one another device saved afterwards, and the
/// player offers to keep this computer's position.
/// </summary>
public sealed class ProgressOutbox(string? path)
{
    public const int Capacity = 256;
    private readonly Lock gate = new();
    private List<PendingProgress>? entries;

    public IReadOnlyList<PendingProgress> Pending
    {
        get
        {
            lock (gate) return [.. Load()];
        }
    }

    public async Task<(ProgressResult Result, PlaybackProgressResponse? Saved)> SaveAsync(PlaybackClient client, PendingProgress progress, CancellationToken cancellation)
    {
        Store(progress);
        return await SendAsync(client, progress, cancellation);
    }

    /// <summary>Sends what is still waiting for this server and profile, oldest first.</summary>
    public async Task FlushAsync(PlaybackClient client, CancellationToken cancellation)
    {
        foreach (var progress in Pending.Where(p => p.ServerId == client.Library.Server.ServerId && p.UserId == client.Library.Profile.User.Id))
        {
            var (result, _) = await SendAsync(client, progress, cancellation);
            if (result == ProgressResult.Waiting) return;
        }
    }

    /// <summary>A few seconds of allowance for clocks that differ slightly.</summary>
    public static bool KeepsLocal(DateTimeOffset? recordedAt, DateTimeOffset? serverUpdatedAt) =>
        recordedAt is { } local && (serverUpdatedAt is not { } server || local.AddSeconds(5) >= server);

    private async Task<(ProgressResult, PlaybackProgressResponse?)> SendAsync(PlaybackClient client, PendingProgress progress, CancellationToken cancellation, int rebases = 0)
    {
        try
        {
            var saved = await client.SaveProgressAsync(progress.MediaId, new UpdatePlaybackProgressRequest(
                progress.PositionMilliseconds, progress.DurationMilliseconds, progress.IsFinished, progress.ClientMutationId,
                EnforceRevision: true, ExpectedRevision: progress.ExpectedRevision), cancellation);
            Remove(progress);
            if (saved.LastMutationId is { } echoed && echoed != progress.ClientMutationId) return (ProgressResult.Conflict, saved);
            return (ProgressResult.Saved, saved);
        }
        catch (AureliaApiException error) when (error.Status == 409 || error.Code == "playback_progress_conflict")
        {
            Remove(progress);
            if (rebases < 3 && progress.RecordedAt is not null)
            {
                PlaybackProgressResponse current;
                try
                {
                    current = await client.ProgressAsync(progress.MediaId, cancellation);
                }
                catch (AureliaApiException)
                {
                    return (ProgressResult.Conflict, null);
                }
                if (KeepsLocal(progress.RecordedAt, current.UpdatedAt))
                {
                    var rebased = progress with { ExpectedRevision = current.Revision, ClientMutationId = Guid.NewGuid() };
                    Store(rebased);
                    return await SendAsync(client, rebased, cancellation, rebases + 1);
                }
            }
            return (ProgressResult.Conflict, null);
        }
        catch (AureliaApiException error) when (error.IsTransient)
        {
            return (ProgressResult.Waiting, null);
        }
        catch (AureliaApiException)
        {
            Remove(progress);
            return (ProgressResult.Refused, null);
        }
    }

    private void Store(PendingProgress progress)
    {
        lock (gate)
        {
            var list = Load();
            list.RemoveAll(p => p.ServerId == progress.ServerId && p.UserId == progress.UserId && p.MediaId == progress.MediaId);
            list.Add(progress);
            if (list.Count > Capacity) list.RemoveRange(0, list.Count - Capacity);
            Write(list);
        }
    }

    private void Remove(PendingProgress progress)
    {
        lock (gate)
        {
            var list = Load();
            if (list.RemoveAll(p => p.ClientMutationId == progress.ClientMutationId) > 0) Write(list);
        }
    }

    private List<PendingProgress> Load()
    {
        if (entries is not null) return entries;
        entries = [];
        if (path is null || !File.Exists(path)) return entries;
        try
        {
            entries = JsonSerializer.Deserialize<List<PendingProgress>>(File.ReadAllText(path), AureliaJson.Options) ?? [];
        }
        catch (Exception error) when (error is JsonException or IOException)
        {
            entries = [];
        }
        return entries;
    }

    private void Write(List<PendingProgress> list)
    {
        entries = list;
        if (path is null) return;
        try
        {
            PrivateFiles.CreateDirectory(Path.GetDirectoryName(path)!);
            var temporary = path + ".tmp";
            PrivateFiles.WriteAllText(temporary, JsonSerializer.Serialize(list, AureliaJson.Options));
            File.Move(temporary, path, overwrite: true);
        }
        catch (IOException)
        {
            // Kept in memory; the next save tries the disk again.
        }
    }
}
