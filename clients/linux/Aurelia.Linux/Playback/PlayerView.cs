using System.ComponentModel;
using Aurelia.Contracts;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Playback;
using Aurelia.Linux.Library;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;

namespace Aurelia.Linux.Playback;

/// <summary>
/// The player, laid out like the Mac app's: the picture full window, the title at the top, the
/// timeline with preview pictures and the controls at the bottom, menus for speed, audio (with
/// Night Mode), subtitles and the sleep timer, scene notes, volume and full screen, and the Up Next
/// card. Controls hide after the chosen delay while playing and return with the pointer or a key.
/// </summary>
public sealed class PlayerView : UserControl, IDisposable
{
    private readonly PlaybackController controller;
    private readonly Window? window;
    private readonly VideoSurface surface = new();
    private readonly Grid chrome = new();
    private readonly TextBlock title = new() { FontSize = 18, FontWeight = FontWeight.Bold, Foreground = Brushes.White };
    private readonly TextBlock subtitle = new() { Foreground = new SolidColorBrush(Color.FromArgb(0xCC, 0xFF, 0xFF, 0xFF)) };
    private readonly Slider timeline = new() { Minimum = 0, Maximum = 1, Classes = { "timeline" } };
    private readonly TextBlock elapsed = new() { Classes = { "playerTime" } };
    private readonly TextBlock remaining = new() { Classes = { "playerTime" } };
    private readonly TextBlock endsAt = new() { Classes = { "playerTime" }, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly Button playPause;
    private readonly Button previous;
    private readonly Button next;
    private readonly Button audio;
    private readonly Button subtitles;
    private readonly Button speed;
    private readonly Button sleep;
    private readonly Button notes;
    private readonly Button mute;
    private readonly Slider volume = new() { Minimum = 0, Maximum = 1, Width = 110, Classes = { "volume" } };
    private readonly Border upNext = new() { Classes = { "upNext" }, IsVisible = false, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 40, 190) };
    private readonly TextBlock upNextTitle = new() { FontWeight = FontWeight.Bold, Foreground = Brushes.White, MaxWidth = 280, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock upNextCountdown = new() { Foreground = new SolidColorBrush(Color.FromArgb(0xCC, 0xFF, 0xFF, 0xFF)) };
    private readonly StackPanel status = new() { Spacing = 14, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock statusText = new() { Foreground = Brushes.White, FontSize = 16, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 520 };
    private readonly StackPanel statusActions = new() { Orientation = Orientation.Horizontal, Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly ProgressBar spinner = new() { IsIndeterminate = true, Width = 140 };
    private readonly Border conflict = new() { Classes = { "banner" }, IsVisible = false, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 90, 0, 0) };
    private readonly Border previewBubble = new() { Classes = { "previewBubble" }, IsVisible = false, VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly Image previewImage = new() { Width = 240, Height = 135, Stretch = Stretch.UniformToFill };
    private readonly TextBlock previewTime = new() { Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, FontWeight = FontWeight.SemiBold };
    private readonly StackPanel noteCues = new() { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(40, 110, 0, 0) };
    private readonly ScrubPreviews previews;
    private readonly SceneNotes sceneNotes;
    private DispatcherTimer? hideTimer;
    private bool draggingTimeline;
    private bool updatingTimeline;

    public PlayerView(PlaybackController controller, Window? window)
    {
        this.controller = controller;
        this.window = window;
        Focusable = true;
        Background = Brushes.Black;
        previews = new ScrubPreviews(controller);
        sceneNotes = new SceneNotes(controller);
        playPause = Control("IconPause", "Pause", controller.PlayPause, large: true);
        previous = Control("IconPreviousTrack", "Previous Episode (P)", () => _ = controller.PreviousAsync());
        next = Control("IconNextTrack", "Next Episode (N)", () => _ = controller.NextAsync());
        var back10 = Control("IconBackward", $"Back {controller.Preferences.SeekIntervalSeconds} Seconds", () => controller.SeekBy(forward: false));
        var forward10 = Control("IconForward", $"Forward {controller.Preferences.SeekIntervalSeconds} Seconds", () => controller.SeekBy(forward: true));
        audio = Menu("IconAudioTracks", "Audio", AudioMenu);
        subtitles = Menu("IconSubtitles", "Subtitles", SubtitleMenu);
        speed = Menu("IconSpeed", "Playback Rate", SpeedMenu);
        sleep = Menu("IconSleep", "Sleep Timer", SleepMenu);
        notes = Control("IconNote", "Scene Notes", () => { });
        notes.Flyout = new Flyout { Content = sceneNotes.Editor(), Placement = PlacementMode.TopEdgeAlignedRight };
        mute = Control("IconVolume", "Mute (M)", () => controller.Muted = !controller.Muted);
        var fullScreen = Control("IconFullScreen", "Full Screen (F)", ToggleFullScreen);
        var close = Control("IconChevronLeft", "Back", () => _ = controller.CloseAsync());
        volume.Value = controller.Volume;
        volume.PropertyChanged += (_, e) =>
        {
            if (e.Property == RangeBase.ValueProperty) controller.Volume = volume.Value;
        };
        AutomationProperties.SetName(volume, "Volume");
        AutomationProperties.SetName(timeline, "Playback Position");
        timeline.PropertyChanged += (_, e) =>
        {
            if (e.Property == RangeBase.ValueProperty && !updatingTimeline && controller.Duration > 0)
                controller.SeekTo((long)(timeline.Value * controller.Duration));
        };
        timeline.PointerMoved += (_, e) => ShowPreview(e.GetPosition(timeline).X);
        timeline.PointerExited += (_, _) => previewBubble.IsVisible = false;
        timeline.AddHandler(PointerPressedEvent, (_, _) => draggingTimeline = true, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        timeline.AddHandler(PointerReleasedEvent, (_, _) => draggingTimeline = false, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        previewBubble.Child = new StackPanel { Spacing = 6, Children = { new Border { CornerRadius = new CornerRadius(8), ClipToBounds = true, Child = previewImage }, previewTime } };

        var top = new Border
        {
            VerticalAlignment = VerticalAlignment.Top,
            Padding = new Thickness(40, 64, 40, 40),
            Background = Shade(top: true),
            Child = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 16,
                Children = { close, new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 2, Children = { title, subtitle } } },
            },
        };
        var center = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 18, HorizontalAlignment = HorizontalAlignment.Center, Children = { previous, back10, playPause, forward10, next } };
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(16, 0, 0, 0), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Children = { speed, audio, subtitles, sleep, notes, mute, volume, fullScreen } };
        var bottom = new Border
        {
            VerticalAlignment = VerticalAlignment.Bottom,
            Padding = new Thickness(40, 50, 40, 30),
            Background = Shade(top: false),
            Child = new StackPanel
            {
                Spacing = 8,
                Children =
                {
                    new Panel { Children = { timeline, previewBubble } },
                    new DockPanel { Children = { elapsed.Also(t => DockPanel.SetDock(t, Dock.Left)), remaining.Also(t => DockPanel.SetDock(t, Dock.Right)), endsAt } },
                    new Grid
                    {
                        ColumnDefinitions = new ColumnDefinitions("*,Auto,*"),
                        Children = { center.Also(c => Grid.SetColumn(c, 1)), right.Also(r => Grid.SetColumn(r, 2)) },
                    },
                },
            },
        };
        var playNow = new Button { Content = "Play", Classes = { "primary" } };
        playNow.Click += (_, _) => _ = controller.NextAsync();
        var cancel = new Button { Content = "Cancel", Classes = { "chip" } };
        cancel.Click += (_, _) => controller.DismissUpNext();
        upNext.Child = new StackPanel
        {
            Spacing = 8,
            Children =
            {
                new TextBlock { Text = "UP NEXT", Classes = { "eyebrow" }, Foreground = new SolidColorBrush(Color.FromArgb(0xCC, 0xFF, 0xFF, 0xFF)) },
                upNextTitle,
                upNextCountdown,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { playNow, cancel } },
            },
        };
        var keep = new Button { Content = "Use This Computer's Position", Classes = { "chip" } };
        keep.Click += (_, _) => _ = controller.KeepThisPositionAsync();
        conflict.Child = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 12,
            Children = { new TextBlock { Text = "Another device saved a different position for this title.", VerticalAlignment = VerticalAlignment.Center, Foreground = Brushes.White }, keep },
        };
        status.Children.Add(spinner);
        status.Children.Add(statusText);
        status.Children.Add(statusActions);
        chrome.Children.Add(top);
        chrome.Children.Add(bottom);
        Content = new Grid { Children = { surface, noteCues, status, chrome, upNext, conflict } };

        controller.PropertyChanged += OnControllerChanged;
        sceneNotes.CuesChanged += ShowCues;
        PointerMoved += (_, _) => ShowControls();
        PointerPressed += (_, _) => ShowControls();
        KeyDown += OnKeyDown;
        AttachedToVisualTree += (_, _) =>
        {
            Focus();
            ShowControls();
            _ = sceneNotes.LoadAsync();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            controller.PropertyChanged -= OnControllerChanged;
            hideTimer?.Stop();
            Cursor = Cursor.Default;
        };
        AttachEngine();
        Update();
    }

    internal PlaybackController Controller => controller;

    public void Dispose() => surface.Dispose();

    internal bool ControlsVisible => chrome.IsVisible;

    private void OnControllerChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(PlaybackController.Engine)) AttachEngine();
        if (e.PropertyName is nameof(PlaybackController.Position)) sceneNotes.Advance(controller.Position);
        Update();
    }

    private void AttachEngine() => surface.Frames = (controller.Engine as VlcVideoEngine)?.Frames;

    private void Update()
    {
        title.Text = controller.Title;
        subtitle.Text = controller.Subtitle;
        var playing = controller.State == PlayerState.Playing;
        var icon = (PathIcon)playPause.Content!;
        icon.Data = Application.Current?.FindResource(playing ? "IconPause" : "IconPlay") as Geometry;
        AutomationProperties.SetName(playPause, playing ? "Pause" : "Play");
        ToolTip.SetTip(playPause, playing ? "Pause (Space)" : "Play (Space)");
        previous.IsVisible = controller.HasPrevious;
        next.IsVisible = controller.NextItem is not null;
        ((PathIcon)mute.Content!).Data = Application.Current?.FindResource(controller.Muted ? "IconMuted" : "IconVolume") as Geometry;
        AutomationProperties.SetName(mute, controller.Muted ? "Unmute (M)" : "Mute (M)");
        if (!draggingTimeline && controller.Duration > 0)
        {
            updatingTimeline = true;
            timeline.Value = Math.Clamp((double)controller.Position / controller.Duration, 0, 1);
            updatingTimeline = false;
        }
        elapsed.Text = PlayerPolicy.TimeLabel(controller.Position);
        remaining.Text = "-" + PlayerPolicy.TimeLabel(Math.Max(0, controller.Duration - controller.Position));
        endsAt.Text = PlayerPolicy.EndTimeLabel(controller.Position, controller.Duration, controller.Rate, DateTimeOffset.Now) ?? "";
        upNext.IsVisible = controller.UpNext is not null;
        if (controller.UpNext is { } upcoming)
        {
            upNextTitle.Text = upcoming.Kind == MediaKind.Episode ? $"S{upcoming.SeasonNumber} E{upcoming.EpisodeNumber} · {upcoming.Title}" : upcoming.Title;
            upNextCountdown.Text = $"Playing in {controller.UpNextSeconds} s";
        }
        conflict.IsVisible = controller.HasConflict;
        spinner.IsVisible = controller.State is PlayerState.Loading or PlayerState.Recovering;
        statusText.Text = controller.State switch
        {
            PlayerState.Recovering => "Reconnecting…",
            PlayerState.Failed => controller.Error ?? "Playback stopped.",
            _ => "",
        };
        statusText.IsVisible = statusText.Text.Length > 0;
        statusActions.Children.Clear();
        if (controller.State == PlayerState.Failed)
        {
            var back = new Button { Content = "Back", Classes = { "chip" } };
            back.Click += (_, _) => _ = controller.CloseAsync();
            var retry = new Button { Content = "Try Again", Classes = { "primary" } };
            retry.Click += (_, _) => _ = controller.RetryAsync();
            statusActions.Children.Add(back);
            statusActions.Children.Add(retry);
            ShowControls();
        }
        sleep.Classes.Set("active", controller.SleepTimer.IsOn);
        subtitles.Classes.Set("active", controller.SubtitleTrack >= 0);
    }

    private void OnKeyDown(object? sender, KeyEventArgs e)
    {
        ShowControls();
        var handled = true;
        switch (e.Key)
        {
            case Key.Space:
                controller.PlayPause();
                break;
            case Key.Left when e.KeyModifiers == KeyModifiers.None:
                controller.SeekBy(forward: false);
                break;
            case Key.Right when e.KeyModifiers == KeyModifiers.None:
                controller.SeekBy(forward: true);
                break;
            case Key.M:
                controller.Muted = !controller.Muted;
                break;
            case Key.F:
                ToggleFullScreen();
                break;
            case Key.P:
                _ = controller.PreviousAsync();
                break;
            case Key.N:
                _ = controller.NextAsync();
                break;
            case Key.Left when e.KeyModifiers == (KeyModifiers.Shift | KeyModifiers.Control):
                _ = controller.PreviousAsync();
                break;
            case Key.Right when e.KeyModifiers == (KeyModifiers.Shift | KeyModifiers.Control):
                _ = controller.NextAsync();
                break;
            case Key.Escape:
                if (window?.WindowState == WindowState.FullScreen) window.WindowState = WindowState.Normal;
                else _ = controller.CloseAsync();
                break;
            default:
                handled = false;
                break;
        }
        e.Handled = handled;
    }

    private void ToggleFullScreen()
    {
        if (window is null) return;
        window.WindowState = window.WindowState == WindowState.FullScreen ? WindowState.Normal : WindowState.FullScreen;
    }

    /// <summary>Shows the controls and the pointer; they hide again after the chosen delay while playing.</summary>
    private void ShowControls()
    {
        chrome.IsVisible = true;
        Cursor = Cursor.Default;
        hideTimer?.Stop();
        hideTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(controller.Preferences.ControlsHideDelaySeconds) };
        hideTimer.Tick += (_, _) =>
        {
            hideTimer?.Stop();
            var menuOpen = this.GetVisualDescendantsOfType<Popup>().Any(p => p.IsOpen) || draggingTimeline;
            if (controller.State == PlayerState.Playing && !menuOpen && !IsPointerOverControls())
            {
                chrome.IsVisible = false;
                Cursor = new Cursor(StandardCursorType.None);
            }
        };
        hideTimer.Start();
    }

    private bool IsPointerOverControls() => chrome.Children.OfType<Control>().Any(child => child.IsPointerOver && child.VerticalAlignment == VerticalAlignment.Bottom && child.IsPointerOver);

    private async void ShowPreview(double x)
    {
        if (controller.Duration <= 0 || timeline.Bounds.Width <= 0) return;
        var fraction = Math.Clamp(x / timeline.Bounds.Width, 0, 1);
        var at = (long)(fraction * controller.Duration);
        previewTime.Text = PlayerPolicy.TimeLabel(at);
        previewBubble.Margin = new Thickness(Math.Clamp(x - 128, 0, Math.Max(0, timeline.Bounds.Width - 256)), 0, 0, 36);
        previewBubble.IsVisible = true;
        var picture = await previews.GetAsync(at);
        if (picture is not null && previewTime.Text == PlayerPolicy.TimeLabel(at)) previewImage.Source = picture;
        previewImage.IsVisible = previewImage.Source is not null;
    }

    private void ShowCues(IReadOnlyList<string> texts)
    {
        noteCues.Children.Clear();
        foreach (var text in texts)
        {
            noteCues.Children.Add(new Border
            {
                Classes = { "banner" },
                MaxWidth = 420,
                Child = new TextBlock { Text = text, Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap },
            });
        }
    }

    private List<Control> SpeedMenu() =>
        [.. PlayerPolicy.Rates.Select(rate => Choice(rate == 1 ? "Standard" : rate.ToString("0.##", System.Globalization.CultureInfo.InvariantCulture) + "×",
            controller.Rate == rate, () => controller.Rate = rate))];

    private List<Control> AudioMenu()
    {
        var items = new List<Control>();
        if (controller.AudioTracks.Count == 0) items.Add(new MenuItem { Header = "No audio tracks available", IsEnabled = false });
        foreach (var track in controller.AudioTracks) items.Add(Choice(track.Name, controller.AudioTrack == track.Id, () => controller.SelectAudio(track)));
        items.Add(new Separator());
        items.Add(Choice("Night Mode", controller.Preferences.NightMode, () => _ = controller.SetNightModeAsync(!controller.Preferences.NightMode)));
        return items;
    }

    private List<Control> SubtitleMenu()
    {
        var items = new List<Control> { Choice("Off", controller.SubtitleTrack < 0, () => controller.SelectSubtitle(null)) };
        foreach (var track in controller.SubtitleTracks) items.Add(Choice(track.Name, controller.SubtitleTrack == track.Id, () => controller.SelectSubtitle(track)));
        return items;
    }

    private List<Control> SleepMenu()
    {
        var current = controller.SleepTimer;
        var items = new List<Control>
        {
            Choice("Off", !current.IsOn, () => controller.SetSleepTimer(SleepTimer.Off)),
            Choice("At End of Episode", current.EndOfEpisode, () => controller.SetSleepTimer(SleepTimer.AtEndOfEpisode)),
        };
        foreach (var minutes in SleepTimer.Choices)
            items.Add(Choice(minutes < 60 ? $"In {minutes} Minutes" : minutes % 60 == 0 ? $"In {minutes / 60} Hour{(minutes == 60 ? "" : "s")}" : $"In {minutes} Minutes",
                current.Minutes == minutes, () => controller.SetSleepTimer(new SleepTimer(minutes, false))));
        return items;
    }

    private static MenuItem Choice(string header, bool selected, Action action)
    {
        var item = new MenuItem { Header = header, ToggleType = MenuItemToggleType.Radio, IsChecked = selected };
        item.Click += (_, _) => action();
        return item;
    }

    private static Button Menu(string icon, string label, Func<List<Control>> items)
    {
        var button = Control(icon, label, () => { });
        var flyout = new MenuFlyout { Placement = PlacementMode.TopEdgeAlignedRight };
        flyout.Opening += (_, _) => flyout.ItemsSource = items();
        button.Flyout = flyout;
        return button;
    }

    private static Button Control(string icon, string label, Action action, bool large = false)
    {
        var size = large ? 30 : 18;
        var button = new Button
        {
            Classes = { large ? "playerPrimary" : "playerControl" },
            Content = new PathIcon { Data = Application.Current?.FindResource(icon) as Geometry, Width = size, Height = size },
        };
        AutomationProperties.SetName(button, label);
        ToolTip.SetTip(button, label);
        button.Click += (_, _) => action();
        return button;
    }

    private static LinearGradientBrush Shade(bool top) => new()
    {
        StartPoint = new RelativePoint(0.5, top ? 0 : 1, RelativeUnit.Relative),
        EndPoint = new RelativePoint(0.5, top ? 1 : 0, RelativeUnit.Relative),
        GradientStops = { new GradientStop(Color.FromArgb(0xB3, 0, 0, 0), 0), new GradientStop(Color.FromArgb(0, 0, 0, 0), 1) },
    };
}
