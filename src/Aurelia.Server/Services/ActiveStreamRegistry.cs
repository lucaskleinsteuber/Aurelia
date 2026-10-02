using Aurelia.Contracts;

namespace Aurelia.Server.Services;

public sealed class ActiveStreamRegistry
{
    private readonly object gate = new();
    private readonly HashSet<Lease> streams = [];
    public int Count { get { lock (gate) return streams.Count; } }

    public Lease Enter(Guid userId, Guid sessionId, int globalLimit, int userLimit, CancellationToken request)
    {
        lock (gate)
        {
            if (streams.Count >= globalLimit || streams.Count(stream => stream.UserId == userId) >= userLimit)
                throw new AccountException("stream_limit", "Too many simultaneous stream requests. Try again shortly.", 429);
            var lease = new Lease(this, userId, sessionId, request);
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
        internal Lease(ActiveStreamRegistry registry, Guid userId, Guid sessionId, CancellationToken request)
        {
            this.registry = registry;
            UserId = userId;
            SessionId = sessionId;
            source = CancellationTokenSource.CreateLinkedTokenSource(request);
        }
        public Guid UserId { get; }
        public Guid SessionId { get; }
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
