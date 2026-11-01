using Aurelia.Contracts;
using System.Text;
using System.Text.Json;
using Aurelia.Linux.Core.Playback;
using Aurelia.Linux.Playback;
using Aurelia.Linux.Views;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.Input;
using Avalonia.Threading;
using Avalonia.VisualTree;
using Xunit;

namespace Aurelia.Linux.Tests;

/// <summary>The player through its real view, with a simulated engine and no real video.</summary>
public sealed class PlayerViewTests
{
    private static (MainWindow Window, SimulatedEngines Engines, PlayerView View) Play(Guid mediaId)
    {
        var engines = new SimulatedEngines();
        var window = FakeLibrary.ShowLibrary(FakeLibrary.Create(), engines);
        var item = window.Session.Library!.Catalog.Concat(window.Session.Library.Home!.ContinueWatching).First(i => i.Id == mediaId);
        _ = window.PlayAsync(item, resume: true);
        FakeLibrary.Pump(() => window.Player?.State == PlayerState.Playing);
        var view = window.GetVisualDescendants().OfType<PlayerView>().Single();
        return (window, engines, view);
    }

    [AvaloniaFact]
    public void OpensOverTheLibraryAndShowsTheControls()
    {
        var (window, engines, view) = Play(FakeLibrary.MovieA);
        Assert.Equal(PlayerState.Playing, window.Player!.State);
        Assert.Equal(1_200_000, engines.Last.OpenedAt);
        var names = view.GetVisualDescendants().OfType<Button>().Select(AutomationProperties.GetName).ToList();
        Assert.Contains("Pause", names);
        Assert.Contains("Back 10 Seconds", names);
        Assert.Contains("Forward 10 Seconds", names);
        Assert.Contains("Playback Rate", names);
        Assert.Contains("Audio", names);
        Assert.Contains("Subtitles", names);
        Assert.Contains("Sleep Timer", names);
        Assert.Contains("Scene Notes", names);
        Assert.Contains("Full Screen (F)", names);
        var texts = view.GetVisualDescendants().OfType<TextBlock>().Select(t => t.Text).ToList();
        Assert.Contains("Quiet Orbit", texts);
        Assert.Contains("20:00", texts);
        Assert.Contains("-40:00", texts);
        using var frame = window.CaptureRenderedFrame()!;
        TestWindows.SaveSnapshot(frame, "player");
    }

    [AvaloniaFact]
    public void KeysControlPlaybackLikeOnTheMac()
    {
        var (window, engines, view) = Play(FakeLibrary.MovieA);
        view.Focus();
        window.KeyPressQwerty(PhysicalKey.Space, RawInputModifiers.None);
        Dispatcher.UIThread.RunJobs();
        Assert.Equal(PlayerState.Paused, window.Player!.State);
        window.KeyPressQwerty(PhysicalKey.Space, RawInputModifiers.None);
        Dispatcher.UIThread.RunJobs();
        Assert.Equal(PlayerState.Playing, window.Player.State);

        window.KeyPressQwerty(PhysicalKey.ArrowRight, RawInputModifiers.None);
        Dispatcher.UIThread.RunJobs();
        Assert.Equal(1_210_000, engines.Last.Time);
        window.KeyPressQwerty(PhysicalKey.ArrowLeft, RawInputModifiers.None);
        Dispatcher.UIThread.RunJobs();
        Assert.Equal(1_200_000, engines.Last.Time);

        window.KeyPressQwerty(PhysicalKey.M, RawInputModifiers.None);
        Dispatcher.UIThread.RunJobs();
        Assert.True(engines.Last.Muted);

        window.KeyPressQwerty(PhysicalKey.F, RawInputModifiers.None);
        Dispatcher.UIThread.RunJobs();
        Assert.Equal(WindowState.FullScreen, window.WindowState);
        window.KeyPressQwerty(PhysicalKey.Escape, RawInputModifiers.None);
        Dispatcher.UIThread.RunJobs();
        Assert.Equal(WindowState.Normal, window.WindowState);
        window.KeyPressQwerty(PhysicalKey.Escape, RawInputModifiers.None);
        FakeLibrary.Pump(() => window.Player is null);
        Assert.Null(window.Player);
        Assert.Empty(window.GetVisualDescendants().OfType<PlayerView>());
    }

    [AvaloniaFact]
    public void TheMenusListTheTracksAndRates()
    {
        var (window, _, view) = Play(FakeLibrary.MovieA);
        var audio = view.GetVisualDescendants().OfType<Button>().Single(b => AutomationProperties.GetName(b) == "Audio");
        var flyout = Assert.IsType<MenuFlyout>(audio.Flyout);
        flyout.ShowAt(audio);
        Dispatcher.UIThread.RunJobs();
        var headers = flyout.Items.OfType<MenuItem>().Select(m => m.Header as string).ToList();
        Assert.Contains("Track 1 - [English]", headers);
        Assert.Contains("Night Mode", headers);
        flyout.Hide();
        var speed = view.GetVisualDescendants().OfType<Button>().Single(b => AutomationProperties.GetName(b) == "Playback Rate");
        var rates = Assert.IsType<MenuFlyout>(speed.Flyout);
        rates.ShowAt(speed);
        Dispatcher.UIThread.RunJobs();
        Assert.Equal(["0.5×", "0.75×", "Standard", "1.25×", "1.5×", "2×"], rates.Items.OfType<MenuItem>().Select(m => m.Header as string));
        rates.Hide();
        _ = window;
    }

    [AvaloniaFact]
    public void TheUpNextCardAppearsNearTheEndOfAnEpisode()
    {
        var (window, engines, view) = Play(FakeLibrary.EpisodeOne);
        Assert.Equal(FakeLibrary.EpisodeTwo, window.Player!.NextItem?.Id);
        engines.Last.Advance(3_600_000 - 600_000 - 12_000);
        Dispatcher.UIThread.RunJobs();
        var texts = view.GetVisualDescendants().OfType<TextBlock>().Where(t => t.IsEffectivelyVisible).Select(t => t.Text).ToList();
        Assert.Contains("UP NEXT", texts);
        Assert.Contains("S1 E2 · Signal", texts);
        Assert.Contains("Playing in 12 s", texts);
        using var frame = window.CaptureRenderedFrame()!;
        TestWindows.SaveSnapshot(frame, "player-up-next");
    }

    [AvaloniaFact]
    public void ChaptersShowAMenuAndTimelineMarkersAndSeekThroughTheEngine()
    {
        var (window, engines, view) = Play(FakeLibrary.MovieA);
        engines.Last.Chapters = [new PlaybackChapter(0, "Departure", 0), new PlaybackChapter(1, "The Signal", 600_000)];
        engines.Last.Chapter = 0;
        engines.Last.Advance(0);
        FakeLibrary.Pump(() => window.Player!.Chapters.Count == 2);
        var button = view.GetVisualDescendants().OfType<Button>().Single(b => AutomationProperties.GetName(b) == "Chapters");
        Assert.True(button.IsEffectivelyVisible);
        var flyout = Assert.IsType<MenuFlyout>(button.Flyout);
        flyout.ShowAt(button);
        Dispatcher.UIThread.RunJobs();
        var entry = flyout.Items.OfType<MenuItem>().Single(item => item.Header as string == "The Signal  10:00");
        entry.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(MenuItem.ClickEvent));
        Assert.Equal(1, engines.Last.Chapter);
        Assert.Equal(600_000, engines.Last.Time);
        Assert.Equal(1, view.ChapterMarkerCount);
        flyout.Hide();
        using var frame = window.CaptureRenderedFrame()!;
        TestWindows.SaveSnapshot(frame, "player-chapters");
        _ = window.Player!.CloseAsync();
    }

    [AvaloniaFact]
    public async Task ExportsSanitizedDiagnosticsOnlyWhenADestinationIsChosen()
    {
        var (window, _, view) = Play(FakeLibrary.MovieA);
        Assert.Contains(view.ContextMenu!.Items.OfType<MenuItem>(), item => item.Header as string == "Export Playback Diagnostics…");
        var output = new MemoryStream();
        output.Write(new byte[10000]);
        view.DiagnosticsDestination = () => Task.FromResult<Stream?>(output);
        await view.ExportDiagnosticsAsync();
        var json = Encoding.UTF8.GetString(output.ToArray());
        using var document = JsonDocument.Parse(json);
        Assert.NotEmpty(document.RootElement.GetProperty("events").EnumerateArray());
        Assert.DoesNotContain("Quiet Orbit", json, StringComparison.Ordinal);
        Assert.DoesNotContain("token", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("192.168", json, StringComparison.Ordinal);
        view.DiagnosticsDestination = () => Task.FromResult<Stream?>(null);
        await view.ExportDiagnosticsAsync();
        await window.Player!.CloseAsync();
    }
}
