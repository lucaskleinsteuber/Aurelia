using System.Collections.Concurrent;
using System.Threading.Channels;

namespace Aurelia.Server.Services;

public sealed class MetadataJobScheduler
{
    private readonly Channel<bool> wake = Channel.CreateBounded<bool>(new BoundedChannelOptions(1)
    {
        FullMode = BoundedChannelFullMode.DropWrite,
        SingleReader = true,
        SingleWriter = false,
    });
    private readonly ConcurrentDictionary<Guid, JobCancellationRegistration> active = new();

    public int ActiveCount => active.Count;

    public void Pulse() => wake.Writer.TryWrite(true);

    public async Task WaitAsync(CancellationToken cancellationToken) =>
        _ = await wake.Reader.ReadAsync(cancellationToken);

    public CancellationToken Register(Guid jobId, CancellationToken stoppingToken)
    {
        var source = new JobCancellationRegistration(stoppingToken);
        if (!active.TryAdd(jobId, source))
        {
            source.Dispose();
            throw new InvalidOperationException("The metadata job is already active.");
        }

        return source.Token;
    }

    public bool RequestCancellation(Guid jobId)
    {
        if (!active.TryGetValue(jobId, out var source))
        {
            Pulse();
            return false;
        }

        return source.Cancel();
    }

    public void Unregister(Guid jobId)
    {
        if (active.TryRemove(jobId, out var source))
        {
            source.Dispose();
        }
    }
}
