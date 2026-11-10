using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using SkiaSharp;
using Xunit;

namespace Aurelia.Server.Tests;

/// <summary>Display names, profile pictures and children's profiles limited by FSK age.</summary>
public sealed class ProfilePersonalizationTests
{
    [Fact]
    public async Task ChildrenSeeOnlyTitlesRatedForTheirAgeAndTheirExceptions()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var library = await LibraryAsync(factory);
        var kids = await SeedAsync(factory, library, MediaKind.Movie, "Bright Meadow", "FSK 0");
        var american = await SeedAsync(factory, library, MediaKind.Movie, "Harbor Lights", "PG");
        var teen = await SeedAsync(factory, library, MediaKind.Movie, "Silent Tower", "FSK 12");
        var adult = await SeedAsync(factory, library, MediaKind.Movie, "Night Cellar", "FSK 16");
        var unrated = await SeedAsync(factory, library, MediaKind.Movie, "Paper Comet", null);
        var cleared = await SeedAsync(factory, library, MediaKind.Movie, "Cleared Canyon", "FSK 0", manual: "");
        var allowed = await SeedAsync(factory, library, MediaKind.Movie, "Granted Glacier", "FSK 18");
        var hidden = await SeedAsync(factory, library, MediaKind.Movie, "Blocked Bay", "FSK 0");
        var show = await SeedAsync(factory, library, MediaKind.Series, "Puddle Friends", "TV-Y");
        var episode = await SeedAsync(factory, library, MediaKind.Episode, "Puddle Episode", null, show);
        var grownShow = await SeedAsync(factory, library, MediaKind.Series, "Dark Harbor", "TV-MA");
        var grownEpisode = await SeedAsync(factory, library, MediaKind.Episode, "Harbor Episode", null, grownShow);

        var child = await CreateAsync(client, owner.Token, new CreateUserRequest("Mia", null, UserRole.User, ApiTestClient.TestPin, AgeLimit: 6));
        Assert.Equal(6, child.AgeLimit);
        Assert.Equal(ProfileAccessMode.EntireLibrary, child.AccessMode);
        var limit = await ReadAsync<ProfileAgeLimitResponse>(await SendAsync(client, owner.Token, HttpMethod.Get, $"/api/v1/users/{child.Id}/age-limit"));
        var updated = await ReadAsync<ProfileAgeLimitResponse>(await SendAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{child.Id}/age-limit",
            new UpdateProfileAgeLimitRequest(6, [allowed.Id], [hidden.Id], limit.Revision)));
        Assert.Equal([allowed.Id], updated.AllowedTitleIds);
        Assert.Equal([hidden.Id], updated.HiddenTitleIds);
        Assert.True(updated.Revision > limit.Revision);

        var session = await ChildSessionAsync(client, child.Id);
        Seeded[] visible = [kids, american, allowed, show, episode];
        Seeded[] invisible = [teen, adult, unrated, cleared, hidden, grownShow, grownEpisode];
        foreach (var route in new[] { "/api/v1/catalog/items?limit=100", "/api/v1/catalog/movies?limit=100", "/api/v1/catalog/series?limit=100",
                     "/api/v1/catalog/search?query=a&limit=100", "/api/v1/home" })
        {
            using var response = await SendAsync(client, session, HttpMethod.Get, route);
            response.EnsureSuccessStatusCode();
            var json = await response.Content.ReadAsStringAsync();
            var leaks = invisible.Where(title => json.Contains(title.Title, StringComparison.Ordinal)).Select(title => title.Title).ToList();
            Assert.True(leaks.Count == 0, $"{route} shows {string.Join(", ", leaks)}");
        }
        using (var movies = await SendAsync(client, session, HttpMethod.Get, "/api/v1/catalog/movies?limit=100"))
        {
            var json = await movies.Content.ReadAsStringAsync();
            foreach (var title in new[] { kids, american, allowed }) Assert.Contains(title.Title, json, StringComparison.Ordinal);
        }
        foreach (var title in visible)
        {
            using var summary = await SendAsync(client, session, HttpMethod.Get, $"/api/v1/catalog/items/{title.Id}/summary");
            Assert.Equal(HttpStatusCode.OK, summary.StatusCode);
        }
        foreach (var title in invisible)
        {
            foreach (var route in new[] { $"/api/v1/catalog/items/{title.Id}/summary", $"/api/v1/catalog/items/{title.Id}",
                         $"/api/v1/media/{title.Id}/metadata", $"/api/v1/media/{title.Id}/progress", $"/api/v1/artwork/{title.ArtworkId}",
                         $"/api/v1/media/{title.Id}/notes" })
            {
                using var denied = await SendAsync(client, session, HttpMethod.Get, route);
                Assert.Equal(HttpStatusCode.NotFound, denied.StatusCode);
            }
            using var playback = await SendAsync(client, session, HttpMethod.Post, $"/api/v1/media/{title.Id}/playback");
            Assert.Equal(HttpStatusCode.NotFound, playback.StatusCode);
            using var favorite = await SendAsync(client, session, HttpMethod.Put, $"/api/v1/media/{title.Id}/favorite", new SetFavoriteRequest(true));
            Assert.Equal(HttpStatusCode.NotFound, favorite.StatusCode);
            using var progress = await SendAsync(client, session, HttpMethod.Put, $"/api/v1/media/{title.Id}/progress",
                new UpdatePlaybackProgressRequest(20_000, 300_000, false, Guid.NewGuid(), true, 0));
            Assert.Equal(HttpStatusCode.NotFound, progress.StatusCode);
        }
        // The owner still sees everything, and a children's profile cannot manage the server.
        using (var all = await SendAsync(client, owner.Token, HttpMethod.Get, "/api/v1/catalog/movies?limit=100"))
            Assert.Contains(adult.Title, await all.Content.ReadAsStringAsync(), StringComparison.Ordinal);
        using (var users = await SendAsync(client, session, HttpMethod.Get, "/api/v1/server/users"))
            Assert.Equal(HttpStatusCode.Forbidden, users.StatusCode);

        // Raising the limit shows more at once, in the session already open.
        var current = await ReadAsync<ProfileAgeLimitResponse>(await SendAsync(client, owner.Token, HttpMethod.Get, $"/api/v1/users/{child.Id}/age-limit"));
        (await SendAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{child.Id}/age-limit",
            new UpdateProfileAgeLimitRequest(12, [], [], current.Revision))).EnsureSuccessStatusCode();
        using (var teenSummary = await SendAsync(client, session, HttpMethod.Get, $"/api/v1/catalog/items/{teen.Id}/summary"))
            Assert.Equal(HttpStatusCode.OK, teenSummary.StatusCode);
        using (var stillHidden = await SendAsync(client, session, HttpMethod.Get, $"/api/v1/catalog/items/{adult.Id}/summary"))
            Assert.Equal(HttpStatusCode.NotFound, stillHidden.StatusCode);
        // Removing the limit makes it a normal profile with the whole library.
        current = await ReadAsync<ProfileAgeLimitResponse>(await SendAsync(client, owner.Token, HttpMethod.Get, $"/api/v1/users/{child.Id}/age-limit"));
        (await SendAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{child.Id}/age-limit",
            new UpdateProfileAgeLimitRequest(null, [], [], current.Revision))).EnsureSuccessStatusCode();
        using (var unlimited = await SendAsync(client, session, HttpMethod.Get, $"/api/v1/catalog/items/{unrated.Id}/summary"))
            Assert.Equal(HttpStatusCode.OK, unlimited.StatusCode);
    }

    // The access filters themselves read titles without filtering. That must not switch off the
    // filtering of the titles, progress or collection members a query reads after the first one.
    [Fact]
    public async Task EveryPartOfAQueryIsLimitedToTheProfilesTitles()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var library = await LibraryAsync(factory);
        var kids = await SeedAsync(factory, library, MediaKind.Movie, "Bright Meadow", "FSK 0");
        var adult = await SeedAsync(factory, library, MediaKind.Movie, "Night Cellar", "FSK 18");
        var child = await CreateAsync(client, owner.Token, new CreateUserRequest("Mia", null, UserRole.User, ApiTestClient.TestPin, AgeLimit: 6));
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        database.AccessUserId = child.Id;
        database.AccessMode = ProfileAccessMode.EntireLibrary;
        database.AccessAgeLimit = 6;

        Assert.Equal([1], await database.MediaItems.Where(item => item.Id == kids.Id)
            .Select(item => database.MediaItems.Count()).ToListAsync());
        Assert.Equal([0], await database.MediaItems.Where(item => item.Id == kids.Id)
            .Select(item => database.MediaItems.Count(other => other.Id == adult.Id)).ToListAsync());
        Assert.False(await database.MediaMetadata.Where(metadata => metadata.MediaItemId == kids.Id)
            .AnyAsync(metadata => database.MediaMetadata.Any(other => other.MediaItemId == adult.Id)));
    }

    // A shared collection's name tells what is in it. A profile that may see none of its titles
    // does not see the collection either.
    [Fact]
    public async Task SharedCollectionsWithoutAVisibleTitleStayHiddenFromChildren()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var library = await LibraryAsync(factory);
        var kids = await SeedAsync(factory, library, MediaKind.Movie, "Bright Meadow", "FSK 0");
        var adult = await SeedAsync(factory, library, MediaKind.Movie, "Night Cellar", "FSK 18");
        foreach (var (name, titles) in new[] { ("Cellar Marathon", new[] { adult.Id }), ("Family Evening", new[] { kids.Id, adult.Id }),
                     ("Planned Evening", Array.Empty<Guid>()) })
        {
            using var created = await SendAsync(client, owner.Token, HttpMethod.Post, "/api/v1/collections",
                new SaveCollectionRequest(name, titles, IsShared: true));
            created.EnsureSuccessStatusCode();
        }
        var child = await CreateAsync(client, owner.Token, new CreateUserRequest("Mia", null, UserRole.User, ApiTestClient.TestPin, AgeLimit: 6));
        var session = await ChildSessionAsync(client, child.Id);

        var seen = await ReadAsync<List<CollectionSummary>>(await SendAsync(client, session, HttpMethod.Get, "/api/v1/catalog/collections"));
        Assert.Equal(["Family Evening"], seen.Select(collection => collection.Name));
        var family = seen[0];
        Assert.Equal([kids.Id], family.Items.Select(item => item.Id));

        // Whoever manages the collections still sees them all, also an empty one to fill.
        var managed = await ReadAsync<List<CollectionSummary>>(await SendAsync(client, owner.Token, HttpMethod.Get, "/api/v1/catalog/collections"));
        Assert.Equal(["Cellar Marathon", "Family Evening", "Planned Evening"], managed.Select(collection => collection.Name));
    }

    [Fact]
    public async Task AgeLimitsAreValidatedAndReservedForViewingProfiles()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using (var odd = await SendAsync(client, owner.Token, HttpMethod.Post, "/api/v1/users",
                   new CreateUserRequest("Odd", null, UserRole.User, AgeLimit: 10)))
            Assert.Equal(HttpStatusCode.BadRequest, odd.StatusCode);
        using (var admin = await SendAsync(client, owner.Token, HttpMethod.Post, "/api/v1/users",
                   new CreateUserRequest("Young Admin", null, UserRole.Admin, ApiTestClient.TestPin, AgeLimit: 6)))
            Assert.Equal(HttpStatusCode.BadRequest, admin.StatusCode);
        var child = await CreateAsync(client, owner.Token, new CreateUserRequest("Ben", null, UserRole.User, AgeLimit: 0));
        var editor = await ReadAsync<ProfileEditorResponse>(await SendAsync(client, owner.Token, HttpMethod.Get, $"/api/v1/users/{child.Id}/profile"));
        using (var promote = await SendAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{child.Id}/profile",
                   new UpdateProfileRequest(editor.Revision, UserRole.Admin, true, true, "5678")))
            Assert.Equal(HttpStatusCode.BadRequest, promote.StatusCode);
        var ownerLimit = await ReadAsync<ProfileAgeLimitResponse>(await SendAsync(client, owner.Token, HttpMethod.Get, $"/api/v1/users/{owner.User.Id}/age-limit"));
        using (var ownerChild = await SendAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{owner.User.Id}/age-limit",
                   new UpdateProfileAgeLimitRequest(6, [], [], ownerLimit.Revision)))
            Assert.Equal(HttpStatusCode.BadRequest, ownerChild.StatusCode);
        var limit = await ReadAsync<ProfileAgeLimitResponse>(await SendAsync(client, owner.Token, HttpMethod.Get, $"/api/v1/users/{child.Id}/age-limit"));
        using (var stale = await SendAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{child.Id}/age-limit",
                   new UpdateProfileAgeLimitRequest(6, [], [], limit.Revision - 1)))
            Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
        using (var missing = await SendAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{child.Id}/age-limit",
                   new UpdateProfileAgeLimitRequest(6, [Guid.NewGuid()], [], limit.Revision)))
            Assert.Equal(HttpStatusCode.BadRequest, missing.StatusCode);
        var session = await ChildSessionAsync(client, child.Id);
        using (var self = await SendAsync(client, session, HttpMethod.Put, $"/api/v1/users/{child.Id}/age-limit",
                   new UpdateProfileAgeLimitRequest(null, [], [], limit.Revision)))
            Assert.Equal(HttpStatusCode.Forbidden, self.StatusCode);
        // Choosing individual titles later replaces the age limit.
        using (var access = await SendAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{child.Id}/titles",
                   new UpdateProfileTitleAccessRequest(ProfileAccessMode.SelectedTitles, [], limit.Revision)))
            access.EnsureSuccessStatusCode();
        Assert.Null((await ReadAsync<ProfileAgeLimitResponse>(await SendAsync(client, owner.Token, HttpMethod.Get, $"/api/v1/users/{child.Id}/age-limit"))).AgeLimit);
        var device = await DeviceAsync(client);
        var picker = await ReadAsync<ProfilePickerResponse>(await SendAsync(client, device.Token, HttpMethod.Get, "/api/v1/profiles"));
        Assert.Null(Assert.Single(picker.Profiles, profile => profile.Id == child.Id).AgeLimit);
    }

    [Fact]
    public async Task ProfilesChooseTheirShownNameWhileTheOwnerKeepsSigningInWithTheOldOne()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var viewer = await CreateAsync(client, owner.Token, new CreateUserRequest("Sam", null, UserRole.User, ApiTestClient.TestPin));
        var renamed = await ReadAsync<UserSummary>(await SendAsync(client, owner.Token, HttpMethod.Put, "/api/v1/profile/name", new UpdateProfileNameRequest("  Papa  ")));
        Assert.Equal("Papa", renamed.DisplayName);
        Assert.Equal("lucas", renamed.Username);
        using (var taken = await SendAsync(client, owner.Token, HttpMethod.Put, "/api/v1/profile/name", new UpdateProfileNameRequest("sam")))
            Assert.Equal(HttpStatusCode.Conflict, taken.StatusCode);
        using (var empty = await SendAsync(client, owner.Token, HttpMethod.Put, "/api/v1/profile/name", new UpdateProfileNameRequest("   ")))
            Assert.Equal(HttpStatusCode.BadRequest, empty.StatusCode);
        using (var tooLong = await SendAsync(client, owner.Token, HttpMethod.Put, "/api/v1/profile/name", new UpdateProfileNameRequest(new string('x', 41))))
            Assert.Equal(HttpStatusCode.BadRequest, tooLong.StatusCode);
        // The owner renames another profile; that profile renames itself back.
        (await SendAsync(client, owner.Token, HttpMethod.Put, $"/api/v1/users/{viewer.Id}/name", new UpdateProfileNameRequest("Samira"))).EnsureSuccessStatusCode();
        var device = await DeviceAsync(client);
        using (var picker = await SendAsync(client, device.Token, HttpMethod.Get, "/api/v1/profiles"))
        {
            var names = (await ReadAsync<ProfilePickerResponse>(picker)).Profiles.Select(profile => profile.Name).ToList();
            Assert.Equal(["Papa", "Samira"], names);
        }
        var session = await UnlockAsync(client, device.Token, viewer.Id);
        using (var other = await SendAsync(client, session, HttpMethod.Put, $"/api/v1/users/{owner.User.Id}/name", new UpdateProfileNameRequest("Boss")))
            Assert.Equal(HttpStatusCode.Forbidden, other.StatusCode);
        var self = await ReadAsync<UserSummary>(await SendAsync(client, session, HttpMethod.Put, "/api/v1/profile/name", new UpdateProfileNameRequest("Sam")));
        Assert.Equal("Sam", self.DisplayName);
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        Assert.Null((await database.Users.SingleAsync(user => user.Id == viewer.Id)).DisplayName);
        // The owner still signs in with the name chosen at setup.
        using var login = await client.PostAsJsonAsync("/api/v1/auth/login", new LoginRequest("lucas", "correct horse battery staple", "Second device"), ApiTestClient.JsonOptions);
        Assert.Equal(HttpStatusCode.OK, login.StatusCode);
    }

    [Fact]
    public async Task PicturesAreBuiltInOrSmallSquarePhotosVisibleInThePicker()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var viewer = await CreateAsync(client, owner.Token, new CreateUserRequest("Lena", null, UserRole.User, ApiTestClient.TestPin, PictureKey: "rocket:teal"));
        Assert.Equal("rocket:teal", viewer.PictureKey);
        using (var invalid = await SendAsync(client, owner.Token, HttpMethod.Put, "/api/v1/profile/picture", new UpdateProfilePictureRequest("../../etc:red")))
            Assert.Equal(HttpStatusCode.BadRequest, invalid.StatusCode);
        var star = await ReadAsync<UserSummary>(await SendAsync(client, owner.Token, HttpMethod.Put, "/api/v1/profile/picture", new UpdateProfilePictureRequest("star:blue")));
        Assert.Equal("star:blue", star.PictureKey);

        var photo = await PhotoAsync(owner.Token, client, Png(1200, 800));
        Assert.Equal(ProfilePictures.PhotoKey, photo.PictureKey);
        Assert.True(photo.PictureRevision > star.PictureRevision);
        var device = await DeviceAsync(client);
        using (var picture = await SendAsync(client, device.Token, HttpMethod.Get, $"/api/v1/profiles/{owner.User.Id}/picture?rev={photo.PictureRevision}"))
        {
            Assert.Equal(HttpStatusCode.OK, picture.StatusCode);
            Assert.Equal("image/jpeg", picture.Content.Headers.ContentType?.MediaType);
            using var decoded = SKBitmap.Decode(await picture.Content.ReadAsByteArrayAsync());
            Assert.Equal(ProfilePictures.PhotoSize, decoded.Width);
            Assert.Equal(ProfilePictures.PhotoSize, decoded.Height);
        }
        using (var picker = await SendAsync(client, device.Token, HttpMethod.Get, "/api/v1/profiles"))
            Assert.Equal(ProfilePictures.PhotoKey, Assert.Single((await ReadAsync<ProfilePickerResponse>(picker)).Profiles, profile => profile.Id == owner.User.Id).PictureKey);
        using (var anonymous = await client.GetAsync(new Uri($"/api/v1/profiles/{owner.User.Id}/picture", UriKind.Relative)))
            Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);
        using (var none = await SendAsync(client, device.Token, HttpMethod.Get, $"/api/v1/profiles/{viewer.Id}/picture"))
            Assert.Equal(HttpStatusCode.NotFound, none.StatusCode);

        using (var garbage = await PutBytesAsync(client, owner.Token, "/api/v1/profile/picture/photo", [1, 2, 3, 4, 5]))
            Assert.Equal(HttpStatusCode.BadRequest, garbage.StatusCode);
        using (var huge = await PutBytesAsync(client, owner.Token, "/api/v1/profile/picture/photo", new byte[ProfilePictures.MaximumUploadBytes + 1]))
            Assert.Equal(HttpStatusCode.RequestEntityTooLarge, huge.StatusCode);
        var session = await UnlockAsync(client, device.Token, viewer.Id);
        using (var foreign = await PutBytesAsync(client, session, $"/api/v1/users/{owner.User.Id}/picture/photo", Png(64, 64)))
            Assert.Equal(HttpStatusCode.Forbidden, foreign.StatusCode);
        // The owner gives another profile a photo; choosing a built-in picture removes it again.
        (await PutBytesAsync(client, owner.Token, $"/api/v1/users/{viewer.Id}/picture/photo", Png(300, 900))).EnsureSuccessStatusCode();
        using (var viewerPhoto = await SendAsync(client, device.Token, HttpMethod.Get, $"/api/v1/profiles/{viewer.Id}/picture"))
            Assert.Equal(HttpStatusCode.OK, viewerPhoto.StatusCode);
        (await SendAsync(client, session, HttpMethod.Put, "/api/v1/profile/picture", new UpdateProfilePictureRequest("cat:pink"))).EnsureSuccessStatusCode();
        using (var removed = await SendAsync(client, device.Token, HttpMethod.Get, $"/api/v1/profiles/{viewer.Id}/picture"))
            Assert.Equal(HttpStatusCode.NotFound, removed.StatusCode);
        using var scope = factory.Services.CreateScope();
        Assert.Equal(1, await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().ProfilePhotos.CountAsync());
    }

    private sealed record Seeded(Guid Id, Guid ArtworkId, string Title);

    private static async Task<LibraryRoot> LibraryAsync(AureliaServerFactory factory)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var root = Path.Combine(factory.DataDirectory, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var library = new LibraryRoot
        {
            Id = Guid.NewGuid(),
            Name = "Synthetic family library",
            Path = root,
            NormalizedPath = MediaPath.Normalize(root),
            Kind = LibraryKind.Automatic,
            Availability = LibraryAvailability.Available,
            CreatedAt = DateTimeOffset.UtcNow,
        };
        database.LibraryRoots.Add(library);
        await database.SaveChangesAsync();
        return library;
    }

    private static async Task<Seeded> SeedAsync(AureliaServerFactory factory, LibraryRoot library, MediaKind kind, string title,
        string? rating, Seeded? parent = null, string? manual = null)
    {
        using var scope = factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var path = Path.Combine(library.Path, Guid.NewGuid().ToString("N") + ".mkv");
        await File.WriteAllBytesAsync(path, [1, 2, 3, 4]);
        var now = DateTimeOffset.UtcNow;
        var media = new MediaItem
        {
            Id = Guid.NewGuid(),
            LibraryRootId = library.Id,
            ParentId = parent?.Id,
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
            SeasonNumber = kind == MediaKind.Episode ? 1 : null,
            EpisodeNumber = kind == MediaKind.Episode ? 1 : null,
        };
        media.Metadata = new MediaMetadata { MediaItemId = media.Id, UpdatedAt = now, ProviderContentRating = rating, ManualContentRating = manual };
        var artwork = new ArtworkAsset { Id = Guid.NewGuid(), MediaItemId = media.Id, RelativeFilePath = Guid.NewGuid().ToString("N"), Kind = ArtworkKind.Poster, CreatedAt = now };
        media.Metadata.Artwork.Add(artwork);
        database.MediaItems.Add(media);
        await database.SaveChangesAsync();
        return new(media.Id, artwork.Id, title);
    }

    private static async Task<UserSummary> CreateAsync(HttpClient client, string owner, CreateUserRequest request)
    {
        using var response = await SendAsync(client, owner, HttpMethod.Post, "/api/v1/users", request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<UserSummary>(response);
    }

    private static async Task<AuthenticationResponse> DeviceAsync(HttpClient client)
    {
        using var response = await client.PostAsJsonAsync("/api/v1/auth/login",
            new LoginRequest("lucas", "correct horse battery staple", "Paired synthetic device"), ApiTestClient.JsonOptions);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<AuthenticationResponse>(response);
    }

    private static async Task<string> ChildSessionAsync(HttpClient client, Guid child) =>
        await UnlockAsync(client, (await DeviceAsync(client)).Token, child);

    private static async Task<string> UnlockAsync(HttpClient client, string device, Guid profile)
    {
        using var response = await SendAsync(client, device, HttpMethod.Post, $"/api/v1/profiles/{profile}/unlock", new UnlockProfileRequest(ApiTestClient.TestPin));
        response.EnsureSuccessStatusCode();
        return (await ApiTestClient.ReadAsync<ProfileSessionResponse>(response)).Token;
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

    private static async Task<HttpResponseMessage> PutBytesAsync(HttpClient client, string token, string path, byte[] bytes)
    {
        using var request = new HttpRequestMessage(HttpMethod.Put, path) { Content = new ByteArrayContent(bytes) };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        return await client.SendAsync(request);
    }

    private static async Task<UserSummary> PhotoAsync(string token, HttpClient client, byte[] png) =>
        await ReadAsync<UserSummary>(await PutBytesAsync(client, token, "/api/v1/profile/picture/photo", png));

    private static byte[] Png(int width, int height)
    {
        using var bitmap = new SKBitmap(width, height);
        using (var canvas = new SKCanvas(bitmap)) canvas.Clear(new SKColor(40, 120, 200));
        using var image = SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        return data.ToArray();
    }
}
