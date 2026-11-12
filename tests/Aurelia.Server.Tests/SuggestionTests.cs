using System.Net;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Aurelia.Server.Services.Suggestions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>What to watch next, with an invented library; no media is read and no provider is asked.</summary>
public sealed class SuggestionTests
{
    private static readonly SuggestionFranchise ToyTales = new("tmdb:1", "Toy Tale Collection", true);
    private static readonly SuggestionFranchise Universe = new("universe:sky", "Sky Universe", false);

    private static SuggestionTitle Title(string name, string? release = null, string[]? genres = null, string[]? keywords = null,
        SuggestionFranchise[]? franchises = null, string[]? people = null, string[]? makers = null, string[]? studios = null, int? age = null,
        MediaKind kind = MediaKind.Movie) =>
        new(Guid.NewGuid(), kind, name, release, genres ?? [], studios ?? [], keywords ?? [], franchises ?? [], people ?? [], makers ?? [], age);

    [Fact]
    public void TheNextFilmOfASeriesComesFarAheadThenTheFranchiseThenRareKeywords()
    {
        var first = Title("Toy Tale", "1995-11-22", ["Animation", "Comedy"], ["toys", "friendship"], [ToyTales], age: 0);
        var second = Title("Toy Tale 2", "1999-11-24", ["Animation", "Comedy"], ["toys"], [ToyTales], age: 0);
        var third = Title("Toy Tale 3", "2010-06-18", ["Animation", "Comedy"], ["toys"], [ToyTales], age: 0);
        var rangers = Title("Space Rangers", "2022-06-17", ["Animation"], ["toys", "space"], age: 0);
        var comedy = Title("Office Laughs", "2005-03-01", ["Comedy"], ["office"], age: 0);
        var cellar = Title("Night Cellar", "2018-10-31", ["Horror"], ["friendship"], age: 18);
        var library = new[] { first, second, third, rangers, comedy, cellar };
        var rarity = SuggestionScoring.Weigh(library);

        var ranked = SuggestionScoring.Rank(first, library, new HashSet<Guid> { first.Id }, rarity, 10);
        Assert.Equal([second.Id, third.Id, rangers.Id], ranked.Take(3).Select(scored => scored.Title.Id));
        Assert.Equal((MediaSuggestionKind.NextPart, "Next in Toy Tale Collection"), (ranked[0].Kind, ranked[0].Reason));
        Assert.Equal((MediaSuggestionKind.Franchise, "Also in Toy Tale Collection"), (ranked[1].Kind, ranked[1].Reason));
        Assert.Equal(MediaSuggestionKind.Keywords, ranked[2].Kind);
        Assert.Equal("Also about toys", ranked[2].Reason);
        // A horror film shares a keyword, but its rating is far from a children's film.
        Assert.DoesNotContain(ranked, scored => scored.Title.Id == cellar.Id);

        // With the second film watched, the third is next.
        var after = SuggestionScoring.Rank(first, library, new HashSet<Guid> { first.Id, second.Id }, rarity, 10);
        Assert.Equal(third.Id, after[0].Title.Id);
        Assert.Equal(MediaSuggestionKind.NextPart, after[0].Kind);
        Assert.DoesNotContain(after, scored => scored.Title.Id == second.Id);
    }

    [Fact]
    public void PeopleStudiosGenresAndTitlesExplainWhatTheyShare()
    {
        var seed = Title("Harbor Lights", genres: ["Drama", "Western"], people: ["Ada Stone", "Ben Field"], makers: ["Cleo Marsh"], studios: ["North Pictures"]);
        var director = Title("Quiet Valley", genres: ["Drama"], makers: ["Cleo Marsh"]);
        var actors = Title("River Bend", people: ["Ben Field", "Ada Stone"]);
        var western = Title("Dust Road", genres: ["Western"]);
        var drama = Title("Grey Rooms", genres: ["Drama"]);
        var sequel = Title("Harbor Lights Returns");
        var library = new[] { seed, director, actors, western, drama, sequel, Title("A"), Title("B"), Title("C", genres: ["Drama"]) };
        var rarity = SuggestionScoring.Weigh(library);

        Assert.Equal("Also directed by Cleo Marsh", SuggestionScoring.Score(seed, director, rarity).Reason);
        Assert.Equal("Also with Ada Stone and Ben Field", SuggestionScoring.Score(seed, actors, rarity).Reason);
        Assert.Equal("Like Harbor Lights", SuggestionScoring.Score(seed, sequel, rarity).Reason);
        // A rare genre weighs more than a common one.
        Assert.True(SuggestionScoring.Score(seed, western, rarity).Score > SuggestionScoring.Score(seed, drama, rarity).Score);
        Assert.Equal("Also Western", SuggestionScoring.Score(seed, western, rarity).Reason);
        Assert.Equal(1, SuggestionScoring.TitleSimilarity("Toy Story", "Toy Story 2"));
        Assert.Equal(0, SuggestionScoring.TitleSimilarity("The Night", "A Day"));
        // A series by the same creator.
        var show = Title("Long Winter", makers: ["Dora Lane"], kind: MediaKind.Series);
        var other = Title("Short Summer", makers: ["Dora Lane"], kind: MediaKind.Series);
        Assert.Equal("Also by Dora Lane", SuggestionScoring.Score(show, other, rarity).Reason);
        // A universe has no order, so nothing in it is "next".
        var sky = Title("Sky One", "2001", franchises: [Universe]);
        var skyTwo = Title("Sky Two", "2003", franchises: [Universe]);
        Assert.Empty(SuggestionScoring.NextParts(sky, [sky, skyTwo], new HashSet<Guid>()));
        Assert.Equal("Also in Sky Universe", SuggestionScoring.Score(sky, skyTwo, rarity).Reason);
    }

    [Fact]
    public async Task SuggestionsAndHomeRailsFollowTheProfilesAccessAndHistory()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using (var capabilities = await client.GetAsync("/api/v1/capabilities"))
        {
            Assert.Contains(ServerFeatures.Suggestions, (await ApiTestClient.ReadAsync<ClientCapabilitiesResponse>(capabilities)).Capabilities);
        }
        var ids = await SeedLibraryAsync(factory);
        await WatchAsync(factory, owner.User.Id, ids["Toy Tale"]);

        var suggestions = await GetAsync<MediaSuggestionsResponse>(client, owner.Token, $"/api/v1/media/{ids["Toy Tale"]}/suggestions?limit=5");
        Assert.Equal(ids["Toy Tale 2"], suggestions.Suggestions[0].Item.Id);
        Assert.Equal((MediaSuggestionKind.NextPart, "Next in Toy Tale Collection"), (suggestions.Suggestions[0].Kind, suggestions.Suggestions[0].Reason));
        Assert.DoesNotContain(suggestions.Suggestions, suggestion => suggestion.Item.Id == ids["Toy Tale"]);
        Assert.True(suggestions.Suggestions.Count <= 5);
        // An episode's suggestions are its series'.
        var episode = await GetAsync<MediaSuggestionsResponse>(client, owner.Token, $"/api/v1/media/{ids["Sky Show E1"]}/suggestions");
        Assert.Equal(ids["Sky Two"], Assert.Single(episode.Suggestions, suggestion => suggestion.Kind == MediaSuggestionKind.Franchise).Item.Id);
        using (var invalid = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/media/{ids["Toy Tale"]}/suggestions?limit=99", owner.Token))
        using (var response = await client.SendAsync(invalid))
        {
            Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        }

        // Home: a rail for the watched film, and the hour's title from the personal top ten.
        var home = await GetAsync<HomeResponse>(client, owner.Token, "/api/v1/home");
        var rail = Assert.Single(home.BecauseYouWatched!);
        Assert.Equal((ids["Toy Tale"], "Toy Tale"), (rail.SourceId, rail.SourceTitle));
        Assert.Equal(ids["Toy Tale 2"], rail.Suggestions[0].Item.Id);
        Assert.Contains(home.Recommendation!.Id, rail.Suggestions.Select(suggestion => suggestion.Item.Id));

        // A children's profile never sees a title above its age, not even as a suggestion.
        using (var created = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
                   new CreateUserRequest("Mia", null, UserRole.User, ApiTestClient.TestPin, AgeLimit: 6)))
        using (var response = await ApiTestClient.SendAsync(client, created))
        {
            var child = await ApiTestClient.ReadAsync<UserSummary>(response);
            await WatchAsync(factory, child.Id, ids["Toy Tale"]);
            var session = await ChildSessionAsync(client, child.Id);
            var json = await GetTextAsync(client, session, $"/api/v1/media/{ids["Toy Tale"]}/suggestions?limit=30");
            Assert.DoesNotContain("Night Cellar", json, StringComparison.Ordinal);
            Assert.Contains("Toy Tale 2", json, StringComparison.Ordinal);
            Assert.DoesNotContain("Night Cellar", await GetTextAsync(client, session, "/api/v1/home"), StringComparison.Ordinal);
            using var hidden = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/media/{ids["Night Cellar"]}/suggestions", session);
            using var refused = await client.SendAsync(hidden);
            Assert.Equal(HttpStatusCode.NotFound, refused.StatusCode);
        }
    }

    private static async Task<Dictionary<string, Guid>> SeedLibraryAsync(AureliaServerFactory factory)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = DateTimeOffset.UtcNow;
        var root = Path.Combine(factory.DataDirectory, "Invented Suggestions");
        Directory.CreateDirectory(root);
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Invented library",
            Path = root,
            NormalizedPath = MediaPath.Normalize(root),
            Kind = LibraryKind.Automatic,
            Availability = LibraryAvailability.Available,
            CreatedAt = now,
        };
        database.LibraryRoots.Add(library);
        var ids = new Dictionary<string, Guid>();
        MediaItem Add(string title, MediaKind kind, string release, string rating, string[] genres, string[] keywords, MediaItem? parent = null)
        {
            var path = Path.Combine(root, title + ".mkv");
            var item = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                Kind = kind,
                DetectedTitle = title,
                SourcePath = path,
                NormalizedSourcePath = MediaPath.Normalize(path),
                Extension = ".mkv",
                FileSize = 4,
                FileModifiedAt = now,
                Availability = MediaAvailability.Available,
                CreatedAt = now,
                UpdatedAt = now,
                Category = string.Empty,
                ParentId = parent?.Id,
                SeasonNumber = kind == MediaKind.Episode ? 1 : null,
                EpisodeNumber = kind == MediaKind.Episode ? 1 : null,
            };
            item.Metadata = new MediaMetadata
            {
                MediaItemId = item.Id,
                UpdatedAt = now,
                ProviderTitle = title,
                ProviderReleaseDate = release,
                ProviderContentRating = rating,
                ProviderGenresJson = MetadataPresentation.SerializeList(genres),
            };
            database.MediaKeywords.Add(new MediaKeywords { MediaItemId = item.Id, KeywordsJson = MetadataPresentation.SerializeList(keywords), UpdatedAt = now });
            database.MediaItems.Add(item);
            ids[title] = item.Id;
            return item;
        }
        var films = new[]
        {
            Add("Toy Tale", MediaKind.Movie, "1995-11-22", "FSK 0", ["Animation", "Comedy"], ["toys", "friendship"]),
            Add("Toy Tale 2", MediaKind.Movie, "1999-11-24", "FSK 0", ["Animation", "Comedy"], ["toys"]),
            Add("Toy Tale 3", MediaKind.Movie, "2010-06-18", "FSK 0", ["Animation", "Comedy"], ["toys"]),
        };
        Add("Space Rangers", MediaKind.Movie, "2022-06-17", "FSK 0", ["Animation"], ["toys", "space"]);
        Add("Night Cellar", MediaKind.Movie, "2018-10-31", "FSK 18", ["Animation", "Horror"], ["toys", "friendship"]);
        var skyTwo = Add("Sky Two", MediaKind.Movie, "2003-01-01", "FSK 12", ["Science Fiction"], ["ships"]);
        var show = Add("Sky Show", MediaKind.Series, "2004-01-01", "FSK 12", ["Science Fiction"], ["crew"]);
        Add("Sky Show E1", MediaKind.Episode, "2004-01-01", "FSK 12", [], [], show);
        Add("Office Laughs", MediaKind.Movie, "2005-03-01", "FSK 6", ["Comedy"], ["office"]);
        database.MediaCollections.Add(new MediaCollectionRecord
        {
            Id = Guid.NewGuid(),
            Name = "Toy Tale Collection",
            Provider = "tmdb",
            ProviderCollectionId = "1",
            CreatedAt = now,
            UpdatedAt = now,
            Members = [.. films.Select((film, index) => new MediaCollectionMember { MediaItemId = film.Id, SortOrder = index })],
        });
        database.MediaCollections.Add(new MediaCollectionRecord
        {
            Id = Guid.NewGuid(),
            Name = "Sky Universe",
            Provider = MediaUniverses.Provider,
            ProviderCollectionId = "sky",
            CreatedAt = now,
            UpdatedAt = now,
            Members = [new MediaCollectionMember { MediaItemId = skyTwo.Id, SortOrder = 0 }, new MediaCollectionMember { MediaItemId = show.Id, SortOrder = 1 }],
        });
        await database.SaveChangesAsync();
        return ids;
    }

    private static async Task WatchAsync(AureliaServerFactory factory, Guid userId, Guid mediaId)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var now = DateTimeOffset.UtcNow;
        database.PlaybackProgress.Add(new PlaybackProgress
        {
            Id = Guid.NewGuid(),
            MediaItemId = mediaId,
            MediaItem = await database.MediaItems.IgnoreQueryFilters().SingleAsync(item => item.Id == mediaId),
            UserId = userId,
            User = await database.Users.SingleAsync(user => user.Id == userId),
            PositionMilliseconds = 5_400_000,
            DurationMilliseconds = 5_400_000,
            IsCompleted = true,
            LastPlayedAt = now,
            UpdatedAt = now,
        });
        await database.SaveChangesAsync();
    }

    private static async Task<string> ChildSessionAsync(HttpClient client, Guid child)
    {
        using var login = await client.PostAsJsonAsync("/api/v1/auth/login",
            new LoginRequest("lucas", "correct horse battery staple", "Paired synthetic device"), ApiTestClient.JsonOptions);
        login.EnsureSuccessStatusCode();
        var device = await ApiTestClient.ReadAsync<AuthenticationResponse>(login);
        using var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/profiles/{child}/unlock", device.Token, new UnlockProfileRequest(ApiTestClient.TestPin));
        using var response = await ApiTestClient.SendAsync(client, request);
        response.EnsureSuccessStatusCode();
        return (await ApiTestClient.ReadAsync<ProfileSessionResponse>(response)).Token;
    }

    private static async Task<T> GetAsync<T>(HttpClient client, string token, string path)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, path, token);
        using var response = await client.SendAsync(request);
        Assert.True(response.IsSuccessStatusCode, $"{path}: {(int)response.StatusCode} {await response.Content.ReadAsStringAsync()}");
        return await ApiTestClient.ReadAsync<T>(response);
    }

    private static async Task<string> GetTextAsync(HttpClient client, string token, string path)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, path, token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsStringAsync();
    }
}
