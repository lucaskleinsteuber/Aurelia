using System.Net;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>
/// Episode details of a matched series: a season TMDB does not know is skipped instead of failing
/// the series, and looking for missing info fills in episodes of a matched series from its known
/// match without searching again.
/// </summary>
public sealed class MetadataEpisodeTests
{
    [Fact]
    public async Task ASeasonTmdbDoesNotKnowHasNoEpisodesInsteadOfAnError()
    {
        using var handler = new NotFoundHandler();
        using var client = new HttpClient(handler);
        var episodes = await new TmdbClient(client).GetEpisodesAsync("synthetic-secret", "en", "45", 7, default);
        Assert.Empty(episodes);
        Assert.Equal(1, handler.Requests);
    }

    [Fact]
    public async Task FindingMissingInfoFillsEpisodesOfAMatchedSeriesWithoutSearchingAgain()
    {
        var root = Path.Combine(TestPaths.CreateDataDirectory(), "Episode Library");
        Directory.CreateDirectory(root);
        var provider = new Provider();
        try
        {
            using var factory = new AureliaServerFactory(configureServices: services =>
            {
                services.RemoveAll<ITmdbClient>();
                services.AddSingleton<ITmdbClient>(provider);
            });
            using var client = factory.CreateClient();
            await ApiTestClient.SetupOwnerAsync(client);
            factory.Services.GetRequiredService<MetadataProviderSettingsStore>().Save(new UpdateMetadataProviderRequest(true, "en", "synthetic-provider-token-with-no-network"));
            var seriesId = Guid.NewGuid();
            var missing = new[] { (Season: 1, Episode: 1), (Season: 3, Episode: 1), (Season: 5, Episode: 2) };
            await using (var scope = factory.Services.CreateAsyncScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Invented", Path = root, NormalizedPath = MediaPath.Normalize(root), MonitoringEnabled = false, Kind = LibraryKind.TvShows };
                database.LibraryRoots.Add(library);
                database.MediaItems.Add(new MediaItem
                {
                    Id = seriesId,
                    LibraryRootId = library.Id,
                    Kind = MediaKind.Series,
                    DetectedTitle = "Invented Motor Show",
                    SourcePath = Path.Combine(root, "Show"),
                    NormalizedSourcePath = MediaPath.Normalize(Path.Combine(root, "Show")),
                    Metadata = new MediaMetadata { Provider = "tmdb", ProviderMediaId = "45", ProviderMediaType = "tv", ProviderTitle = "Invented Motor Show", ReviewState = MetadataReviewState.Matched },
                });
                foreach (var (season, episode) in missing.Append((Season: 2, Episode: 1)))
                {
                    var path = Path.Combine(root, "Show", $"S{season:00}E{episode:00}.mkv");
                    database.MediaItems.Add(new MediaItem
                    {
                        Id = Guid.NewGuid(),
                        LibraryRootId = library.Id,
                        ParentId = seriesId,
                        Kind = MediaKind.Episode,
                        DetectedTitle = $"Episode {episode}",
                        SeasonNumber = season,
                        EpisodeNumber = episode,
                        SourcePath = path,
                        NormalizedSourcePath = MediaPath.Normalize(path),
                        Metadata = season == 2 ? new MediaMetadata { Provider = "tmdb", ProviderMediaId = "e2", ProviderTitle = "Known", ReviewState = MetadataReviewState.Matched } : null,
                    });
                }
                await database.SaveChangesAsync();
            }

            await using (var scope = factory.Services.CreateAsyncScope())
            {
                var job = await scope.ServiceProvider.GetRequiredService<MetadataService>().StartAsync(new StartMetadataJobRequest(MetadataJobMode.Incremental), default);
                Assert.Equal(1, job.ItemsTotal);
                var deadline = DateTime.UtcNow.AddSeconds(15);
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                while ((await database.MetadataJobs.IgnoreQueryFilters().AsNoTracking().SingleAsync(value => value.Id == job.Id)).State is not (MetadataJobState.Completed or MetadataJobState.Failed))
                {
                    Assert.True(DateTime.UtcNow < deadline, "The metadata job did not finish.");
                    await Task.Delay(20);
                }
                Assert.Equal(MetadataJobState.Completed, (await database.MetadataJobs.IgnoreQueryFilters().AsNoTracking().SingleAsync(value => value.Id == job.Id)).State);
                var titles = await database.MediaItems.AsNoTracking().Where(item => item.ParentId == seriesId)
                    .OrderBy(item => item.SeasonNumber).Select(item => new { item.SeasonNumber, Title = item.Metadata == null ? null : item.Metadata.ProviderTitle }).ToListAsync();
                // Season 3 is unknown to TMDB; seasons 1 and 5 still get their details.
                Assert.Equal(["Season 1 Episode 1", "Known", null, "Season 5 Episode 2"], titles.Select(value => value.Title));
            }
            Assert.Equal(0, provider.Searches);
            Assert.Equal([1, 2, 3, 5], provider.Seasons.Order());
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(root)!, recursive: true);
        }
    }

    [Fact]
    public async Task SameNamedShowsAndLongTitlesAreMatchedWithoutReview()
    {
        var root = Path.Combine(TestPaths.CreateDataDirectory(), "Signal Library");
        Directory.CreateDirectory(root);
        var provider = new SignalProvider();
        try
        {
            using var factory = new AureliaServerFactory(configureServices: services =>
            {
                services.RemoveAll<ITmdbClient>();
                services.AddSingleton<ITmdbClient>(provider);
            });
            using var client = factory.CreateClient();
            await ApiTestClient.SetupOwnerAsync(client);
            factory.Services.GetRequiredService<MetadataProviderSettingsStore>().Save(new UpdateMetadataProviderRequest(true, "en", "synthetic-provider-token-with-no-network"));
            var seriesId = Guid.NewGuid();
            var movieId = Guid.NewGuid();
            await using (var scope = factory.Services.CreateAsyncScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Invented", Path = root, NormalizedPath = MediaPath.Normalize(root), MonitoringEnabled = false, Kind = LibraryKind.Automatic };
                database.LibraryRoots.Add(library);
                MediaItem Item(Guid id, MediaKind kind, string title, string relative, Guid? parent = null, int? season = null, int? episode = null) => new()
                {
                    Id = id,
                    LibraryRootId = library.Id,
                    ParentId = parent,
                    Kind = kind,
                    DetectedTitle = title,
                    SeasonNumber = season,
                    EpisodeNumber = episode,
                    SourcePath = Path.Combine(root, relative),
                    NormalizedSourcePath = MediaPath.Normalize(Path.Combine(root, relative)),
                };
                database.MediaItems.Add(Item(seriesId, MediaKind.Series, "Invented Road Show", "Road Show"));
                foreach (var season in new[] { 12, 20 })
                {
                    database.MediaItems.Add(Item(Guid.NewGuid(), MediaKind.Episode, "Episode 1", $"Road Show/S{season}E01.mkv", seriesId, season, 1));
                }
                database.MediaItems.Add(Item(movieId, MediaKind.Movie, "Invented Hunt - A Very Long Subtitle", "Invented Hunt - A Very Long Subtitle.mkv"));
                await database.SaveChangesAsync();
            }

            await using (var scope = factory.Services.CreateAsyncScope())
            {
                var job = await scope.ServiceProvider.GetRequiredService<MetadataService>().StartAsync(new StartMetadataJobRequest(MetadataJobMode.Incremental), default);
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var deadline = DateTime.UtcNow.AddSeconds(15);
                while ((await database.MetadataJobs.IgnoreQueryFilters().AsNoTracking().SingleAsync(value => value.Id == job.Id)).State is not (MetadataJobState.Completed or MetadataJobState.Failed))
                {
                    Assert.True(DateTime.UtcNow < deadline, "The metadata job did not finish.");
                    await Task.Delay(20);
                }
                var matches = await database.MediaMetadata.AsNoTracking().Where(value => value.MediaItemId == seriesId || value.MediaItemId == movieId)
                    .ToDictionaryAsync(value => value.MediaItemId, value => value.ProviderMediaId);
                // Only the long-running show has twenty seasons; the movie is found by its main title.
                Assert.Equal("11", matches[seriesId]);
                Assert.Equal("30", matches[movieId]);
                Assert.Empty(await database.MetadataReviews.AsNoTracking().Where(review => review.State == MetadataReviewState.NeedsReview).ToListAsync());
            }
            Assert.Contains("Invented Hunt", provider.Queries);
            Assert.Equal(3, provider.ShapeLookups);
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(root)!, recursive: true);
        }
    }

    private sealed class SignalProvider : ITmdbClient
    {
        public System.Collections.Concurrent.ConcurrentBag<string> Queries { get; } = [];
        public int ShapeLookups;
        public Task ValidateAsync(string token, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task<IReadOnlyList<MetadataCandidateSummary>> SearchAsync(string token, string language, MediaKind kind, string title, int? year, CancellationToken cancellationToken)
        {
            Queries.Add(title);
            MetadataCandidateSummary Candidate(string id, string type, string name, int candidateYear, int votes) =>
                new("tmdb", id, type, name, null, candidateYear, null, null, MetadataMatcher.Score(title, year, name, null, candidateYear), votes);
            IReadOnlyList<MetadataCandidateSummary> results = title switch
            {
                "Invented Road Show" =>
                [
                    Candidate("10", "tv", "Invented Road Show", 1977, 40),
                    Candidate("11", "tv", "Invented Road Show", 2002, 90),
                    Candidate("12", "tv", "Invented Road Show", 2010, 60),
                ],
                "Invented Hunt" => [Candidate("30", "movie", "Invented Hunt", 2011, 5)],
                _ => [],
            };
            return Task.FromResult(results);
        }
        public Task<TmdbShowShape> GetShowShapeAsync(string token, string providerId, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref ShapeLookups);
            return Task.FromResult(providerId switch { "10" => new TmdbShowShape(6, 80), "11" => new TmdbShowShape(33, 250), _ => new TmdbShowShape(8, 90) });
        }
        public Task<TmdbMetadata> GetAsync(string token, string language, string mediaType, string providerId, CancellationToken cancellationToken) =>
            Task.FromResult(new TmdbMetadata(providerId, mediaType, mediaType == "tv" ? "Invented Road Show" : "Invented Hunt", null, null, null, null, null, null, [], [], [], null, null, [], null));
        public Task<IReadOnlyList<TmdbEpisodeMetadata>> GetEpisodesAsync(string token, string language, string seriesProviderId, int seasonNumber, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<TmdbEpisodeMetadata>>([]);
        public Task<byte[]> DownloadImageAsync(string token, string providerPath, string size, CancellationToken cancellationToken) =>
            Task.FromResult<byte[]>([0xff, 0xd8, 1, 2, 3, 4, 0xff, 0xd9, 0, 0, 0, 0, 0xff, 0xd9]);
    }

    private sealed class NotFoundHandler : HttpMessageHandler
    {
        public int Requests { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests++;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.NotFound));
        }
    }

    private sealed class Provider : ITmdbClient
    {
        public int Searches;
        public System.Collections.Concurrent.ConcurrentBag<int> Seasons { get; } = [];
        public Task ValidateAsync(string token, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task<IReadOnlyList<MetadataCandidateSummary>> SearchAsync(string token, string language, MediaKind kind, string title, int? year, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref Searches);
            return Task.FromResult<IReadOnlyList<MetadataCandidateSummary>>([]);
        }
        public Task<TmdbMetadata> GetAsync(string token, string language, string mediaType, string providerId, CancellationToken cancellationToken) =>
            Task.FromResult(new TmdbMetadata(providerId, mediaType, "Invented Motor Show", null, null, null, null, null, null, [], [], [], null, null, [], null));
        public Task<IReadOnlyList<TmdbEpisodeMetadata>> GetEpisodesAsync(string token, string language, string seriesProviderId, int seasonNumber, CancellationToken cancellationToken)
        {
            Seasons.Add(seasonNumber);
            if (seasonNumber == 3) return Task.FromResult<IReadOnlyList<TmdbEpisodeMetadata>>([]);
            return Task.FromResult<IReadOnlyList<TmdbEpisodeMetadata>>(Enumerable.Range(1, 2).Select(episode =>
                new TmdbEpisodeMetadata($"s{seasonNumber}e{episode}", seasonNumber, episode, seasonNumber == 2 ? "Known" : $"Season {seasonNumber} Episode {episode}", null, null, null, null, null)).ToList());
        }
        public Task<byte[]> DownloadImageAsync(string token, string providerPath, string size, CancellationToken cancellationToken) =>
            Task.FromResult<byte[]>([0xff, 0xd8, 1, 2, 3, 4, 0xff, 0xd9, 0, 0, 0, 0, 0xff, 0xd9]);
    }
}
