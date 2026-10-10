using System.Net;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class PlaybackProgressTests
{
    [Fact]
    public async Task GuardedProgressReplaysIdempotentlyAndRejectsStaleOrReusedMutations()
    {
        var root = CreateDirectory();
        try
        {
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var mediaId = await AddMediaAsync(factory, root, Path.Combine(root, "Offline.mkv"));
            Assert.Equal(0, (await GetAsync(client, owner.Token, mediaId)).Revision);
            var mutation = new UpdatePlaybackProgressRequest(50_000, 300_000, false, Guid.NewGuid(), true, 0);
            var stored = await PutAsync(client, owner.Token, mediaId, mutation);
            Assert.Equal(1, stored.Revision);
            Assert.Equal(mutation.ClientMutationId, stored.LastMutationId);
            long changeCount;
            using (var scope = factory.Services.CreateScope())
                changeCount = await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().SyncChanges.LongCountAsync();

            var replay = await PutAsync(client, owner.Token, mediaId, mutation);
            Assert.Equal(stored, replay);
            using (var scope = factory.Services.CreateScope())
                Assert.Equal(changeCount, await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().SyncChanges.LongCountAsync());

            await AssertConflictAsync(client, owner.Token, mediaId, mutation with { PositionMilliseconds = 60_000 }, "playback_mutation_reused");
            await AssertConflictAsync(client, owner.Token, mediaId, mutation with { ClientMutationId = Guid.NewGuid() }, "playback_progress_conflict");

            // Deliberate backwards seek is valid when based on the latest revision.
            var backwards = await PutAsync(client, owner.Token, mediaId,
                mutation with { ClientMutationId = Guid.NewGuid(), ExpectedRevision = stored.Revision, PositionMilliseconds = 20_000 });
            Assert.Equal(20_000, backwards.PositionMilliseconds);
            Assert.Equal(2, backwards.Revision);
            await AssertConflictAsync(client, owner.Token, mediaId, mutation, "playback_progress_conflict");
            Assert.Equal(backwards, await GetAsync(client, owner.Token, mediaId));

            // Old clients remain supported, but invalidate the last idempotency marker.
            var legacy = await PutAsync(client, owner.Token, mediaId, new(25_000, 300_000, false));
            Assert.Equal(3, legacy.Revision);
            Assert.Null(legacy.LastMutationId);
        }
        finally { DeleteDirectory(root); }
    }

    [Fact]
    public async Task TwoDevicesCannotCommitAgainstTheSameProgressRevision()
    {
        var root = CreateDirectory();
        try
        {
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var mediaId = await AddMediaAsync(factory, root, Path.Combine(root, "Offline.mkv"));
            using var first = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/media/{mediaId}/progress", owner.Token,
                new UpdatePlaybackProgressRequest(40_000, 300_000, false, Guid.NewGuid(), true, 0));
            using var second = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/media/{mediaId}/progress", owner.Token,
                new UpdatePlaybackProgressRequest(50_000, 300_000, false, Guid.NewGuid(), true, 0));
            var responses = await Task.WhenAll(ApiTestClient.SendAsync(client, first), ApiTestClient.SendAsync(client, second));
            try
            {
                Assert.Single(responses, value => value.StatusCode == HttpStatusCode.OK);
                var rejected = Assert.Single(responses, value => value.StatusCode == HttpStatusCode.Conflict);
                Assert.Equal("playback_progress_conflict", (await ApiTestClient.ReadAsync<ApiProblem>(rejected)).Code);
                Assert.Equal(1, (await GetAsync(client, owner.Token, mediaId)).Revision);
            }
            finally { foreach (var response in responses) response.Dispose(); }
        }
        finally { DeleteDirectory(root); }
    }

    [Fact]
    public async Task GuardedProgressRejectsIncompleteOrInvalidConcurrencyFields()
    {
        var root = CreateDirectory();
        try
        {
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var mediaId = await AddMediaAsync(factory, root, Path.Combine(root, "Offline.mkv"));
            foreach (var invalid in new[]
            {
                new UpdatePlaybackProgressRequest(20_000, 300_000, false, Guid.NewGuid(), true),
                new UpdatePlaybackProgressRequest(20_000, 300_000, false, null, true, 0),
                new UpdatePlaybackProgressRequest(20_000, 300_000, false, Guid.Empty, true, 0),
                new UpdatePlaybackProgressRequest(20_000, 300_000, false, Guid.NewGuid(), true, -1),
            })
            {
                using var request = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/media/{mediaId}/progress", owner.Token, invalid);
                using var response = await ApiTestClient.SendAsync(client, request);
                Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
            }
            Assert.Equal(0, (await GetAsync(client, owner.Token, mediaId)).Revision);
        }
        finally { DeleteDirectory(root); }
    }

    private static async Task AssertConflictAsync(HttpClient client, string token, Guid mediaId,
        UpdatePlaybackProgressRequest progress, string code)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/media/{mediaId}/progress", token, progress);
        using var response = await ApiTestClient.SendAsync(client, request);
        Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
        Assert.Equal(code, (await ApiTestClient.ReadAsync<ApiProblem>(response)).Code);
    }

    [Fact]
    public async Task ProgressIsAuthenticatedValidatedAndIncludedWithPlayback()
    {
        var root = CreateDirectory();
        var path = Path.Combine(root, "Movie.mkv");
        await File.WriteAllBytesAsync(path, [1, 2, 3, 4]);

        try
        {
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var mediaId = await AddMediaAsync(factory, root, path);

            using (var unauthorized = await client.GetAsync(
                       $"/api/v1/media/{mediaId}/progress"))
            {
                Assert.Equal(HttpStatusCode.Unauthorized, unauthorized.StatusCode);
            }

            var empty = await GetAsync(client, owner.Token, mediaId);
            Assert.Equal(mediaId, empty.MediaId);
            Assert.Equal(0, empty.PositionMilliseconds);
            Assert.False(empty.IsCompleted);
            Assert.Null(empty.UpdatedAt);

            var stored = await PutAsync(
                client,
                owner.Token,
                mediaId,
                new UpdatePlaybackProgressRequest(50_000, 120_000, false));
            Assert.Equal(50_000, stored.PositionMilliseconds);
            Assert.Equal(120_000, stored.DurationMilliseconds);
            Assert.False(stored.IsCompleted);
            Assert.NotNull(stored.LastPlayedAt);

            using (var playbackRequest = ApiTestClient.Authorized(
                       HttpMethod.Post,
                       $"/api/v1/media/{mediaId}/playback",
                       owner.Token))
            using (var playbackResponse = await ApiTestClient.SendAsync(client, playbackRequest))
            {
                playbackResponse.EnsureSuccessStatusCode();
                var playback = await ApiTestClient.ReadAsync<PlaybackSourceResponse>(
                    playbackResponse);
                Assert.Equal(stored.MediaId, playback.Progress.MediaId);
                Assert.Equal(stored.PositionMilliseconds, playback.Progress.PositionMilliseconds);
                Assert.Equal(stored.DurationMilliseconds, playback.Progress.DurationMilliseconds);
                Assert.Equal(stored.IsCompleted, playback.Progress.IsCompleted);
            }

            await AssertInvalidAsync(client, owner.Token, mediaId, -1, 100);
            await AssertInvalidAsync(client, owner.Token, mediaId, 101, 100);
            await AssertInvalidAsync(client, owner.Token, mediaId, 0, 0);
        }
        finally
        {
            DeleteDirectory(root);
        }
    }

    [Fact]
    public async Task ProgressUsesResumeResetAndCompletionPolicy()
    {
        var root = CreateDirectory();
        var path = Path.Combine(root, "Episode.mp4");
        await File.WriteAllBytesAsync(path, [4, 3, 2, 1]);

        try
        {
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var mediaId = await AddMediaAsync(factory, root, path, MediaKind.Episode);

            var meaningful = await PutAsync(
                client,
                owner.Token,
                mediaId,
                new UpdatePlaybackProgressRequest(10_001, 120_000, false));
            Assert.Equal(10_001, meaningful.PositionMilliseconds);
            Assert.False(meaningful.IsCompleted);

            var reset = await PutAsync(
                client,
                owner.Token,
                mediaId,
                new UpdatePlaybackProgressRequest(10_000, 120_000, false));
            Assert.Equal(0, reset.PositionMilliseconds);
            Assert.False(reset.IsCompleted);

            var completedByThreshold = await PutAsync(
                client,
                owner.Token,
                mediaId,
                new UpdatePlaybackProgressRequest(75_000, 120_000, false));
            Assert.Equal(0, completedByThreshold.PositionMilliseconds);
            Assert.True(completedByThreshold.IsCompleted);

            var restarted = await PutAsync(
                client,
                owner.Token,
                mediaId,
                new UpdatePlaybackProgressRequest(20_000, 120_000, false));
            Assert.Equal(20_000, restarted.PositionMilliseconds);
            Assert.False(restarted.IsCompleted);

            var explicitlyFinished = await PutAsync(
                client,
                owner.Token,
                mediaId,
                new UpdatePlaybackProgressRequest(25_000, 120_000, true));
            Assert.Equal(0, explicitlyFinished.PositionMilliseconds);
            Assert.True(explicitlyFinished.IsCompleted);
        }
        finally
        {
            DeleteDirectory(root);
        }
    }

    [Fact]
    public async Task ProgressIsPerUserSurvivesLogoutAndWorksForMissingMedia()
    {
        var root = CreateDirectory();
        var path = Path.Combine(root, "Missing.webm");

        try
        {
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var mediaId = await AddMediaAsync(
                factory,
                root,
                path,
                MediaKind.Movie,
                MediaAvailability.Missing,
                LibraryAvailability.Unavailable);
            var viewer = await CreateViewerAsync(client, owner.Token);
            await ApiTestClient.GrantExistingLibrariesAsync(client, owner.Token, viewer.User.Id);

            // Mutation identities and revisions are scoped to the account/title,
            // never used to deduplicate another user's independent progress.
            var sharedMutationId = Guid.NewGuid();

            await PutAsync(
                client,
                owner.Token,
                mediaId,
                new UpdatePlaybackProgressRequest(20_000, 100_000, false, sharedMutationId, true, 0));
            await PutAsync(
                client,
                viewer.Token,
                mediaId,
                new UpdatePlaybackProgressRequest(30_000, 100_000, false, sharedMutationId, true, 0));

            Assert.Equal(20_000, (await GetAsync(client, owner.Token, mediaId)).PositionMilliseconds);
            Assert.Equal(30_000, (await GetAsync(client, viewer.Token, mediaId)).PositionMilliseconds);

            using (var logout = ApiTestClient.Authorized(
                       HttpMethod.Post,
                       "/api/v1/auth/logout",
                       viewer.Token))
            using (var response = await ApiTestClient.SendAsync(client, logout))
            {
                Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
            }

            using var scope = factory.Services.CreateScope();
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            Assert.Equal(2, await database.PlaybackProgress.CountAsync());
        }
        finally
        {
            DeleteDirectory(root);
        }
    }

    [Fact]
    public async Task SeriesContainersRejectProgressAndDeletingMediaCascades()
    {
        var root = CreateDirectory();
        try
        {
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var seriesId = await AddMediaAsync(factory, root, root, MediaKind.Series);

            using (var get = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       $"/api/v1/media/{seriesId}/progress",
                       owner.Token))
            using (var response = await ApiTestClient.SendAsync(client, get))
            {
                Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
                Assert.Equal(
                    "media_not_playable",
                    (await ApiTestClient.ReadAsync<ApiProblem>(response)).Code);
            }

            var movieRoot = Path.Combine(root, "Movies");
            Directory.CreateDirectory(movieRoot);
            var moviePath = Path.Combine(movieRoot, "Movie.mov");
            await File.WriteAllBytesAsync(moviePath, [1]);
            var movieId = await AddMediaAsync(factory, movieRoot, moviePath);
            await PutAsync(
                client,
                owner.Token,
                movieId,
                new UpdatePlaybackProgressRequest(20_000, 100_000, false));

            using var scope = factory.Services.CreateScope();
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            await database.MediaItems
                .Where(item => item.Id == movieId)
                .ExecuteDeleteAsync();
            Assert.False(await database.PlaybackProgress.AnyAsync());
        }
        finally
        {
            DeleteDirectory(root);
        }
    }

    private static async Task AssertInvalidAsync(
        HttpClient client,
        string token,
        Guid mediaId,
        long position,
        long duration)
    {
        using var request = ApiTestClient.Authorized(
            HttpMethod.Put,
            $"/api/v1/media/{mediaId}/progress",
            token,
            new UpdatePlaybackProgressRequest(position, duration, false));
        using var response = await ApiTestClient.SendAsync(client, request);
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Equal(
            "invalid_playback_progress",
            (await ApiTestClient.ReadAsync<ApiProblem>(response)).Code);
    }

    private static async Task<PlaybackProgressResponse> GetAsync(
        HttpClient client,
        string token,
        Guid mediaId)
    {
        using var request = ApiTestClient.Authorized(
            HttpMethod.Get,
            $"/api/v1/media/{mediaId}/progress",
            token);
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<PlaybackProgressResponse>(response);
    }

    private static async Task<PlaybackProgressResponse> PutAsync(
        HttpClient client,
        string token,
        Guid mediaId,
        UpdatePlaybackProgressRequest progress)
    {
        using var request = ApiTestClient.Authorized(
            HttpMethod.Put,
            $"/api/v1/media/{mediaId}/progress",
            token,
            progress);
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<PlaybackProgressResponse>(response);
    }

    private static async Task<AuthenticationResponse> CreateViewerAsync(
        HttpClient client,
        string ownerToken)
    {
        using (var create = ApiTestClient.Authorized(
                   HttpMethod.Post,
                   "/api/v1/users",
                   ownerToken,
                   new CreateUserRequest("viewer", "a secure viewer password", UserRole.User)))
        using (var response = await ApiTestClient.SendAsync(client, create))
        {
            response.EnsureSuccessStatusCode();
        }

        using var login = await client.PostAsJsonAsync(
            "/api/v1/auth/login",
            new LoginRequest("viewer", "a secure viewer password", "Viewer Mac"),
            ApiTestClient.JsonOptions);
        login.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<AuthenticationResponse>(login);
    }

    private static async Task<Guid> AddMediaAsync(
        AureliaServerFactory factory,
        string root,
        string path,
        MediaKind kind = MediaKind.Movie,
        MediaAvailability availability = MediaAvailability.Available,
        LibraryAvailability libraryAvailability = LibraryAvailability.Available)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = DateTimeOffset.UtcNow;
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = $"Library {Guid.NewGuid():N}",
            Path = root,
            NormalizedPath = MediaPath.Normalize(root),
            Kind = kind is MediaKind.Series or MediaKind.Episode
                ? LibraryKind.TvShows
                : LibraryKind.Movies,
            Availability = libraryAvailability,
            CreatedAt = now,
        };
        var media = new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRoot = library,
            LibraryRootId = library.Id,
            Kind = kind,
            SourcePath = path,
            NormalizedSourcePath = MediaPath.Normalize(path),
            DetectedTitle = "Test Media",
            Category = string.Empty,
            Extension = kind == MediaKind.Series ? null : Path.GetExtension(path).ToLowerInvariant(),
            FileSize = File.Exists(path) ? new FileInfo(path).Length : null,
            FileModifiedAt = File.Exists(path)
                ? new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero)
                : null,
            Availability = availability,
            CreatedAt = now,
            UpdatedAt = now,
        };
        database.MediaItems.Add(media);
        await database.SaveChangesAsync();
        return media.Id;
    }

    private static string CreateDirectory()
    {
        var root = Path.Combine(TestPaths.CreateDataDirectory(), "Playback Progress");
        Directory.CreateDirectory(root);
        return root;
    }

    private static void DeleteDirectory(string path)
    {
        if (Directory.Exists(path))
        {
            Directory.Delete(path, recursive: true);
        }
    }
}
