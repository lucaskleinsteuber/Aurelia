namespace Aurelia.Server.Services;

/// <summary>
/// Passes a media file through unchanged and notes each read on its stream lease, so the server
/// knows a device is watching rather than just holding a paused connection open.
/// </summary>
public sealed class PlaybackReadStream(Stream inner, ActiveStreamRegistry.Lease lease) : Stream
{
    public override bool CanRead => inner.CanRead;
    public override bool CanSeek => inner.CanSeek;
    public override bool CanWrite => false;
    public override long Length => inner.Length;
    public override long Position { get => inner.Position; set => inner.Position = value; }

    public override int Read(byte[] buffer, int offset, int count) => Noted(inner.Read(buffer, offset, count));
    public override int Read(Span<byte> buffer) => Noted(inner.Read(buffer));
    public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        Noted(await inner.ReadAsync(buffer.AsMemory(offset, count), cancellationToken));
    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) =>
        Noted(await inner.ReadAsync(buffer, cancellationToken));

    public override long Seek(long offset, SeekOrigin origin) => inner.Seek(offset, origin);
    public override void Flush() { }
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

    protected override void Dispose(bool disposing)
    {
        if (disposing) inner.Dispose();
        base.Dispose(disposing);
    }

    public override async ValueTask DisposeAsync()
    {
        await inner.DisposeAsync();
        await base.DisposeAsync();
    }

    private int Noted(int read)
    {
        if (read > 0) lease.MarkRead();
        return read;
    }
}
