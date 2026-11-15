using System.Globalization;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;

namespace Aurelia.Linux.Core.Playback;

/// <summary>What a download does with this computer's quality setting.</summary>
public enum DownloadChoiceKind
{
    Ask,
    Original,
    Converted,
}

public sealed record DownloadChoice(DownloadChoiceKind Kind, string? Quality = null);

/// <summary>
/// Smaller downloads ("converted-downloads-v1", server 2.20.0): the quality setting, the words the
/// choice shows and how the copy is fetched. Only this computer keeps the copy (owner's decision,
/// 15.11.2026). Pure where it can be, so tests check it.
/// </summary>
public static class ConvertedDownloads
{
    public const string Ask = "ask";
    public const string Original = "original";

    public static readonly IReadOnlyList<(string Value, string Label)> Choices =
    [
        (Ask, "Ask Every Time"), (Original, "Original"), ("1080p", "1080p"), ("720p", "720p"), ("480p", "480p"),
    ];

    private static readonly string[] Order = ["1080p", "720p", "480p", "360p"];

    /// <summary>The original when nothing smaller is offered; otherwise the chosen quality, the next smaller one the title has, or its smallest.</summary>
    public static DownloadChoice Resolve(string preference, DownloadOptionsResponse? options)
    {
        if (options is not { CanConvert: true, Qualities.Count: > 0 }) return new DownloadChoice(DownloadChoiceKind.Original);
        if (preference == Original) return new DownloadChoice(DownloadChoiceKind.Original);
        var wanted = Array.IndexOf(Order, preference);
        if (wanted < 0) return new DownloadChoice(DownloadChoiceKind.Ask);
        var match = options.Qualities.FirstOrDefault(quality => Array.IndexOf(Order, quality.Id) >= wanted) ?? options.Qualities[^1];
        return new DownloadChoice(DownloadChoiceKind.Converted, match.Id);
    }

    /// <summary>"18 GB", "1.8 GB", "640 MB".</summary>
    public static string Size(long bytes) => bytes >= 10_000_000_000
        ? Math.Round(bytes / 1e9).ToString(CultureInfo.InvariantCulture) + " GB"
        : bytes >= 1_000_000_000
            ? (bytes / 1e9).ToString("0.0", CultureInfo.InvariantCulture) + " GB"
            : Math.Max(1, Math.Round(bytes / 1e6)).ToString(CultureInfo.InvariantCulture) + " MB";

    /// <summary>"about 20 min", "about 1 h 40 min".</summary>
    public static string Time(int seconds)
    {
        var minutes = Math.Max(1, (int)Math.Round(seconds / 60.0));
        if (minutes < 60) return $"about {minutes} min";
        var rest = minutes % 60;
        return $"about {minutes / 60} h" + (rest > 0 ? $" {rest} min" : "");
    }

    /// <summary>"About 1.8 GB · the server needs about 20 min".</summary>
    public static string Detail(DownloadQuality quality)
    {
        ArgumentNullException.ThrowIfNull(quality);
        return $"About {Size(quality.EstimatedBytes)}" + (quality.EstimatedSeconds is { } seconds ? $" · the server needs {Time(seconds)}" : "");
    }

    public static int SegmentCount(string playlist) =>
        playlist.Split('\n').Count(line => !line.StartsWith('#') && line.Contains(".m4s", StringComparison.Ordinal));

    /// <summary>"…/hls/720p/3.m4s?audio=1&amp;purpose=download".</summary>
    public static string PiecePath(string streamPath, string quality, string piece, int? audio) =>
        $"{streamPath}/hls/{quality}/{piece}?" + (audio is { } index ? $"audio={index.ToString(CultureInfo.InvariantCulture)}&" : "") + "purpose=download";

    /// <summary>How long to wait before asking again, or null to give up.</summary>
    public static TimeSpan? RetryDelay(int? status, TimeSpan? retryAfter, int attempt) => status switch
    {
        429 or 503 => TimeSpan.FromSeconds(Math.Clamp(retryAfter?.TotalSeconds ?? 5, 2, 60)),
        null or 0 or 408 or 500 or 502 or 504 => attempt < 8 ? TimeSpan.FromSeconds(Math.Min(30, Math.Pow(2, attempt))) : null,
        _ => null,
    };

    public static readonly TimeSpan LongestWait = TimeSpan.FromMinutes(30);

    /// <summary>
    /// Fetches the quality's playlist, init and every media segment in order into
    /// <paramref name="destination"/>, renewing the ticket once when it ended. Returns the size.
    /// </summary>
    public static async Task<long> FetchAsync(PlaybackClient client, Guid mediaId, PlaybackSourceResponse first, string quality, int? audio,
        Stream destination, Action<double> progress, Action<PlaybackSourceResponse> renewed, CancellationToken cancellation)
    {
        ArgumentNullException.ThrowIfNull(client);
        ArgumentNullException.ThrowIfNull(destination);
        var ticket = first;
        async Task<byte[]> Fetch(string piece)
        {
            var attempt = 0;
            var waited = TimeSpan.Zero;
            var renewedOnce = false;
            while (true)
            {
                cancellation.ThrowIfCancellationRequested();
                TimeSpan? delay;
                try
                {
                    return await client.DownloadPieceAsync(ticket, quality, piece, audio, cancellation);
                }
                catch (AureliaApiException failure) when (failure.Status is 401 or 404 && !renewedOnce && failure.Code != "segment_not_found")
                {
                    ticket = await client.StartAsync(mediaId, cancellation, forDownload: true);
                    renewed(ticket);
                    renewedOnce = true;
                    continue;
                }
                catch (AureliaApiException failure)
                {
                    delay = RetryDelay(failure.Status, failure.RetryAfter, attempt);
                    if (delay is null || waited + delay.Value > LongestWait) throw;
                }
                catch (HttpRequestException) when (RetryDelay(null, null, attempt) is not null)
                {
                    delay = RetryDelay(null, null, attempt);
                }
                attempt++;
                waited += delay!.Value;
                await Task.Delay(delay.Value, cancellation);
            }
        }

        var count = SegmentCount(System.Text.Encoding.UTF8.GetString(await Fetch("index.m3u8")));
        if (count == 0) throw AureliaApiException.InvalidResponse();
        long written = 0;
        var init = await Fetch("init.mp4");
        await destination.WriteAsync(init, cancellation);
        written += init.Length;
        for (var index = 0; index < count; index++)
        {
            var segment = await Fetch(index.ToString(CultureInfo.InvariantCulture) + ".m4s");
            await destination.WriteAsync(segment, cancellation);
            written += segment.Length;
            progress((double)(index + 1) / count);
        }
        await destination.FlushAsync(cancellation);
        return written;
    }
}
