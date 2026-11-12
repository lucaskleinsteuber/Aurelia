using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>
/// Titles matched before FSK ratings were preferred get them once from their known match, without
/// searching again or touching anything else.
/// </summary>
public sealed class ContentRatingRefreshTests
{
    [Fact]
    public async Task MatchedTitlesGetTheirFskRatingOnceWithoutChangingTheirMatch()
    {
        var root = Path.Combine(TestPaths.CreateDataDirectory(), "Rating Library");
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
            var refresh = factory.Services.GetRequiredService<ContentRatingRefresh>();
            // Without TMDB nothing happens, and it is tried again later.
            Assert.False(await refresh.RunAsync(TimeSpan.Zero, default));

            factory.Services.GetRequiredService<MetadataProviderSettingsStore>().Save(new UpdateMetadataProviderRequest(true, "en", "synthetic-provider-token-with-no-network"));
            var movie = Guid.NewGuid();
            var show = Guid.NewGuid();
            var unmatched = Guid.NewGuid();
            await using (var scope = factory.Services.CreateAsyncScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Invented", Path = root, NormalizedPath = MediaPath.Normalize(root), MonitoringEnabled = false, Kind = LibraryKind.Automatic };
                database.LibraryRoots.Add(library);
                MediaItem Item(Guid id, MediaKind kind, string name, MediaMetadata? metadata) => new()
                {
                    Id = id,
                    LibraryRootId = library.Id,
                    Kind = kind,
                    DetectedTitle = name,
                    SourcePath = Path.Combine(root, name),
                    NormalizedSourcePath = MediaPath.Normalize(Path.Combine(root, name)),
                    Metadata = metadata,
                };
                database.MediaItems.Add(Item(movie, MediaKind.Movie, "Invented Heist", new MediaMetadata
                {
                    Provider = "tmdb",
                    ProviderMediaId = "11",
                    ProviderMediaType = "movie",
                    ProviderTitle = "Invented Heist",
                    ProviderContentRating = "R",
                    ManualContentRating = "FSK 18",
                    ReviewState = MetadataReviewState.Matched,
                }));
                database.MediaItems.Add(Item(show, MediaKind.Series, "Invented Harbor", new MediaMetadata
                {
                    Provider = "tmdb",
                    ProviderMediaId = "22",
                    ProviderMediaType = "tv",
                    ProviderTitle = "Invented Harbor",
                    ProviderContentRating = "TV-MA",
                    ReviewState = MetadataReviewState.Matched,
                }));
                database.MediaItems.Add(Item(unmatched, MediaKind.Movie, "Unknown Film", null));
                await database.SaveChangesAsync();
            }

            Assert.True(await refresh.RunAsync(TimeSpan.Zero, default));
            await using (var scope = factory.Services.CreateAsyncScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var ratings = await database.MediaMetadata.AsNoTracking()
                    .ToDictionaryAsync(metadata => metadata.MediaItemId, metadata => (metadata.ProviderContentRating, metadata.ManualContentRating, metadata.ProviderTitle, metadata.ProviderMediaId));
                Assert.Equal(("FSK 12", "FSK 18", "Invented Heist", "11"), ratings[movie]);
                Assert.Equal(("FSK 16", null, "Invented Harbor", "22"), ratings[show]);
                Assert.False(ratings.ContainsKey(unmatched));
            }
            Assert.Equal(0, provider.Searches);
            Assert.Equal(["movie/11", "tv/22"], provider.Details.Order());

            // Done once: a later start asks TMDB nothing.
            Assert.True(await refresh.RunAsync(TimeSpan.Zero, default));
            Assert.Equal(2, provider.Details.Count);
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(root)!, recursive: true);
        }
    }

    [Fact]
    public async Task MatchedTitlesGetTheirWholeCastOnceAndHandEditedCreditsStay()
    {
        var root = Path.Combine(TestPaths.CreateDataDirectory(), "Credit Library");
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
            var movie = Guid.NewGuid();
            var edited = Guid.NewGuid();
            await using (var scope = factory.Services.CreateAsyncScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Invented", Path = root, NormalizedPath = MediaPath.Normalize(root), MonitoringEnabled = false, Kind = LibraryKind.Automatic };
                database.LibraryRoots.Add(library);
                MediaItem Item(Guid id, string name, string providerId, string? overrides) => new()
                {
                    Id = id,
                    LibraryRootId = library.Id,
                    Kind = MediaKind.Movie,
                    DetectedTitle = name,
                    SourcePath = Path.Combine(root, name),
                    NormalizedSourcePath = MediaPath.Normalize(Path.Combine(root, name)),
                    Metadata = new MediaMetadata
                    {
                        Provider = "tmdb",
                        ProviderMediaId = providerId,
                        ProviderMediaType = "movie",
                        ProviderTitle = name,
                        ReviewState = MetadataReviewState.Matched,
                        ManualFieldsJson = overrides ?? "[]",
                        Credits = [new MediaCredit { Id = Guid.NewGuid(), MediaItemId = id, Name = "Old Lead", Department = "Acting", SortOrder = 0 }],
                    },
                };
                database.MediaItems.Add(Item(movie, "Invented Heist", "11", null));
                database.MediaItems.Add(Item(edited, "Invented Edit", "12", "[\"credits\"]"));
                await database.SaveChangesAsync();
            }

            var refresh = factory.Services.GetRequiredService<CreditRefresh>();
            Assert.True(await refresh.RunAsync(TimeSpan.Zero, default));
            await using (var scope = factory.Services.CreateAsyncScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var names = await database.MediaCredits.AsNoTracking().Where(credit => credit.MediaItemId == movie).OrderBy(credit => credit.SortOrder).Select(credit => credit.Name).ToListAsync();
                Assert.Equal(Enumerable.Range(0, 60).Select(i => $"Actor {i}").Append("Director"), names);
                Assert.Equal(["Old Lead"], await database.MediaCredits.AsNoTracking().Where(credit => credit.MediaItemId == edited).Select(credit => credit.Name).ToListAsync());
                Assert.Equal("Invented Heist", (await database.MediaMetadata.AsNoTracking().SingleAsync(metadata => metadata.MediaItemId == movie)).ProviderTitle);
                // Both join their shared universe, the hand-edited one too; only its credits stay.
                var universe = await database.MediaCollections.AsNoTracking().Include(collection => collection.Members)
                    .SingleAsync(collection => collection.Provider == MediaUniverses.Provider);
                Assert.Equal("Marvel Cinematic Universe", universe.Name);
                Assert.Equal(new[] { edited, movie }.Order(), universe.Members.Select(member => member.MediaItemId).Order());
            }
            var asked = provider.Details.Count;
            Assert.True(await refresh.RunAsync(TimeSpan.Zero, default));
            Assert.Equal(asked, provider.Details.Count);
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(root)!, recursive: true);
        }
    }

    [Fact]
    public async Task MatchedTitlesGetTheirKeywordsOnceAndTitlesWithKeywordsAreNotAsked()
    {
        var root = Path.Combine(TestPaths.CreateDataDirectory(), "Keyword Library");
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
            var refresh = factory.Services.GetRequiredService<KeywordRefresh>();
            Assert.False(await refresh.RunAsync(TimeSpan.Zero, default));
            factory.Services.GetRequiredService<MetadataProviderSettingsStore>().Save(new UpdateMetadataProviderRequest(true, "en", "synthetic-provider-token-with-no-network"));
            var movie = Guid.NewGuid();
            var known = Guid.NewGuid();
            await using (var scope = factory.Services.CreateAsyncScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Invented", Path = root, NormalizedPath = MediaPath.Normalize(root), MonitoringEnabled = false, Kind = LibraryKind.Automatic };
                database.LibraryRoots.Add(library);
                MediaItem Item(Guid id, string name, string providerId) => new()
                {
                    Id = id,
                    LibraryRootId = library.Id,
                    Kind = MediaKind.Movie,
                    DetectedTitle = name,
                    SourcePath = Path.Combine(root, name),
                    NormalizedSourcePath = MediaPath.Normalize(Path.Combine(root, name)),
                    Metadata = new MediaMetadata
                    {
                        Provider = "tmdb",
                        ProviderMediaId = providerId,
                        ProviderMediaType = "movie",
                        ProviderTitle = name,
                        ProviderContentRating = "FSK 6",
                        ReviewState = MetadataReviewState.Matched,
                    },
                };
                database.MediaItems.Add(Item(movie, "Invented Heist", "11"));
                database.MediaItems.Add(Item(known, "Invented Known", "12"));
                database.MediaKeywords.Add(new MediaKeywords { MediaItemId = known, KeywordsJson = "[\"lighthouse\"]", UpdatedAt = DateTimeOffset.UtcNow });
                await database.SaveChangesAsync();
            }

            Assert.True(await refresh.RunAsync(TimeSpan.Zero, default));
            await using (var scope = factory.Services.CreateAsyncScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var stored = await database.MediaKeywords.AsNoTracking().ToDictionaryAsync(row => row.MediaItemId, row => row.KeywordsJson);
                Assert.Equal(MetadataPresentation.SerializeList(["heist", "Marvel Cinematic Universe (MCU)"]), stored[movie]);
                Assert.Equal("[\"lighthouse\"]", stored[known]);
                var metadata = await database.MediaMetadata.AsNoTracking().SingleAsync(row => row.MediaItemId == movie);
                Assert.Equal(("Invented Heist", "FSK 6"), (metadata.ProviderTitle, metadata.ProviderContentRating));
            }
            Assert.Equal(["movie/11"], provider.Details);
            Assert.True(await refresh.RunAsync(TimeSpan.Zero, default));
            Assert.Single(provider.Details);
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(root)!, recursive: true);
        }
    }

    private sealed class Provider : ITmdbClient
    {
        public int Searches;
        public System.Collections.Concurrent.ConcurrentBag<string> Details { get; } = [];
        public Task ValidateAsync(string token, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task<IReadOnlyList<MetadataCandidateSummary>> SearchAsync(string token, string language, MediaKind kind, string title, int? year, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref Searches);
            return Task.FromResult<IReadOnlyList<MetadataCandidateSummary>>([]);
        }
        public Task<TmdbMetadata> GetAsync(string token, string language, string mediaType, string providerId, CancellationToken cancellationToken)
        {
            Details.Add($"{mediaType}/{providerId}");
            var rating = mediaType == "movie" ? "FSK 12" : "FSK 16";
            IReadOnlyList<TmdbCredit> credits = [.. Enumerable.Range(0, 60).Select(i => new TmdbCredit($"{i + 1}", $"Actor {i}", "Acting", null, $"Role {i}", i, null)),
                new TmdbCredit("900", "Director", "Directing", "Director", null, 100_000, null)];
            return Task.FromResult(new TmdbMetadata(providerId, mediaType, "Changed Title", null, null, null, null, null, rating, [], [], [], null, null, credits, null,
                ["heist", "Marvel Cinematic Universe (MCU)"]));
        }
        public Task<IReadOnlyList<TmdbEpisodeMetadata>> GetEpisodesAsync(string token, string language, string seriesProviderId, int seasonNumber, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<TmdbEpisodeMetadata>>([]);
        public Task<byte[]> DownloadImageAsync(string token, string providerPath, string size, CancellationToken cancellationToken) =>
            Task.FromResult<byte[]>([]);
    }
}
