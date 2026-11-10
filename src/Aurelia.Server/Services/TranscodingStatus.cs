using Aurelia.Contracts;
using Aurelia.Server.Services.Hls;

namespace Aurelia.Server.Services;

/// <summary>
/// The owner's view of video conversion: which encoder runs, what converts now and, when the
/// computer has a video chip the server cannot use, the one step that usually fixes it.
/// </summary>
public static class TranscodingStatus
{
    private const string Intel = "0x8086";
    private const string Amd = "0x1002";
    private const string Nvidia = "0x10de";

    public static async Task<TranscodingStatusResponse> ReadAsync(LiveConversionService live, HlsSessionManager sessions, string? setting)
    {
        var tools = await live.ToolsAsync();
        var chosen = tools is null ? null : live.ChooseEncoder(tools);
        var running = sessions.Sessions.Select(session => new TranscodingSessionStatus(
            session.Title, session.Step.Id, session.Encoder is { } kind ? Name(kind) : null, session.IsProducing ? session.Speed : null,
            session.IsProducing)).ToList();
        var hint = OperatingSystem.IsLinux()
            ? Hint(tools, setting, isLinux: true, GraphicsVendors(), HardwareEncoding.RenderDevices(), CanOpen)
            : Hint(tools, setting, isLinux: false, [], [], _ => true);
        return new TranscodingStatusResponse(
            chosen is not null,
            chosen is { } encoder ? Name(encoder.Kind) : null,
            chosen is { } shown ? HardwareEncoding.DisplayName(shown.Kind) : "None",
            chosen?.Chip?.Device,
            chosen?.Chip?.Decodes == true,
            tools?.Hardware is not null && live.Health.IsResting,
            live.RunningVideo,
            LiveConversionService.VideoConversionLimit(tools),
            running,
            hint);
    }

    public static string Name(LiveVideoEncoder kind) => kind.ToString().ToLowerInvariant();

    /// <summary>The next step when hardware encoding could work but doesn't, or null when nothing is to do.</summary>
    /// <param name="vendors">PCI vendor ids of the computer's graphics, such as "0x8086".</param>
    /// <param name="canOpen">Whether the server may open a render node.</param>
    public static string? Hint(FfmpegTools? tools, string? setting, bool isLinux, IReadOnlyList<string> vendors,
        IReadOnlyList<string> renderNodes, Func<string, bool> canOpen)
    {
        ArgumentNullException.ThrowIfNull(canOpen);
        if (tools is null)
            return isLinux
                ? "Install ffmpeg so the server can convert titles, for example with: sudo apt install ffmpeg"
                : "This server has no ffmpeg, so it can't convert titles.";
        if (tools.Hardware is not null || !isLinux) return null;
        if (setting is not null && HardwareEncoding.Choice(setting) is { Count: 0 })
            return "Video chips are turned off with the Aurelia:HardwareEncoding setting, so the processor converts.";
        var known = vendors.Select(vendor => vendor.Trim().ToLowerInvariant()).ToHashSet(StringComparer.Ordinal);
        if (known.Count == 0) return null;
        var vaapi = known.Contains(Intel) || known.Contains(Amd);
        if (vaapi && renderNodes.Count == 0)
            return "This computer has a video chip, but the server sees no render device in /dev/dri. In Docker, pass /dev/dri to the container.";
        if (vaapi && !canOpen(renderNodes[0]))
            return "The server isn't allowed to use the video chip. Add its user to the render group (sudo usermod -aG render,video aurelia), then restart Aurelia.";
        if (known.Contains(Intel))
            return "Intel graphics found, but no working VA-API driver. Install intel-media-va-driver (Intel from 2015 on) or i965-va-driver (older Intel), then restart Aurelia.";
        if (known.Contains(Amd))
            return "AMD graphics found, but no working VA-API driver. Install mesa-va-drivers, then restart Aurelia.";
        if (known.Contains(Nvidia))
            return "Nvidia graphics found, but NVENC didn't work. Install Nvidia's driver with its encoding libraries, then restart Aurelia.";
        return null;
    }

    /// <summary>The PCI vendor ids of the graphics cards Linux lists in /sys/class/drm.</summary>
    public static IReadOnlyList<string> GraphicsVendors(string directory = "/sys/class/drm")
    {
        try
        {
            if (!Directory.Exists(directory)) return [];
            return Directory.EnumerateDirectories(directory, "card*")
                .Select(card => Path.Combine(card, "device", "vendor"))
                .Where(File.Exists)
                .Select(path => File.ReadAllText(path).Trim())
                .Where(vendor => vendor.Length is > 0 and <= 10)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    private static bool CanOpen(string path)
    {
        try
        {
            using var handle = File.OpenHandle(path, FileMode.Open, FileAccess.ReadWrite);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }
}
