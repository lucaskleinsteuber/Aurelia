using System.Text.Json;
using System.Text.Json.Serialization;
using Aurelia.Linux.Core.Api;

namespace Aurelia.Linux.Core.Playback;

public enum PlaybackDiagnosticKind
{
    Started, StateChanged, Seeked, AudioChanged, SubtitleChanged, RecoveryAttempt, TicketRenewed, ProgressPending, ProgressConflict, Failed, Ended, Stopped,
}

/// <summary>A closed, sanitized schema: no media identifiers, names, URLs, paths, tokens or raw error text.</summary>
public sealed record PlaybackDiagnosticEvent(DateTimeOffset Timestamp, PlaybackDiagnosticKind Kind, long PositionMilliseconds,
    long DurationMilliseconds, PlayerState State, int? Attempt = null, int? HttpStatus = null, string? ProblemCode = null);

/// <summary>In-memory diagnostics, bounded to 200 events. Export requires an explicit action in the player.</summary>
public sealed class PlaybackDiagnostics(TimeProvider time)
{
    public const int Capacity = 200;
    private static readonly HashSet<string> ProblemCodes = new(StringComparer.Ordinal)
    {
        "media_unavailable", "media_file_unavailable", "media_not_found", "media_not_playable", "invalid_session", "session_revoked", "access_denied",
        "playback_ticket_expired", "playback_ticket_not_found", "stream_limit", "stream_limit_reached", "too_many_streams", "identity_mismatch",
    };
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };
    private readonly Queue<PlaybackDiagnosticEvent> events = new();

    public IReadOnlyList<PlaybackDiagnosticEvent> Events => [.. events];

    public void Record(PlaybackDiagnosticKind kind, long position, long duration, PlayerState state, int? attempt = null, AureliaApiException? failure = null)
    {
        events.Enqueue(new PlaybackDiagnosticEvent(time.GetUtcNow(), kind, Math.Max(0, position), Math.Max(0, duration), state,
            attempt is >= 0 and <= 100 ? attempt : null, failure?.Status is >= 100 and <= 599 ? failure.Status : null,
            failure?.Code is { } code && ProblemCodes.Contains(code) ? code : null));
        while (events.Count > Capacity) events.Dequeue();
    }

    public byte[] Export() => JsonSerializer.SerializeToUtf8Bytes(new { formatVersion = 1, platform = "linux", version = AppInfo.DisplayVersion, events = Events }, Json);
}
