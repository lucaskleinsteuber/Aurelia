using System.Net;
using System.Text;
using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class ApiErrorHandlingTests
{
    [Fact]
    public async Task RestoringExclusionWhileScanIsActiveReturns409InsteadOf500()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);
        var rootDir = Path.Combine(TestPaths.CreateDataDirectory(), "ExclusionBusy");
        Directory.CreateDirectory(rootDir);
        try
        {
            Guid libraryId;
            Guid exclusionId;
            using (var scope = factory.Services.CreateScope())
            {
                var db = scope.ServiceProvider.GetRequiredService<AureliaDbContext>();
                var now = DateTimeOffset.UtcNow;
                var root = new LibraryRoot
                {
                    Id = Guid.NewGuid(),
                    Name = "Busy Library",
                    Path = rootDir,
                    NormalizedPath = MediaPath.Normalize(rootDir),
                    Kind = LibraryKind.Movies,
                    Availability = LibraryAvailability.Available,
                    CreatedAt = now,
                };
                libraryId = root.Id;
                var exclusion = new MediaExclusion
                {
                    Id = Guid.NewGuid(),
                    LibraryRootId = libraryId,
                    RelativePath = "Skipped.mkv",
                    NormalizedSourcePath = Path.Combine(rootDir, "Skipped.mkv"),
                    IsDirectory = false,
                };
                exclusionId = exclusion.Id;
                db.LibraryRoots.Add(root);
                db.MediaExclusions.Add(exclusion);
                db.LibraryScans.Add(new LibraryScan
                {
                    Id = Guid.NewGuid(),
                    LibraryRootId = libraryId,
                    State = LibraryScanState.Running,
                    Trigger = LibraryScanTrigger.Manual,
                    CreatedAt = now,
                });
                await db.SaveChangesAsync();
            }

            using var request = ApiTestClient.Authorized(HttpMethod.Delete, $"/api/v1/libraries/{libraryId}/exclusions/{exclusionId}", owner.Token);
            using var response = await client.SendAsync(request);
            Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
            var problem = await ApiTestClient.ReadAsync<ApiProblem>(response);
            Assert.Equal("library_scan_active", problem.Code);

            // Because the scan was already active, the exclusion was kept intact.
            using var verifyScope = factory.Services.CreateScope();
            var verifyDb = verifyScope.ServiceProvider.GetRequiredService<AureliaDbContext>();
            Assert.True(await verifyDb.MediaExclusions.AnyAsync(item => item.Id == exclusionId));
        }
        finally { Directory.Delete(Path.GetDirectoryName(rootDir)!, recursive: true); }
    }

    [Fact]
    public async Task RetryingUnknownMetadataJobReturnsApiProblemInsteadOf500()
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        using var request = ApiTestClient.Authorized(HttpMethod.Post, $"/api/v1/metadata/jobs/{Guid.NewGuid()}/retry", owner.Token);
        using var response = await client.SendAsync(request);
        Assert.True(response.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.NotFound or HttpStatusCode.Conflict,
            $"Expected 4xx ApiProblem, got {(int)response.StatusCode}");
        var problem = await ApiTestClient.ReadAsync<ApiProblem>(response);
        Assert.False(string.IsNullOrWhiteSpace(problem.Code));
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("""{"name":null}""")]
    public async Task CreatingCollectionWithoutNameReturns400InsteadOf500(string json)
    {
        using var factory = new AureliaServerFactory();
        using var client = factory.CreateClient();
        var owner = await ApiTestClient.SetupOwnerAsync(client);

        using var request = ApiTestClient.Authorized(HttpMethod.Post, "/api/v1/collections", owner.Token);
        request.Content = new StringContent(json, Encoding.UTF8, "application/json");
        using var response = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        var problem = await ApiTestClient.ReadAsync<ApiProblem>(response);
        Assert.Equal("invalid_collection", problem.Code);
    }

    [Fact]
    public void StorageFullErrorsAreDetectedForSqliteDbUpdateAndIoExceptions()
    {
        var sqliteFull = new SqliteException("SQLite Error 13: 'database or disk is full'.", 13);
        var wrapped = new DbUpdateException("Save failed", sqliteFull);
        var ioEnospc = new IOException("No space left on device", 28);
        var ioWinDiskFull = new IOException("Disk full", unchecked((int)0x80070070));
        var unrelatedSqlite = new SqliteException("SQLite Error 5: 'database is locked'.", 5);
        var unrelatedIo = new IOException("Broken pipe", 32);

        Assert.True(ServerStorageErrors.IsStorageFull(sqliteFull));
        Assert.True(ServerStorageErrors.IsStorageFull(wrapped));
        Assert.True(ServerStorageErrors.IsStorageFull(ioEnospc));
        Assert.True(ServerStorageErrors.IsStorageFull(ioWinDiskFull));
        Assert.False(ServerStorageErrors.IsStorageFull(unrelatedSqlite));
        Assert.False(ServerStorageErrors.IsStorageFull(unrelatedIo));
    }
}
