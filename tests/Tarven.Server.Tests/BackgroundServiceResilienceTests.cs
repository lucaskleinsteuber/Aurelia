using System.ComponentModel;
using System.Text.Json;
using Tarven.Contracts;
using Tarven.Server.Data;
using Tarven.Server.Services;
using Tarven.Server.Services.Speech;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;
using Xunit;

namespace Tarven.Server.Tests;

public sealed class BackgroundServiceResilienceTests
{
    [Fact]
    public void HostIgnoresUnhandledBackgroundServiceExceptionsInsteadOfStoppingServer()
    {
        using var factory = new TarvenServerFactory();
        var options = factory.Services.GetRequiredService<IOptions<HostOptions>>().Value;
        Assert.Equal(BackgroundServiceExceptionBehavior.Ignore, options.BackgroundServiceExceptionBehavior);
    }

    [Fact]
    public async Task CreditRefreshCatchesUnexpectedJsonExceptionWithoutCrashing()
    {
        var rootDir = Path.Combine(TestPaths.CreateDataDirectory(), "CreditCrash");
        Directory.CreateDirectory(rootDir);
        try
        {
            using var factory = new TarvenServerFactory(configureServices: services =>
            {
                services.RemoveAll<ITmdbClient>();
                services.AddSingleton<ITmdbClient>(new ThrowingTmdbClient());
            });
            using var client = factory.CreateClient();
            _ = await ApiTestClient.SetupOwnerAsync(client);

            using (var scope = factory.Services.CreateScope())
            {
                scope.ServiceProvider.GetRequiredService<MetadataProviderSettingsStore>()
                    .Save(new UpdateMetadataProviderRequest(true, "en", "synthetic-provider-token-with-no-network"));
                var db = scope.ServiceProvider.GetRequiredService<TarvenDbContext>();
                var now = DateTimeOffset.UtcNow;
                var library = new LibraryRoot
                {
                    Id = Guid.NewGuid(),
                    Name = "Movies",
                    Path = rootDir,
                    NormalizedPath = MediaPath.Normalize(rootDir),
                    Kind = LibraryKind.Movies,
                    Availability = LibraryAvailability.Available,
                    CreatedAt = now,
                };
                var mediaId = Guid.NewGuid();
                var path = Path.Combine(rootDir, "Film.mkv");
                await File.WriteAllBytesAsync(path, [1, 2, 3]);
                db.LibraryRoots.Add(library);
                db.MediaItems.Add(new MediaItem
                {
                    Id = mediaId,
                    LibraryRoot = library,
                    LibraryRootId = library.Id,
                    Kind = MediaKind.Movie,
                    SourcePath = path,
                    NormalizedSourcePath = MediaPath.Normalize(path),
                    DetectedTitle = "Film",
                    Category = string.Empty,
                    Extension = ".mkv",
                    FileSize = 3,
                    Availability = MediaAvailability.Available,
                    CreatedAt = now,
                    UpdatedAt = now,
                    Metadata = new MediaMetadata
                    {
                        MediaItemId = mediaId,
                        Provider = "tmdb",
                        ProviderMediaId = "42",
                        ProviderMediaType = "movie",
                        ProviderTitle = "Film",
                        ReviewState = MetadataReviewState.Matched,
                    },
                });
                await db.SaveChangesAsync();
            }

            var refresh = factory.Services.GetRequiredService<CreditRefresh>();
            Assert.False(await refresh.RunAsync(TimeSpan.Zero, CancellationToken.None));
            var ratings = factory.Services.GetRequiredService<ContentRatingRefresh>();
            Assert.False(await ratings.RunAsync(TimeSpan.Zero, CancellationToken.None));
            var keywords = factory.Services.GetRequiredService<KeywordRefresh>();
            Assert.False(await keywords.RunAsync(TimeSpan.Zero, CancellationToken.None));
        }
        finally { Directory.Delete(Path.GetDirectoryName(rootDir)!, recursive: true); }
    }

    [Fact]
    public async Task BackgroundConversionSlotsDoNotCountAsPlayback()
    {
        using var factory = new TarvenServerFactory();
        var live = factory.Services.GetRequiredService<LiveConversionService>();
        Assert.Equal(0, live.Running);
        Assert.Equal(0, live.RunningForPlayback);

        using (var bgSlot = await live.EnterAsync(encodesVideo: false, CancellationToken.None, background: true))
        {
            Assert.NotNull(bgSlot);
            Assert.Equal(1, live.Running);
            Assert.Equal(0, live.RunningForPlayback);

            using var playSlot = await live.EnterAsync(encodesVideo: false, CancellationToken.None, background: false);
            Assert.NotNull(playSlot);
            Assert.Equal(2, live.Running);
            Assert.Equal(1, live.RunningForPlayback);
        }

        Assert.Equal(0, live.Running);
        Assert.Equal(0, live.RunningForPlayback);
    }

    private sealed class ThrowingTmdbClient : ITmdbClient
    {
        public Task ValidateAsync(string token, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task<IReadOnlyList<MetadataCandidateSummary>> SearchAsync(string token, string language, MediaKind kind, string title, int? year, CancellationToken cancellationToken) =>
            throw new JsonException("Unexpected TMDB payload");

        public Task<TmdbMetadata> GetAsync(string token, string language, string mediaType, string providerId, CancellationToken cancellationToken) =>
            throw new JsonException("Unexpected TMDB payload");

        public Task<IReadOnlyList<TmdbEpisodeMetadata>> GetEpisodesAsync(string token, string language, string seriesProviderId, int seasonNumber, CancellationToken cancellationToken) =>
            throw new JsonException("Unexpected TMDB payload");

        public Task<byte[]> DownloadImageAsync(string token, string providerPath, string size, CancellationToken cancellationToken) =>
            throw new JsonException("Unexpected TMDB payload");
    }
}
