using System.Runtime.InteropServices;
using LibVLCSharp.Shared;

namespace Aurelia.Linux.Playback;

/// <summary>
/// Decoded pictures in memory: VLC writes each frame into a back buffer in BGRA, and the newest
/// complete frame is swapped to the front for the screen to copy. Frames stay at full size, since
/// the graphics card scales them while drawing. Nothing is written to disk.
/// </summary>
public sealed class VideoFrames(int maximumWidth = 0) : IDisposable
{
    private readonly Lock gate = new();
    private IntPtr front;
    private IntPtr back;
    private bool disposed;

    /// <summary>Raised on VLC's thread after a frame is complete; read it with <see cref="Copy"/>.</summary>
    public event Action? FrameReady;

    public int Width { get; private set; }

    public int Height { get; private set; }

    public int Pitch => Width * 4;

    public long Version { get; private set; }

    /// <summary>Copies a complete still without retaining decoder-owned buffers; only small preview frames may use it.</summary>
    internal Aurelia.Linux.Core.Playback.ScrubPreviewFrame? Snapshot()
    {
        lock (gate)
        {
            if (front == IntPtr.Zero || Version == 0 || Width <= 0 || Height <= 0 || (long)Width * Height > 320 * 320) return null;
            var pixels = new byte[Width * Height * 4];
            Marshal.Copy(front, pixels, 0, pixels.Length);
            return new Aurelia.Linux.Core.Playback.ScrubPreviewFrame(Width, Height, pixels);
        }
    }

    public void Attach(MediaPlayer player)
    {
        player.SetVideoFormatCallbacks(Format, Cleanup);
        player.SetVideoCallbacks(LockFrame, null, Display);
    }

    /// <summary>Copies the newest frame into <paramref name="destination"/>, row by row with its own stride.</summary>
    public unsafe bool Copy(IntPtr destination, int destinationStride)
    {
        lock (gate)
        {
            if (front == IntPtr.Zero || Version == 0) return false;
            var rowBytes = Math.Min(Pitch, destinationStride);
            if (rowBytes == destinationStride && rowBytes == Pitch)
            {
                Buffer.MemoryCopy((byte*)front, (byte*)destination, (long)Pitch * Height, (long)Pitch * Height);
                return true;
            }
            for (var row = 0; row < Height; row++)
            {
                Buffer.MemoryCopy((byte*)front + (long)row * Pitch, (byte*)destination + (long)row * destinationStride, rowBytes, rowBytes);
            }
            return true;
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            disposed = true;
            Free();
        }
    }

    internal uint Format(ref IntPtr opaque, IntPtr chroma, ref uint width, ref uint height, ref uint pitches, ref uint lines)
    {
        if (maximumWidth > 0 && Math.Max(width, height) > maximumWidth)
        {
            var scale = (double)maximumWidth / Math.Max(width, height);
            width = Math.Max(1, (uint)(width * scale));
            height = Math.Max(1, (uint)(height * scale));
        }
        Marshal.Copy("RV32"u8.ToArray(), 0, chroma, 4);
        pitches = width * 4;
        lines = height;
        lock (gate)
        {
            if (disposed) return 0;
            Free();
            Width = (int)width;
            Height = (int)height;
            Version = 0;
            front = Marshal.AllocHGlobal(checked((IntPtr)((long)pitches * lines)));
            back = Marshal.AllocHGlobal(checked((IntPtr)((long)pitches * lines)));
        }
        return 1;
    }

    private void Cleanup(ref IntPtr opaque)
    {
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
            (front, back) = (back, front);
            Version++;
        }
        FrameReady?.Invoke();
    }

    private void Free()
    {
        if (front != IntPtr.Zero) Marshal.FreeHGlobal(front);
        if (back != IntPtr.Zero) Marshal.FreeHGlobal(back);
        front = IntPtr.Zero;
        back = IntPtr.Zero;
        Width = 0;
        Height = 0;
    }
}
