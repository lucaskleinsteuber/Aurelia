using Tarven.Contracts;
using Tarven.Server.Data;
using Tarven.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Tarven.Server.Tests;

public sealed class SyncAndMutationTests
{
    [Fact]
    public async Task RemovingLibraryNotifiesEntireLibraryAndSelectedTitleProfiles()
    {
        var rootDir = Path.Combine(TestPaths.CreateDataDirectory(), "SyncRemove");
        Directory.CreateDirectory(rootDir);
        var filmPath = Path.Combine(rootDir, "Solar Drift (2024).mkv");
        await File.WriteAllBytesAsync(filmPath, [1, 2, 3, 4]);
        try
        {
            using var factory = new TarvenServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);

            Guid libraryId;
            Guid movieId;
            using (var createLib = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries", owner.Token,
                new CreateLibraryRequest("Movies", rootDir, LibraryKind.Movies)))
            using (var libRes = await client.SendAsync(createLib))
            {
                libRes.EnsureSuccessStatusCode();
                libraryId = (await ApiTestClient.ReadAsync<LibrarySummary>(libRes)).Id;
            }
            await RunScanToCompletionAsync(factory, client, owner.Token, libraryId);
            using (var scope = factory.Services.CreateScope())
            {
                var db = scope.ServiceProvider.GetRequiredService<TarvenDbContext>();
                movieId = (await db.MediaItems.AsNoTracking().SingleAsync(item => item.LibraryRootId == libraryId)).Id;
            }

            // Create an EntireLibrary user and a SelectedTitles user with a grant to the movie.
            using (var createEntire = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
                new CreateUserRequest("viewer-entire", null, UserRole.User, ApiTestClient.TestPin,
                    AccessMode: ProfileAccessMode.EntireLibrary, DisplayName: "Viewer Entire")))
            using (var res = await client.SendAsync(createEntire))
                res.EnsureSuccessStatusCode();

            using (var createSelected = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
                new CreateUserRequest("viewer-selected", null, UserRole.User, ApiTestClient.TestPin,
                    AccessMode: ProfileAccessMode.SelectedTitles, TitleIds: [movieId], DisplayName: "Viewer Selected")))
            using (var res = await client.SendAsync(createSelected))
                res.EnsureSuccessStatusCode();

            var entireViewer = await ApiTestClient.ReadAsync<AuthenticationResponse>(
                await ApiTestClient.LoginAsync(client, new LoginRequest("Viewer Entire", "unused", "Device 1")));
            var selectedViewer = await ApiTestClient.ReadAsync<AuthenticationResponse>(
                await ApiTestClient.LoginAsync(client, new LoginRequest("Viewer Selected", "unused", "Device 2")));

            var entireBefore = await GetSyncAsync(client, entireViewer.Token, null);
            var selectedBefore = await GetSyncAsync(client, selectedViewer.Token, null);

            // Remove the library through LibraryMutationService (the same path as DELETE /api/v1/libraries/{id} and reset).
            using (var scope = factory.Services.CreateScope())
            {
                var mutations = scope.ServiceProvider.GetRequiredService<LibraryMutationService>();
                var preview = await mutations.PreviewAsync([libraryId], CancellationToken.None);
                await mutations.ResetAsync(owner.User.Id, new ResetLibraryRequest([libraryId], preview.Revision), CancellationToken.None);
            }

            var entireAfter = await GetSyncAsync(client, entireViewer.Token, entireBefore.Cursor);
            var selectedAfter = await GetSyncAsync(client, selectedViewer.Token, selectedBefore.Cursor);

            Assert.Contains(SyncChangeArea.Catalog, entireAfter.ChangedAreas);
            Assert.Contains(SyncChangeArea.Catalog, selectedAfter.ChangedAreas);
        }
        finally { Directory.Delete(Path.GetDirectoryName(rootDir)!, recursive: true); }
    }

    [Fact]
    public async Task UnchangedRescanWritesZeroCatalogSyncChangesAndLeavesSeriesUpdatedAtAlone()
    {
        var rootDir = Path.Combine(TestPaths.CreateDataDirectory(), "SyncNoOpScan");
        var showDir = Path.Combine(rootDir, "Starlight", "Season 01");
        Directory.CreateDirectory(showDir);
        await File.WriteAllBytesAsync(Path.Combine(showDir, "Starlight - S01E01 - Pilot.mkv"), [1, 2, 3, 4]);
        await File.WriteAllBytesAsync(Path.Combine(showDir, "Starlight - S01E02 - Orbit.mkv"), [5, 6, 7, 8]);
        try
        {
            using var factory = new TarvenServerFactory();
            using var client = factory.CreateClient();
            var owner = await ApiTestClient.SetupOwnerAsync(client);

            Guid libraryId;
            using (var createLib = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/libraries", owner.Token,
                new CreateLibraryRequest("TV", rootDir, LibraryKind.TvShows)))
            using (var libRes = await client.SendAsync(createLib))
            {
                libRes.EnsureSuccessStatusCode();
                libraryId = (await ApiTestClient.ReadAsync<LibrarySummary>(libRes)).Id;
            }

            await RunScanToCompletionAsync(factory, client, owner.Token, libraryId);

            var syncBefore = await GetSyncAsync(client, owner.Token, null);
            DateTimeOffset seriesUpdatedBefore;
            long maxCursorBefore;
            using (var scope = factory.Services.CreateScope())
            {
                var db = scope.ServiceProvider.GetRequiredService<TarvenDbContext>();
                var series = await db.MediaItems.AsNoTracking().SingleAsync(item => item.Kind == MediaKind.Series);
                seriesUpdatedBefore = series.UpdatedAt;
                maxCursorBefore = await db.SyncChanges.AsNoTracking().Select(c => (long?)c.Cursor).MaxAsync() ?? 0;
            }

            await Task.Delay(25);
            await RunScanToCompletionAsync(factory, client, owner.Token, libraryId);

            var syncAfter = await GetSyncAsync(client, owner.Token, syncBefore.Cursor);
            Assert.DoesNotContain(SyncChangeArea.Catalog, syncAfter.ChangedAreas);

            using (var scope = factory.Services.CreateScope())
            {
                var db = scope.ServiceProvider.GetRequiredService<TarvenDbContext>();
                var series = await db.MediaItems.AsNoTracking().SingleAsync(item => item.Kind == MediaKind.Series);
                var newCatalogChanges = await db.SyncChanges.AsNoTracking()
                    .Where(c => c.Cursor > maxCursorBefore && c.Area == SyncChangeArea.Catalog)
                    .ToListAsync();
                Assert.Empty(newCatalogChanges);
                Assert.Equal(seriesUpdatedBefore, series.UpdatedAt);
            }
        }
        finally { Directory.Delete(Path.GetDirectoryName(rootDir)!, recursive: true); }
    }

    private static async Task<SyncChangesResponse> GetSyncAsync(HttpClient client, string token, long? after)
    {
        var url = after is { } cursor ? $"/api/v1/sync/changes?after={cursor}" : "/api/v1/sync/changes";
        using var request = ApiTestClient.Authorized(HttpMethod.Get, url, token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<SyncChangesResponse>(response);
    }

    private static async Task RunScanToCompletionAsync(TarvenServerFactory factory, HttpClient client, string token, Guid libraryId)
    {
        Guid scanId;
        using (var startReq = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/libraries/{libraryId}/scans", token))
        using (var startRes = await client.SendAsync(startReq))
        {
            startRes.EnsureSuccessStatusCode();
            scanId = (await ApiTestClient.ReadAsync<LibraryScanSummary>(startRes)).Id;
        }
        var deadline = DateTimeOffset.UtcNow.AddSeconds(15);
        while (DateTimeOffset.UtcNow < deadline)
        {
            using var scope = factory.Services.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<TarvenDbContext>();
            var state = await db.LibraryScans.AsNoTracking().Where(s => s.Id == scanId).Select(s => s.State).SingleAsync();
            if (state == LibraryScanState.Completed) return;
            Assert.NotEqual(LibraryScanState.Failed, state);
            await Task.Delay(50);
        }
        throw new TimeoutException("Library scan did not complete in time.");
    }
}
