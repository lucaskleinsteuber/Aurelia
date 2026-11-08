using System.Runtime.InteropServices;
using LibVLCSharp.Shared;

namespace Aurelia.Linux.Playback;

/// <summary>
/// Decoded pictures in memory, in three BGRA buffers: VLC writes into the back buffer, a finished
/// frame becomes the ready one, and the screen takes the newest ready frame as its front buffer
/// and copies it without holding up the decoder. Only taking a buffer is done under the short
/// frame lock; the long copy holds a separate lock that only a size change waits for. Frames are
/// at most the size of the largest screen (<see cref="ScreenLimit"/>), since a bigger picture
/// would only be scaled down while drawing. Nothing is written to disk.
/// </summary>
public sealed class VideoFrames(int maximumWidth = -1) : IDisposable
{
    /// <summary>The longest side of the largest screen in device pixels; 0 keeps the video's own size.</summary>
    public static int ScreenLimit { get; set; }

    private readonly int limit = maximumWidth < 0 ? ScreenLimit : maximumWidth;
    private readonly Lock gate = new();
    private readonly Lock copying = new();
    private IntPtr front;
    private IntPtr ready;
    private IntPtr back;
    private bool fresh;
    private bool disposed;

    /// <summary>Raised on VLC's thread after a frame is complete; read it with <see cref="Copy"/>.</summary>
    public event Action? FrameReady;

    public int Width { get; private set; }

    public int Height { get; private set; }

    public int Pitch => Width * 4;

    public long Version { get; private set; }

    /// <summary>
    /// Makes the newest finished frame the front buffer. Called under <see cref="gate"/> while
    /// <see cref="copying"/> is held, so the front buffer stays valid for the copy that follows.
    /// </summary>
    private bool TakeNewest()
    {
        if (front == IntPtr.Zero || Version == 0) return false;
        if (fresh)
        {
            (front, ready) = (ready, front);
            fresh = false;
        }
        return true;
    }

    /// <summary>Copies a complete still without retaining decoder-owned buffers; only small preview frames may use it.</summary>
    internal Aurelia.Linux.Core.Playback.ScrubPreviewFrame? Snapshot()
    {
        lock (copying)
        {
            int width, height;
            lock (gate)
            {
                if (!TakeNewest() || Width <= 0 || Height <= 0 || (long)Width * Height > 320 * 320) return null;
                width = Width;
                height = Height;
            }
            var pixels = new byte[width * height * 4];
            Marshal.Copy(front, pixels, 0, pixels.Length);
            return new Aurelia.Linux.Core.Playback.ScrubPreviewFrame(width, height, pixels);
        }
    }

    public void Attach(MediaPlayer player)
    {
        player.SetVideoFormatCallbacks(Format, Cleanup);
        player.SetVideoCallbacks(LockFrame, null, Display);
    }

    /// <summary>
    /// Copies the newest frame into <paramref name="destination"/>, row by row with its own stride.
    /// The destination's size is checked first: if the video changed size since the caller looked,
    /// nothing is copied, so a larger frame never writes past a smaller bitmap. The decoder keeps
    /// writing its next frame meanwhile.
    /// </summary>
    public unsafe bool Copy(IntPtr destination, int destinationStride, int destinationWidth, int destinationHeight)
    {
        lock (copying)
        {
            int height, pitch;
            lock (gate)
            {
                if (!TakeNewest()) return false;
                if (Width != destinationWidth || Height != destinationHeight || destinationStride < Pitch) return false;
                height = Height;
                pitch = Pitch;
            }
            // Format, Cleanup and Dispose wait for this lock before they free the front buffer.
            if (destinationStride == pitch)
            {
                Buffer.MemoryCopy((byte*)front, (byte*)destination, (long)pitch * height, (long)pitch * height);
                return true;
            }
            for (var row = 0; row < height; row++)
                Buffer.MemoryCopy((byte*)front + (long)row * pitch, (byte*)destination + (long)row * destinationStride, pitch, pitch);
            return true;
        }
    }

    public void Dispose()
    {
        lock (copying)
            lock (gate)
            {
                disposed = true;
                Free();
            }
    }

    internal uint Format(ref IntPtr opaque, IntPtr chroma, ref uint width, ref uint height, ref uint pitches, ref uint lines)
    {
        if (limit > 0 && Math.Max(width, height) > limit)
        {
            var scale = (double)limit / Math.Max(width, height);
            width = Math.Max(1, (uint)(width * scale));
            height = Math.Max(1, (uint)(height * scale));
        }
        Marshal.Copy("RV32"u8.ToArray(), 0, chroma, 4);
        pitches = width * 4;
        lines = height;
        var bytes = checked((IntPtr)((long)pitches * lines));
        lock (copying)
            lock (gate)
            {
                if (disposed) return 0;
                Free();
                Width = (int)width;
                Height = (int)height;
                Version = 0;
                front = Marshal.AllocHGlobal(bytes);
                ready = Marshal.AllocHGlobal(bytes);
                back = Marshal.AllocHGlobal(bytes);
            }
        return 1;
    }

    private void Cleanup(ref IntPtr opaque)
    {
        lock (copying)
            lock (gate) Free();
    }

    internal IntPtr LockFrame(IntPtr opaque, IntPtr planes)
    {
        lock (gate) Marshal.WriteIntPtr(planes, back);
        return IntPtr.Zero;
    }

    internal void Display(IntPtr opaque, IntPtr picture)
    {
        lock (gate)
        {
            if (back == IntPtr.Zero) return;
            (ready, back) = (back, ready);
            fresh = true;
            Version++;
        }
        FrameReady?.Invoke();
    }

    /// <summary>Called with both locks held.</summary>
    private void Free()
    {
        if (front != IntPtr.Zero) Marshal.FreeHGlobal(front);
        if (ready != IntPtr.Zero) Marshal.FreeHGlobal(ready);
        if (back != IntPtr.Zero) Marshal.FreeHGlobal(back);
        front = IntPtr.Zero;
        ready = IntPtr.Zero;
        back = IntPtr.Zero;
        fresh = false;
        Width = 0;
        Height = 0;
    }
}
