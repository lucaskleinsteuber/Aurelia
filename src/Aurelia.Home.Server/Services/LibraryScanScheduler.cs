using System.Threading.Channels;

namespace Aurelia.Home.Server.Services;

public sealed record QueuedLibraryScan(Guid ScanId, Guid LibraryId, string? TargetRelativePath);

public sealed class LibraryScanScheduler
{
    private readonly Channel<QueuedLibraryScan> channel = Channel.CreateUnbounded<QueuedLibraryScan>(
        new UnboundedChannelOptions
        {
            SingleReader = true,
            SingleWriter = false,
        });
    private readonly Lock gate = new();
    private readonly HashSet<Guid> reservedLibraries = [];

    public bool TryReserve(Guid libraryId)
    {
        lock (gate)
        {
            return reservedLibraries.Add(libraryId);
        }
    }

    public void Enqueue(Guid scanId, Guid libraryId, string? targetRelativePath = null)
    {
        if (!channel.Writer.TryWrite(new QueuedLibraryScan(
                scanId,
                libraryId,
                targetRelativePath)))
        {
            Release(libraryId);
            throw new InvalidOperationException("The library scan queue is unavailable.");
        }
    }

    public IAsyncEnumerable<QueuedLibraryScan> ReadAllAsync(CancellationToken cancellationToken)
    {
        return channel.Reader.ReadAllAsync(cancellationToken);
    }

    public void Release(Guid libraryId)
    {
        lock (gate)
        {
            reservedLibraries.Remove(libraryId);
        }
    }
}
