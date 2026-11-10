using System.Net.Http.Headers;
using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ConcurrentProfileChangeTests
{
    // A double tap, or two devices of one profile, send the same change at the same moment.
    // Each request used to read the old state and then write: the later ones failed in the
    // database and the device got a server error.
    [Fact]
    public async Task SimultaneousFavoriteCollectionAndHistoryChangesAllGetACleanAnswer()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        Guid filmId, seriesId;
        await using (var scope = factory.Services.CreateAsyncScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var root = Path.Combine(factory.DataDirectory, "media");
            Directory.CreateDirectory(root);
            var storage = new LibraryRoot { Id = Guid.NewGuid(), Name = "Synthetic", Path = root, NormalizedPath = MediaPath.Normalize(root), MonitoringEnabled = false, Availability = LibraryAvailability.Available };
            var film = Title(storage, MediaKind.Movie, "Synthetic Film");
            var series = Title(storage, MediaKind.Series, "Synthetic Series");
            database.LibraryRoots.Add(storage);
            database.MediaItems.AddRange(film, series);
            database.WatchEvents.AddRange(Enumerable.Range(0, 20).Select(index => new WatchEvent
            {
                Id = Guid.NewGuid(),
                UserId = owner.User.Id,
                MediaItemId = film.Id,
                Timestamp = DateTimeOffset.UtcNow.AddMinutes(-index),
                SecondsWatched = 60,
            }));
            await database.SaveChangesAsync();
            (filmId, seriesId) = (film.Id, series.Id);
        }
        using var create = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/collections", owner.Token, new SaveCollectionRequest("Synthetic List", []));
        using var created = await client.SendAsync(create);
        created.EnsureSuccessStatusCode();
        var collection = await ApiTestClient.ReadAsync<CollectionSummary>(created);

        await AllSucceedAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/media/{seriesId}/favorite", _ => "{\"isFavorite\":true}");
        await AllSucceedAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/media/{filmId}/favorite", index => index % 2 == 0 ? "{\"isFavorite\":true}" : "{\"isFavorite\":false}");
        await AllSucceedAsync(client, owner.Token, HttpMethod.Post, $"/api/v1/collections/{collection.Id}/items/{filmId}", _ => null);
        await AllSucceedAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/collections/{collection.Id}",
            index => $"{{\"name\":\"Synthetic List {index}\",\"mediaIds\":[\"{filmId}\",\"{seriesId}\"]}}");
        await AllSucceedAsync(client, owner.Token, HttpMethod.Delete, $"/api/v1/collections/{collection.Id}/items/{filmId}", _ => null);
        await AllSucceedAsync(client, owner.Token, HttpMethod.Delete, "/api/v1/history", _ => null);
    }

    private static async Task AllSucceedAsync(HttpClient client, string token, HttpMethod method, string path, Func<int, string?> body)
    {
        var statuses = await Task.WhenAll(Enumerable.Range(0, 16).Select(async index =>
        {
            using var request = new HttpRequestMessage(method, path);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            if (body(index) is { } text) request.Content = new StringContent(text, Encoding.UTF8, "application/json");
            using var response = await client.SendAsync(request);
            return (int)response.StatusCode;
        }));
        Assert.All(statuses, status => Assert.InRange(status, 200, 299));
    }

    private static MediaItem Title(LibraryRoot storage, MediaKind kind, string title)
    {
        var path = Path.Combine(storage.Path, title + ".mkv");
        return new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRoot = storage,
            LibraryRootId = storage.Id,
            Kind = kind,
            DetectedTitle = title,
            SourcePath = path,
            NormalizedSourcePath = MediaPath.Normalize(path),
            Availability = MediaAvailability.Available,
        };
    }
}
