namespace Aurelia.Server.Services.Segments;

/// <summary>What one small picture from an episode's ending shows, for finding its credits.</summary>
public enum PictureKind : byte
{
    /// <summary>Anything else: a scene, a logo, text over moving pictures.</summary>
    Other,

    /// <summary>A black picture, as between credit cards or in a fade.</summary>
    Black,

    /// <summary>Sharp text on black, the usual look of end credits.</summary>
    Text,
}

/// <summary>
/// The pictures of an episode's ending, reduced to what credits detection needs: each picture's
/// kind and a 32 × 18 thumbnail for comparing with other episodes. Exists only in memory.
/// </summary>
/// <param name="StartSeconds">Where the first picture is in the file.</param>
/// <param name="StepSeconds">Time between pictures.</param>
/// <param name="Thumbnails">Thumbnails with mean 0 and length 1, or null for an even picture.</param>
public sealed record PictureWindow(double StartSeconds, double StepSeconds, PictureKind[] Kinds, float[]?[] Thumbnails)
{
    public double Time(int index) => StartSeconds + index * StepSeconds;
}

/// <summary>
/// Finds end credits in pictures. Credits are either sharp text on a black screen, or pictures
/// that other episodes of the season show too (a title card behind the names). They must last
/// until shortly before the end of the file; anything that is not certain is left out.
/// </summary>
public static class CreditsPictures
{
    public const int Width = 320;
    public const int Height = 180;
    public const int FrameBytes = Width * Height;
    public const int FramesPerSecond = 2;

    /// <summary>The ending that is searched: six minutes or a quarter of the episode, whichever is shorter.</summary>
    public static double WindowSeconds(double duration) => Math.Min(360, duration * 0.25);

    private const int BlackLevel = 20;
    private const int BrightLevel = 140;
    private const int EdgeStep = 60;
    private const int ThumbnailWidth = 32;
    private const int ThumbnailHeight = 18;
    private const double SharedCorrelation = 0.92;
    private const double MaximumGapSeconds = 3;
    private const double MaximumTailSeconds = 30;
    private const double MinimumSeconds = 12;
    private const double MinimumPositiveShare = 0.6;

    /// <summary>Statistics of one 320 × 180 grey picture.</summary>
    public readonly record struct PictureMeasure(double Black, double Mid, int Edges, int UpperEdges, double Even = 1);

    public static PictureMeasure Measure(ReadOnlySpan<byte> picture)
    {
        if (picture.Length != FrameBytes) throw new ArgumentException("A picture is 320 × 180 grey pixels.", nameof(picture));
        int black = 0, mid = 0, edges = 0, upper = 0;
        Span<int> histogram = stackalloc int[256];
        // Subtitles sit in the lowest fifth; credits text does not need it to count.
        const int SubtitleRows = Height * 4 / 5;
        for (var y = 0; y < Height; y++)
        {
            var row = picture.Slice(y * Width, Width);
            for (var x = 0; x < Width; x++)
            {
                var value = row[x];
                histogram[value]++;
                if (value <= BlackLevel) black++;
                else if (value < BrightLevel) mid++;
                if (x + 1 < Width && Math.Abs(value - row[x + 1]) >= EdgeStep)
                {
                    edges++;
                    if (y < SubtitleRows) upper++;
                }
            }
        }
        // The background's level: the darkest values, ignoring a few stray pixels. Credits sit on an
        // even black, so nearly every pixel is within a few levels of it; a dark scene's shadows
        // spread over many levels of grey.
        var floor = 0;
        for (var seen = 0; floor < 255 && (seen += histogram[floor]) < FrameBytes / 50; floor++) { }
        var even = 0;
        for (var level = 0; level <= Math.Min(255, floor + 4); level++) even += histogram[level];
        return new PictureMeasure((double)black / FrameBytes, (double)mid / FrameBytes, edges, upper, (double)even / FrameBytes);
    }

    /// <summary>
    /// Text on black: nearly every pixel black, most of them one even level, almost no grey, and
    /// many sharp edges. A dark scene's shadows spread over many levels even where lamps make hard
    /// edges; subtitles alone have their edges only at the bottom.
    /// </summary>
    public static PictureKind Classify(PictureMeasure measure)
    {
        if (measure.Black >= 0.99 && measure.Edges < 60) return PictureKind.Black;
        if (measure.Black >= 0.90 && measure.Even >= 0.75 && measure.Mid <= 0.06 && measure.Edges >= 250 && measure.UpperEdges >= 150)
            return PictureKind.Text;
        return PictureKind.Other;
    }

    /// <summary>A 32 × 18 thumbnail with mean 0 and length 1, or null when the picture is nearly even.</summary>
    public static float[]? Thumbnail(ReadOnlySpan<byte> picture)
    {
        const int BlockWidth = Width / ThumbnailWidth;
        const int BlockHeight = Height / ThumbnailHeight;
        var values = new float[ThumbnailWidth * ThumbnailHeight];
        for (var by = 0; by < ThumbnailHeight; by++)
        {
            for (var bx = 0; bx < ThumbnailWidth; bx++)
            {
                var sum = 0;
                for (var y = by * BlockHeight; y < (by + 1) * BlockHeight; y++)
                {
                    for (var x = bx * BlockWidth; x < (bx + 1) * BlockWidth; x++) sum += picture[y * Width + x];
                }
                values[by * ThumbnailWidth + bx] = sum / (float)(BlockWidth * BlockHeight);
            }
        }
        var mean = values.Average();
        double squares = 0;
        for (var index = 0; index < values.Length; index++)
        {
            values[index] -= mean;
            squares += values[index] * values[index];
        }
        // An even picture (black, a single color) says nothing about which picture it is.
        var deviation = Math.Sqrt(squares / values.Length);
        if (deviation < 10) return null;
        var scale = (float)(1 / Math.Sqrt(squares));
        for (var index = 0; index < values.Length; index++) values[index] *= scale;
        return values;
    }

    /// <summary>Builds a window from 320 × 180 grey pictures taken <see cref="FramesPerSecond"/> times a second.</summary>
    public static PictureWindow FromPictures(IReadOnlyList<byte[]> pictures, double startSeconds)
    {
        ArgumentNullException.ThrowIfNull(pictures);
        var builder = new Builder(startSeconds);
        foreach (var picture in pictures) builder.Add(picture);
        return builder.Build();
    }

    /// <summary>Collects pictures one by one, keeping only their kind and thumbnail.</summary>
    public sealed class Builder(double startSeconds)
    {
        private readonly List<PictureKind> kinds = [];
        private readonly List<float[]?> thumbnails = [];

        public int Count => kinds.Count;

        public void Add(ReadOnlySpan<byte> picture)
        {
            var kind = Classify(Measure(picture));
            kinds.Add(kind);
            thumbnails.Add(kind == PictureKind.Other ? Thumbnail(picture) : null);
        }

        public PictureWindow Build() => new(startSeconds, 1.0 / FramesPerSecond, [.. kinds], [.. thumbnails]);
    }

    /// <summary>
    /// Marks the pictures of <paramref name="own"/> that are also in enough of the other episodes'
    /// endings: in two of them, or in the only one a two-episode season has.
    /// </summary>
    public static bool[] Shared(PictureWindow own, IReadOnlyList<PictureWindow> partners)
    {
        ArgumentNullException.ThrowIfNull(own);
        ArgumentNullException.ThrowIfNull(partners);
        var shared = new bool[own.Kinds.Length];
        if (partners.Count == 0) return shared;
        var needed = Math.Min(2, partners.Count);
        for (var index = 0; index < shared.Length; index++)
        {
            if (own.Thumbnails[index] is not { } thumbnail) continue;
            var found = 0;
            foreach (var partner in partners)
            {
                if (Contains(partner, thumbnail) && ++found >= needed) break;
            }
            shared[index] = found >= needed;
        }
        return shared;
    }

    private static bool Contains(PictureWindow window, float[] thumbnail)
    {
        foreach (var other in window.Thumbnails)
        {
            if (other is null) continue;
            double dot = 0;
            for (var index = 0; index < thumbnail.Length; index++) dot += thumbnail[index] * other[index];
            if (dot >= SharedCorrelation) return true;
        }
        return false;
    }

    /// <summary>Where a reference stretch of pictures appears in a window, and how much of it matched.</summary>
    /// <param name="Offset">Seconds to add to a time in the reference to get the same picture in the window.</param>
    public readonly record struct Alignment(double Offset, double Share);

    /// <summary>
    /// Finds <paramref name="reference"/> (such as another episode's intro) in <paramref name="window"/>:
    /// matching pictures vote for a shift, and the share of the reference's pictures found at the
    /// winning shift tells how complete the match is. Even pictures (black, one color) do not count.
    /// </summary>
    public static Alignment? Align(PictureWindow window, PictureWindow reference)
    {
        ArgumentNullException.ThrowIfNull(window);
        ArgumentNullException.ThrowIfNull(reference);
        var usable = Enumerable.Range(0, reference.Thumbnails.Length).Where(index => reference.Thumbnails[index] is not null).ToArray();
        if (usable.Length < 10 || Math.Abs(window.StepSeconds - reference.StepSeconds) > 1e-6) return null;
        var baseShift = (int)Math.Round((window.StartSeconds - reference.StartSeconds) / window.StepSeconds);
        var matches = new Dictionary<int, HashSet<int>>();
        foreach (var index in usable)
        {
            var thumbnail = reference.Thumbnails[index]!;
            for (var other = 0; other < window.Thumbnails.Length; other++)
            {
                if (window.Thumbnails[other] is not { } candidate) continue;
                double dot = 0;
                for (var pixel = 0; pixel < thumbnail.Length; pixel++) dot += thumbnail[pixel] * candidate[pixel];
                if (dot < SharedCorrelation) continue;
                var shift = other - index;
                if (!matches.TryGetValue(shift, out var found)) matches[shift] = found = [];
                found.Add(index);
            }
        }
        if (matches.Count == 0) return null;
        // A shift and its neighbours together, since pictures are taken half a second apart.
        var best = matches.Keys.Select(shift => (Shift: shift, Found: new[] { shift - 1, shift, shift + 1 }
                .Where(matches.ContainsKey).SelectMany(near => matches[near]).Distinct().Count()))
            .OrderByDescending(entry => entry.Found).ThenBy(entry => Math.Abs(entry.Shift)).First();
        return new Alignment((best.Shift + baseShift) * window.StepSeconds, (double)best.Found / usable.Length);
    }

    /// <summary>Credits found in pictures: where they begin and how much of them clearly looked like credits.</summary>
    public readonly record struct Result(double Start, double End, double Confidence);

    /// <summary>
    /// The credits of an episode of <paramref name="duration"/> seconds: the longest stretch of text
    /// on black and shared pictures (with black between them and gaps of at most three seconds)
    /// that lasts until at most 30 seconds before the end, such as studio logos after the names.
    /// </summary>
    public static Result? Find(PictureWindow window, bool[] shared, double duration)
    {
        ArgumentNullException.ThrowIfNull(window);
        ArgumentNullException.ThrowIfNull(shared);
        var count = window.Kinds.Length;
        if (count == 0) return null;
        bool Positive(int index) => window.Kinds[index] == PictureKind.Text || (index < shared.Length && shared[index]);
        bool CreditLike(int index) => Positive(index) || window.Kinds[index] == PictureKind.Black;
        var gapFrames = (int)Math.Round(MaximumGapSeconds / window.StepSeconds);

        Result? best = null;
        var index = 0;
        while (index < count)
        {
            if (!Positive(index))
            {
                index++;
                continue;
            }
            // A stretch starts at a positive picture; black pictures continue it, and other
            // pictures only for up to three seconds in a row.
            var start = index;
            var last = index;
            var lastCreditLike = index;
            var cursor = index + 1;
            for (; cursor < count; cursor++)
            {
                if (CreditLike(cursor))
                {
                    lastCreditLike = cursor;
                    if (Positive(cursor)) last = cursor;
                }
                else if (cursor - lastCreditLike > gapFrames)
                {
                    break;
                }
            }
            index = cursor;

            var startTime = window.Time(start);
            var endTime = window.Time(last) + window.StepSeconds;
            if (duration - endTime > MaximumTailSeconds || endTime - startTime < MinimumSeconds) continue;
            int positives = 0, considered = 0;
            for (var frame = start; frame <= last; frame++)
            {
                if (window.Kinds[frame] == PictureKind.Black) continue;
                considered++;
                if (Positive(frame)) positives++;
            }
            var share = considered == 0 ? 0 : (double)positives / considered;
            if (share < MinimumPositiveShare || positives * window.StepSeconds < MinimumSeconds * 0.6) continue;
            if (best is null || endTime - startTime > best.Value.End - best.Value.Start)
            {
                best = new Result(startTime, endTime, Math.Round(share, 3));
            }
        }
        return best;
    }
}
