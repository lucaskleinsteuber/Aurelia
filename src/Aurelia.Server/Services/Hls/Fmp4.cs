using System.Buffers.Binary;
using System.Text;

namespace Aurelia.Server.Services.Hls;

/// <summary>The start of a fragmented MP4 stream: ftyp and moov, plus what is needed to place fragments in title time.</summary>
/// <param name="Data">ftyp and moov as one init segment.</param>
/// <param name="VideoTrackId">The picture track's id; its fragments decide the time.</param>
/// <param name="Timescale">The picture track's ticks per second.</param>
/// <param name="Descriptions">The sample descriptions (stsd) of every track: equal ones decode the same segments.</param>
public sealed record Fmp4Init(byte[] Data, uint VideoTrackId, uint Timescale, byte[] Descriptions);

/// <summary>One moof and its mdat, and where it starts in the title.</summary>
public sealed record Fmp4Fragment(double Start, byte[] Data);

/// <summary>
/// Reads ffmpeg's fragmented MP4 from its standard output box by box, in memory only. Sizes are
/// checked before anything is allocated, so a broken stream ends the read instead of the server.
/// </summary>
public static class Fmp4
{
    /// <summary>The largest box accepted; a 4-second segment of a 1080p picture is a few megabytes.</summary>
    public const int MaximumBoxBytes = 32 * 1024 * 1024;

    public sealed record Box(string Type, byte[] Data);

    /// <summary>The next whole top-level box, or null at the end of the stream.</summary>
    /// <exception cref="InvalidDataException">The stream is cut off or a box is too large.</exception>
    public static async Task<Box?> ReadBoxAsync(Stream stream, CancellationToken cancellationToken, int maximumBytes = MaximumBoxBytes)
    {
        var header = new byte[8];
        var first = await ReadAtLeastAsync(stream, header, cancellationToken);
        if (first == 0) return null;
        if (first < 8) throw new InvalidDataException("The stream ended inside a box header.");
        long size = BinaryPrimitives.ReadUInt32BigEndian(header);
        var type = Encoding.ASCII.GetString(header, 4, 4);
        var headerLength = 8;
        byte[]? large = null;
        if (size == 1)
        {
            large = new byte[8];
            if (await ReadAtLeastAsync(stream, large, cancellationToken) < 8) throw new InvalidDataException("The stream ended inside a box header.");
            size = (long)BinaryPrimitives.ReadUInt64BigEndian(large);
            headerLength = 16;
        }
        if (size < headerLength || size > maximumBytes) throw new InvalidDataException($"A {Printable(type)} box has an unusable size.");
        var data = new byte[size];
        header.CopyTo(data, 0);
        large?.CopyTo(data, 8);
        if (await ReadAtLeastAsync(stream, data.AsMemory(headerLength), cancellationToken) < size - headerLength)
            throw new InvalidDataException("The stream ended inside a box.");
        return new Box(type, data);
    }

    private static async Task<int> ReadAtLeastAsync(Stream stream, Memory<byte> buffer, CancellationToken cancellationToken) =>
        await stream.ReadAtLeastAsync(buffer, buffer.Length, throwOnEndOfStream: false, cancellationToken);

    private static string Printable(string type) => new(type.Select(character => char.IsAsciiLetterOrDigit(character) ? character : '?').ToArray());

    /// <summary>The init segment from ftyp and moov, with the picture track's id and timescale.</summary>
    /// <exception cref="InvalidDataException">The moov holds no picture track.</exception>
    public static Fmp4Init ParseInit(byte[] ftyp, byte[] moov)
    {
        uint? videoTrack = null;
        uint timescale = 0;
        using var descriptions = new MemoryStream();
        foreach (var trak in Children(moov, 8).Where(child => child.Type == "trak"))
        {
            var tkhd = Find(moov, trak, "tkhd");
            var mdia = Find(moov, trak, "mdia");
            if (tkhd is null || mdia is null) continue;
            var hdlr = Find(moov, mdia.Value, "hdlr");
            var mdhd = Find(moov, mdia.Value, "mdhd");
            var stsd = Find(moov, mdia.Value, "minf") is { } minf && Find(moov, minf, "stbl") is { } stbl ? Find(moov, stbl, "stsd") : null;
            if (stsd is { } description) descriptions.Write(moov, description.Start, description.Length);
            // hdlr: version and flags (4), pre_defined (4), handler type (4).
            if (videoTrack is null && hdlr is { } handler && mdhd is { } header && handler.Length >= 20
                && Encoding.ASCII.GetString(moov, handler.Start + 16, 4) == "vide")
            {
                var version = moov[tkhd.Value.Start + 8];
                videoTrack = BinaryPrimitives.ReadUInt32BigEndian(moov.AsSpan(tkhd.Value.Start + (version == 1 ? 28 : 20)));
                var mdhdVersion = moov[header.Start + 8];
                timescale = BinaryPrimitives.ReadUInt32BigEndian(moov.AsSpan(header.Start + (mdhdVersion == 1 ? 28 : 20)));
            }
        }
        if (videoTrack is not { } track || timescale == 0) throw new InvalidDataException("The stream has no picture track.");
        var data = new byte[ftyp.Length + moov.Length];
        ftyp.CopyTo(data, 0);
        moov.CopyTo(data, ftyp.Length);
        return new Fmp4Init(data, track, timescale, descriptions.ToArray());
    }

    /// <summary>The picture track's decode time in the fragment, in seconds; null when the fragment holds no picture.</summary>
    public static double? FragmentStart(byte[] moof, Fmp4Init init)
    {
        foreach (var traf in Children(moof, 8).Where(child => child.Type == "traf"))
        {
            if (Find(moof, traf, "tfhd") is not { } tfhd || tfhd.Length < 16) continue;
            if (BinaryPrimitives.ReadUInt32BigEndian(moof.AsSpan(tfhd.Start + 12)) != init.VideoTrackId) continue;
            if (Find(moof, traf, "tfdt") is not { } tfdt || tfdt.Length < 16) return null;
            var time = moof[tfdt.Start + 8] == 1 && tfdt.Length >= 20
                ? BinaryPrimitives.ReadUInt64BigEndian(moof.AsSpan(tfdt.Start + 12))
                : BinaryPrimitives.ReadUInt32BigEndian(moof.AsSpan(tfdt.Start + 12));
            return (double)time / init.Timescale;
        }
        return null;
    }

    private readonly record struct Range(string Type, int Start, int Length);

    private static Range? Find(byte[] data, Range parent, string type) =>
        Children(data, parent.Start + 8, parent.Start + parent.Length).FirstOrDefault(child => child.Type == type) is { Length: > 0 } found ? found : null;

    private static IEnumerable<Range> Children(byte[] data, int start, int? end = null)
    {
        var limit = end ?? data.Length;
        for (var offset = start; offset + 8 <= limit;)
        {
            var size = (long)BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(offset));
            if (size < 8 || offset + size > limit) yield break;
            yield return new Range(Encoding.ASCII.GetString(data, offset + 4, 4), offset, (int)size);
            offset += (int)size;
        }
    }
}
