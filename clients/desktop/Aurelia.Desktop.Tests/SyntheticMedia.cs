using System.Buffers.Binary;
using System.Text;
using SkiaSharp;

namespace Aurelia.Desktop.Tests;

/// <summary>
/// Synthetic test media made here, without tools or personal files: a Motion-JPEG AVI whose
/// gray level changes every few seconds, and a WAV tone that is loud and then quiet.
/// </summary>
internal static class SyntheticMedia
{
    /// <summary>One key frame per second at `levels[second / secondsPerLevel]` brightness.</summary>
    public static void WriteAvi(string path, byte[] levels, int secondsPerLevel, int width = 320, int height = 180)
    {
        var frames = new List<byte[]>();
        for (var second = 0; second < levels.Length * secondsPerLevel; second++)
        {
            var level = levels[second / secondsPerLevel];
            using var bitmap = new SKBitmap(width, height, SKColorType.Rgba8888, SKAlphaType.Opaque);
            bitmap.Erase(new SKColor(level, level, level));
            using var image = SKImage.FromBitmap(bitmap);
            using var data = image.Encode(SKEncodedImageFormat.Jpeg, 85);
            frames.Add(data.ToArray());
        }

        using var stream = File.Create(path);
        using var writer = new BinaryWriter(stream, Encoding.ASCII);
        void FourCc(string value) => writer.Write(Encoding.ASCII.GetBytes(value));
        var largest = frames.Max(frame => frame.Length);

        FourCc("RIFF");
        var riffSize = stream.Position;
        writer.Write(0);
        FourCc("AVI ");

        FourCc("LIST");
        var headerSize = stream.Position;
        writer.Write(0);
        FourCc("hdrl");
        FourCc("avih");
        writer.Write(56);
        writer.Write(1_000_000); // microseconds per frame: one frame per second
        writer.Write(largest);
        writer.Write(0);
        writer.Write(0x10); // has index
        writer.Write(frames.Count);
        writer.Write(0);
        writer.Write(1);
        writer.Write(largest);
        writer.Write(width);
        writer.Write(height);
        writer.Write(new byte[16]);

        FourCc("LIST");
        var streamListSize = stream.Position;
        writer.Write(0);
        FourCc("strl");
        FourCc("strh");
        writer.Write(56);
        FourCc("vids");
        FourCc("MJPG");
        writer.Write(0);
        writer.Write((short)0);
        writer.Write((short)0);
        writer.Write(0);
        writer.Write(1); // scale
        writer.Write(1); // rate: 1 frame per second
        writer.Write(0);
        writer.Write(frames.Count);
        writer.Write(largest);
        writer.Write(-1);
        writer.Write(0);
        writer.Write((short)0);
        writer.Write((short)0);
        writer.Write((short)width);
        writer.Write((short)height);
        FourCc("strf");
        writer.Write(40);
        writer.Write(40);
        writer.Write(width);
        writer.Write(height);
        writer.Write((short)1);
        writer.Write((short)24);
        FourCc("MJPG");
        writer.Write(width * height * 3);
        writer.Write(new byte[16]);
        Patch(stream, writer, streamListSize);
        Patch(stream, writer, headerSize);

        FourCc("LIST");
        var moviSize = stream.Position;
        writer.Write(0);
        var moviStart = stream.Position;
        FourCc("movi");
        var index = new List<(int Offset, int Size)>();
        foreach (var frame in frames)
        {
            index.Add(((int)(stream.Position - moviStart), frame.Length));
            FourCc("00dc");
            writer.Write(frame.Length);
            writer.Write(frame);
            if (frame.Length % 2 == 1) writer.Write((byte)0);
        }
        Patch(stream, writer, moviSize);

        FourCc("idx1");
        writer.Write(index.Count * 16);
        foreach (var (offset, size) in index)
        {
            FourCc("00dc");
            writer.Write(0x10); // key frame
            writer.Write(offset);
            writer.Write(size);
        }
        Patch(stream, writer, riffSize);
    }

    /// <summary>A 48 kHz stereo 16-bit WAV: `loudSeconds` of a loud tone, then the same tone quiet.</summary>
    public static void WriteWav(string path, int loudSeconds, int quietSeconds)
    {
        const int rate = 48_000;
        var samples = new List<short>();
        void Tone(double amplitude, int seconds)
        {
            for (var index = 0; index < rate * seconds; index++)
            {
                var value = (short)(amplitude * Math.Sin(index * 2 * Math.PI * 440 / rate) * short.MaxValue);
                samples.Add(value);
                samples.Add(value);
            }
        }
        Tone(0.9, loudSeconds);
        Tone(0.02, quietSeconds);
        using var writer = new BinaryWriter(File.Create(path), Encoding.ASCII);
        writer.Write(Encoding.ASCII.GetBytes("RIFF"));
        writer.Write(36 + samples.Count * 2);
        writer.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
        writer.Write(16);
        writer.Write((short)1);
        writer.Write((short)2);
        writer.Write(rate);
        writer.Write(rate * 4);
        writer.Write((short)4);
        writer.Write((short)16);
        writer.Write(Encoding.ASCII.GetBytes("data"));
        writer.Write(samples.Count * 2);
        foreach (var sample in samples) writer.Write(sample);
    }

    /// <summary>Interleaved 16-bit samples of a WAV file VLC wrote.</summary>
    public static short[] ReadWav(string path)
    {
        var bytes = File.ReadAllBytes(path);
        var offset = 12;
        while (offset + 8 <= bytes.Length)
        {
            var id = Encoding.ASCII.GetString(bytes, offset, 4);
            var size = BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(offset + 4));
            if (id == "data")
            {
                var end = Math.Min(bytes.Length, offset + 8 + size);
                var samples = new short[(end - offset - 8) / 2];
                for (var index = 0; index < samples.Length; index++)
                    samples[index] = BinaryPrimitives.ReadInt16LittleEndian(bytes.AsSpan(offset + 8 + index * 2));
                return samples;
            }
            offset += 8 + size + size % 2;
        }
        return [];
    }

    /// <summary>Average green value of a BGRA frame.</summary>
    /// <summary>A plain synthetic picture for image uploads.</summary>
    public static byte[] Png(int width, int height)
    {
        using var bitmap = new SkiaSharp.SKBitmap(width, height);
        bitmap.Erase(new SkiaSharp.SKColor(60, 90, 160));
        using var image = SkiaSharp.SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SkiaSharp.SKEncodedImageFormat.Png, 90);
        return data.ToArray();
    }

    public static double Brightness(byte[] bgra)
    {
        long total = 0;
        var count = 0;
        for (var index = 1; index < bgra.Length; index += 4 * 97)
        {
            total += bgra[index];
            count++;
        }
        return count == 0 ? 0 : (double)total / count;
    }

    private static void Patch(Stream stream, BinaryWriter writer, long sizePosition)
    {
        var end = stream.Position;
        stream.Position = sizePosition;
        writer.Write((int)(end - sizePosition - 4));
        stream.Position = end;
    }
}
