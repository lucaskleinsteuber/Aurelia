using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Aurelia.Desktop.Core;
using Aurelia.Desktop.Playback;

namespace Aurelia.Desktop.Views;

/// <summary>The player screen: picture, controls that hide while watching, and keyboard shortcuts.</summary>
public sealed partial class PlayerView : UserControl
{
    private static readonly TimeSpan HideDelay = TimeSpan.FromSeconds(3);
    private readonly DispatcherTimer hideTimer;
    private PlayerModel? model;
    private ScrubPreviews? previews;
    private long previewBucket = -1;
    private bool scrubbing;
    private bool menuOpen;
    private bool updatingSliders;

    /// <summary>Keeps the top controls clear of the window's title bar while the window is not full screen.</summary>
    public void SetTitleBarInset(double top) => TopBar.Margin = new Avalonia.Thickness(24, 20 + top, 24, 0);

    public PlayerView()
    {
        InitializeComponent();
        hideTimer = new DispatcherTimer { Interval = HideDelay };
        hideTimer.Tick += (_, _) => HideControlsIfIdle();
        Timeline.AddHandler(PointerPressedEvent, (_, _) => scrubbing = true, RoutingStrategies.Tunnel, handledEventsToo: true);
        Timeline.AddHandler(PointerReleasedEvent, (_, _) => FinishScrub(), RoutingStrategies.Tunnel, handledEventsToo: true);
        VolumeSlider.PropertyChanged += (_, change) =>
        {
            if (change.Property == Avalonia.Controls.Primitives.RangeBase.ValueProperty && !updatingSliders) model?.SetVolume((int)VolumeSlider.Value);
        };
    }

    /// <summary>Raised when the person leaves the player.</summary>
    public event Action? CloseRequested;

    /// <summary>Makes timeline previews; tests turn them off because they need a real stream.</summary>
    public Func<Uri, long, bool, ScrubPreviews?> PreviewFactory { get; set; } =
        (source, duration, parallel) => new ScrubPreviews(source, duration, parallel);

    public void Show(PlayerModel player)
    {
        model = player;
        DataContext = player;
        hideTimer.Interval = player.HideDelay;
        player.PropertyChanged += ModelChanged;
        AttachEngine();
        UpdateSliders();
        UpdatePlayPause();
        ShowControls();
        Focus();
    }

    public void Release()
    {
        hideTimer.Stop();
        if (model is not null) model.PropertyChanged -= ModelChanged;
        model = null;
        Surface.Frames = null;
        previews?.Dispose();
        previews = null;
        previewBucket = -1;
        PreviewBubble.IsVisible = false;
        Cursor = Cursor.Default;
        DataContext = null;
    }

    private void ModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(PlayerModel.Engine):
                AttachEngine();
                break;
            case nameof(PlayerModel.Progress):
            case nameof(PlayerModel.Volume):
                UpdateSliders();
                break;
            case nameof(PlayerModel.IsPlaying):
                UpdatePlayPause();
                if (model?.IsPlaying == false) ShowControls();
                else RestartHideTimer();
                break;
            case nameof(PlayerModel.PreviewSource):
            case nameof(PlayerModel.Duration):
            case nameof(PlayerModel.MediaId):
                ConfigurePreviews();
                break;
        }
    }

    private void AttachEngine() => Surface.Frames = (model?.Engine as VlcVideoEngine)?.Frames;

    /// <summary>Previews belong to the open title; the next one discards them from memory.</summary>
    private void ConfigurePreviews()
    {
        previews?.Dispose();
        previews = null;
        previewBucket = -1;
        if (model is not { PreviewSource: { } source, Duration: > 0 } current) return;
        previews = PreviewFactory(source, current.Duration, current.PreviewsParallel);
        previews?.Start();
    }

    private void UpdateSliders()
    {
        if (model is null) return;
        updatingSliders = true;
        if (!scrubbing) Timeline.Value = model.Progress;
        VolumeSlider.Value = model.Volume;
        updatingSliders = false;
    }

    private void UpdatePlayPause() => PlayPauseGlyph.Text = model?.IsPlaying == true ? "❚❚" : "▶";

    private void FinishScrub()
    {
        if (!scrubbing || model is null) return;
        scrubbing = false;
        model.Seek((long)(Timeline.Value * model.Duration));
        RestartHideTimer();
    }

    private void TimelineHover(object? sender, PointerEventArgs e)
    {
        if (model is not { Duration: > 0 } current) return;
        var width = Timeline.Bounds.Width;
        if (width <= 0) return;
        var x = Math.Clamp(e.GetPosition(Timeline).X, 0, width);
        var time = (long)(x / width * current.Duration);
        PreviewTime.Text = PlayerPolicy.TimeLabel(time);
        if (previews?.Frame(time) is { } jpeg)
        {
            var bucket = previews.Bucket(time);
            if (bucket != previewBucket)
            {
                previewBucket = bucket;
                using var stream = new MemoryStream(jpeg);
                (PreviewImage.Source as IDisposable)?.Dispose();
                PreviewImage.Source = new Bitmap(stream);
            }
        }
        else
        {
            PreviewImage.Source = null;
            previewBucket = -1;
        }
        var bubbleWidth = 206.0;
        Canvas.SetLeft(PreviewBubble, Math.Clamp(x - bubbleWidth / 2, 0, Math.Max(0, width - bubbleWidth)));
        Canvas.SetTop(PreviewBubble, -150);
        PreviewBubble.IsVisible = true;
        ShowControls();
    }

    private void TimelineLeft(object? sender, PointerEventArgs e) => PreviewBubble.IsVisible = false;

    private void PointerActivity(object? sender, PointerEventArgs e) => ShowControls();

    private void PointerPressedActivity(object? sender, PointerPressedEventArgs e)
    {
        ShowControls();
        Focus();
    }

    private void ShowControls()
    {
        Overlay.Opacity = 1;
        Overlay.IsHitTestVisible = true;
        Cursor = Cursor.Default;
        RestartHideTimer();
    }

    private void RestartHideTimer()
    {
        hideTimer.Stop();
        hideTimer.Start();
    }

    private void HideControlsIfIdle()
    {
        hideTimer.Stop();
        if (model is not { IsPlaying: true, HasError: false } || menuOpen || scrubbing || Timeline.IsPointerOver) return;
        Overlay.Opacity = 0;
        Overlay.IsHitTestVisible = false;
        PreviewBubble.IsVisible = false;
        Cursor = new Cursor(StandardCursorType.None);
    }

    private void KeyPressed(object? sender, KeyEventArgs e)
    {
        // Typing a scene note is not a shortcut.
        if (model is null || e.Source is TextBox) return;
        switch (e.Key)
        {
            case Key.Space or Key.K: model.TogglePlay(); break;
            case Key.Left or Key.J: model.SkipBy(-model.SkipMilliseconds); break;
            case Key.Right or Key.L: model.SkipBy(model.SkipMilliseconds); break;
            case Key.Up: model.SetVolume(model.Volume + 5); break;
            case Key.Down: model.SetVolume(model.Volume - 5); break;
            case Key.M: model.ToggleMute(); break;
            case Key.F: ToggleFullScreen(null, new RoutedEventArgs()); break;
            case Key.N when model.HasUpNext: _ = model.PlayNextNowAsync(); break;
            case Key.Escape:
                if (TopLevel.GetTopLevel(this) is Window { WindowState: WindowState.FullScreen } window) window.WindowState = WindowState.Normal;
                else CloseRequested?.Invoke();
                break;
            default: return;
        }
        e.Handled = true;
        ShowControls();
    }

    private void Back(object? sender, RoutedEventArgs e) => CloseRequested?.Invoke();
    private void TogglePlay(object? sender, RoutedEventArgs e) => model?.TogglePlay();
    private void SkipBack(object? sender, RoutedEventArgs e) => model?.SkipBy(-(model?.SkipMilliseconds ?? PlayerPolicy.SkipMilliseconds));
    private void SkipForward(object? sender, RoutedEventArgs e) => model?.SkipBy(model?.SkipMilliseconds ?? PlayerPolicy.SkipMilliseconds);
    private void ToggleMute(object? sender, RoutedEventArgs e) => model?.ToggleMute();
    private async void PlayNext(object? sender, RoutedEventArgs e) => await (model?.PlayNextNowAsync() ?? Task.CompletedTask);
    private void DismissUpNext(object? sender, RoutedEventArgs e) => model?.DismissUpNext();
    private async void Retry(object? sender, RoutedEventArgs e) => await (model?.RetryAsync() ?? Task.CompletedTask);

    private void ToggleFullScreen(object? sender, RoutedEventArgs e)
    {
        if (TopLevel.GetTopLevel(this) is Window window)
            window.WindowState = window.WindowState == WindowState.FullScreen ? WindowState.Normal : WindowState.FullScreen;
    }

    private void ShowRateMenu(object? sender, RoutedEventArgs e)
    {
        if (model is not { } current) return;
        ShowMenu(sender, PlayerPolicy.Rates.Select(rate => Item(rate == 1 ? "Standard" : $"{rate:0.##}×", current.Rate == rate,
            () => current.SetRate(rate))));
    }

    private void ShowAudioMenu(object? sender, RoutedEventArgs e)
    {
        if (model is not { } current) return;
        var items = current.AudioTracks.Select(track => Item(track.Name, current.SelectedAudio == track.Id, () => current.SelectAudio(track))).ToList();
        if (items.Count == 0) items.Add(new MenuItem { Header = "No audio tracks", IsEnabled = false });
        items.Add(new MenuItem { Header = "-" });
        items.Add(Item("Night Mode", current.NightMode, () => current.SetNightMode(!current.NightMode)));
        ShowMenu(sender, items);
    }

    private void ShowSubtitleMenu(object? sender, RoutedEventArgs e)
    {
        if (model is not { } current) return;
        var items = new List<MenuItem> { Item("Off", current.SelectedSubtitle < 0, () => current.SelectSubtitle(null)) };
        items.AddRange(current.SubtitleTracks.Select(track => Item(track.Name, current.SelectedSubtitle == track.Id,
            () => current.SelectSubtitle(track))));
        ShowMenu(sender, items);
    }

    private void ShowSleepMenu(object? sender, RoutedEventArgs e)
    {
        if (model is not { } current) return;
        (string Title, int Minutes)[] choices = [("Off", 0), ("End of Episode", -1), ("15 Minutes", 15), ("30 Minutes", 30),
            ("45 Minutes", 45), ("60 Minutes", 60), ("90 Minutes", 90)];
        ShowMenu(sender, choices.Select(choice => Item(choice.Title, current.SleepMinutes == choice.Minutes,
            () => current.SetSleepTimer(choice.Minutes))));
    }

    private async void NotesOpened(object? sender, EventArgs e)
    {
        menuOpen = true;
        if (model is null) return;
        NotesPanel.DataContext = model.Notes;
        await model.Notes.LoadAsync();
    }

    private void NotesClosed(object? sender, EventArgs e)
    {
        menuOpen = false;
        model?.Notes.Cancel();
        RestartHideTimer();
        Focus();
    }

    private void MarkScene(object? sender, RoutedEventArgs e)
    {
        model?.Notes.Create();
        SceneText.Focus();
    }

    private async void SaveScene(object? sender, RoutedEventArgs e)
    {
        if (model is not null) await model.Notes.SaveAsync();
    }

    private void CancelScene(object? sender, RoutedEventArgs e) => model?.Notes.Cancel();

    private void JumpToScene(object? sender, RoutedEventArgs e)
    {
        if (model is not null && (sender as Control)?.DataContext is SceneNoteRow row) model.Notes.Jump(row);
    }

    private void EditScene(object? sender, RoutedEventArgs e)
    {
        if (model is not null && (sender as Control)?.DataContext is SceneNoteRow row) model.Notes.Edit(row);
    }

    private async void RemoveScene(object? sender, RoutedEventArgs e)
    {
        if (model is not null && (sender as Control)?.DataContext is SceneNoteRow row) await model.Notes.RemoveAsync(row);
    }

    private void ShowMenu(object? sender, IEnumerable<MenuItem> items)
    {
        if (sender is not Control anchor) return;
        var flyout = new MenuFlyout { Placement = PlacementMode.BottomEdgeAlignedRight };
        foreach (var item in items) flyout.Items.Add(item);
        flyout.Opened += (_, _) => menuOpen = true;
        flyout.Closed += (_, _) =>
        {
            menuOpen = false;
            RestartHideTimer();
            Focus();
        };
        flyout.ShowAt(anchor);
    }

    private static MenuItem Item(string title, bool selected, Action action)
    {
        var item = new MenuItem { Header = title, ToggleType = MenuItemToggleType.CheckBox, IsChecked = selected };
        item.Click += (_, _) => action();
        return item;
    }
}
