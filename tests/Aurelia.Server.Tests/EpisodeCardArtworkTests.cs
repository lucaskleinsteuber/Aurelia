using System.Net;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class EpisodeCardArtworkTests
{
    [Theory]
    [InlineData("none")]
    [InlineData("series")]
    [InlineData("manual")]
    [InlineData("episode")]
    [InlineData("removed")]
    public async Task SearchSummaryAndHistoryUseTheSelectedPosterWithoutChangingEpisodeIdentity(string mode)
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client, username: "owner");
        var seriesId = Guid.NewGuid();
        var episodeId = Guid.NewGuid();
        var seriesPoster = Guid.NewGuid();
        var ownPoster = Guid.NewGuid();
        var manualPoster = Guid.NewGuid();
        Guid? expected = mode switch { "episode" => ownPoster, "manual" => manualPoster, "series" => seriesPoster, _ => null };
        var image = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZ1sAAAAASUVORK5CYII=");
        using (var scope = factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Synthetic shows", Path = factory.DataDirectory, NormalizedPath = factory.DataDirectory, Kind = LibraryKind.TvShows, MonitoringEnabled = false };
            var series = new MediaItem { Id = seriesId, LibraryRoot = library, Kind = MediaKind.Series, DetectedTitle = "Another Story", SourcePath = "synthetic-series", NormalizedSourcePath = "synthetic-series" };
            var episode = new MediaItem { Id = episodeId, LibraryRoot = library, Parent = series, Kind = MediaKind.Episode, DetectedTitle = "Better Days", SeasonNumber = 2, EpisodeNumber = 8, SourcePath = "synthetic-episode", NormalizedSourcePath = "synthetic-episode" };
            series.Metadata = new MediaMetadata { MediaItemId = seriesId, MediaItem = series };
            episode.Metadata = new MediaMetadata { MediaItemId = episodeId, MediaItem = episode };
            if (mode != "none") AddPoster(series.Metadata, seriesPoster);
            if (mode == "episode") AddPoster(episode.Metadata, ownPoster);
            if (mode == "manual")
            {
                AddPoster(series.Metadata, manualPoster, manual: true);
                series.Metadata.ManualFieldsJson = "[\"poster\"]";
                series.Metadata.ManualPosterId = manualPoster;
            }
            if (mode == "removed") series.Metadata.ManualFieldsJson = "[\"poster\"]";
            db.MediaItems.AddRange(series, episode);
            db.WatchEvents.Add(new WatchEvent { Id = Guid.NewGuid(), UserId = owner.User.Id, MediaItem = episode, Timestamp = DateTimeOffset.UtcNow, PositionMilliseconds = 30_000, DurationMilliseconds = 90_000, SecondsWatched = 30 });
            await db.SaveChangesAsync();
        }

        var search = await Get<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/search?query=Better", owner.Token);
        var found = Assert.Single(search.Items);
        var summary = await Get<CatalogItemSummary>($"/api/v1/catalog/items/{episodeId}/summary", owner.Token);
        var history = Assert.Single((await Get<WatchHistoryPage>("/api/v1/history", owner.Token)).Items);
        Assert.Equal(episodeId, found.Id);
        Assert.Equal(seriesId, found.ParentId);
        Assert.Equal("Another Story", found.ParentTitle);
        Assert.Equal("Another Story · S2E8", history.Eyebrow);
        Assert.All(new[] { found.Poster, summary.Poster, history.Poster }, poster => Assert.Equal(expected, poster?.Id));

        if (expected.HasValue)
        {
            using var request = ApiTestClient.Authorized(HttpMethod.Get, found.Poster!.Path, owner.Token);
            using var response = await ApiTestClient.SendAsync(client, request);
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            Assert.Equal(image, await response.Content.ReadAsByteArrayAsync());
            using var anonymous = await client.GetAsync(found.Poster.Path);
            Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);
        }

        using var create = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
            new CreateUserRequest("restricted", "another correct horse password", UserRole.User, ApiTestClient.TestPin, AccessMode: ProfileAccessMode.SelectedTitles, TitleIds: []));
        using var created = await ApiTestClient.SendAsync(client, create);
        created.EnsureSuccessStatusCode();
        using var login = await ApiTestClient.LoginAsync(client, new LoginRequest("restricted", "another correct horse password", "Synthetic client"));
        var restricted = await ApiTestClient.ReadAsync<AuthenticationResponse>(login);
        Assert.Empty((await Get<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/search?query=Better", restricted.Token)).Items);
        Assert.Empty((await Get<WatchHistoryPage>("/api/v1/history", restricted.Token)).Items);
        if (expected.HasValue)
        {
            using var request = ApiTestClient.Authorized(HttpMethod.Get, found.Poster!.Path, restricted.Token);
            using var response = await ApiTestClient.SendAsync(client, request);
            Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
        }

        void AddPoster(MediaMetadata metadata, Guid id, bool manual = false)
        {
            var path = $"{id:N}.png";
            Directory.CreateDirectory(Path.Combine(factory.DataDirectory, "Artwork"));
            File.WriteAllBytes(Path.Combine(factory.DataDirectory, "Artwork", path), image);
            metadata.Artwork.Add(new ArtworkAsset { Id = id, MediaItemId = metadata.MediaItemId, Kind = ArtworkKind.Poster, ProviderPath = path, ContentType = "image/png", ContentLength = image.Length, RelativeFilePath = path, IsManual = manual, Revision = 3, CreatedAt = DateTimeOffset.UtcNow });
        }

        async Task<T> Get<T>(string path, string token)
        {
            using var request = ApiTestClient.Authorized(HttpMethod.Get, path, token);
            using var response = await ApiTestClient.SendAsync(client, request);
            response.EnsureSuccessStatusCode();
            return await ApiTestClient.ReadAsync<T>(response);
        }
    }
}
