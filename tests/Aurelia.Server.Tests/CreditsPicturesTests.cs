using Aurelia.Contracts;
using Aurelia.Server.Services.Segments;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>End credits in pictures, with invented 320 × 180 grey pictures; no media and no ffmpeg.</summary>
public sealed class CreditsPicturesTests
{
    [Fact]
    public void TextOnBlackIsCreditsButNightScenesSubtitlesAndBlackAreNot()
    {
        Assert.Equal(PictureKind.Text, Kind(SyntheticPictures.Credits(seed: 1)));
        Assert.Equal(PictureKind.Text, Kind(SyntheticPictures.Credits(seed: 2, lines: 2)));
        Assert.Equal(PictureKind.Other, Kind(SyntheticPictures.Night(seed: 3)));
        Assert.Equal(PictureKind.Other, Kind(SyntheticPictures.Subtitle(seed: 4)));
        Assert.Equal(PictureKind.Other, Kind(SyntheticPictures.Scene(seed: 5)));
        Assert.Equal(PictureKind.Black, Kind(new byte[CreditsPictures.FrameBytes]));
        // A tunnel at night with hard lamp reflections: dark grey shadows, not an even black.
        Assert.Equal(PictureKind.Other, Kind(SyntheticPictures.Tunnel(seed: 6)));
        // Credits on a slightly raised black (a video whose black is not at 0) still count.
        Assert.Equal(PictureKind.Text, Kind(SyntheticPictures.Credits(seed: 7).Select(value => (byte)Math.Max(value, (byte)9)).ToArray()));
    }

    [Fact]
    public void CreditsMustLastUntilShortlyBeforeTheEnd()
    {
        // 150 s of scenes, 40 s of credits with black between cards, 10 s of a studio logo.
        var pictures = Seconds(150, SyntheticPictures.Scene).Concat(CreditCards(40)).Concat(Seconds(10, SyntheticPictures.Scene)).ToList();
        var window = CreditsPictures.FromPictures(pictures, startSeconds: 1_000);
        var result = CreditsPictures.Find(window, new bool[window.Kinds.Length], duration: 1_200);
        Assert.NotNull(result);
        Assert.InRange(result.Value.Start, 1_149.5, 1_150.5);
        Assert.True(result.Value.Confidence >= 0.6);

        // The same credits followed by a two-minute scene are not taken: that is not the end.
        var early = Seconds(60, SyntheticPictures.Scene).Concat(CreditCards(40)).Concat(Seconds(120, SyntheticPictures.Scene)).ToList();
        var earlyWindow = CreditsPictures.FromPictures(early, 1_000);
        Assert.Null(CreditsPictures.Find(earlyWindow, new bool[earlyWindow.Kinds.Length], 1_220));
    }

    [Fact]
    public void ADarkLastSceneAndShortTextAreNotCredits()
    {
        var dark = Seconds(170, SyntheticPictures.Scene).Concat(Seconds(30, SyntheticPictures.Night)).ToList();
        var darkWindow = CreditsPictures.FromPictures(dark, 1_000);
        Assert.Null(CreditsPictures.Find(darkWindow, new bool[darkWindow.Kinds.Length], 1_200));

        // Eight seconds of a title card at the end are too short for credits.
        var card = Seconds(192, SyntheticPictures.Scene).Concat(CreditCards(8)).ToList();
        var cardWindow = CreditsPictures.FromPictures(card, 1_000);
        Assert.Null(CreditsPictures.Find(cardWindow, new bool[cardWindow.Kinds.Length], 1_200));
    }

    [Fact]
    public void PicturesTheOtherEpisodesShareCountAsCredits()
    {
        // Names over the same drawn card in every episode, then text on black to the end.
        var card = SyntheticPictures.Scene(seed: 99);
        PictureWindow Episode(int seed) => CreditsPictures.FromPictures(
            Seconds(150, second => SyntheticPictures.Scene(seed * 1_000 + second))
                .Concat(Enumerable.Range(0, 60).Select(_ => SyntheticPictures.WithNames(card, seed)))
                .Concat(CreditCards(20)).ToList(), 1_000);
        var episodes = Enumerable.Range(1, 4).Select(Episode).ToArray();

        var shared = CreditsPictures.Shared(episodes[0], episodes[1..]);
        var result = CreditsPictures.Find(episodes[0], shared, duration: 1_200);
        Assert.NotNull(result);
        Assert.InRange(result.Value.Start, 1_149.5, 1_150.5);
        // Without the other episodes only the text on black is found.
        var alone = CreditsPictures.Find(episodes[0], new bool[episodes[0].Kinds.Length], 1_200);
        Assert.InRange(alone!.Value.Start, 1_179.5, 1_180.5);
        // Scenes of their own are never shared.
        Assert.DoesNotContain(true, shared.Take(300));
    }

    [Fact]
    public void AnIntroIsFoundInPicturesEvenAtAnotherPlace()
    {
        // Another episode's intro: 30 s of its own pictures from 0:05.
        var intro = Enumerable.Range(0, 60).Select(index => SyntheticPictures.Scene(500 + index / 2)).ToList();
        var reference = CreditsPictures.FromPictures(intro, startSeconds: 5);
        // This episode shows the same pictures from 2:11, after a story of its own.
        var episode = Seconds(131, second => SyntheticPictures.Scene(9_000 + second)).Concat(intro)
            .Concat(Seconds(60, second => SyntheticPictures.Scene(9_500 + second))).ToList();
        var window = CreditsPictures.FromPictures(episode, startSeconds: 0);
        var alignment = CreditsPictures.Align(window, reference);
        Assert.NotNull(alignment);
        Assert.InRange(alignment.Value.Offset, 125.5, 126.5);
        Assert.True(alignment.Value.Share >= 0.9);

        // An episode without those pictures has no match.
        var other = CreditsPictures.FromPictures(Seconds(200, second => SyntheticPictures.Scene(12_000 + second)).ToList(), 0);
        Assert.True(CreditsPictures.Align(other, reference) is null or { Share: < 0.6 });
    }

    [Fact]
    public void ThePictureWindowIsTheLastSixMinutes()
    {
        Assert.Equal(360, CreditsPictures.WindowSeconds(2_700));
        Assert.Equal(300, CreditsPictures.WindowSeconds(1_200));
    }

    [Theory]
    // Sound earlier and reaching the pictures' credits (names over footage): the sound's start.
    [InlineData(3_662, 3_700, 3_694, 3_703, 3_662)]
    // Pictures earlier (credits begin in silence): the pictures' start.
    [InlineData(3_775, 3_890, 3_735, 3_896, 3_735)]
    // Shared music long before the credits and ending before them: the pictures win.
    [InlineData(3_400, 3_450, 3_694, 3_703, 3_694)]
    public void SoundAndPicturesAreCombined(double soundStart, double soundEnd, double pictureStart, double pictureEnd, double expected)
    {
        var chosen = SeasonSegmentAnalyzer.ChooseCredits((soundStart, soundEnd, 0.8), (pictureStart, pictureEnd, 0.9));
        Assert.Equal(expected, chosen!.Value.Start);
        Assert.Equal((3_500.0, 3_550.0, 0.7), SeasonSegmentAnalyzer.ChooseCredits((3_500, 3_550, 0.7), null));
        Assert.Null(SeasonSegmentAnalyzer.ChooseCredits(null, null));
    }

    [Fact]
    public void AMovieKeepsItsCreditsAcrossAMidCreditsSceneAndAPostCreditsScene()
    {
        // 2 min of the film, 90 s of names, a one-minute mid-credits scene, 40 s more names and a
        // two-minute scene after the credits.
        var pictures = Seconds(120, second => SyntheticPictures.Scene(20_000 + second)).Concat(CreditCards(90))
            .Concat(Seconds(60, second => SyntheticPictures.Scene(21_000 + second))).Concat(CreditCards(40))
            .Concat(Seconds(120, second => SyntheticPictures.Scene(22_000 + second))).ToList();
        var window = CreditsPictures.FromPictures(pictures, startSeconds: 6_770);
        var duration = 6_770.0 + 430;
        var result = CreditsPictures.Find(window, new bool[window.Kinds.Length], duration, CreditsRules.Movie);
        Assert.NotNull(result);
        Assert.InRange(result.Value.Start, 6_889.5, 6_890.5);
        Assert.InRange(result.Value.End, 7_079, 7_081);
        Assert.True(result.Value.Confidence >= 0.6);
        // An episode's rules allow no two minutes after the credits.
        Assert.Null(CreditsPictures.Find(window, new bool[window.Kinds.Length], duration));
    }

    [Fact]
    public void AMovieNeedsLongCreditsAndATitleCardInTheFilmIsNotJoined()
    {
        // A 15 s card ("Ten years later") in the film, three minutes of film, 60 s of names to the end.
        var pictures = Seconds(60, second => SyntheticPictures.Scene(30_000 + second)).Concat(CreditCards(15))
            .Concat(Seconds(170, second => SyntheticPictures.Scene(31_000 + second))).Concat(CreditCards(60)).ToList();
        var window = CreditsPictures.FromPictures(pictures, startSeconds: 5_000);
        var result = CreditsPictures.Find(window, new bool[window.Kinds.Length], 5_305, CreditsRules.Movie);
        Assert.InRange(result!.Value.Start, 5_244.5, 5_245.5);

        // 30 s of names are too short for a movie's credits.
        var brief = Seconds(200, second => SyntheticPictures.Scene(32_000 + second)).Concat(CreditCards(30)).ToList();
        var briefWindow = CreditsPictures.FromPictures(brief, 5_000);
        Assert.Null(CreditsPictures.Find(briefWindow, new bool[briefWindow.Kinds.Length], 5_230, CreditsRules.Movie));
    }

    [Fact]
    public async Task AMoviesCreditsComeFromAChapterOrItsLastPicturesAndItsIntroOnlyFromAChapter()
    {
        Assert.Equal(1_200, MovieSegmentAnalyzer.CreditsWindowSeconds(9_000));
        Assert.Equal(900, MovieSegmentAnalyzer.CreditsWindowSeconds(6_000));

        // Chapters: used without looking at any picture.
        var named = new SegmentEpisode(6_000, [new(0, 90, "Opening Credits"), new(90, 5_600, "Film"), new(5_600, 6_000, "End Credits")]);
        var asked = 0;
        var chapters = await new MovieSegmentAnalyzer(named, (_, _, _) => { asked++; return Task.FromResult<PictureWindow?>(null); })
            .AnalyzeAsync(CancellationToken.None);
        Assert.Equal((0.0, 90.0, MediaSegmentSource.Chapters), (chapters.IntroStart!.Value, chapters.IntroEnd!.Value, chapters.IntroSource));
        Assert.Equal((5_600.0, MediaSegmentSource.Chapters), (chapters.CreditsStart!.Value, chapters.CreditsSource));
        Assert.Equal(0, asked);

        // Pictures: the last 15 % are asked for, and the intro stays empty.
        (double Start, double Length)? requested = null;
        var ending = Seconds(700, second => SyntheticPictures.Scene(40_000 + second)).Concat(CreditCards(200)).ToList();
        var found = await new MovieSegmentAnalyzer(new SegmentEpisode(6_000, []), (start, length, _) =>
        {
            requested = (start, length);
            return Task.FromResult<PictureWindow?>(CreditsPictures.FromPictures(ending, start));
        }).AnalyzeAsync(CancellationToken.None);
        Assert.Equal((5_100.0, 900.0), requested);
        Assert.Equal(MediaSegmentSource.Detected, found.CreditsSource);
        Assert.InRange(found.CreditsStart!.Value, 5_799.5, 5_800.5);
        Assert.Equal(MediaSegmentSource.None, found.IntroSource);

        // Nothing certain: nothing is kept. A short film is not examined.
        var plain = Seconds(900, second => SyntheticPictures.Scene(41_000 + second)).ToList();
        var nothing = await new MovieSegmentAnalyzer(new SegmentEpisode(6_000, []),
            (start, _, _) => Task.FromResult<PictureWindow?>(CreditsPictures.FromPictures(plain, start))).AnalyzeAsync(CancellationToken.None);
        Assert.Equal(DetectedSegments.Nothing, nothing);
        Assert.Equal(DetectedSegments.Nothing, await new MovieSegmentAnalyzer(new SegmentEpisode(900, [new(800, 900, "Credits")]), null)
            .AnalyzeAsync(CancellationToken.None));
    }

    private static PictureKind Kind(byte[] picture) => CreditsPictures.Classify(CreditsPictures.Measure(picture));

    /// <summary>Two pictures a second, as the server reads them.</summary>
    private static IEnumerable<byte[]> Seconds(int seconds, Func<int, byte[]> make) =>
        Enumerable.Range(0, seconds * CreditsPictures.FramesPerSecond).Select(index => make(index / CreditsPictures.FramesPerSecond));

    /// <summary>Credit cards of four seconds with half a second of black between them.</summary>
    private static IEnumerable<byte[]> CreditCards(int seconds) =>
        Enumerable.Range(0, seconds * CreditsPictures.FramesPerSecond).Select(index =>
            index % 8 == 7 ? new byte[CreditsPictures.FrameBytes] : SyntheticPictures.Credits(seed: index / 8));
}

/// <summary>Invented grey pictures of 320 × 180, seeded so every run sees the same.</summary>
internal static class SyntheticPictures
{
    private const int Width = CreditsPictures.Width;
    private const int Height = CreditsPictures.Height;

    /// <summary>Lines of white letters (thin strokes) on black around the middle.</summary>
    public static byte[] Credits(int seed, int lines = 4)
    {
        var picture = new byte[CreditsPictures.FrameBytes];
        var random = new Random(seed);
        for (var line = 0; line < lines; line++)
        {
            Letters(picture, random, top: 50 + line * 16, left: 90, count: 18);
        }
        return picture;
    }

    /// <summary>One line of white letters on black, in the subtitle area at the bottom.</summary>
    public static byte[] Subtitle(int seed)
    {
        var picture = new byte[CreditsPictures.FrameBytes];
        var random = new Random(seed);
        Letters(picture, random, top: 155, left: 60, count: 30);
        return picture;
    }

    /// <summary>A dark street at night: soft dark gradients with a few blurred lights.</summary>
    public static byte[] Night(int seed)
    {
        var picture = new byte[CreditsPictures.FrameBytes];
        var random = new Random(seed);
        var lights = Enumerable.Range(0, 4).Select(_ => (X: random.Next(Width), Y: random.Next(Height / 2))).ToArray();
        for (var y = 0; y < Height; y++)
        {
            for (var x = 0; x < Width; x++)
            {
                double value = 6 + 18.0 * y / Height;
                foreach (var light in lights)
                {
                    var distance = Math.Sqrt((x - light.X) * (x - light.X) + (y - light.Y) * (y - light.Y));
                    value += 120 * Math.Exp(-distance * distance / 60);
                }
                picture[y * Width + x] = (byte)Math.Clamp(value + random.Next(-2, 3), 0, 255);
            }
        }
        return picture;
    }

    /// <summary>A near-black tunnel: shadows of 5 to 20 with vertical bars and lamp reflections.</summary>
    public static byte[] Tunnel(int seed)
    {
        var picture = new byte[CreditsPictures.FrameBytes];
        var random = new Random(seed);
        for (var y = 0; y < Height; y++)
        {
            for (var x = 0; x < Width; x++)
            {
                var value = 5 + random.Next(16);
                if (x % 40 < 2 && y > 20) value = 200;
                if ((x - 160) * (x - 160) + (y - 90) * (y - 90) < 30) value = 230;
                picture[y * Width + x] = (byte)value;
            }
        }
        return picture;
    }

    /// <summary>A bright scene: a few soft shapes at random places with texture.</summary>
    public static byte[] Scene(int seed)
    {
        var picture = new byte[CreditsPictures.FrameBytes];
        var random = new Random(seed);
        var shapes = Enumerable.Range(0, 6).Select(_ => (X: random.Next(Width), Y: random.Next(Height),
            Size: 200.0 + random.Next(1_500), Level: random.Next(-90, 91))).ToArray();
        for (var y = 0; y < Height; y++)
        {
            for (var x = 0; x < Width; x++)
            {
                double value = 120;
                foreach (var shape in shapes)
                {
                    var distance = (x - shape.X) * (x - shape.X) + (y - shape.Y) * (y - shape.Y);
                    value += shape.Level * Math.Exp(-distance / shape.Size);
                }
                picture[y * Width + x] = (byte)Math.Clamp(value + random.Next(-12, 13), 0, 255);
            }
        }
        return picture;
    }

    /// <summary>The same card with a few different names written on it.</summary>
    public static byte[] WithNames(byte[] card, int seed)
    {
        var picture = (byte[])card.Clone();
        var random = new Random(seed);
        for (var index = 0; index < 120; index++)
        {
            var x = 120 + random.Next(80);
            var y = 80 + random.Next(20);
            picture[y * Width + x] = 30;
        }
        return picture;
    }

    private static void Letters(byte[] picture, Random random, int top, int left, int count)
    {
        for (var letter = 0; letter < count; letter++)
        {
            var x0 = left + letter * 8;
            // Two vertical strokes and one or two horizontal ones, a pixel wide, like small capitals.
            for (var y = top; y < top + 9; y++)
            {
                picture[y * Width + x0] = 235;
                if (random.Next(2) == 0) picture[y * Width + x0 + 4] = 235;
            }
            for (var x = x0; x <= x0 + 4; x++)
            {
                picture[top * Width + x] = 235;
                if (random.Next(2) == 0) picture[(top + 4) * Width + x] = 235;
            }
        }
    }
}
