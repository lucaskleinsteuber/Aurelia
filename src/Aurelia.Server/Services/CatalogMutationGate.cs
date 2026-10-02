namespace Aurelia.Server.Services;

// Serialize editor commits, provider writes and scan reconciliation. Network
// discovery/provider requests happen outside this short database critical section.
public sealed class CatalogMutationGate : IDisposable
{
    private readonly SemaphoreSlim gate = new(1, 1);
    public async Task<IDisposable> EnterAsync(CancellationToken token)
    {
        await gate.WaitAsync(token);
        return new Lease(gate);
    }
    public void Dispose() => gate.Dispose();
    private sealed class Lease(SemaphoreSlim gate) : IDisposable
    {
        private bool disposed;
        public void Dispose() { if (!disposed) { disposed = true; gate.Release(); } }
    }
}
