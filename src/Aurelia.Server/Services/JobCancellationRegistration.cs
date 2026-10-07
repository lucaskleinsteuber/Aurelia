namespace Aurelia.Server.Services;

// A concurrent dictionary does not synchronize the lifetime of its values.
// Cancel and Dispose share this gate so a finishing job cannot dispose the
// source after a cancellation caller has retrieved it.
internal sealed class JobCancellationRegistration : IDisposable
{
    private readonly object gate = new();
    private readonly CancellationTokenSource source;
    private bool disposed;
    private int cancelling;
    public JobCancellationRegistration(CancellationToken stoppingToken)
    {
        source = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
        Token = source.Token;
    }
    public CancellationToken Token { get; }
    public bool Cancel()
    {
        lock (gate)
        {
            if (disposed) return false;
            cancelling++;
        }
        // Cancellation invokes user callbacks synchronously. Do not hold our
        // lock while callbacks unregister this job or wait for another thread.
        try { source.Cancel(); return true; }
        finally
        {
            lock (gate)
            {
                cancelling--;
                if (disposed && cancelling == 0) source.Dispose();
            }
        }
    }
    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            if (cancelling == 0) source.Dispose();
        }
    }
}
