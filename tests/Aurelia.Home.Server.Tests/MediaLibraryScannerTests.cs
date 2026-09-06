using Aurelia.Home.Contracts;
using Aurelia.Home.Server.Services;
using Xunit;

namespace Aurelia.Home.Server.Tests;

public sealed class MediaLibraryScannerTests
{
    private readonly MediaLibraryScanner scanner = new();

    [Theory]
    [InlineData("Show - S02E01 - Seven Thirty-Seven.mkv", null, 2, 1, "Seven Thirty-Seven")]
    [InlineData("Show.2x03.Grilled.1080p.mkv", null, 2, 3, "Grilled")]
    [InlineData("Season 4 Episode 7 - Problem Dog.mkv", null, 4, 7, "Problem Dog")]
    [InlineData("Episode 8 - Hermanos.mkv", 4, 4, 8, "Hermanos")]
    [InlineData("09 - Bug.mkv", 4, 4, 9, "Bug")]
    public void EpisodeParserRecognizesSupportedPatterns(
        string filename,
        int? expectedSeason,
        int season,
        int episode,
        string title)
    {
        var result = FilenameMetadataParser.Episode(filename, expectedSeason);

        Assert.Equal(season, result.Season);
        Assert.Equal(episode, result.Episode);
        Assert.Equal(title, result.Title);
    }

    [Fact]
    public void MovieScannerAssociatesExtrasAndIgnoresAppleDoubleFiles()
    {
        var root = CreateDirectory();
        try
        {
            var moviePath = Touch(root, "El Camino - A Breaking Bad Movie.mkv");
            Touch(root, "._El Camino - A Breaking Bad Movie.mkv");
            Touch(root, ".hidden.mkv");
            Touch(root, "Extras/Making El Camino.mkv");
            Touch(root, "Extras/Trailers/Official Trailer.mkv");
            Touch(root, "Artwork/poster.mp4.jpg");
            Touch(root, "Ignored.app/embedded.mkv");
            if (!OperatingSystem.IsWindows())
            {
                File.CreateSymbolicLink(Path.Combine(root, "linked.mkv"), moviePath);
            }

            var result = scanner.Scan(root, LibraryKind.Movies, [], null, CancellationToken.None);

            Assert.Equal(3, result.FilesDiscovered);
            Assert.Equal(3, result.Items.Count);
            var movie = Assert.Single(result.Items, item => item.Kind == MediaKind.Movie);
            Assert.Equal("El Camino - A Breaking Bad Movie", movie.DetectedTitle);
            var extra = Assert.Single(result.Items, item => item.Kind == MediaKind.Extra);
            Assert.Equal(movie.SourcePath, extra.ParentSourcePath);
            var trailer = Assert.Single(result.Items, item => item.Kind == MediaKind.Trailer);
            Assert.Equal(string.Empty, trailer.Category);
            Assert.Empty(result.Issues);
        }
        finally
        {
            DeleteFixture(root);
        }
    }

    [Fact]
    public void TvScannerBuildsSeasonsAndSeriesLevelExtras()
    {
        var root = CreateDirectory("Breaking Bad");
        try
        {
            Touch(root, "Season 1/Breaking Bad - S01E01 - Pilot (1080p BluRay x265).mkv");
            Touch(root, "Season 1/Breaking Bad 1x02 Cats in the Bag.mkv");
            Touch(root, "Season 1/Episode 3 - And the Bag's in the River.mkv");
            Touch(root, "Season 1/Extras/Making Of.mkv");
            Touch(root, "Extras/Series Retrospective.mkv");

            var result = scanner.Scan(root, LibraryKind.TvShows, [], null, CancellationToken.None);

            Assert.Equal(5, result.FilesDiscovered);
            var series = Assert.Single(result.Items, item => item.Kind == MediaKind.Series);
            Assert.Equal("Breaking Bad", series.DetectedTitle);
            Assert.Equal(3, result.Items.Count(item => item.Kind == MediaKind.Episode));
            var supplements = result.Items.Where(item => item.Kind == MediaKind.Extra).ToList();
            Assert.Equal(2, supplements.Count);
            Assert.Contains(supplements, item => item.SeasonNumber == 1);
            Assert.Contains(supplements, item => item.SeasonNumber is null);
            Assert.All(result.Items.Where(item => item.Kind != MediaKind.Series), item =>
                Assert.Equal(series.SourcePath, item.ParentSourcePath));
        }
        finally
        {
            DeleteFixture(root);
        }
    }

    [Fact]
    public void ExistingEpisodeBindingWinsAConflict()
    {
        var root = CreateDirectory("Conflict Show");
        try
        {
            var existingPath = Touch(root, "Season 1/Show S01E01 Existing.mkv");
            var duplicatePath = Touch(root, "Season 1/Show S01E01 Duplicate.mkv");
            var existing = new ExistingEpisodeBinding(root, 1, 1, existingPath);

            var result = scanner.Scan(
                root,
                LibraryKind.TvShows,
                [existing],
                null,
                CancellationToken.None);

            var episode = Assert.Single(result.Items, item => item.Kind == MediaKind.Episode);
            Assert.Equal(existingPath, episode.SourcePath);
            var issue = Assert.Single(result.Issues, issue => issue.Code == "duplicate_episode");
            Assert.Equal(duplicatePath, issue.Path);
            Assert.Equal(1, result.SkippedFiles);
        }
        finally
        {
            DeleteFixture(root);
        }
    }

    [Fact]
    public void TvCollectionRootFindsMultipleSeries()
    {
        var root = CreateDirectory();
        try
        {
            Touch(root, "First Show/Season 1/First Show S01E01 Pilot.mkv");
            Touch(root, "Second Show/Season 1/Second Show S01E01 Pilot.mkv");

            var result = scanner.Scan(root, LibraryKind.TvShows, [], null, CancellationToken.None);

            var titles = result.Items
                .Where(item => item.Kind == MediaKind.Series)
                .Select(item => item.DetectedTitle)
                .OrderBy(title => title)
                .ToList();
            Assert.Equal(["First Show", "Second Show"], titles);
            Assert.Equal(2, result.Items.Count(item => item.Kind == MediaKind.Episode));
        }
        finally
        {
            DeleteFixture(root);
        }
    }

    [Fact]
    public void LibraryCommandParserKeepsPathsAndFlagsSeparate()
    {
        var command = ServerCommandLine.Parse(
            [
                "library",
                "add",
                "--kind",
                "tv",
                "--path",
                "/Volumes/Media Drive/TV Shows",
                "--username",
                "lucas",
                "--password-stdin",
            ]);

        Assert.Equal("library", command.Command);
        Assert.Equal("add", command.Action);
        Assert.Equal("tv", command.Option("--kind"));
        Assert.Equal("/Volumes/Media Drive/TV Shows", command.Option("--path"));
        Assert.Equal("lucas", command.Username);
        Assert.True(command.PasswordFromStandardInput);
    }

    private static string CreateDirectory(string? name = null)
    {
        var root = TestPaths.CreateDataDirectory();
        if (name is not null)
        {
            root = Path.Combine(root, name);
        }

        Directory.CreateDirectory(root);
        return root;
    }

    private static string Touch(string root, string relativePath)
    {
        var path = Path.Combine(root, relativePath);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, [1, 2, 3]);
        return path;
    }

    private static void DeleteFixture(string root)
    {
        var parent = Directory.GetParent(root);
        var target = parent is not null && Guid.TryParseExact(parent.Name, "N", out _)
            ? parent.FullName
            : root;
        if (Directory.Exists(target))
        {
            Directory.Delete(target, recursive: true);
        }
    }
}
