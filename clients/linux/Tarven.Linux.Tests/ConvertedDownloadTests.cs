using Tarven.Contracts;
using Tarven.Linux.Core.Playback;
using Xunit;

namespace Tarven.Linux.Tests;

/// <summary>Smaller downloads on Linux ("converted-downloads-v1"), the same rules as on the Mac.</summary>
public sealed class ConvertedDownloadTests
{
    private static DownloadOptionsResponse Options(string[] ids, bool canConvert = true) =>
        new(54_000_000_000, 7200, canConvert, [.. ids.Select(id => new DownloadQuality(id, 0, 0, 1_800_000_000, 1200))], [], 1);

    [Fact]
    public void TheSettingPicksTheQualityOrTheOriginal()
    {
        var all = Options(["1080p", "720p", "480p", "360p"]);
        Assert.Equal(DownloadChoiceKind.Ask, ConvertedDownloads.Resolve("ask", all).Kind);
        Assert.Equal(new DownloadChoice(DownloadChoiceKind.Converted, "720p"), ConvertedDownloads.Resolve("720p", all));
        Assert.Equal(new DownloadChoice(DownloadChoiceKind.Converted, "480p"), ConvertedDownloads.Resolve("1080p", Options(["480p"])));
        Assert.Equal(DownloadChoiceKind.Original, ConvertedDownloads.Resolve("ask", Options([])).Kind);
        Assert.Equal(DownloadChoiceKind.Original, ConvertedDownloads.Resolve("720p", null).Kind);
        Assert.Equal(DownloadChoiceKind.Original, ConvertedDownloads.Resolve("720p", Options(["720p"], canConvert: false)).Kind);
    }

    [Fact]
    public void PiecesWaitsAndWords()
    {
        Assert.Equal(2, ConvertedDownloads.SegmentCount("#EXTM3U\n#EXTINF:4,\n0.m4s?audio=1\n#EXTINF:2,\n1.m4s?audio=1\n"));
        Assert.Equal("/api/v1/streams/abc/hls/720p/3.m4s?audio=1&purpose=download", ConvertedDownloads.PiecePath("/api/v1/streams/abc", "720p", "3.m4s", 1));
        Assert.Equal(TimeSpan.FromSeconds(5), ConvertedDownloads.RetryDelay(429, null, 9));
        Assert.Equal(TimeSpan.FromSeconds(8), ConvertedDownloads.RetryDelay(null, null, 3));
        Assert.Null(ConvertedDownloads.RetryDelay(403, null, 0));
        Assert.Equal("About 1.8 GB · the server needs about 20 min", ConvertedDownloads.Detail(Options(["720p"]).Qualities[0]));
        Assert.Equal("54 GB", ConvertedDownloads.Size(54_000_000_000));
        Assert.Equal("about 1 h 40 min", ConvertedDownloads.Time(6000));
    }

    [Fact]
    public void AnUnknownQualitySettingFallsBackToAsking() =>
        Assert.Equal(ConvertedDownloads.Ask, (new PlaybackPreferences() with { DownloadQuality = "4k" }).Normalized().DownloadQuality);
}
