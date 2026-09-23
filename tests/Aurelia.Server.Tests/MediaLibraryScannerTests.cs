using Aurelia.Contracts;
using Aurelia.Server.Services;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class MediaLibraryScannerTests
{
    private readonly MediaLibraryScanner scanner = new();

    [Theory]
    [InlineData("Show - S02E01 - Seven Thirty-Seven.mkv", null, 2, 1, "Seven Thirty-Seven")]
    [InlineData("Show.2x03.Grilled.1080p.mkv", null, 2, 3, "Grilled")]
    [InlineData("Season 4 Episode 7 - Problem Dog.mkv", null, 4, 7, "Problem Dog")]
    [InlineData("Episode 8 - Hermanos.mkv", 4, 4, 8, "Hermanos")]
    [InlineData("09 - Bug.mkv", 4, 4, 9, "Bug")]
    [InlineData("ShowS02E03 - Compact Name.mkv", null, 2, 3, "Compact Name")]
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
    public void MovieScannerAttachesAnExplicitTrailerToOneExactTitleMatch()
    {
        var root = CreateDirectory("Trailer Match");
        try
        {
            var moviePath = Touch(root, "The Truman Show (1998).mkv");
            Touch(root, "The Truman Show - Official Trailer.mp4");

            var result = scanner.Scan(root, LibraryKind.Movies, [], null, CancellationToken.None);

            var movie = Assert.Single(result.Items, item => item.Kind == MediaKind.Movie);
            var trailer = Assert.Single(result.Items, item => item.Kind == MediaKind.Trailer);
            Assert.Equal(moviePath, movie.SourcePath);
            Assert.Equal(movie.SourcePath, trailer.ParentSourcePath);
            Assert.Empty(result.ImportReviews!);
        }
        finally
        {
            DeleteFixture(root);
        }
    }

    [Theory]
    [InlineData(false, "No exact movie title match was found in this storage location.")]
    [InlineData(true, "More than one movie has this title in this storage location.")]
    public void MovieScannerRequiresReviewWhenATrailerMatchIsNotUnique(
        bool ambiguous,
        string expectedReason)
    {
        var root = CreateDirectory("Trailer Review");
        try
        {
            if (ambiguous)
            {
                Touch(root, "First/The Truman Show (1998).mkv");
                Touch(root, "Second/The Truman Show (1998).mkv");
            }
            else
            {
                Touch(root, "Other Movie (1998).mkv");
            }

            var trailerPath = Touch(root, "The Truman Show - Trailer.mp4");
            var result = scanner.Scan(root, LibraryKind.Movies, [], null, CancellationToken.None);

            Assert.Contains(result.Items, item =>
                item.Kind == MediaKind.Trailer
                && item.SourcePath == trailerPath
                && item.ParentSourcePath is null);
            var review = Assert.Single(result.ImportReviews!);
            Assert.Equal(trailerPath, review.SourcePath);
            Assert.Equal("The Truman Show", review.DetectedTitle);
            Assert.Equal(expectedReason, review.Reason);
            Assert.DoesNotContain(result.Items, item =>
                item.Kind == MediaKind.Movie && item.SourcePath == trailerPath);
        }
        finally
        {
            DeleteFixture(root);
        }
    }

    [Theory]
    [InlineData(LibraryImportReviewState.Assigned, true)]
    [InlineData(LibraryImportReviewState.Ignored, false)]
    public void MovieScannerPreservesExplicitTrailerReviewDecisions(
        LibraryImportReviewState state,
        bool expectParent)
    {
        var root = CreateDirectory("Trailer Decision");
        try
        {
            var moviePath = Touch(root, "The Truman Show (1998).mkv");
            var trailerPath = Touch(root, "Unrelated Name - Trailer.mp4");
            var decisions = new[]
            {
                new ExistingImportReviewDecision(trailerPath, state, expectParent ? moviePath : null),
            };

            var result = scanner.Scan(
                root,
                LibraryKind.Movies,
                [],
                null,
                CancellationToken.None,
                importReviewDecisions: decisions);

            var trailer = Assert.Single(result.Items, item => item.Kind == MediaKind.Trailer);
            Assert.Equal(expectParent ? moviePath : null, trailer.ParentSourcePath);
            Assert.Empty(result.ImportReviews!);
        }
        finally
        {
            DeleteFixture(root);
        }
    }

    [Theory]
    [InlineData(LibraryImportReviewState.Assigned, true)]
    [InlineData(LibraryImportReviewState.Ignored, false)]
    public void MovieScannerAppliesReviewDecisionsToTrailersInsideExtrasFolders(
        LibraryImportReviewState state,
        bool expectParent)
    {
        var root = CreateDirectory("Trailer Extras Decision");
        try
        {
            var moviePath = Touch(root, "The Truman Show (1998).mkv");
            var trailerPath = Touch(root, "Extras/Trailers/Unrelated Name.mp4");
            var decision = new ExistingImportReviewDecision(
                trailerPath,
                state,
                expectParent ? moviePath : null);

            var result = scanner.Scan(
                root,
                LibraryKind.Movies,
                [],
                null,
                CancellationToken.None,
                importReviewDecisions: [decision]);

            var trailer = Assert.Single(result.Items, item => item.Kind == MediaKind.Trailer);
            Assert.Equal(expectParent ? moviePath : null, trailer.ParentSourcePath);
            Assert.Empty(result.ImportReviews!);
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
    public void TvScannerForceImportsUnnumberedFilesInNaturalOrder()
    {
        var root = CreateDirectory("Unnumbered Show");
        try
        {
            Touch(root, "Leon Part 10.mkv");
            Touch(root, "Leon Part 2.mkv");
            Touch(root, "Leon Part 1.mkv");

            var result = scanner.Scan(root, LibraryKind.TvShows, [], null, CancellationToken.None);

            var episodes = result.Items
                .Where(item => item.Kind == MediaKind.Episode)
                .OrderBy(item => item.EpisodeNumber)
                .ToList();
            Assert.Equal(3, episodes.Count);
            Assert.EndsWith("Leon Part 1.mkv", episodes[0].SourcePath, StringComparison.Ordinal);
            Assert.EndsWith("Leon Part 2.mkv", episodes[1].SourcePath, StringComparison.Ordinal);
            Assert.EndsWith("Leon Part 10.mkv", episodes[2].SourcePath, StringComparison.Ordinal);
            Assert.Equal([1, 2, 3], episodes.Select(item => item.EpisodeNumber).ToArray());
            Assert.Equal(0, result.SkippedFiles);
            Assert.Empty(result.Issues);
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
    public void AutomaticScannerSeparatesShowsMoviesContainersAndAmbiguousFolders()
    {
        var root = CreateDirectory("Mixed Drive");
        try
        {
            Touch(root, "Breaking Bad/Season 1/Breaking Bad S01E01 Pilot.mkv");
            Touch(root, "Breaking Bad/Season 1/Breaking Bad S01E02 Cat's in the Bag.mkv");
            Touch(root, "El Camino/El Camino - A Breaking Bad Movie.mkv");
            Touch(root, "El Camino/Extras/Making El Camino.mkv");
            Touch(root, "Minions & Despicable Me/Minions/Minions.mkv");
            Touch(root, "Minions & Despicable Me/Despicable Me/Despicable Me.mkv");
            Touch(root, "Tiktok/clip-one.mkv");
            Touch(root, "Tiktok/clip-two.mp4");

            var result = scanner.Scan(
                root,
                LibraryKind.Automatic,
                [],
                null,
                CancellationToken.None);

            var series = Assert.Single(result.Items, item => item.Kind == MediaKind.Series);
            Assert.Equal("Breaking Bad", series.DetectedTitle);
            Assert.Equal(2, result.Items.Count(item => item.Kind == MediaKind.Episode));
            Assert.Equal(3, result.Items.Count(item => item.Kind == MediaKind.Movie));
            Assert.Single(result.Items, item => item.Kind == MediaKind.Extra);
            Assert.DoesNotContain(result.Items, item => item.SourcePath.Contains("Tiktok"));

            var review = Assert.Single(result.Classifications!, item => item.RelativePath == "Tiktok");
            Assert.True(review.NeedsReview);
            Assert.Null(review.SuggestedKind);
            Assert.Equal("multiple_unmatched_videos", review.Reason);
            Assert.Contains(result.Issues, issue => issue.Code == "classification_required");
        }
        finally
        {
            DeleteFixture(root);
        }
    }

    [Fact]
    public void AutomaticScannerKeepsLooseRootVideosSeparateFromNestedTitles()
    {
        var root = CreateDirectory("Mixed Root With Loose Video");
        try
        {
            Touch(root, "Loose Clip.mkv");
            Touch(root, "Movies/El Camino/El Camino.mkv");
            Touch(root, "TV/Breaking Bad/Season 1/Breaking Bad S01E01.mkv");

            var result = scanner.Scan(
                root,
                LibraryKind.Automatic,
                [],
                null,
                CancellationToken.None);

            Assert.Contains(result.Items, item =>
                item.Kind == MediaKind.Movie
                && item.DetectedTitle == "Loose Clip"
                && item.SourcePath == Path.Combine(root, "Loose Clip.mkv"));
            Assert.Contains(result.Items, item =>
                item.Kind == MediaKind.Movie
                && item.DetectedTitle == "El Camino");
            Assert.Contains(result.Items, item =>
                item.Kind == MediaKind.Series
                && item.DetectedTitle == "Breaking Bad");
            Assert.DoesNotContain(result.Items, item =>
                item.ParentSourcePath == root
                && item.SourcePath.Contains("Breaking Bad", StringComparison.Ordinal));
        }
        finally
        {
            DeleteFixture(root);
        }
    }

    [Fact]
    public void AutomaticScannerDoesNotTreatAMixedRootAsOneSeries()
    {
        var root = CreateDirectory("Mixed Root With Loose Episode");
        try
        {
            Touch(root, "Breaking Bad S01E01.mkv");
            Touch(root, "Movies/El Camino/El Camino.mkv");

            var result = scanner.Scan(
                root,
                LibraryKind.Automatic,
                [],
                null,
                CancellationToken.None);

            Assert.DoesNotContain(result.Items, item =>
                item.Kind == MediaKind.Series && item.SourcePath == root);
            Assert.Contains(result.Items, item =>
                item.Kind == MediaKind.Movie && item.DetectedTitle == "El Camino");
            var review = Assert.Single(result.Classifications!, item => item.RelativePath == "");
            Assert.True(review.NeedsReview);
            Assert.Equal("mixed_root_episode_files", review.Reason);
        }
        finally
        {
            DeleteFixture(root);
        }
    }

    [Fact]
    public void AutomaticScannerHonorsStoredClassificationDecisions()
    {
        var root = CreateDirectory("Decisions");
        try
        {
            Touch(root, "Home Videos/Part 1.mkv");
            Touch(root, "Home Videos/Part 2.mkv");
            Touch(root, "Ignored/One.mkv");
            Touch(root, "Ignored/Two.mkv");

            var result = scanner.Scan(
                root,
                LibraryKind.Automatic,
                [],
                null,
                CancellationToken.None,
                [
                    new ExistingClassificationDecision("Home Videos", ClassificationDecision.Movie),
                    new ExistingClassificationDecision("Ignored", ClassificationDecision.Ignore),
                ]);

            Assert.Equal(2, result.Items.Count(item => item.Kind == MediaKind.Movie));
            Assert.DoesNotContain(result.Items, item => item.SourcePath.Contains("Ignored"));
            Assert.DoesNotContain(result.Issues, issue => issue.Code == "classification_required");
        }
        finally
        {
            DeleteFixture(root);
        }
    }

    [Fact]
    public void AutomaticScannerForceImportsAnAmbiguousFolderAsSeasonOne()
    {
        var root = CreateDirectory("Force Import");
        try
        {
            Touch(root, "Video 10.mkv");
            Touch(root, "Video 2.mkv");
            Touch(root, "Video 1.mkv");

            var result = scanner.Scan(
                root,
                LibraryKind.Automatic,
                [],
                null,
                CancellationToken.None,
                [new ExistingClassificationDecision("", ClassificationDecision.TvShows)]);

            Assert.Single(result.Items, item => item.Kind == MediaKind.Series);
            var episodes = result.Items
                .Where(item => item.Kind == MediaKind.Episode)
                .OrderBy(item => item.EpisodeNumber)
                .ToList();
            Assert.Equal(3, episodes.Count);
            Assert.All(episodes, episode => Assert.Equal(1, episode.SeasonNumber));
            Assert.Equal(0, result.SkippedFiles);
            Assert.DoesNotContain(result.Issues, issue => issue.Code == "classification_required");
        }
        finally
        {
            DeleteFixture(root);
        }
    }

    [Fact]
    public void AutomaticStorageWithOneNestedShowUsesTheShowFolderAsItsIdentity()
    {
        var root = CreateDirectory("Single Show Storage");
        try
        {
            Touch(root, "Breaking Bad/Season 1/Breaking Bad S01E01 Pilot.mkv");

            var result = scanner.Scan(
                root,
                LibraryKind.Automatic,
                [],
                null,
                CancellationToken.None);

            var series = Assert.Single(result.Items, item => item.Kind == MediaKind.Series);
            Assert.Equal("Breaking Bad", series.DetectedTitle);
            Assert.EndsWith("Breaking Bad", series.SourcePath, StringComparison.Ordinal);
            Assert.Single(
                result.Classifications!,
                item => item.RelativePath == "Breaking Bad"
                    && item.SuggestedKind == LibraryKind.TvShows);
        }
        finally
        {
            DeleteFixture(root);
        }
    }

    [Fact]
    public void ExplicitMixedStorageAcceptanceRemainsMetadataOnly()
    {
        var root = Environment.GetEnvironmentVariable("AURELIA_REAL_STORAGE_TEST");
        if (string.IsNullOrWhiteSpace(root))
        {
            return;
        }

        var result = scanner.Scan(
            root,
            LibraryKind.Automatic,
            [],
            null,
            CancellationToken.None);
        var classifications = result.Classifications!;

        foreach (var folder in new[]
                 {
                     "Breaking Bad",
                     "Top Gear",
                     "Better Call Saul",
                     "Mr Robot",
                     "The Grand Tour",
                     "Clarksons Farm",
                 })
        {
            Assert.True(classifications.Any(item =>
                item.SuggestedKind == LibraryKind.TvShows
                && item.RelativePath.Trim().Equals(folder, StringComparison.OrdinalIgnoreCase)),
                $"Expected TV show folder was not recognized: {folder}");
        }

        Assert.Contains(classifications, item =>
            item.SuggestedKind == LibraryKind.Movies
            && item.DetectedTitle.Contains("El Camino", StringComparison.OrdinalIgnoreCase));
        Assert.Contains(classifications, item =>
            item.SuggestedKind == LibraryKind.Movies
            && item.DetectedTitle.Contains("Truman Show", StringComparison.OrdinalIgnoreCase));
        Assert.True(classifications.Count(item =>
            item.SuggestedKind == LibraryKind.Movies
            && (item.RelativePath.Contains("Minions & Despicable Me", StringComparison.OrdinalIgnoreCase)
                || item.RelativePath.Contains("Monsters Inc", StringComparison.OrdinalIgnoreCase))) >= 4);
        if (Directory.EnumerateDirectories(root).Any(path =>
                Path.GetFileName(path).Contains("Tiktok", StringComparison.OrdinalIgnoreCase)))
        {
            Assert.Contains(classifications, item =>
                item.RelativePath.Contains("Tiktok", StringComparison.OrdinalIgnoreCase)
                && item.SuggestedKind == null
                && item.NeedsReview);
        }
        Assert.DoesNotContain(result.Items, item =>
            Path.GetFileName(item.SourcePath).StartsWith("._", StringComparison.Ordinal));
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
