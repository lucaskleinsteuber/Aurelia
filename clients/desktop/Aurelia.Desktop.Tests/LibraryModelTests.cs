using Aurelia.Contracts;
using Aurelia.Desktop.Core;
using Xunit;

namespace Aurelia.Desktop.Tests;

public sealed class LibraryModelTests
{
    private static (LibraryModel Model, FakeLibraryApi Api) Create()
    {
        var api = new FakeLibraryApi();
        return (new LibraryModel(api, delay: (_, _) => Task.CompletedTask), api);
    }

    [Fact]
    public async Task HomeHasAHeroAndShelvesInTheMacOrder()
    {
        var (model, _) = Create();
        await model.ShowAsync(LibrarySection.Home);
        Assert.Equal("Synthetic Series", model.Hero?.Title);
        Assert.Equal("TV SHOW · 2008 · DRAMA", model.HeroEyebrow);
        Assert.Equal(["Continue Watching", "Recently Added", "Favorites", "Synthetic Collection"], model.Rows.Select(row => row.Title));
        Assert.True(model.Rows[0].Landscape);
        Assert.False(model.IsHomeEmpty);
    }

    [Fact]
    public async Task MoviesAndShowsLoadInPagesOnlyOnce()
    {
        var (model, api) = Create();
        await model.ShowAsync(LibrarySection.Movies);
        await model.LoadMoreAsync(MediaKind.Movie);
        Assert.Equal(["Synthetic Movie", "Second Feature"], model.Movies.Select(item => item.Title));
        Assert.Single(api.Calls, call => call.StartsWith("browse Movie", StringComparison.Ordinal));
        await model.ShowAsync(LibrarySection.Shows);
        Assert.Single(model.Shows);
    }

    [Fact]
    public async Task FiltersAndSortingReloadTheGridFromTheFirstPage()
    {
        var (model, api) = Create();
        await model.ShowAsync(LibrarySection.Movies);
        var browse = model.MovieBrowse;
        Assert.Equal("2 movies", browse.CountText);
        // Genres and years come from the titles seen in the grid.
        Assert.Equal([CatalogBrowse.AllGenres, "Comedy", "Drama"], browse.Genres);
        Assert.Equal([CatalogBrowse.AnyYear, "2024", "2020"], browse.Years);
        Assert.False(browse.HasFilters);

        browse.SortIndex = 2;
        browse.Descending = true;
        await WaitForAsync(() => !model.IsLoading && browse.Items.Count == 2);
        Assert.Equal(["Second Feature", "Synthetic Movie"], browse.Items.Select(item => item.Title));
        Assert.Contains("browse Movie 0 sort=releaseYear&direction=descending", api.Calls);

        browse.Genre = "Comedy";
        await WaitForAsync(() => !model.IsLoading && browse.Items.Count == 1);
        Assert.True(browse.HasFilters);
        Assert.Contains(api.Calls, call => call.EndsWith("&genre=Comedy", StringComparison.Ordinal));
        browse.WatchIndex = (int)WatchFilter.Watched;
        await WaitForAsync(() => !model.IsLoading && browse.Total == 0);
        Assert.True(browse.IsEmpty);
        Assert.Equal("No movies match these filters.", browse.EmptyText);

        browse.ClearFilters();
        await WaitForAsync(() => !model.IsLoading && browse.Items.Count == 2);
        Assert.False(browse.HasFilters);
        Assert.Equal(CatalogBrowse.AllGenres, browse.Genre);
    }

    [Fact]
    public async Task TitlesSeasonsAndEpisodesAreMarkedWatchedAndUnwatched()
    {
        var (model, api) = Create();
        await model.OpenDetailAsync(FakeLibraryApi.MovieId);
        Assert.Equal("Mark as Watched", model.WatchedLabel);
        await model.ToggleWatchedAsync();
        Assert.Contains(FakeLibraryApi.MovieId, api.Watched);
        Assert.Equal("Mark as Unwatched", model.WatchedLabel);
        Assert.True(model.Detail?.Item.Progress?.IsCompleted);
        await model.ToggleWatchedAsync();
        Assert.Empty(api.Watched);

        await model.OpenDetailAsync(FakeLibraryApi.SeriesId);
        await WaitForAsync(() => model.SeasonWatch is not null);
        Assert.Equal("Mark Season as Watched", model.SeasonWatchedLabel);
        await model.ToggleEpisodeWatchedAsync(model.Episodes[0]);
        Assert.Equal([FakeLibraryApi.EpisodeOneId], api.Watched);
        Assert.True(model.Episodes[0].Item.Progress?.IsCompleted);
        await model.ToggleSeasonWatchedAsync();
        Assert.Equal(2, api.Watched.Count);
        await WaitForAsync(() => model.SeasonWatchedLabel == "Mark Season as Unwatched");
        Assert.Equal("Mark as Unwatched", model.WatchedLabel);
        // The season stays chosen after the page reloads.
        Assert.Equal(1, model.SelectedSeason?.Number);
    }

    private static async Task WaitForAsync(Func<bool> condition)
    {
        for (var attempt = 0; attempt < 200 && !condition(); attempt++) await Task.Delay(10, TestContext.Current.CancellationToken);
        Assert.True(condition());
    }

    [Fact]
    public async Task SearchWaitsForAPauseAndShowsWhenNothingMatches()
    {
        var api = new FakeLibraryApi();
        var pauses = 0;
        var model = new LibraryModel(api, delay: (_, _) =>
        {
            pauses++;
            return Task.CompletedTask;
        });
        await model.ShowAsync(LibrarySection.Search);
        model.SearchText = "feature";
        await Task.Delay(50, TestContext.Current.CancellationToken);
        Assert.Equal(1, pauses);
        Assert.Equal(["Second Feature"], model.SearchResults.Select(item => item.Title));
        model.SearchText = "zzz";
        await Task.Delay(50, TestContext.Current.CancellationToken);
        Assert.True(model.ShowsNoResults);
    }

    [Fact]
    public async Task ASeriesPageOpensAtTheSeasonToContinue()
    {
        var (model, _) = Create();
        await model.OpenDetailAsync(FakeLibraryApi.SeriesId);
        Assert.True(model.ShowsDetail);
        Assert.True(model.IsSeries);
        Assert.Equal("Resume", model.PlayLabel);
        Assert.Equal("S1 E1 · Pilot", model.PlayHint);
        Assert.Equal(1, model.SelectedSeason?.Number);
        Assert.Equal(["Pilot", "The Second One"], model.Episodes.Select(episode => episode.Item.Title));
        Assert.StartsWith("2008 · 12 · 1 season", model.DetailMeta, StringComparison.Ordinal);
        model.CloseDetail();
        Assert.False(model.ShowsDetail);
    }

    [Fact]
    public async Task AMoviePageShowsExtrasAndKeepsFavoritesInStep()
    {
        var (model, api) = Create();
        await model.OpenDetailAsync(FakeLibraryApi.MovieId);
        Assert.Equal("Play", model.PlayLabel);
        Assert.True(model.HasExtras);
        Assert.Equal("2020 · 1 h 44 min · 12 · Drama", model.DetailMeta);
        Assert.Equal("Add to Favorites", model.FavoriteLabel);
        await model.ToggleFavoriteAsync();
        Assert.True(model.IsFavorite);
        Assert.Contains($"favorite {FakeLibraryApi.MovieId} True", api.Calls);
    }

    [Fact]
    public async Task PlayingFollowsTheServersPlanWithTheEpisodesAfterIt()
    {
        var (model, _) = Create();
        PlaybackRequest? requested = null;
        model.PlayRequested += request => requested = request;
        await model.OpenAsync(FakeLibraryApi.Episode(1));
        Assert.NotNull(requested);
        Assert.Equal(FakeLibraryApi.EpisodeOneId, requested.Target.Id);
        Assert.Equal([FakeLibraryApi.EpisodeTwoId], requested.Queue.Select(item => item.Id));
        Assert.Equal(FakeLibraryApi.SeriesId, requested.SeriesId);
    }
}
