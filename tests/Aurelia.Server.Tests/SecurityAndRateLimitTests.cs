using System.Net;
using System.Net.Http.Json;
using System.Security.Claims;
using Aurelia.Contracts;
using Aurelia.Server.Authentication;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class SecurityAndRateLimitTests
{
    [Fact]
    public async Task LegacyAccessEndpointRefusesAgeLimitedChildProfile()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        using var create = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
            new CreateUserRequest("Kid", null, UserRole.User, null, PinProtectionEnabled: false,
                AccessMode: ProfileAccessMode.EntireLibrary, AgeLimit: 12));
        using var createdResponse = await ApiTestClient.SendAsync(client, create);
        createdResponse.EnsureSuccessStatusCode();
        var kid = await ApiTestClient.ReadAsync<UserSummary>(createdResponse);

        using var legacy = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{kid.Id}/access", owner.Token,
            new UpdateUserAccessRequest(true, []));
        using var legacyResponse = await ApiTestClient.SendAsync(client, legacy);
        Assert.Equal(HttpStatusCode.Conflict, legacyResponse.StatusCode);
        var problem = await ApiTestClient.ReadAsync<ApiProblem>(legacyResponse);
        Assert.Equal("age_limit_active", problem.Code);
    }

    [Fact]
    public void RateLimitPartitionsGroupIpv6By64AndIsolateAuthenticatedSessionsAndWrites()
    {
        // SRV-SEC-004: IPv6 privacy addresses within the same /64 map to one key.
        var a = IPAddress.Parse("fd00:1234:5678:9abc::1");
        var b = IPAddress.Parse("fd00:1234:5678:9abc::beef");
        Assert.Equal(ServerRequestGuard.AddressKey(a), ServerRequestGuard.AddressKey(b));

        // DYN-API-009: Authenticated device sessions get separate authentication partitions per session and route.
        var ctxA = new DefaultHttpContext();
        ctxA.Connection.RemoteIpAddress = IPAddress.Loopback;
        ctxA.Request.Path = "/api/v1/profiles/11111111-1111-1111-1111-111111111111/unlock";
        ctxA.User = new ClaimsPrincipal(new ClaimsIdentity([new Claim(DeviceTokenAuthenticationHandler.SessionIdClaim, Guid.NewGuid().ToString())], "Bearer"));

        var ctxB = new DefaultHttpContext();
        ctxB.Connection.RemoteIpAddress = IPAddress.Loopback;
        ctxB.Request.Path = "/api/v1/profiles/11111111-1111-1111-1111-111111111111/unlock";
        ctxB.User = new ClaimsPrincipal(new ClaimsIdentity([new Claim(DeviceTokenAuthenticationHandler.SessionIdClaim, Guid.NewGuid().ToString())], "Bearer"));

        Assert.NotEqual(
            ServerRequestGuard.AuthenticationPartitionKey(ctxA),
            ServerRequestGuard.AuthenticationPartitionKey(ctxB));

        // DYN-LIFE-008: Loopback gets its larger budget and user-state writes stay isolated from read bursts.
        var guard = new ServerRequestGuard();
        var remote = IPAddress.Parse("192.168.1.50");
        for (var i = 0; i < ServerRequestGuard.RequestsPerMinute; i++)
            Assert.True(guard.Admit(remote));
        Assert.False(guard.Admit(remote));
        Assert.True(guard.Admit(remote, userStateWrite: true));

        for (var i = 0; i < ServerRequestGuard.RequestsPerMinute + 50; i++)
            Assert.True(guard.Admit(IPAddress.Loopback));

        // SRV-SEC-004: DeviceAuthorizationGuard caps pending pairings per /64 network.
        using var pairingGuard = new DeviceAuthorizationGuard(TimeProvider.System);
        var networkKey = ServerRequestGuard.AddressKey(a);
        var expires = DateTimeOffset.UtcNow.AddMinutes(5);
        for (var i = 0; i < DeviceAuthorizationGuard.MaxPendingPerAddress; i++)
            pairingGuard.ReservePending(networkKey, Guid.NewGuid(), expires);
        var overflow = Assert.Throws<AccountException>(() => pairingGuard.ReservePending(networkKey, Guid.NewGuid(), expires));
        Assert.Equal(429, overflow.StatusCode);
    }

    [Fact]
    public void WebCookiesUseHostPrefixOverHttpsAndFallbackToLegacyName()
    {
        var https = new DefaultHttpContext();
        https.Request.Scheme = "https";
        WebCookies.Set(https, WebCookies.Device, "tok-1", DateTimeOffset.UtcNow.AddDays(1));
        var setCookie = https.Response.Headers.SetCookie.ToString();
        Assert.Contains("__Host-aurelia_device=tok-1", setCookie, StringComparison.Ordinal);
        Assert.Contains("secure", setCookie, StringComparison.OrdinalIgnoreCase);

        var httpsRead = new DefaultHttpContext();
        httpsRead.Request.Scheme = "https";
        httpsRead.Request.Headers[WebCookies.Header] = "device";
        httpsRead.Request.Headers.Cookie = "__Host-aurelia_device=tok-host; aurelia_device=tok-old";
        Assert.Equal("tok-host", WebCookies.Credential(httpsRead.Request));

        var httpsLegacy = new DefaultHttpContext();
        httpsLegacy.Request.Scheme = "https";
        httpsLegacy.Request.Headers[WebCookies.Header] = "device";
        httpsLegacy.Request.Headers.Cookie = "aurelia_device=tok-old";
        Assert.Equal("tok-old", WebCookies.Credential(httpsLegacy.Request));
    }

    [Fact]
    public async Task ChildProfileWishSearchAndPeopleProfileFilterExternalTitlesAndBlockUnknownPeople()
    {
        var provider = new AgeFilteringTmdbClient();
        using var factory = new AureliaServerFactory(configureServices: services =>
        {
            services.RemoveAll<ITmdbClient>();
            services.AddSingleton<ITmdbClient>(provider);
        });
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        using (var enable = ApiTestClient.Authorized(HttpMethod.Put, "/api/v1/metadata/provider", owner.Token,
            new UpdateMetadataProviderRequest(true, "en-US", "test-token-value-with-more-than-thirty-two-characters")))
        using (var enabled = await ApiTestClient.SendAsync(client, enable)) enabled.EnsureSuccessStatusCode();

        // Seed a G-rated movie in the library with TMDB person 17.
        var mediaParent = TestPaths.CreateDataDirectory();
        Directory.CreateDirectory(mediaParent);
        try
        {
            using (var scope = factory.Services.CreateScope())
            {
                var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var now = DateTimeOffset.UtcNow;
                var lib = new LibraryRoot
                {
                    Id = Guid.NewGuid(),
                    Name = "Family",
                    Path = mediaParent,
                    NormalizedPath = MediaPath.Normalize(mediaParent),
                    Kind = LibraryKind.Movies,
                    Availability = LibraryAvailability.Available,
                    CreatedAt = now,
                };
                db.LibraryRoots.Add(lib);
                var file = Path.Combine(mediaParent, "Sunny Day (2020).mkv");
                await File.WriteAllBytesAsync(file, [1, 2, 3, 4]);
                var item = new MediaItem
                {
                    Id = Guid.NewGuid(),
                    LibraryRootId = lib.Id,
                    Kind = MediaKind.Movie,
                    DetectedTitle = "Sunny Day",
                    Year = 2020,
                    SourcePath = file,
                    NormalizedSourcePath = MediaPath.Normalize(file),
                    Extension = ".mkv",
                    FileSize = 4,
                    FileModifiedAt = now,
                    Availability = MediaAvailability.Available,
                    CreatedAt = now,
                    UpdatedAt = now,
                };
                item.Metadata = new MediaMetadata
                {
                    MediaItemId = item.Id,
                    Provider = "tmdb",
                    ProviderMediaId = "10",
                    ProviderTitle = "Sunny Day",
                    ProviderContentRating = "FSK 0",
                    ReviewState = MetadataReviewState.Matched,
                    UpdatedAt = now,
                    Credits =
                    [
                        new MediaCredit
                        {
                            Id = Guid.NewGuid(),
                            MediaItemId = item.Id,
                            Name = "Family Actor",
                            ProviderPersonId = "17",
                            Department = "Acting",
                            SortOrder = 0,
                        },
                    ],
                };
                db.MediaItems.Add(item);
                await db.SaveChangesAsync();
            }

            // Create a child profile with FSK 6 limit and open a profile session for it.
            using var createKid = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
                new CreateUserRequest("Kid", null, UserRole.User, null, PinProtectionEnabled: false,
                    AccessMode: ProfileAccessMode.EntireLibrary, AgeLimit: 6));
            using var kidResp = await ApiTestClient.SendAsync(client, createKid);
            kidResp.EnsureSuccessStatusCode();
            var kid = await ApiTestClient.ReadAsync<UserSummary>(kidResp);

            using var loginResp = await client.PostAsJsonAsync("/api/v1/auth/login",
                new LoginRequest(owner.User.Username, "correct horse battery staple", "Kid Device"), ApiTestClient.JsonOptions);
            loginResp.EnsureSuccessStatusCode();
            var deviceAuth = await ApiTestClient.ReadAsync<AuthenticationResponse>(loginResp);

            using var unlockKid = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/profiles/{kid.Id}/unlock", deviceAuth.Token,
                new UnlockProfileRequest(null));
            using var unlockResp = await ApiTestClient.SendAsync(client, unlockKid);
            unlockResp.EnsureSuccessStatusCode();
            var kidSession = await ApiTestClient.ReadAsync<ProfileSessionResponse>(unlockResp);

            // Wish search for child returns only titles rated <= FSK 6 (hides FSK 18 and unrated).
            using var searchReq = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/wishes/search?query=test&kind=movie", kidSession.Token);
            using var searchResp = await ApiTestClient.SendAsync(client, searchReq);
            searchResp.EnsureSuccessStatusCode();
            var results = await ApiTestClient.ReadAsync<WishSearchResponse>(searchResp);
            var kept = Assert.Single(results.Results);
            Assert.Equal("Safe Cartoon", kept.Title);

            // Child cannot see external "Known for" credits on a person page.
            using var personReq = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/people/profile?key=tmdb:person:17", kidSession.Token);
            using var personResp = await ApiTestClient.SendAsync(client, personReq);
            personResp.EnsureSuccessStatusCode();
            var personProfile = await ApiTestClient.ReadAsync<PersonProfileResponse>(personResp);
            Assert.NotNull(personProfile.About);
            Assert.Empty(personProfile.KnownFor);

            // Unknown person IDs not present in library credits never call TMDB.
            var callsBefore = provider.PersonCalls;
            using var unknownReq = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/people/profile?key=tmdb:person:99999", owner.Token);
            using var unknownResp = await ApiTestClient.SendAsync(client, unknownReq);
            unknownResp.EnsureSuccessStatusCode();
            var unknownProfile = await ApiTestClient.ReadAsync<PersonProfileResponse>(unknownResp);
            Assert.Null(unknownProfile.About);
            Assert.Equal(callsBefore, provider.PersonCalls);
        }
        finally
        {
            if (Directory.Exists(mediaParent)) Directory.Delete(mediaParent, recursive: true);
        }
    }

    private sealed class AgeFilteringTmdbClient : ITmdbClient
    {
        public int PersonCalls { get; private set; }

        public Task ValidateAsync(string token, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task<IReadOnlyList<MetadataCandidateSummary>> SearchAsync(string token, string language, MediaKind kind, string title, int? year, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<MetadataCandidateSummary>>(
            [
                new("tmdb", "101", "movie", "Safe Cartoon", null, 2022, "Friendly", "/safe.jpg", 0.9),
                new("tmdb", "102", "movie", "Horror Movie", null, 2022, "Scary", "/horror.jpg", 0.8),
                new("tmdb", "103", "movie", "Unrated Movie", null, 2022, "Unknown", "/unrated.jpg", 0.7),
            ]);

        public Task<TmdbMetadata> GetAsync(string token, string language, string mediaType, string providerId, CancellationToken cancellationToken) =>
            Task.FromResult(providerId switch
            {
                "101" => new TmdbMetadata("101", mediaType, "Safe Cartoon", null, "Friendly", "2022-01-01", 90, 7.5, "FSK 0", [], [], [], "/safe.jpg", null, [], null),
                "102" => new TmdbMetadata("102", mediaType, "Horror Movie", null, "Scary", "2022-01-01", 95, 7.0, "FSK 18", [], [], [], "/horror.jpg", null, [], null),
                _ => new TmdbMetadata(providerId, mediaType, "Unrated Movie", null, "Unknown", "2022-01-01", 95, 6.5, null, [], [], [], "/unrated.jpg", null, [], null),
            });

        public Task<IReadOnlyList<TmdbEpisodeMetadata>> GetEpisodesAsync(string token, string language, string seriesProviderId, int seasonNumber, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<TmdbEpisodeMetadata>>([]);

        public Task<TmdbPerson?> GetPersonAsync(string token, string language, string personId, CancellationToken cancellationToken)
        {
            PersonCalls++;
            return Task.FromResult<TmdbPerson?>(new TmdbPerson(
                personId, "Family Actor", "Bio", "1980-01-01", null, "Town", "Acting", "/actor.jpg",
                [new TmdbPersonCredit("movie", "102", "Horror Movie", 2022, "Scary", "/horror.jpg", "Lead", 100, 10)]));
        }

        public Task<byte[]> DownloadImageAsync(string token, string providerPath, string size, CancellationToken cancellationToken) =>
            Task.FromResult(Array.Empty<byte>());
    }
}
