using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Management;
using Aurelia.Linux.Core.Playback;
using Aurelia.Linux.Core.Settings;
using Xunit;

namespace Aurelia.Linux.Tests;

/// <summary>Adaptive streaming on Linux: addresses, VLC options, the relay's allowlist and older settings.</summary>
public sealed class StreamingQualityTests
{
    private static readonly Uri Stream = new("http://127.0.0.1:50123/stream/secret");

    [Fact]
    public void OriginalPlaysTheStreamAndTheOthersItsMasterPlaylist()
    {
        Assert.Equal(Stream, StreamingQualities.PlaybackUrl(StreamingQuality.Original, Stream));
        Assert.Equal("http://127.0.0.1:50123/stream/secret/hls/master.m3u8", StreamingQualities.PlaybackUrl(StreamingQuality.Automatic, Stream).AbsoluteUri);
        Assert.Empty(StreamingQualities.VlcOptions(StreamingQuality.Original));
        Assert.Equal([":network-caching=1500"], StreamingQualities.VlcOptions(StreamingQuality.Automatic));
        Assert.Equal([":network-caching=1500", ":adaptive-maxheight=480", ":adaptive-logic=highest"], StreamingQualities.VlcOptions(StreamingQuality.UpTo480p));
        Assert.Equal(StreamingQuality.Original, StreamingQualities.Effective(StreamingQuality.UpTo720p, serverSupports: false));
        Assert.Equal(StreamingQuality.UpTo720p, StreamingQualities.Effective(StreamingQuality.UpTo720p, serverSupports: true));
        Assert.Equal(StreamingQuality.Original, StreamingQualities.Effective((StreamingQuality)42, serverSupports: true));
        Assert.Equal("Up to 720p", StreamingQualities.Title(StreamingQuality.UpTo720p));
    }

    [Fact]
    public void SettingsSavedBeforeTheChoiceExistedKeepTheOriginal()
    {
        var store = new MemorySettingsStore();
        store.Write(PlaybackPreferences.Key, JsonSerializer.Deserialize<JsonElement>("""{"automaticResume":false}"""));
        Assert.Equal(StreamingQuality.Original, PlaybackPreferences.Load(store).StreamingQuality);
        (new PlaybackPreferences() with { StreamingQuality = StreamingQuality.UpTo1080p }).Save(store);
        Assert.Equal(StreamingQuality.UpTo1080p, PlaybackPreferences.Load(store).StreamingQuality);
        Assert.Equal(StreamingQuality.Original, (new PlaybackPreferences() with { StreamingQuality = (StreamingQuality)9 }).Normalized().StreamingQuality);
    }

    [Theory]
    [InlineData("hls/master.m3u8", true)]
    [InlineData("hls/720p/index.m3u8?audio=2", true)]
    [InlineData("hls/720p/init.mp4", true)]
    [InlineData("hls/1080p/1234.m4s?audio=1", true)]
    [InlineData("hls/../../users", false)]
    [InlineData("hls/720p/x.m4s", false)]
    [InlineData("hls/720p/index.m3u8?audio=1&video=copy", false)]
    [InlineData("live", false)]
    [InlineData("hls/0p/index.m3u8", false)]
    public void TheRelayPassesOnlyTheServersHlsFiles(string path, bool allowed)
    {
        Assert.Equal(allowed, LoopbackStreamRelay.IsAllowedHlsPath(path));
        var source = new Uri("https://server.test:43111/api/v1/streams/ticket-1");
        if (allowed) Assert.StartsWith("https://server.test:43111/api/v1/streams/ticket-1/hls/", LoopbackStreamRelay.HlsUrl(path, source)!.AbsoluteUri, StringComparison.Ordinal);
        else Assert.Null(LoopbackStreamRelay.HlsUrl(path, source));
    }

    [Fact]
    public void AnHlsAddressKeepsItsSoundTrackQuery()
    {
        var source = new Uri("https://server.test:43111/api/v1/streams/ticket-1");
        Assert.Equal("https://server.test:43111/api/v1/streams/ticket-1/hls/720p/3.m4s?audio=1", LoopbackStreamRelay.HlsUrl("hls/720p/3.m4s?audio=1", source)!.AbsoluteUri);
    }

    [Fact]
    public void TheOwnerReadsTheEncoderAndEachConversion()
    {
        var status = new TranscodingStatusResponse(true, "vaapi", "VA-API", "/dev/dri/renderD128", true, false, 1, 3,
            [new("Invented Film.mkv", "720p", "vaapi", 4.36, true), new("Invented Show.mkv", "480p", null, null, false)], null);
        Assert.Equal("VA-API (renderD128) · decodes on the chip", TranscodingText.Encoder(status));
        Assert.Equal("1 of 3 at once", TranscodingText.Running(status));
        Assert.Equal(["720p · 4.4× real time", "480p · ready"], status.Sessions.Select(TranscodingText.Session));
        Assert.Equal("Not available", TranscodingText.Encoder(status with { Available = false }));
    }
}
