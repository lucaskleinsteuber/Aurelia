using System.Threading.Channels;

namespace Aurelia.Home.Server.Services;

public sealed class MetadataJobScheduler
{
    private readonly Channel<Guid> channel = Channel.CreateUnbounded<Guid>(new UnboundedChannelOptions
    {
        SingleReader = true,
        SingleWriter = false,
    });

    public void Enqueue(Guid jobId) => channel.Writer.TryWrite(jobId);
    public IAsyncEnumerable<Guid> ReadAllAsync(CancellationToken cancellationToken) => channel.Reader.ReadAllAsync(cancellationToken);
}
