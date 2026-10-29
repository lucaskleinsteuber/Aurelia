namespace Aurelia.Contracts;

public sealed record PlayerHeartbeatRequest(
    string DeviceId,
    string DeviceName,
    string ClientType,
    bool IsPlaying,
    Guid? MediaId = null,
    string? Title = null,
    double? PositionSeconds = null,
    double? DurationSeconds = null,
    bool IsPaused = false);

public sealed record PlayerHeartbeatResponse(
    bool Success,
    DateTimeOffset Timestamp);

public sealed record RemotePlayerDevice(
    string DeviceId,
    string DeviceName,
    string ClientType,
    bool IsPlaying,
    Guid? MediaId,
    string? Title,
    double? PositionSeconds,
    double? DurationSeconds,
    bool IsPaused,
    DateTimeOffset LastSeen);

public sealed record RemotePlaybackCommandRequest(
    string Action,
    Guid? MediaId = null,
    double? PositionSeconds = null,
    double? SkipSeconds = null);

public sealed record RemotePlaybackCommandResponse(
    Guid CommandId,
    string Status);

public sealed record RemotePlaybackCommand(
    Guid CommandId,
    string Action,
    Guid? MediaId,
    double? PositionSeconds,
    double? SkipSeconds,
    DateTimeOffset CreatedAt);
