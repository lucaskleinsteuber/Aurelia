using System.Runtime.InteropServices;
using Aurelia.Linux.Core;
using Aurelia.Linux.Views;
using Avalonia;
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
    private static MainWindow ShowWindow()
    {
        var window = new MainWindow { Width = 1280, Height = 800 };
        window.Show();
        Dispatcher.UIThread.RunJobs();
        return window;
    }

    [AvaloniaFact]
    public void SidebarListsTheLibraryPagesInTheMacOrder()
    {
        var window = ShowWindow();
        Assert.Equal(
            ["Home", "Library", "Collections", "Watchlist", "Recently Added", "TV Shows", "Movies"],
            window.Shell.SidebarItems.Select(item => item.Title));
        Assert.All(window.Shell.SidebarItems, item => Assert.NotNull(item.Icon));
    }

    [AvaloniaFact]
    public void EveryPageHasASymbol()
    {
        ShowWindow();
        foreach (var destination in Enum.GetValues<LibraryDestination>()) Assert.NotNull(LibraryShell.Icon(destination));
    }

    [AvaloniaFact]
    public void StartsOnHomeAndSwitchesPages()
    {
        var window = ShowWindow();
        Assert.Equal(LibraryDestination.Home, window.Shell.CurrentPage?.Destination);

        window.Shell.Destination = LibraryDestination.Movies;
        Dispatcher.UIThread.RunJobs();
        Assert.Equal(LibraryDestination.Movies, window.Shell.CurrentPage?.Destination);
        Assert.Contains(window.Shell.CurrentPage!.GetVisualDescendants().OfType<TextBlock>(), text => text.Text == "Movies");
    }

    [AvaloniaFact]
    public void KeyboardMovesThroughTheSidebar()
    {
        var window = ShowWindow();
        var list = window.Shell.GetVisualDescendants().OfType<ListBox>().Single(l => l.Name == "SidebarList");
        var first = list.ContainerFromIndex(0)!;
        first.Focus(NavigationMethod.Tab);
        window.KeyPressQwerty(PhysicalKey.ArrowDown, RawInputModifiers.None);
        Dispatcher.UIThread.RunJobs();
        Assert.Equal(LibraryDestination.Library, window.Shell.Destination);
    }

    [AvaloniaFact]
    public void PagesRunBeneathTheSidebarAndStartBesideIt()
    {
        var window = ShowWindow();
        Assert.Equal(236, window.Shell.CurrentPage!.SidebarOverlap);
        Assert.Equal(new Point(0, 0), window.Shell.CurrentPage.TranslatePoint(new Point(0, 0), window));

        window.Shell.SidebarVisible = false;
        Dispatcher.UIThread.RunJobs();
        Assert.Equal(0, window.Shell.CurrentPage.SidebarOverlap);
        var toggle = window.Shell.GetVisualDescendants().OfType<Button>().Single(b => b.Name == "SidebarToggle");
        Assert.Equal("Show Sidebar", Avalonia.Automation.AutomationProperties.GetName(toggle));
    }

    [AvaloniaFact]
    public void SidebarBlursWhatPassesBeneathItAndCanBeOpaque()
    {
        var window = ShowWindow();
        var backdrop = window.Shell.SidebarBackdrop;
        Assert.True(backdrop.ShowsBlur);

        backdrop.ReduceTransparency = true;
        Dispatcher.UIThread.RunJobs();
        Assert.False(backdrop.ShowsBlur);
    }

    [AvaloniaFact]
    public void RendersTheHeroBeneathTheTintedSidebar()
    {
        var window = ShowWindow();
        using var frame = window.CaptureRenderedFrame()!;
        SaveSnapshot(frame, "home");
        // Hero artwork glows behind the page; beneath the sidebar it stays visible but darker.
        var hero = Pixel(frame, 900, 200);
        var sidebar = Pixel(frame, 120, 200);
        Assert.True(hero.B > hero.R + 40, $"Hero should be blue, was {hero}");
        Assert.True(Brightness(sidebar) < Brightness(hero), $"Sidebar {sidebar} should be darker than the hero {hero}");
        Assert.True(sidebar.B >= sidebar.R, $"Hero color should show through the sidebar, was {sidebar}");

        window.Shell.Destination = LibraryDestination.TvShows;
        Dispatcher.UIThread.RunJobs();
        using var page = window.CaptureRenderedFrame()!;
        SaveSnapshot(page, "tv-shows");
    }

    private static int Brightness(Color color) => color.R + color.G + color.B;

    private static Color Pixel(WriteableBitmap bitmap, int x, int y)
    {
        using var buffer = bitmap.Lock();
        var scale = buffer.Size.Width / 1280.0;
        var pixel = new byte[4];
        Marshal.Copy(buffer.Address + (int)(y * scale) * buffer.RowBytes + (int)(x * scale) * 4, pixel, 0, 4);
        return buffer.Format == Avalonia.Platform.PixelFormat.Rgba8888
            ? Color.FromArgb(pixel[3], pixel[0], pixel[1], pixel[2])
            : Color.FromArgb(pixel[3], pixel[2], pixel[1], pixel[0]);
    }

    /// <summary>Keeps rendered frames for a person to look at when AURELIA_LINUX_SNAPSHOTS names a folder.</summary>
    private static void SaveSnapshot(Bitmap frame, string name)
    {
        var folder = Environment.GetEnvironmentVariable("AURELIA_LINUX_SNAPSHOTS");
        if (string.IsNullOrEmpty(folder)) return;
        Directory.CreateDirectory(folder);
        frame.Save(Path.Combine(folder, name + ".png"), PngBitmapEncoderOptions.Default);
    }
}
