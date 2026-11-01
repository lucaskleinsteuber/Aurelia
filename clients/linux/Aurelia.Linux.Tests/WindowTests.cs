using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Platform;
using Aurelia.Linux.Views;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.Input;
using Avalonia.Threading;
using Avalonia.VisualTree;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class WindowTests
{
    private static readonly WindowButtonLayout LeftButtons = WindowButtonLayout.FromKde("XIA", "");

    [AvaloniaFact]
    public void OpensOnTheWelcomeChoice()
    {
        var window = TestWindows.Show();
        Assert.IsType<WelcomeView>(window.CurrentScreen);
        var choices = window.CurrentScreen!.GetVisualDescendants().OfType<Button>().Select(AutomationProperties.GetName).ToList();
        Assert.Contains("Set Up This PC", choices);
        Assert.Contains("Connect to an Existing Server", choices);
        using var frame = window.CaptureRenderedFrame()!;
        TestWindows.SaveSnapshot(frame, "welcome");
    }

    [AvaloniaFact]
    public void ChoosingAModeOpensItsScreenAndBackReturns()
    {
        var window = TestWindows.Show();
        Click(window.CurrentScreen!.GetVisualDescendants().OfType<Button>().Single(b => AutomationProperties.GetName(b) == "Connect to an Existing Server"));
        Assert.Equal(AppScreen.Connection, window.Flow.Screen);
        Assert.IsType<ConnectionView>(window.CurrentScreen);

        Click(window.CurrentScreen!.GetVisualDescendants().OfType<Button>().Single(b => b.Content as string == "Back" && b.IsEffectivelyVisible));
        Assert.Equal(AppScreen.Welcome, window.Flow.Screen);
    }

    [AvaloniaFact]
    public void WindowButtonsFollowTheDesktopLayout()
    {
        var left = TestWindows.Show(LeftButtons);
        var leftButtons = Chrome(left).Buttons.ToList();
        Assert.Equal(["Close Window", "Minimize Window", "Maximize Window"], leftButtons.Select(AutomationProperties.GetName));
        Assert.All(leftButtons, b => Assert.True(b.TranslatePoint(new Point(0, 0), left)!.Value.X < 120));
        Assert.True(Chrome(left).LeadingWidth > 0);
        using (var frame = left.CaptureRenderedFrame()!) TestWindows.SaveSnapshot(frame, "welcome-buttons-left");

        var right = TestWindows.Show();
        Assert.All(Chrome(right).Buttons, b => Assert.True(b.TranslatePoint(new Point(0, 0), right)!.Value.X > 1100));
        Assert.Equal(0, Chrome(right).LeadingWidth);
    }

    [AvaloniaFact]
    public void MaximizeButtonTogglesAndRelabels()
    {
        var window = TestWindows.Show();
        var maximize = Chrome(window).Buttons.Single(b => AutomationProperties.GetName(b) == "Maximize Window");
        Click(maximize);
        Assert.Equal(WindowState.Maximized, window.WindowState);
        Assert.Equal("Restore Window", AutomationProperties.GetName(maximize));
        Click(maximize);
        Assert.Equal(WindowState.Normal, window.WindowState);
    }

    [AvaloniaFact]
    public void FullScreenHidesTheButtons()
    {
        var window = TestWindows.Show();
        window.KeyPressQwerty(PhysicalKey.F11, RawInputModifiers.None);
        Dispatcher.UIThread.RunJobs();
        Assert.Equal(WindowState.FullScreen, window.WindowState);
        Assert.False(Chrome(window).IsVisible);
        Assert.False(AppWindowBehavior.IsInDragBand(window, new Point(400, 10)));

        window.KeyPressQwerty(PhysicalKey.Escape, RawInputModifiers.None);
        Dispatcher.UIThread.RunJobs();
        Assert.Equal(WindowState.Normal, window.WindowState);
        Assert.True(Chrome(window).IsVisible);
    }

    [AvaloniaFact]
    public void TheTopBandMovesTheWindow()
    {
        var window = TestWindows.Show();
        Assert.True(AppWindowBehavior.IsInDragBand(window, new Point(600, 20)));
        Assert.False(AppWindowBehavior.IsInDragBand(window, new Point(600, 80)));
    }

    [AvaloniaFact]
    public void SidebarToggleMovesBesideLeftWindowButtons()
    {
        var window = TestWindows.Show(LeftButtons);
        window.Flow.Show(AppScreen.Library);
        Dispatcher.UIThread.RunJobs();
        var toggle = window.Shell!.GetVisualDescendants().OfType<Button>().Single(b => b.Name == "SidebarToggle");
        window.Shell!.SidebarVisible = false;
        Dispatcher.UIThread.RunJobs();
        var lastButtonEnd = Chrome(window).Buttons.Max(b => b.TranslatePoint(new Point(b.Bounds.Width, 0), window)!.Value.X);
        Assert.True(toggle.TranslatePoint(new Point(0, 0), window)!.Value.X > lastButtonEnd);
        using var frame = window.CaptureRenderedFrame()!;
        TestWindows.SaveSnapshot(frame, "library-sidebar-hidden-buttons-left");
    }

    [AvaloniaFact]
    public void SidebarWidthStaysBetweenTheMacLimits()
    {
        var window = FakeLibrary.ShowLibrary(FakeLibrary.Create());
        window.Shell!.SidebarWidth = 500;
        Assert.Equal(LibraryShell.MaximumSidebarWidth, window.Shell.SidebarWidth);
        window.Shell.SidebarWidth = 100;
        Assert.Equal(LibraryShell.MinimumSidebarWidth, window.Shell.SidebarWidth);
        Dispatcher.UIThread.RunJobs();
        Assert.Equal(LibraryShell.MinimumSidebarWidth, window.Shell.CurrentPage!.SidebarOverlap);
    }

    private static WindowChrome Chrome(MainWindow window) => window.GetVisualDescendants().OfType<WindowChrome>().Single();

    private static void Click(Button button)
    {
        button.Command?.Execute(button.CommandParameter);
        button.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        Dispatcher.UIThread.RunJobs();
    }
}
