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
