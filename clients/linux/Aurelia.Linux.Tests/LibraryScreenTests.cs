using Aurelia.Contracts;
using Aurelia.Linux.Core;
using Aurelia.Linux.Library;
using Aurelia.Linux.Views;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.VisualTree;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class LibraryScreenTests
{
    [AvaloniaFact]
    public void MoviesShowPostersAndFiltersReachTheServer()
    {
        var server = FakeLibrary.Create();
        var window = FakeLibrary.ShowLibrary(server);
        window.Shell!.Destination = LibraryDestination.Movies;
        FakeLibrary.Pump(() => false, rounds: 30);
        var page = Assert.IsType<BrowsePage>(window.Shell.CurrentPage);
        Assert.Contains(page.GetVisualDescendants().OfType<Button>(), b => AutomationProperties.GetName(b) == "Quiet Orbit");
        Snapshot(window, "library-movies");

        Click(page.GetVisualDescendants().OfType<ToggleButton>().Single(t => AutomationProperties.GetName(t) == "Favorites"));
        FakeLibrary.Pump(() => server.RequestUris.Any(u => u.Contains("favorite=true", StringComparison.Ordinal)));
        Assert.Contains(server.RequestUris, uri => uri.Contains("/api/v1/catalog/items?kind=movie&favorite=true", StringComparison.Ordinal));
        Assert.True(page.Model.Query.FavoritesOnly);
    }

    [AvaloniaFact]
    public void ASeriesPageResumesItsEpisodeAndGoesBack()
    {
        var window = FakeLibrary.ShowLibrary(FakeLibrary.Create());
        var series = window.Session.Library!.Catalog.Single(item => item.Kind == MediaKind.Series);
        window.Shell!.OpenDetail(series);
        FakeLibrary.Pump(() => (window.Shell.CurrentPage as DetailPage)?.Detail is not null);
        var detail = Assert.IsType<DetailPage>(window.Shell.CurrentPage);
        var buttons = detail.GetVisualDescendants().OfType<Button>().Select(AutomationProperties.GetName).ToList();
        Assert.Contains("Resume S01 E01", buttons);
        Assert.Contains("Add to Favorites", buttons);
        Assert.Contains("Add to Watchlist", buttons);
        var texts = detail.GetVisualDescendants().OfType<TextBlock>().Select(t => t.Text).ToList();
        Assert.Contains("Cast & Crew", texts);
        Assert.Contains("Captain Rhea, Writer", texts);
        Assert.Contains("Trailers", texts.Select(t => t?.Replace("Series ", "", StringComparison.Ordinal)));
        Assert.Contains("Information", texts);
        FakeLibrary.Pump(() => false, rounds: 30);
        Snapshot(window, "detail-series");

        window.Shell.Back();
        Assert.IsType<HomePage>(window.Shell.CurrentPage);
        Assert.Equal(0, window.Shell.DetailDepth);
    }

    [AvaloniaFact]
    public void TheContextMenuFollowsTheMacOrder()
    {
        var window = FakeLibrary.ShowLibrary(FakeLibrary.Create());
        var store = window.Session.Library!;
        var episode = store.Home!.ContinueWatching.Single(item => item.Kind == MediaKind.Episode);
        var context = new LibraryContext(store, window.Shell!);
        var headers = MediaMenu.Items(context, episode).OfType<MenuItem>().Select(m => m.Header as string).ToList();
        Assert.Equal(
            ["Play", "Resume", "Go to Series", "Mark as Watched", "Mark Season as Watched", "Mark Season as Unwatched",
             "Mark Series as Watched", "Mark Series as Unwatched", "Add to Collection", "Remove from Continue Watching"],
            headers);
        var movie = store.Catalog.Single(item => item.Id == FakeLibrary.MovieB);
        var movieHeaders = MediaMenu.Items(context, movie).OfType<MenuItem>().Select(m => m.Header as string).ToList();
        Assert.Contains("Add to Favorites", movieHeaders);
        Assert.Contains("Remove from Watchlist", movieHeaders);
    }

    [AvaloniaFact]
    public void MarkingASeasonAsksWithTheEpisodeCountFirst()
    {
        var server = FakeLibrary.Create();
        var window = FakeLibrary.ShowLibrary(server);
        var store = window.Session.Library!;
        var episode = store.Home!.ContinueWatching.Single(item => item.Kind == MediaKind.Episode);
        var context = new LibraryContext(store, window.Shell!);
        _ = MediaMenu.MarkAsync(context, FakeLibrary.SeriesId, WatchStateScope.Season, watched: true, season: 1);
        FakeLibrary.Pump(() => window.Shell!.SheetHost.IsShowing);
        Assert.True(window.Shell!.SheetHost.IsShowing);
        Assert.Contains(window.Shell.SheetHost.GetVisualDescendants().OfType<TextBlock>(), t => t.Text == "Mark 2 episodes as watched?");
        Assert.Contains("GET /api/v1/media/" + FakeLibrary.SeriesId + "/watch-state?scope=season&seasonNumber=1", server.RequestUris);
        Snapshot(window, "confirm-season");
        Click(window.Shell.SheetHost.GetVisualDescendants().OfType<Button>().Single(b => b.Content as string == "Mark as Watched"));
        FakeLibrary.Pump(() => server.Bodies.ContainsKey("PUT /api/v1/media/" + FakeLibrary.SeriesId + "/watch-state"));
        var body = server.Bodies["PUT /api/v1/media/" + FakeLibrary.SeriesId + "/watch-state"];
        Assert.Contains("\"isWatched\":true", body, StringComparison.Ordinal);
        Assert.Contains("\"scope\":\"season\"", body, StringComparison.Ordinal);
        Assert.Contains("\"stateToken\":\"token-1\"", body, StringComparison.Ordinal);
    }

    [AvaloniaFact]
    public void TheCollectionEditorNeedsTwoTitlesAndSendsThem()
    {
        var server = FakeLibrary.Create();
        var window = FakeLibrary.ShowLibrary(server);
        window.Shell!.EditCollection(null, window.Session.Library!.Catalog.Single(item => item.Id == FakeLibrary.MovieA));
        FakeLibrary.Pump(() => window.Shell.SheetHost.IsShowing);
        var editor = Assert.IsType<CollectionEditorSheet>(Assert.IsType<Border>(window.Shell.SheetHost.Current).Child);
        editor.Model.Name = "New One";
        Assert.False(editor.Model.CanSave);
        Assert.Equal("Choose at least two titles.", editor.Model.Problem);
        editor.Model.Toggle(window.Session.Library!.Catalog.Single(item => item.Id == FakeLibrary.MovieB));
        Assert.True(editor.Model.CanSave);
        Snapshot(window, "collection-editor");
        Click(editor.GetVisualDescendants().OfType<Button>().Single(b => b.Content as string == "Save"));
        FakeLibrary.Pump(() => server.Bodies.ContainsKey("POST /api/v1/collections"));
        var body = server.Bodies["POST /api/v1/collections"];
        Assert.Contains("\"name\":\"New One\"", body, StringComparison.Ordinal);
        Assert.Contains(FakeLibrary.MovieA.ToString(), body, StringComparison.Ordinal);
        Assert.Contains(FakeLibrary.MovieB.ToString(), body, StringComparison.Ordinal);
    }

    [AvaloniaFact]
    public void HistoryAndStatisticsShowTheProfilesActivity()
    {
        var window = FakeLibrary.ShowLibrary(FakeLibrary.Create());
        window.Shell!.Destination = LibraryDestination.Collections;
        FakeLibrary.Pump(() => false, rounds: 20);
        Assert.IsType<CollectionsPage>(window.Shell.CurrentPage);
        Snapshot(window, "library-collections");

        var history = new HistoryPage(new LibraryContext(window.Session.Library!, window.Shell));
        window.Shell.FindControl<ContentControl>("PageHost")!.Content = history;
        history.SidebarOverlap = 236;
        FakeLibrary.Pump(() => history.GetVisualDescendants().OfType<TextBlock>().Any(t => t.Text == "Amber Fields"));
        var texts = history.GetVisualDescendants().OfType<TextBlock>().Select(t => t.Text).ToList();
        Assert.Contains("Today", texts);
        Assert.Contains("Yesterday", texts);
        Assert.Contains("Watched 20 min", texts);
        Assert.Contains("Finished", texts);
        Snapshot(window, "library-history");

        var statistics = new StatisticsPage(new LibraryContext(window.Session.Library!, window.Shell));
        window.Shell.FindControl<ContentControl>("PageHost")!.Content = statistics;
        statistics.SidebarOverlap = 236;
        FakeLibrary.Pump(() => statistics.GetVisualDescendants().OfType<TextBlock>().Any(t => t.Text == "Year in Review"));
        var numbers = statistics.GetVisualDescendants().OfType<TextBlock>().Select(t => t.Text).ToList();
        Assert.Contains("1 d 7 h", numbers);
        Assert.Contains("72 %", numbers);
        Assert.Contains("Saturday, evening", numbers);
        Snapshot(window, "library-statistics");
    }

    private static void Click(Button button)
    {
        button.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        FakeLibrary.Pump(() => false, rounds: 5);
    }

    private static void Snapshot(MainWindow window, string name)
    {
        using var frame = window.CaptureRenderedFrame()!;
        TestWindows.SaveSnapshot(frame, name);
    }
}
