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
using Avalonia.Platform.Storage;
using Avalonia.Threading;

namespace Aurelia.Linux.Playback;

/// <summary>
/// The player, laid out like the Mac app's: the picture full window under a soft shade; at the
/// top the Back button and one capsule with the playback rate, audio (with Dialogue Boost and
/// Volume Leveling), subtitles, sleep timer and scene notes; the play controls in a capsule in
/// the middle; at the bottom the title, a capsule with chapters, volume, Fill Screen and full
/// screen, and the timeline with preview pictures. Controls hide after the chosen delay while
/// playing and return with the pointer or a key. The picture fills the window without black
/// bars.
/// </summary>
public sealed class PlayerView : UserControl, IDisposable
{
    private static readonly IBrush Secondary = new SolidColorBrush(Color.FromArgb(0xAD, 0xFF, 0xFF, 0xFF));
    private readonly PlaybackController controller;
    private readonly Window? window;

    /// <summary>The library's artwork store, for the suggestions' posters; without it they show titles only.</summary>
    public Aurelia.Linux.Core.Library.LibraryStore? Store { get; init; }
    private readonly VideoSurface surface = new();
    private readonly Grid chrome = new();
    private readonly TextBlock title = new() { FontSize = 20, FontWeight = FontWeight.SemiBold, Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap, MaxLines = 2, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock subtitle = new() { FontSize = 12, FontWeight = FontWeight.SemiBold, Foreground = Secondary, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly Slider timeline = new() { Minimum = 0, Maximum = 1, Classes = { "timeline" } };
    private readonly TextBlock elapsed = new() { Classes = { "playerTime" }, MinWidth = 48, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock total = new() { Classes = { "playerTime" }, MinWidth = 48, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock endsAt = new() { Classes = { "playerTime" }, FontSize = 11, Foreground = new SolidColorBrush(Color.FromArgb(0x9E, 0xFF, 0xFF, 0xFF)), HorizontalAlignment = HorizontalAlignment.Right };
    private readonly Button playPause;
    private readonly Button previous;
    private readonly Button next;
    private readonly Button audio;
    private readonly Button subtitles;
    private readonly Button speed;
    private readonly TextBlock speedLabel = new() { FontSize = 14, FontWeight = FontWeight.Bold, FontFeatures = FontFeatureCollection.Parse("+tnum"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button sleep;
    private readonly Button notes;
    private readonly Button chapters;
    private readonly Canvas chapterMarkers = new() { IsHitTestVisible = false };
    private readonly Canvas previewLayer = new() { IsHitTestVisible = false, ClipToBounds = false };
    private readonly Button mute;
    private readonly Button fullScreen;
    private readonly Slider volume = new() { Minimum = 0, Maximum = 1, Width = 96, VerticalAlignment = VerticalAlignment.Center, Classes = { "volume" } };
    private readonly Border top;
    private readonly Border transport;
    private readonly StackPanel bottom;
    private readonly Border upNext = new() { Classes = { "upNext" }, IsVisible = false, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Width = 340 };
    private readonly TextBlock upNextTitle = new() { FontSize = 18, FontWeight = FontWeight.SemiBold, Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap, MaxLines = 2, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock upNextCountdown = new() { Foreground = Secondary };
    private readonly Button upNextSecond = new() { Content = "Cancel", Classes = { "chip" } };
    /// <summary>After a movie or a series' last episode: the server's suggestion from the credits on, without a countdown.</summary>
    private readonly Border suggestionCard = new() { Classes = { "upNext" }, IsVisible = false, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Width = 420 };
    /// <summary>When the file ended: the suggestion and two more.</summary>
    private readonly Border endScreen = new() { Background = new SolidColorBrush(Color.FromArgb(0xC8, 0, 0, 0)), IsVisible = false };
    private Guid? shownSuggestion;
    private bool endScreenBuilt;
    /// <summary>Screen time is over (docs/SCREEN_TIME.md): a calm moon, the profile's name and when Aurelia opens.</summary>
    private readonly Border goodNight = new()
    {
        IsVisible = false,
        Background = new RadialGradientBrush
        {
            GradientStops = { new GradientStop(Color.FromArgb(0xF0, 0x28, 0x34, 0x60), 0), new GradientStop(Color.FromArgb(0xF6, 0x04, 0x06, 0x10), 1) },
        },
    };
    private bool goodNightBuilt;
    /// <summary>The quiet "last episode" note while the last title of the day plays.</summary>
    private readonly Border lastTitle = new() { Classes = { "playerMaterial", "playerPill" }, IsVisible = false, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 96, 0, 0), IsHitTestVisible = false };
    private readonly TextBlock lastTitleText = new() { Foreground = Brushes.White, FontSize = 13 };
    /// <summary>"Skip Intro" while an episode's intro plays; it stays when the controls hide.</summary>
    private readonly Button skipIntro = new() { Classes = { "skipIntro" }, IsVisible = false, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom };
    private readonly Border status = new() { Classes = { "playerMaterial", "playerPanel" }, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock statusText = new() { Foreground = Brushes.White, FontSize = 15, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 480 };
    private readonly StackPanel statusActions = new() { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly Aurelia.Linux.Controls.Spinner spinner = new(40);
    private readonly Border conflict = new() { Classes = { "playerMaterial", "playerPill" }, IsVisible = false, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom };
    private readonly Border previewBubble = new() { Classes = { "previewBubble" }, IsVisible = false, VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly Image previewImage = new() { Width = 240, Height = 135, Stretch = Stretch.UniformToFill };
    private readonly TextBlock previewTime = new() { Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, FontWeight = FontWeight.SemiBold };
    private readonly StackPanel noteCues = new() { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top };
    private readonly ScrubPreviews previews;
    private readonly SceneNotes sceneNotes;
    private DispatcherTimer? hideTimer;
    // Menus open in their own popup surfaces outside this view, so the view counts them itself:
    // while one is open the controls stay, and closing it starts the hide delay anew.
    private int openMenus;
    private bool draggingTimeline;
    private bool updatingTimeline;
    private bool exportingDiagnostics;

    internal Func<Task<Stream?>>? DiagnosticsDestination { get; set; }

    private readonly IWatchTogetherHost? together;
    private readonly Border togetherNotice = new()
    {
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Top,
        Margin = new Thickness(0, 90, 0, 0),
        Padding = new Thickness(14, 8),
        CornerRadius = new CornerRadius(18),
        Background = new SolidColorBrush(Color.FromArgb(0xCC, 0x1C, 0x1E, 0x22)),
        IsVisible = false,
        IsHitTestVisible = false,
    };

    public PlayerView(PlaybackController controller, Window? window, IWatchTogetherHost? together = null)
    {
        this.controller = controller;
        this.window = window;
        this.together = together;
        Focusable = true;
        Background = Brushes.Black;
        var diagnostics = new MenuItem { Header = "Export Playback Diagnostics…" };
        diagnostics.Click += async (_, _) => await ExportDiagnosticsAsync();
        ContextMenu = new ContextMenu { Items = { diagnostics } };
        previews = new ScrubPreviews(controller);
        sceneNotes = new SceneNotes(controller);

        // Top: Back on the left, the track and timer menus in one capsule on the right.
        var close = Control("IconChevronLeft", "Back", () => _ = controller.CloseAsync(), size: 18);
        close.Classes.Add("playerMaterial");
        speed = Menu("IconSpeed", "Playback Rate", SpeedMenu, PlacementMode.BottomEdgeAlignedRight);
        speed.Content = speedLabel;
        speed.MinWidth = 44;
        speed.Width = double.NaN;
        speed.Padding = new Thickness(8, 0);
        audio = Menu("IconAudioTracks", "Audio", AudioMenu, PlacementMode.BottomEdgeAlignedRight);
        subtitles = Menu("IconSubtitles", "Subtitles", SubtitleMenu, PlacementMode.BottomEdgeAlignedRight);
        sleep = Menu("IconSleep", "Sleep Timer", SleepMenu, PlacementMode.BottomEdgeAlignedRight);
        notes = Control("IconNote", "Scene Notes", () => { });
        notes.Flyout = new Flyout { Content = sceneNotes.Editor(), Placement = PlacementMode.BottomEdgeAlignedRight };
        Track(notes.Flyout);
        top = new Border
        {
            VerticalAlignment = VerticalAlignment.Top,
            Child = new DockPanel
            {
                LastChildFill = false,
                Children =
                {
                    close.Also(c => DockPanel.SetDock(c, Dock.Left)),
                    (together is null ? Capsule(speed, audio, subtitles, sleep, notes) : Capsule(speed, audio, subtitles, sleep, notes, TogetherButton()))
                        .Also(c => DockPanel.SetDock(c, Dock.Right)),
                },
            },
        };

        // Middle: previous, back, play, forward, next, as on the Mac.
        playPause = Control("IconPause", "Pause", controller.PlayPause, size: 22);
        playPause.Classes.Remove("playerControl");
        playPause.Classes.Add("playerPrimary");
        previous = Control("IconPreviousTrack", "Previous Episode (P)", () => _ = controller.PreviousAsync());
        next = Control("IconNextTrack", "Next Episode (N)", () => _ = controller.NextAsync());
        var back10 = Control("IconBackward", $"Back {controller.Preferences.SeekIntervalSeconds} Seconds", () => controller.SeekBy(forward: false), size: 22);
        var forward10 = Control("IconForward", $"Forward {controller.Preferences.SeekIntervalSeconds} Seconds", () => controller.SeekBy(forward: true), size: 22);
        // A circling arrow with the seconds in it, like the Mac's skip buttons.
        back10.Content = SkipSymbol(forward: false, controller.Preferences.SeekIntervalSeconds);
        forward10.Content = SkipSymbol(forward: true, controller.Preferences.SeekIntervalSeconds);
        transport = Capsule(previous, back10, playPause, forward10, next);
        transport.HorizontalAlignment = HorizontalAlignment.Center;
        transport.VerticalAlignment = VerticalAlignment.Center;
        transport.Padding = new Thickness(6);

        // Bottom: title and the trailing capsule, then the timeline, then when it ends.
        chapters = Menu("IconChapters", "Chapters", ChapterMenu, PlacementMode.TopEdgeAlignedRight);
        chapterMarkers.SizeChanged += (_, _) => DrawChapterMarkers();
        mute = Control("IconVolume", "Mute (M)", () => controller.Muted = !controller.Muted);
        fullScreen = Control("IconFullScreen", "Full Screen (F)", ToggleFullScreen);
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
        previewLayer.Children.Add(previewBubble);
        var trailing = Capsule(chapters, mute, volume, fullScreen);
        trailing.Padding = new Thickness(6, 4);
        trailing.VerticalAlignment = VerticalAlignment.Bottom;
        bottom = new StackPanel
        {
            VerticalAlignment = VerticalAlignment.Bottom,
            Spacing = 9,
            Children =
            {
                new Grid
                {
                    ColumnDefinitions = new ColumnDefinitions("*,Auto"),
                    Children =
                    {
                        new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 30, 0), Children = { subtitle, title } },
                        trailing.Also(t => Grid.SetColumn(t, 1)),
                    },
                },
                new Grid
                {
                    ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"),
                    ColumnSpacing = 10,
                    Children =
                    {
                        elapsed,
                        // The preview floats above the timeline on a canvas, so showing it never
                        // changes the timeline's height (it made the bar jump and hid the markers).
                        new Panel { Children = { timeline, chapterMarkers, previewLayer } }.Also(p => Grid.SetColumn(p, 1)),
                        total.Also(t => Grid.SetColumn(t, 2)),
                    },
                },
                endsAt,
            },
        };

        var playNow = new Button { Content = "Play Now", Classes = { "primary" } };
        playNow.Click += (_, _) => _ = controller.NextAsync();
        ToolTip.SetTip(playNow, "Starts the next episode now");
        var cancel = upNextSecond;
        cancel.Click += (_, _) => controller.DismissUpNext();
        skipIntro.Content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 12,
            Children =
            {
                new PathIcon { Data = Application.Current?.FindResource("IconNextTrack") as Geometry, Width = 16, Height = 16, Foreground = Brushes.White },
                new TextBlock { Text = "Skip Intro", FontSize = 18, FontWeight = FontWeight.SemiBold, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center },
                // The key that skips without the mouse (S works too).
                new Border
                {
                    BorderBrush = Secondary, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(5), Padding = new Thickness(7, 2),
                    VerticalAlignment = VerticalAlignment.Center,
                    Child = new TextBlock { Text = "↵ Enter", FontSize = 11, FontWeight = FontWeight.SemiBold, Foreground = Secondary },
                },
            },
        };
        AutomationProperties.SetName(skipIntro, "Skip Intro");
        AutomationProperties.SetHelpText(skipIntro, "Jumps to the end of the intro. Enter or S does the same.");
        ToolTip.SetTip(skipIntro, "Jumps to the end of the intro. Enter or S does the same.");
        skipIntro.Click += (_, _) => controller.SkipIntro();
        upNext.Child = new StackPanel
        {
            Spacing = 10,
            Children =
            {
                new TextBlock { Text = "UP NEXT", Classes = { "eyebrow" }, Foreground = Secondary },
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
            Children = { new TextBlock { Text = "Another device saved a different position for this title.", VerticalAlignment = VerticalAlignment.Center, Foreground = Brushes.White, FontSize = 12 }, keep },
        };
        status.Child = new StackPanel { Spacing = 14, Children = { spinner, statusText, statusActions } };
        chrome.Children.Add(new Border { Background = Shade(), IsHitTestVisible = false });
        chrome.Children.Add(top);
        chrome.Children.Add(transport);
        chrome.Children.Add(bottom);
        chrome.Children.Add(conflict);
        lastTitle.Child = lastTitleText;
        Content = new Grid { Children = { surface, chrome, status, skipIntro, upNext, suggestionCard, endScreen, lastTitle, goodNight, noteCues, togetherNotice } };
        if (together is not null) together.WatchPartyChanged += ShowTogetherNotice;

        controller.PropertyChanged += OnControllerChanged;
        sceneNotes.CuesChanged += ShowCues;
        PointerMoved += (_, _) => ShowControls();
        PointerPressed += (_, _) => ShowControls();
        KeyDown += OnKeyDown;
        if (window is not null) window.PropertyChanged += OnWindowChanged;
        AttachedToVisualTree += (_, _) =>
        {
            Focus();
            ShowControls();
            _ = sceneNotes.LoadAsync();
        };
        DetachedFromVisualTree += (_, _) =>
        {
            controller.PropertyChanged -= OnControllerChanged;
            if (window is not null) window.PropertyChanged -= OnWindowChanged;
            hideTimer?.Stop();
            Cursor = Cursor.Default;
        };
        AttachEngine();
        Layout();
        Update();
    }

    internal PlaybackController Controller => controller;

    internal bool FillsScreen => surface.Fills;

    public void Dispose()
    {
        if (together is not null) together.WatchPartyChanged -= ShowTogetherNotice;
        controller.PropertyChanged -= OnControllerChanged;
        if (window is not null) window.PropertyChanged -= OnWindowChanged;
        sceneNotes.CuesChanged -= ShowCues;
        hideTimer?.Stop();
        previewImage.Source = null;
        previews.Dispose();
        surface.Dispose();
    }

    internal bool ControlsVisible => chrome.IsVisible;

    /// <summary>Whether a player menu is open; the controls stay while it is.</summary>
    internal bool HasOpenMenu => openMenus > 0;

    private bool IsFullScreen => window?.WindowState == WindowState.FullScreen;

    private void OnWindowChanged(object? sender, AvaloniaPropertyChangedEventArgs e)
    {
        if (e.Property == Window.WindowStateProperty) Layout();
    }

    /// <summary>The Mac's spacing: closer to the edges in full screen, clear of the window buttons otherwise.</summary>
    private void Layout()
    {
        var fullScreen = IsFullScreen;
        top.Margin = new Thickness(36, fullScreen ? 16 : 46, 36, 0);
        bottom.Margin = new Thickness(48, 0, 48, fullScreen ? 34 : 24);
        conflict.Margin = new Thickness(48, 0, 48, fullScreen ? 176 : 166);
        ((PathIcon)this.fullScreen.Content!).Data = Application.Current?.FindResource("IconFullScreen") as Geometry;
        AutomationProperties.SetName(this.fullScreen, "Full Screen (F)");
        ToolTip.SetTip(this.fullScreen, fullScreen ? "Exit Full Screen (F)" : "Full Screen (F)");
        PlaceOverlays();
    }

    private void PlaceOverlays()
    {
        var visible = chrome.IsVisible;
        // Skip Intro and Up Next sit above the bottom controls while they show, never on them.
        upNext.Margin = new Thickness(0, 0, 48, visible ? 200 : 40);
        suggestionCard.Margin = new Thickness(0, 0, 48, visible ? 200 : 40);
        skipIntro.Margin = new Thickness(0, 0, 48, visible ? 200 : 40);
        noteCues.Margin = new Thickness(0, visible ? 104 : 32, 26, 0);
    }

    private void OnControllerChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(PlaybackController.Engine)) AttachEngine();
        if (e.PropertyName is nameof(PlaybackController.Chapters) or nameof(PlaybackController.Duration)) DrawChapterMarkers();
        if (e.PropertyName == nameof(PlaybackController.Item))
        {
            previewImage.Source = null;
            previewBubble.IsVisible = false;
            previews.Reset();
        }
        if (e.PropertyName is nameof(PlaybackController.Position)) sceneNotes.Advance(controller.Position);
        Update();
    }

    private void AttachEngine() => surface.Frames = (controller.Engine as VlcVideoEngine)?.Frames;

    private void Update()
    {
        title.Text = controller.Title;
        subtitle.Text = string.IsNullOrWhiteSpace(controller.Subtitle) ? "NOW PLAYING" : controller.Subtitle.ToUpperInvariant();
        var playing = controller.State == PlayerState.Playing;
        var icon = (PathIcon)playPause.Content!;
        icon.Data = Application.Current?.FindResource(playing ? "IconPause" : "IconPlay") as Geometry;
        AutomationProperties.SetName(playPause, playing ? "Pause" : "Play");
        ToolTip.SetTip(playPause, playing ? "Pause (Space)" : "Play (Space)");
        previous.IsEnabled = controller.HasPrevious;
        next.IsEnabled = controller.NextItem is not null;
        chapters.IsVisible = controller.Chapters.Count > 0;
        speedLabel.Text = RateLabel(controller.Rate);
        ((PathIcon)mute.Content!).Data = Application.Current?.FindResource(controller.Muted ? "IconMuted" : "IconVolume") as Geometry;
        AutomationProperties.SetName(mute, controller.Muted ? "Unmute (M)" : "Mute (M)");
        // The picture always fills the window, without black bars (owner's decision, 07.11.2026).
        surface.Fills = true;
        if (!draggingTimeline && controller.Duration > 0)
        {
            updatingTimeline = true;
            timeline.Value = Math.Clamp((double)controller.Position / controller.Duration, 0, 1);
            updatingTimeline = false;
        }
        elapsed.Text = PlayerPolicy.TimeLabel(controller.Position);
        total.Text = PlayerPolicy.TimeLabel(controller.Duration);
        endsAt.Text = PlayerPolicy.EndTimeLabel(controller.Position, controller.Duration, controller.Rate, DateTimeOffset.Now) ?? "";
        endsAt.IsVisible = endsAt.Text.Length > 0;
        upNext.IsVisible = controller.UpNext is not null;
        if (controller.UpNext is { } upcoming)
        {
            upNextTitle.Text = upcoming.Kind == MediaKind.Episode ? $"S{upcoming.SeasonNumber} E{upcoming.EpisodeNumber} · {upcoming.Title}" : upcoming.Title;
            upNextCountdown.Text = $"Playing in {controller.UpNextSeconds} s";
            var credits = controller.UpNextDuringCredits;
            upNextSecond.Content = credits ? "Watch Credits" : "Cancel";
            ToolTip.SetTip(upNextSecond, credits
                ? "Hides this card and keeps playing the credits; the next episode still follows at the end"
                : "Stops at the end instead of playing the next episode");
        }
        UpdateSuggestions();
        skipIntro.IsVisible = controller.ShowsSkipIntro && controller.UpNext is null && !suggestionCard.IsVisible;
        conflict.IsVisible = controller.HasConflict;
        var preparing = controller.State is PlayerState.Loading or PlayerState.Recovering;
        var failed = controller.State == PlayerState.Failed;
        transport.IsVisible = !preparing && !failed;
        spinner.IsVisible = preparing;
        statusText.Text = controller.State switch
        {
            PlayerState.Loading => "Preparing playback…",
            PlayerState.Recovering => "Reconnecting…",
            PlayerState.Failed => controller.Error ?? "Playback stopped.",
            _ => "",
        };
        statusText.IsVisible = statusText.Text.Length > 0;
        status.IsVisible = preparing || failed || statusText.IsVisible;
        statusActions.Children.Clear();
        if (failed)
        {
            var back = new Button { Content = "Back", Classes = { "chip" } };
            back.Click += (_, _) => _ = controller.CloseAsync();
            var retry = new Button { Content = "Try Again", Classes = { "primary" } };
            retry.Click += (_, _) => _ = controller.RetryAsync();
            statusActions.Children.Add(back);
            statusActions.Children.Add(retry);
            var diagnostics = new Button { Content = "Export Playback Diagnostics…", Classes = { "chip" } };
            diagnostics.Click += async (_, _) => await ExportDiagnosticsAsync();
            statusActions.Children.Add(diagnostics);
            ShowControls();
        }
        statusActions.IsVisible = statusActions.Children.Count > 0;
        sleep.Classes.Set("active", controller.SleepTimer.IsOn);
        subtitles.Classes.Set("active", controller.SubtitleTracks.Any(track => track.Id == controller.SubtitleTrack));
    }

    private void UpdateSuggestions()
    {
        var first = controller.Suggestions.Count > 0 ? controller.Suggestions[0] : null;
        suggestionCard.IsVisible = controller.ShowsSuggestion && first is not null;
        if (suggestionCard.IsVisible && first is not null && shownSuggestion != first.Item.Id)
        {
            shownSuggestion = first.Item.Id;
            var watch = new Button { Content = "Watch Now", Classes = { "primary" } };
            watch.Click += (_, _) => _ = controller.PlaySuggestionAsync(first.Item);
            ToolTip.SetTip(watch, $"Starts {first.Item.Title}; this title counts as watched");
            var credits = new Button { Content = "Watch Credits", Classes = { "chip" } };
            credits.Click += (_, _) => controller.DismissSuggestion();
            ToolTip.SetTip(credits, "Hides the suggestion and plays the credits to the end");
            var done = new Button { Content = "Done", Classes = { "chip" } };
            done.Click += (_, _) => _ = controller.DoneAsync();
            ToolTip.SetTip(done, "Closes the player; this title counts as watched");
            var text = new StackPanel
            {
                Spacing = 4,
                Children =
                {
                    new TextBlock { Text = first.Item.Title, FontSize = 18, FontWeight = FontWeight.SemiBold, Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap, MaxLines = 2, TextTrimming = TextTrimming.CharacterEllipsis },
                    new TextBlock { Text = PlayerPolicy.SuggestionCaption(first), Foreground = Secondary, TextWrapping = TextWrapping.Wrap, MaxLines = 2 },
                },
            };
            suggestionCard.Child = new StackPanel
            {
                Spacing = 10,
                Children =
                {
                    new TextBlock { Text = "UP NEXT", Classes = { "eyebrow" }, Foreground = Secondary },
                    Store is null ? text : new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Children = { Poster(first.Item, 54), text } },
                    new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { watch, credits, done } },
                },
            };
        }
        endScreen.IsVisible = controller.ShowsEndScreen && controller.Suggestions.Count > 0;
        if (endScreen.IsVisible && !endScreenBuilt)
        {
            endScreenBuilt = true;
            var items = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Center };
            foreach (var (suggestion, index) in controller.Suggestions.Take(3).Select((entry, index) => (entry, index)))
            {
                var width = index == 0 ? 200 : 150;
                var watch = new Button { Content = "Watch Now", Classes = { index == 0 ? "primary" : "chip" } };
                watch.Click += (_, _) => _ = controller.PlaySuggestionAsync(suggestion.Item);
                AutomationProperties.SetName(watch, $"Watch {suggestion.Item.Title} Now");
                var column = new StackPanel { Width = width, Spacing = 8, Margin = new Thickness(14) };
                if (Store is not null) column.Children.Add(Poster(suggestion.Item, width));
                column.Children.Add(new TextBlock { Text = suggestion.Item.Title, FontSize = index == 0 ? 18 : 15, FontWeight = FontWeight.SemiBold, Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap, MaxLines = 2 });
                column.Children.Add(new TextBlock { Text = PlayerPolicy.SuggestionCaption(suggestion), Foreground = Secondary, TextWrapping = TextWrapping.Wrap, MaxLines = 2 });
                column.Children.Add(watch);
                items.Children.Add(column);
            }
            var done = new Button { Content = "Done", Classes = { "chip" }, HorizontalAlignment = HorizontalAlignment.Center };
            done.Click += (_, _) => _ = controller.DoneAsync();
            endScreen.Child = new ScrollViewer
            {
                Content = new StackPanel
                {
                    Spacing = 18,
                    Margin = new Thickness(16),
                    VerticalAlignment = VerticalAlignment.Center,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Children =
                    {
                        new TextBlock { Text = "What's Next", FontSize = 32, FontWeight = FontWeight.Bold, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center },
                        items,
                        done,
                    },
                },
            };
        }
        if (!endScreen.IsVisible) endScreenBuilt = false;
        UpdateGoodNight();
    }

    private void UpdateGoodNight()
    {
        lastTitleText.Text = controller.LastTitleNote ?? "";
        lastTitle.IsVisible = controller.LastTitleNote is not null && chrome.IsVisible;
        goodNight.IsVisible = controller.ShowsGoodNight;
        if (!goodNight.IsVisible || goodNightBuilt) return;
        goodNightBuilt = true;
        var words = ScreenTimeText.GoodNight(controller.ScreenTime, Aurelia.Linux.Core.ProfileVisuals.ShownName(controller.Client.Library.Profile.User));
        var done = new Button { Content = "Done", Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 0) };
        done.Click += (_, _) => _ = controller.CloseAsync();
        AutomationProperties.SetName(goodNight, words.Title);
        goodNight.Child = new StackPanel
        {
            Spacing = 16,
            Margin = new Thickness(16),
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
            Children =
            {
                new PathIcon { Data = Application.Current?.FindResource("IconSleep") as Geometry, Width = 80, Height = 80, Foreground = new SolidColorBrush(Color.FromRgb(0xF3, 0xE3, 0xA8)), HorizontalAlignment = HorizontalAlignment.Center },
                new TextBlock { Text = words.Title, FontSize = 32, FontWeight = FontWeight.Bold, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center },
                new TextBlock { Text = words.Text, FontSize = 18, Foreground = Secondary, HorizontalAlignment = HorizontalAlignment.Center },
                done,
            },
        };
        done.AttachedToVisualTree += (_, _) => done.Focus();
    }

    private Border Poster(CatalogItemSummary item, double width) => new()
    {
        Width = width,
        Height = width * 1.5,
        CornerRadius = new CornerRadius(8),
        ClipToBounds = true,
        Child = new ArtworkImage(Store, item.Poster, width),
    };

    private static string RateLabel(double rate) => rate.ToString("0.##", System.Globalization.CultureInfo.InvariantCulture) + "×";

    private void OnKeyDown(object? sender, KeyEventArgs e)
    {
        ShowControls();
        var handled = true;
        // Enter or S skips the intro while Skip Intro is offered.
        if (controller.ShowsSkipIntro && e.KeyModifiers == KeyModifiers.None && e.Key is Key.Enter or Key.Return or Key.S)
        {
            controller.SkipIntro();
            e.Handled = true;
            return;
        }
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
        PlaceOverlays();
        Cursor = Cursor.Default;
        hideTimer?.Stop();
        hideTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(controller.Preferences.ControlsHideDelaySeconds) };
        hideTimer.Tick += (_, _) =>
        {
            hideTimer?.Stop();
            var menuOpen = openMenus > 0 || this.GetVisualDescendantsOfType<Popup>().Any(p => p.IsOpen) || draggingTimeline || exportingDiagnostics || ContextMenu?.IsOpen == true;
            if (controller.State == PlayerState.Playing && !menuOpen && !IsPointerOverControls())
            {
                chrome.IsVisible = false;
                PlaceOverlays();
                Cursor = new Cursor(StandardCursorType.None);
            }
        };
        hideTimer.Start();
    }

    private bool IsPointerOverControls() => top.IsPointerOver || transport.IsPointerOver || bottom.IsPointerOver || conflict.IsPointerOver;

    internal async Task ExportDiagnosticsAsync()
    {
        if (exportingDiagnostics) return;
        exportingDiagnostics = true;
        ShowControls();
        try
        {
            Stream? output = null;
            if (DiagnosticsDestination is { } destination) output = await destination();
            else if (TopLevel.GetTopLevel(this)?.StorageProvider is { } storage)
            {
                var file = await storage.SaveFilePickerAsync(new FilePickerSaveOptions
                {
                    Title = "Export Playback Diagnostics",
                    SuggestedFileName = "Aurelia Playback Diagnostics.json",
                    DefaultExtension = "json",
                    FileTypeChoices = [new FilePickerFileType("JSON") { Patterns = ["*.json"] }],
                });
                if (file is not null) output = await file.OpenWriteAsync();
            }
            if (output is null) return;
            await using (output)
            {
                if (output.CanSeek) output.SetLength(0);
                await output.WriteAsync(controller.Diagnostics.Export());
                await output.FlushAsync();
            }
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException)
        {
            statusText.Text = "Diagnostics could not be exported. Choose another location and try again.";
            statusText.IsVisible = true;
        }
        finally
        {
            exportingDiagnostics = false;
            ShowControls();
        }
    }

    private async void ShowPreview(double x)
    {
        if (controller.Duration <= 0 || timeline.Bounds.Width <= 0) return;
        var fraction = Math.Clamp(x / timeline.Bounds.Width, 0, 1);
        var at = (long)(fraction * controller.Duration);
        previewTime.Text = PlayerPolicy.TimeLabel(at);
        Canvas.SetLeft(previewBubble, Math.Clamp(x - 128, 0, Math.Max(0, timeline.Bounds.Width - 256)));
        Canvas.SetBottom(previewBubble, timeline.Bounds.Height / 2 + 14);
        previewBubble.IsVisible = true;
        // The cache may evict or reset its old bitmap while the next frame is awaited.
        previewImage.Source = null;
        var picture = await previews.GetAsync(at);
        if (previewTime.Text == PlayerPolicy.TimeLabel(at)) previewImage.Source = picture;
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

    private List<Control> ChapterMenu() =>
        [.. controller.Chapters.Select(chapter => Choice(chapter.Title + "  " + PlayerPolicy.TimeLabel(chapter.PositionMilliseconds),
            controller.Chapter == chapter.Index, () => controller.SelectChapter(chapter)))];

    private void DrawChapterMarkers()
    {
        chapterMarkers.Children.Clear();
        if (controller.Duration <= 0 || chapterMarkers.Bounds.Width <= 0) return;
        foreach (var chapter in controller.Chapters.Where(chapter => chapter.PositionMilliseconds > 0))
        {
            // A small gap in the bar, as on the Mac, centered on the track.
            var marker = new Border { Width = 2, Height = 6, CornerRadius = new CornerRadius(1), Background = new SolidColorBrush(Color.FromArgb(200, 12, 14, 16)) };
            Canvas.SetLeft(marker, chapterMarkers.Bounds.Width * Math.Clamp((double)chapter.PositionMilliseconds / controller.Duration, 0, 1) - 1);
            Canvas.SetTop(marker, Math.Max(0, chapterMarkers.Bounds.Height / 2 - 3));
            chapterMarkers.Children.Add(marker);
        }
    }

    internal int ChapterMarkerCount => chapterMarkers.Children.Count;

    private List<Control> AudioMenu()
    {
        var items = new List<Control>();
        if (controller.AudioTracks.Count == 0) items.Add(Note("No audio tracks available"));
        foreach (var track in controller.AudioTracks) items.Add(Choice(track.Name, controller.AudioTrack == track.Id, () => controller.SelectAudio(track)));
        items.Add(new Separator());
        items.Add(SectionTitle("Dialogue Boost"));
        foreach (var mode in Enum.GetValues<DialogueBoost>())
            items.Add(Choice(mode.ToString(), controller.Preferences.DialogueBoost == mode, () => controller.SetDialogueBoost(mode)));
        items.Add(new Separator());
        items.Add(SectionTitle("Volume Leveling"));
        foreach (var mode in Enum.GetValues<VolumeLeveling>())
            items.Add(Choice(mode.ToString(), controller.Preferences.EffectiveLeveling == mode, () => _ = controller.SetVolumeLevelingAsync(mode)));
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

    /// <summary>
    /// One choice of a player menu. The chosen one carries a checkmark and stands out, as in the
    /// Mac app's menus; every entry keeps the checkmark's room so the names line up.
    /// </summary>
    private static MenuItem Choice(string header, bool selected, Action action)
    {
        var item = new MenuItem
        {
            Header = header,
            Classes = { "playerChoice" },
            Icon = new PathIcon
            {
                Data = Application.Current?.FindResource("IconCheck") as Geometry,
                Opacity = selected ? 1 : 0,
            },
        };
        if (selected) item.Classes.Add("chosen");
        AutomationProperties.SetName(item, selected ? header + ", selected" : header);
        item.Click += (_, _) => action();
        return item;
    }

    /// <summary>A small title over a group of choices, such as "Dialogue Boost".</summary>
    private static MenuItem SectionTitle(string header) =>
        new() { Header = header, IsEnabled = false, Focusable = false, Classes = { "menuSectionTitle" } };

    /// <summary>A quiet line that only informs, such as "No audio tracks available".</summary>
    private static MenuItem Note(string header) =>
        new() { Header = header, IsEnabled = false, Focusable = false, Classes = { "menuNote" } };

    /// <summary>Watch Together: start a party for this title, or see who watches along and leave.</summary>
    private Button TogetherButton()
    {
        var button = Control("IconPeople", "Watch Together", () => { });
        var content = new StackPanel { Spacing = 10, Width = 280, Margin = new Thickness(6) };
        var flyout = new Flyout { Content = content, Placement = PlacementMode.BottomEdgeAlignedRight };
        flyout.Opening += (_, _) => FillTogether(content, flyout);
        Track(flyout);
        button.Flyout = flyout;
        return button;
    }

    private void FillTogether(StackPanel content, Flyout flyout)
    {
        content.Children.Clear();
        content.Children.Add(new TextBlock { Text = "Watch Together", FontWeight = FontWeight.SemiBold, FontSize = 15 });
        if (together?.WatchParty is { State: { } state })
        {
            foreach (var member in state.Members)
            {
                content.Children.Add(new StackPanel
                {
                    Spacing = 1,
                    Children =
                    {
                        new TextBlock { Text = (member.IsYou ? $"{member.Name} (You)" : member.Name) + (member.IsHost ? " · Host" : "") + (member.IsBuffering ? " · Loading…" : "") },
                        new TextBlock { Text = member.DeviceName, FontSize = 11, Foreground = Secondary },
                    },
                });
            }
            if (state.IsWaiting) content.Children.Add(new TextBlock { Text = "Waiting until everyone is ready…", FontSize = 12, Foreground = Secondary });
            var leave = new Button { Content = "Leave Watch Together", Classes = { "destructive" } };
            leave.Click += async (_, _) => { flyout.Hide(); await together.LeaveWatchTogetherAsync(); };
            content.Children.Add(leave);
            return;
        }
        content.Children.Add(new TextBlock
        {
            Text = "Watch this title in step with other devices at home. They join from the title's page, and play, pause and jumps apply to everyone.",
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Foreground = Secondary,
        });
        var start = new Button { Content = "Start Watch Together", Classes = { "primary" } };
        AutomationProperties.SetName(start, "Start Watch Together");
        start.Click += async (_, _) =>
        {
            start.IsEnabled = false;
            if (together is not null) await together.StartWatchTogetherAsync(controller);
            FillTogether(content, flyout);
        };
        content.Children.Add(start);
        if (together?.WatchParty?.Error is { } error) content.Children.Add(new TextBlock { Text = error, TextWrapping = TextWrapping.Wrap, Foreground = new SolidColorBrush(Color.Parse("#FFB36B")) });
    }

    /// <summary>"Mia paused" and similar, shown briefly at the top of the picture.</summary>
    private void ShowTogetherNotice()
    {
        var party = together?.WatchParty;
        var text = party?.Notice ?? (party?.State is { IsWaiting: true } ? "Waiting until everyone is ready…" : null);
        togetherNotice.Child = new TextBlock { Text = text, Foreground = Brushes.White, FontSize = 13 };
        togetherNotice.IsVisible = text is not null;
    }

    internal string? TogetherNoticeText => togetherNotice.IsVisible ? (togetherNotice.Child as TextBlock)?.Text : null;

    private Button Menu(string icon, string label, Func<List<Control>> items, PlacementMode placement)
    {
        // The entries are filled before the menu opens: filled only while opening, the menu
        // showed as an empty box. The menu is kept in Tag for tests.
        var flyout = new MenuFlyout { Placement = placement };
        flyout.Opening += (_, _) => flyout.ItemsSource = items();
        Track(flyout);
        Button? button = null;
        button = Control(icon, label, () =>
        {
            // A second click on the same button closes its menu instead of opening it again.
            if (flyout.IsOpen) { flyout.Hide(); return; }
            flyout.ItemsSource = items();
            flyout.ShowAt(button!);
        });
        button.Tag = flyout;
        return button;
    }

    private void Track(FlyoutBase flyout)
    {
        flyout.Opened += (_, _) => { openMenus++; ShowControls(); };
        flyout.Closed += (_, _) => { openMenus = Math.Max(0, openMenus - 1); ShowControls(); };
    }

    private static Button Control(string icon, string label, Action action, double size = 18)
    {
        var button = new Button
        {
            Classes = { "playerControl" },
            Content = new PathIcon { Data = Application.Current?.FindResource(icon) as Geometry, Width = size, Height = size },
        };
        AutomationProperties.SetName(button, label);
        ToolTip.SetTip(button, label);
        button.Click += (_, _) => action();
        return button;
    }

    /// <summary>An open circle with an arrowhead at its top and the skip seconds inside.</summary>
    internal static Control SkipSymbol(bool forward, int seconds)
    {
        var white = Brushes.White;
        var symbol = new Grid
        {
            Width = 26,
            Height = 26,
            Children =
            {
                new Avalonia.Controls.Shapes.Path
                {
                    // From the top, around, ending up left; open at the upper left.
                    Data = Geometry.Parse("M 13,3.7 A 9.5,9.5 0 1 1 4.8,8.45"),
                    Stroke = white,
                    StrokeThickness = 2,
                    StrokeLineCap = PenLineCap.Round,
                },
                new Avalonia.Controls.Shapes.Path { Data = Geometry.Parse("M 13.6,0.6 L 13.6,6.8 L 9.4,3.7 Z"), Fill = white },
                new TextBlock
                {
                    Text = seconds.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    FontSize = 9.5,
                    FontWeight = FontWeight.Bold,
                    Foreground = white,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Thickness(0, 2, 0, 0),
                },
            },
        };
        if (forward)
        {
            // The arrow turns the other way; the number stays readable.
            foreach (var shape in symbol.Children.OfType<Avalonia.Controls.Shapes.Path>())
            {
                shape.RenderTransformOrigin = new RelativePoint(13 / 26.0, 0.5, RelativeUnit.Relative);
                shape.RenderTransform = new ScaleTransform(-1, 1);
            }
        }
        return symbol;
    }

    /// <summary>One shared glass capsule, as the Mac draws its control groups.</summary>
    private static Border Capsule(params Control[] children)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        foreach (var child in children) row.Children.Add(child);
        return new Border { Classes = { "playerMaterial", "playerCapsule" }, Child = row };
    }

    /// <summary>The Mac's shade: a little darker at the top, darker at the bottom, clear between.</summary>
    private static LinearGradientBrush Shade() => new()
    {
        StartPoint = new RelativePoint(0.5, 0, RelativeUnit.Relative),
        EndPoint = new RelativePoint(0.5, 1, RelativeUnit.Relative),
        GradientStops =
        {
            new GradientStop(Color.FromArgb(0x6B, 0, 0, 0), 0),
            new GradientStop(Color.FromArgb(0, 0, 0, 0), 0.5),
            new GradientStop(Color.FromArgb(0xC7, 0, 0, 0), 1),
        },
    };
}

/// <summary>Where the player finds this computer's Watch Together party (the main window).</summary>
public interface IWatchTogetherHost
{
    WatchTogetherSession? WatchParty { get; }

    /// <summary>Raised on the UI thread when the party, its state or its notice changes.</summary>
    event Action? WatchPartyChanged;

    Task StartWatchTogetherAsync(PlaybackController controller);

    Task LeaveWatchTogetherAsync();
}
