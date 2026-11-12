using System.Globalization;
using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Management;

/// <summary>How a speech job on the server reads in the app.</summary>
public static class SpeechText
{
    public static bool Running(SpeechJobStatus? job) => job?.State is SpeechJobState.Waiting or SpeechJobState.Listening or SpeechJobState.Saving;

    public static string Line(SpeechJobStatus? job)
    {
        if (job is null) return "";
        var percent = Math.Round(job.Progress * 100).ToString(CultureInfo.InvariantCulture) + " %";
        return job.State switch
        {
            SpeechJobState.Waiting => "Waiting for the server…",
            SpeechJobState.Listening => job.PausedForPlayback ? $"Paused while someone watches · {percent} heard" : $"Listening… {percent} heard",
            SpeechJobState.Saving => "Saving the subtitles…",
            SpeechJobState.Done => job.Message ?? "Saved.",
            SpeechJobState.AlreadyInSync => job.Message ?? "These subtitles already fit the speech.",
            SpeechJobState.Failed => job.Message ?? "The server couldn't listen to this title.",
            _ => "Stopped.",
        };
    }

    public static string Bytes(long value) => value >= 1_000_000_000
        ? (value / 1e9).ToString("0.0", CultureInfo.InvariantCulture) + " GB"
        : Math.Round(value / 1e6).ToString(CultureInfo.InvariantCulture) + " MB";
}
