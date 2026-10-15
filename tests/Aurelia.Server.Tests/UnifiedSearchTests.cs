using Aurelia.Contracts;
using Aurelia.Server.Data;
using Aurelia.Server.Services;
using Microsoft.EntityFrameworkCore;
using Xunit;

namespace Aurelia.Server.Tests;

public sealed class UnifiedSearchTests
{
    [Fact]
    public async Task FiltersAndExplicitOrderingKeepTheSameWordPrefixMatchesAndCounts()
    {
        await using var fixture = await Fixture.CreateAsync();
        var service = fixture.Presentation;
        var all = await service.SearchAsync(fixture.User.Id, "star wars", new CatalogQuery(), default);
        Assert.Equal(2, all.Total);
        foreach (var query in new[] {
            new CatalogQuery(Kind: MediaKind.Movie), new CatalogQuery(Favorite: true),
            new CatalogQuery(Genre: "Drama", YearFrom: 2020, YearTo: 2026),
            new CatalogQuery(Relevance: false, Sort: CatalogSort.DateAdded, Direction: SortDirection.Descending) })
        {
            var filtered = await service.SearchAsync(fixture.User.Id, "star wars", query, default);
            Assert.Equal(all.Total, filtered.Total);
            Assert.Equal(all.Items.Select(item => item.Id).Order(), filtered.Items.Select(item => item.Id).Order());
        }
        var first = await service.SearchAsync(fixture.User.Id, "star wars", new CatalogQuery(Limit: 1), default);
        var second = await service.SearchAsync(fixture.User.Id, "star wars", new CatalogQuery(Offset: 1, Limit: 1), default);
        Assert.NotEqual(Assert.Single(first.Items).Id, Assert.Single(second.Items).Id);
        await new MediaSearchIndexService(fixture.Database).RebuildAsync(default);
        Assert.Equal(first.Items[0].Id, (await service.SearchAsync(fixture.User.Id, "star wars", new CatalogQuery(Limit: 1), default)).Items[0].Id);
    }

    [Fact]
    public async Task EverySortAndStateFilterUsesTheSameFtsSetBeforePagination()
    {
        await using var fixture = await Fixture.CreateAsync();
        var movies = await fixture.Database.MediaItems.OrderBy(item => item.Id).ToListAsync();
        for (var index = 0; index < movies.Count; index++)
            fixture.Database.PlaybackProgress.Add(new PlaybackProgress { Id = Guid.NewGuid(), UserId = fixture.User.Id, User = fixture.User, MediaItemId = movies[index].Id, MediaItem = movies[index], IsCompleted = index == 0, PositionMilliseconds = index == 0 ? 0 : 45_000, LastPlayedAt = DateTimeOffset.UtcNow.AddDays(-index) });
        await fixture.Database.SaveChangesAsync();
        foreach (var sort in Enum.GetValues<CatalogSort>())
            foreach (var direction in Enum.GetValues<SortDirection>())
                foreach (var state in new CatalogWatchState?[] { null, CatalogWatchState.Unplayed, CatalogWatchState.InProgress, CatalogWatchState.Completed })
                {
                    var query = new CatalogQuery(Kind: MediaKind.Movie, LibraryId: fixture.Library.Id,
                        Favorite: true, Genre: "Drama", YearFrom: 2024, YearTo: 2024,
                        WatchState: state, Sort: sort, Direction: direction, Relevance: false, Limit: 1);
                    var expected = await fixture.Presentation.CatalogAsync(fixture.User.Id, query, default);
                    var found = await fixture.Presentation.SearchAsync(fixture.User.Id, "sta war", query, default);
                    Assert.Equal(expected.Total, found.Total);
                    Assert.Equal(expected.Items.Select(item => item.Id), found.Items.Select(item => item.Id));
                    var second = await fixture.Presentation.SearchAsync(fixture.User.Id, "sta war", query with { Offset = 1 }, default);
                    Assert.Equal(found.Total, second.Total);
                    Assert.Empty(found.Items.Select(item => item.Id).Intersect(second.Items.Select(item => item.Id)));
                }
    }

    [Fact]
    public async Task AccentStudiosCreditsAndRenamedSeriesAreSearchableWithFilters()
    {
        await using var fixture = await Fixture.CreateAsync();
        foreach (var term in new[] { "Uber", "Kram", "Galactic" })
            Assert.Equal(fixture.First.Id, Assert.Single((await fixture.Presentation.SearchAsync(fixture.User.Id, term, new CatalogQuery(Kind: MediaKind.Movie), default)).Items).Id);
        var series = new MediaItem { Id = Guid.NewGuid(), Kind = MediaKind.Series, DetectedTitle = "Old Name", LibraryRootId = fixture.Library.Id, LibraryRoot = fixture.Library, NormalizedSourcePath = "SERIES" };
        var episode = new MediaItem { Id = Guid.NewGuid(), Kind = MediaKind.Episode, DetectedTitle = "Pilot", Parent = series, ParentId = series.Id, LibraryRootId = fixture.Library.Id, LibraryRoot = fixture.Library, NormalizedSourcePath = "EPISODE", SeasonNumber = 1, EpisodeNumber = 1 };
        fixture.Database.AddRange(series, episode);
        await fixture.Database.SaveChangesAsync();
        series.Metadata = new MediaMetadata { MediaItemId = series.Id, ManualTitle = "Renamed Galaxy" };
        await fixture.Database.SaveChangesAsync();
        var renamed = await fixture.Presentation.SearchAsync(fixture.User.Id, "Renamed Galaxy", new CatalogQuery(), default);
        Assert.Equal(2, renamed.Total);
        Assert.Contains(renamed.Items, item => item.Id == episode.Id);
        var season = await fixture.Presentation.SearchAsync(fixture.User.Id, "Season 1", new CatalogQuery(), default);
        Assert.Equal(episode.Id, Assert.Single(season.Items).Id);
        Assert.Empty((await fixture.Presentation.SearchAsync(fixture.User.Id, "\" OR *", new CatalogQuery(), default)).Items);
    }

    [Fact]
    public async Task RestrictedMatchesAreFilteredBeforeTheTotalAndPage()
    {
        await using var fixture = await Fixture.CreateAsync();
        var viewer = new ServerUser { Id = Guid.NewGuid(), Username = "Viewer", NormalizedUsername = "VIEWER", PasswordHash = "synthetic", AccessMode = ProfileAccessMode.SelectedTitles };
        fixture.Database.Users.Add(viewer);
        fixture.Database.UserTitleGrants.Add(new UserTitleGrant { UserId = viewer.Id, User = viewer, MediaItemId = fixture.First.Id, MediaItem = fixture.First });
        await fixture.Database.SaveChangesAsync();
        fixture.Database.AccessUserId = viewer.Id;
        fixture.Database.AccessMode = ProfileAccessMode.SelectedTitles;
        var found = await fixture.Presentation.SearchAsync(viewer.Id, "star wars", new CatalogQuery(Limit: 1), default);
        Assert.Equal(1, found.Total);
        Assert.Equal(fixture.First.Id, Assert.Single(found.Items).Id);
        Assert.Empty((await fixture.Presentation.SearchAsync(viewer.Id, "star wars", new CatalogQuery(Offset: 1, Limit: 1), default)).Items);
    }

    private sealed class Fixture : IAsyncDisposable
    {
        public required AureliaDbContext Database { get; init; }
        public required ServerUser User { get; init; }
        public required LibraryRoot Library { get; init; }
        public required MediaItem First { get; init; }
        public PresentationService Presentation => new(Database, TimeProvider.System, new MediaSearchIndexService(Database));
        public static async Task<Fixture> CreateAsync()
        {
            var database = new AureliaDbContext(new DbContextOptionsBuilder<AureliaDbContext>().UseSqlite("Data Source=:memory:").Options);
            await database.Database.OpenConnectionAsync();
            await database.Database.MigrateAsync();
            var user = new ServerUser { Id = Guid.NewGuid(), Username = "Owner", NormalizedUsername = "OWNER", PasswordHash = "synthetic", Role = UserRole.Owner, AccessMode = ProfileAccessMode.EntireLibrary };
            var library = new LibraryRoot { Id = Guid.NewGuid(), Name = "Synthetic", MonitoringEnabled = false };
            var first = new MediaItem { Id = Guid.NewGuid(), Kind = MediaKind.Movie, DetectedTitle = "Star Clone Wars", Year = 2024, LibraryRoot = library, LibraryRootId = library.Id, NormalizedSourcePath = "FIRST" };
            var second = new MediaItem { Id = Guid.NewGuid(), Kind = MediaKind.Movie, DetectedTitle = "Star Wars", Year = 2024, LibraryRoot = library, LibraryRootId = library.Id, NormalizedSourcePath = "SECOND" };
            first.Metadata = new MediaMetadata { MediaItemId = first.Id, ManualOriginalTitle = "Über den Sternen", ProviderGenresJson = "[\"Drama\"]", ProviderStudiosJson = "[\"Galactic Works\"]" };
            first.Metadata.Credits.Add(new MediaCredit { Id = Guid.NewGuid(), MediaItemId = first.Id, Name = "Ana Krämer" });
            second.Metadata = new MediaMetadata { MediaItemId = second.Id, ProviderGenresJson = "[\"Drama\"]" };
            database.AddRange(user, library, first, second);
            foreach (var item in new[] { first, second }) database.UserFavorites.Add(new UserFavorite { Id = Guid.NewGuid(), User = user, UserId = user.Id, MediaItem = item, MediaItemId = item.Id });
            await database.SaveChangesAsync();
            return new Fixture { Database = database, User = user, Library = library, First = first };
        }
        public ValueTask DisposeAsync() => Database.DisposeAsync();
    }
}
