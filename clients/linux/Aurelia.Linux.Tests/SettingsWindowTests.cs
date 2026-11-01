using Aurelia.Linux.Core;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Playback;
using Aurelia.Linux.Core.Settings;
using Aurelia.Linux.Settings;
using Aurelia.Linux.Views;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.Input;
using Avalonia.VisualTree;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class SettingsWindowTests
{
    private static (MainWindow Window, SettingsWindow Settings, FakeServer Server) Open(SettingsCategory category = SettingsCategory.General, MemoryCredentialStore? keyring = null)
    {
        var server = FakeLibrary.Create();
        var window = FakeLibrary.ShowLibrary(server, keyring: keyring);
        var settings = window.OpenSettings(category);
        FakeLibrary.Pump(() => false, rounds: 20);
        return (window, settings, server);
    }

    private static void Snapshot(Window window, string name)
    {
        using var frame = window.CaptureRenderedFrame()!;
        TestWindows.SaveSnapshot(frame, name);
    }

    [AvaloniaFact]
    public void ListsTheCategoriesAndSearchesThem()
    {
        var (_, settings, _) = Open();
        Assert.Equal(
            [SettingsCategory.General, SettingsCategory.Sidebar, SettingsCategory.Activity, SettingsCategory.Playback,
             SettingsCategory.ProfilesAndDevices, SettingsCategory.Updates, SettingsCategory.Advanced],
            settings.VisibleCategories);
        Snapshot(settings, "settings-general");
        Assert.Equal([SettingsCategory.Playback], SettingsWindow.Matching("subtitle"));
        Assert.Contains(SettingsCategory.Advanced, SettingsWindow.Matching("fingerprint"));
        Assert.Equal(7, SettingsWindow.Matching(" ").Count);
    }

    [AvaloniaFact]
    public void GeneralSettingsAreSavedAtOnce()
    {
        var (window, settings, _) = Open();
        var toggles = settings.Page!.GetVisualDescendants().OfType<ToggleSwitch>().ToList();
        var watched = toggles.Single(t => AutomationProperties.GetName(t) == "Show Watched Titles in Rows");
        watched.IsChecked = false;
        Assert.False(window.Session.Preferences.ShowWatchedInRows);
        var rest = toggles.Single(t => AutomationProperties.GetName(t) == "Let the Server Rest When Unused");
        rest.IsChecked = false;
        Assert.False(window.Session.Preferences.RestsWhenUnused);
    }

    [AvaloniaFact]
    public void TheSidebarPagesCanBeHiddenAndMovedButOneStays()
    {
        var (window, settings, _) = Open(SettingsCategory.Sidebar);
        Snapshot(settings, "settings-sidebar");
        ToggleSwitch Show(string title) => settings.Page!.GetVisualDescendants().OfType<ToggleSwitch>().Single(t => AutomationProperties.GetName(t) == "Show " + title);
        Show("Collections").IsChecked = false;
        FakeLibrary.Pump(() => false, rounds: 5);
        Assert.DoesNotContain(window.Shell!.SidebarItems, item => item.Destination == LibraryDestination.Collections);
        Show("History").IsChecked = true;
        FakeLibrary.Pump(() => false, rounds: 5);
        Assert.Contains(window.Shell.SidebarItems, item => item.Destination == LibraryDestination.History);

        var down = settings.Page!.GetVisualDescendants().OfType<Button>().Single(b => AutomationProperties.GetName(b) == "Move Down, Home");
        down.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        FakeLibrary.Pump(() => false, rounds: 5);
        Assert.Equal(LibraryDestination.Library, window.Session.Preferences.Sidebar().Order[0]);

        foreach (var destination in window.Session.Preferences.Sidebar().Order) Show(destination.Title()).IsChecked = false;
        Assert.NotEmpty(window.Session.Preferences.Sidebar().VisibleItems(supportsWatchlist: true));
    }

    [AvaloniaFact]
    public void PlaybackSettingsUseTheMacChoices()
    {
        var (window, settings, _) = Open(SettingsCategory.Playback);
        Snapshot(settings, "settings-playback");
        var countdown = settings.Page!.GetVisualDescendants().OfType<ComboBox>().Single(c => AutomationProperties.GetName(c) == "Up Next Countdown");
        countdown.SelectedIndex = 0;
        Assert.Equal(5, PlaybackPreferences.Load(window.Session.Preferences.Store).UpNextCountdownSeconds);
        var restore = settings.Page!.GetVisualDescendants().OfType<Button>().Single(b => b.Content as string == "Restore Playback Defaults");
        restore.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        Assert.Equal(20, PlaybackPreferences.Load(window.Session.Preferences.Store).UpNextCountdownSeconds);
    }

    [AvaloniaFact]
    public void ChangingTheOwnPinChecksTheEntryAndLocksTheProfile()
    {
        var (window, settings, server) = Open(SettingsCategory.ProfilesAndDevices);
        Snapshot(settings, "settings-profiles");
        TextBox Field(string name) => settings.Page!.GetVisualDescendants().OfType<TextBox>().Single(t => AutomationProperties.GetName(t) == name);
        Field("Current PIN").Text = "1234";
        Field("New PIN").Text = "5678";
        Field("Confirm New PIN").Text = "5679";
        var apply = settings.Page!.GetVisualDescendants().OfType<Button>().Single(b => b.Content as string == "Change PIN & Lock Profile");
        apply.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        FakeLibrary.Pump(() => false, rounds: 5);
        Assert.Contains(settings.Page!.GetVisualDescendants().OfType<TextBlock>(), t => t.Text == "The new PINs do not match." && t.IsVisible);
        Assert.DoesNotContain("PUT /api/v1/profile/pin-protection", server.Requests);

        Field("Confirm New PIN").Text = "5678";
        apply.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        FakeLibrary.Pump(() => window.Flow.Screen == AppScreen.ProfilePicker);
        var body = server.Bodies["PUT /api/v1/profile/pin-protection"];
        Assert.Contains("\"pinProtectionEnabled\":true", body, StringComparison.Ordinal);
        Assert.Contains("\"currentPin\":\"1234\"", body, StringComparison.Ordinal);
        Assert.Contains("\"pin\":\"5678\"", body, StringComparison.Ordinal);
        Assert.Equal(AppScreen.ProfilePicker, window.Flow.Screen);
    }

    [AvaloniaFact]
    public void DisconnectingAsksFirstAndForgetsTheServer()
    {
        var keyring = new MemoryCredentialStore
        {
            Server = new StoredServer(FakeServer.ServerId, "Living Room Server", new Uri("https://192.168.1.20:43111"), FakeServer.Fingerprint,
                "device-token-synthetic-0000000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30)),
        };
        var (window, settings, server) = Open(SettingsCategory.Advanced, keyring);
        Assert.Contains(settings.Page!.GetVisualDescendants().OfType<TextBlock>(), t => t.Text == "A1B2-C3D4-E5F6-0718-293A-4B5C");
        Snapshot(settings, "settings-advanced");
        settings.Page!.GetVisualDescendants().OfType<Button>().Single(b => b.Content as string == "Disconnect This PC…")
            .RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        FakeLibrary.Pump(() => settings.Sheets.IsShowing);
        settings.Sheets.GetVisualDescendants().OfType<Button>().Single(b => b.Content as string == "Disconnect")
            .RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        FakeLibrary.Pump(() => window.Flow.Screen == AppScreen.Connection);
        Assert.Null(keyring.Server);
        Assert.Contains("DELETE /api/v1/device", server.Requests);
    }

    [AvaloniaFact]
    public void TheServerRestsWhenUnusedAndAnyInputContinues()
    {
        var time = new ManualTime();
        var server = FakeLibrary.Create();
        var window = FakeLibrary.ShowLibrary(server, time: time);
        window.Session.Preferences.RestMinutes = 5;
        time.Advance(TimeSpan.FromMinutes(4), TimeSpan.FromMinutes(1));
        window.CheckRest();
        Assert.False(window.Session.IsResting);
        time.Advance(TimeSpan.FromMinutes(2), TimeSpan.FromMinutes(1));
        window.CheckRest();
        Assert.True(window.Session.IsResting);
        Assert.Null(window.Session.Library is { } library && library.Revision < 0 ? library : null);
        FakeLibrary.Pump(() => false, rounds: 5);
        using (var frame = window.CaptureRenderedFrame()!) TestWindows.SaveSnapshot(frame, "rest");

        window.KeyPressQwerty(PhysicalKey.Space, RawInputModifiers.None);
        FakeLibrary.Pump(() => !window.Session.IsResting && window.Session.Library?.Home is not null);
        Assert.False(window.Session.IsResting);
        Assert.Equal(AppScreen.Library, window.Flow.Screen);
    }

    [Fact]
    public void RestFollowsTheMacRules()
    {
        Assert.True(GeneralPreferences.ShouldRest(true, 15, TimeSpan.FromMinutes(15), playing: false, connectedElsewhere: true));
        Assert.False(GeneralPreferences.ShouldRest(true, 15, TimeSpan.FromMinutes(14), false, true));
        Assert.False(GeneralPreferences.ShouldRest(true, 15, TimeSpan.FromHours(1), playing: true, connectedElsewhere: true));
        Assert.False(GeneralPreferences.ShouldRest(true, 15, TimeSpan.FromHours(1), false, connectedElsewhere: false));
        Assert.False(GeneralPreferences.ShouldRest(false, 15, TimeSpan.FromHours(1), false, true));
        var prefs = new GeneralPreferences(new MemorySettingsStore());
        Assert.True(prefs.RestsWhenUnused);
        Assert.Equal(15, prefs.RestMinutes);
        prefs.RestMinutes = 7;
        Assert.Equal(15, prefs.RestMinutes);
    }
}
