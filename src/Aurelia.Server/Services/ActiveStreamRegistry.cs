using Aurelia.Contracts;

namespace Aurelia.Server.Services;

public sealed class ActiveStreamRegistry
{
    /// <summary>
    /// Timeline preview frames are short reads beside a playing stream. They have their own small
    /// budget so they never take a slot that playback, a seek or another device needs.
    /// </summary>
    public const int PreviewStreamsPerSession = 2;
    public const int PreviewStreamsGlobal = 16;
    private readonly object gate = new();
    private readonly HashSet<Lease> streams = [];
    public int Count { get { lock (gate) return streams.Count; } }

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
            return lease;
        }
    }

    public void RevokeUser(Guid userId) => Cancel(stream => stream.UserId == userId);
    public void RevokeSession(Guid sessionId) => Cancel(stream => stream.SessionId == sessionId);
    public void RevokeMedia(IReadOnlyCollection<Guid> ids) => Cancel(stream => stream.MediaId is { } id && ids.Contains(id));

    private void Cancel(Func<Lease, bool> predicate)
    {
        // Cancel outside the lock: cancellation callbacks may dispose a stream lease.
        Lease[] affected;
        lock (gate) affected = streams.Where(predicate).ToArray();
        foreach (var lease in affected) lease.Cancel();
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
        public CancellationToken Token => source.Token;
        internal void Cancel() { lock (gate) { if (!disposed) source.Cancel(); } }
        public void Dispose()
        {
            lock (registry.gate) registry.streams.Remove(this);
            lock (gate) { if (!disposed) { disposed = true; source.Dispose(); } }
        }
    }
}
