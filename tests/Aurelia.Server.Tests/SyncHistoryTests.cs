using System.Net;
using System.Net.Http.Json;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class SyncHistoryTests
{
    [Fact]
    public async Task ALibraryChangeByAnAdminReachesEveryProfileWithAccess()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var adminId = Guid.NewGuid();
        var libraryViewerId = Guid.NewGuid();
        var titleViewerId = Guid.NewGuid();
        var libraryId = Guid.NewGuid();
        var mediaId = Guid.NewGuid();
        await using (var seed = factory.Services.CreateAsyncScope())
        {
            var database = seed.ServiceProvider.GetRequiredService<AureliaDbContext>();
            var now = DateTimeOffset.UtcNow;
            var root = Path.Combine(factory.DataDirectory, "Invented Sync Library");
            var library = new LibraryRoot
            {
                Id = libraryId,
                Name = "Invented",
                Path = root,
                NormalizedPath = MediaPath.Normalize(root),
                Kind = LibraryKind.Movies,
                Availability = LibraryAvailability.Available,
                CreatedAt = now,
            };
            var path = Path.Combine(root, "Invented Film.mkv");
            database.MediaItems.Add(new MediaItem
            {
                Id = mediaId,
                LibraryRoot = library,
                LibraryRootId = libraryId,
                Kind = MediaKind.Movie,
                SourcePath = path,
                NormalizedSourcePath = MediaPath.Normalize(path),
                DetectedTitle = "Invented Film",
                Category = string.Empty,
                Extension = ".mkv",
                FileSize = 1,
                FileModifiedAt = now,
                Availability = MediaAvailability.Available,
                CreatedAt = now,
                UpdatedAt = now,
            });
            foreach (var (id, role, mode) in new[] { (adminId, UserRole.Admin, ProfileAccessMode.LegacyLibraries),
                         (libraryViewerId, UserRole.User, ProfileAccessMode.LegacyLibraries), (titleViewerId, UserRole.User, ProfileAccessMode.SelectedTitles) })
                database.Users.Add(new ServerUser
                {
                    Id = id,
                    Username = $"invented {id:N}",
                    NormalizedUsername = $"INVENTED {id:N}",
                    Role = role,
                    PasswordHash = "synthetic",
                    AccessMode = mode,
                    CreatedAt = now
                });
            database.UserLibraryGrants.Add(new UserLibraryGrant { UserId = adminId, LibraryRootId = libraryId });
            database.UserLibraryGrants.Add(new UserLibraryGrant { UserId = libraryViewerId, LibraryRootId = libraryId });
            database.UserTitleGrants.Add(new UserTitleGrant { UserId = titleViewerId, MediaItemId = mediaId, MediaItem = null! });
            await database.SaveChangesAsync();
        }

        await using (var scope = factory.Services.CreateAsyncScope())
        {
            // The change is saved with the admin's own access boundary, as during its request.
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            database.AccessUserId = adminId;
            database.AccessMode = ProfileAccessMode.LegacyLibraries;
            var library = await database.LibraryRoots.SingleAsync(root => root.Id == libraryId);
            library.Name = "Invented Renamed";
            await database.SaveChangesAsync();
        }

        await using var check = factory.Services.CreateAsyncScope();
        var changes = await check.ServiceProvider.GetRequiredService<AureliaDbContext>().SyncChanges.IgnoreQueryFilters()
            .Where(change => change.Area == SyncChangeArea.Libraries).Select(change => change.UserId).ToListAsync();
        Assert.Contains(libraryViewerId, changes);
        Assert.Contains(titleViewerId, changes);
    }

    [Fact]
    public async Task RoleChangeInvalidatesTheAffectedUsersCatalogAndConditionalHome()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        using var create = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/users", owner.Token,
            new CreateUserRequest("second-owner", "correct horse battery staple", UserRole.Owner, ApiTestClient.TestPin));
        using var created = await ApiTestClient.SendAsync(client, create);
        created.EnsureSuccessStatusCode();
        var target = await ApiTestClient.ReadAsync<UserSummary>(created);
        using var login = await ApiTestClient.LoginAsync(client, new LoginRequest("second-owner", "correct horse battery staple", "Synthetic"));
        login.EnsureSuccessStatusCode();
        var session = await ApiTestClient.ReadAsync<AuthenticationResponse>(login);
        await using var scope = factory.Services.CreateAsyncScope();
        var changes = scope.ServiceProvider.GetRequiredService<SyncChangeService>();
        var before = await changes.ChangesAsync(target.Id, true, 0, 0, CancellationToken.None);
        using var home = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/home", session.Token);
        using var homeResponse = await client.SendAsync(home);
        homeResponse.EnsureSuccessStatusCode();
        var tag = homeResponse.Headers.ETag!.ToString();
        using var demote = ApiTestClient.Authorized(HttpMethod.Put, $"/api/v1/users/{target.Id}/role", owner.Token,
            new ChangeUserRoleRequest(UserRole.User));
        using var demoted = await ApiTestClient.SendAsync(client, demote);
        demoted.EnsureSuccessStatusCode();
        var after = await changes.ChangesAsync(target.Id, false, before.Cursor, 0, before.Generation, CancellationToken.None);
        Assert.Contains(SyncChangeArea.Catalog, after.ChangedAreas);
        using var reauthentication = await ApiTestClient.LoginAsync(client, new LoginRequest("second-owner", "correct horse battery staple", "Synthetic updated role"));
        session = await ApiTestClient.ReadAsync<AuthenticationResponse>(reauthentication);
        using var conditional = ApiTestClient.Authorized(HttpMethod.Get, "/api/v1/home", session.Token);
        conditional.Headers.TryAddWithoutValidation("If-None-Match", tag);
        using var changed = await client.SendAsync(conditional);
        Assert.Equal(HttpStatusCode.OK, changed.StatusCode);
        Assert.NotEqual(tag, changed.Headers.ETag!.ToString());
    }

    [Fact]
    public async Task TwoReadSnapshotsAllowAWalWriterAndRetainTheirOriginalRevision()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        await using var firstScope = factory.Services.CreateAsyncScope();
        await using var secondScope = factory.Services.CreateAsyncScope();
        await using var writerScope = factory.Services.CreateAsyncScope();
        var first = firstScope.ServiceProvider.GetRequiredService<SyncChangeService>();
        var second = secondScope.ServiceProvider.GetRequiredService<SyncChangeService>();
        var writer = writerScope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        Assert.Equal(SqliteCacheMode.Private,
            new SqliteConnectionStringBuilder(writer.Database.GetConnectionString()).Cache);
        Assert.Equal("wal", await writer.Database.SqlQueryRaw<string>(
            "SELECT journal_mode AS Value FROM pragma_journal_mode").SingleAsync());
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var original = await first.HistoryAsync(timeout.Token);
        await first.SnapshotAsync(owner.User.Id, async firstRevision =>
        {
            await second.SnapshotAsync(owner.User.Id, async secondRevision =>
            {
                Assert.Equal(firstRevision, secondRevision);
                writer.SyncChanges.Add(new SyncChange { Area = SyncChangeArea.Catalog, CreatedAt = DateTimeOffset.UtcNow });
                await writer.SaveChangesAsync(timeout.Token);
                Assert.Equal(original.HighWater, (await first.HistoryAsync(timeout.Token)).HighWater);
                Assert.Equal(original.HighWater, (await second.HistoryAsync(timeout.Token)).HighWater);
                return true;
            }, timeout.Token);
            return true;
        }, timeout.Token);
        Assert.True((await first.HistoryAsync(timeout.Token)).HighWater > original.HighWater);
    }

    [Theory]
    [InlineData("/api/v1/home")]
    [InlineData("/api/v1/catalog/items?limit=1")]
    public async Task ConditionalResponsesDoNotRegressAfterPruningOrSurviveHistoryReplacement(string path)
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        await using var scope = factory.Services.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var changes = scope.ServiceProvider.GetRequiredService<SyncChangeService>();
        database.SyncChanges.Add(new SyncChange { Area = SyncChangeArea.Catalog, UserId = owner.User.Id, CreatedAt = DateTimeOffset.UtcNow.AddDays(-8) });
        await database.SaveChangesAsync();
        using var first = ApiTestClient.Authorized(HttpMethod.Get, path, owner.Token);
        using var firstResponse = await client.SendAsync(first);
        firstResponse.EnsureSuccessStatusCode();
        var tag = Assert.IsType<System.Net.Http.Headers.EntityTagHeaderValue>(firstResponse.Headers.ETag).ToString();
        await changes.PruneAsync(CancellationToken.None);
        Assert.Empty(await database.SyncChanges.ToListAsync());
        using var afterPrune = ApiTestClient.Authorized(HttpMethod.Get, path, owner.Token);
        afterPrune.Headers.TryAddWithoutValidation("If-None-Match", tag);
        using var prunedResponse = await client.SendAsync(afterPrune);
        Assert.Equal(HttpStatusCode.NotModified, prunedResponse.StatusCode);
        await database.Database.ExecuteSqlRawAsync(SyncChangeService.RotateGenerationSql);
        using var afterReplacement = ApiTestClient.Authorized(HttpMethod.Get, path, owner.Token);
        afterReplacement.Headers.TryAddWithoutValidation("If-None-Match", tag);
        using var replacedResponse = await client.SendAsync(afterReplacement);
        Assert.Equal(HttpStatusCode.OK, replacedResponse.StatusCode);
        Assert.NotEqual(tag, replacedResponse.Headers.ETag!.ToString());
    }

    [Fact]
    public async Task PruningEveryEventKeepsHighWaterAndResetsExpiredHistoryAcrossRestart()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        await using var scope = factory.Services.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var changes = scope.ServiceProvider.GetRequiredService<SyncChangeService>();
        database.SyncChanges.AddRange(Enumerable.Range(0, 3).Select(_ => new SyncChange
        { Area = SyncChangeArea.Catalog, UserId = owner.User.Id, CreatedAt = DateTimeOffset.UtcNow.AddDays(-8) }));
        await database.SaveChangesAsync();
        var before = await changes.ChangesAsync(owner.User.Id, true, 0, 0, CancellationToken.None);
        await changes.PruneAsync(CancellationToken.None);
        Assert.Empty(await database.SyncChanges.ToListAsync());
        var pruned = await changes.ChangesAsync(owner.User.Id, true, before.Cursor - 1, 0, before.Generation, CancellationToken.None);
        Assert.True(pruned.ResetRequired);
        Assert.Equal(before.Cursor, pruned.Cursor);
        var caughtUp = await changes.ChangesAsync(owner.User.Id, true, pruned.Cursor, 0, pruned.Generation, CancellationToken.None);
        Assert.False(caughtUp.ResetRequired);
        Assert.Equal(pruned.Cursor, caughtUp.Cursor);
        await using var nextScope = factory.Services.CreateAsyncScope();
        var reopened = await nextScope.ServiceProvider.GetRequiredService<SyncChangeService>().HistoryAsync(CancellationToken.None);
        Assert.Equal(before.Generation, reopened.Generation);
        Assert.Equal(before.Cursor, reopened.HighWater);
        await database.Database.ExecuteSqlRawAsync(SyncChangeService.RotateGenerationSql);
        Assert.True((await changes.ChangesAsync(owner.User.Id, true, caughtUp.Cursor, 0, caughtUp.Generation, CancellationToken.None)).ResetRequired);
        Assert.True((await changes.ChangesAsync(owner.User.Id, true, before.Cursor + 1, 0, CancellationToken.None)).ResetRequired);
    }

    [Fact]
    public async Task InvisibleCursorGapsDoNotMasqueradeAsPrunedHistoryOrExposeMedia()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        await using var scope = factory.Services.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
        var changes = scope.ServiceProvider.GetRequiredService<SyncChangeService>();
        var other = new ServerUser { Id = Guid.NewGuid(), Username = "Synthetic", NormalizedUsername = "SYNTHETIC", PasswordHash = "unused", Role = UserRole.User };
        database.Users.Add(other);
        await database.SaveChangesAsync();
        database.SyncChanges.Add(new SyncChange { Area = SyncChangeArea.Catalog, UserId = owner.User.Id, CreatedAt = DateTimeOffset.UtcNow });
        await database.SaveChangesAsync();
        var before = await changes.ChangesAsync(owner.User.Id, true, 0, 0, CancellationToken.None);
        database.SyncChanges.AddRange(Enumerable.Range(0, 10).Select(_ => new SyncChange
        { Area = SyncChangeArea.UserState, UserId = other.Id, CreatedAt = DateTimeOffset.UtcNow }));
        await database.SaveChangesAsync();
        var gap = await changes.ChangesAsync(owner.User.Id, true, before.Cursor, 0, before.Generation, CancellationToken.None);
        Assert.False(gap.ResetRequired);
        Assert.Empty(gap.ChangedAreas);
        Assert.Empty(gap.ChangedMediaIds);
        Assert.True(gap.Cursor > before.Cursor);
    }

    [Fact]
    public async Task CatalogPagesRejectChangedOrCrossUserRevisionsAndKeepLegacyQueriesWorking()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var first = await PageAsync(client, owner.Token, "/api/v1/catalog/items?limit=1");
        Assert.NotNull(first.Revision);
        await using (var scope = factory.Services.CreateAsyncScope())
        {
            var database = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            database.SyncChanges.Add(new SyncChange { Area = SyncChangeArea.Catalog, UserId = owner.User.Id, CreatedAt = DateTimeOffset.UtcNow });
            await database.SaveChangesAsync();
        }
        using var stale = ApiTestClient.Authorized(HttpMethod.Get, $"/api/v1/catalog/items?limit=1&revision={first.Revision}", owner.Token);
        using var response = await client.SendAsync(stale);
        Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
        Assert.Equal("catalog_changed", (await ApiTestClient.ReadAsync<ApiProblem>(response)).Code);
        var fresh = await PageAsync(client, owner.Token, "/api/v1/catalog/items?limit=1");
        Assert.NotEqual(first.Revision, fresh.Revision);
        await using (var scope = factory.Services.CreateAsyncScope())
        {
            var changes = scope.ServiceProvider.GetRequiredService<SyncChangeService>();
            await Assert.ThrowsAsync<MetadataException>(() => changes.PageAsync(Guid.NewGuid(), fresh.Revision,
                () => Task.FromResult(new PagedResponse<Guid>([], 0, 1, 0)), CancellationToken.None));
        }
        foreach (var path in new[] { "/api/v1/catalog/movies", "/api/v1/catalog/series", "/api/v1/catalog/search?query=synthetic" })
            Assert.NotNull((await PageAsync(client, owner.Token, path)).Revision);
    }

    private static async Task<PagedResponse<CatalogItemSummary>> PageAsync(HttpClient client, string token, string path)
    {
        using var request = ApiTestClient.Authorized(HttpMethod.Get, path, token);
        using var response = await client.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await ApiTestClient.ReadAsync<PagedResponse<CatalogItemSummary>>(response);
    }
}
