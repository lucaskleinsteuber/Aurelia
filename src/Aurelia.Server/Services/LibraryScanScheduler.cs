using System.Collections.Concurrent;
using System.Threading.Channels;

namespace Aurelia.Server.Services;

public sealed record QueuedLibraryScan(Guid ScanId, Guid LibraryId, string? TargetRelativePath);

public sealed class LibraryScanScheduler(ServerConfigurationStore configuration)
{
    private readonly Channel<bool> wake = Channel.CreateBounded<bool>(
        new BoundedChannelOptions(1)
        {
            SingleReader = true,
            SingleWriter = false,
            FullMode = BoundedChannelFullMode.DropWrite,
        });
    private readonly Lock gate = new();
    private readonly HashSet<Guid> reservedLibraries = [];
    private readonly ConcurrentDictionary<Guid, JobCancellationRegistration> active = new();

    public bool TryReserve(Guid libraryId)
    {
        lock (gate)
        {
            if (reservedLibraries.Count >= configuration.Current.JobQueueLimit) return false;
            return reservedLibraries.Add(libraryId);
        }
    }

    public void ReserveExisting(Guid libraryId)
    {
        lock (gate)
        {
            reservedLibraries.Add(libraryId);
        }
    }

    public void Release(Guid libraryId)
    {
        lock (gate)
        {
            reservedLibraries.Remove(libraryId);
        }
    }

    internal bool IsReserved(Guid libraryId)
    {
        lock (gate)
        {
            return reservedLibraries.Contains(libraryId);
        }
    }

    public void Pulse() => wake.Writer.TryWrite(true);

    public async Task WaitAsync(CancellationToken cancellationToken)
    {
        _ = await wake.Reader.ReadAsync(cancellationToken);
    }

    public CancellationToken Register(Guid scanId, CancellationToken stoppingToken)
    {
        var source = new JobCancellationRegistration(stoppingToken);
        if (!active.TryAdd(scanId, source))
        {
            source.Dispose();
            throw new InvalidOperationException("The scan is already registered as active.");
        }

        return source.Token;
    }

    public void Unregister(Guid scanId)
    {
        if (active.TryRemove(scanId, out var source))
        {
            source.Dispose();
        }
    }

    public void RequestCancellation(Guid scanId)
    {
        if (active.TryGetValue(scanId, out var source))
        {
            source.Cancel();
        }

        Pulse();
    }
}
