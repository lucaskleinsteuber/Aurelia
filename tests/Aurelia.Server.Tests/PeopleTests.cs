using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>People ("people-v1"): the library's people with search, and a person's life from TMDB. Invented data only.</summary>
public sealed class PeopleTests
{
    [Fact]
    public async Task ThePeopleListPutsThoseInMostTitlesFirstAndFindsThemByName()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        await SeedAsync(factory);

        var all = await GetAsync<PeoplePageResponse>(client, owner.Token, "/api/v1/people");
        Assert.Equal(3, all.Total);
        Assert.Equal(["Morgan Vale", "Ines Varga", "Theo Brandt"], all.Items.Select(person => person.Name));
        Assert.Equal([3, 2, 1], all.Items.Select(person => person.TitleCount));
        Assert.Equal("tmdb:person:17", all.Items[0].PersonKey);
        Assert.Equal("Acting", all.Items[0].Department);
        Assert.Equal("Director", all.Items[2].Department);
        Assert.DoesNotContain(all.Items, person => person.Name == "Typed By Hand");

        var found = await GetAsync<PeoplePageResponse>(client, owner.Token, "/api/v1/people?query=varg");
        Assert.Equal("Ines Varga", Assert.Single(found.Items).Name);

        var second = await GetAsync<PeoplePageResponse>(client, owner.Token, "/api/v1/people?offset=1&limit=1");
        Assert.Equal("Ines Varga", Assert.Single(second.Items).Name);
        Assert.Equal(3, second.Total);

        var info = await GetAsync<ServerInfoResponse>(client, owner.Token, "/api/v1/server/info");
        Assert.Contains(ServerFeatures.People, info.Capabilities ?? []);
    }

    [Fact]
    public async Task APersonsLifeComesFromTmdbOnceAndLeavesTheLibrarysTitlesOut()
    {
        var provider = new PeopleTmdb();
        using var factory = new AureliaServerFactory(configureServices: services =>
        {
            services.RemoveAll<ITmdbClient>();
            services.AddSingleton<ITmdbClient>(provider);
        });
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        await SeedAsync(factory);

        // Without TMDB the page has only the library's titles.
        var off = await GetAsync<PersonProfileResponse>(client, owner.Token, "/api/v1/people/profile?key=tmdb:person:17");
        Assert.Null(off.About);
        Assert.Empty(off.KnownFor);
        Assert.Equal(0, provider.Calls);

        using (var enable = ApiTestClient.Authorized(HttpMethod.Put, "/api/v1/metadata/provider", owner.Token,
            new UpdateMetadataProviderRequest(true, "en-US", "test-token-value-with-more-than-thirty-two-characters")))
        using (var enabled = await ApiTestClient.SendAsync(client, enable)) enabled.EnsureSuccessStatusCode();

        var profile = await GetAsync<PersonProfileResponse>(client, owner.Token, "/api/v1/people/profile?key=tmdb:person:17");
        Assert.NotNull(profile.About);
        Assert.Equal("An invented actor.", profile.About.Biography);
        Assert.Equal("1970-05-01", profile.About.Birthday);
        Assert.Equal("Invented Town", profile.About.PlaceOfBirth);
        Assert.Equal(["Distant Shore", "Night Ferry"], profile.KnownFor.Select(hit => hit.Title));
        Assert.Equal([MediaKind.Movie, MediaKind.Series], profile.KnownFor.Select(hit => hit.Kind));
        Assert.All(profile.KnownFor, hit => Assert.False(hit.AlreadyInLibrary));
        Assert.Contains("path=%2Fshore.jpg", profile.KnownFor[0].PosterUrl);

        // Kept for 30 days: opening the person again doesn't ask TMDB.
        await GetAsync<PersonProfileResponse>(client, owner.Token, "/api/v1/people/profile?key=tmdb:person:17");
        Assert.Equal(1, provider.Calls);

        // A key without a TMDB person has no profile.
        var unknown = await GetAsync<PersonProfileResponse>(client, owner.Token, "/api/v1/people/profile?key=unidentified:3");
        Assert.Null(unknown.About);
    }

    [Fact]
    public async Task AProfileSeesOnlyThePeopleOfTheTitlesItMaySee()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var titles = await SeedAsync(factory);

        // A profile that may see only "Paper Moons" meets only the one person in it.
        using (var create = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
            new CreateUserRequest("viewer", "another correct horse password", UserRole.User, ApiTestClient.TestPin,
                AccessMode: ProfileAccessMode.SelectedTitles, TitleIds: [titles["Paper Moons"]])))
        using (var created = await ApiTestClient.SendAsync(client, create)) created.EnsureSuccessStatusCode();
        using var login = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/auth/login", owner.Token,
            new LoginRequest("viewer", "another correct horse password", "Viewer Mac"));
        using var loginResponse = await ApiTestClient.SendAsync(client, login);
        loginResponse.EnsureSuccessStatusCode();
        var viewer = await ApiTestClient.ReadAsync<AuthenticationResponse>(loginResponse);

        var seen = await GetAsync<PeoplePageResponse>(client, viewer.Token, "/api/v1/people");
        var person = Assert.Single(seen.Items);
        Assert.Equal("Morgan Vale", person.Name);
        Assert.Equal(1, person.TitleCount);
        Assert.Empty((await GetAsync<PeoplePageResponse>(client, viewer.Token, "/api/v1/people?query=varga")).Items);
    }

    [Theory]
    [InlineData("tmdb:person:17419", "17419")]
    [InlineData("TMDB:person:5", "5")]
    [InlineData("tmdb:person:", null)]
    [InlineData("tmdb:person:12a", null)]
    [InlineData("imdb:person:nm1", null)]
    [InlineData(null, null)]
    public void OnlyTmdbPeopleHaveAProfile(string? key, string? expected) =>
        Assert.Equal(expected, PeopleService.ProviderPersonId(key));

    private static async Task<Dictionary<string, Guid>> SeedAsync(AureliaServerFactory factory)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = DateTimeOffset.UtcNow;
        var root = Path.Combine(factory.DataDirectory, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Invented Films",
            Path = root,
            NormalizedPath = MediaPath.Normalize(root),
            Kind = LibraryKind.Movies,
            Availability = LibraryAvailability.Available,
            CreatedAt = now,
        };
        database.LibraryRoots.Add(library);
        MediaItem Film(string title, string providerId, params (string Name, string? PersonId, string Department, string? Job)[] people)
        {
            var path = Path.Combine(root, title + ".mkv");
            File.WriteAllBytes(path, [1, 2, 3, 4]);
            var media = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                Kind = MediaKind.Movie,
                DetectedTitle = title,
                Year = 2020,
                SourcePath = path,
                NormalizedSourcePath = MediaPath.Normalize(path),
                Extension = ".mkv",
                FileSize = 4,
                FileModifiedAt = now,
                Availability = MediaAvailability.Available,
                CreatedAt = now,
                UpdatedAt = now,
            };
            media.Metadata = new MediaMetadata
            {
                MediaItemId = media.Id,
                Provider = "tmdb",
                ProviderMediaId = providerId,
                ProviderTitle = title,
                ReviewState = MetadataReviewState.Matched,
                UpdatedAt = now,
                Credits = people.Select((person, index) => new MediaCredit
                {
                    Id = Guid.NewGuid(),
                    MediaItemId = media.Id,
                    Name = person.Name,
                    ProviderPersonId = person.PersonId,
                    Department = person.Department,
                    Job = person.Job,
                    SortOrder = index,
                }).ToList(),
            };
            return media;
        }
        MediaItem[] films =
        [
            Film("Quiet Harbor", "100", ("Morgan Vale", "17", "Acting", null), ("Ines Varga", "19", "Acting", null), ("Typed By Hand", null, "Acting", null)),
            Film("Cobalt Run", "101", ("Morgan Vale", "17", "Acting", null), ("Ines Varga", "19", "Acting", null), ("Theo Brandt", "18", "Directing", "Director")),
            Film("Paper Moons", "102", ("Morgan Vale", "17", "Acting", null)),
        ];
        database.MediaItems.AddRange(films);
        await database.SaveChangesAsync();
        return films.ToDictionary(film => film.DetectedTitle, film => film.Id);
    }

    private static async Task<T> GetAsync<T>(HttpClient client, string token, string path)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, path, token);
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<T>(response);
    }

    private sealed class PeopleTmdb : ITmdbClient
    {
        public int Calls { get; private set; }

        public Task<TmdbPerson?> GetPersonAsync(string token, string language, string personId, CancellationToken cancellationToken)
        {
            Calls++;
            return Task.FromResult<TmdbPerson?>(new TmdbPerson(personId, "Morgan Vale", "An invented actor.", "1970-05-01", null,
                "Invented Town", "Acting", "/vale.jpg",
            [
                new("movie", "100", "Quiet Harbor", 2020, null, "/harbor.jpg", "Alex", 900, 9),
                new("movie", "200", "Distant Shore", 2018, "An invented film.", "/shore.jpg", "Sam", 800, 8),
                new("tv", "300", "Night Ferry", 2015, null, "/ferry.jpg", "Captain", 700, 7),
            ]));
        }

        public Task ValidateAsync(string token, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task<IReadOnlyList<MetadataCandidateSummary>> SearchAsync(string token, string language, MediaKind kind, string title, int? year, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<MetadataCandidateSummary>>([]);
        public Task<TmdbMetadata> GetAsync(string token, string language, string mediaType, string providerId, CancellationToken cancellationToken) =>
            throw new InvalidOperationException("Not used.");
        public Task<IReadOnlyList<TmdbEpisodeMetadata>> GetEpisodesAsync(string token, string language, string seriesProviderId, int seasonNumber, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<TmdbEpisodeMetadata>>([]);
        public Task<byte[]> DownloadImageAsync(string token, string providerPath, string size, CancellationToken cancellationToken) =>
            Task.FromResult<byte[]>([]);
    }
}
