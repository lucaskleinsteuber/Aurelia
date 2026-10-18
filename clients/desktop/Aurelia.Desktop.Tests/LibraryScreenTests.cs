using Avalonia.Controls;
using Avalonia.Headless.XUnit;
using Avalonia.Threading;
using Aurelia.Desktop.Core;
using Aurelia.Desktop.Views;
using Xunit;

namespace Aurelia.Desktop.Tests;

/// <summary>The library and player screens with synthetic data, rendered off screen.</summary>
public sealed class LibraryScreenTests
{
    private static async Task<(MainWindow Window, FakeEngineFactory Engines)> OpenLibraryAsync()
    {
        var (flow, _, _) = ConnectionFlowTests.Create(FakeServerApi.Saved());
        var engines = new FakeEngineFactory();
        var window = new MainWindow(flow, _ => new FakeLibraryApi(), _ => engines, MainWindowTests.TemporarySettings(), startOnOpen: false,
            artworkCache: _ => null)
        { Width = 1280, Height = 800 };
        window.Show();
        await flow.StartAsync();
        await flow.ChooseProfileAsync(FakeServerApi.Guest);
        await MainWindowTests.WaitFor(() => window.LibraryModel?.Rows.Count > 0);
        await Artwork();
        return (window, engines);
    }

    /// <summary>Lets artwork decode and arrive, then draws.</summary>
    private static async Task Artwork()
    {
        for (var round = 0; round < 10; round++)
        {
            Dispatcher.UIThread.RunJobs();
            await Task.Delay(30);
        }
    }

    [AvaloniaFact]
    public async Task HomeShowsTheHeroAndShelves()
    {
        var (window, _) = await OpenLibraryAsync();
        MainWindowTests.Settle(window, "home");
        Assert.True(window.FindControl<LibraryView>("Library")!.IsVisible);
        var library = window.FindControl<LibraryView>("Library")!;
        Assert.Equal("Synthetic Series", library.FindControl<TextBlock>("HeroTitle")!.Text);
        Assert.Equal(4, library.FindControl<ItemsControl>("HomeRows")!.ItemCount);
    }

    [AvaloniaFact]
    public async Task GridsSearchAndDetailPagesRender()
    {
        var (window, _) = await OpenLibraryAsync();
        var model = window.LibraryModel!;
        var library = window.FindControl<LibraryView>("Library")!;

        library.FindControl<ListBox>("Navigation")!.SelectedIndex = 1;
        await MainWindowTests.WaitFor(() => model.Movies.Count == 2);
        await Artwork();
        MainWindowTests.Settle(window, "movies");
        Assert.Equal(2, library.FindControl<ItemsControl>("MovieGrid")!.ItemCount);

        library.FindControl<ListBox>("Navigation")!.SelectedIndex = 3;
        model.SearchText = "synthetic";
        await MainWindowTests.WaitFor(() => model.SearchResults.Count == 2);
        await Artwork();
        MainWindowTests.Settle(window, "search");

        await model.OpenDetailAsync(FakeLibraryApi.SeriesId);
        await Artwork();
        MainWindowTests.Settle(window, "series");
        Assert.True(library.FindControl<ScrollViewer>("DetailPage")!.IsVisible);
        Assert.Equal("Synthetic Series", library.FindControl<TextBlock>("DetailTitle")!.Text);
        Assert.Equal(2, library.FindControl<ItemsControl>("EpisodeList")!.ItemCount);

        await model.OpenDetailAsync(FakeLibraryApi.MovieId);
        await Artwork();
        MainWindowTests.Settle(window, "movie");
        Assert.Equal("Synthetic Movie", library.FindControl<TextBlock>("DetailTitle")!.Text);
    }

    [AvaloniaFact]
    public async Task PlayingOpensThePlayerAndClosingReturnsToTheLibrary()
    {
        var (window, engines) = await OpenLibraryAsync();
        var model = window.LibraryModel!;
        await model.PlayAsync(FakeLibraryApi.EpisodeOneId);
        await MainWindowTests.WaitFor(() => window.PlayerModel is not null && engines.Created.Count > 0 && engines.Created[^1].Opened.Count > 0);
        var player = window.FindControl<PlayerView>("Player")!;
        Assert.True(player.IsVisible);
        Assert.False(window.FindControl<LibraryView>("Library")!.IsVisible);
        MainWindowTests.Settle(window, "player-starting");
        Assert.True(player.FindControl<Panel>("StartScreen")!.IsVisible);

        var engine = engines.Created[^1];
        engine.Advance(600_100);
        engine.Advance(601_000);
        Dispatcher.UIThread.RunJobs();
        MainWindowTests.Settle(window, "player");
        Assert.False(player.FindControl<Panel>("StartScreen")!.IsVisible);
        Assert.Equal("Pilot", player.FindControl<TextBlock>("PlayerTitle")!.Text);

        engine.Advance(2_686_000);
        Dispatcher.UIThread.RunJobs();
        MainWindowTests.Settle(window, "player-up-next");
        Assert.True(player.FindControl<Border>("UpNextCard")!.IsVisible);
        Assert.Equal("The Second One", player.FindControl<TextBlock>("UpNextTitle")!.Text);

        player.FindControl<Button>("BackButton")!.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        await MainWindowTests.WaitFor(() => engine.Disposed && window.FindControl<LibraryView>("Library")!.IsVisible);
        Assert.False(player.IsVisible);
        Assert.Null(window.PlayerModel);
    }
}
