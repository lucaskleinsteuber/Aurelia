using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class SidecarSubtitleTests : IDisposable
{
    private readonly string tempDir;

    public SidecarSubtitleTests()
    {
        tempDir = Path.Combine(Path.GetTempPath(), "aurelia-sub-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDir);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(tempDir)) Directory.Delete(tempDir, recursive: true);
        }
        catch
        {
            // Ignore cleanup errors
        }
    }

    [Fact]
    public void ParsesLanguageTokensCorrectly()
    {
        Assert.True(SidecarSubtitles.TryParseLanguage("en", out var en));
        Assert.Equal("en", en);

        Assert.True(SidecarSubtitles.TryParseLanguage("deu", out var de));
        Assert.Equal("de", de);

        Assert.True(SidecarSubtitles.TryParseLanguage("french", out var fr));
        Assert.Equal("fr", fr);

        Assert.True(SidecarSubtitles.TryParseLanguage("spanish", out var es));
        Assert.Equal("es", es);

        Assert.False(SidecarSubtitles.TryParseLanguage("1080p", out _));
        Assert.False(SidecarSubtitles.TryParseLanguage("x264", out _));
    }

    [Fact]
    public void ParsesFilenameTagsForLanguageAndFlags()
    {
        var (lang1, forced1, sdh1, def1, title1) = SidecarSubtitles.ParseTags("Inception (2010)", "Inception (2010).en.forced");
        Assert.Equal("en", lang1);
        Assert.True(forced1);
        Assert.False(sdh1);
        Assert.Contains("English", title1);
        Assert.Contains("Forced", title1);

        var (lang2, forced2, sdh2, def2, title2) = SidecarSubtitles.ParseTags("Inception (2010)", "Inception (2010).german.sdh");
        Assert.Equal("de", lang2);
        Assert.False(forced2);
        Assert.True(sdh2);
        Assert.Contains("German", title2);
        Assert.Contains("SDH", title2);

        var (lang3, forced3, sdh3, def3, title3) = SidecarSubtitles.ParseTags("Inception (2010)", "Inception (2010).default");
        Assert.Null(lang3);
        Assert.True(def3);
    }

    [Fact]
    public void IgnoresSubtitlesOfOtherVideosAndLinks()
    {
        var alien = Path.Combine(tempDir, "Alien.mkv");
        File.WriteAllText(alien, "video");
        File.WriteAllText(Path.Combine(tempDir, "Aliens.mkv"), "video");
        File.WriteAllText(Path.Combine(tempDir, "Alien.en.srt"), "1\n00:00:01,000 --> 00:00:02,000\nA\n");
        File.WriteAllText(Path.Combine(tempDir, "Aliens.en.srt"), "1\n00:00:01,000 --> 00:00:02,000\nB\n");
        var secret = Path.Combine(tempDir, "outside.txt");
        File.WriteAllText(secret, "secret");
        File.CreateSymbolicLink(Path.Combine(tempDir, "Alien.de.srt"), secret);
        var subs = Directory.CreateDirectory(Path.Combine(tempDir, "Subs"));
        File.WriteAllText(Path.Combine(subs.FullName, "Aliens.fr.srt"), "x");
        File.WriteAllText(Path.Combine(subs.FullName, "Alien.it.srt"), "x");

        var discovered = SidecarSubtitles.Discover(alien);

        Assert.Equal(["en", "it"], discovered.Select(track => track.Language).OrderBy(value => value));
        Assert.All(discovered, track => Assert.DoesNotContain("Aliens", track.FilePath, StringComparison.Ordinal));
    }

    [Fact]
    public void ALinkedSubtitleFolderIsNotFollowedAndOrderIsStable()
    {
        var video = Path.Combine(tempDir, "Film.mkv");
        File.WriteAllText(video, "video");
        var elsewhere = Directory.CreateDirectory(Path.Combine(tempDir, "..", "aurelia-elsewhere-" + Guid.NewGuid().ToString("N")));
        try
        {
            File.WriteAllText(Path.Combine(elsewhere.FullName, "Film.en.srt"), "x");
            Directory.CreateSymbolicLink(Path.Combine(tempDir, "Subs"), elsewhere.FullName);
            File.WriteAllText(Path.Combine(tempDir, "Film.zh.srt"), "x");
            File.WriteAllText(Path.Combine(tempDir, "Film.de.srt"), "x");

            var first = SidecarSubtitles.Discover(video).Select(track => track.FilePath).ToArray();
            var second = SidecarSubtitles.Discover(video).Select(track => track.FilePath).ToArray();

            Assert.Equal(2, first.Length);
            Assert.Equal(first, second);
            Assert.Equal(first.OrderBy(path => path, StringComparer.Ordinal), first);
        }
        finally { elsewhere.Delete(recursive: true); }
    }

    [Fact]
    public async Task ReadingRefusesALinkedSubtitle()
    {
        var target = Path.Combine(tempDir, "target.srt");
        File.WriteAllText(target, "1\n00:00:01,000 --> 00:00:02,000\nA\n");
        var link = Path.Combine(tempDir, "link.srt");
        File.CreateSymbolicLink(link, target);

        await Assert.ThrowsAsync<FileNotFoundException>(() => SidecarSubtitles.ReadAsWebVttAsync(link, CancellationToken.None));
    }

    [Fact]
    public void DiscoversSiblingAndSubfolderSubtitles()
    {
        var videoPath = Path.Combine(tempDir, "Movie (2020).mkv");
        File.WriteAllText(videoPath, "dummy video");

        File.WriteAllText(Path.Combine(tempDir, "Movie (2020).srt"), "1\n00:00:01,000 --> 00:00:02,000\nHello\n");
        File.WriteAllText(Path.Combine(tempDir, "Movie (2020).en.forced.srt"), "1\n00:00:01,000 --> 00:00:02,000\nHello English\n");
        File.WriteAllText(Path.Combine(tempDir, "Movie (2020).de.ass"), "[Events]\nFormat: Start, End, Text\nDialogue: 0:00:01.00, 0:00:02.00, Hallo\n");
        File.WriteAllText(Path.Combine(tempDir, "Movie (2020).sub"), "bitmap sub");

        var subsDir = Path.Combine(tempDir, "Subs");
        Directory.CreateDirectory(subsDir);
        File.WriteAllText(Path.Combine(subsDir, "Movie (2020).fr.vtt"), "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nBonjour\n");

        var discovered = SidecarSubtitles.Discover(videoPath);
        Assert.Equal(5, discovered.Count);

        var srtTrack = discovered.FirstOrDefault(t => t.Language == "en");
        Assert.NotNull(srtTrack);
        Assert.True(srtTrack.IsForced);
        Assert.True(srtTrack.Supported);
        Assert.Equal("subrip", srtTrack.Format);

        var assTrack = discovered.FirstOrDefault(t => t.Language == "de");
        Assert.NotNull(assTrack);
        Assert.True(assTrack.Supported);
        Assert.Equal("ass", assTrack.Format);

        var subTrack = discovered.FirstOrDefault(t => t.Format == "vobsub");
        Assert.NotNull(subTrack);
        Assert.False(subTrack.Supported);

        var vttTrack = discovered.FirstOrDefault(t => t.Language == "fr");
        Assert.NotNull(vttTrack);
        Assert.True(vttTrack.Supported);
        Assert.Equal("webvtt", vttTrack.Format);
    }

    [Fact]
    public void ConvertsSrtToWebVttWithCommaMillisecondReplacement()
    {
        var srt = """
            1
            00:01:20,123 --> 00:01:24,456
            First subtitle line

            2
            00:01:25,789 --> 00:01:30,000
            Second subtitle line
            """;

        var vtt = SidecarSubtitles.ConvertSrtToWebVtt(srt);
        Assert.StartsWith("WEBVTT", vtt);
        Assert.Contains("00:01:20.123 --> 00:01:24.456", vtt);
        Assert.Contains("First subtitle line", vtt);
        Assert.Contains("00:01:25.789 --> 00:01:30.000", vtt);
        Assert.Contains("Second subtitle line", vtt);
    }

    [Fact]
    public void ConvertsAssToWebVttWithDialogueAndFormatting()
    {
        var ass = """
            [Script Info]
            Title: Test ASS
            [V4+ Styles]
            Format: Name, Fontname, Fontsize
            Style: Default, Arial, 20
            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            Dialogue: 0,0:01:05.20,0:01:08.50,Default,,0,0,0,,{\pos(192,200)\i1}Italic text{\i0} and regular text
            Dialogue: 0,0:01:10.00,0:01:12.40,Default,,0,0,0,,Line 1\NLine 2
            """;

        var vtt = SidecarSubtitles.ConvertAssToWebVtt(ass);
        Assert.StartsWith("WEBVTT", vtt);
        Assert.Contains("00:01:05.200 --> 00:01:08.500", vtt);
        Assert.Contains("<i>Italic text</i> and regular text", vtt);
        Assert.DoesNotContain(@"\pos", vtt);
        Assert.Contains("00:01:10.000 --> 00:01:12.400", vtt);
        Assert.Contains("Line 1\nLine 2", vtt);
    }

    [Fact]
    public void DecodesEncodingsAccurately()
    {
        var utf8Bom = new byte[] { 0xEF, 0xBB, 0xBF }.Concat(Encoding.UTF8.GetBytes("Grüße")).ToArray();
        Assert.Equal("Grüße", SidecarSubtitles.DecodeText(utf8Bom));

        var utf16Le = new byte[] { 0xFF, 0xFE }.Concat(Encoding.Unicode.GetBytes("Hello UTF-16")).ToArray();
        Assert.Equal("Hello UTF-16", SidecarSubtitles.DecodeText(utf16Le));

        var utf8Plain = Encoding.UTF8.GetBytes("Plain UTF-8 text");
        Assert.Equal("Plain UTF-8 text", SidecarSubtitles.DecodeText(utf8Plain));

        // Windows-1252 Umlaut: 'ä' is 0xE4, 'ö' is 0xF6, 'ü' is 0xFC (invalid UTF-8 sequence)
        var win1252Bytes = new byte[] { 0xE4, 0xF6, 0xFC };
        var decodedWin1252 = SidecarSubtitles.DecodeText(win1252Bytes);
        Assert.Equal("äöü", decodedWin1252);
    }

    [Fact]
    public async Task EnforcesSizeCapAndDoesNotWriteDiskFiles()
    {
        var largePath = Path.Combine(tempDir, "large.srt");
        using (var fs = new FileStream(largePath, FileMode.CreateNew))
        {
            fs.SetLength(6 * 1024 * 1024); // 6 MB
        }

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            SidecarSubtitles.ReadAsWebVttAsync(largePath, CancellationToken.None));

        // Small subtitle read succeeds in memory without creating files
        var smallPath = Path.Combine(tempDir, "small.srt");
        await File.WriteAllTextAsync(smallPath, "1\n00:00:01,000 --> 00:00:02,000\nHello\n");

        var initialFileCount = Directory.GetFiles(tempDir).Length;
        var bytes = await SidecarSubtitles.ReadAsWebVttAsync(smallPath, CancellationToken.None);
        Assert.NotEmpty(bytes);
        Assert.Equal(initialFileCount, Directory.GetFiles(tempDir).Length);
    }
}
