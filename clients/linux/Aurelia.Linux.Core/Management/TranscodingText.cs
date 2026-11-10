using System.Globalization;
using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Management;

/// <summary>The owner's lines about video conversion, as in the Mac app and the browser.</summary>
public static class TranscodingText
{
    /// <summary>"VA-API (renderD128) · decodes on the chip", or "Not available".</summary>
    public static string Encoder(TranscodingStatusResponse status)
    {
        ArgumentNullException.ThrowIfNull(status);
        if (!status.Available) return "Not available";
        List<string> parts = [status.EncoderName + (status.Device is { } device ? $" ({Path.GetFileName(device)})" : "")];
        if (status.HardwareDecoding) parts.Add("decodes on the chip");
        if (status.HardwareResting) parts.Add("the processor stands in after a chip error");
        return string.Join(" · ", parts);
    }

    public static string Running(TranscodingStatusResponse status)
    {
        ArgumentNullException.ThrowIfNull(status);
        var converting = status.Sessions.Count(session => session.Converting);
        return converting == 0 ? "None" : $"{converting} of {status.VideoLimit} at once";
    }

    public static string Session(TranscodingSessionStatus session)
    {
        ArgumentNullException.ThrowIfNull(session);
        var state = session.Converting
            ? session.Speed is { } speed ? speed.ToString("0.0", CultureInfo.InvariantCulture) + "× real time" : "starting"
            : "ready";
        return $"{session.Quality} · {state}";
    }
}
