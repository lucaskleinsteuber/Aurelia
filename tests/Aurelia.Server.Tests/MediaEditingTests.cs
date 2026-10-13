using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using SkiaSharp;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class MediaEditingTests
{
    private static readonly string[] AllFields = ["title", "releaseYear", "overview", "runtimeMinutes", "fsk", "genres", "studios", "country", "credits", "poster", "backdrop"];

    [Fact]
    public async Task ProviderPersonKeysSurviveEditorSnapshotsWithoutAllowingClientIdentityAssignments()
    {
        using var fixture = await Fixture.CreateAsync();
        var movie = await fixture.MovieAsync("People.mkv");
        using (var scope = fixture.Factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var item = await database.MediaItems.SingleAsync(item => item.Id == movie.Id);
            await scope.ServiceProvider.GetRequiredService<MetadataService>().ApplyAsync(item,
                new TmdbMetadata("123", "movie", "People", null, null, "2020-01-01", 90, null, null,
                    [], [], [], null, null,
                    [new TmdbCredit("44", "Actor", "Acting", null, "Character", 0, null),
                     new TmdbCredit("44", "Actor", "Production", "Producer", null, 9, null)], null),
                1, CancellationToken.None);
        }
        var summary = await fixture.GetAsync<MediaMetadataSummary>($"/api/v1/media/{movie.Id}/metadata");
        Assert.Equal(2, summary.Credits.Count);
        Assert.All(summary.Credits, credit => Assert.Equal("tmdb:person:44", credit.PersonKey));
        var draft = await fixture.GetAsync<MediaEditorDocument>($"/api/v1/media/{movie.Id}/editor");
        var forged = draft.Values with { Credits = draft.Values.Credits.Select(credit => credit with { PersonKey = "tmdb:person:999" }).ToArray() };
        var manual = await fixture.SaveAsync(movie.Id, draft, forged, ["credits"]);
        Assert.All(manual.Values.Credits, credit => Assert.Equal("tmdb:person:44", credit.PersonKey));
        Assert.All(manual.AutomaticValues.Credits, credit => Assert.Equal("tmdb:person:44", credit.PersonKey));
        var removed = await fixture.SaveAsync(movie.Id, manual, manual.Values with { Credits = [] }, ["credits"]);
        var restored = await fixture.SaveAsync(movie.Id, removed, removed.AutomaticValues, []);
        Assert.Equal(2, restored.Values.Credits.Count);
        Assert.All(restored.Values.Credits, credit => Assert.Equal("tmdb:person:44", credit.PersonKey));
        var newPerson = new EditorCredit(Guid.NewGuid(), "Manual Person", "Acting", null, null, null, "tmdb:person:44");
        var added = await fixture.SaveAsync(movie.Id, restored, restored.Values with { Credits = [newPerson] }, ["credits"]);
        Assert.Null(Assert.Single(added.Values.Credits).PersonKey);
    }

    [Fact]
    public async Task AsymmetricCropCoordinatesUseClockwiseRotationAndTopLeftOrigin()
    {
        using var fixture = await Fixture.CreateAsync();
        var movie = await fixture.MovieAsync("Asymmetric.mkv");
        using var bitmap = new SKBitmap(600, 400);
        using (var canvas = new SKCanvas(bitmap))
        {
            canvas.Clear(SKColors.Red);
            using var paint = new SKPaint { Color = SKColors.Green };
            canvas.DrawRect(new SKRect(300, 0, 600, 200), paint);
            paint.Color = SKColors.Blue; canvas.DrawRect(new SKRect(0, 200, 300, 400), paint);
            paint.Color = SKColors.Yellow; canvas.DrawRect(new SKRect(300, 200, 600, 400), paint);
        }
        using var image = SKImage.FromBitmap(bitmap);
        using var encoded = image.Encode(SKEncodedImageFormat.Png, 100);
        using var uploadResponse = await fixture.UploadAsync(movie.Id, encoded.ToArray());
        var upload = await ApiTestClient.ReadAsync<EditorUploadSummary>(uploadResponse);
        var draft = await fixture.GetAsync<MediaEditorDocument>($"/api/v1/media/{movie.Id}/editor");
        var crop = new ArtworkCrop(0, 1d / 3, 1, 2d / 3, 90);
        var person = new EditorCredit(Guid.NewGuid(), "Asymmetric Person", "Acting", null, null, new(UploadId: upload.Id, Crop: crop));
        var saved = await fixture.SaveAsync(movie.Id, draft, draft.Values with { Credits = [person] }, ["credits"]);
        var selected = Assert.Single(saved.Values.Credits).Profile!;
        Assert.Equal(crop, selected.Crop);
        using var response = await fixture.SendAsync(HttpMethod.Get, $"/api/v1/artwork/{selected.AssetId}");
        using var result = SKBitmap.Decode(await response.Content.ReadAsByteArrayAsync());
        Assert.Equal(400, result.Width); Assert.Equal(400, result.Height);
        Assert.Equal(SKColors.Blue, result.GetPixel(20, 20));
        Assert.Equal(SKColors.Red, result.GetPixel(380, 20));
        Assert.Equal(SKColors.Yellow, result.GetPixel(20, 380));
        Assert.Equal(SKColors.Green, result.GetPixel(380, 380));
    }

    [Fact]
    public async Task ManualFieldsIncludingBlanksSurviveProviderRefreshScanAndConflictingEditors()
    {
        using var fixture = await Fixture.CreateAsync();
        var movie = await fixture.MovieAsync("Original (2010).mkv");
        var draft = await fixture.GetAsync<MediaEditorDocument>($"/api/v1/media/{movie.Id}/editor");
        var person = new EditorCredit(Guid.NewGuid(), "Correct Actor", "Acting", "Actor", "Correct Character", null);
        var values = draft.Values with
        {
            Title = "My Correct Title",
            ReleaseYear = 2025,
            Overview = "",
            RuntimeMinutes = 101,
            FskAge = 12,
            Genres = ["My Genre"],
            Studios = ["First Studio", "Second Studio"],
            Country = "DE",
            Credits = [person]
        };
        var saved = await fixture.SaveAsync(movie.Id, draft, values, AllFields);
        Assert.True(saved.Revision > draft.Revision);
        using (var scope = fixture.Factory.Services.CreateScope())
        {
            var service = scope.ServiceProvider.GetRequiredService<MetadataService>();
            var item = await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().MediaItems.SingleAsync(item => item.Id == movie.Id);
            await service.ApplyAsync(item, new TmdbMetadata("123", "movie", "Automatic Title", null, "Automatic Description", "1999-01-01", 90, null, "R",
                ["Auto Genre"], ["Auto Studio"], ["US", "GB"], null, null,
                [new TmdbCredit("44", "Automatic Actor", "Acting", null, "Auto Character", 0, null)], null), 1, CancellationToken.None);
        }
        await fixture.ScanAsync(movie.LibraryRootId);
        var current = await fixture.GetAsync<MediaEditorDocument>($"/api/v1/media/{movie.Id}/editor");
        Assert.Equal("My Correct Title", current.Values.Title); Assert.Equal("", current.Values.Overview);
        Assert.Equal(2025, current.Values.ReleaseYear); Assert.Equal(person.Id, Assert.Single(current.Values.Credits).Id);
        Assert.Equal(values.Studios, current.Values.Studios); Assert.Null(current.AutomaticValues.FskAge);
        var search = await fixture.GetAsync<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/search?query=Correct%20Actor");
        Assert.Equal(movie.Id, Assert.Single(search.Items).Id);
        var year = await fixture.GetAsync<PagedResponse<CatalogItemSummary>>("/api/v1/catalog/items?yearFrom=2025&yearTo=2025");
        Assert.Equal(movie.Id, Assert.Single(year.Items).Id);
        using var stale = await fixture.SendAsync(HttpMethod.Put, $"/api/v1/media/{movie.Id}/editor", new SaveMediaEditorRequest(saved.Revision, values, AllFields));
        Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
        var automatic = await fixture.SaveAsync(movie.Id, current, current.AutomaticValues, []);
        Assert.Equal("Automatic Title", automatic.Values.Title); Assert.Equal(1999, automatic.Values.ReleaseYear);
        Assert.Equal("Automatic Actor", Assert.Single(automatic.Values.Credits).Name);
        var blankYear = await fixture.SaveAsync(movie.Id, automatic, automatic.Values with { ReleaseYear = null }, ["releaseYear"]);
        Assert.Null(blankYear.Values.ReleaseYear);
        Assert.Null((await fixture.GetAsync<MediaMetadataSummary>($"/api/v1/media/{movie.Id}/metadata")).Year);
    }

    [Fact]
    public async Task MoviesWithoutProviderMetadataCanBeEditedAndEpisodesRejectRuntime()
    {
        using var fixture = await Fixture.CreateAsync();
        var movie = await fixture.MovieAsync("No Provider.mkv", metadata: false);
        var draft = await fixture.GetAsync<MediaEditorDocument>($"/api/v1/media/{movie.Id}/editor");
        var saved = await fixture.SaveAsync(movie.Id, draft, draft.Values with { Title = "Manual Only", FskAge = 0 }, ["title", "fsk"]);
        Assert.Equal("Manual Only", saved.Values.Title); Assert.Equal(0, saved.Values.FskAge);
        using var scope = fixture.Factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        await database.MediaItems.Where(item => item.Id == movie.Id).ExecuteUpdateAsync(set => set.SetProperty(item => item.Kind, MediaKind.Episode));
        var episode = await fixture.GetAsync<MediaEditorDocument>($"/api/v1/media/{movie.Id}/editor");
        Assert.Null(episode.Values.RuntimeMinutes);
        using var invalid = await fixture.SendAsync(HttpMethod.Put, $"/api/v1/media/{movie.Id}/editor",
            new SaveMediaEditorRequest(episode.Revision, episode.Values with { RuntimeMinutes = 90 }, ["runtimeMinutes"]));
        Assert.Equal(HttpStatusCode.BadRequest, invalid.StatusCode);
    }

    [Fact]
    public async Task ImageImportsArePrivateValidatedRecroppableAndPublishFreshAssetsTogether()
    {
        using var fixture = await Fixture.CreateAsync();
        var movie = await fixture.MovieAsync("Images.mkv");
        using var invalid = await fixture.UploadAsync(movie.Id, [1, 2, 3]);
        Assert.Equal(HttpStatusCode.BadRequest, invalid.StatusCode);
        using var uploaded = await fixture.UploadAsync(movie.Id, Png(600, 600));
        Assert.Equal(HttpStatusCode.OK, uploaded.StatusCode);
        var upload = await ApiTestClient.ReadAsync<EditorUploadSummary>(uploaded);
        using var anonymous = await fixture.Client.GetAsync(upload.Path);
        Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);
        using var otherSessionResponse = await ApiTestClient.LoginAsync(fixture.Client, new LoginRequest("lucas", Fixture.Password, "Other editor"));
        var otherSession = await ApiTestClient.ReadAsync<AuthenticationResponse>(otherSessionResponse);
        using var otherRequest = ApiTestClient.Authorized(HttpMethod.Get, upload.Path, otherSession.Token);
        using var otherRead = await fixture.Client.SendAsync(otherRequest);
        Assert.Equal(HttpStatusCode.NotFound, otherRead.StatusCode);
        var draft = await fixture.GetAsync<MediaEditorDocument>($"/api/v1/media/{movie.Id}/editor");
        var selection = new EditorArtwork(UploadId: upload.Id, Crop: new ArtworkCrop(1d / 6, 0, 2d / 3, 1, 90));
        var saved = await fixture.SaveAsync(movie.Id, draft, draft.Values with { Poster = selection }, ["poster"]);
        var asset = saved.Values.Poster!.AssetId!.Value;
        using var image = await fixture.SendAsync(HttpMethod.Get, $"/api/v1/artwork/{asset}");
        Assert.Equal(HttpStatusCode.OK, image.StatusCode);
        using var decoded = SKBitmap.Decode(await image.Content.ReadAsByteArrayAsync());
        Assert.Equal(400, decoded.Width); Assert.Equal(600, decoded.Height);
        var recropped = await fixture.SaveAsync(movie.Id, saved, saved.Values with { Poster = new(asset, Crop: new ArtworkCrop(1d / 6, 0, 2d / 3, 1, 180)) }, ["poster"]);
        Assert.NotEqual(asset, recropped.Values.Poster!.AssetId);
        using var oldAsset = await fixture.SendAsync(HttpMethod.Get, $"/api/v1/artwork/{asset}");
        Assert.Equal(HttpStatusCode.NotFound, oldAsset.StatusCode);
        Assert.False(File.Exists(Path.Combine(fixture.Factory.DataDirectory, "Artwork", asset.ToString("N") + ".original.png")));
        var removed = await fixture.SaveAsync(movie.Id, recropped, recropped.Values with { Poster = null }, ["poster"]);
        Assert.Null(removed.Values.Poster);
        using var badCrop = await fixture.SendAsync(HttpMethod.Put, $"/api/v1/media/{movie.Id}/editor",
            new SaveMediaEditorRequest(removed.Revision, removed.Values with { Backdrop = new(UploadId: upload.Id, Crop: new ArtworkCrop(0, 0, 1, 1)) }, ["backdrop"]));
        Assert.Equal(HttpStatusCode.BadRequest, badCrop.StatusCode);
        Assert.Null((await fixture.GetAsync<MediaEditorDocument>($"/api/v1/media/{movie.Id}/editor")).Values.Backdrop);
        using var overLimit = await fixture.UploadAsync(movie.Id, new byte[EditorArtworkStore.MaximumUploadBytes + 1]);
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, overLimit.StatusCode);
    }

    [Fact]
    public async Task FileRebindingPreservesIdentityExcludesOldSourceAndRejectsTraversalSymlinksAndDuplicates()
    {
        using var fixture = await Fixture.CreateAsync();
        var movie = await fixture.MovieAsync("Original (2010).mkv");
        var root = Path.GetDirectoryName(movie.SourcePath)!;
        var replacement = Path.Combine(root, "Different (2024).mkv");
        await File.WriteAllBytesAsync(replacement, [4, 5, 6]);
        var bytes = await File.ReadAllBytesAsync(movie.SourcePath); var date = File.GetLastWriteTimeUtc(movie.SourcePath);
        var streams = fixture.Factory.Services.GetRequiredService<ActiveStreamRegistry>();
        using var stream = streams.Enter(fixture.Owner.User.Id, fixture.Owner.SessionId, 32, 4, CancellationToken.None); stream.BindMedia(movie.Id);
        var draft = await fixture.GetAsync<MediaEditorDocument>($"/api/v1/media/{movie.Id}/editor");
        var saved = await fixture.SaveAsync(movie.Id, draft, draft.Values with { Title = "Pinned Title" }, ["title"], "Different (2024).mkv");
        Assert.True(stream.Token.IsCancellationRequested); Assert.Equal(movie.Id, saved.MediaId);
        await fixture.ScanAsync(movie.LibraryRootId);
        var items = await fixture.GetAsync<PagedResponse<MovieSummary>>("/api/v1/catalog/movies");
        Assert.Equal(movie.Id, Assert.Single(items.Items).Id); Assert.Equal("Pinned Title", items.Items[0].Title);
        Assert.Equal(bytes, await File.ReadAllBytesAsync(movie.SourcePath)); Assert.Equal(date, File.GetLastWriteTimeUtc(movie.SourcePath));
        var current = await fixture.GetAsync<MediaEditorDocument>($"/api/v1/media/{movie.Id}/editor");
        Assert.Equal(replacement, current.SourcePath);
        using var traversal = await fixture.SendAsync(HttpMethod.Get, $"/api/v1/media/{movie.Id}/editor/files?path=..%2F..");
        Assert.Equal(HttpStatusCode.BadRequest, traversal.StatusCode);
        var another = await fixture.MovieAsync("Assigned.mkv", libraryId: movie.LibraryRootId);
        using var duplicate = await fixture.SendAsync(HttpMethod.Put, $"/api/v1/media/{movie.Id}/editor", new SaveMediaEditorRequest(current.Revision, current.Values, current.OverrideFields, Path.GetFileName(another.SourcePath)));
        Assert.Equal(HttpStatusCode.Conflict, duplicate.StatusCode);
        if (!OperatingSystem.IsWindows())
        {
            File.CreateSymbolicLink(Path.Combine(root, "Alias.mkv"), Path.Combine(fixture.Factory.DataDirectory, "aurelia.db"));
            var listing = await fixture.GetAsync<ServerFileListing>($"/api/v1/media/{movie.Id}/editor/files");
            Assert.DoesNotContain(listing.Entries, entry => entry.Name == "Alias.mkv");
            using var alias = await fixture.SendAsync(HttpMethod.Put, $"/api/v1/media/{movie.Id}/editor", new SaveMediaEditorRequest(current.Revision, current.Values, current.OverrideFields, "Alias.mkv"));
            Assert.False(alias.IsSuccessStatusCode);
        }
    }

    [Fact]
    public async Task RemovalCleansAllUsersStateArtworkAndDraftsButNeverVideosOrReimportsAutomatically()
    {
        using var fixture = await Fixture.CreateAsync();
        var movie = await fixture.MovieAsync("Removed (2010).mkv");
        using var uploaded = await fixture.UploadAsync(movie.Id, Png(600, 600));
        var upload = await ApiTestClient.ReadAsync<EditorUploadSummary>(uploaded);
        var draft = await fixture.GetAsync<MediaEditorDocument>($"/api/v1/media/{movie.Id}/editor");
        var saved = await fixture.SaveAsync(movie.Id, draft, draft.Values with { Poster = new(UploadId: upload.Id) }, ["poster"]);
        using (var scope = fixture.Factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            database.UserFavorites.Add(new UserFavorite { Id = Guid.NewGuid(), UserId = fixture.Owner.User.Id, MediaItemId = movie.Id, CreatedAt = DateTimeOffset.UtcNow });
            database.PlaybackProgress.Add(new PlaybackProgress
            {
                Id = Guid.NewGuid(),
                UserId = fixture.Owner.User.Id,
                MediaItemId = movie.Id,
                MediaItem = await database.MediaItems.SingleAsync(item => item.Id == movie.Id),
                User = await database.Users.SingleAsync(user => user.Id == fixture.Owner.User.Id),
                LastPlayedAt = DateTimeOffset.UtcNow
            });
            await database.SaveChangesAsync();
        }
        var bytes = await File.ReadAllBytesAsync(movie.SourcePath); var modified = File.GetLastWriteTimeUtc(movie.SourcePath);
        var result = await fixture.RequestAsync<LibraryMutationResult>(HttpMethod.Delete, $"/api/v1/media/{movie.Id}");
        Assert.Equal("completed", result.State); Assert.Equal(1, result.RemovedItems);
        Assert.False(File.Exists(Path.Combine(fixture.Factory.DataDirectory, "Artwork", saved.Values.Poster!.AssetId!.Value.ToString("N") + ".png")));
        Assert.Empty(Directory.GetFiles(Path.Combine(fixture.Factory.DataDirectory, "EditorUploads")));
        using (var scope = fixture.Factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            Assert.Empty(await database.UserFavorites.ToListAsync()); Assert.Empty(await database.PlaybackProgress.ToListAsync());
            Assert.Empty(await database.MediaMetadata.ToListAsync()); Assert.Empty(await database.ArtworkAssets.ToListAsync());
        }
        await fixture.ScanAsync(movie.LibraryRootId);
        Assert.Empty((await fixture.GetAsync<PagedResponse<MovieSummary>>("/api/v1/catalog/movies")).Items);
        var excluded = Assert.Single(await fixture.GetAsync<ExcludedMediaSummary[]>($"/api/v1/libraries/{movie.LibraryRootId}/exclusions"));
        var scan = await fixture.RequestAsync<LibraryScanSummary>(HttpMethod.Delete, $"/api/v1/libraries/{movie.LibraryRootId}/exclusions/{excluded.Id}");
        await fixture.WaitScanAsync(scan.Id);
        Assert.Single((await fixture.GetAsync<PagedResponse<MovieSummary>>("/api/v1/catalog/movies")).Items);
        Assert.Equal(bytes, await File.ReadAllBytesAsync(movie.SourcePath)); Assert.Equal(modified, File.GetLastWriteTimeUtc(movie.SourcePath));
    }

    [Fact]
    public async Task ResetRequiresBoundSingleUsePasswordApprovalAndPreservesAccountsAndOtherLibraries()
    {
        using var fixture = await Fixture.CreateAsync();
        var movie = await fixture.MovieAsync("Reset.mkv"); var privateMovie = await fixture.MovieAsync("Private.mkv");
        var administrator = await fixture.RequestAsync<UserSummary>(HttpMethod.Post, "/api/v1/users", new CreateUserRequest("admin", Fixture.Password, UserRole.Admin, ApiTestClient.TestPin));
        using (var grant = await fixture.SendAsync(HttpMethod.Put, $"/api/v1/users/{administrator.Id}/access", new UpdateUserAccessRequest(true, [movie.LibraryRootId]))) grant.EnsureSuccessStatusCode();
        using var login = await ApiTestClient.LoginAsync(fixture.Client, new LoginRequest("admin", Fixture.Password, "Admin Mac"));
        var session = await ApiTestClient.ReadAsync<AuthenticationResponse>(login);
        using var denied = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/media/{privateMovie.Id}/editor", session.Token);
        using var deniedResponse = await fixture.Client.SendAsync(denied); Assert.Equal(HttpStatusCode.NotFound, deniedResponse.StatusCode);
        var preview = await fixture.RequestAsync<ResetLibraryPreview>(HttpMethod.Post, "/api/v1/libraries/reset/preview", new[] { movie.LibraryRootId });
        var payload = new ResetLibraryRequest([movie.LibraryRootId], preview.Revision);
        using var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries/reset", session.Token, payload);
        using var withoutApproval = await fixture.Client.SendAsync(request); Assert.Equal(HttpStatusCode.Forbidden, withoutApproval.StatusCode);
        var body = JsonSerializer.SerializeToUtf8Bytes(payload, ApiTestClient.JsonOptions);
        using var wrong = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries/reset/approval", session.Token,
            new AdministrationApprovalRequest("POST /api/v1/libraries/reset", AdministrationApprovalStore.Hash(body), "wrong password"));
        using var wrongResponse = await fixture.Client.SendAsync(wrong); Assert.False(wrongResponse.IsSuccessStatusCode);
        using var approve = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries/reset/approval", session.Token,
            new AdministrationApprovalRequest("POST /api/v1/libraries/reset", AdministrationApprovalStore.Hash(body), Fixture.Password));
        using var approvalResponse = await fixture.Client.SendAsync(approve); approvalResponse.EnsureSuccessStatusCode();
        var approval = await ApiTestClient.ReadAsync<AdministrationApprovalResponse>(approvalResponse);
        using var reset = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries/reset", session.Token, payload); reset.Headers.Add("X-Aurelia-Approval", approval.Token);
        using var resetResponse = await fixture.Client.SendAsync(reset); resetResponse.EnsureSuccessStatusCode();
        Assert.Equal("completed", (await ApiTestClient.ReadAsync<LibraryMutationResult>(resetResponse)).State);
        using var reuse = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries/reset", session.Token, payload); reuse.Headers.Add("X-Aurelia-Approval", approval.Token);
        using var reuseResponse = await fixture.Client.SendAsync(reuse); Assert.Equal(HttpStatusCode.Forbidden, reuseResponse.StatusCode);
        var remaining = Assert.Single((await fixture.GetAsync<PagedResponse<MovieSummary>>("/api/v1/catalog/movies")).Items);
        Assert.Equal(privateMovie.Id, remaining.Id);
        Assert.True(File.Exists(movie.SourcePath)); Assert.True(File.Exists(privateMovie.SourcePath));
        using var scope = fixture.Factory.Services.CreateScope(); var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        Assert.Equal(2, await database.Users.CountAsync()); Assert.True(await database.DeviceSessions.AnyAsync(device => device.Id == session.SessionId && device.RevokedAt == null));
        Assert.False(await database.LibraryRoots.AnyAsync(root => root.Id == movie.LibraryRootId));
        Assert.Empty(await database.UserLibraryGrants.Where(grant => grant.LibraryRootId == movie.LibraryRootId).ToListAsync());
    }

    [Fact]
    public async Task CastEditsKeepStableOrderAndPhotosOnlyForThisTitleAndEmptyListsStayEmpty()
    {
        using var fixture = await Fixture.CreateAsync();
        var movie = await fixture.MovieAsync("Cast.mkv"); var other = await fixture.MovieAsync("Other Cast.mkv");
        using var uploadResponse = await fixture.UploadAsync(movie.Id, Png(300, 300));
        var upload = await ApiTestClient.ReadAsync<EditorUploadSummary>(uploadResponse);
        var first = new EditorCredit(Guid.NewGuid(), "Actor", "Acting", "Actor", "Character", new(UploadId: upload.Id));
        var second = new EditorCredit(Guid.NewGuid(), "Director", "Directing", "Director", null, null);
        var draft = await fixture.GetAsync<MediaEditorDocument>($"/api/v1/media/{movie.Id}/editor");
        var saved = await fixture.SaveAsync(movie.Id, draft, draft.Values with { Credits = [first, second] }, ["credits"]);
        var photo = saved.Values.Credits[0].Profile!.AssetId;
        var reordered = await fixture.SaveAsync(movie.Id, saved, saved.Values with
        {
            Credits = [saved.Values.Credits[1], saved.Values.Credits[0] with { Name = "Corrected Actor", Job = "Voice", Character = "Corrected Character" }],
        }, ["credits"]);
        Assert.Equal(new[] { second.Id, first.Id }, reordered.Values.Credits.Select(credit => credit.Id));
        Assert.Equal(photo, reordered.Values.Credits[1].Profile!.AssetId);
        Assert.Equal("Corrected Actor", reordered.Values.Credits[1].Name);
        var otherDraft = await fixture.GetAsync<MediaEditorDocument>($"/api/v1/media/{other.Id}/editor");
        Assert.Empty(otherDraft.Values.Credits);
        using var foreign = await fixture.SendAsync(HttpMethod.Put, $"/api/v1/media/{other.Id}/editor",
            new SaveMediaEditorRequest(otherDraft.Revision, otherDraft.Values with { Credits = [first with { Id = Guid.NewGuid(), Profile = new(AssetId: photo) }] }, ["credits"]));
        Assert.Equal(HttpStatusCode.NotFound, foreign.StatusCode);
        var cleared = await fixture.SaveAsync(movie.Id, reordered, reordered.Values with { Credits = [] }, ["credits"]);
        using (var scope = fixture.Factory.Services.CreateScope())
        {
            var item = await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().MediaItems.SingleAsync(item => item.Id == movie.Id);
            await scope.ServiceProvider.GetRequiredService<MetadataService>().ApplyAsync(item,
                new TmdbMetadata("77", "movie", "Automatic", null, "Provider", "2000-01-01", 99, null, null, [], [], [], null, null,
                    [new("77", "Provider Actor", "Acting", "Actor", null, 0, null)], null), 1, CancellationToken.None);
        }
        Assert.Empty((await fixture.GetAsync<MediaEditorDocument>($"/api/v1/media/{movie.Id}/editor")).Values.Credits);
        Assert.False(File.Exists(Path.Combine(fixture.Factory.DataDirectory, "Artwork", photo!.Value.ToString("N") + ".png")));
        Assert.Contains("credits", cleared.OverrideFields);
    }

    [Fact]
    public async Task InvalidCreditEntriesAndTruncatedImagesAreRejectedWithoutChangingTheDraft()
    {
        using var fixture = await Fixture.CreateAsync(); var movie = await fixture.MovieAsync("Validation.mkv");
        var draft = await fixture.GetAsync<MediaEditorDocument>($"/api/v1/media/{movie.Id}/editor");
        using var invalid = await fixture.SendAsync(HttpMethod.Put, $"/api/v1/media/{movie.Id}/editor",
            new SaveMediaEditorRequest(draft.Revision, draft.Values with { Credits = [null!] }, ["credits"]));
        Assert.Equal(HttpStatusCode.BadRequest, invalid.StatusCode);
        var png = Png(300, 300);
        using var truncated = await fixture.UploadAsync(movie.Id, png[..(png.Length / 2)]);
        Assert.Equal(HttpStatusCode.BadRequest, truncated.StatusCode);
        Assert.Equal(draft.Revision, (await fixture.GetAsync<MediaEditorDocument>($"/api/v1/media/{movie.Id}/editor")).Revision);
    }

    [Fact]
    public async Task FailedFileCleanupRemainsPendingAndRetriesWithoutDeletingReferencedImages()
    {
        using var fixture = await Fixture.CreateAsync(); var movie = await fixture.MovieAsync("Cleanup.mkv");
        using var lease = await fixture.Factory.Services.GetRequiredService<CatalogMutationGate>().EnterAsync(CancellationToken.None);
        using var scope = fixture.Factory.Services.CreateScope(); var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var service = scope.ServiceProvider.GetRequiredService<LibraryMutationService>();
        var name = Guid.NewGuid().ToString("N") + ".png";
        var path = Path.Combine(fixture.Factory.DataDirectory, "Artwork", name);
        Directory.CreateDirectory(path);
        var id = service.TrackArtworkCleanup(fixture.Owner.User.Id, [name]); await database.SaveChangesAsync();
        var pending = await service.CleanupAsync(id, CancellationToken.None);
        Assert.Equal("cleaning", pending.State); Assert.NotNull(pending.Error);
        Directory.Delete(path); await File.WriteAllBytesAsync(path, Png(120, 180));
        database.ArtworkAssets.Add(new ArtworkAsset
        {
            Id = Guid.NewGuid(),
            MediaItemId = movie.Id,
            Kind = ArtworkKind.Poster,
            ProviderPath = "/shared.png",
            RelativeFilePath = name,
            ContentType = "image/png",
            ContentLength = new FileInfo(path).Length,
            CreatedAt = DateTimeOffset.UtcNow
        });
        await database.SaveChangesAsync();
        Assert.Equal("completed", (await service.CleanupAsync(id, CancellationToken.None)).State);
        Assert.True(File.Exists(path));
        var obsolete = service.TrackArtworkCleanup(fixture.Owner.User.Id, [name]);
        await database.ArtworkAssets.Where(asset => asset.RelativeFilePath == name).ExecuteDeleteAsync(); await database.SaveChangesAsync();
        Assert.Equal("completed", (await service.CleanupAsync(obsolete, CancellationToken.None)).State);
        Assert.False(File.Exists(path));
        if (OperatingSystem.IsMacOS() || OperatingSystem.IsLinux())
        {
            var directory = Path.GetDirectoryName(path)!;
            var mode = File.GetUnixFileMode(directory);
            await File.WriteAllBytesAsync(path, Png(120, 180));
            var unreadable = service.TrackArtworkCleanup(fixture.Owner.User.Id, [name]);
            await database.SaveChangesAsync();
            try
            {
                File.SetUnixFileMode(directory, UnixFileMode.None);
                if (Environment.UserName != "root")
                    Assert.Equal("cleaning", (await service.CleanupAsync(unreadable, CancellationToken.None)).State);
            }
            finally { File.SetUnixFileMode(directory, mode); }
            Assert.Equal("completed", (await service.CleanupAsync(unreadable, CancellationToken.None)).State);
            Assert.False(File.Exists(path));
        }
    }

    [Fact]
    public async Task SeriesRemovalIncludesDescendantsAndExplicitDirectoryReimportClearsAllExclusions()
    {
        using var fixture = await Fixture.CreateAsync();
        var path = Path.Combine(fixture.Factory.DataDirectory, "Synthetic Shows");
        var names = new[] { "Example Show/Season 1/Example Show S01E01 Pilot.mkv", "Example Show/Season 1/Example Show S01E02 Second.mkv",
            "Example Show/Season 1/Extras/Behind the Scenes.mkv", "Example Show/Extras/Retrospective.mkv", "Example Show/Trailers/Trailer.mkv" };
        foreach (var name in names) { var source = Path.Combine(path, name); Directory.CreateDirectory(Path.GetDirectoryName(source)!); await File.WriteAllBytesAsync(source, [1, 2, 3]); }
        var library = await fixture.RequestAsync<LibrarySummary>(HttpMethod.Post, "/api/v1/libraries", new CreateLibraryRequest(null, path, LibraryKind.TvShows));
        await fixture.ScanAsync(library.Id);
        var show = Assert.Single((await fixture.GetAsync<PagedResponse<SeriesSummary>>("/api/v1/catalog/series")).Items);
        var removed = await fixture.RequestAsync<LibraryMutationResult>(HttpMethod.Delete, $"/api/v1/media/{show.Id}");
        Assert.Equal(6, removed.RemovedItems); Assert.Equal("completed", removed.State);
        await fixture.ScanAsync(library.Id);
        Assert.Empty((await fixture.GetAsync<PagedResponse<SeriesSummary>>("/api/v1/catalog/series")).Items);
        var exclusions = await fixture.GetAsync<ExcludedMediaSummary[]>($"/api/v1/libraries/{library.Id}/exclusions");
        Assert.Equal(6, exclusions.Length); var directory = Assert.Single(exclusions, value => value.IsDirectory);
        var scan = await fixture.RequestAsync<LibraryScanSummary>(HttpMethod.Delete, $"/api/v1/libraries/{library.Id}/exclusions/{directory.Id}");
        await fixture.WaitScanAsync(scan.Id);
        Assert.Empty(await fixture.GetAsync<ExcludedMediaSummary[]>($"/api/v1/libraries/{library.Id}/exclusions"));
        Assert.Single((await fixture.GetAsync<PagedResponse<SeriesSummary>>("/api/v1/catalog/series")).Items);
        foreach (var name in names) Assert.Equal(new byte[] { 1, 2, 3 }, await File.ReadAllBytesAsync(Path.Combine(path, name)));
    }

    internal static byte[] Png(int width, int height)
    {
        using var bitmap = new SKBitmap(width, height); bitmap.Erase(SKColors.CornflowerBlue);
        using var image = SKImage.FromBitmap(bitmap); using var data = image.Encode(SKEncodedImageFormat.Png, 100); return data.ToArray();
    }

    private sealed class Fixture : IDisposable
    {
        public const string Password = "correct horse battery staple";
        public AureliaServerFactory Factory { get; } = new();
        public HttpClient Client { get; private set; } = null!;
        public AuthenticationResponse Owner { get; private set; } = null!;
        public static async Task<Fixture> CreateAsync()
        {
            var result = new Fixture(); result.Client = result.Factory.CreateClient(); result.Owner = await ApiTestClient.SetupOwnerAsync(result.Client); return result;
        }
        public void Dispose() { Client.Dispose(); Factory.Dispose(); }
        public async Task<MediaItem> MovieAsync(string name, bool metadata = true, Guid? libraryId = null)
        {
            using var scope = Factory.Services.CreateScope(); var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var library = libraryId is { } id ? await database.LibraryRoots.SingleAsync(root => root.Id == id) : new LibraryRoot
            { Id = Guid.NewGuid(), Name = "Synthetic library", Path = Path.Combine(Factory.DataDirectory, "Media", Guid.NewGuid().ToString("N")), Kind = LibraryKind.Movies, CreatedAt = DateTimeOffset.UtcNow };
            library.NormalizedPath = MediaPath.Normalize(library.Path); Directory.CreateDirectory(library.Path);
            if (libraryId is null) database.LibraryRoots.Add(library);
            var source = Path.Combine(library.Path, name); await File.WriteAllBytesAsync(source, [1, 2, 3]);
            var item = new MediaItem
            {
                Id = Guid.NewGuid(),
                LibraryRootId = library.Id,
                SourcePath = source,
                NormalizedSourcePath = MediaPath.Normalize(source),
                DetectedTitle = Path.GetFileNameWithoutExtension(name),
                Kind = MediaKind.Movie,
                Year = 2010,
                Extension = ".mkv",
                Availability = MediaAvailability.Available,
                FileSize = 3,
                FileModifiedAt = File.GetLastWriteTimeUtc(source),
                CreatedAt = DateTimeOffset.UtcNow,
                UpdatedAt = DateTimeOffset.UtcNow
            };
            if (metadata) item.Metadata = new MediaMetadata { MediaItemId = item.Id, ProviderTitle = "Original Title", ProviderOverview = "Provider Description", ProviderReleaseDate = "2010-01-01", UpdatedAt = DateTimeOffset.UtcNow };
            database.MediaItems.Add(item); await database.SaveChangesAsync(); return item;
        }
        public async Task<HttpResponseMessage> SendAsync(HttpMethod method, string path, object? body = null)
        {
            using var request = ApiTestClient.Authorized(method, path, Owner.Token, body); return await ApiTestClient.SendAsync(Client, request);
        }
        public async Task<T> RequestAsync<T>(HttpMethod method, string path, object? body = null)
        { using var response = await SendAsync(method, path, body); response.EnsureSuccessStatusCode(); return await ApiTestClient.ReadAsync<T>(response); }
        public Task<T> GetAsync<T>(string path) => RequestAsync<T>(HttpMethod.Get, path);
        public Task<MediaEditorDocument> SaveAsync(Guid id, MediaEditorDocument draft, MediaEditorValues values, IReadOnlyList<string> fields, string? source = null) =>
            RequestAsync<MediaEditorDocument>(HttpMethod.Put, $"/api/v1/media/{id}/editor", new SaveMediaEditorRequest(draft.Revision, values, fields, source));
        public async Task<HttpResponseMessage> UploadAsync(Guid media, byte[] bytes)
        {
            using var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/media/{media}/editor/uploads", Owner.Token);
            request.Content = new ByteArrayContent(bytes); request.Content.Headers.ContentType = new MediaTypeHeaderValue("image/png"); return await Client.SendAsync(request);
        }
        public async Task ScanAsync(Guid root) { var scan = await RequestAsync<LibraryScanSummary>(HttpMethod.Post, $"/api/v1/libraries/{root}/scans"); await WaitScanAsync(scan.Id); }
        public async Task WaitScanAsync(Guid id)
        {
            for (var attempt = 0; attempt < 100; attempt++)
            {
                var scan = await GetAsync<LibraryScanSummary>($"/api/v1/scans/{id}");
                if (scan.State == LibraryScanState.Completed) return;
                Assert.False(scan.State is LibraryScanState.Failed or LibraryScanState.Cancelled, scan.Error); await Task.Delay(30);
            }
            throw new TimeoutException("Synthetic scan did not complete.");
        }
    }
}
