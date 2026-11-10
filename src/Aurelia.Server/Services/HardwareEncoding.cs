using System.Globalization;
using System.Text.RegularExpressions;

namespace Aurelia.Server.Services;

/// <summary>A video chip that encodes H.264: which kind, the render device it uses and whether it also decodes.</summary>
/// <param name="Device">A Linux render node such as /dev/dri/renderD128 for VAAPI and Quick Sync; null for NVENC.</param>
/// <param name="Decodes">Whether ffmpeg may decode on the chip as well (it falls back to the CPU per title).</param>
public sealed record HardwareEncoder(LiveVideoEncoder Kind, string? Device, bool Decodes);

/// <summary>
/// Finds a video chip that can encode for live conversion and builds ffmpeg's arguments for it.
/// A chip counts only when ffmpeg lists its encoder and a short trial encode of an invented test
/// picture succeeds; the trial writes to ffmpeg's null output, never to a file. All decisions are
/// pure, so tests check them with canned ffmpeg answers.
/// </summary>
public static partial class HardwareEncoding
{
    /// <summary>The order in which chips are tried on Linux: Nvidia, Intel Quick Sync, then VAAPI (Intel and AMD).</summary>
    public static readonly IReadOnlyList<LiveVideoEncoder> LinuxOrder = [LiveVideoEncoder.Nvenc, LiveVideoEncoder.Qsv, LiveVideoEncoder.Vaapi];

    /// <summary>How long a chip that failed during a conversion is left aside before it is tried again.</summary>
    public static readonly TimeSpan FailurePause = TimeSpan.FromMinutes(10);

    /// <summary>ffmpeg's name of the H.264 encoder.</summary>
    public static string EncoderName(LiveVideoEncoder kind) => kind switch
    {
        LiveVideoEncoder.Libx264 => "libx264",
        LiveVideoEncoder.VideoToolbox => "h264_videotoolbox",
        LiveVideoEncoder.Nvenc => "h264_nvenc",
        LiveVideoEncoder.Qsv => "h264_qsv",
        LiveVideoEncoder.Vaapi => "h264_vaapi",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    /// <summary>The name shown to people, such as "Nvidia NVENC".</summary>
    public static string DisplayName(LiveVideoEncoder kind) => kind switch
    {
        LiveVideoEncoder.Libx264 => "Processor (x264)",
        LiveVideoEncoder.VideoToolbox => "Apple VideoToolbox",
        LiveVideoEncoder.Nvenc => "Nvidia NVENC",
        LiveVideoEncoder.Qsv => "Intel Quick Sync",
        LiveVideoEncoder.Vaapi => "VA-API",
        _ => kind.ToString(),
    };

    public static bool IsHardware(LiveVideoEncoder kind) => kind is not LiveVideoEncoder.Libx264;

    /// <summary>
    /// What the owner chose in Aurelia:HardwareEncoding: null for automatic, an empty list for off,
    /// or the one chip to use.
    /// </summary>
    public static IReadOnlyList<LiveVideoEncoder>? Choice(string? setting) =>
        setting?.Trim().ToLowerInvariant() switch
        {
            null or "" or "auto" or "on" => null,
            "off" or "none" or "software" => [],
            "nvenc" or "nvidia" or "cuda" => [LiveVideoEncoder.Nvenc],
            "qsv" or "quicksync" or "intel" => [LiveVideoEncoder.Qsv],
            "vaapi" or "va-api" or "amd" => [LiveVideoEncoder.Vaapi],
            _ => [],
        };

    /// <summary>Linux render nodes in the folder, renderD128 to renderD191, in order; nothing else qualifies.</summary>
    public static IReadOnlyList<string> RenderDevices(string directory = "/dev/dri")
    {
        try
        {
            if (!Directory.Exists(directory)) return [];
            return Directory.EnumerateFileSystemEntries(directory)
                .Where(path => RenderNode().IsMatch(Path.GetFileName(path)))
                .OrderBy(path => int.Parse(Path.GetFileName(path)["renderD".Length..], CultureInfo.InvariantCulture))
                .Take(8)
                .ToList();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    [GeneratedRegex("^renderD(12[89]|1[3-8][0-9]|19[01])$", RegexOptions.CultureInvariant)]
    private static partial Regex RenderNode();

    /// <summary>
    /// The first chip that ffmpeg lists and that passes a trial encode, or null to stay on the
    /// processor. <paramref name="run"/> runs ffmpeg with the arguments and returns its output, or
    /// null when it failed or took too long.
    /// </summary>
    public static HardwareEncoder? Detect(
        Func<IReadOnlyList<string>, string?> run,
        string encoders,
        string? hardwareAccelerations,
        string? setting,
        IReadOnlyList<string> renderDevices)
    {
        ArgumentNullException.ThrowIfNull(run);
        var candidates = Choice(setting) ?? LinuxOrder;
        foreach (var kind in candidates)
        {
            if (!Lists(encoders, EncoderName(kind))) continue;
            var devices = kind == LiveVideoEncoder.Nvenc ? new string?[] { null } : renderDevices.Select(device => (string?)device);
            foreach (var device in devices)
            {
                var candidate = new HardwareEncoder(kind, device, Decodes: false);
                if (run(TrialArguments(candidate)) is null) continue;
                return candidate with { Decodes = Lists(hardwareAccelerations, DecodeMethod(kind)) };
            }
        }
        return null;
    }

    /// <summary>Whether a line of ffmpeg's -encoders or -hwaccels list names exactly this entry.</summary>
    public static bool Lists(string? list, string name) =>
        list is not null && list.Split('\n').Any(line =>
            line.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries) switch
            {
                [var only] => only == name,
                [_, var entry, ..] => entry == name,
                _ => false,
            });

    private static string DecodeMethod(LiveVideoEncoder kind) => kind switch
    {
        LiveVideoEncoder.Nvenc => "cuda",
        // Quick Sync decodes through VAAPI on the same render node, which keeps the filters unchanged.
        LiveVideoEncoder.Qsv or LiveVideoEncoder.Vaapi => "vaapi",
        _ => "none",
    };

    /// <summary>A one-second encode of an invented test picture to ffmpeg's null output.</summary>
    public static IReadOnlyList<string> TrialArguments(HardwareEncoder encoder)
    {
        var arguments = new List<string> { "-hide_banner", "-nostdin", "-loglevel", "error" };
        arguments.AddRange(DeviceArguments(encoder, decode: false));
        arguments.AddRange(["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25", "-frames:v", "25", "-an"]);
        arguments.AddRange(["-vf", UploadFilter(encoder.Kind, "format=yuv420p")]);
        arguments.AddRange(["-c:v", EncoderName(encoder.Kind), "-b:v", "1M", "-f", "null", "-"]);
        return arguments;
    }

    /// <summary>Arguments before the input: the device to use and, when the chip decodes, the decoder.</summary>
    public static IReadOnlyList<string> DeviceArguments(HardwareEncoder encoder, bool decode)
    {
        var arguments = new List<string>();
        switch (encoder.Kind)
        {
            case LiveVideoEncoder.Nvenc:
                if (decode && encoder.Decodes) arguments.AddRange(["-hwaccel", "cuda"]);
                break;
            case LiveVideoEncoder.Vaapi:
                var device = Device(encoder);
                arguments.AddRange(["-vaapi_device", device]);
                // Without an output format the decoded frames come back to memory, so the
                // picture filters (size, HDR mapping) stay the same as for the processor.
                if (decode && encoder.Decodes) arguments.AddRange(["-hwaccel", "vaapi", "-hwaccel_device", device]);
                break;
            case LiveVideoEncoder.Qsv:
                var node = Device(encoder);
                arguments.AddRange(["-init_hw_device", "vaapi=va:" + node, "-init_hw_device", "qsv=qs@va", "-filter_hw_device", "qs"]);
                if (decode && encoder.Decodes) arguments.AddRange(["-hwaccel", "vaapi", "-hwaccel_device", "va"]);
                break;
        }
        return arguments;
    }

    /// <summary>The picture filter with the upload to the chip appended where the chip needs it.</summary>
    public static string UploadFilter(LiveVideoEncoder kind, string pictureFilter) => kind switch
    {
        LiveVideoEncoder.Vaapi => pictureFilter + ",format=nv12,hwupload",
        LiveVideoEncoder.Qsv => pictureFilter + ",format=nv12,hwupload=extra_hw_frames=64,format=qsv",
        _ => pictureFilter,
    };

    /// <summary>The encoder and its rate settings for a target video bitrate in kbit/s.</summary>
    public static IReadOnlyList<string> EncoderArguments(LiveVideoEncoder kind, int kilobits)
    {
        var rate = Kilobits(kilobits);
        var peak = Kilobits(kilobits * 3 / 2);
        var buffer = Kilobits(kilobits * 2);
        return kind switch
        {
            LiveVideoEncoder.Libx264 => ["-c:v", "libx264", "-preset", "veryfast", "-crf", "22", "-maxrate", rate, "-bufsize", buffer, "-profile:v", "high"],
            LiveVideoEncoder.VideoToolbox => ["-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", rate, "-profile:v", "high"],
            LiveVideoEncoder.Nvenc => ["-c:v", "h264_nvenc", "-preset", "p4", "-rc", "vbr", "-b:v", rate, "-maxrate", peak, "-bufsize", buffer, "-profile:v", "high", "-forced-idr", "1"],
            LiveVideoEncoder.Qsv => ["-c:v", "h264_qsv", "-preset", "veryfast", "-b:v", rate, "-maxrate", peak, "-bufsize", buffer, "-profile:v", "high"],
            LiveVideoEncoder.Vaapi => ["-c:v", "h264_vaapi", "-rc_mode", "VBR", "-b:v", rate, "-maxrate", peak, "-profile:v", "high"],
            _ => throw new ArgumentOutOfRangeException(nameof(kind)),
        };
    }

    private static string Kilobits(int value) => value.ToString(CultureInfo.InvariantCulture) + "k";

    private static string Device(HardwareEncoder encoder) =>
        encoder.Device is { } device && RenderNode().IsMatch(Path.GetFileName(device)) && device.StartsWith("/dev/dri/", StringComparison.Ordinal)
            ? device
            : throw new InvalidOperationException("A VAAPI or Quick Sync encoder needs a render node under /dev/dri.");
}

/// <summary>Remembers in memory when a chip failed during a conversion, so the next ones use the processor for a while.</summary>
public sealed class HardwareHealth(TimeProvider? clock = null)
{
    private readonly TimeProvider clock = clock ?? TimeProvider.System;
    private readonly object gate = new();
    private DateTimeOffset? failedAt;

    public bool IsResting
    {
        get
        {
            lock (gate) return failedAt is { } at && clock.GetUtcNow() - at < HardwareEncoding.FailurePause;
        }
    }

    public DateTimeOffset? LastFailure { get { lock (gate) return failedAt; } }

    public void ReportFailure()
    {
        lock (gate) failedAt = clock.GetUtcNow();
    }
}
