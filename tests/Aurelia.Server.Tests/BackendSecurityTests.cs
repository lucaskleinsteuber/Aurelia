using System.Net;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class BackendSecurityTests
{
    [Fact]
    public async Task NormalUserCannotReadAdminResourcesOrLocalLibraryPaths()
    {
        var root = Path.Combine(
            TestPaths.CreateDataDirectory(),
            $"Aurelia-Private-Path-Sentinel-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        var mediaPath = Path.Combine(root, $"DoNotExpose-{Guid.NewGuid():N}.mkv");
        await File.WriteAllBytesAsync(mediaPath, [1, 2, 3, 4]);

        try
        {
            using var factory = new AureliaServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            var libraryId = await AddPrivateMediaAsync(factory, root, mediaPath);
            await CreateUserAsync(client, owner.Token);
            var viewer = await LoginViewerAsync(client);
            await ApiTestClient.GrantExistingLibrariesAsync(client, owner.Token, viewer.User.Id);

            foreach (var path in new[]
                     {
                         "/api/v1/users",
                         "/api/v1/libraries",
                         "/api/v1/metadata/provider",
                     })
            {
                using var anonymous = await client.GetAsync(path);
                Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);

                using var userRequest = ApiTestClient.Authorized(HttpMethod.Get, path, viewer.Token);
                using var userResponse = await ApiTestClient.SendAsync(client, userRequest);
                Assert.Equal(HttpStatusCode.Forbidden, userResponse.StatusCode);

                using var ownerRequest = ApiTestClient.Authorized(HttpMethod.Get, path, owner.Token);
                using var ownerResponse = await ApiTestClient.SendAsync(client, ownerRequest);
                Assert.Equal(HttpStatusCode.OK, ownerResponse.StatusCode);
            }

            using (var userLibrary = ApiTestClient.Authorized(
                       HttpMethod.Get,
                       $"/api/v1/libraries/{libraryId}/scans",
                       viewer.Token))
            using (var userLibraryResponse = await ApiTestClient.SendAsync(client, userLibrary))
            {
                Assert.Equal(HttpStatusCode.Forbidden, userLibraryResponse.StatusCode);
            }

            foreach (var path in new[]
                     {
                         "/api/v1/catalog/items?limit=50",
                         $"/api/v1/catalog/items/{await FindMediaIdAsync(factory)}",
                         "/api/v1/catalog/search?query=Privacy%20Film",
                         "/api/v1/home",
                     })
            {
                using var request = ApiTestClient.Authorized(HttpMethod.Get, path, viewer.Token);
                using var response = await ApiTestClient.SendAsync(client, request);
                Assert.Equal(HttpStatusCode.OK, response.StatusCode);
                var json = await response.Content.ReadAsStringAsync();
                Assert.DoesNotContain(root, json, StringComparison.Ordinal);
                Assert.DoesNotContain(Path.GetFileName(mediaPath), json, StringComparison.Ordinal);
            }

            using var ownerLibraryRequest = ApiTestClient.Authorized(
                HttpMethod.Get,
                "/api/v1/libraries",
                owner.Token);
            using var ownerLibraryResponse = await ApiTestClient.SendAsync(client, ownerLibraryRequest);
            var ownerJson = await ownerLibraryResponse.Content.ReadAsStringAsync();
            Assert.Contains(root, ownerJson, StringComparison.Ordinal);
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    [Fact]
    public async Task ExpiredDeviceSessionCannotCallAuthenticatedEndpoints()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var session = await ApiTestClient.SetupOwnerAsync(client);

        using (var scope = factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var storedSession = await database.DeviceSessions.SingleAsync(
                candidate => candidate.Id == session.SessionId);
            storedSession.ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(-1);
            await database.SaveChangesAsync();
        }

        using var request = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/auth/me", session.Token);
        using var response = await ApiTestClient.SendAsync(client, request);
        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    private static async Task<Guid> AddPrivateMediaAsync(
        AureliaServerFactory factory,
        string root,
        string mediaPath)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = DateTimeOffset.UtcNow;
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Privacy Test Library",
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
            SourcePath = mediaPath,
            NormalizedSourcePath = MediaPath.Normalize(mediaPath),
            DetectedTitle = "Privacy Film",
            Category = string.Empty,
            Extension = ".mkv",
            FileSize = new FileInfo(mediaPath).Length,
            FileModifiedAt = new DateTimeOffset(File.GetLastWriteTimeUtc(mediaPath), TimeSpan.Zero),
            Availability = MediaAvailability.Available,
            CreatedAt = now,
            UpdatedAt = now,
        };
        database.MediaItems.Add(media);
        await database.SaveChangesAsync();
        await scope.ServiceProvider.GetRequiredService<MediaSearchIndexService>()
            .RebuildAsync(CancellationToken.None);
        return media.Id;
    }

    private static async Task<Guid> FindMediaIdAsync(AureliaServerFactory factory)
    {
        using var scope = factory.Services.CreateScope();
        return await scope.ServiceProvider.GetRequiredService<AureliaDbContext>()
            .MediaItems.Select(media => media.Id).SingleAsync();
    }

    private static async Task CreateUserAsync(HttpClient client, string ownerToken)
    {
        using var request = ApiTestClient.Authorized(
            HttpMethod.Post,
            "/api/v1/users",
            ownerToken,
            new CreateUserRequest("privacy-viewer", "secure privacy viewer password", UserRole.User, ApiTestClient.TestPin));
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
    }

    private static async Task<AuthenticationResponse> LoginViewerAsync(HttpClient client)
    {
        using var response = await ApiTestClient.LoginAsync(client, new LoginRequest("privacy-viewer", "secure privacy viewer password", "Privacy Test Client"));
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<AuthenticationResponse>(response);
    }
}
