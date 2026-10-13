using System.Net;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ImportPlanningApiTests
{
    [Fact]
    public async Task NestedFeaturettesWatcherScanRetainsFullTitleAndSeasonContext()
    {
        using var fixture = await Fixture.CreateAsync();
        fixture.Touch("Series/Season 2/Series S02E01.mkv");
        fixture.Touch("Series/Season 2/Featurettes/Making of.mkv");
        fixture.Touch("Chernobyl/Chernobyl S01E01.mkv");
        fixture.Touch("Chernobyl/Featurettes/Elements/Part 1.mkv");
        var root = await fixture.LibraryAsync(); var preview = await fixture.AnalyzeAsync(root.Id);
        await fixture.WaitAsync((await fixture.ConfirmAsync(root.Id, preview)).Id);
        Dictionary<string, Guid> original;
        using (var scope = fixture.Factory.Services.CreateScope())
            original = await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().MediaItems.ToDictionaryAsync(item => item.SourcePath, item => item.Id);
        fixture.Touch("Series/Season 2/Featurettes/Interview.mkv");
        LibraryScanSummary targeted;
        using (var scope = fixture.Factory.Services.CreateScope())
            targeted = await scope.ServiceProvider.GetRequiredService<LibraryService>().StartScanAsync(root.Id, LibraryScanTrigger.FileChange, "Series/Season 2/Featurettes", CancellationToken.None);
        await fixture.WaitAsync(targeted.Id);
        using var verification = fixture.Factory.Services.CreateScope();
        var items = await verification.ServiceProvider.GetRequiredService<AureliaDbContext>().MediaItems.ToArrayAsync();
        Assert.Equal(2, items.Count(item => item.Kind == MediaKind.Series)); Assert.Equal(2, items.Count(item => item.Kind == MediaKind.Episode));
        Assert.Equal(3, items.Count(item => item.Kind == MediaKind.Extra)); Assert.DoesNotContain(items, item => item.Kind == MediaKind.Movie);
        var series = Assert.Single(items, item => item.Kind == MediaKind.Series && item.DetectedTitle == "Series");
        foreach (var extra in items.Where(item => item.Kind == MediaKind.Extra && item.ParentId == series.Id)) Assert.Equal(2, extra.SeasonNumber);
        var chernobyl = Assert.Single(items, item => item.Kind == MediaKind.Series && item.DetectedTitle == "Chernobyl");
        Assert.Null(Assert.Single(items, item => item.Kind == MediaKind.Extra && item.ParentId == chernobyl.Id).SeasonNumber);
        foreach (var item in items.Where(item => original.ContainsKey(item.SourcePath))) Assert.Equal(original[item.SourcePath], item.Id);
        Assert.All(items, item => Assert.Equal(MediaAvailability.Available, item.Availability));
    }

    [Fact]
    public async Task RemovingAndReincludingTitleInvalidatesPreviewsWithoutChangingVideoStatData()
    {
        using var fixture = await Fixture.CreateAsync(); fixture.Touch("Film.mkv");
        var root = await fixture.LibraryAsync(); var first = await fixture.AnalyzeAsync(root.Id);
        await fixture.WaitAsync((await fixture.ConfirmAsync(root.Id, first)).Id);
        Guid movieId;
        using (var scope = fixture.Factory.Services.CreateScope())
            movieId = (await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().MediaItems.SingleAsync()).Id;
        var beforeRemove = await fixture.AnalyzeAsync(root.Id);
        _ = await fixture.RequestAsync<LibraryMutationResult>(HttpMethod.Delete, $"/api/v1/media/{movieId}");
        using (var stale = await fixture.SendAsync(HttpMethod.Post, $"{Fixture.PreviewPath(root.Id, beforeRemove)}/confirm", new ConfirmImportPreviewRequest(beforeRemove.Revision)))
            Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
        var beforeRestore = await fixture.AnalyzeAsync(root.Id); Assert.Equal(1, beforeRestore.Counts.Ignored);
        var excluded = Assert.Single(await fixture.GetAsync<ExcludedMediaSummary[]>($"/api/v1/libraries/{root.Id}/exclusions"));
        var restore = await fixture.RequestAsync<LibraryScanSummary>(HttpMethod.Delete, $"/api/v1/libraries/{root.Id}/exclusions/{excluded.Id}");
        await fixture.WaitAsync(restore.Id);
        using var changed = await fixture.SendAsync(HttpMethod.Post, $"{Fixture.PreviewPath(root.Id, beforeRestore)}/confirm", new ConfirmImportPreviewRequest(beforeRestore.Revision));
        Assert.Equal(HttpStatusCode.Conflict, changed.StatusCode); Assert.True(File.Exists(Path.Combine(fixture.Directory, "Film.mkv")));
    }

    [Fact]
    public async Task FileReassociationInvalidatesStoredPreviewButMetadataOnlyEditsDoNot()
    {
        using var fixture = await Fixture.CreateAsync(); fixture.Touch("Film.mkv");
        var root = await fixture.LibraryAsync(); var first = await fixture.AnalyzeAsync(root.Id);
        await fixture.WaitAsync((await fixture.ConfirmAsync(root.Id, first)).Id);
        Guid id; long originalRevision;
        using (var scope = fixture.Factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            id = (await database.MediaItems.SingleAsync()).Id; originalRevision = (await database.LibraryRoots.SingleAsync()).ImportAssignmentRevision;
        }
        fixture.Touch("Replacement.mkv"); var preview = await fixture.AnalyzeAsync(root.Id);
        var editor = await fixture.GetAsync<MediaEditorDocument>($"/api/v1/media/{id}/editor");
        var edited = await fixture.RequestAsync<MediaEditorDocument>(HttpMethod.Put, $"/api/v1/media/{id}/editor", new SaveMediaEditorRequest(editor.Revision, editor.Values with { Title = "Manual Title" }, ["title"]));
        using (var scope = fixture.Factory.Services.CreateScope())
            Assert.Equal(originalRevision, (await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().LibraryRoots.SingleAsync()).ImportAssignmentRevision);
        _ = await fixture.RequestAsync<MediaEditorDocument>(HttpMethod.Put, $"/api/v1/media/{id}/editor", new SaveMediaEditorRequest(edited.Revision, edited.Values, edited.OverrideFields, "Replacement.mkv"));
        using var stale = await fixture.SendAsync(HttpMethod.Post, $"{Fixture.PreviewPath(root.Id, preview)}/confirm", new ConfirmImportPreviewRequest(preview.Revision));
        Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
        using var verification = fixture.Factory.Services.CreateScope();
        Assert.Equal(1, await verification.ServiceProvider.GetRequiredService<AureliaDbContext>().MediaItems.CountAsync());
    }

    [Fact]
    public async Task FileReassociationAfterConfirmationStopsItsQueuedResolution()
    {
        var scanner = new PausedWorkerScanner(); scanner.Continue.Set();
        using var fixture = await Fixture.CreateAsync(scanner); fixture.Touch("Film.mkv");
        var root = await fixture.LibraryAsync(); var first = await fixture.AnalyzeAsync(root.Id);
        await fixture.WaitAsync((await fixture.ConfirmAsync(root.Id, first)).Id);
        Guid id;
        using (var scope = fixture.Factory.Services.CreateScope())
            id = (await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().MediaItems.SingleAsync()).Id;
        scanner.Continue.Reset(); scanner.Started.Reset(); fixture.Touch("Replacement.mkv");
        var preview = await fixture.AnalyzeAsync(root.Id); var scan = await fixture.ConfirmAsync(root.Id, preview);
        Assert.True(await Task.Run(() => scanner.Started.Wait(TimeSpan.FromSeconds(5))));
        var editor = await fixture.GetAsync<MediaEditorDocument>($"/api/v1/media/{id}/editor");
        _ = await fixture.RequestAsync<MediaEditorDocument>(HttpMethod.Put, $"/api/v1/media/{id}/editor", new SaveMediaEditorRequest(editor.Revision, editor.Values, editor.OverrideFields, "Replacement.mkv"));
        scanner.Continue.Set(); LibraryScanSummary? status = null;
        for (var attempt = 0; attempt < 200; attempt++)
        {
            status = await fixture.GetAsync<LibraryScanSummary>($"/api/v1/scans/{scan.Id}");
            if (status.State == LibraryScanState.Failed) break;
            await Task.Delay(25);
        }
        Assert.NotNull(status); Assert.Equal(LibraryScanState.Failed, status.State); Assert.Contains("binding changed", status.Error);
        using var verification = fixture.Factory.Services.CreateScope();
        var movie = await verification.ServiceProvider.GetRequiredService<AureliaDbContext>().MediaItems.SingleAsync();
        Assert.Equal(id, movie.Id); Assert.EndsWith("Replacement.mkv", movie.SourcePath, StringComparison.Ordinal);
    }

    [Fact]
    public async Task LegacyCombineCannotDiscardSavedAssignmentsOrOpenPreviews()
    {
        using var fixture = await Fixture.CreateAsync(); fixture.Touch("Movies/Film.mkv");
        var root = await fixture.RequestAsync<LibrarySummary>(HttpMethod.Post, "/api/v1/libraries", new CreateLibraryRequest("Movies", Path.Combine(fixture.Directory, "Movies"), LibraryKind.Movies));
        using (var scope = fixture.Factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            database.LibraryImportAssignments.Add(new LibraryImportAssignment { Id = Guid.NewGuid(), LibraryRootId = root.Id, RelativePath = "Film.mkv", NormalizedRelativePath = "FILM.MKV", Kind = MediaKind.Movie });
            await database.SaveChangesAsync();
        }
        using (var blocked = await fixture.SendAsync(HttpMethod.Post, "/api/v1/libraries", new CreateLibraryRequest("Combined", fixture.Directory, LibraryKind.Automatic, CombineExisting: true)))
            Assert.Equal(HttpStatusCode.Conflict, blocked.StatusCode);
        using (var scope = fixture.Factory.Services.CreateScope())
            await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().LibraryImportAssignments.ExecuteDeleteAsync();
        _ = await fixture.AnalyzeAsync(root.Id);
        using (var blocked = await fixture.SendAsync(HttpMethod.Post, "/api/v1/libraries", new CreateLibraryRequest("Combined", fixture.Directory, LibraryKind.Automatic, CombineExisting: true)))
            Assert.Equal(HttpStatusCode.Conflict, blocked.StatusCode);
        Assert.Equal(root.Id, Assert.Single(await fixture.GetAsync<LibrarySummary[]>("/api/v1/libraries")).Id);
    }

    [Fact]
    public async Task ExpiredAndDeletedRootPreviewsCannotBeUsedAndDraftsCascadeWithTheRoot()
    {
        using var fixture = await Fixture.CreateAsync(); fixture.Touch("Film.mkv");
        var root = await fixture.LibraryAsync(); var expired = await fixture.AnalyzeAsync(root.Id);
        using (var scope = fixture.Factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var stored = await database.LibraryImportPreviews.SingleAsync(); stored.CreatedAt = DateTimeOffset.UtcNow.AddDays(-2);
            await database.SaveChangesAsync();
        }
        using (var page = await fixture.SendAsync(HttpMethod.Get, $"{Fixture.PreviewPath(root.Id, expired)}/items"))
            Assert.Equal(HttpStatusCode.Conflict, page.StatusCode);
        using (var confirm = await fixture.SendAsync(HttpMethod.Post, $"{Fixture.PreviewPath(root.Id, expired)}/confirm", new ConfirmImportPreviewRequest(expired.Revision)))
            Assert.Equal(HttpStatusCode.Conflict, confirm.StatusCode);
        var current = await fixture.AnalyzeAsync(root.Id);
        using (var scope = fixture.Factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            database.LibraryImportAssignments.Add(new LibraryImportAssignment { Id = Guid.NewGuid(), LibraryRootId = root.Id, RelativePath = "Film.mkv", NormalizedRelativePath = "FILM.MKV", Kind = MediaKind.Movie });
            await database.SaveChangesAsync(); await database.LibraryRoots.Where(value => value.Id == root.Id).ExecuteDeleteAsync();
            Assert.False(await database.LibraryImportPreviews.AnyAsync()); Assert.False(await database.LibraryImportAssignments.AnyAsync());
        }
        using var removed = await fixture.SendAsync(HttpMethod.Post, $"{Fixture.PreviewPath(root.Id, current)}/confirm", new ConfirmImportPreviewRequest(current.Revision));
        Assert.Equal(HttpStatusCode.NotFound, removed.StatusCode);
    }

    [Fact]
    public async Task ProtectedMovieBindingOverridesImportRulesAndSurvivesAnEpisodeLikeRename()
    {
        using var fixture = await Fixture.CreateAsync(); fixture.Touch("Film.mkv");
        var root = await fixture.LibraryAsync(); var preview = await fixture.AnalyzeAsync(root.Id);
        await fixture.WaitAsync((await fixture.ConfirmAsync(root.Id, preview)).Id);
        Guid id;
        using (var scope = fixture.Factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var movie = await database.MediaItems.SingleAsync(); id = movie.Id;
            movie.ManualSourceBinding = true; movie.DetectedTitle = "My protected movie";
            database.LibraryImportAssignments.Add(new LibraryImportAssignment { Id = Guid.NewGuid(), LibraryRootId = root.Id, RelativePath = "Film.mkv", NormalizedRelativePath = "FILM.MKV", Kind = null });
            await database.SaveChangesAsync();
        }
        var protectedPreview = await fixture.AnalyzeAsync(root.Id); Assert.Equal(1, protectedPreview.Counts.Movies); Assert.Equal(0, protectedPreview.Counts.Ignored);
        File.Move(Path.Combine(fixture.Directory, "Film.mkv"), Path.Combine(fixture.Directory, "Wrong S05E09.mkv"));
        var renamed = await fixture.AnalyzeAsync(root.Id); Assert.Equal(1, renamed.Counts.Movies); Assert.Equal(0, renamed.Counts.Series); Assert.Equal(0, renamed.Counts.Episodes);
        await fixture.WaitAsync((await fixture.ConfirmAsync(root.Id, renamed)).Id);
        using var verification = fixture.Factory.Services.CreateScope();
        var final = await verification.ServiceProvider.GetRequiredService<AureliaDbContext>().MediaItems.SingleAsync();
        Assert.Equal(id, final.Id); Assert.Equal(MediaKind.Movie, final.Kind); Assert.Equal("My protected movie", final.DetectedTitle);
        Assert.EndsWith("Wrong S05E09.mkv", final.SourcePath, StringComparison.Ordinal);
    }

    [Fact]
    public async Task CancellingConfirmedScanLeavesItsSourcesAndCatalogUntouched()
    {
        var scanner = new PausedWorkerScanner(); using var fixture = await Fixture.CreateAsync(scanner); fixture.Touch("Film.mkv");
        var root = await fixture.LibraryAsync(); var preview = await fixture.AnalyzeAsync(root.Id);
        var scan = await fixture.ConfirmAsync(root.Id, preview);
        Assert.True(await Task.Run(() => scanner.Started.Wait(TimeSpan.FromSeconds(5))));
        using (var cancelled = await fixture.SendAsync(HttpMethod.Delete, $"/api/v1/scans/{scan.Id}"))
            Assert.Equal(HttpStatusCode.NoContent, cancelled.StatusCode);
        LibraryScanSummary? status = null;
        for (var attempt = 0; attempt < 200; attempt++)
        {
            status = await fixture.GetAsync<LibraryScanSummary>($"/api/v1/scans/{scan.Id}");
            if (status.State == LibraryScanState.Cancelled) break;
            await Task.Delay(25);
        }
        Assert.NotNull(status); Assert.Equal(LibraryScanState.Cancelled, status.State); Assert.Equal("Cancelled", status.Phase);
        using var scope = fixture.Factory.Services.CreateScope();
        Assert.False(await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().MediaItems.AnyAsync());
        Assert.True(File.Exists(Path.Combine(fixture.Directory, "Film.mkv")));
    }

    [Fact]
    public async Task PartialBackgroundScanPreservesPreviouslyAvailableMediaAndReportsItsError()
    {
        var scanner = new PartialScanner();
        using var fixture = await Fixture.CreateAsync(scanner);
        fixture.Touch("First/First.mkv"); fixture.Touch("Protected/Protected.mkv");
        var root = await fixture.LibraryAsync(); var preview = await fixture.AnalyzeAsync(root.Id);
        var imported = await fixture.ConfirmAsync(root.Id, preview); await fixture.WaitAsync(imported.Id);
        Guid original;
        using (var scope = fixture.Factory.Services.CreateScope())
            original = (await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().MediaItems.SingleAsync(item => item.DetectedTitle == "Protected")).Id;
        scanner.UnreadableRelativePath = "Protected";
        var partial = await fixture.RequestAsync<LibraryScanSummary>(HttpMethod.Post, $"/api/v1/libraries/{root.Id}/scans"); await fixture.WaitAsync(partial.Id);
        var report = await fixture.GetAsync<LibraryScanSummary>($"/api/v1/scans/{partial.Id}");
        Assert.Equal(0, report.MissingFiles); Assert.Equal(1, report.FailedFiles);
        using (var scope = fixture.Factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            Assert.Equal(MediaAvailability.Available, (await database.MediaItems.SingleAsync(item => item.Id == original)).Availability);
            Assert.Equal(LibraryAvailability.Error, (await database.LibraryRoots.SingleAsync()).Availability);
        }
        var failedPreview = await fixture.AnalyzeAsync(root.Id); Assert.Equal(1, failedPreview.Counts.Errors);
        using var blocked = await fixture.SendAsync(HttpMethod.Post, $"{Fixture.PreviewPath(root.Id, failedPreview)}/confirm", new ConfirmImportPreviewRequest(failedPreview.Revision));
        Assert.Equal(HttpStatusCode.Conflict, blocked.StatusCode);
    }
    [Fact]
    public async Task FirstImportIsGatedPaginatedAndPreviewEqualsCommittedCatalog()
    {
        using var fixture = await Fixture.CreateAsync();
        fixture.Touch("Chernobyl/Chernobyl S01E01.mkv");
        fixture.Touch("Chernobyl/Chernobyl S01E02.mkv");
        fixture.Touch("Chernobyl/Featurettes/Elements/Episode 3.mkv");
        fixture.Touch("Truman/Truman (1998).mkv");
        fixture.Touch("Truman/Trailer/Truman Trailer.mkv");
        var root = await fixture.LibraryAsync();
        Assert.True(root.ImportPreviewRequired);
        using (var blocked = await fixture.SendAsync(HttpMethod.Post, $"/api/v1/libraries/{root.Id}/scans"))
            Assert.Equal(HttpStatusCode.Conflict, blocked.StatusCode);
        var preview = await fixture.AnalyzeAsync(root.Id);
        Assert.Equal(5, preview.Counts.Files);
        Assert.Equal(1, preview.Counts.Movies); Assert.Equal(1, preview.Counts.Series);
        Assert.Equal(2, preview.Counts.Episodes); Assert.Equal(1, preview.Counts.Extras); Assert.Equal(1, preview.Counts.Trailers);
        var page = await fixture.GetAsync<ImportPreviewPage>($"{Fixture.PreviewPath(root.Id, preview)}/items?offset=0&limit=2");
        Assert.Equal(2, page.Items.Count); Assert.Equal(6, page.TotalCount);
        using (var scope = fixture.Factory.Services.CreateScope())
            Assert.False(await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().MediaItems.AnyAsync());
        var scan = await fixture.ConfirmAsync(root.Id, preview);
        await fixture.WaitAsync(scan.Id);
        var roots = await fixture.GetAsync<LibrarySummary[]>("/api/v1/libraries");
        Assert.False(Assert.Single(roots).ImportPreviewRequired);
        using (var scope = fixture.Factory.Services.CreateScope())
        {
            var items = await scope.ServiceProvider.GetRequiredService<AureliaDbContext>().MediaItems.ToArrayAsync();
            Assert.Equal(6, items.Length);
            Assert.Null(Assert.Single(items, item => item.Kind == MediaKind.Extra).SeasonNumber);
            Assert.Equal(Assert.Single(items, item => item.Kind == MediaKind.Series).Id,
                Assert.Single(items, item => item.Kind == MediaKind.Extra).ParentId);
        }
        using var reused = await fixture.SendAsync(HttpMethod.Post, $"{Fixture.PreviewPath(root.Id, preview)}/confirm", new ConfirmImportPreviewRequest(preview.Revision));
        Assert.Equal(HttpStatusCode.Conflict, reused.StatusCode);
    }

    [Fact]
    public async Task DirectoryAssignmentAndFileOverridePersistAndCanReturnToAutomatic()
    {
        using var fixture = await Fixture.CreateAsync();
        fixture.Touch("Series/Season 1/Series S01E01.mkv");
        fixture.Touch("Series/Season 2/Series S02E01.mkv");
        fixture.Touch("Loose/Interview.mkv"); fixture.Touch("Loose/Preview.mkv");
        var root = await fixture.LibraryAsync();
        var original = await fixture.AnalyzeAsync(root.Id);
        var draft = await fixture.UpdateAsync(root.Id, original,
            new("Loose", true, MediaKind.Extra, "Series", 2, Category: "Interviews"),
            new("Loose/Preview.mkv", false, MediaKind.Trailer, "Series", null, Title: "Series Trailer"));
        Assert.Equal(1, draft.Counts.Extras); Assert.Equal(1, draft.Counts.Trailers);
        using (var stale = await fixture.SendAsync(HttpMethod.Put, $"{Fixture.PreviewPath(root.Id, draft)}/assignments",
                   new ImportAssignmentsRequest(original.Revision, [new("Loose/Preview.mkv", false, null)])))
            Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
        var scan = await fixture.ConfirmAsync(root.Id, draft); await fixture.WaitAsync(scan.Id);
        var saved = await fixture.GetAsync<ImportAssignmentsSummary>($"/api/v1/libraries/{root.Id}/import-assignments");
        Assert.Equal(2, saved.Assignments.Count);
        var rescanned = await fixture.AnalyzeAsync(root.Id);
        var page = await fixture.GetAsync<ImportPreviewPage>($"{Fixture.PreviewPath(root.Id, rescanned)}/items");
        var extra = Assert.Single(page.Items, item => item.RelativePath == "Loose/Interview.mkv");
        Assert.Equal(MediaKind.Extra, extra.Kind); Assert.Equal(2, extra.SeasonNumber); Assert.Equal("Interviews", extra.Category);
        Assert.Null(Assert.Single(page.Items, item => item.RelativePath == "Loose/Preview.mkv").SeasonNumber);
        var automatic = await fixture.UpdateAsync(root.Id, rescanned, new("Loose", true, null, UseAutomaticDetection: true),
            new("Loose/Preview.mkv", false, null, UseAutomaticDetection: true));
        Assert.True(automatic.Counts.Pending > 0);
        var finalScan = await fixture.ConfirmAsync(root.Id, automatic); await fixture.WaitAsync(finalScan.Id);
        Assert.Empty((await fixture.GetAsync<ImportAssignmentsSummary>($"/api/v1/libraries/{root.Id}/import-assignments")).Assignments);
    }

    [Fact]
    public async Task SourceChangesBadPathsForeignParentsAndUnknownSeasonsAreRejectedWithoutCatalogChanges()
    {
        using var fixture = await Fixture.CreateAsync();
        fixture.Touch("Series/Season 1/Series S01E01.mkv"); fixture.Touch("Loose/Interview.mkv");
        var root = await fixture.LibraryAsync();
        var preview = await fixture.AnalyzeAsync(root.Id);
        foreach (var bad in new[] {
            new ImportAssignmentUpdate("../escape.mkv", false, MediaKind.Movie),
            new ImportAssignmentUpdate("Loose/Interview.mkv", false, MediaKind.Extra, "Another Library/Movie.mkv"),
            new ImportAssignmentUpdate("Loose/Interview.mkv", false, MediaKind.Extra, "Series", 88) })
        {
            using var response = await fixture.SendAsync(HttpMethod.Put, $"{Fixture.PreviewPath(root.Id, preview)}/assignments", new ImportAssignmentsRequest(preview.Revision, [bad]));
            Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        }
        fixture.Touch("Series/Season 1/Series S01E02.mkv");
        using var changed = await fixture.SendAsync(HttpMethod.Post, $"{Fixture.PreviewPath(root.Id, preview)}/confirm", new ConfirmImportPreviewRequest(preview.Revision));
        Assert.Equal(HttpStatusCode.Conflict, changed.StatusCode);
        using var scope = fixture.Factory.Services.CreateScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        Assert.False(await database.MediaItems.AnyAsync()); Assert.True((await database.LibraryRoots.SingleAsync()).ImportPreviewRequired);
    }

    [Fact]
    public async Task UnsharedAdministratorsCannotReadAnalyzeOrEditAnotherLibrary()
    {
        using var fixture = await Fixture.CreateAsync();
        fixture.Touch("Film.mkv");
        var root = await fixture.LibraryAsync(); var preview = await fixture.AnalyzeAsync(root.Id);
        var admin = await fixture.RequestAsync<UserSummary>(HttpMethod.Post, "/api/v1/users", new CreateUserRequest("restricted-admin", "long isolated test password", UserRole.Admin, ApiTestClient.TestPin));
        var login = await fixture.RequestAsync<AuthenticationResponse>(HttpMethod.Post, "/api/v1/auth/login", new LoginRequest(admin.Username, "long isolated test password", "Restricted Mac"));
        foreach (var route in new[] { $"/api/v1/libraries/{root.Id}/import-assignments", $"{Fixture.PreviewPath(root.Id, preview)}/items" })
        {
            using var request = ApiTestClient.Authorized(HttpMethod.Get, route, login.Token);
            using var response = await fixture.Client.SendAsync(request); Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        }
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/libraries/{root.Id}/import-preview", login.Token))
        using (var response = await fixture.Client.SendAsync(request)) Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        using (var request = ApiTestClient.Authorized(HttpMethod.Post, $"{Fixture.PreviewPath(root.Id, preview)}/confirm", login.Token, new ConfirmImportPreviewRequest(preview.Revision)))
        using (var response = await fixture.Client.SendAsync(request)) Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
    }

    [Fact]
    public async Task ExclusionsRemainIgnoredAndLegacyFolderDecisionsCanBeCleared()
    {
        using var fixture = await Fixture.CreateAsync();
        fixture.Touch("Ambiguous/One.mkv"); fixture.Touch("Ambiguous/Two.mkv"); fixture.Touch("Removed.mkv");
        var root = await fixture.LibraryAsync();
        using (var scope = fixture.Factory.Services.CreateScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            database.MediaExclusions.Add(new MediaExclusion { Id = Guid.NewGuid(), LibraryRootId = root.Id, RelativePath = "Removed.mkv", NormalizedSourcePath = Aurelia.Server.Services.MediaPath.Normalize(Path.Combine(fixture.Directory, "Removed.mkv")) });
            database.LibraryDiscoveries.Add(new LibraryDiscovery { Id = Guid.NewGuid(), LibraryRootId = root.Id, RelativePath = "Ambiguous", NormalizedRelativePath = "AMBIGUOUS", DetectedTitle = "Ambiguous", Decision = ClassificationDecision.Ignore, Reason = "manual_ignore", CreatedAt = DateTimeOffset.UtcNow, UpdatedAt = DateTimeOffset.UtcNow });
            await database.SaveChangesAsync();
        }
        var preview = await fixture.AnalyzeAsync(root.Id); Assert.Equal(3, preview.Counts.Ignored);
        var automatic = await fixture.UpdateAsync(root.Id, preview, new ImportAssignmentUpdate("Ambiguous", true, null, UseAutomaticDetection: true));
        Assert.Equal(1, automatic.Counts.Ignored); Assert.Equal(2, automatic.Counts.Pending);
        var scan = await fixture.ConfirmAsync(root.Id, automatic); await fixture.WaitAsync(scan.Id);
        var next = await fixture.AnalyzeAsync(root.Id); Assert.Equal(1, next.Counts.Ignored); Assert.Equal(2, next.Counts.Pending);
    }

    private sealed class Fixture : IDisposable
    {
        private Fixture(AureliaServerFactory factory, HttpClient client, string token, string directory)
        { Factory = factory; Client = client; Token = token; Directory = directory; }
        public AureliaServerFactory Factory { get; }
        public HttpClient Client { get; }
        private string Token { get; }
        public string Directory { get; }
        public static async Task<Fixture> CreateAsync(IMediaLibraryScanner? scanner = null)
        {
            var directory = TestPaths.CreateDataDirectory(); System.IO.Directory.CreateDirectory(directory);
            var factory = new AureliaServerFactory(configureServices: services =>
            {
                if (scanner is null) return;
                services.RemoveAll<IMediaLibraryScanner>(); services.AddSingleton(scanner);
            }); var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);
            return new(factory, client, owner.Token, directory);
        }
        public void Touch(string relative)
        {
            var path = Path.Combine(Directory, relative); System.IO.Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllBytes(path, []);
        }
        public Task<LibrarySummary> LibraryAsync() => RequestAsync<LibrarySummary>(HttpMethod.Post, "/api/v1/libraries", new CreateLibraryRequest("Import Fixture", Directory, LibraryKind.Automatic, RequireImportPreview: true));
        public Task<ImportPreviewSummary> AnalyzeAsync(Guid root) => RequestAsync<ImportPreviewSummary>(HttpMethod.Post, $"/api/v1/libraries/{root}/import-preview");
        public static string PreviewPath(Guid root, ImportPreviewSummary preview) => $"/api/v1/libraries/{root}/import-preview/{preview.PreviewId}";
        public Task<ImportPreviewSummary> UpdateAsync(Guid root, ImportPreviewSummary preview, params ImportAssignmentUpdate[] rules) => RequestAsync<ImportPreviewSummary>(HttpMethod.Put, $"{PreviewPath(root, preview)}/assignments", new ImportAssignmentsRequest(preview.Revision, rules));
        public Task<LibraryScanSummary> ConfirmAsync(Guid root, ImportPreviewSummary preview) => RequestAsync<LibraryScanSummary>(HttpMethod.Post, $"{PreviewPath(root, preview)}/confirm", new ConfirmImportPreviewRequest(preview.Revision));
        public Task<T> GetAsync<T>(string path) => RequestAsync<T>(HttpMethod.Get, path);
        public async Task<HttpResponseMessage> SendAsync(HttpMethod method, string path, object? body = null)
        { using var request = ApiTestClient.Authorized(method, path, Token, body); return await ApiTestClient.SendAsync(Client, request); }
        public async Task<T> RequestAsync<T>(HttpMethod method, string path, object? body = null)
        { using var response = await SendAsync(method, path, body); Assert.True(response.IsSuccessStatusCode, $"{response.StatusCode}: {await response.Content.ReadAsStringAsync()}"); return await ApiTestClient.ReadAsync<T>(response); }
        public async Task WaitAsync(Guid scan)
        {
            for (var attempt = 0; attempt < 200; attempt++)
            {
                var status = await GetAsync<LibraryScanSummary>($"/api/v1/scans/{scan}");
                if (status.State == LibraryScanState.Completed) { await Task.Delay(75); return; }
                Assert.DoesNotContain(status.State, new[] { LibraryScanState.Failed, LibraryScanState.Cancelled });
                await Task.Delay(25);
            }
            Assert.Fail("The isolated import did not finish.");
        }
        public void Dispose()
        { Client.Dispose(); Factory.Dispose(); if (System.IO.Directory.Exists(Directory)) System.IO.Directory.Delete(Directory, true); }
    }

    private sealed class PartialScanner : IMediaLibraryScanner
    {
        public string? UnreadableRelativePath { get; set; }
        public MediaScanDiscovery Scan(string rootPath, LibraryKind kind, IReadOnlyList<ExistingEpisodeBinding> existingEpisodes, Action<int>? progress,
            CancellationToken cancellationToken, IReadOnlyList<ExistingClassificationDecision>? classificationDecisions = null,
            IReadOnlyList<ExistingMovieBinding>? existingMovies = null, IReadOnlyList<ExistingImportReviewDecision>? importReviewDecisions = null,
            IReadOnlyList<ExistingImportAssignment>? assignments = null, Action<string>? onPhase = null)
        {
            var result = new MediaLibraryScanner().Scan(rootPath, kind, existingEpisodes, progress, cancellationToken, classificationDecisions, existingMovies, importReviewDecisions, assignments, onPhase);
            if (UnreadableRelativePath is null) return result;
            var hidden = MediaPath.Normalize(Path.Combine(rootPath, UnreadableRelativePath));
            var files = result.Files!.Where(file => !MediaPath.IsSameOrDescendant(MediaPath.Normalize(file.SourcePath), hidden)).ToArray();
            return result with
            {
                Items = result.Items.Where(item => !MediaPath.IsSameOrDescendant(MediaPath.Normalize(item.SourcePath), hidden)).ToArray(),
                Files = files,
                FilesDiscovered = files.Length,
                Issues = [.. result.Issues, new ScanDiscoveryIssue("unreadable_directory", "Synthetic denied directory.", Path.Combine(rootPath, UnreadableRelativePath))]
            };
        }
    }

    private sealed class PausedWorkerScanner : IMediaLibraryScanner
    {
        public ManualResetEventSlim Started { get; } = new(false);
        public ManualResetEventSlim Continue { get; } = new(false);
        public MediaScanDiscovery Scan(string rootPath, LibraryKind kind, IReadOnlyList<ExistingEpisodeBinding> existingEpisodes, Action<int>? progress,
            CancellationToken cancellationToken, IReadOnlyList<ExistingClassificationDecision>? classificationDecisions = null,
            IReadOnlyList<ExistingMovieBinding>? existingMovies = null, IReadOnlyList<ExistingImportReviewDecision>? importReviewDecisions = null,
            IReadOnlyList<ExistingImportAssignment>? assignments = null, Action<string>? onPhase = null)
        {
            if (progress is not null)
            {
                onPhase?.Invoke("Discovering"); Started.Set();
                Continue.Wait(cancellationToken);
            }
            return new MediaLibraryScanner().Scan(rootPath, kind, existingEpisodes, progress, cancellationToken,
                classificationDecisions, existingMovies, importReviewDecisions, assignments, onPhase);
        }
    }
}
