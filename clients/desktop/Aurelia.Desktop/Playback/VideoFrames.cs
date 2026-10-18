using System.Runtime.InteropServices;
using LibVLCSharp.Shared;

namespace Aurelia.Desktop.Playback;

/// <summary>
/// Decoded pictures in memory: VLC writes each frame into a back buffer in BGRA, and the newest
/// complete frame is swapped to the front for the screen to copy. Nothing is written to disk.
/// </summary>
public sealed class VideoFrames : IDisposable
{
    private readonly Lock gate = new();
    private readonly int maximumWidth;
    private IntPtr front;
    private IntPtr back;
    private bool disposed;

    public VideoFrames(int maximumWidth = 1920) => this.maximumWidth = maximumWidth;

    /// <summary>Raised on VLC's thread after a frame is complete; read it with <see cref="Copy"/>.</summary>
    public event Action? FrameReady;

    public int Width { get; private set; }
    public int Height { get; private set; }
    public int Pitch => Width * 4;
    public long Version { get; private set; }

    public void Attach(MediaPlayer player)
    {
        player.SetVideoFormatCallbacks(Format, Cleanup);
        player.SetVideoCallbacks(LockFrame, null, Display);
    }

    /// <summary>Copies the newest frame into `destination` (row by row with its own stride).</summary>
    public bool Copy(IntPtr destination, int destinationStride, int width, int height)
    {
        lock (gate)
        {
            if (front == IntPtr.Zero || width != Width || height != Height || Version == 0) return false;
            var rowBytes = Math.Min(Pitch, destinationStride);
            unsafe
            {
                for (var row = 0; row < height; row++)
                {
                    Buffer.MemoryCopy((byte*)front + (long)row * Pitch, (byte*)destination + (long)row * destinationStride, rowBytes, rowBytes);
                }
            }
            return true;
        }
    }

    /// <summary>The newest frame as a copy, for preview frames.</summary>
    public byte[]? Snapshot(out int width, out int height)
    {
        lock (gate)
        {
            width = Width;
            height = Height;
            if (front == IntPtr.Zero || Version == 0) return null;
            var bytes = new byte[Pitch * Height];
            Marshal.Copy(front, bytes, 0, bytes.Length);
            return bytes;
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

    private uint Format(ref IntPtr opaque, IntPtr chroma, ref uint width, ref uint height, ref uint pitches, ref uint lines)
    {
        // Scale large pictures down: copying 4K frames would cost more than it shows on most screens.
        if (width > maximumWidth)
        {
            height = (uint)Math.Max(2, Math.Round(height * (double)maximumWidth / width / 2) * 2);
            width = (uint)maximumWidth;
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

    private IntPtr LockFrame(IntPtr opaque, IntPtr planes)
    {
        lock (gate) Marshal.WriteIntPtr(planes, back);
        return IntPtr.Zero;
    }

    private void Display(IntPtr opaque, IntPtr picture)
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
