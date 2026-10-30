using System.Collections.Concurrent;
using Aurelia.Contracts;
using Aurelia.Server.Authentication;

namespace Aurelia.Server.Services;

/// <summary>
/// "Play on…": players announce themselves with heartbeats and long-poll for commands that
/// other devices of the same profile send them. A player id is chosen by the client, so it is
/// bound to the paired device session that first claimed it: another device cannot take over
/// a live registration or read its commands. Registrations live only in memory and expire.
/// </summary>
public sealed class RemotePlaybackService
{
    private static readonly TimeSpan HeartbeatTimeout = TimeSpan.FromSeconds(45);
    private static readonly TimeSpan CommandTimeout = TimeSpan.FromSeconds(60);
    /// <summary>Registrations not heard from for this long are forgotten.</summary>
    private static readonly TimeSpan RegistrationLifetime = TimeSpan.FromMinutes(10);
    private const int MaxPendingCommands = 50;
    private const int MaxRegistrations = 256;
    private const int MaxDeviceIdLength = 128;
    private const int MaxNameLength = 100;
    private const int MaxClientTypeLength = 32;
    private const int MaxTitleLength = 512;

    private readonly object registrationGate = new();
    private readonly ConcurrentDictionary<string, RegisteredPlayer> _devices = new(StringComparer.OrdinalIgnoreCase);

    public PlayerHeartbeatResponse RecordHeartbeat(Guid userId, Guid deviceSessionId, PlayerHeartbeatRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var deviceId = request.DeviceId?.Trim();
        if (string.IsNullOrEmpty(deviceId) || deviceId.Length > MaxDeviceIdLength)
            throw new AccountException("invalid_device_id", "A valid device identifier is required.", 400);

        var now = DateTimeOffset.UtcNow;
        var name = Bounded(request.DeviceName, MaxNameLength) ?? "Unknown Device";
        var clientType = Bounded(request.ClientType, MaxClientTypeLength) ?? "unknown";
        var title = Bounded(request.Title, MaxTitleLength);

        lock (registrationGate)
        {
            if (_devices.TryGetValue(deviceId, out var existing) && existing.LastSeen >= now - HeartbeatTimeout
                && existing.DeviceSessionId != deviceSessionId)
                throw new AccountException("device_id_in_use", "Another paired device is using this player identifier.", 409);

            if (existing is null || existing.DeviceSessionId != deviceSessionId)
            {
                PruneStaleRegistrations(now);
                if (existing is null && _devices.Count >= MaxRegistrations)
                    throw new AccountException("too_many_players", "Too many players are registered. Try again shortly.", 429);
                existing = new RegisteredPlayer(deviceId, deviceSessionId, userId);
                _devices[deviceId] = existing;
            }

            existing.Update(name, clientType, userId, now, request.IsPlaying, request.MediaId, title,
                request.PositionSeconds, request.DurationSeconds, request.IsPaused);
        }

        return new PlayerHeartbeatResponse(true, now);
    }

    public IReadOnlyList<RemotePlayerDevice> GetActiveDevices(Guid userId, string? excludeDeviceId = null)
    {
        var cutoff = DateTimeOffset.UtcNow - HeartbeatTimeout;
        var result = new List<RemotePlayerDevice>();

        foreach (var pair in _devices)
        {
            var device = pair.Value;
            if (device.LastSeen < cutoff)
                continue;

            if (device.UserId != userId)
                continue;

            if (!string.IsNullOrEmpty(excludeDeviceId) && string.Equals(device.DeviceId, excludeDeviceId, StringComparison.OrdinalIgnoreCase))
                continue;

            result.Add(device.ToContract());
        }

        return result;
    }

    public RemotePlayerDevice GetDeviceStatus(Guid userId, string deviceId)
    {
        if (!_devices.TryGetValue(deviceId, out var device) || device.LastSeen < DateTimeOffset.UtcNow - HeartbeatTimeout)
            throw new AccountException("target_offline", "The target device is no longer reachable.", 404);

        if (device.UserId != userId)
            throw new AccountException("target_profile_mismatch", "The target device is currently using a different profile.", 409);

        return device.ToContract();
    }

    public RemotePlaybackCommandResponse SendCommand(Guid senderUserId, string targetDeviceId, RemotePlaybackCommandRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.Action))
            throw new AccountException("invalid_action", "A valid playback action is required.", 400);

        var action = request.Action.Trim().ToLowerInvariant();
        if (action is not ("play" or "pause" or "resume" or "seek" or "skip" or "stop"))
            throw new AccountException("unsupported_action", $"Action '{action}' is not supported.", 400);

        if (action == "play" && request.MediaId is null)
            throw new AccountException("missing_media_id", "A media identifier is required to start playback.", 400);

        if (!_devices.TryGetValue(targetDeviceId, out var target) || target.LastSeen < DateTimeOffset.UtcNow - HeartbeatTimeout)
            throw new AccountException("target_offline", "The target device is no longer reachable.", 404);

        if (target.UserId != senderUserId)
            throw new AccountException("target_profile_mismatch", "The target device is currently using a different profile.", 409);

        var commandId = Guid.NewGuid();
        var now = DateTimeOffset.UtcNow;
        var expiresAt = now + CommandTimeout;

        var command = new QueuedCommand(
            commandId,
            action,
            request.MediaId,
            request.PositionSeconds,
            request.SkipSeconds,
            now,
            expiresAt);

        target.EnqueueCommand(command);
        return new RemotePlaybackCommandResponse(commandId, "queued");
    }

    public async Task<IReadOnlyList<RemotePlaybackCommand>> GetCommandsAsync(
        Guid userId,
        Guid deviceSessionId,
        string deviceId,
        int waitMs,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(deviceId))
            throw new AccountException("invalid_device_id", "A valid device identifier is required.", 400);

        if (!_devices.TryGetValue(deviceId, out var device))
            return Array.Empty<RemotePlaybackCommand>();

        if (device.UserId != userId || device.DeviceSessionId != deviceSessionId)
            throw new AccountException("device_profile_mismatch", "The registered device does not belong to the current profile.", 403);

        // First check if pending commands already exist
        var pending = device.DrainPendingCommands();
        if (pending.Count > 0 || waitMs <= 0)
            return pending;

        // Long-poll wait
        var clampedWait = Math.Min(waitMs, 15000);
        await device.WaitForCommandAsync(clampedWait, cancellationToken);

        return device.DrainPendingCommands();
    }

    private void PruneStaleRegistrations(DateTimeOffset now)
    {
        foreach (var pair in _devices)
            if (pair.Value.LastSeen < now - RegistrationLifetime)
                _devices.TryRemove(pair);
    }

    private static string? Bounded(string? value, int maximumLength)
    {
        var trimmed = value?.Trim();
        if (string.IsNullOrEmpty(trimmed)) return null;
        return trimmed.Length <= maximumLength ? trimmed : trimmed[..maximumLength];
    }

    private sealed class RegisteredPlayer
    {
        private readonly object _sync = new();
        private readonly Queue<QueuedCommand> _commandQueue = new();
        private TaskCompletionSource<bool>? _waitSource;

        public string DeviceId { get; }
        public Guid DeviceSessionId { get; }
        public string DeviceName { get; private set; }
        public string ClientType { get; private set; }
        public Guid UserId { get; private set; }
        public DateTimeOffset LastSeen { get; private set; }
        public bool IsPlaying { get; private set; }
        public Guid? MediaId { get; private set; }
        public string? Title { get; private set; }
        public double? PositionSeconds { get; private set; }
        public double? DurationSeconds { get; private set; }
        public bool IsPaused { get; private set; }

        public RegisteredPlayer(string deviceId, Guid deviceSessionId, Guid userId)
        {
            DeviceId = deviceId;
            DeviceSessionId = deviceSessionId;
            UserId = userId;
            DeviceName = "Unknown Device";
            ClientType = "unknown";
        }

        public void Update(
            string deviceName,
            string clientType,
            Guid userId,
            DateTimeOffset lastSeen,
            bool isPlaying,
            Guid? mediaId,
            string? title,
            double? positionSeconds,
            double? durationSeconds,
            bool isPaused)
        {
            lock (_sync)
            {
                // Commands sent to the previous profile must not run for the next one.
                if (UserId != userId) _commandQueue.Clear();
                DeviceName = deviceName;
                ClientType = clientType;
                UserId = userId;
                LastSeen = lastSeen;
                IsPlaying = isPlaying;
                MediaId = mediaId;
                Title = title;
                PositionSeconds = positionSeconds;
                DurationSeconds = durationSeconds;
                IsPaused = isPaused;
            }
        }

        public void EnqueueCommand(QueuedCommand command)
        {
            TaskCompletionSource<bool>? waiter = null;
            lock (_sync)
            {
                PruneExpiredLocked(DateTimeOffset.UtcNow);
                if (_commandQueue.Count < MaxPendingCommands)
                {
                    _commandQueue.Enqueue(command);
                }
                waiter = _waitSource;
                _waitSource = null;
            }
            waiter?.TrySetResult(true);
        }

        public List<RemotePlaybackCommand> DrainPendingCommands()
        {
            var now = DateTimeOffset.UtcNow;
            var list = new List<RemotePlaybackCommand>();

            lock (_sync)
            {
                PruneExpiredLocked(now);
                while (_commandQueue.Count > 0)
                {
                    var queued = _commandQueue.Dequeue();
                    if (queued.ExpiresAt > now)
                    {
                        list.Add(new RemotePlaybackCommand(
                            queued.CommandId,
                            queued.Action,
                            queued.MediaId,
                            queued.PositionSeconds,
                            queued.SkipSeconds,
                            queued.CreatedAt));
                    }
                }
            }

            return list;
        }

        public async Task WaitForCommandAsync(int timeoutMs, CancellationToken cancellationToken)
        {
            TaskCompletionSource<bool> tcs;
            lock (_sync)
            {
                if (_commandQueue.Count > 0)
                    return;
                _waitSource = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                tcs = _waitSource;
            }

            using var timeoutCts = new CancellationTokenSource(timeoutMs);
            using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);

            try
            {
                await tcs.Task.WaitAsync(linkedCts.Token);
            }
            catch (OperationCanceledException)
            {
                // Timeout or aborted: normal completion
            }
            finally
            {
                lock (_sync)
                {
                    if (ReferenceEquals(_waitSource, tcs))
                        _waitSource = null;
                }
            }
        }

        private void PruneExpiredLocked(DateTimeOffset now)
        {
            while (_commandQueue.Count > 0 && _commandQueue.Peek().ExpiresAt <= now)
            {
                _commandQueue.Dequeue();
            }
        }

        public RemotePlayerDevice ToContract()
        {
            lock (_sync)
            {
                return new RemotePlayerDevice(
                    DeviceId,
                    DeviceName,
                    ClientType,
                    IsPlaying,
                    MediaId,
                    Title,
                    PositionSeconds,
                    DurationSeconds,
                    IsPaused,
                    LastSeen);
            }
        }
    }

    private sealed record QueuedCommand(
        Guid CommandId,
        string Action,
        Guid? MediaId,
        double? PositionSeconds,
        double? SkipSeconds,
        DateTimeOffset CreatedAt,
        DateTimeOffset ExpiresAt);
}
