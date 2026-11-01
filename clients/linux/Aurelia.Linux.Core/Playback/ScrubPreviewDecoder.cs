namespace Aurelia.Linux.Core.Playback;

/// <summary>A small BGRA still in memory. Converted video and preview streams are never written to disk.</summary>
public sealed record ScrubPreviewFrame(int Width, int Height, byte[] Pixels);

/// <summary>A separate, silent decoder for one timeline still; tests supply invented pixels.</summary>
public interface IScrubPreviewDecoder : IDisposable
{
    Task<ScrubPreviewFrame?> CaptureAsync(Uri loopbackSource, long milliseconds, CancellationToken cancellation);
}

public interface IScrubPreviewDecoderFactory
{
    IScrubPreviewDecoder CreatePreviewDecoder();
}
