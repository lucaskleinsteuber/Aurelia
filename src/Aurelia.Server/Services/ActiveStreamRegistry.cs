using Aurelia.Contracts;

namespace Aurelia.Server.Services;

public sealed class ActiveStreamRegistry(TimeProvider? clock = null)
{
    private readonly TimeProvider clock = clock ?? TimeProvider.System;
    /// <summary>
    /// Timeline preview frames are short reads beside a playing stream. They have their own small
    /// budget so they never take a slot that playback, a seek or another device needs.
    /// </summary>
    public const int PreviewStreamsPerSession = 8;
    public const int PreviewStreamsGlobal = 32;
    private readonly object gate = new();
    private readonly HashSet<Lease> streams = [];
    private DateTimeOffset? lastPlayback;
    public int Count { get { lock (gate) return streams.Count; } }
    /// <summary>Playback reads now open; preview frames do not count.</summary>
    public int PlaybackCount { get { lock (gate) return streams.Count(stream => !stream.IsPreview); } }
    /// <summary>
    /// When a playback read last started, ended or sent data. A paused player may keep its read
    /// open, but sends nothing then, so this tells watching apart from an open connection.
    /// </summary>
    public DateTimeOffset? LastPlaybackActivity { get { lock (gate) return lastPlayback; } }

    public Lease Enter(Guid userId, Guid sessionId, int globalLimit, int userLimit, CancellationToken request, bool preview = false)
    {
        lock (gate)
        {
            var full = preview
                ? streams.Count(stream => stream.IsPreview) >= PreviewStreamsGlobal
                    || streams.Count(stream => stream.IsPreview && stream.SessionId == sessionId) >= PreviewStreamsPerSession
                : streams.Count(stream => !stream.IsPreview) >= globalLimit
                    || streams.Count(stream => !stream.IsPreview && stream.UserId == userId) >= userLimit;
            if (full)
                throw new AccountException("stream_limit", "Too many simultaneous stream requests. Try again shortly.", 429);
            var lease = new Lease(this, userId, sessionId, preview, request);
            streams.Add(lease);
            if (!preview) lastPlayback = clock.GetUtcNow();
            return lease;
        }
    }

    /// <summary>A playback read or a running conversion of this user is open now.</summary>
    public bool HasPlayback(Guid userId)
    {
        lock (gate) return streams.Any(stream => !stream.IsPreview && stream.UserId == userId) || watchers.Any(watch => watch.UserId == userId);
    }

    public void RevokeUser(Guid userId) => Cancel(stream => stream.UserId == userId, watch => watch.UserId == userId);
    public void RevokeSession(Guid sessionId) => Cancel(stream => stream.SessionId == sessionId, watch => watch.SessionId == sessionId);
    public void RevokeMedia(IReadOnlyCollection<Guid> ids) =>
        Cancel(stream => stream.MediaId is { } id && ids.Contains(id), watch => ids.Contains(watch.MediaId));

    private readonly HashSet<Watcher> watchers = [];

    /// <summary>
    /// Something that plays beyond single requests, such as an HLS session's conversion, ends
    /// with the user, profile session or title like a running read. It does not count as a stream.
    /// </summary>
    public IDisposable Watch(Guid userId, Guid sessionId, Guid mediaId, Action cancel)
    {
        var watcher = new Watcher(this, userId, sessionId, mediaId, cancel);
        lock (gate) watchers.Add(watcher);
        return watcher;
    }

    private void Cancel(Func<Lease, bool> predicate, Func<Watcher, bool> watched)
    {
        // Cancel outside the lock: cancellation callbacks may dispose a stream lease.
        Lease[] affected;
        Watcher[] ending;
        lock (gate)
        {
            affected = streams.Where(predicate).ToArray();
            ending = watchers.Where(watched).ToArray();
        }
        foreach (var lease in affected) lease.Cancel();
        foreach (var watcher in ending) watcher.Cancel();
    }

    private sealed class Watcher(ActiveStreamRegistry registry, Guid userId, Guid sessionId, Guid mediaId, Action cancel) : IDisposable
    {
        public Guid UserId { get; } = userId;
        public Guid SessionId { get; } = sessionId;
        public Guid MediaId { get; } = mediaId;

        public void Cancel()
        {
            Dispose();
            cancel();
        }

        public void Dispose()
        {
            lock (registry.gate) registry.watchers.Remove(this);
        }
    }

    public sealed class Lease : IDisposable
    {
        private readonly ActiveStreamRegistry registry;
        private readonly CancellationTokenSource source;
        private readonly object gate = new();
        private bool disposed;
        internal Lease(ActiveStreamRegistry registry, Guid userId, Guid sessionId, bool preview, CancellationToken request)
        {
            this.registry = registry;
            UserId = userId;
            SessionId = sessionId;
            IsPreview = preview;
            source = CancellationTokenSource.CreateLinkedTokenSource(request);
        }
        public Guid UserId { get; }
        public Guid SessionId { get; }
        public bool IsPreview { get; }
        public Guid? MediaId { get; private set; }
        public void BindMedia(Guid id) { lock (registry.gate) MediaId = id; }
        /// <summary>The read sent data to the device.</summary>
        public void MarkRead()
        {
            if (IsPreview) return;
            lock (registry.gate) registry.lastPlayback = registry.clock.GetUtcNow();
        }
        public CancellationToken Token => source.Token;
        internal void Cancel() { lock (gate) { if (!disposed) source.Cancel(); } }
        public void Dispose()
        {
            lock (registry.gate)
            {
                if (registry.streams.Remove(this) && !IsPreview) registry.lastPlayback = registry.clock.GetUtcNow();
            }
            lock (gate) { if (!disposed) { disposed = true; source.Dispose(); } }
        }
    }
}
