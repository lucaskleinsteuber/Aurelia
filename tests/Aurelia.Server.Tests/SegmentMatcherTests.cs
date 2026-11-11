using Aurelia.Contracts;
using Aurelia.Server.Services.Segments;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>
/// Intro and credits detection on invented sound: generated tones and noise, no media file and no
/// ffmpeg. Each rule against wrong times has its own test.
/// </summary>
public sealed class SegmentMatcherTests
{
    private const int Rate = AudioFingerprint.SampleRate;
    private const double EpisodeSeconds = 1_500;

    [Fact]
    public async Task ASharedIntroBehindColdOpensOfDifferentLengthIsFoundWithinHalfASecond()
    {
        var intro = SyntheticAudio.Music(seed: 1, seconds: 40);
        double[] coldOpens = [0, 45, 130, 300];
        var episodes = coldOpens.Select((coldOpen, index) => SyntheticAudio.Join(
            SyntheticAudio.Music(seed: 100 + index, seconds: coldOpen), intro, SyntheticAudio.Music(seed: 200 + index, seconds: 25))).ToArray();
        var analyzer = Analyzer(episodes, SegmentKind.Intro);

        for (var index = 0; index < episodes.Length; index++)
        {
            var result = await analyzer.AnalyzeAsync(index, CancellationToken.None);
            Assert.Equal(MediaSegmentSource.Detected, result.IntroSource);
            Assert.InRange(result.IntroStart!.Value, coldOpens[index] - 0.5, coldOpens[index] + 0.5);
            Assert.InRange(result.IntroEnd!.Value, coldOpens[index] + 39.5, coldOpens[index] + 40.5);
            Assert.True(result.IntroConfidence >= SegmentRules.MinimumConfidence);
            Assert.Equal(MediaSegmentSource.None, result.CreditsSource);
        }
    }

    [Fact]
    public async Task ARecapSharedByOnlyTwoEpisodesIsNotAnIntro()
    {
        var recap = SyntheticAudio.Music(seed: 2, seconds: 30);
        var episodes = Enumerable.Range(0, 4).Select(index => index is 1 or 2
            ? SyntheticAudio.Join(SyntheticAudio.Music(seed: 300 + index, seconds: 20 + index * 10), recap, SyntheticAudio.Music(seed: 400 + index, seconds: 40))
            : SyntheticAudio.Music(seed: 300 + index, seconds: 100)).ToArray();
        var analyzer = Analyzer(episodes, SegmentKind.Intro);

        for (var index = 0; index < episodes.Length; index++)
        {
            Assert.Equal(DetectedSegments.Nothing, await analyzer.AnalyzeAsync(index, CancellationToken.None));
        }
    }

    [Fact]
    public async Task AnEpisodeWithoutTheIntroGetsNoTimesWhileItsNeighboursKeepTheirs()
    {
        var intro = SyntheticAudio.Music(seed: 3, seconds: 35);
        var episodes = Enumerable.Range(0, 4).Select(index => index == 2
            ? SyntheticAudio.Music(seed: 500 + index, seconds: 110)
            : SyntheticAudio.Join(SyntheticAudio.Music(seed: 500 + index, seconds: 15 + index * 12), intro, SyntheticAudio.Music(seed: 600 + index, seconds: 30))).ToArray();
        var analyzer = Analyzer(episodes, SegmentKind.Intro);

        Assert.Equal(MediaSegmentSource.None, (await analyzer.AnalyzeAsync(2, CancellationToken.None)).IntroSource);
        foreach (var index in new[] { 0, 1, 3 })
        {
            var result = await analyzer.AnalyzeAsync(index, CancellationToken.None);
            Assert.Equal(MediaSegmentSource.Detected, result.IntroSource);
            Assert.InRange(result.IntroStart!.Value, 15 + index * 12 - 0.5, 15 + index * 12 + 0.5);
        }
    }

    [Fact]
    public async Task DifferentLoudnessAndEncodingNoiseAreTolerated()
    {
        var intro = SyntheticAudio.Music(seed: 4, seconds: 30);
        double[] gains = [1, 0.2, 0.6, 0.35];
        var episodes = gains.Select((gain, index) => SyntheticAudio.Noisy(SyntheticAudio.Scale(SyntheticAudio.Join(
            SyntheticAudio.Music(seed: 700 + index, seconds: 10 + index * 8), intro, SyntheticAudio.Music(seed: 800 + index, seconds: 20)), gain), seed: 900 + index)).ToArray();
        var analyzer = Analyzer(episodes, SegmentKind.Intro);

        for (var index = 0; index < episodes.Length; index++)
        {
            var result = await analyzer.AnalyzeAsync(index, CancellationToken.None);
            Assert.Equal(MediaSegmentSource.Detected, result.IntroSource);
            Assert.InRange(result.IntroStart!.Value, 10 + index * 8 - 0.5, 10 + index * 8 + 0.5);
            Assert.InRange(result.IntroEnd!.Value, 40 + index * 8 - 0.5, 40 + index * 8 + 0.5);
        }
    }

    [Fact]
    public async Task BoundariesLandOnTheSilenceAroundTheIntro()
    {
        // The intro fades in and out of half a second of silence that lies 0.8 s outside the
        // shared music, as when a title card is held before the theme begins.
        var intro = SyntheticAudio.Music(seed: 5, seconds: 30);
        var episodes = Enumerable.Range(0, 4).Select(index => SyntheticAudio.Join(
            SyntheticAudio.Music(seed: 1000 + index, seconds: 20 + index * 10), SyntheticAudio.Silence(0.5),
            SyntheticAudio.Music(seed: 1100 + index, seconds: 0.8), intro, SyntheticAudio.Music(seed: 1200 + index, seconds: 0.8),
            SyntheticAudio.Silence(0.5), SyntheticAudio.Music(seed: 1300 + index, seconds: 20))).ToArray();
        var analyzer = Analyzer(episodes, SegmentKind.Intro);

        for (var index = 0; index < episodes.Length; index++)
        {
            var coldOpen = 20 + index * 10;
            var result = await analyzer.AnalyzeAsync(index, CancellationToken.None);
            Assert.InRange(result.IntroStart!.Value, coldOpen, coldOpen + 0.5);
            Assert.InRange(result.IntroEnd!.Value, coldOpen + 32.1, coldOpen + 32.6);
        }
    }

    [Fact]
    public void ABoundaryInsideContinuousSoundStaysWhereItIs()
    {
        var window = SegmentWindow.FromPcm(SyntheticAudio.Noise(seed: 6, seconds: 10), startSeconds: 100);
        Assert.Equal(105, SegmentRules.SnapToSilence(window, 105));
    }

    [Fact]
    public async Task NoiseWithNothingInCommonGivesNoResult()
    {
        var episodes = Enumerable.Range(0, 4).Select(index => SyntheticAudio.Noise(seed: 1400 + index, seconds: 90)).ToArray();
        var analyzer = Analyzer(episodes, SegmentKind.Intro);
        for (var index = 0; index < episodes.Length; index++)
        {
            Assert.Equal(DetectedSegments.Nothing, await analyzer.AnalyzeAsync(index, CancellationToken.None));
        }
        Assert.Empty(SegmentMatcher.CommonPassages(
            AudioFingerprint.Compute(episodes[0]).Values, AudioFingerprint.Compute(episodes[1]).Values, 10, 150));
    }

    [Fact]
    public async Task SharedSilenceIsNotAPassage()
    {
        var episodes = Enumerable.Range(0, 4).Select(index => SyntheticAudio.Join(
            SyntheticAudio.Music(seed: 1500 + index, seconds: 20), SyntheticAudio.Silence(30), SyntheticAudio.Music(seed: 1600 + index, seconds: 20))).ToArray();
        var analyzer = Analyzer(episodes, SegmentKind.Intro);
        for (var index = 0; index < episodes.Length; index++)
        {
            Assert.Equal(DetectedSegments.Nothing, await analyzer.AnalyzeAsync(index, CancellationToken.None));
        }
    }

    [Fact]
    public async Task TwoEpisodesNeedOneVeryClearComparison()
    {
        var intro = SyntheticAudio.Music(seed: 7, seconds: 30);
        var episodes = Enumerable.Range(0, 2).Select(index => SyntheticAudio.Join(
            SyntheticAudio.Music(seed: 1700 + index, seconds: 10 + index * 20), intro, SyntheticAudio.Music(seed: 1800 + index, seconds: 20))).ToArray();
        var analyzer = Analyzer(episodes, SegmentKind.Intro);

        for (var index = 0; index < episodes.Length; index++)
        {
            var result = await analyzer.AnalyzeAsync(index, CancellationToken.None);
            Assert.Equal(MediaSegmentSource.Detected, result.IntroSource);
            Assert.InRange(result.IntroStart!.Value, 10 + index * 20 - 0.5, 10 + index * 20 + 0.5);
            Assert.Equal(0.75, result.IntroConfidence);
        }
    }

    [Fact]
    public async Task AnIntroChapterTakesPrecedenceAndNothingIsComparedForIt()
    {
        var intro = SyntheticAudio.Music(seed: 8, seconds: 30);
        var sound = Enumerable.Range(0, 3).Select(index => SyntheticAudio.Join(
            SyntheticAudio.Music(seed: 1900 + index, seconds: 12), intro, SyntheticAudio.Music(seed: 2000 + index, seconds: 20))).ToArray();
        var loaded = new List<(int Index, SegmentKind Kind)>();
        var episodes = sound.Select((_, index) => new SegmentEpisode(EpisodeSeconds, index == 0
            ? [new(0, 14.5, "Cold Open"), new(14.5, 44.25, "opening"), new(44.25, 1_400, "Episode"), new(1_400, EpisodeSeconds, "ED")]
            : [])).ToArray();
        var analyzer = new SeasonSegmentAnalyzer(episodes, (index, kind, _) =>
        {
            loaded.Add((index, kind));
            return Task.FromResult<SegmentWindow?>(kind == SegmentKind.Intro ? SegmentWindow.FromPcm(sound[index], 0) : null);
        });

        var result = await analyzer.AnalyzeAsync(0, CancellationToken.None);

        Assert.Equal((14.5, 44.25, MediaSegmentSource.Chapters, 1.0), (result.IntroStart, result.IntroEnd, result.IntroSource, result.IntroConfidence));
        Assert.Equal((1_400.0, MediaSegmentSource.Chapters), (result.CreditsStart, result.CreditsSource));
        Assert.Empty(loaded);
    }

    [Theory]
    [InlineData("Intro", true, false)]
    [InlineData("OPENING", true, false)]
    [InlineData("OP", true, false)]
    [InlineData("Opening Credits", true, false)]
    [InlineData("OP 2", true, false)]
    [InlineData("Credits", false, true)]
    [InlineData("Ending", false, true)]
    [InlineData("ed", false, true)]
    [InlineData("End Credits", false, true)]
    [InlineData("Chapter 1", false, false)]
    [InlineData("Operation", false, false)]
    [InlineData("The Ending of Everything", false, false)]
    public void ChapterNamesDecideWhatAChapterIs(string title, bool intro, bool credits)
    {
        var asIntro = new SegmentEpisode(EpisodeSeconds, [new(60, 150, title)]);
        var asCredits = new SegmentEpisode(EpisodeSeconds, [new(1_380, 1_470, title)]);
        Assert.Equal(intro, SegmentRules.IntroChapter(asIntro) is not null);
        Assert.Equal(credits, SegmentRules.CreditsChapter(asCredits) is not null);
    }

    [Fact]
    public void ChaptersOutsideTheLimitsAreIgnored()
    {
        // An "Opening" of five minutes is a scene, not an intro; "Credits" in the middle are not the end.
        Assert.Null(SegmentRules.IntroChapter(new SegmentEpisode(EpisodeSeconds, [new(0, 300, "Opening")])));
        Assert.Null(SegmentRules.IntroChapter(new SegmentEpisode(EpisodeSeconds, [new(0, 5, "Intro")])));
        Assert.Null(SegmentRules.CreditsChapter(new SegmentEpisode(EpisodeSeconds, [new(600, 700, "Credits")])));
        Assert.Null(SegmentRules.CreditsChapter(new SegmentEpisode(EpisodeSeconds, [new(1_495, EpisodeSeconds, "Credits")])));
    }

    [Fact]
    public async Task SharedCreditsMusicGivesTheCreditsStartEvenWithASceneAfterIt()
    {
        var credits = SyntheticAudio.Music(seed: 9, seconds: 40);
        double[] afterCredits = [0, 0, 70, 5];
        var windows = afterCredits.Select((after, index) => SyntheticAudio.Join(
            SyntheticAudio.Music(seed: 2100 + index, seconds: 30 + index * 7), credits, SyntheticAudio.Music(seed: 2200 + index, seconds: after))).ToArray();
        var analyzer = Analyzer(windows, SegmentKind.Credits);

        for (var index = 0; index < windows.Length; index++)
        {
            var expected = EpisodeSeconds - afterCredits[index] - 40;
            var result = await analyzer.AnalyzeAsync(index, CancellationToken.None);
            Assert.Equal(MediaSegmentSource.Detected, result.CreditsSource);
            Assert.InRange(result.CreditsStart!.Value, expected - 0.5, expected + 0.5);
            Assert.Equal(MediaSegmentSource.None, result.IntroSource);
        }
    }

    [Fact]
    public async Task PassagesOutsideTheLimitsAreDiscarded()
    {
        // 170 s of shared sound is too long for an intro (a repeated scene or a duplicate file),
        // 9 s too short (a logo jingle); 12 s of shared ending is too short for credits.
        var tooLong = SyntheticAudio.Music(seed: 10, seconds: 170);
        var tooShort = SyntheticAudio.Music(seed: 11, seconds: 9);
        var jingle = SyntheticAudio.Music(seed: 12, seconds: 12);
        var longEpisodes = Enumerable.Range(0, 3).Select(index => SyntheticAudio.Join(SyntheticAudio.Music(seed: 2300 + index, seconds: 5 + index * 4), tooLong)).ToArray();
        var shortEpisodes = Enumerable.Range(0, 3).Select(index => SyntheticAudio.Join(
            SyntheticAudio.Music(seed: 2400 + index, seconds: 15 + index * 4), tooShort, SyntheticAudio.Music(seed: 2500 + index, seconds: 30))).ToArray();
        var endings = Enumerable.Range(0, 3).Select(index => SyntheticAudio.Join(SyntheticAudio.Music(seed: 2600 + index, seconds: 40 + index * 4), jingle)).ToArray();

        for (var index = 0; index < 3; index++)
        {
            Assert.Equal(DetectedSegments.Nothing, await Analyzer(longEpisodes, SegmentKind.Intro).AnalyzeAsync(index, CancellationToken.None));
            Assert.Equal(DetectedSegments.Nothing, await Analyzer(shortEpisodes, SegmentKind.Intro).AnalyzeAsync(index, CancellationToken.None));
            Assert.Equal(DetectedSegments.Nothing, await Analyzer(endings, SegmentKind.Credits).AnalyzeAsync(index, CancellationToken.None));
        }
    }

    [Fact]
    public async Task ALateIntroIsFoundWhenFourOtherEpisodesHaveItButNotWhenOnlyTwoShareTheMusic()
    {
        // 25-minute episodes: the first window is 10 minutes, the late search goes to 12:30.
        var intro = SyntheticAudio.Music(seed: 21, seconds: 30);
        var recap = SyntheticAudio.Music(seed: 22, seconds: 30);
        short[] Episode(int index, double introAt, bool recapLate = false) => SyntheticAudio.Join(
            SyntheticAudio.Music(seed: 2700 + index, seconds: introAt), intro,
            SyntheticAudio.Music(seed: 2800 + index, seconds: recapLate ? 700 - introAt - 30 : 750 - introAt - 30),
            recapLate ? SyntheticAudio.Join(recap, SyntheticAudio.Music(seed: 2900 + index, seconds: 20)) : []);
        var sound = new[] { Episode(0, 40), Episode(1, 680), Episode(2, 25), Episode(3, 60), Episode(4, 35) };
        var result = await LateAnalyzer(sound).AnalyzeAsync(1, CancellationToken.None);
        Assert.Equal(MediaSegmentSource.Detected, result.IntroSource);
        Assert.InRange(result.IntroStart!.Value, 679.5, 680.5);
        Assert.InRange(result.IntroEnd!.Value, 709.5, 710.5);

        // Music shared late by only two episodes (a recap) is no intro.
        var recapSeason = Enumerable.Range(0, 5).Select(index => index is 1 or 2
            ? SyntheticAudio.Join(SyntheticAudio.Music(seed: 3000 + index, seconds: 700), recap, SyntheticAudio.Music(seed: 3100 + index, seconds: 20))
            : SyntheticAudio.Music(seed: 3000 + index, seconds: 750)).ToArray();
        Assert.Equal(DetectedSegments.Nothing, await LateAnalyzer(recapSeason).AnalyzeAsync(1, CancellationToken.None));
    }

    /// <summary>Episodes of 1 500 s whose given sound covers their first half.</summary>
    private static SeasonSegmentAnalyzer LateAnalyzer(short[][] sound) => new(
        [.. sound.Select(_ => new SegmentEpisode(EpisodeSeconds, []))],
        (index, kind, _) =>
        {
            if (kind == SegmentKind.Credits) return Task.FromResult<SegmentWindow?>(null);
            var start = kind == SegmentKind.Intro ? 0 : SegmentRules.LateIntroStartSeconds(EpisodeSeconds);
            var length = kind == SegmentKind.Intro ? SegmentRules.IntroWindowSeconds(EpisodeSeconds) : SegmentRules.LateIntroLengthSeconds(EpisodeSeconds);
            var samples = sound[index].Skip((int)(start * Rate)).Take((int)(length * Rate)).ToArray();
            return Task.FromResult<SegmentWindow?>(SegmentWindow.FromPcm(samples, start));
        });

    [Fact]
    public async Task ASeasonOfOneEpisodeHasNothingToCompare()
    {
        var analyzer = Analyzer([SyntheticAudio.Music(seed: 13, seconds: 60)], SegmentKind.Intro);
        Assert.Equal(DetectedSegments.Nothing, await analyzer.AnalyzeAsync(0, CancellationToken.None));
    }

    /// <summary>
    /// Episodes of 25 minutes whose given sound is the start (intro) or the end (credits) of the
    /// file; the other window has no sound.
    /// </summary>
    private static SeasonSegmentAnalyzer Analyzer(short[][] sound, SegmentKind provided)
    {
        var fingerprints = new SegmentWindow?[sound.Length];
        return new SeasonSegmentAnalyzer(
            [.. sound.Select(_ => new SegmentEpisode(EpisodeSeconds, []))],
            (index, kind, _) =>
            {
                if (kind != provided) return Task.FromResult<SegmentWindow?>(null);
                var start = kind == SegmentKind.Intro ? 0 : EpisodeSeconds - (double)sound[index].Length / Rate;
                return Task.FromResult<SegmentWindow?>(fingerprints[index] ??= SegmentWindow.FromPcm(sound[index], start));
            });
    }
}

/// <summary>Invented sound for detection tests: seeded, so every run hears the same.</summary>
internal static class SyntheticAudio
{
    private const int Rate = AudioFingerprint.SampleRate;

    /// <summary>Chords of six tones that change every 0.15 to 0.45 s, like a melody.</summary>
    public static short[] Music(int seed, double seconds)
    {
        var random = new Random(seed);
        var samples = new short[(int)Math.Round(seconds * Rate)];
        var position = 0;
        while (position < samples.Length)
        {
            var length = Math.Min(samples.Length - position, (int)(Rate * (0.15 + random.NextDouble() * 0.3)));
            // Six tones with an overtone each, so most of the compared bands carry sound as in real music.
            var frequencies = Enumerable.Range(0, 6).Select(_ => 150 + random.NextDouble() * 1_000).ToArray();
            var amplitude = 0.03 + random.NextDouble() * 0.04;
            for (var index = 0; index < length; index++)
            {
                var envelope = Math.Min(1, Math.Min(index, length - index) / (Rate * 0.01));
                double value = 0;
                foreach (var frequency in frequencies)
                {
                    value += Math.Sin(2 * Math.PI * frequency * index / Rate) + 0.5 * Math.Sin(4 * Math.PI * frequency * index / Rate);
                }
                samples[position + index] = (short)(value * amplitude * envelope * short.MaxValue);
            }
            position += length;
        }
        return samples;
    }

    public static short[] Noise(int seed, double seconds)
    {
        var random = new Random(seed);
        var samples = new short[(int)Math.Round(seconds * Rate)];
        for (var index = 0; index < samples.Length; index++) samples[index] = (short)((random.NextDouble() - 0.5) * 0.5 * short.MaxValue);
        return samples;
    }

    public static short[] Silence(double seconds) => new short[(int)Math.Round(seconds * Rate)];

    public static short[] Join(params short[][] parts) => [.. parts.SelectMany(part => part)];

    public static short[] Scale(short[] samples, double gain) => [.. samples.Select(sample => (short)(sample * gain))];

    /// <summary>Adds faint noise, as two separately encoded copies of the same music differ.</summary>
    public static short[] Noisy(short[] samples, int seed)
    {
        var random = new Random(seed);
        return [.. samples.Select(sample => (short)Math.Clamp(sample + (random.NextDouble() - 0.5) * 200, short.MinValue, short.MaxValue))];
    }
}
