using System.Net;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class MediaSegmentTests
{
    [Fact]
    public async Task AdministratorsStoreTimesViewersReadThemAndManualCorrectionsWin()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var episode = await SeedAsync(factory, MediaKind.Episode, season: 1, episode: 1);
        var route = $"/api/v1/media/{episode.Id}/segments";

        using (var empty = await SendAsync(client, owner.Token, HttpMethod.Get, route))
        {
            var value = await ApiTestClient.ReadAsync<MediaSegmentsResponse>(empty);
            Assert.False(value.Analyzed);
            Assert.Null(value.IntroStartMilliseconds);
        }
        using (var detected = await SendAsync(client, owner.Token, HttpMethod.Put, route,
            new SetMediaSegmentsRequest(161_000, 182_000, 2_600_000, MediaSegmentSource.Detected, 1)))
        {
            var value = await ApiTestClient.ReadAsync<MediaSegmentsResponse>(detected);
            Assert.True(value.Analyzed);
            Assert.Equal((161_000L, 182_000L, 2_600_000L), (value.IntroStartMilliseconds!.Value, value.IntroEndMilliseconds!.Value, value.CreditsStartMilliseconds!.Value));
        }

        // A viewer with access reads the times but cannot change them.
        var user = await CreateViewerAsync(client, owner.Token, "segment-viewer", ProfileAccessMode.EntireLibrary);
        using (var read = await SendAsync(client, user.Token, HttpMethod.Get, route))
            Assert.Equal(161_000, (await ApiTestClient.ReadAsync<MediaSegmentsResponse>(read)).IntroStartMilliseconds);
        using (var forbidden = await SendAsync(client, user.Token, HttpMethod.Put, route,
            new SetMediaSegmentsRequest(null, null, null, MediaSegmentSource.None, 1)))
            Assert.Equal(HttpStatusCode.Forbidden, forbidden.StatusCode);

        // A hand correction is never replaced by a later automatic result.
        using (var manual = await SendAsync(client, owner.Token, HttpMethod.Put, route,
            new SetMediaSegmentsRequest(30_000, 90_000, null, MediaSegmentSource.Manual, 0)))
            Assert.Equal(MediaSegmentSource.Manual, (await ApiTestClient.ReadAsync<MediaSegmentsResponse>(manual)).Source);
        using (var automatic = await SendAsync(client, owner.Token, HttpMethod.Put, route,
            new SetMediaSegmentsRequest(1_000, 2_000, null, MediaSegmentSource.Detected, 5)))
        {
            var value = await ApiTestClient.ReadAsync<MediaSegmentsResponse>(automatic);
            Assert.Equal((MediaSegmentSource.Manual, 30_000L), (value.Source, value.IntroStartMilliseconds!.Value));
        }

        using (var cleared = await SendAsync(client, owner.Token, HttpMethod.Delete, route))
            Assert.Equal(HttpStatusCode.NoContent, cleared.StatusCode);
        using (var after = await SendAsync(client, owner.Token, HttpMethod.Get, route))
            Assert.False((await ApiTestClient.ReadAsync<MediaSegmentsResponse>(after)).Analyzed);
    }

    [Fact]
    public async Task BackgroundDetectionSavesWithoutAManagementUnlockButNeverByHand()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var episode = await SeedAsync(factory, MediaKind.Episode, season: 1, episode: 1);
        var route = $"/api/v1/media/{episode.Id}/segments";
        var user = await CreateViewerAsync(client, owner.Token, "detection-viewer", ProfileAccessMode.EntireLibrary);
        using (var locking = await SendAsync(client, owner.Token, HttpMethod.Post, "/api/v1/management/lock"))
            locking.EnsureSuccessStatusCode();

        // Hand corrections stay behind the management unlock.
        using (var manual = await SendAsync(client, owner.Token, HttpMethod.Put, route,
            new SetMediaSegmentsRequest(30_000, 90_000, null, MediaSegmentSource.Manual, 0)))
        {
            Assert.Equal(HttpStatusCode.Forbidden, manual.StatusCode);
            Assert.Equal("management_locked", (await ApiTestClient.ReadAsync<ApiProblem>(manual)).Code);
        }
        using (var detected = await SendAsync(client, owner.Token, HttpMethod.Put, route + "/detected",
            new SetMediaSegmentsRequest(161_000, 182_000, 2_600_000, MediaSegmentSource.Detected, 2)))
        {
            var value = await ApiTestClient.ReadAsync<MediaSegmentsResponse>(detected);
            Assert.Equal((MediaSegmentSource.Detected, 161_000L), (value.Source, value.IntroStartMilliseconds!.Value));
        }
        using (var disguised = await SendAsync(client, owner.Token, HttpMethod.Put, route + "/detected",
            new SetMediaSegmentsRequest(1_000, 2_000, null, MediaSegmentSource.Manual, 0)))
            Assert.Equal(HttpStatusCode.BadRequest, disguised.StatusCode);

        // Viewers still cannot save results.
        using (var forbidden = await SendAsync(client, user.Token, HttpMethod.Put, route + "/detected",
            new SetMediaSegmentsRequest(null, null, null, MediaSegmentSource.None, 2)))
            Assert.Equal(HttpStatusCode.Forbidden, forbidden.StatusCode);
    }

    [Theory]
    [InlineData(10_000L, null, null, MediaSegmentSource.Detected)]
    [InlineData(20_000L, 10_000L, null, MediaSegmentSource.Detected)]
    [InlineData(0L, 16L * 60 * 1000, null, MediaSegmentSource.Detected)]
    [InlineData(-1L, 1_000L, null, MediaSegmentSource.Detected)]
    [InlineData(null, null, 49L * 60 * 60 * 1000, MediaSegmentSource.Detected)]
    [InlineData(1_000L, 2_000L, null, MediaSegmentSource.None)]
    public async Task InvalidTimesAreRejected(long? start, long? end, long? credits, MediaSegmentSource source)
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var movie = await SeedAsync(factory, MediaKind.Movie);
        using var response = await SendAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/media/{movie.Id}/segments",
            new SetMediaSegmentsRequest(start, end, credits, source, 1));
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task ProfilesWithoutAccessAndSeriesCannotReadSegments()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var series = await SeedAsync(factory, MediaKind.Series);
        var episode = await SeedAsync(factory, MediaKind.Episode, parent: series, season: 1, episode: 1);
        using (var seriesResponse = await SendAsync(client, owner.Token, HttpMethod.Get, $"/api/v1/media/{series.Id}/segments"))
            Assert.Equal(HttpStatusCode.NotFound, seriesResponse.StatusCode);
        var restricted = await CreateViewerAsync(client, owner.Token, "segment-restricted", ProfileAccessMode.SelectedTitles);
        using var hidden = await SendAsync(client, restricted.Token, HttpMethod.Get, $"/api/v1/media/{episode.Id}/segments");
        Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
    }

    [Fact]
    public async Task QueueListsWholeSeasonsAndMoviesUntilEveryTitleIsAnalyzed()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var series = await SeedAsync(factory, MediaKind.Series);
        var first = await SeedAsync(factory, MediaKind.Episode, parent: series, season: 1, episode: 1);
        var second = await SeedAsync(factory, MediaKind.Episode, parent: series, season: 1, episode: 2);
        var missing = await SeedAsync(factory, MediaKind.Episode, parent: series, season: 1, episode: 3, available: false);
        var movie = await SeedAsync(factory, MediaKind.Movie);
        await SetAsync(client, owner.Token, first.Id, new(1_000, 31_000, null, MediaSegmentSource.Detected, 1));

        var queue = await QueueAsync(client, owner.Token, 1);
        // Two available episodes and one movie; one episode is done.
        Assert.Equal((3, 1), (queue.TotalTitles, queue.AnalyzedTitles));
        var season = Assert.Single(queue.Groups, group => group.SeriesId == series.Id);
        Assert.Equal([first.Id, second.Id], season.Items.Select(item => item.MediaId));
        Assert.Equal([false, true], season.Items.Select(item => item.NeedsAnalysis));
        Assert.DoesNotContain(season.Items, item => item.MediaId == missing.Id);
        Assert.Contains(queue.Groups, group => group.SeriesId == null && group.Items.Single().MediaId == movie.Id);

        await SetAsync(client, owner.Token, second.Id, new(null, null, null, MediaSegmentSource.None, 1));
        await SetAsync(client, owner.Token, movie.Id, new(null, null, 5_400_000, MediaSegmentSource.Chapters, 1));
        var finished = await QueueAsync(client, owner.Token, 1);
        Assert.Empty(finished.Groups);
        Assert.Equal((3, 3), (finished.TotalTitles, finished.AnalyzedTitles));

        // A newer analysis repeats automatic results, never manual ones.
        await SetAsync(client, owner.Token, first.Id, new(2_000, 32_000, null, MediaSegmentSource.Manual, 1));
        var newer = Assert.Single((await QueueAsync(client, owner.Token, 2)).Groups, group => group.SeriesId == series.Id);
        Assert.Equal([false, true], newer.Items.Select(item => item.NeedsAnalysis));

        var viewer = await CreateViewerAsync(client, owner.Token, "segment-queue-viewer", ProfileAccessMode.EntireLibrary);
        using var forbidden = await SendAsync(client, viewer.Token, HttpMethod.Get, "/api/v1/media/segment-analysis");
        Assert.Equal(HttpStatusCode.Forbidden, forbidden.StatusCode);
    }

    [Fact]
    public async Task SegmentsAreDeletedWithTheirTitle()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var movie = await SeedAsync(factory, MediaKind.Movie);
        await SetAsync(client, owner.Token, movie.Id, new(null, null, 5_000_000, MediaSegmentSource.Chapters, 1));
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        database.MediaItems.Remove(await database.MediaItems.SingleAsync(item => item.Id == movie.Id));
        await database.SaveChangesAsync();
        Assert.Empty(await database.MediaSegments.ToListAsync());
    }

    private static async Task SetAsync(HttpClient client, string token, Guid mediaId, SetMediaSegmentsRequest request)
    {
        using var response = await SendAsync(client, token, HttpMethod.Put, $"/api/v1/media/{mediaId}/segments", request);
        response.EnsureSuccessStatusCode();
    }

    private static async Task<MediaSegmentAnalysisQueueResponse> QueueAsync(HttpClient client, string token, int version)
    {
        using var response = await SendAsync(client, token, HttpMethod.Get, $"/api/v1/media/segment-analysis?analysisVersion={version}&limit=50");
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<MediaSegmentAnalysisQueueResponse>(response);
    }

    private static async Task<AuthenticationResponse> CreateViewerAsync(HttpClient client, string owner, string name, ProfileAccessMode mode)
    {
        using var create = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner, new CreateUserRequest(name, "", UserRole.User, ApiTestClient.TestPin));
        using var created = await ApiTestClient.SendAsync(client, create);
        created.EnsureSuccessStatusCode();
        var user = await ApiTestClient.ReadAsync<UserSummary>(created);
        using (var grant = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{user.Id}/titles", owner,
            new UpdateProfileTitleAccessRequest(mode, [], 0)))
        using (var response = await ApiTestClient.SendAsync(client, grant)) response.EnsureSuccessStatusCode();
        using var login = await ApiTestClient.LoginAsync(client, new LoginRequest(user.Username, "unused", name));
        return await ApiTestClient.ReadAsync<AuthenticationResponse>(login);
    }

    private static async Task<HttpResponseMessage> SendAsync(HttpClient client, string token, HttpMethod method, string path, object? body = null)
    {
        using var request = ApiTestClient.Authorized(method, path, token, body);
        return await client.SendAsync(request);
    }

    private static async Task<MediaItem> SeedAsync(
        AureliaServerFactory factory, MediaKind kind, MediaItem? parent = null, int? season = null, int? episode = null,
        bool available = true)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var library = parent is not null
            ? await database.LibraryRoots.SingleAsync(item => item.Id == parent.LibraryRootId)
            : await database.LibraryRoots.FirstOrDefaultAsync() ?? new LibraryRoot
            {
                Id = Guid.NewGuid(),
                Name = "Synthetic library",
                Path = factory.DataDirectory,
                NormalizedPath = MediaPath.Normalize(factory.DataDirectory),
                Kind = LibraryKind.Automatic,
                CreatedAt = DateTimeOffset.UtcNow,
            };
        var path = Path.Combine(factory.DataDirectory, Guid.NewGuid() + ".mkv");
        var media = new MediaItem
        {
            Id = Guid.NewGuid(),
            Kind = kind,
            DetectedTitle = "Synthetic " + kind,
            LibraryRoot = library,
            LibraryRootId = library.Id,
            ParentId = parent?.Id,
            SourcePath = path,
            NormalizedSourcePath = MediaPath.Normalize(path),
            CreatedAt = DateTimeOffset.UtcNow,
            UpdatedAt = DateTimeOffset.UtcNow,
            Availability = available ? MediaAvailability.Available : MediaAvailability.Missing,
            SeasonNumber = season,
            EpisodeNumber = episode,
        };
        database.MediaItems.Add(media);
        await database.SaveChangesAsync();
        return media;
    }
}
