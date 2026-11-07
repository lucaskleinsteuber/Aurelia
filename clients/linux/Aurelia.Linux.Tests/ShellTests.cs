using System.Runtime.InteropServices;
using Aurelia.Contracts;
using Aurelia.Linux.Core;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Library;
using Aurelia.Linux.Views;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Avalonia.VisualTree;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class ShellTests
{
    [AvaloniaFact]
    public void SidebarListsTheLibraryPagesInTheMacOrder()
    {
        var window = FakeLibrary.ShowLibrary(FakeLibrary.Create());
        Assert.Equal(
            ["Home", "Library", "Collections", "Watchlist", "Recently Added", "TV Shows", "Movies", "Downloads"],
            window.Shell!.SidebarItems.Select(item => item.Title));
        Assert.All(window.Shell.SidebarItems, item => Assert.NotNull(item.Icon));
    }

    [AvaloniaFact]
    public void WatchlistNeedsAServerThatSupportsIt()
    {
        var window = FakeLibrary.ShowLibrary(FakeLibrary.Create(watchlist: false));
        Assert.DoesNotContain(window.Shell!.SidebarItems, item => item.Destination == LibraryDestination.Watchlist);
    }

    [AvaloniaFact]
    public void EveryPageHasASymbol()
    {
        TestWindows.Show();
        foreach (var destination in Enum.GetValues<LibraryDestination>()) Assert.NotNull(LibraryShell.Icon(destination));
    }

    [AvaloniaFact]
    public void HomeShowsTheHeroAndTheShelves()
    {
        var window = FakeLibrary.ShowLibrary(FakeLibrary.Create());
        Assert.IsType<HomePage>(window.Shell!.CurrentPage);
        var texts = window.Shell.CurrentPage!.GetVisualDescendants().OfType<TextBlock>().Select(t => t.Text).ToList();
        Assert.Contains("Cobalt Station", texts);
        Assert.Contains("Continue Watching", texts);
        Assert.Contains("Science Fiction", texts);
        Assert.Contains("Favorites", texts);
        Assert.Contains("Collections", texts);
        Assert.Contains("Recently Added", texts);
        FakeLibrary.Pump(() => false, rounds: 40);
        using var frame = window.CaptureRenderedFrame()!;
        TestWindows.SaveSnapshot(frame, "library-home");
        // Hero artwork runs beneath the sidebar; there it stays visible but darker.
        var hero = Pixel(frame, 900, 200);
        var sidebar = Pixel(frame, 120, 200);
        Assert.True(Brightness(sidebar) < Brightness(hero) + 30, $"Sidebar {sidebar} should not be brighter than the hero {hero}");
    }

    [AvaloniaFact]
    public void SwitchingPagesKeepsEachPageAlive()
    {
        var window = FakeLibrary.ShowLibrary(FakeLibrary.Create());
        var home = window.Shell!.CurrentPage;
        window.Shell.Destination = LibraryDestination.Movies;
        FakeLibrary.Pump(() => false, rounds: 20);
        var movies = Assert.IsType<BrowsePage>(window.Shell.CurrentPage);
        Assert.Equal(Core.Library.BrowseSection.Movies, movies.Model.Section);
        window.Shell.Destination = LibraryDestination.Home;
        Assert.Same(home, window.Shell.CurrentPage);
    }

    [AvaloniaFact]
    public void KeyboardMovesThroughTheSidebar()
    {
        var window = FakeLibrary.ShowLibrary(FakeLibrary.Create());
        var list = window.Shell!.GetVisualDescendants().OfType<ListBox>().Single(l => l.Name == "SidebarList");
        list.ContainerFromIndex(0)!.Focus(NavigationMethod.Tab);
        window.KeyPressQwerty(PhysicalKey.ArrowDown, RawInputModifiers.None);
        Dispatcher.UIThread.RunJobs();
        Assert.Equal(LibraryDestination.Library, window.Shell!.Destination);
    }

    [AvaloniaFact]
    public void PagesRunBeneathTheSidebarAndStartBesideIt()
    {
        var window = FakeLibrary.ShowLibrary(FakeLibrary.Create());
        Assert.Equal(236, window.Shell!.CurrentPage!.SidebarOverlap);
        Assert.Equal(new Point(0, 0), window.Shell.CurrentPage.TranslatePoint(new Point(0, 0), window));
        window.Shell.SidebarVisible = false;
        Dispatcher.UIThread.RunJobs();
        Assert.Equal(0, window.Shell.CurrentPage.SidebarOverlap);
        var toggle = window.Shell.GetVisualDescendants().OfType<Button>().Single(b => b.Name == "SidebarToggle");
        Assert.Equal("Show Sidebar", AutomationProperties.GetName(toggle));
    }

    [AvaloniaFact]
    public void SidebarBlursWhatPassesBeneathItAndCanBeOpaque()
    {
        var window = FakeLibrary.ShowLibrary(FakeLibrary.Create());
        var backdrop = window.Shell!.SidebarBackdrop;
        Assert.True(backdrop.ShowsBlur);
        backdrop.ReduceTransparency = true;
        Dispatcher.UIThread.RunJobs();
        Assert.False(backdrop.ShowsBlur);
    }

    [AvaloniaFact]
    public void ControlFLeadsToTheLibrarySearch()
    {
        var window = FakeLibrary.ShowLibrary(FakeLibrary.Create());
        window.Shell!.FindInLibrary();
        FakeLibrary.Pump(() => false, rounds: 20);
        Assert.Equal(LibraryDestination.Library, window.Shell.Destination);
        Assert.IsType<BrowsePage>(window.Shell.CurrentPage);
    }

    internal static int Brightness(Color color) => color.R + color.G + color.B;

    internal static Color Pixel(WriteableBitmap bitmap, int x, int y)
    {
        using var buffer = bitmap.Lock();
        var scale = buffer.Size.Width / 1280.0;
        var pixel = new byte[4];
        Marshal.Copy(buffer.Address + (int)(y * scale) * buffer.RowBytes + (int)(x * scale) * 4, pixel, 0, 4);
        return buffer.Format == Avalonia.Platform.PixelFormat.Rgba8888
            ? Color.FromArgb(pixel[3], pixel[0], pixel[1], pixel[2])
            : Color.FromArgb(pixel[3], pixel[2], pixel[1], pixel[0]);
    }
}
