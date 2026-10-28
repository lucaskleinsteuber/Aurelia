using System.Net;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class WatchlistAndPersonTests
{
    [Fact]
    public async Task WatchlistAndPersonPagesReturnAccessibleTitlesPerProfile()
    {
        var rootPath = Path.Combine(TestPaths.CreateDataDirectory(), "WatchlistPersonMovies");
        Directory.CreateDirectory(rootPath);
        var movieAlphaPath = Path.Combine(rootPath, "First Horizon (2024).mkv");
        var movieBetaPath = Path.Combine(rootPath, "Second Horizon (2022).mkv");
        try
        {
            await File.WriteAllTextAsync(movieAlphaPath, "alpha");
            await File.WriteAllTextAsync(movieBetaPath, "beta");

            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);

            using (var capabilities = await client.GetAsync("/api/v1/capabilities"))
            {
                var reported = await ApiTestClient.ReadAsync<ClientCapabilitiesResponse>(capabilities);
                Assert.Contains(ServerFeatures.WatchlistAndPeople, reported.Capabilities);
            }

            Guid alphaId;
            Guid betaId;
            await using (var scope = factory.Services.CreateAsyncScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var now = DateTimeOffset.UtcNow;
                var root = new LibraryRoot
                {
                    Id = Guid.NewGuid(),
                    Name = "Movies",
                    Path = rootPath,
                    NormalizedPath = MediaPath.Normalize(rootPath),
                    Kind = LibraryKind.Movies,
                    Availability = LibraryAvailability.Available,
                    CreatedAt = now,
                };
                database.LibraryRoots.Add(root);
                var alpha = new MediaItem
                {
                    Id = Guid.NewGuid(),
                    LibraryRootId = root.Id,
                    Kind = MediaKind.Movie,
                    DetectedTitle = "First Horizon",
                    Year = 2024,
                    Category = string.Empty,
                    Extension = ".mkv",
                    SourcePath = movieAlphaPath,
                    NormalizedSourcePath = MediaPath.Normalize(movieAlphaPath),
                    Availability = MediaAvailability.Available,
                    CreatedAt = now,
                    UpdatedAt = now,
                };
                var beta = new MediaItem
                {
                    Id = Guid.NewGuid(),
                    LibraryRootId = root.Id,
                    Kind = MediaKind.Movie,
                    DetectedTitle = "Second Horizon",
                    Year = 2022,
                    Category = string.Empty,
                    Extension = ".mkv",
                    SourcePath = movieBetaPath,
                    NormalizedSourcePath = MediaPath.Normalize(movieBetaPath),
                    Availability = MediaAvailability.Available,
                    CreatedAt = now,
                    UpdatedAt = now,
                };
                database.MediaItems.AddRange(alpha, beta);
                var alphaMeta = new MediaMetadata
                {
                    MediaItemId = alpha.Id,
                    Provider = "tmdb",
                    ProviderMediaId = "101",
                    ProviderTitle = "First Horizon",
                    ReviewState = MetadataReviewState.Matched,
                    UpdatedAt = now,
                };
                var betaMeta = new MediaMetadata
                {
                    MediaItemId = beta.Id,
                    Provider = "tmdb",
                    ProviderMediaId = "102",
                    ProviderTitle = "Second Horizon",
                    ReviewState = MetadataReviewState.Matched,
                    UpdatedAt = now,
                };
                database.MediaMetadata.AddRange(alphaMeta, betaMeta);
                database.MediaCredits.AddRange(
                    new MediaCredit
                    {
                        Id = Guid.NewGuid(),
                        MediaItemId = alpha.Id,
                        Name = "Elena Vance",
                        Department = "Acting",
                        Character = "Commander",
                        ProviderPersonId = "777",
                        SortOrder = 0,
                    },
                    new MediaCredit
                    {
                        Id = Guid.NewGuid(),
                        MediaItemId = beta.Id,
                        Name = "Elena Vance",
                        Department = "Directing",
                        Job = "Director",
                        ProviderPersonId = "777",
                        SortOrder = 1,
                    });
                await database.SaveChangesAsync();
                alphaId = alpha.Id;
                betaId = beta.Id;
            }

            using (var addAlpha = ApiTestClient.Authorized(
                       HttpMethod.Put,
                       $"/api/v1/media/{alphaId}/watchlist",
                       owner.Token,
                       new SetWatchlistRequest(true)))
            using (var addAlphaResponse = await client.SendAsync(addAlpha))
            {
                Assert.Equal(HttpStatusCode.OK, addAlphaResponse.StatusCode);
                var state = await ApiTestClient.ReadAsync<WatchlistItemStateResponse>(addAlphaResponse);
                Assert.Equal(alphaId, state.MediaId);
                Assert.True(state.IsWatchlisted);
            }

            using (var listRequest = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/watchlist", owner.Token))
            using (var listResponse = await client.SendAsync(listRequest))
            {
                Assert.Equal(HttpStatusCode.OK, listResponse.StatusCode);
                var watchlist = await ApiTestClient.ReadAsync<WatchlistResponse>(listResponse);
                Assert.Equal([alphaId], watchlist.MediaIds);
                Assert.Equal("First Horizon", Assert.Single(watchlist.Items).Title);
            }

            using (var removeAlpha = ApiTestClient.Authorized(
                       HttpMethod.Put,
                       $"/api/v1/media/{alphaId}/watchlist",
                       owner.Token,
                       new SetWatchlistRequest(false)))
            using (var removeAlphaResponse = await client.SendAsync(removeAlpha))
            {
                Assert.Equal(HttpStatusCode.OK, removeAlphaResponse.StatusCode);
            }

            using (var listAfterRemove = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/watchlist", owner.Token))
            using (var listAfterRemoveResponse = await client.SendAsync(listAfterRemove))
            {
                var watchlist = await ApiTestClient.ReadAsync<WatchlistResponse>(listAfterRemoveResponse);
                Assert.Empty(watchlist.Items);
                Assert.Empty(watchlist.MediaIds);
            }

            using (var personRequest = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       "/api/v1/catalog/person?name=Elena%20Vance&key=tmdb%3Aperson%3A777",
                       owner.Token))
            using (var personResponse = await client.SendAsync(personRequest))
            {
                Assert.Equal(HttpStatusCode.OK, personResponse.StatusCode);
                var person = await ApiTestClient.ReadAsync<PersonDetailResponse>(personResponse);
                Assert.Equal("Elena Vance", person.Name);
                Assert.Equal("Acting · Director", person.Subtitle);
                Assert.Equal([alphaId, betaId], person.Items.Select(item => item.Id).ToArray());
            }
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(rootPath)!, recursive: true);
        }
    }
}
