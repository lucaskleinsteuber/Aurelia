namespace Aurelia.Server.Services;

public enum HdrToneMapping
{
    Unavailable,
    /// <summary>FFmpeg's LGPL native color mapper, available in the bundled FFmpeg 9 scale filter.</summary>
    PerceptualScale,
    /// <summary>The zscale and tonemap filters supplied by some older Linux distribution builds.</summary>
    Zscale,
}

/// <summary>HDR-to-SDR decisions and filter arguments; never changes a picture being copied.</summary>
public static class LiveHdr
{
    private static readonly string[] NativeScaleOptions = ["out_transfer", "out_primaries", "intent", "perceptual"];
    private static readonly IReadOnlyDictionary<string, int> Primaries = new Dictionary<string, int>(StringComparer.Ordinal)
    {
        ["bt709"] = 1,
        ["bt470m"] = 4,
        ["bt470bg"] = 5,
        ["smpte170m"] = 6,
        ["smpte240m"] = 7,
        ["film"] = 8,
        ["bt2020"] = 9,
        ["smpte428"] = 10,
        ["smpte431"] = 11,
        ["smpte432"] = 12,
        ["jedec-p22"] = 22,
        ["ebu3213"] = 22,
    };
    private static readonly IReadOnlyDictionary<string, int> Matrices = new Dictionary<string, int>(StringComparer.Ordinal)
    {
        ["gbr"] = 0,
        ["bt709"] = 1,
        ["fcc"] = 4,
        ["bt470bg"] = 5,
        ["smpte170m"] = 6,
        ["smpte240m"] = 7,
        ["ycgco"] = 8,
        ["bt2020nc"] = 9,
        ["bt2020c"] = 10,
        ["smpte2085"] = 11,
        ["chroma-derived-nc"] = 12,
        ["chroma-derived-c"] = 13,
        ["ictcp"] = 14,
        ["ipt-c2"] = 15,
        ["ycgco-re"] = 16,
        ["ycgco-ro"] = 17,
    };

    public static HdrToneMapping Detect(string? scaleHelp, string? filters)
    {
        if (scaleHelp is not null && NativeScaleOptions
            .All(option => scaleHelp.Contains(option, StringComparison.Ordinal))) return HdrToneMapping.PerceptualScale;
        static bool HasFilter(string? list, string name) => list?.Split('\n').Any(line =>
            line.Split(' ', StringSplitOptions.RemoveEmptyEntries) is [_, var filter, ..] && filter == name) == true;
        return HasFilter(filters, "zscale") && HasFilter(filters, "tonemap") ? HdrToneMapping.Zscale : HdrToneMapping.Unavailable;
    }

    public static PlaybackException Unsupported() => new("hdr_conversion_unavailable",
        "This server's ffmpeg cannot convert HDR pictures to SDR. Use a player that supports the original picture, or install an ffmpeg build with HDR conversion support.",
        StatusCodes.Status422UnprocessableEntity);

    public static string PictureFilter(ProbedVideo video, HdrToneMapping method)
    {
        var resize = $"scale='min({LiveConversionPlanner.MaximumWidth},iw)':'min({LiveConversionPlanner.MaximumHeight},ih)':force_original_aspect_ratio=decrease:force_divisible_by=2";
        if (!video.IsHdr) return resize + ",format=yuv420p";
        // Only missing/unknown tags get HDR defaults. Real P3, 709, matrix and full-range tags
        // remain authoritative. Values come from fixed allowlists, never filter text from a file.
        var primaries = Value(Primaries, video.ColorPrimaries, 9);
        var matrix = Value(Matrices, video.ColorSpace, 9);
        var range = video.ColorRange is "pc" or "full" or "jpeg" ? 2 : 1;
        var zscaleRange = range == 2 ? "full" : "limited";
        var resizedMatrix = matrix == 0 ? 9 : matrix;
        var transfer = video.ColorTransfer == "smpte2084" ? 16 : 18;
        var peak = video.ColorTransfer == "smpte2084" ? 100 : 10;
        var (width, height) = LiveConversionPlanner.Fit(video.Width, video.Height);
        return method switch
        {
            HdrToneMapping.PerceptualScale => resize
                + $":in_transfer={transfer}:in_primaries={primaries}:in_color_matrix={matrix}:in_range={range}"
                + ":out_transfer=bt709:out_primaries=bt709:out_color_matrix=bt709:out_range=tv:intent=perceptual,format=yuv420p",
            // Resize in the original 10-bit signal before the expensive floating-point work.
            // With a 100-nit reference, PQ's full 10000-nit signal needs a peak of 100;
            // HLG uses its conventional 1000-nit display reference, hence a peak of 10.
            // Native scale-to-linear must not be substituted here: it clips highlights at 1.0.
            HdrToneMapping.Zscale => $"zscale=w={width}:h={height}:transferin={transfer}:transfer={transfer}:primariesin={primaries}:primaries={primaries}"
                + $":matrixin={matrix}:matrix={resizedMatrix}:rangein={zscaleRange}:range={zscaleRange},format=yuv420p10le"
                + $",zscale=transferin={transfer}:primariesin={primaries}:matrixin={resizedMatrix}:rangein={zscaleRange}:transfer=linear:npl=100"
                + ",format=gbrpf32le,zscale=primaries=bt709"
                + $",tonemap=mobius:desat=0:peak={peak},zscale=transfer=bt709:matrix=bt709:range=limited:npl=100,format=yuv420p",
            _ => throw Unsupported(),
        };
    }

    private static int Value(IReadOnlyDictionary<string, int> values, string? value, int fallback) =>
        value is not null && values.TryGetValue(value, out var known) ? known : fallback;
}
