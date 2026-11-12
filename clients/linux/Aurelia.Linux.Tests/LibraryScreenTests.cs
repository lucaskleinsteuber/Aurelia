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
    public void AFailedFirstLoadOffersTryAgainInsteadOfSpinning()
    {
        var server = FakeLibrary.Create().Replace("GET", "/api/v1/home",
            """{"code":"server_busy","message":"The server is busy."}""", System.Net.HttpStatusCode.ServiceUnavailable);
        var window = FakeLibrary.ShowLibrary(server);
        static bool Shows(Control page, string text) => page.GetVisualDescendants().OfType<TextBlock>().Any(t => t.Text == text);
        FakeLibrary.Pump(() => window.Shell?.CurrentPage is HomePage page && Shows(page, "Server Unavailable"));
        var home = Assert.IsType<HomePage>(window.Shell!.CurrentPage);
        Assert.True(Shows(home, "Server Unavailable"));
        Assert.Empty(home.GetVisualDescendants().OfType<Aurelia.Linux.Controls.Spinner>());

        server.Replace("GET", "/api/v1/home", System.Text.Json.JsonSerializer.Serialize(
            new HomeResponse(null, [], [], [], [], DateTimeOffset.UtcNow.AddHours(1)), Aurelia.Linux.Core.Api.AureliaJson.Options));
        Click(home.GetVisualDescendants().OfType<Button>().Single(b => b.Content as string == "Try Again"));
        FakeLibrary.Pump(() => window.Session.Library!.Home is not null && !Shows(home, "Server Unavailable"));
        Assert.NotNull(window.Session.Library!.Home);
        Assert.False(Shows(home, "Server Unavailable"));
    }

    [AvaloniaFact]
    public void ALargeLibraryMakesOnlyTheCardsNearTheViewAndMoreWhileScrolling()
    {
        var titles = Enumerable.Range(0, 600).Select(index => new CatalogItemSummary(Guid.NewGuid(), MediaKind.Movie, $"Invented Film {index:D3}", null, 2000,
            null, ["Drama"], null, null, MediaAvailability.Available, false, null, DateTimeOffset.UtcNow.AddMinutes(-index))).ToArray();
        var server = FakeLibrary.Create().Replace("GET", "/api/v1/catalog/items", System.Text.Json.JsonSerializer.Serialize(
            new PagedResponse<CatalogItemSummary>(titles, 0, titles.Length, titles.Length, "r1"), Aurelia.Linux.Core.Api.AureliaJson.Options));
        var window = FakeLibrary.ShowLibrary(server);
        window.Shell!.Destination = LibraryDestination.Movies;
        FakeLibrary.Pump(() => (window.Shell.CurrentPage as BrowsePage)?.Model.Items.Count == 600, rounds: 400);
        FakeLibrary.Pump(() => false, rounds: 10);
        var page = Assert.IsType<BrowsePage>(window.Shell.CurrentPage);
        var grid = page.GetVisualDescendants().OfType<LazyCards>().Single();
        Assert.Equal(600, grid.Count);
        Assert.InRange(grid.Children.Count, 4, 60);
        Assert.Contains(page.GetVisualDescendants().OfType<Button>(), b => AutomationProperties.GetName(b) == "Invented Film 000");

        // Far down the page the cards there are made, in their places.
        page.GetVisualDescendants().OfType<ScrollViewer>().First().Offset = new Avalonia.Vector(0, 20_000);
        FakeLibrary.Pump(() => false, rounds: 20);
        window.UpdateLayout();
        FakeLibrary.Pump(() => false, rounds: 10);
        var shown = grid.Children.OfType<Button>().Where(b => b.IsEffectivelyVisible && b.Bounds.Top > 0).ToList();
        Assert.InRange(grid.Children.Count, 8, 160);
        Assert.Contains(grid.Children.OfType<Button>(), b => int.Parse(AutomationProperties.GetName(b)![^3..], System.Globalization.CultureInfo.InvariantCulture) > 200);
        Assert.NotEmpty(shown);
    }

    [AvaloniaFact]
    public void ACardBuildsItsMenuWhenItOpens()
    {
        var window = FakeLibrary.ShowLibrary(FakeLibrary.Create());
        window.Shell!.Destination = LibraryDestination.Movies;
        FakeLibrary.Pump(() => (window.Shell.CurrentPage as BrowsePage)?.Model.Items.Count > 0);
        var card = window.Shell.CurrentPage!.GetVisualDescendants().OfType<Button>().First(b => AutomationProperties.GetName(b) == "Quiet Orbit");
        var menu = Assert.IsType<ContextMenu>(card.ContextMenu);
        Assert.Single(menu.ItemsSource!.OfType<MenuItem>());
        // Asking for the menu (right click, menu key) fills it before it opens.
        card.RaiseEvent(new Avalonia.Input.ContextRequestedEventArgs { RoutedEvent = Control.ContextRequestedEvent, Source = card });
        FakeLibrary.Pump(() => false, rounds: 5);
        Assert.Contains(menu.ItemsSource!.OfType<MenuItem>(), item => item.Header as string == "Play");
        menu.Close();
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
        // No other player is open, so there is nothing to Play On.
        Assert.DoesNotContain(detail.GetVisualDescendants().OfType<Button>(), b => AutomationProperties.GetName(b) == "Play On…" && b.IsVisible);
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
    public void PlayOnAppearsOnlyWhileAnotherPlayerIsOpen()
    {
        var server = FakeLibrary.Create();
        var tv = new RemotePlayerDevice("synthetic-tv", "Living Room TV", "tvos", false, null, null, null, null, false, DateTimeOffset.UtcNow);
        server.Answer("GET", "/api/v1/devices/players", System.Text.Json.JsonSerializer.Serialize(new[] { tv }, Aurelia.Linux.Core.Api.AureliaJson.Options));
        var window = FakeLibrary.ShowLibrary(server);
        var movie = window.Session.Library!.Catalog.First(item => item.Kind == MediaKind.Movie);
        window.Shell!.OpenDetail(movie);
        FakeLibrary.Pump(() => (window.Shell.CurrentPage as DetailPage)?.GetVisualDescendants().OfType<Button>()
            .Any(b => AutomationProperties.GetName(b) == "Play On…" && b.IsVisible) == true);
        var detail = Assert.IsType<DetailPage>(window.Shell.CurrentPage);
        var playOn = detail.GetVisualDescendants().OfType<Button>().Single(b => AutomationProperties.GetName(b) == "Play On…");
        var flyout = Assert.IsType<MenuFlyout>(playOn.Flyout);
        Assert.Equal(["Play on Living Room TV"], flyout.ItemsSource!.OfType<MenuItem>().Select(m => m.Header as string));

        // The menu beside the buttons repeats none of them.
        var more = detail.GetVisualDescendants().OfType<Button>().Single(b => AutomationProperties.GetName(b) == "More Actions");
        var headers = Assert.IsType<MenuFlyout>(more.Flyout).ItemsSource!.OfType<MenuItem>().Select(m => m.Header as string).ToList();
        Assert.DoesNotContain("Play", headers);
        Assert.DoesNotContain("Add to Favorites", headers);
        Assert.DoesNotContain("Add to Watchlist", headers);
        Assert.IsNotType<Separator>(Assert.IsType<MenuFlyout>(more.Flyout).ItemsSource!.OfType<Control>().First());
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
             "Mark Series as Watched", "Mark Series as Unwatched", "Add to Collection", "Remove from Continue Watching",
             "Edit Metadata…", "Remove from Library…"],
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
    public void TheCollectionEditorSavesBoxSetWithOverviewSortOrderAndMembers()
    {
        var server = FakeLibrary.Create();
        var window = FakeLibrary.ShowLibrary(server);
        window.Shell!.EditCollection(null, window.Session.Library!.Catalog.Single(item => item.Id == FakeLibrary.MovieA));
        FakeLibrary.Pump(() => window.Shell.SheetHost.IsShowing);
        var editor = Assert.IsType<CollectionEditorSheet>(Assert.IsType<Border>(window.Shell.SheetHost.Current).Child);
        Assert.False(editor.Model.CanSave);
        Assert.Equal("Give the collection a name.", editor.Model.Problem);

        editor.Model.Name = "New One";
        Assert.True(editor.Model.CanSave);
        editor.Model.Overview = "Curated double bill.";
        editor.Model.SortMode = "release";
        editor.Model.Toggle(window.Session.Library!.Catalog.Single(item => item.Id == FakeLibrary.MovieB));
        editor.Model.ToggleMember(FakeLibrary.SeriesId, 0, "Cobalt Station · Specials", MediaKind.Series);
        Assert.Equal(3, editor.Model.SelectedMembers.Count);

        Snapshot(window, "collection-editor");
        Click(editor.GetVisualDescendants().OfType<Button>().Single(b => b.Content as string == "Save"));
        FakeLibrary.Pump(() => server.Bodies.ContainsKey("POST /api/v1/collections"));
        var body = server.Bodies["POST /api/v1/collections"];
        Assert.Contains("\"name\":\"New One\"", body, StringComparison.Ordinal);
        Assert.Contains("\"overview\":\"Curated double bill.\"", body, StringComparison.Ordinal);
        Assert.Contains("\"sortMode\":\"release\"", body, StringComparison.Ordinal);
        Assert.Contains("\"seasonNumber\":0", body, StringComparison.Ordinal);
        Assert.Contains(FakeLibrary.MovieA.ToString(), body, StringComparison.Ordinal);
        Assert.Contains(FakeLibrary.MovieB.ToString(), body, StringComparison.Ordinal);
    }

    [AvaloniaFact]
    public void CollectionDetailLoadsBoxSetMetadataAndPlaysOrderedQueue()
    {
        var server = FakeLibrary.Create();
        var engines = new SimulatedEngines();
        var window = FakeLibrary.ShowLibrary(server, engines);
        window.Shell!.Destination = LibraryDestination.Collections;
        FakeLibrary.Pump(() => window.Shell.CurrentPage is CollectionsPage);
        var cardButton = window.Shell.CurrentPage!.GetVisualDescendants().OfType<Button>()
            .First(b => b.GetVisualDescendants().OfType<TextBlock>().Any(t => t.Text == "Weekend Picks"));
        Click(cardButton);
        FakeLibrary.Pump(() => window.Shell.CurrentPage is CollectionDetailPage
            && server.Requests.Contains($"GET /api/v1/collections/{FakeLibrary.CollectionId}")
            && window.Shell.CurrentPage.GetVisualDescendants().OfType<TextBlock>().Any(t => t.Text == "Invented double-feature box."));
        var texts = window.Shell.CurrentPage!.GetVisualDescendants().OfType<TextBlock>().Select(t => t.Text).ToList();
        Assert.Contains("Weekend Picks", texts);
        Assert.Contains("Invented double-feature box.", texts);
        Assert.Contains("Quiet Orbit", texts);
        Assert.Contains("The Quiet Harbor", texts);
        Assert.Contains(texts, t => t?.Contains("2023–2024", StringComparison.Ordinal) == true);

        var playButton = window.Shell.CurrentPage!.GetVisualDescendants().OfType<Button>()
            .First(b => (b.Content as string)?.Contains("Resume", StringComparison.Ordinal) == true
                || b.GetVisualDescendants().OfType<TextBlock>().Any(t => t.Text?.Contains("Resume", StringComparison.Ordinal) == true));
        Click(playButton);
        FakeLibrary.Pump(() => server.Requests.Contains($"POST /api/v1/media/{FakeLibrary.MovieA}/playback"));
        Assert.Contains($"GET /api/v1/collections/{FakeLibrary.CollectionId}/next", server.Requests);
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
