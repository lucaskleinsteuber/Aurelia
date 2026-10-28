using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class IncrementalSearchMaintenanceTests
{
    [Fact]
    public async Task BookkeepingUpdatesLeaveFullTextDocumentsUntouched()
    {
        await using var fixture = await Fixture.CreateAsync();
        var before = await fixture.Documents();
        var changes = await fixture.Changes();
        await fixture.Database.Database.ExecuteSqlRawAsync("""
            UPDATE MediaItems SET UpdatedAt=UpdatedAt+1, LastSeenScanId='00112233-4455-6677-8899-AABBCCDDEEFF',
                FileSize=2, Availability='Missing';
            """);
        Assert.Equal(3, await fixture.Changes() - changes);
        Assert.Equal(before, await fixture.Documents());
        Assert.Contains(fixture.Episode.Id, await fixture.Hits("Original"));
    }

    [Fact]
    public async Task TitleChangesIncludeChildrenAndNullTransitions()
    {
        await using var fixture = await Fixture.CreateAsync();
        await fixture.Database.Database.ExecuteSqlInterpolatedAsync($"UPDATE MediaItems SET DetectedTitle='Renamed Galaxy' WHERE Id={fixture.Series.Id}");
        Assert.Equal(new[] { fixture.Series.Id, fixture.Episode.Id }.Order(), (await fixture.Hits("Renamed")).Order());
        Assert.Empty(await fixture.Hits("Original"));
        await fixture.Database.Database.ExecuteSqlInterpolatedAsync($"UPDATE MediaItems SET OverrideTitle='Custom Nebula' WHERE Id={fixture.Series.Id}");
        Assert.Equal(2, (await fixture.Hits("Custom")).Count);
        await fixture.Database.Database.ExecuteSqlInterpolatedAsync($"UPDATE MediaItems SET OverrideTitle=NULL WHERE Id={fixture.Series.Id}");
        Assert.Empty(await fixture.Hits("Custom"));
        Assert.Equal(2, (await fixture.Hits("Renamed")).Count);
        var changes = await fixture.Changes();
        await fixture.Database.Database.ExecuteSqlInterpolatedAsync($"UPDATE MediaItems SET DetectedTitle=DetectedTitle, OverrideTitle=OverrideTitle WHERE Id={fixture.Series.Id}");
        Assert.Equal(1, await fixture.Changes() - changes);
    }

    [Fact]
    public async Task ParentSeasonEpisodeAndKindChangesKeepSearchConsistent()
    {
        await using var fixture = await Fixture.CreateAsync();
        await fixture.Database.Database.ExecuteSqlInterpolatedAsync($"UPDATE MediaItems SET ParentId={fixture.Other.Id}, SeasonNumber=2, EpisodeNumber=7 WHERE Id={fixture.Episode.Id}");
        Assert.DoesNotContain(fixture.Episode.Id, await fixture.Hits("Original"));
        Assert.Contains(fixture.Episode.Id, await fixture.Hits("Other"));
        Assert.Equal(fixture.Episode.Id, Assert.Single(await fixture.Hits("Season 2 Episode 7")));
        await fixture.Database.Database.ExecuteSqlInterpolatedAsync($"UPDATE MediaItems SET Kind='Trailer' WHERE Id={fixture.Episode.Id}");
        Assert.DoesNotContain(fixture.Episode.Id, await fixture.Hits("Pilot"));
        await fixture.Database.Database.ExecuteSqlInterpolatedAsync($"UPDATE MediaItems SET Kind='Episode' WHERE Id={fixture.Episode.Id}");
        Assert.Contains(fixture.Episode.Id, await fixture.Hits("Pilot"));
        await fixture.Database.Database.ExecuteSqlInterpolatedAsync($"DELETE FROM MediaItems WHERE Id={fixture.Episode.Id}");
        Assert.Empty(await fixture.Hits("Pilot"));
    }

    [Fact]
    public async Task RawUnreferencedPrimaryKeyChangeRemovesTheOldSearchIdentity()
    {
        await using var fixture = await Fixture.CreateAsync();
        var replacement = Guid.NewGuid();
        await fixture.Database.Database.ExecuteSqlInterpolatedAsync($"UPDATE MediaItems SET Id={replacement} WHERE Id={fixture.Other.Id}");
        Assert.Equal(replacement, Assert.Single(await fixture.Hits("Other")));
        Assert.DoesNotContain(fixture.Other.Id, await fixture.Hits("Other"));
    }

    [Fact]
    public async Task TransactionRollbackAndExplicitRebuildKeepTheirExistingSemantics()
    {
        await using var fixture = await Fixture.CreateAsync();
        var original = await fixture.Documents();
        await using (var transaction = await fixture.Database.Database.BeginTransactionAsync())
        {
            await fixture.Database.Database.ExecuteSqlInterpolatedAsync($"UPDATE MediaItems SET DetectedTitle='Transient' WHERE Id={fixture.Series.Id}");
            Assert.Equal(2, (await fixture.Hits("Transient")).Count);
            await transaction.RollbackAsync();
        }
        Assert.Equal(original, await fixture.Documents());
        await fixture.Database.Database.ExecuteSqlRawAsync("DELETE FROM MediaSearchIndex;");
        Assert.Empty(await fixture.Hits("Original"));
        await new MediaSearchIndexService(fixture.Database).RebuildAsync(default);
        Assert.Equal(2, (await fixture.Hits("Original")).Count);
    }

    [Fact]
    public async Task ExistingDatabaseUpgradeAndDowngradeReplaceOnlyTheUpdateTrigger()
    {
        await using var fixture = await Fixture.CreateAsync("20261018182038_RemoveMediaSegments");
        var original = await fixture.Documents();
        var migrator = fixture.Database.GetService<IMigrator>();
        await migrator.MigrateAsync();
        Assert.Equal(original, await fixture.Documents());
        var changes = await fixture.Changes();
        await fixture.Database.Database.ExecuteSqlInterpolatedAsync($"UPDATE MediaItems SET UpdatedAt=UpdatedAt+1 WHERE Id={fixture.Series.Id}");
        Assert.Equal(1, await fixture.Changes() - changes);
        await migrator.MigrateAsync("20261018182038_RemoveMediaSegments");
        changes = await fixture.Changes();
        await fixture.Database.Database.ExecuteSqlInterpolatedAsync($"UPDATE MediaItems SET UpdatedAt=UpdatedAt+1 WHERE Id={fixture.Series.Id}");
        Assert.True(await fixture.Changes() - changes > 1);
        await migrator.MigrateAsync();
        Assert.Equal(2, (await fixture.Hits("Original")).Count);
    }

    private sealed class Fixture : IAsyncDisposable
    {
        public required AureliaDbContext Database { get; init; }
        public required MediaItem Series { get; init; }
        public required MediaItem Episode { get; init; }
        public required MediaItem Other { get; init; }
        public Task<List<Guid>> Hits(string query) => new MediaSearchIndexService(Database).Hits(query).Select(hit => hit.Id).ToListAsync();
        public Task<List<string>> Documents() => Database.Database.SqlQueryRaw<string>("SELECT rowid || ':' || MediaId || ':' || Title || ':' || OriginalTitle || ':' || Details AS Value FROM MediaSearchIndex ORDER BY MediaId").ToListAsync();
        public Task<long> Changes() => Database.Database.SqlQueryRaw<long>("SELECT total_changes() AS Value").SingleAsync();
        public static async Task<Fixture> CreateAsync(string? migration = null)
        {
            var database = new AureliaDbContext(new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite("Data Source=:memory:").Options);
            await database.Database.OpenConnectionAsync();
            await database.GetService<IMigrator>().MigrateAsync(migration);
            var root = new LibraryRoot { Id = Guid.NewGuid(), Name = "Invented", NormalizedPath = "INVENTED", MonitoringEnabled = false };
            var series = new MediaItem { Id = Guid.NewGuid(), Kind = MediaKind.Series, DetectedTitle = "Original Galaxy", LibraryRoot = root, LibraryRootId = root.Id, NormalizedSourcePath = "SERIES" };
            var episode = new MediaItem { Id = Guid.NewGuid(), Kind = MediaKind.Episode, DetectedTitle = "Pilot", LibraryRoot = root, LibraryRootId = root.Id, Parent = series, ParentId = series.Id, SeasonNumber = 1, EpisodeNumber = 1, NormalizedSourcePath = "EPISODE" };
            var other = new MediaItem { Id = Guid.NewGuid(), Kind = MediaKind.Series, DetectedTitle = "Other Orbit", LibraryRoot = root, LibraryRootId = root.Id, NormalizedSourcePath = "OTHER" };
            database.AddRange(series, episode, other);
            await database.SaveChangesAsync();
            return new Fixture { Database = database, Series = series, Episode = episode, Other = other };
        }
        public ValueTask DisposeAsync() => Database.DisposeAsync();
    }
}
