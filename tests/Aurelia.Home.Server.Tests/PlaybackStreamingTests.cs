using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Aurelia.Home.Contracts;
using Aurelia.Home.Server.Data;
using Aurelia.Home.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Aurelia.Home.Server.Tests;

public sealed class PlaybackStreamingTests
{
    [Fact]
    public async Task UserCanCreatePlaybackAndReadFullHeadAndRangeResponses()
    {
        var root = CreateDirectory("Range Movie");
        var path = Path.Combine(root, "Original Secret Name.mkv");
        var content = Enumerable.Range(0, 4096).Select(index => (byte)(index % 251)).ToArray();
        await File.WriteAllBytesAsync(path, content);

        try
        {
            using var factory = new AureliaHomeServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var mediaId = await AddMediaAsync(factory, root, path);
            await CreateUserAsync(client, owner.Token);
            var viewer = await LoginAsync(client);

            using (var unauthorizedResponse = await client.PostAsync(
                       $"/api/v1/media/{mediaId}/playback",
                       content: null))
            {
                Assert.Equal(HttpStatusCode.Unauthorized, unauthorizedResponse.StatusCode);
            }

            var playback = await CreatePlaybackAsync(client, viewer.Token, mediaId);
            Assert.Equal(mediaId, playback.MediaId);
            Assert.Equal("video/x-matroska", playback.ContentType);
            Assert.Equal(content.Length, playback.ContentLength);
            Assert.StartsWith("/api/v1/streams/", playback.StreamPath, StringComparison.Ordinal);
            Assert.DoesNotContain(root, playback.StreamPath, StringComparison.Ordinal);
            Assert.DoesNotContain(Path.GetFileName(path), playback.StreamPath, StringComparison.Ordinal);
            Assert.Equal(mediaId, playback.Progress.MediaId);
            Assert.Equal(0, playback.Progress.PositionMilliseconds);
            Assert.False(playback.Progress.IsCompleted);

            var rawTicket = Path.GetFileName(playback.StreamPath);
            using (var scope = factory.Services.CreateScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaHomeDbContext>();
                var stored = await database.PlaybackTickets.SingleAsync();
                Assert.Equal(mediaId, stored.MediaItemId);
                Assert.NotEqual(rawTicket, stored.TokenHash);
                Assert.Equal(64, stored.TokenHash.Length);
                Assert.InRange(
                    stored.ExpiresAt - stored.CreatedAt,
                    TimeSpan.FromHours(12),
                    TimeSpan.FromHours(12));
            }

            using (var fullResponse = await client.GetAsync(playback.StreamPath))
            {
                Assert.Equal(HttpStatusCode.OK, fullResponse.StatusCode);
                Assert.Equal("video/x-matroska", fullResponse.Content.Headers.ContentType?.MediaType);
                Assert.Equal(content.Length, fullResponse.Content.Headers.ContentLength);
                Assert.Null(fullResponse.Content.Headers.ContentDisposition);
                Assert.True(fullResponse.Headers.CacheControl?.NoStore);
                Assert.Equal(content, await fullResponse.Content.ReadAsByteArrayAsync());
            }

            using (var headRequest = new HttpRequestMessage(HttpMethod.Head, playback.StreamPath))
            using (var headResponse = await client.SendAsync(headRequest))
            {
                Assert.Equal(HttpStatusCode.OK, headResponse.StatusCode);
                Assert.Equal(content.Length, headResponse.Content.Headers.ContentLength);
                Assert.Empty(await headResponse.Content.ReadAsByteArrayAsync());
                Assert.NotNull(headResponse.Headers.ETag);

                using var ifRangeRequest = RangeRequest(playback.StreamPath, 100, 199);
                ifRangeRequest.Headers.TryAddWithoutValidation(
                    "If-Range",
                    headResponse.Headers.ETag.Tag);
                using var ifRangeResponse = await client.SendAsync(ifRangeRequest);
                Assert.Equal(HttpStatusCode.PartialContent, ifRangeResponse.StatusCode);
                Assert.Equal(content[100..200], await ifRangeResponse.Content.ReadAsByteArrayAsync());
            }

            await AssertRangeAsync(client, playback.StreamPath, content, 10, 19);
            await AssertRangeAsync(client, playback.StreamPath, content, 4000, null);
            await AssertSuffixRangeAsync(client, playback.StreamPath, content, 20);

            using (var invalidRequest = new HttpRequestMessage(HttpMethod.Get, playback.StreamPath))
            {
                invalidRequest.Headers.TryAddWithoutValidation("Range", "bytes=invalid");
                using var invalidResponse = await client.SendAsync(invalidRequest);
                Assert.Equal(HttpStatusCode.RequestedRangeNotSatisfiable, invalidResponse.StatusCode);
                Assert.Equal($"bytes */{content.Length}", invalidResponse.Content.Headers.ContentRange?.ToString());
            }

            using (var unsatisfiedRequest = RangeRequest(
                       playback.StreamPath,
                       content.Length + 100,
                       content.Length + 200))
            using (var unsatisfiedResponse = await client.SendAsync(unsatisfiedRequest))
            {
                Assert.Equal(HttpStatusCode.RequestedRangeNotSatisfiable, unsatisfiedResponse.StatusCode);
                Assert.Equal($"bytes */{content.Length}", unsatisfiedResponse.Content.Headers.ContentRange?.ToString());
            }

            var parallelRequests = Enumerable.Range(0, 4).Select(async index =>
            {
                var start = index * 100;
                using var request = RangeRequest(playback.StreamPath, start, start + 99);
                using var response = await client.SendAsync(request);
                Assert.Equal(HttpStatusCode.PartialContent, response.StatusCode);
                Assert.Equal(content[start..(start + 100)], await response.Content.ReadAsByteArrayAsync());
            });
            await Task.WhenAll(parallelRequests);

            using (var revokeRequest = ApiTestClient.Authorized(
                       HttpMethod.Delete,
                       $"/api/v1/playback/{playback.Id}",
                       viewer.Token))
            using (var revokeResponse = await client.SendAsync(revokeRequest))
            {
                Assert.Equal(HttpStatusCode.NoContent, revokeResponse.StatusCode);
            }

            using var revokedResponse = await client.GetAsync(playback.StreamPath);
            Assert.Equal(HttpStatusCode.NotFound, revokedResponse.StatusCode);
        }
        finally
        {
            DeleteDirectory(root);
        }
    }

    [Fact]
    public async Task ExpiredTicketIsPrunedAndDeviceLogoutInvalidatesPlayback()
    {
        var root = CreateDirectory("Ticket Lifetime");
        var path = Path.Combine(root, "Movie.mp4");
        await File.WriteAllBytesAsync(path, [1, 2, 3, 4]);

        try
        {
            using var factory = new AureliaHomeServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var mediaId = await AddMediaAsync(factory, root, path);
            var expired = await CreatePlaybackAsync(client, owner.Token, mediaId);

            using (var scope = factory.Services.CreateScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaHomeDbContext>();
                var ticket = await database.PlaybackTickets.FindAsync(expired.Id);
                Assert.NotNull(ticket);
                ticket.ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(-1);
                await database.SaveChangesAsync();
            }

            using (var expiredResponse = await client.GetAsync(expired.StreamPath))
            {
                Assert.Equal(HttpStatusCode.NotFound, expiredResponse.StatusCode);
            }

            var active = await CreatePlaybackAsync(client, owner.Token, mediaId);
            using (var scope = factory.Services.CreateScope())
            {
                var database = scope.ServiceProvider.GetRequiredService<AureliaHomeDbContext>();
                Assert.False(await database.PlaybackTickets.AnyAsync(ticket => ticket.Id == expired.Id));
            }

            using (var logout = ApiTestClient.Authorized(
                       HttpMethod.Post,
                       "/api/v1/auth/logout",
                       owner.Token))
            using (var logoutResponse = await client.SendAsync(logout))
            {
                Assert.Equal(HttpStatusCode.NoContent, logoutResponse.StatusCode);
            }

            using var afterLogout = await client.GetAsync(active.StreamPath);
            Assert.Equal(HttpStatusCode.NotFound, afterLogout.StatusCode);
        }
        finally
        {
            DeleteDirectory(root);
        }
    }

    [Fact]
    public async Task ExpiredTicketsArePrunedWhenServerRestarts()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        var root = CreateDirectory("Restart Cleanup");
        var path = Path.Combine(root, "Movie.avi");
        await File.WriteAllBytesAsync(path, [2, 4, 6, 8]);
        Guid playbackId;

        try
        {
            using (var firstFactory = new AureliaHomeServerFactory(dataDirectory))
            using (var firstClient = firstFactory.CreateClient())
            {
                var owner = await ApiTestClient.SetupOwnerAsync(firstClient);
                var mediaId = await AddMediaAsync(firstFactory, root, path);
                var playback = await CreatePlaybackAsync(firstClient, owner.Token, mediaId);
                playbackId = playback.Id;

                using var scope = firstFactory.Services.CreateScope();
                var database = scope.ServiceProvider.GetRequiredService<AureliaHomeDbContext>();
                var ticket = await database.PlaybackTickets.FindAsync(playbackId);
                Assert.NotNull(ticket);
                ticket.ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(-1);
                await database.SaveChangesAsync();
            }

            using var secondFactory = new AureliaHomeServerFactory(dataDirectory);
            using var secondClient = secondFactory.CreateClient();
            using var response = await secondClient.GetAsync("/api/v1/health");
            response.EnsureSuccessStatusCode();
            using var secondScope = secondFactory.Services.CreateScope();
            var secondDatabase = secondScope.ServiceProvider.GetRequiredService<AureliaHomeDbContext>();
            Assert.False(await secondDatabase.PlaybackTickets.AnyAsync(
                ticket => ticket.Id == playbackId));
        }
        finally
        {
            DeleteDirectory(root);
            DeleteDirectory(dataDirectory);
        }
    }

    [Fact]
    public async Task UnsafeOrUnavailableMediaCannotCreatePlayback()
    {
        var root = CreateDirectory("Unsafe Media");

        try
        {
            using var factory = new AureliaHomeServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);

            using (var unknown = ApiTestClient.Authorized(
                       HttpMethod.Post,
                       $"/api/v1/media/{Guid.NewGuid()}/playback",
                       owner.Token))
            using (var unknownResponse = await client.SendAsync(unknown))
            {
                await AssertProblemAsync(unknownResponse, HttpStatusCode.NotFound, "media_not_found");
            }

            var seriesRoot = Path.Combine(root, "Series Library");
            Directory.CreateDirectory(seriesRoot);
            var seriesId = await AddMediaAsync(factory, seriesRoot, seriesRoot, MediaKind.Series);
            await AssertPlaybackProblemAsync(
                client,
                owner.Token,
                seriesId,
                "media_not_playable");

            var missingRoot = Path.Combine(root, "Missing Library");
            Directory.CreateDirectory(missingRoot);
            var missingPath = Path.Combine(missingRoot, "Missing.mkv");
            var missingId = await AddMediaAsync(
                factory,
                missingRoot,
                missingPath,
                availability: MediaAvailability.Missing);
            await AssertPlaybackProblemAsync(client, owner.Token, missingId, "media_unavailable");

            var offlineRoot = Path.Combine(root, "Offline Library");
            Directory.CreateDirectory(offlineRoot);
            var offlinePath = Path.Combine(offlineRoot, "Safe.webm");
            await File.WriteAllBytesAsync(offlinePath, [1, 2, 3]);
            var offlineId = await AddMediaAsync(
                factory,
                offlineRoot,
                offlinePath,
                libraryAvailability: LibraryAvailability.Unavailable);
            await AssertPlaybackProblemAsync(client, owner.Token, offlineId, "media_unavailable");

            var outsideRoot = CreateDirectory("Outside Library");
            try
            {
                var outsidePath = Path.Combine(outsideRoot, "Outside.mkv");
                await File.WriteAllBytesAsync(outsidePath, [5, 6, 7]);
                var outsideLibraryRoot = Path.Combine(root, "Outside Anchor");
                Directory.CreateDirectory(outsideLibraryRoot);
                var outsideId = await AddMediaAsync(factory, outsideLibraryRoot, outsidePath);
                await AssertPlaybackProblemAsync(
                    client,
                    owner.Token,
                    outsideId,
                    "media_file_unavailable");
            }
            finally
            {
                DeleteDirectory(outsideRoot);
            }

            var linkRoot = Path.Combine(root, "Link Library");
            Directory.CreateDirectory(linkRoot);
            var targetPath = Path.Combine(linkRoot, "Target.mkv");
            var linkPath = Path.Combine(linkRoot, "Linked.mkv");
            await File.WriteAllBytesAsync(targetPath, [8, 9, 10]);
            File.CreateSymbolicLink(linkPath, targetPath);
            var linkId = await AddMediaAsync(factory, linkRoot, linkPath);
            await AssertPlaybackProblemAsync(
                client,
                owner.Token,
                linkId,
                "media_file_unavailable");

            var packageRoot = Path.Combine(root, "Package Library");
            var packagePath = Path.Combine(packageRoot, "Hidden.app", "Inside.mkv");
            Directory.CreateDirectory(Path.GetDirectoryName(packagePath)!);
            await File.WriteAllBytesAsync(packagePath, [11, 12, 13]);
            var packageId = await AddMediaAsync(factory, packageRoot, packagePath);
            await AssertPlaybackProblemAsync(
                client,
                owner.Token,
                packageId,
                "media_file_unavailable");

            var deletedRoot = Path.Combine(root, "Deleted Library");
            Directory.CreateDirectory(deletedRoot);
            var deletedPath = Path.Combine(deletedRoot, "Deleted.mov");
            await File.WriteAllBytesAsync(deletedPath, [14, 15, 16]);
            var deletedId = await AddMediaAsync(factory, deletedRoot, deletedPath);
            var deletedPlayback = await CreatePlaybackAsync(client, owner.Token, deletedId);
            File.Delete(deletedPath);
            using var deletedResponse = await client.GetAsync(deletedPlayback.StreamPath);
            Assert.Equal(HttpStatusCode.NotFound, deletedResponse.StatusCode);
        }
        finally
        {
            DeleteDirectory(root);
        }
    }

    [Fact]
    public async Task PlaybackTicketNeverAppearsInApplicationLogs()
    {
        var root = CreateDirectory("Private Ticket");
        var path = Path.Combine(root, "Movie.m4v");
        await File.WriteAllBytesAsync(path, [1, 3, 5, 7]);
        var logs = new CollectingLoggerProvider();

        try
        {
            using var factory = new AureliaHomeServerFactory(
                configureLogging: logging =>
                {
                    logging.SetMinimumLevel(LogLevel.Trace);
                    logging.AddProvider(logs);
                });
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var mediaId = await AddMediaAsync(factory, root, path);
            var playback = await CreatePlaybackAsync(client, owner.Token, mediaId);
            var rawTicket = Path.GetFileName(playback.StreamPath);

            using var streamResponse = await client.GetAsync(playback.StreamPath);
            Assert.Equal(HttpStatusCode.OK, streamResponse.StatusCode);
            Assert.DoesNotContain(
                logs.Messages,
                message => message.Contains(rawTicket, StringComparison.Ordinal));
        }
        finally
        {
            logs.Dispose();
            DeleteDirectory(root);
        }
    }

    [Fact]
    public void NonLoopbackListenUrlIsRejected()
    {
        var configuration = new ConfigurationBuilder().Build();
        var dataDirectory = TestPaths.CreateDataDirectory();
        try
        {
            Assert.Throws<ArgumentException>(() => ServerRuntimeOptions.Resolve(
                configuration,
                ["--data-dir", dataDirectory, "--urls", "http://0.0.0.0:43110"]));
            var loopback = ServerRuntimeOptions.Resolve(
                configuration,
                ["--data-dir", dataDirectory, "--urls", "http://127.0.0.1:43110"]);
            Assert.Equal("http://127.0.0.1:43110", loopback.ListenUrl);
        }
        finally
        {
            if (Directory.Exists(dataDirectory))
            {
                Directory.Delete(dataDirectory, recursive: true);
            }
        }
    }

    [Theory]
    [InlineData(".mkv", "video/x-matroska")]
    [InlineData(".mp4", "video/mp4")]
    [InlineData(".mov", "video/quicktime")]
    [InlineData(".m4v", "video/x-m4v")]
    [InlineData(".avi", "video/x-msvideo")]
    [InlineData(".webm", "video/webm")]
    public async Task SupportedMediaExtensionsHaveStableContentTypes(
        string extension,
        string expectedContentType)
    {
        var root = CreateDirectory("Content Type");
        var path = Path.Combine(root, $"Movie{extension}");
        await File.WriteAllBytesAsync(path, [1]);
        try
        {
            var now = DateTimeOffset.UtcNow;
            var library = new LibraryRoot
            {
                Id = Guid.NewGuid(),
                Name = "Movies",
                Path = root,
                NormalizedPath = MediaPath.Normalize(root),
                Kind = LibraryKind.Movies,
                Availability = LibraryAvailability.Available,
                CreatedAt = now,
            };
            var media = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRoot = library,
                LibraryRootId = library.Id,
                Kind = MediaKind.Movie,
                SourcePath = path,
                NormalizedSourcePath = MediaPath.Normalize(path),
                DetectedTitle = "Movie",
                Category = string.Empty,
                Extension = extension,
                Availability = MediaAvailability.Available,
                CreatedAt = now,
                UpdatedAt = now,
            };

            var opened = MediaFileAccess.OpenRead(media);
            await using var stream = opened.Stream;
            Assert.Equal(expectedContentType, opened.ContentType);
        }
        finally
        {
            DeleteDirectory(root);
        }
    }

    private static async Task<Guid> AddMediaAsync(
        AureliaHomeServerFactory factory,
        string root,
        string path,
        MediaKind kind = MediaKind.Movie,
        MediaAvailability availability = MediaAvailability.Available,
        LibraryAvailability libraryAvailability = LibraryAvailability.Available)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaHomeDbContext>();
        var now = DateTimeOffset.UtcNow;
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = $"Library {Guid.NewGuid():N}",
            Path = root,
            NormalizedPath = MediaPath.Normalize(root),
            Kind = kind == MediaKind.Series ? LibraryKind.TvShows : LibraryKind.Movies,
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

    private static async Task CreateUserAsync(HttpClient client, string ownerToken)
    {
        using var request = ApiTestClient.Authorized(
            HttpMethod.Post,
            "/api/v1/users",
            ownerToken,
            new CreateUserRequest(
                "viewer",
                "a secure viewer password",
                UserRole.User));
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
    }

    private static async Task<AuthenticationResponse> LoginAsync(HttpClient client)
    {
        using var response = await client.PostAsJsonAsync(
            "/api/v1/auth/login",
            new LoginRequest("viewer", "a secure viewer password", "Viewer Mac"),
            ApiTestClient.JsonOptions);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<AuthenticationResponse>(response);
    }

    private static async Task<PlaybackSourceResponse> CreatePlaybackAsync(
        HttpClient client,
        string token,
        Guid mediaId)
    {
        using var request = ApiTestClient.Authorized(
            HttpMethod.Post,
            $"/api/v1/media/{mediaId}/playback",
            token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<PlaybackSourceResponse>(response);
    }

    private static HttpRequestMessage RangeRequest(string path, long from, long? to)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, path);
        request.Headers.Range = new RangeHeaderValue(from, to);
        return request;
    }

    private static async Task AssertRangeAsync(
        HttpClient client,
        string path,
        byte[] content,
        int from,
        int? to)
    {
        using var request = RangeRequest(path, from, to);
        using var response = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.PartialContent, response.StatusCode);
        var finalIndex = to ?? content.Length - 1;
        Assert.Equal(content[from..(finalIndex + 1)], await response.Content.ReadAsByteArrayAsync());
        Assert.Equal(
            $"bytes {from}-{finalIndex}/{content.Length}",
            response.Content.Headers.ContentRange?.ToString());
    }

    private static async Task AssertSuffixRangeAsync(
        HttpClient client,
        string path,
        byte[] content,
        int length)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, path);
        request.Headers.Range = new RangeHeaderValue();
        request.Headers.Range.Ranges.Add(new RangeItemHeaderValue(null, length));
        using var response = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.PartialContent, response.StatusCode);
        Assert.Equal(content[^length..], await response.Content.ReadAsByteArrayAsync());
        Assert.Equal(
            $"bytes {content.Length - length}-{content.Length - 1}/{content.Length}",
            response.Content.Headers.ContentRange?.ToString());
    }

    private static async Task AssertPlaybackProblemAsync(
        HttpClient client,
        string token,
        Guid mediaId,
        string code)
    {
        using var request = ApiTestClient.Authorized(
            HttpMethod.Post,
            $"/api/v1/media/{mediaId}/playback",
            token);
        using var response = await client.SendAsync(request);
        await AssertProblemAsync(response, HttpStatusCode.Conflict, code);
    }

    private static async Task AssertProblemAsync(
        HttpResponseMessage response,
        HttpStatusCode status,
        string code)
    {
        Assert.Equal(status, response.StatusCode);
        var problem = await ApiTestClient.ReadAsync<ApiProblem>(response);
        Assert.Equal(code, problem.Code);
        Assert.DoesNotContain("/", problem.Message, StringComparison.Ordinal);
    }

    private static string CreateDirectory(string name)
    {
        var root = Path.Combine(TestPaths.CreateDataDirectory(), name);
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

    private sealed class CollectingLoggerProvider : ILoggerProvider
    {
        public ConcurrentQueue<string> Messages { get; } = [];

        public ILogger CreateLogger(string categoryName)
        {
            return new CollectingLogger(Messages);
        }

        public void Dispose()
        {
        }

        private sealed class CollectingLogger(ConcurrentQueue<string> messages) : ILogger
        {
            public IDisposable? BeginScope<TState>(TState state)
                where TState : notnull
            {
                return null;
            }

            public bool IsEnabled(LogLevel logLevel)
            {
                return true;
            }

            public void Log<TState>(
                LogLevel logLevel,
                EventId eventId,
                TState state,
                Exception? exception,
                Func<TState, Exception?, string> formatter)
            {
                messages.Enqueue(formatter(state, exception));
            }
        }
    }
}
