using System.Collections.Concurrent;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.EntityFrameworkCore;

namespace Aurelia.Server.Services.Automation;

/// <summary>What is playing where, kept only in memory, for webhooks and "now playing".</summary>
public sealed record PlaybackActivity(
    Guid TicketId,
    Guid UserId,
    AutomationDeviceInfo Device,
    AutomationProfileInfo Profile,
    Guid ProfileId,
    AutomationMedia Media,
    string State,
    bool Reported,
    bool Started,
    DateTimeOffset Since,
    DateTimeOffset LastSeen);

/// <summary>
/// Turns players' state reports into events, as fast as they arrive. A ticket is opened when a
/// title starts loading; "started" is sent when the player reports that it actually plays, so a
/// light dims when the picture is there, not while it buffers. A player that never reports (an
/// older app) still gets "started" a few seconds after opening and "stopped" when it closes.
/// Equal reports in a row send nothing. Nothing here touches the database on the hot path.
/// </summary>
public sealed class PlaybackActivityTracker(AutomationEventBus bus, TimeProvider clock)
{
    /// <summary>How long a player that never reports gets before "started" is sent anyway.</summary>
    public static readonly TimeSpan SilentStart = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan Forget = TimeSpan.FromHours(12);
    private const string Opening = "opened";
    private readonly ConcurrentDictionary<Guid, PlaybackActivity> activities = new();

    public IReadOnlyList<PlaybackActivity> Current =>
        activities.Values.Where(value => value.State is PlaybackStates.Playing or PlaybackStates.Paused or PlaybackStates.Buffering)
            .OrderBy(value => value.Since).ToList();

    public PlaybackActivity? Find(Guid ticketId) => activities.TryGetValue(ticketId, out var value) ? value : null;

    /// <summary>A playback ticket was created; nothing is sent yet.</summary>
    public void Opened(Guid ticketId, Guid userId, Guid profileId, AutomationDeviceInfo device, AutomationProfileInfo profile, AutomationMedia media)
    {
        var now = clock.GetUtcNow();
        Prune(now);
        // A player renews its ticket during a long title: the same device and title continue
        // without a second "started", and closing the old ticket sends no "stopped".
        var continued = activities.Values.FirstOrDefault(value => value.UserId == userId && value.Device.Id == device.Id
            && value.Media.Id == media.Id && value.State is not (PlaybackStates.Finished or PlaybackStates.Stopped));
        if (continued is not null && activities.TryRemove(continued.TicketId, out _))
        {
            activities[ticketId] = continued with { TicketId = ticketId, LastSeen = now };
            return;
        }
        activities[ticketId] = new PlaybackActivity(ticketId, userId, device, profile, profileId, media, Opening, false, false, now, now);
        _ = StartSilentlyAsync(ticketId);
    }

    private async Task StartSilentlyAsync(Guid ticketId)
    {
        try { await Task.Delay(SilentStart, clock); } catch (OperationCanceledException) { return; }
        if (activities.TryGetValue(ticketId, out var activity) && !activity.Reported && activity.State == Opening)
            Move(activity, PlaybackStates.Playing, null, reported: false);
    }

    /// <summary>A player's report. Returns false when the ticket isn't known for this profile.</summary>
    public bool Report(Guid ticketId, Guid userId, string state, double? position)
    {
        if (!activities.TryGetValue(ticketId, out var activity) || activity.UserId != userId) return false;
        Move(activity, state, position, reported: true);
        return true;
    }

    /// <summary>The player closed (its ticket was revoked).</summary>
    public void Closed(Guid ticketId)
    {
        if (!activities.TryRemove(ticketId, out var activity)) return;
        if (Transition(activity.State, PlaybackStates.Stopped, activity.Started) is { } kind) Publish(kind, activity, null);
    }

    /// <summary>Progress said the title was watched to its end: one "finished" for its open ticket.</summary>
    public void Finished(Guid userId, Guid mediaId)
    {
        var activity = activities.Values.Where(value => value.UserId == userId && value.Media.Id == mediaId
            && value.State is not (PlaybackStates.Finished or PlaybackStates.Stopped)).OrderByDescending(value => value.LastSeen).FirstOrDefault();
        if (activity is not null) Move(activity, PlaybackStates.Finished, null, reported: activity.Reported);
    }

    private void Move(PlaybackActivity activity, string state, double? position, bool reported)
    {
        var now = clock.GetUtcNow();
        var kind = Transition(activity.State, state, activity.Started);
        var next = activity with
        {
            State = state,
            Reported = activity.Reported || reported,
            LastSeen = now,
            Started = activity.Started || kind == AutomationEvents.PlaybackStarted,
            Media = position is { } seconds ? activity.Media with { PositionSeconds = seconds } : activity.Media
        };
        if (!activities.TryUpdate(activity.TicketId, next, activity)) return;
        if (kind is not null) Publish(kind, next, position);
    }

    /// <summary>
    /// The event a change of state sends, or null when nothing worth telling happened: buffering
    /// sends nothing, the first real playing sends "started", and pausing, continuing, finishing
    /// and stopping only count after that.
    /// </summary>
    public static string? Transition(string previous, string next, bool started)
    {
        if (previous == next) return null;
        var ended = previous is PlaybackStates.Finished or PlaybackStates.Stopped;
        return next switch
        {
            PlaybackStates.Playing when !started => AutomationEvents.PlaybackStarted,
            PlaybackStates.Playing when previous == PlaybackStates.Paused => AutomationEvents.PlaybackResumed,
            PlaybackStates.Paused when started && !ended => AutomationEvents.PlaybackPaused,
            PlaybackStates.Finished when started && !ended => AutomationEvents.PlaybackFinished,
            PlaybackStates.Stopped when started && !ended => AutomationEvents.PlaybackStopped,
            _ => null,
        };
    }

    private void Publish(string kind, PlaybackActivity activity, double? position) =>
        bus.Publish(new AutomationEvent(kind, Guid.NewGuid(), clock.GetUtcNow(), activity.Device, activity.Profile, activity.ProfileId,
            position is { } seconds ? activity.Media with { PositionSeconds = seconds } : activity.Media));

    private void Prune(DateTimeOffset now)
    {
        foreach (var (id, activity) in activities)
            if (now - activity.LastSeen > Forget) activities.TryRemove(id, out _);
    }

    /// <summary>The title, device and profile of a new ticket, read once when it is created.</summary>
    public static async Task<(AutomationDeviceInfo Device, AutomationProfileInfo Profile, AutomationMedia Media)> DescribeAsync(
        AureliaDbContext database, DeviceSession session, ServerUser user, MediaItem media, CancellationToken cancellationToken) =>
        (new AutomationDeviceInfo(session.Id, session.DeviceName, session.Platform),
            new AutomationProfileInfo(user.DisplayName ?? user.Username, user.AgeLimit is not null),
            await MediaAsync(database, media, cancellationToken));

    /// <summary>A title as webhooks describe it: its shown name, its show, season and episode.</summary>
    public static async Task<AutomationMedia> MediaAsync(AureliaDbContext database, MediaItem media, CancellationToken cancellationToken)
    {
        var metadata = await database.MediaMetadata.AsNoTracking()
            .Where(value => value.MediaItemId == media.Id || (media.ParentId != null && value.MediaItemId == media.ParentId))
            .Select(value => new { value.MediaItemId, value.ManualTitle, value.ProviderTitle, value.ProviderRuntimeMinutes, value.ManualRuntimeMinutes })
            .ToListAsync(cancellationToken);
        var own = metadata.FirstOrDefault(value => value.MediaItemId == media.Id);
        string? seriesTitle = null;
        if (media.ParentId is { } parentId)
        {
            var parent = await database.MediaItems.AsNoTracking().Where(value => value.Id == parentId)
                .Select(value => new { value.OverrideTitle, value.DetectedTitle }).SingleOrDefaultAsync(cancellationToken);
            var parentMetadata = metadata.FirstOrDefault(value => value.MediaItemId == parentId);
            seriesTitle = parentMetadata?.ManualTitle ?? parent?.OverrideTitle ?? parentMetadata?.ProviderTitle ?? parent?.DetectedTitle;
        }
        var minutes = own?.ManualRuntimeMinutes ?? own?.ProviderRuntimeMinutes;
        var description = new AutomationMedia(
            media.Id,
            media.Kind.ToString().ToLowerInvariant(),
            own?.ManualTitle ?? media.OverrideTitle ?? own?.ProviderTitle ?? media.DetectedTitle,
            media.Kind == MediaKind.Episode ? seriesTitle : null,
            media.SeasonNumber,
            media.EpisodeNumber,
            media.Year,
            minutes is > 0 ? minutes * 60.0 : null,
            null);
        return description;
    }
}
