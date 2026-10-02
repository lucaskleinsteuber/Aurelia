using System.Diagnostics;
using Aurelia.Contracts;
using Aurelia.Server.Services;
using Xunit;
using Xunit.Abstractions;

namespace Aurelia.Server.Tests;

public sealed class ImportStructureAcceptanceTests(ITestOutputHelper output)
{
    private readonly MediaLibraryScanner scanner = new();

    [Fact]
    public void CompleteNamesOnlyFixtureProducesEverySourceOnceWithoutPhantomTitles()
    {
        using var fixture = CreateFixture();
        var result = Scan(fixture.Root);

        AssertCompleteDiscovery(fixture.Root, result);
        Assert.Empty(result.Issues);
        Assert.Empty(result.ImportReviews ?? []);
        Assert.DoesNotContain(result.Classifications ?? [], item => item.NeedsReview);
    }

    [Theory]
    [InlineData("Breaking Bad", 62, 245, 0)]
    [InlineData("Better Call Saul", 63, 88, 1)]
    [InlineData("Chernobyl", 5, 12, 0)]
    [InlineData("The Grand Tour", 46, 0, 0)]
    [InlineData("Top Gear ", 173, 0, 0)]
    public void SeriesRetainAllEpisodesAndNestedSupplements(
        string directory,
        int episodeCount,
        int extraCount,
        int trailerCount)
    {
        using var fixture = CreateFixture(directory);
        var result = Scan(fixture.Root);
        var series = Assert.Single(result.Items, item => item.Kind == MediaKind.Series);

        Assert.Equal(Path.Combine(fixture.Root, directory), series.SourcePath);
        Assert.Equal(directory.Trim(), series.DetectedTitle);
        Assert.Equal(episodeCount, result.Items.Count(item => item.Kind == MediaKind.Episode));
        Assert.Equal(extraCount, result.Items.Count(item => item.Kind == MediaKind.Extra));
        Assert.Equal(trailerCount, result.Items.Count(item => item.Kind == MediaKind.Trailer));
        Assert.DoesNotContain(result.Items, item => item.Kind == MediaKind.Movie);
        Assert.All(result.Items.Where(item => item.Kind != MediaKind.Series), item =>
            Assert.Equal(series.SourcePath, item.ParentSourcePath));
        Assert.Empty(result.Issues);
        Assert.Empty(result.ImportReviews ?? []);

        foreach (var extra in result.Items.Where(item => item.Kind == MediaKind.Extra))
        {
            if (directory == "Chernobyl")
            {
                Assert.Null(extra.SeasonNumber);
            }
            else
            {
                Assert.InRange(extra.SeasonNumber.GetValueOrDefault(), 1, 6);
            }
        }
    }

    [Theory]
    [InlineData("El Camino - A Breaking Bad Movie", 9, 3)]
    [InlineData("The Truman Show", 6, 1)]
    public void MoviesRetainExtrasAndTrailersWithoutProducingAdditionalTitles(
        string directory,
        int extraCount,
        int trailerCount)
    {
        using var fixture = CreateFixture(directory);
        var result = Scan(fixture.Root);
        var movie = Assert.Single(result.Items, item => item.Kind == MediaKind.Movie);

        Assert.Equal(directory, movie.DetectedTitle);
        Assert.Equal(extraCount, result.Items.Count(item => item.Kind == MediaKind.Extra));
        Assert.Equal(trailerCount, result.Items.Count(item => item.Kind == MediaKind.Trailer));
        Assert.DoesNotContain(result.Items, item => item.Kind is MediaKind.Series or MediaKind.Episode);
        Assert.All(result.Items.Where(item => item.Kind != MediaKind.Movie), item =>
            Assert.Equal(movie.SourcePath, item.ParentSourcePath));
        Assert.Empty(result.Issues);
        Assert.Empty(result.ImportReviews ?? []);
    }

    [Fact]
    public void NumberedFeaturetteCategoriesInheritSeasonFiveAndCannotCreateEpisodes()
    {
        using var fixture = CreateFixture("Breaking Bad");
        var result = Scan(fixture.Root);
        var featurettes = result.Items.Where(item =>
            item.SourcePath.Contains("/Featurettes 5.", StringComparison.Ordinal)).ToArray();

        Assert.NotEmpty(featurettes);
        Assert.All(featurettes, item =>
        {
            Assert.Equal(MediaKind.Extra, item.Kind);
            Assert.Equal(5, item.SeasonNumber);
            Assert.DoesNotContain("Season 5", item.Category ?? string.Empty, StringComparison.Ordinal);
        });
        Assert.All(result.Items.Where(item =>
            item.SourcePath.Contains("/Mini Video Podcasts/", StringComparison.Ordinal)), item =>
        {
            Assert.Equal(MediaKind.Extra, item.Kind);
            Assert.Equal(3, item.SeasonNumber);
        });
    }

    [Fact]
    public void EpisodeWordsInsideFeaturettesRemainSeriesWideExtras()
    {
        using var fixture = CreateFixture("Chernobyl");
        var result = Scan(fixture.Root);
        var elements = result.Items.Where(item =>
            item.SourcePath.Contains("/Elements of Chernobyl/", StringComparison.Ordinal)).ToArray();

        Assert.Equal(5, elements.Length);
        Assert.All(elements, item =>
        {
            Assert.Equal(MediaKind.Extra, item.Kind);
            Assert.Null(item.SeasonNumber);
            Assert.Null(item.EpisodeNumber);
        });
    }

    [Theory]
    [InlineData("Minions & Despicable Me", 7)]
    [InlineData("Monsters Inc. & Monsters University", 2)]
    public void CollectionContainersProduceIndependentMoviesNotSeries(string directory, int movieCount)
    {
        using var fixture = CreateFixture(directory);
        var result = Scan(fixture.Root);

        Assert.Equal(movieCount, result.Items.Count);
        Assert.All(result.Items, item =>
        {
            Assert.Equal(MediaKind.Movie, item.Kind);
            Assert.Null(item.ParentSourcePath);
        });
        Assert.Empty(result.Issues);
    }

    [Theory]
    [InlineData("Extras")]
    [InlineData("Featurettes")]
    [InlineData("Featurettes 5.1")]
    [InlineData("Bonus")]
    [InlineData("Special Features")]
    [InlineData("Behind the Scenes")]
    [InlineData("Making Of")]
    [InlineData("Deleted Scenes")]
    [InlineData("Interviews")]
    [InlineData("Bloopers")]
    [InlineData("Outtakes")]
    [InlineData("Zusatzmaterial")]
    public void AliasFoldersRetainDeepParentAndSeasonContext(string alias)
    {
        using var fixture = new NameOnlyFixture();
        fixture.Touch("Example Series/Season 5/Example Series - S05E01.mkv");
        fixture.Touch($"Example Series/{alias}/Season 5/Nested Category/Episode 2 Interview.mkv");

        var result = Scan(fixture.Root);
        var series = Assert.Single(result.Items, item => item.Kind == MediaKind.Series);
        var extra = Assert.Single(result.Items, item => item.Kind == MediaKind.Extra);

        Assert.Equal(series.SourcePath, extra.ParentSourcePath);
        Assert.Equal(5, extra.SeasonNumber);
        Assert.Null(extra.EpisodeNumber);
        Assert.Single(result.Items, item => item.Kind == MediaKind.Episode);
        Assert.DoesNotContain("Season 5", extra.Category, StringComparison.Ordinal);
    }

    [Fact]
    public void SpecialsAndTrailerWordsInSeriesTitlesDoNotBecomeBonusContent()
    {
        using var fixture = new NameOnlyFixture();
        fixture.Touch("Trailer Park Boys/Season 1/Trailer Park Boys - S01E01.mkv");
        fixture.Touch("Trailer Park Boys/Season 0/Trailer Park Boys - S00E01 - Special.mkv");

        var result = Scan(fixture.Root);
        var series = Assert.Single(result.Items, item => item.Kind == MediaKind.Series);

        Assert.Equal("Trailer Park Boys", series.DetectedTitle);
        Assert.Equal(2, result.Items.Count(item => item.Kind == MediaKind.Episode));
        Assert.Single(result.Items, item => item.Kind == MediaKind.Episode && item.SeasonNumber == 0);
        Assert.DoesNotContain(result.Items, item => item.Kind is MediaKind.Extra or MediaKind.Trailer);
    }

    [Fact]
    public void OrphanBonusSourcesNeedReviewInsteadOfBecomingIndependentTitles()
    {
        using var fixture = new NameOnlyFixture();
        fixture.Touch("Featurettes/Featurettes 5.1/Interview.mkv");
        fixture.Touch("Trailer/Official Trailer.mkv");

        var result = Scan(fixture.Root);

        Assert.Equal(2, result.FilesDiscovered);
        Assert.DoesNotContain(result.Items, item => item.Kind is MediaKind.Movie or MediaKind.Series);
        Assert.DoesNotContain(result.Items, item => item.IsFile);
        Assert.True((result.ImportReviews?.Count ?? 0) > 0
            || (result.Classifications?.Any(item => item.NeedsReview) ?? false));
    }

    [Fact]
    public void RepeatedScanningReturnsTheSameStructureWithoutWritingSources()
    {
        using var fixture = CreateFixture();
        var before = SnapshotMetadata(fixture.Root);
        var first = Scan(fixture.Root);
        var second = Scan(fixture.Root);

        AssertCompleteDiscovery(fixture.Root, first);
        Assert.Equal(
            first.Items.Select(ItemSignature).Order(StringComparer.Ordinal),
            second.Items.Select(ItemSignature).Order(StringComparer.Ordinal));
        Assert.Equal(before, SnapshotMetadata(fixture.Root));
    }

    [Fact]
    public void LargerSyntheticCatalogReportsAReproducibleDiscoveryMeasurement()
    {
        using var fixture = new NameOnlyFixture();
        for (var index = 0; index < 10_000; index++)
        {
            fixture.Touch($"Series {index:D5}/Season 1/Series {index:D5} - S01E01.mkv");
        }

        var timer = Stopwatch.StartNew();
        var result = Scan(fixture.Root);
        timer.Stop();

        Assert.Equal(10_000, result.FilesDiscovered);
        Assert.Equal(10_000, result.Items.Count(item => item.Kind == MediaKind.Series));
        Assert.Equal(10_000, result.Items.Count(item => item.Kind == MediaKind.Episode));
        Assert.Empty(result.ImportReviews ?? []);
        output.WriteLine($"10,000 names-only sources: {timer.ElapsedMilliseconds} ms; no media reads.");
    }

    [Fact]
    public void ExplicitlyEnabledPersonalStructureProbeReadsOnlyFilesystemMetadata()
    {
        // This opt-in never starts a server, scans a catalog, or opens a source file.
        var root = Environment.GetEnvironmentVariable("AURELIA_IMPORT_ACCEPTANCE_ROOT");
        if (string.IsNullOrWhiteSpace(root))
        {
            output.WriteLine("Personal-structure probe not requested; portable synthetic tests cover the names.");
            return;
        }

        Assert.True(Directory.Exists(root), "The explicitly authorized import-probe folder is unavailable.");
        var before = SnapshotMetadata(root);
        MediaScanDiscovery? result = null;
        for (var repeat = 0; repeat < 3; repeat++)
        {
            var timer = Stopwatch.StartNew();
            result = Scan(root);
            timer.Stop();
            AssertCompleteDiscovery(root, result);
            Assert.Empty(result.Issues);
            Assert.Empty(result.ImportReviews ?? []);
            output.WriteLine($"Metadata-only probe {repeat + 1}: {timer.ElapsedMilliseconds} ms; {result.FilesDiscovered} sources, {result.Items.Count} items.");
        }

        Assert.Equal(before, SnapshotMetadata(root));
        Assert.NotNull(result);
        foreach (var title in result.Items.GroupBy(item =>
                     Path.GetRelativePath(root, item.SourcePath).Split(Path.DirectorySeparatorChar)[0]))
        {
            var counts = string.Join(", ", title.GroupBy(item => item.Kind).Select(group => $"{group.Key}: {group.Count()}"));
            output.WriteLine($"{title.Key.Trim()}: {counts}");
        }
    }

    private MediaScanDiscovery Scan(string root) =>
        scanner.Scan(root, LibraryKind.Automatic, [], null, CancellationToken.None);

    private static void AssertCompleteDiscovery(string root, MediaScanDiscovery result)
    {
        Assert.Equal(843, result.FilesDiscovered);
        Assert.Equal(14, result.Items.Count(item => item.Kind == MediaKind.Movie));
        Assert.Equal(11, result.Items.Count(item => item.Kind == MediaKind.Series));
        Assert.Equal(464, result.Items.Count(item => item.Kind == MediaKind.Episode));
        Assert.Equal(360, result.Items.Count(item => item.Kind == MediaKind.Extra));
        Assert.Equal(5, result.Items.Count(item => item.Kind == MediaKind.Trailer));
        var fileItems = result.Items.Where(item => item.Kind != MediaKind.Series).ToArray();
        Assert.Equal(843, fileItems.Length);
        Assert.Equal(843, fileItems.Select(item => item.SourcePath).Distinct(StringComparer.Ordinal).Count());
        Assert.Equal(
            ReadPaths().Order(StringComparer.Ordinal),
            fileItems.Select(item => Path.GetRelativePath(root, item.SourcePath).Replace('\\', '/'))
                .Order(StringComparer.Ordinal));
    }

    private static NameOnlyFixture CreateFixture(string? directory = null)
    {
        var fixture = new NameOnlyFixture();
        foreach (var path in ReadPaths().Where(path => directory is null
            || path.StartsWith(directory + "/", StringComparison.Ordinal)))
        {
            fixture.Touch(path);
        }

        return fixture;
    }

    private static string[] ReadPaths()
    {
        using var stream = typeof(ImportStructureAcceptanceTests).Assembly.GetManifestResourceStream(
            "Aurelia.Server.Tests.Fixtures.ImportStructurePaths.txt");
        Assert.NotNull(stream);
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd().Split('\n', StringSplitOptions.RemoveEmptyEntries);
    }

    private static string[] SnapshotMetadata(string root) => Directory.EnumerateFiles(
            root, "*", new EnumerationOptions
            {
                RecurseSubdirectories = true,
                AttributesToSkip = FileAttributes.ReparsePoint | FileAttributes.Hidden | FileAttributes.System,
            })
        .Where(path => !Path.GetFileName(path).StartsWith("._", StringComparison.Ordinal)
            && !Path.GetFileName(path).StartsWith('.'))
        .Select(path => new FileInfo(path))
        .Select(file => $"{file.FullName}|{file.Length}|{file.LastWriteTimeUtc.Ticks}")
        .Order(StringComparer.Ordinal)
        .ToArray();

    private static string ItemSignature(DiscoveredMediaItem item) =>
        $"{item.Kind}|{item.SourcePath}|{item.ParentSourcePath}|{item.DetectedTitle}|{item.SeasonNumber}|{item.EpisodeNumber}|{item.Category}";

    private sealed class NameOnlyFixture : IDisposable
    {
        public string Root { get; } = TestPaths.CreateDataDirectory();

        public NameOnlyFixture() => Directory.CreateDirectory(Root);

        public void Touch(string relativePath)
        {
            var path = Path.Combine(Root, relativePath);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllBytes(path, []);
        }

        public void Dispose() => Directory.Delete(Root, recursive: true);
    }
}
