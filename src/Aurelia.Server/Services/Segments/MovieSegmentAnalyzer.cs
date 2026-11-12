using Aurelia.Contracts;

namespace Aurelia.Server.Services.Segments;

/// <summary>
/// Finds a movie's end credits. A movie has no other episodes to compare with, so its credits come
/// from a chapter named like credits or from its last pictures (text on black). Its intro comes
/// only from a chapter or from a person's correction. Anything uncertain is left out.
/// </summary>
/// <param name="movie">The movie's length and chapters.</param>
/// <param name="pictures">Loads grey pictures of a stretch (start, length), or null when the movie cannot be read; null skips pictures.</param>
public sealed class MovieSegmentAnalyzer(
    SegmentEpisode movie,
    Func<double, double, CancellationToken, Task<PictureWindow?>>? pictures)
{
    /// <summary>Shorter titles are not treated as movies with credits.</summary>
    public const double MinimumMovieSeconds = 20 * 60;

    /// <summary>The ending that is searched: 20 minutes or 15 % of the movie, whichever is shorter.</summary>
    public static double CreditsWindowSeconds(double duration) => Math.Min(1200, duration * 0.15);

    /// <summary>A chapter named like credits within the searched ending, at least 45 seconds long.</summary>
    public static double? CreditsChapter(SegmentEpisode movie)
    {
        ArgumentNullException.ThrowIfNull(movie);
        var window = CreditsWindowSeconds(movie.DurationSeconds);
        var chapter = SegmentRules.NamedCreditsChapter(movie);
        return chapter is { } found && found.Start >= movie.DurationSeconds - window && found.Start < movie.DurationSeconds
            && found.End - found.Start >= CreditsRules.Movie.MinimumSeconds ? found.Start : null;
    }

    public async Task<DetectedSegments> AnalyzeAsync(CancellationToken cancellationToken)
    {
        var duration = movie.DurationSeconds;
        if (duration < MinimumMovieSeconds) return DetectedSegments.Nothing;
        double? introStart = null, introEnd = null;
        var introSource = MediaSegmentSource.None;
        var introConfidence = 0.0;
        if (SegmentRules.IntroChapter(movie) is { } intro)
        {
            (introStart, introEnd, introSource, introConfidence) = (intro.Start, intro.End, MediaSegmentSource.Chapters, 1);
        }

        double? creditsStart = null;
        var creditsSource = MediaSegmentSource.None;
        var creditsConfidence = 0.0;
        if (CreditsChapter(movie) is { } chapter)
        {
            (creditsStart, creditsSource, creditsConfidence) = (chapter, MediaSegmentSource.Chapters, 1);
        }
        else if (pictures is not null)
        {
            var length = CreditsWindowSeconds(duration);
            var start = Math.Max(0, duration - length);
            if (await pictures(start, length, cancellationToken) is { Kinds.Length: > 0 } window
                && CreditsPictures.Find(window, new bool[window.Kinds.Length], duration, CreditsRules.Movie) is { } found
                && found.Confidence >= SegmentRules.MinimumConfidence && found.Start > duration / 2)
            {
                (creditsStart, creditsSource, creditsConfidence) = (found.Start, MediaSegmentSource.Detected, found.Confidence);
            }
        }
        return new DetectedSegments(introStart, introEnd, introSource, introConfidence, creditsStart, creditsSource, creditsConfidence);
    }
}
