using System.Net;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>Family wishlist, TMDB poster cache, age filtering, sync notifications and sleep-timer responses.</summary>
public sealed class WishTests
{
    private static readonly byte[] ValidJpeg = [0xff, 0xd8, 1, 2, 3, 4, 0xff, 0xd9, 0, 0, 0, 0, 0xff, 0xd9];

    [Fact]
    public async Task FamilyWishesMigrationHasNoPendingModelChangesAndUpgradesFromCollectionBoxSets()
    {
        var dataDirectory = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(dataDirectory);
        var databasePath = Path.Combine(dataDirectory, "aurelia.db");
        try
        {
            var options = new DbContextOptionsBuilder<AureliaDbContext>()
                .UseSqlite($"Data Source={databasePath}")
                .Options;
            await using (var preUpgrade = new AureliaDbContext(options))
            {
                await preUpgrade.Database.GetService<IMigrator>().MigrateAsync("20261113100000_CollectionBoxSets");
                Assert.Equal("20261113120000_FamilyWishes", (await preUpgrade.Database.GetPendingMigrationsAsync()).First());
            }

            using var factory = new AureliaServerFactory(dataDirectory);
            using var client = factory.CreateClient();
            using var health = await client.GetAsync("/api/v1/health");
            health.EnsureSuccessStatusCode();

            using var scope = factory.Services.CreateScope();
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            Assert.False(database.Database.HasPendingModelChanges());
            Assert.Empty(await database.Wishes.ToListAsync());
            Assert.Empty(await database.WishSupports.ToListAsync());

            var capabilities = await client.GetFromJsonAsync<ClientCapabilitiesResponse>("/api/v1/capabilities", ApiTestClient.JsonOptions);
            Assert.Contains(ServerFeatures.Wishes, capabilities!.Capabilities);
        }
        finally
        {
            if (Directory.Exists(dataDirectory))
                Directory.Delete(dataDirectory, recursive: true);
        }
    }

    [Fact]
    public async Task TmdbDisabledSearchReportsProviderDisabledAndManualWishesSurfaceAdminSuggestions()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var memberId = await CreateUserAsync(client, owner.Token, "Mia", UserRole.User, ageLimit: null);
        var memberToken = await UnlockAsync(client, memberId);

        using (var searchResponse = await SendAsync(client, memberToken, HttpMethod.Get, "/api/v1/wishes/search?query=Matrix&kind=movie"))
        {
            Assert.Equal(HttpStatusCode.Conflict, searchResponse.StatusCode);
            var problem = await ApiTestClient.ReadAsync<ApiProblem>(searchResponse);
            Assert.Equal("provider_disabled", problem.Code);
        }

        using var createdResponse = await SendAsync(client, memberToken, HttpMethod.Post, "/api/v1/wishes",
            new CreateWishRequest(MediaKind.Movie, "The Matrix", 1999, Note: "4K if possible"));
        Assert.Equal(HttpStatusCode.Created, createdResponse.StatusCode);
        var created = await ApiTestClient.ReadAsync<CreateWishResponse>(createdResponse);
        Assert.False(created.MergedIntoExistingSupport);
        Assert.Null(created.Wish.Provider);

        await SeedMovieAsync(factory, "The Matrix", 1999, providerMediaId: null, ageRating: "FSK 16");

        // Admin sees the title+year match suggestion, while the wish stays open (no auto-fulfill without TMDB).
        var adminList = await ReadAsync<WishListResponse>(await SendAsync(client, owner.Token, HttpMethod.Get, "/api/v1/wishes"));
        Assert.False(adminList.ProviderEnabled);
        var adminWish = Assert.Single(adminList.Wishes);
        Assert.Equal(WishState.Open, adminWish.State);
        var suggestion = Assert.Single(adminWish.Suggestions);
        Assert.Equal("The Matrix", suggestion.Title);
        Assert.Equal(1999, suggestion.Year);

        // Non-admin member does not get admin match suggestions.
        var memberList = await ReadAsync<WishListResponse>(await SendAsync(client, memberToken, HttpMethod.Get, "/api/v1/wishes"));
        Assert.Empty(Assert.Single(memberList.Wishes).Suggestions);
    }

    [Fact]
    public async Task TmdbSearchDeduplicationSupportWithdrawAndAuthorizationWorkEndToEnd()
    {
        var provider = new FakeTmdbClient();
        using var factory = new AureliaServerFactory(configureServices: services =>
        {
            services.RemoveAll<ITmdbClient>();
            services.AddSingleton<ITmdbClient>(provider);
        });
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        await EnableTmdbAsync(client, owner.Token);

        var aliceId = await CreateUserAsync(client, owner.Token, "Alice", UserRole.User, ageLimit: null);
        var bobId = await CreateUserAsync(client, owner.Token, "Bob", UserRole.User, ageLimit: null);
        var aliceToken = await UnlockAsync(client, aliceId);
        var bobToken = await UnlockAsync(client, bobId);

        var existingMovieId = await SeedMovieAsync(factory, "Already Owned", 2020, providerMediaId: "100", ageRating: "FSK 12");
        await ApiTestClient.GrantExistingLibrariesAsync(client, owner.Token, aliceId);

        var search = await ReadAsync<WishSearchResponse>(
            await SendAsync(client, aliceToken, HttpMethod.Get, "/api/v1/wishes/search?query=Dune&kind=movie"));
        Assert.True(search.ProviderEnabled);
        Assert.Collection(search.Results,
            owned =>
            {
                Assert.Equal("100", owned.ProviderMediaId);
                Assert.True(owned.AlreadyInLibrary);
                Assert.Equal(existingMovieId, owned.ExistingMediaId);
            },
            wishable =>
            {
                Assert.Equal("200", wishable.ProviderMediaId);
                Assert.False(wishable.AlreadyInLibrary);
                Assert.Equal("/dune2.jpg", wishable.PosterPath);
                Assert.Contains("path=%2Fdune2.jpg", wishable.PosterUrl);
            });

        // Creating a wish for a title already in the library returns already_in_library + mediaId.
        using (var alreadyResponse = await SendAsync(client, aliceToken, HttpMethod.Post, "/api/v1/wishes",
            new CreateWishRequest(MediaKind.Movie, "Already Owned", 2020, "tmdb", "100")))
        {
            Assert.Equal(HttpStatusCode.Conflict, alreadyResponse.StatusCode);
            var conflict = await ApiTestClient.ReadAsync<WishAlreadyInLibraryProblem>(alreadyResponse);
            Assert.Equal("already_in_library", conflict.Code);
            Assert.Equal(existingMovieId, conflict.MediaId);
        }

        // Alice wishes Dune Part Two; server fetches age rating via GetAsync.
        var aliceCreate = await ReadAsync<CreateWishResponse>(
            await SendAsync(client, aliceToken, HttpMethod.Post, "/api/v1/wishes",
                new CreateWishRequest(MediaKind.Movie, "Dune Part Two", 2024, "tmdb", "200", "Desert sequel", "/dune2.jpg", "Weekend watch")));
        Assert.False(aliceCreate.MergedIntoExistingSupport);
        Assert.Equal("FSK 12", aliceCreate.Wish.AgeRating);
        Assert.Equal(12, aliceCreate.Wish.MinimumAge);
        Assert.Equal("Alice", aliceCreate.Wish.UserName);

        // Bob wishing the same TMDB ID merges into "Me Too" support rather than creating a second row.
        var bobDuplicate = await ReadAsync<CreateWishResponse>(
            await SendAsync(client, bobToken, HttpMethod.Post, "/api/v1/wishes",
                new CreateWishRequest(MediaKind.Movie, "Dune Part Two", 2024, "tmdb", "200")));
        Assert.True(bobDuplicate.MergedIntoExistingSupport);
        Assert.Equal(aliceCreate.Wish.Id, bobDuplicate.Wish.Id);
        Assert.True(bobDuplicate.Wish.SupportedByCaller);
        Assert.Equal("Bob", Assert.Single(bobDuplicate.Wish.Supporters).Name);

        // Bob cannot delete Alice's wish, and Alice cannot support her own wish.
        using (var forbiddenDelete = await SendAsync(client, bobToken, HttpMethod.Delete, $"/api/v1/wishes/{aliceCreate.Wish.Id}"))
            Assert.Equal(HttpStatusCode.Forbidden, forbiddenDelete.StatusCode);
        using (var ownSupport = await SendAsync(client, aliceToken, HttpMethod.Put, $"/api/v1/wishes/{aliceCreate.Wish.Id}/support", new SetWishSupportRequest(true)))
            Assert.Equal(HttpStatusCode.Conflict, ownSupport.StatusCode);

        // Bob toggles support off, and Member cannot resolve wishes (403).
        var afterUnsupport = await ReadAsync<WishSummary>(
            await SendAsync(client, bobToken, HttpMethod.Put, $"/api/v1/wishes/{aliceCreate.Wish.Id}/support", new SetWishSupportRequest(false)));
        Assert.False(afterUnsupport.SupportedByCaller);
        Assert.Empty(afterUnsupport.Supporters);

        using (var nonAdminResolve = await SendAsync(client, aliceToken, HttpMethod.Put, $"/api/v1/wishes/{aliceCreate.Wish.Id}/state",
            new UpdateWishStateRequest(WishState.Fulfilled)))
            Assert.Equal(HttpStatusCode.Forbidden, nonAdminResolve.StatusCode);

        // Alice can withdraw her open wish.
        using (var withdraw = await SendAsync(client, aliceToken, HttpMethod.Delete, $"/api/v1/wishes/{aliceCreate.Wish.Id}"))
            Assert.Equal(HttpStatusCode.NoContent, withdraw.StatusCode);

        var finalList = await ReadAsync<WishListResponse>(await SendAsync(client, owner.Token, HttpMethod.Get, "/api/v1/wishes"));
        Assert.Empty(finalList.Wishes);
    }

    [Fact]
    public async Task ChildProfilesSeeOwnWishesAndAllowedRatingsOnly()
    {
        var provider = new FakeTmdbClient();
        using var factory = new AureliaServerFactory(configureServices: services =>
        {
            services.RemoveAll<ITmdbClient>();
            services.AddSingleton<ITmdbClient>(provider);
        });
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        await EnableTmdbAsync(client, owner.Token);

        var childId = await CreateUserAsync(client, owner.Token, "Robin", UserRole.User, ageLimit: 12);
        var childToken = await UnlockAsync(client, childId);

        // Adult wishes FSK 18 (tmdb 300), FSK 6 (tmdb 400), and unrated free text.
        await ReadAsync<CreateWishResponse>(await SendAsync(client, owner.Token, HttpMethod.Post, "/api/v1/wishes",
            new CreateWishRequest(MediaKind.Movie, "Adult Action", 2024, "tmdb", "300", PosterPath: "/adult.jpg")));
        await ReadAsync<CreateWishResponse>(await SendAsync(client, owner.Token, HttpMethod.Post, "/api/v1/wishes",
            new CreateWishRequest(MediaKind.Movie, "Family Tale", 2024, "tmdb", "400", PosterPath: "/family.jpg")));
        await ReadAsync<CreateWishResponse>(await SendAsync(client, owner.Token, HttpMethod.Post, "/api/v1/wishes",
            new CreateWishRequest(MediaKind.Movie, "Mama Mystery", 2022)));

        // Child wishes an own unrated free-text film (must remain visible to the child).
        await ReadAsync<CreateWishResponse>(await SendAsync(client, childToken, HttpMethod.Post, "/api/v1/wishes",
            new CreateWishRequest(MediaKind.Movie, "Kid Sketch Film", 2023)));

        var childList = await ReadAsync<WishListResponse>(await SendAsync(client, childToken, HttpMethod.Get, "/api/v1/wishes"));
        Assert.Equal(["Kid Sketch Film", "Family Tale"], childList.Wishes.Select(wish => wish.Title).OrderBy(title => title, StringComparer.Ordinal).Reverse());
        Assert.DoesNotContain(childList.Wishes, wish => wish.Title is "Adult Action" or "Mama Mystery");
        Assert.Equal(0, childList.OpenCount);

        // Child cannot support Mama's FSK 18 wish directly or via duplicate POST.
        var ownerList = await ReadAsync<WishListResponse>(await SendAsync(client, owner.Token, HttpMethod.Get, "/api/v1/wishes"));
        var fsk18Id = ownerList.Wishes.Single(wish => wish.Title == "Adult Action").Id;

        using (var supportAdult = await SendAsync(client, childToken, HttpMethod.Put, $"/api/v1/wishes/{fsk18Id}/support", new SetWishSupportRequest(true)))
            Assert.Equal(HttpStatusCode.NotFound, supportAdult.StatusCode);

        using (var duplicateAdult = await SendAsync(client, childToken, HttpMethod.Post, "/api/v1/wishes",
            new CreateWishRequest(MediaKind.Movie, "Adult Action", 2024, "tmdb", "300")))
        {
            Assert.Equal(HttpStatusCode.Forbidden, duplicateAdult.StatusCode);
            Assert.Equal("wish_age_restricted", (await ApiTestClient.ReadAsync<ApiProblem>(duplicateAdult)).Code);
        }
    }

    [Fact]
    public async Task AutoFulfillOnMetadataApplyAdminResolutionBadgesAndSyncChangesWork()
    {
        var provider = new FakeTmdbClient();
        using var factory = new AureliaServerFactory(configureServices: services =>
        {
            services.RemoveAll<ITmdbClient>();
            services.AddSingleton<ITmdbClient>(provider);
        });
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        await EnableTmdbAsync(client, owner.Token);

        var aliceId = await CreateUserAsync(client, owner.Token, "Alice", UserRole.User, ageLimit: null);
        var adminId = await CreateUserAsync(client, owner.Token, "Papa", UserRole.Admin, ageLimit: null);
        var aliceToken = await UnlockAsync(client, aliceId);
        var adminToken = await UnlockAsync(client, adminId);

        var baselineAdminSync = await ReadAsync<SyncChangesResponse>(await SendAsync(client, adminToken, HttpMethod.Get, "/api/v1/sync/changes?after=0"));
        var baselineAliceSync = await ReadAsync<SyncChangesResponse>(await SendAsync(client, aliceToken, HttpMethod.Get, "/api/v1/sync/changes?after=0"));

        var wish = (await ReadAsync<CreateWishResponse>(await SendAsync(client, aliceToken, HttpMethod.Post, "/api/v1/wishes",
            new CreateWishRequest(MediaKind.Movie, "Dune Part Two", 2024, "tmdb", "200")))).Wish;

        var adminSummary = await ReadAsync<WishSummaryResponse>(await SendAsync(client, adminToken, HttpMethod.Get, "/api/v1/wishes/summary"));
        Assert.Equal(1, adminSummary.OpenCount);
        Assert.Equal(0, adminSummary.NewlyFulfilledCount);

        var afterCreateSync = await ReadAsync<SyncChangesResponse>(
            await SendAsync(client, adminToken, HttpMethod.Get, $"/api/v1/sync/changes?after={baselineAdminSync.Cursor}"));
        Assert.Contains(SyncChangeArea.UserState, afterCreateSync.ChangedAreas);

        // Declined wish stays declined even when matching TMDB media enters later; reopened fulfills cleanly.
        var declined = await ReadAsync<WishSummary>(await SendAsync(client, adminToken, HttpMethod.Put, $"/api/v1/wishes/{wish.Id}/state",
            new UpdateWishStateRequest(WishState.Declined, "Already saw in cinema")));
        Assert.Equal(WishState.Declined, declined.State);
        Assert.Equal("Papa", declined.ResolvedByUserName);

        var reopened = await ReadAsync<WishSummary>(await SendAsync(client, adminToken, HttpMethod.Put, $"/api/v1/wishes/{wish.Id}/state",
            new UpdateWishStateRequest(WishState.Open)));
        Assert.Equal(WishState.Open, reopened.State);
        Assert.Null(reopened.ResolvedByUserId);

        // MetadataService.ApplyAsync applies TMDB match "200" and auto-fulfills the open wish.
        var addedMediaId = await SeedMovieAsync(factory, "Dune Part Two", 2024, providerMediaId: null, ageRating: null);
        using (var scope = factory.Services.CreateScope())
        {
            var metadata = scope.ServiceProvider.GetRequiredService<MetadataService>();
            await metadata.SelectAsync(addedMediaId, new SelectMetadataMatchRequest("200", "movie"), CancellationToken.None);
        }

        var aliceSummary = await ReadAsync<WishSummaryResponse>(await SendAsync(client, aliceToken, HttpMethod.Get, "/api/v1/wishes/summary"));
        Assert.Equal(0, aliceSummary.OpenCount);
        Assert.Equal(1, aliceSummary.NewlyFulfilledCount);

        var aliceSync = await ReadAsync<SyncChangesResponse>(
            await SendAsync(client, aliceToken, HttpMethod.Get, $"/api/v1/sync/changes?after={baselineAliceSync.Cursor}"));
        Assert.Contains(SyncChangeArea.UserState, aliceSync.ChangedAreas);

        var aliceWishes = await ReadAsync<WishListResponse>(await SendAsync(client, aliceToken, HttpMethod.Get, "/api/v1/wishes"));
        var fulfilled = Assert.Single(aliceWishes.Wishes);
        Assert.Equal(WishState.Fulfilled, fulfilled.State);
        Assert.Equal(addedMediaId, fulfilled.FulfilledMediaItemId);

        using var seenResponse = await SendAsync(client, aliceToken, HttpMethod.Post, "/api/v1/wishes/seen");
        Assert.Equal(HttpStatusCode.NoContent, seenResponse.StatusCode);

        var afterSeenSummary = await ReadAsync<WishSummaryResponse>(await SendAsync(client, aliceToken, HttpMethod.Get, "/api/v1/wishes/summary"));
        Assert.Equal(0, afterSeenSummary.NewlyFulfilledCount);
    }

    [Fact]
    public async Task PosterProxyRestrictsUnknownPathsCachesWithEvictionAndAcceptsProfileCookie()
    {
        var provider = new FakeTmdbClient();
        using var factory = new AureliaServerFactory(configureServices: services =>
        {
            services.RemoveAll<ITmdbClient>();
            services.AddSingleton<ITmdbClient>(provider);
        });
        using var browserClient = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(browserClient);
        await EnableTmdbAsync(browserClient, owner.Token);

        // Unknown / arbitrary path must be rejected without calling TMDB.
        using (var unknown = await SendAsync(browserClient, owner.Token, HttpMethod.Get, "/api/v1/wishes/poster?path=/arbitrary-unknown.jpg&width=342"))
        {
            Assert.Equal(HttpStatusCode.NotFound, unknown.StatusCode);
            Assert.Equal(0, provider.ImageDownloads);
        }

        // Save a wish with /dune2.jpg and verify poster fetch + disk caching.
        await ReadAsync<CreateWishResponse>(await SendAsync(browserClient, owner.Token, HttpMethod.Post, "/api/v1/wishes",
            new CreateWishRequest(MediaKind.Movie, "Dune Part Two", 2024, "tmdb", "200", PosterPath: "/dune2.jpg")));

        using (var first = await SendAsync(browserClient, owner.Token, HttpMethod.Get, "/api/v1/wishes/poster?path=/dune2.jpg&width=342"))
        {
            first.EnsureSuccessStatusCode();
            Assert.Equal("image/jpeg", first.Content.Headers.ContentType?.MediaType);
            Assert.Equal(ValidJpeg, await first.Content.ReadAsByteArrayAsync());
        }
        using (var second = await SendAsync(browserClient, owner.Token, HttpMethod.Get, "/api/v1/wishes/poster?path=/dune2.jpg&width=342"))
        {
            second.EnsureSuccessStatusCode();
            Assert.Equal(ValidJpeg, await second.Content.ReadAsByteArrayAsync());
        }
        Assert.Equal(1, provider.ImageDownloads);

        // Web profile cookie works on <img src="/api/v1/wishes/poster?..."> without X-Aurelia-Web,
        // while /api/v1/wishes JSON still rejects cookie requests missing X-Aurelia-Web.
        using var pairingRequest = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/auth/pairings", owner.Token);
        using var pairingResponse = await ApiTestClient.SendAsync(browserClient, pairingRequest);
        pairingResponse.EnsureSuccessStatusCode();
        var pairingCode = await ApiTestClient.ReadAsync<PairingCodeResponse>(pairingResponse);

        using var webNoCookiesClient = factory.CreateClient(new Microsoft.AspNetCore.Mvc.Testing.WebApplicationFactoryClientOptions { HandleCookies = false });
        string deviceCookie;
        using (var webPair = new HttpRequestMessage(HttpMethod.Post, "/api/v1/web/pair"))
        {
            webPair.Headers.Add("X-Aurelia-Web", "device");
            webPair.Content = JsonContent.Create(new RedeemPairingCodeRequest(pairingCode.Code, "Browser"), options: ApiTestClient.JsonOptions);
            using var paired = await webNoCookiesClient.SendAsync(webPair);
            paired.EnsureSuccessStatusCode();
            deviceCookie = ExtractCookieValue(paired, "aurelia_device");
        }
        string profileCookie;
        using (var webUnlock = new HttpRequestMessage(HttpMethod.Post, $"/api/v1/web/profiles/{owner.User.Id}/unlock"))
        {
            webUnlock.Headers.Add("X-Aurelia-Web", "device");
            webUnlock.Headers.Add("Cookie", $"aurelia_device={deviceCookie}");
            webUnlock.Content = JsonContent.Create(new UnlockProfileRequest(ApiTestClient.TestPin), options: ApiTestClient.JsonOptions);
            using var unlocked = await webNoCookiesClient.SendAsync(webUnlock);
            unlocked.EnsureSuccessStatusCode();
            profileCookie = ExtractCookieValue(unlocked, "aurelia_profile");
        }
        using (var imgRequest = new HttpRequestMessage(HttpMethod.Get, "/api/v1/wishes/poster?path=/dune2.jpg&width=342"))
        {
            imgRequest.Headers.Add("Cookie", $"aurelia_profile={profileCookie}");
            using var imgResponse = await webNoCookiesClient.SendAsync(imgRequest);
            imgResponse.EnsureSuccessStatusCode();
            Assert.Equal(ValidJpeg, await imgResponse.Content.ReadAsByteArrayAsync());
        }
        using (var noCsrfHeader = new HttpRequestMessage(HttpMethod.Get, "/api/v1/wishes"))
        {
            noCsrfHeader.Headers.Add("Cookie", $"aurelia_profile={profileCookie}");
            using var denied = await webNoCookiesClient.SendAsync(noCsrfHeader);
            Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);
        }

        // Direct bounded cache eviction check with a 28-byte limit (each ValidJpeg is 14 bytes -> max 2 entries).
        var clock = new FakeClock(new DateTimeOffset(2026, 11, 13, 12, 0, 0, TimeSpan.Zero));
        using var scope = factory.Services.CreateScope();
        var runtime = scope.ServiceProvider.GetRequiredService<ServerRuntimeOptions>();
        var settings = scope.ServiceProvider.GetRequiredService<MetadataProviderSettingsStore>();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var smallCacheDir = Path.Combine(factory.DataDirectory, "SmallCacheTest");
        var smallRuntime = new ServerRuntimeOptions(smallCacheDir, runtime.DatabasePath, runtime.ListenUrl, runtime.ServerName, false, 0, "", "", null);
        var boundedCache = new WishPosterCache(smallRuntime, settings, provider, clock, maximumCacheBytes: 28);
        boundedCache.AllowRecent(["/one.jpg", "/two.jpg", "/three.jpg"]);

        foreach (var path in new[] { "/one.jpg", "/two.jpg", "/three.jpg" })
        {
            var item = await boundedCache.OpenAsync(path, 342, database, CancellationToken.None);
            Assert.NotNull(item);
            await item.Stream.DisposeAsync();
            clock.Advance(TimeSpan.FromSeconds(5));
        }

        var cacheFiles = Directory.GetFiles(Path.Combine(smallCacheDir, "WishPosters"));
        Assert.Equal(2, cacheFiles.Length);
        Assert.True(cacheFiles.Sum(file => new FileInfo(file).Length) <= 28);
    }

    [Theory]
    [InlineData("off", true)]
    [InlineData("stop", true)]
    [InlineData("sleep", true)]
    [InlineData("shutdown", true)]
    [InlineData("sleep", false)]
    public async Task SleepTimerEndedReturnsServerPowerModeAndDelay(string mode, bool afterSleepTimer)
    {
        var tempRoot = Directory.CreateTempSubdirectory("aurelia-sleep-response-");
        try
        {
            var runtime = new ServerRuntimeOptions(tempRoot.FullName, Path.Combine(tempRoot.FullName, "unused.db"),
                "http://127.0.0.1:0", "Synthetic", false, 0, "", "", null);
            var store = new ServerPowerSettingsStore(runtime, available: true);
            store.Update(new UpdateServerPowerSettingsRequest(mode, 15, null, null, AfterSleepTimer: afterSleepTimer));

            using var factory = new AureliaServerFactory(configureServices: services =>
            {
                services.RemoveAll<ServerPowerSettingsStore>();
                services.AddSingleton(store);
            });
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);

            using var response = await SendAsync(client, owner.Token, HttpMethod.Post, "/api/v1/playback/sleep-timer-ended");
            var body = await ReadAsync<SleepTimerEndedResponse>(response);
            Assert.Equal(mode, body.PowerMode);
            Assert.Equal(afterSleepTimer, body.AfterSleepTimer);
            Assert.Equal((int)ServerSleepSignal.Delay.TotalMinutes, body.Minutes);
        }
        finally
        {
            if (tempRoot.Exists)
                tempRoot.Delete(recursive: true);
        }
    }

    private static async Task EnableTmdbAsync(HttpClient client, string ownerToken)
    {
        using var response = await SendAsync(client, ownerToken, HttpMethod.Put, "/api/v1/metadata/provider",
            new UpdateMetadataProviderRequest(true, "en-US", "test-token-value-with-more-than-thirty-two-characters"));
        response.EnsureSuccessStatusCode();
    }

    private static async Task<Guid> CreateUserAsync(HttpClient client, string ownerToken, string username, UserRole role, int? ageLimit)
    {
        using var response = await SendAsync(client, ownerToken, HttpMethod.Post, "/api/v1/users",
            new CreateUserRequest(username, null, role, ApiTestClient.TestPin, AgeLimit: ageLimit));
        response.EnsureSuccessStatusCode();
        return (await ApiTestClient.ReadAsync<UserSummary>(response)).Id;
    }

    private static async Task<string> UnlockAsync(HttpClient client, Guid userId)
    {
        using var login = await client.PostAsJsonAsync("/api/v1/auth/login",
            new LoginRequest("lucas", "correct horse battery staple", "Device"), ApiTestClient.JsonOptions);
        login.EnsureSuccessStatusCode();
        var device = await ApiTestClient.ReadAsync<AuthenticationResponse>(login);
        using var unlock = await SendAsync(client, device.Token, HttpMethod.Post, $"/api/v1/profiles/{userId}/unlock",
            new UnlockProfileRequest(ApiTestClient.TestPin));
        unlock.EnsureSuccessStatusCode();
        return (await ApiTestClient.ReadAsync<ProfileSessionResponse>(unlock)).Token;
    }

    private static async Task<Guid> SeedMovieAsync(AureliaServerFactory factory, string title, int year, string? providerMediaId, string? ageRating)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = DateTimeOffset.UtcNow;
        var root = Path.Combine(factory.DataDirectory, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Synthetic Movies",
            Path = root,
            NormalizedPath = MediaPath.Normalize(root),
            Kind = LibraryKind.Movies,
            Availability = LibraryAvailability.Available,
            CreatedAt = now,
        };
        var filePath = Path.Combine(root, title + ".mkv");
        await File.WriteAllBytesAsync(filePath, [1, 2, 3, 4]);
        var media = new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRootId = library.Id,
            Kind = MediaKind.Movie,
            DetectedTitle = title,
            Year = year,
            SourcePath = filePath,
            NormalizedSourcePath = MediaPath.Normalize(filePath),
            Extension = ".mkv",
            FileSize = 4,
            FileModifiedAt = now,
            Availability = MediaAvailability.Available,
            CreatedAt = now,
            UpdatedAt = now,
        };
        if (providerMediaId is not null || ageRating is not null)
        {
            media.Metadata = new MediaMetadata
            {
                MediaItemId = media.Id,
                Provider = providerMediaId is not null ? "tmdb" : null,
                ProviderMediaId = providerMediaId,
                ProviderTitle = title,
                ProviderReleaseDate = $"{year}-01-01",
                ProviderContentRating = ageRating,
                ReviewState = providerMediaId is not null ? MetadataReviewState.Matched : MetadataReviewState.NeedsReview,
                UpdatedAt = now,
            };
        }

        database.LibraryRoots.Add(library);
        database.MediaItems.Add(media);
        await database.SaveChangesAsync();
        return media.Id;
    }

    private static async Task<HttpResponseMessage> SendAsync(HttpClient client, string token, HttpMethod method, string path, object? body = null)
    {
        using var request = ApiTestClient.Authorized(method, path, token, body);
        return await ApiTestClient.SendAsync(client, request);
    }

    private static async Task<T> ReadAsync<T>(HttpResponseMessage response)
    {
        using (response)
        {
            response.EnsureSuccessStatusCode();
            return await ApiTestClient.ReadAsync<T>(response);
        }
    }

    private static string ExtractCookieValue(HttpResponseMessage response, string cookieName)
    {
        var prefix = cookieName + "=";
        foreach (var header in response.Headers.GetValues("Set-Cookie"))
        {
            var first = header.Split(';', 2)[0].Trim();
            if (first.StartsWith(prefix, StringComparison.Ordinal))
                return first[prefix.Length..];
        }
        throw new InvalidOperationException($"Missing cookie {cookieName}.");
    }

    private sealed class FakeTmdbClient : ITmdbClient
    {
        public int ImageDownloads { get; private set; }

        public Task ValidateAsync(string token, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task<IReadOnlyList<MetadataCandidateSummary>> SearchAsync(
            string token,
            string language,
            MediaKind kind,
            string title,
            int? year,
            CancellationToken cancellationToken)
        {
            IReadOnlyList<MetadataCandidateSummary> results =
            [
                new("tmdb", "100", kind == MediaKind.Series ? "tv" : "movie", "Already Owned", null, 2020, "Owned", "/owned.jpg", 0.9),
                new("tmdb", "200", kind == MediaKind.Series ? "tv" : "movie", "Dune Part Two", null, 2024, "Desert sequel", "/dune2.jpg", 0.95),
            ];
            return Task.FromResult(results);
        }

        public Task<TmdbMetadata> GetAsync(
            string token,
            string language,
            string mediaType,
            string providerId,
            CancellationToken cancellationToken)
        {
            var (title, rating, poster) = providerId switch
            {
                "200" => ("Dune Part Two", "FSK 12", "/dune2.jpg"),
                "300" => ("Adult Action", "FSK 18", "/adult.jpg"),
                "400" => ("Family Tale", "FSK 6", "/family.jpg"),
                _ => ("Unknown Title", null, "/unknown.jpg"),
            };
            return Task.FromResult(new TmdbMetadata(
                providerId,
                mediaType,
                title,
                title,
                "Overview",
                "2024-03-01",
                120,
                8.0,
                rating,
                ["Drama"],
                [],
                [],
                poster,
                null,
                [],
                null));
        }

        public Task<IReadOnlyList<TmdbEpisodeMetadata>> GetEpisodesAsync(
            string token,
            string language,
            string seriesProviderId,
            int seasonNumber,
            CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<TmdbEpisodeMetadata>>([]);

        public Task<byte[]> DownloadImageAsync(
            string token,
            string providerPath,
            string size,
            CancellationToken cancellationToken)
        {
            ImageDownloads++;
            return Task.FromResult<byte[]>([.. ValidJpeg]);
        }
    }

    private sealed class FakeClock(DateTimeOffset now) : TimeProvider
    {
        private DateTimeOffset current = now;
        public override DateTimeOffset GetUtcNow() => current;
        public void Advance(TimeSpan delta) => current = current.Add(delta);
    }
}
