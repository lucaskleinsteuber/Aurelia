using Aurelia.Contracts;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Management;
using Aurelia.Linux.Core.Playback;
using Aurelia.Linux.Playback;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using static Aurelia.Linux.Management.AdminScope;
using static Aurelia.Linux.Settings.SettingsRows;

namespace Aurelia.Linux.Management;

/// <summary>
/// Edit Metadata › Intro and Credits, as on the Mac: the episode's times with where they came
/// from, corrections by hand, Edit Intro… and Edit Credits… on a film strip, and a new analysis.
/// A series only offers the new analysis.
/// </summary>
public sealed class SegmentsPanel : StackPanel
{
    private readonly AdminScope scope;
    private readonly Guid mediaId;
    private readonly IVideoEngineFactory? engines;
    private readonly TextBox introStart = new() { PlaceholderText = "0:00", Width = 110 };
    private readonly TextBox introEnd = new() { PlaceholderText = "1:30", Width = 110 };
    private readonly TextBox creditsStart = new() { PlaceholderText = "42:10", Width = 110 };
    private readonly TextBlock introOrigin = Note("");
    private readonly TextBlock creditsOrigin = Note("");
    private readonly TextBlock pending = Note("");
    private readonly bool movie;
    private string Noun => movie ? "movie" : "episode";
    private readonly TextBlock problem = Message();
    private readonly TextBlock done = Note("");
    private MediaSegmentsResponse? times;

    public SegmentsPanel(AdminScope scope, Guid mediaId, MediaKind kind, IVideoEngineFactory? engines)
    {
        this.scope = scope;
        this.mediaId = mediaId;
        this.engines = engines;
        movie = kind == MediaKind.Movie;
        pending.Text = $"The server has not examined this {Noun} yet.";
        Spacing = 10;
        if (kind == MediaKind.Series)
        {
            Children.Add(Note("The server compares a season's episodes to find the intro and the credits. Times set by hand stay."));
            Children.Add(Buttons(Tip(Button("Re-analyze All Seasons", () => Act(async () =>
            {
                await scope.Client.ReanalyzeMediaSegmentsAsync(mediaId);
                return "The server examines the episodes again in the background.";
            })), "Has the server compare every season's episodes again in the background. Times set by hand stay.")));
            Children.Add(done);
            Children.Add(problem);
            return;
        }
        AutomationProperties.SetName(introStart, "Intro Starts");
        AutomationProperties.SetName(introEnd, "Intro Ends");
        AutomationProperties.SetName(creditsStart, "Credits Start");
        Children.Add(Note("Loading…"));
        _ = LoadAsync();
    }

    private static Button Tip(Button button, string tip)
    {
        ToolTip.SetTip(button, tip);
        AutomationProperties.SetHelpText(button, tip);
        return button;
    }

    private async Task LoadAsync()
    {
        if (!await scope.RunAsync(async () => times = await scope.Client.MediaSegmentsAsync(mediaId), problem) || times is null)
        {
            Children.Clear();
            Children.Add(problem);
            return;
        }
        Children.Clear();
        Children.Add(Buttons(
            Tip(Button("Edit Intro…", () => TrimAsync(SegmentPart.Intro)), "Opens the title's beginning with a film strip: drag the yellow handles to where the intro begins and ends, play it to check, then save."),
            Tip(Button("Edit Credits…", () => TrimAsync(SegmentPart.Credits)), "Opens the title's ending with a film strip: drag the handle to where the credits begin, play it to check, then save.")));
        Children.Add(Note("Or type the times as minutes:seconds, for example 1:24. Leave a field empty when there is nothing to skip."));
        Children.Add(Line("Intro Starts", introStart, introOrigin));
        Children.Add(Line("Intro Ends", introEnd, new TextBlock()));
        Children.Add(Line("Credits Start", creditsStart, creditsOrigin));
        Children.Add(pending);
        var save = Tip(Button("Save Times", () => Act(async () =>
        {
            var request = SegmentEditing.Request(introStart.Text ?? "", introEnd.Text ?? "", creditsStart.Text ?? "")
                ?? throw new FormatException("Enter times like 1:24 or 1:02:30.");
            Apply(await scope.Client.SaveMediaSegmentsAsync(mediaId, SegmentEditing.KeepUnchanged(request, times!)));
            return $"Saved. These times are used the next time the {Noun} starts.";
        }), "primary"), "Saves the typed times as corrections; detection never replaces them.");
        var reset = Tip(Button("Reset to Detected", () => Act(async () =>
        {
            Apply(await scope.Client.ResetMediaSegmentsAsync(mediaId));
            return $"The server examines the {Noun} again; its times appear here shortly.";
        })), $"Removes the times set by hand; the server examines the {Noun} again and fills in what it finds.");
        var reanalyze = Tip(Button(movie ? "Re-analyze Movie" : "Re-analyze Season", () => Act(async () =>
        {
            await scope.Client.ReanalyzeMediaSegmentsAsync(mediaId);
            return movie ? "The server looks for the movie's credits again in the background." : "The server examines the episodes again in the background.";
        })), movie ? "Has the server look for this movie's credits again in the background. Times set by hand stay."
            : "Has the server compare this season's episodes again in the background. Times set by hand stay.");
        Children.Add(Buttons(save, reset, reanalyze));
        Children.Add(done);
        Children.Add(problem);
        Apply(times);
        reset.IsEnabled = times.IntroSource == MediaSegmentSource.Manual || times.CreditsSource == MediaSegmentSource.Manual;
        reanalyze.IsVisible = times.CanAnalyze;
    }

    private static DockPanel Line(string label, TextBox field, TextBlock origin) => new()
    {
        LastChildFill = true,
        Children =
        {
            new TextBlock { Text = label, Width = 130, VerticalAlignment = VerticalAlignment.Center }.Also(t => DockPanel.SetDock(t, Dock.Left)),
            field.Also(f => DockPanel.SetDock(f, Dock.Left)),
            origin.Also(o => { o.Margin = new Thickness(12, 0, 0, 0); o.VerticalAlignment = VerticalAlignment.Center; }),
        },
    };

    private void Apply(MediaSegmentsResponse value)
    {
        times = value;
        introStart.Text = SegmentEditing.Text(value.IntroStartMilliseconds);
        introEnd.Text = SegmentEditing.Text(value.IntroEndMilliseconds);
        creditsStart.Text = SegmentEditing.Text(value.CreditsStartMilliseconds);
        introOrigin.Text = SegmentEditing.Origin(value.IntroSource, value.IntroConfidence);
        creditsOrigin.Text = SegmentEditing.Origin(value.CreditsSource, value.CreditsConfidence);
        pending.IsVisible = value.CanAnalyze && !value.Analyzed;
    }

    private async Task Act(Func<Task<string>> action)
    {
        done.Text = "";
        string? result = null;
        try
        {
            if (await scope.RunAsync(async () => result = await action(), problem) && result is not null) done.Text = result;
        }
        catch (FormatException failure)
        {
            problem.Text = failure.Message;
            problem.IsVisible = true;
        }
    }

    private async Task TrimAsync(SegmentPart part)
    {
        if (times is null) return;
        var sheet = new TrimEditorSheet(scope, mediaId, part, times, engines);
        if (await scope.Sheets.ShowAsync(sheet) && sheet.Saved is { } saved)
        {
            Apply(saved);
            done.Text = $"Saved. These times are used the next time the {Noun} starts.";
        }
        await sheet.DisposeAsync();
    }
}

/// <summary>
/// The trim editor: the episode's picture through its own ticket, relay and decoder (nothing
/// changes its progress), a film strip of the server's stills, and yellow handles. Space plays
/// the selection in a loop; arrow keys nudge the focused handle by a tenth of a second.
/// </summary>
public sealed class TrimEditorSheet : UserControl, IAsyncDisposable
{
    private const int StripFrames = 10;
    private static readonly IBrush Yellow = new SolidColorBrush(Color.Parse("#F5C518"));
    private readonly AdminScope scope;
    private readonly Guid mediaId;
    private readonly SegmentPart part;
    private readonly MediaSegmentsResponse times;
    private readonly IVideoEngineFactory? engines;
    private readonly PlaybackClient? playback;
    private readonly VideoSurface surface = new() { Fills = false };
    private readonly Image still = new() { Stretch = Stretch.Uniform };
    private readonly Grid strip = new() { Height = 64, ClipToBounds = false };
    private readonly StackPanel frames = new() { Orientation = Orientation.Horizontal };
    private readonly Canvas overlay = new();
    private readonly Border selection = new() { BorderBrush = Yellow, BorderThickness = new Thickness(3), CornerRadius = new CornerRadius(6), Background = new SolidColorBrush(Color.FromArgb(30, 245, 197, 24)), IsHitTestVisible = false };
    private readonly Border startHandle = Handle();
    private readonly Border? endHandle;
    private readonly Border playhead = new() { Width = 2, Height = 76, Background = Brushes.White, IsHitTestVisible = false };
    private readonly TextBlock startLabel = new() { MinWidth = 60 };
    private readonly TextBlock endLabel = new() { MinWidth = 60 };
    private readonly TextBlock problem = Message();
    private readonly Button play;
    private readonly Button mute;
    private readonly DispatcherTimer loop = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private IVideoEngine? engine;
    private LoopbackStreamRelay? relay;
    private PlaybackSourceResponse? ticket;
    private (long Lower, long Upper) span = (0, 1);
    private long duration;
    private long start;
    private long end;
    private bool looping;
    private Border? dragging;

    public TrimEditorSheet(AdminScope scope, Guid mediaId, SegmentPart part, MediaSegmentsResponse times, IVideoEngineFactory? engines)
    {
        this.scope = scope;
        this.mediaId = mediaId;
        this.part = part;
        this.times = times;
        this.engines = engines;
        playback = scope.Session.Library is { } library ? new PlaybackClient(scope.Session.Api, library.Client) : null;
        var intro = part == SegmentPart.Intro;
        endHandle = intro ? Handle() : null;
        Width = 820;
        Focusable = true;
        AutomationProperties.SetName(startHandle, intro ? "Intro starts" : "Credits start");
        if (endHandle is not null) AutomationProperties.SetName(endHandle, "Intro ends");
        overlay.Children.Add(selection);
        overlay.Children.Add(startHandle);
        if (endHandle is not null) overlay.Children.Add(endHandle);
        overlay.Children.Add(playhead);
        strip.Children.Add(new Border { CornerRadius = new CornerRadius(8), ClipToBounds = true, Background = new SolidColorBrush(Color.FromArgb(20, 255, 255, 255)), Child = frames });
        strip.Children.Add(overlay);
        strip.SizeChanged += (_, _) => { LayoutFrames(); Draw(); };
        foreach (var handle in new[] { startHandle, endHandle })
        {
            if (handle is null) continue;
            handle.PointerPressed += (_, e) => { dragging = handle; e.Pointer.Capture(handle); };
            handle.PointerMoved += (_, e) =>
            {
                if (dragging != handle || strip.Bounds.Width <= 0) return;
                var fraction = Math.Clamp(e.GetPosition(strip).X / strip.Bounds.Width, 0, 1);
                Move(handle == startHandle, (long)(span.Lower + fraction * (span.Upper - span.Lower)));
            };
            handle.PointerReleased += (_, e) => { dragging = null; e.Pointer.Capture(null); };
            handle.KeyDown += (_, e) =>
            {
                var step = e.KeyModifiers.HasFlag(KeyModifiers.Shift) ? 1000 : SegmentEditing.Nudge;
                if (e.Key is not (Key.Left or Key.Right)) return;
                var isStart = handle == startHandle;
                Move(isStart, (isStart ? start : end) + (e.Key == Key.Left ? -step : step));
                e.Handled = true;
            };
        }
        play = Tip(Button("Play Selection", () => { TogglePlay(); return Task.CompletedTask; }), "Plays only the yellow part, over and over, so you can check it (Space).");
        mute = Tip(Button("Mute", () =>
        {
            if (engine is not null) engine.Muted = !engine.Muted;
            mute!.Content = engine?.Muted == true ? "Unmute" : "Mute";
            return Task.CompletedTask;
        }), "Turns the sound of the preview off or on; the episode itself is not changed.");
        Button Nudge(bool isStart, long delta, string label) => Tip(Button(label, () => { Move(isStart, (isStart ? start : end) + delta); return Task.CompletedTask; }),
            $"Moves the {(isStart ? (intro ? "intro's start" : "credits' start") : "intro's end")} by a tenth of a second.");
        var none = Tip(Button(intro ? "No Intro" : "No Credits", () => SaveAsync(clear: true)),
            intro ? "Saves that this episode has no intro, so nothing is skipped." : "Saves that this episode has no credits; Up Next then appears in the last seconds.");
        var cancel = Tip(Button("Cancel", () => { scope.Sheets.Close(false); return Task.CompletedTask; }), "Closes without saving anything.");
        var save = Tip(Button("Save", () => SaveAsync(clear: false), "primary"),
            intro ? "Saves where the intro begins and ends; Skip Intro jumps to its end." : "Saves where the credits begin; Up Next appears there.");
        var times_ = new WrapPanel { ItemSpacing = 10, LineSpacing = 8 };
        times_.Children.Add(new TextBlock { Text = intro ? "Starts" : "Credits start", VerticalAlignment = VerticalAlignment.Center });
        times_.Children.Add(startLabel.Also(t => t.VerticalAlignment = VerticalAlignment.Center));
        times_.Children.Add(Nudge(true, -SegmentEditing.Nudge, "−0.1 s"));
        times_.Children.Add(Nudge(true, SegmentEditing.Nudge, "+0.1 s"));
        if (intro)
        {
            times_.Children.Add(new TextBlock { Text = "   Ends", VerticalAlignment = VerticalAlignment.Center });
            times_.Children.Add(endLabel.Also(t => t.VerticalAlignment = VerticalAlignment.Center));
            times_.Children.Add(Nudge(false, -SegmentEditing.Nudge, "−0.1 s"));
            times_.Children.Add(Nudge(false, SegmentEditing.Nudge, "+0.1 s"));
        }
        Content = new StackPanel
        {
            Spacing = 12,
            Children =
            {
                new TextBlock { Text = intro ? "Edit Intro" : "Edit Credits", FontSize = 20, FontWeight = FontWeight.Bold },
                Note(intro ? "Drag the yellow handles to where the intro begins and ends. Arrow keys move a handle by a tenth of a second, with Shift by a second."
                    : "Drag the yellow handle to where the credits begin. Arrow keys move it by a tenth of a second, with Shift by a second."),
                new Border { Height = 400, Background = Brushes.Black, CornerRadius = new CornerRadius(10), ClipToBounds = true, Child = new Grid { Children = { still, surface } } },
                strip.Also(s => s.Margin = new Thickness(8, 10)),
                times_,
                Buttons(play, mute),
                problem,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { none, cancel, save } },
            },
        };
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Space && e.Source is not Avalonia.Controls.Button)
            {
                TogglePlay();
                e.Handled = true;
            }
        };
        loop.Tick += (_, _) => Follow();
        _ = OpenAsync();
    }

    /// <summary>The saved times after Save or No Intro/No Credits.</summary>
    public MediaSegmentsResponse? Saved { get; private set; }

    private static Border Handle() => new()
    {
        Width = 14,
        Height = 80,
        CornerRadius = new CornerRadius(5),
        Background = Yellow,
        Cursor = new Cursor(StandardCursorType.SizeWestEast),
        Focusable = true,
        BoxShadow = BoxShadows.Parse("0 2 6 0 #80000000"),
    };

    private static Button Tip(Button button, string tip)
    {
        ToolTip.SetTip(button, tip);
        AutomationProperties.SetHelpText(button, tip);
        return button;
    }

    private bool Intro => part == SegmentPart.Intro;

    private async Task OpenAsync()
    {
        if (playback is null) return;
        try
        {
            ticket = await playback.StartAsync(mediaId, CancellationToken.None);
            duration = ticket.Progress.DurationMilliseconds;
            if (engines is not null)
            {
                relay = new LoopbackStreamRelay(playback.StreamConnection, playback.StreamToken, playback.StreamUri(ticket), "preview");
                engine = engines.Create(nightMode: false);
                engine.Muted = true;
                mute.Content = "Unmute";
                surface.Frames = (engine as VlcVideoEngine)?.Frames;
                engine.Open(relay.Start(), 0, paused: true);
                for (var wait = 0; wait < 50 && engine.Length <= 0; wait++) await Task.Delay(100);
                if (engine.Length > 0) duration = engine.Length;
            }
            if (duration <= 0) throw new InvalidOperationException("The episode's length isn't known yet. Play it once, then try again.");
            span = SegmentEditing.Span(part, duration, Intro ? times.IntroStartMilliseconds : times.CreditsStartMilliseconds, times.IntroEndMilliseconds);
            (long Start, long End)? known = Intro
                ? times is { IntroStartMilliseconds: { } s, IntroEndMilliseconds: { } e } ? (s, e) : null
                : times.CreditsStartMilliseconds is { } c ? (c, span.Upper) : null;
            var first = known ?? SegmentEditing.Initial(part, span);
            (start, end) = SegmentEditing.Clamp(first.Start, first.End, span);
            Draw();
            Show(start);
            await LoadFramesAsync();
        }
        catch (Exception failure) when (failure is Core.Api.AureliaApiException or InvalidOperationException or HttpRequestException)
        {
            problem.Text = failure.Message;
            problem.IsVisible = true;
        }
    }

    private async Task LoadFramesAsync()
    {
        if (playback is null) return;
        frames.Children.Clear();
        var images = new List<Image>();
        for (var index = 0; index < StripFrames; index++)
        {
            var image = new Image { Stretch = Stretch.UniformToFill, Height = 64 };
            images.Add(image);
            frames.Children.Add(image);
        }
        LayoutFrames();
        for (var index = 0; index < StripFrames; index++)
        {
            var at = span.Lower + (index + 0.5) / StripFrames * (span.Upper - span.Lower);
            if (await playback.ScrubPreviewAsync(mediaId, (int)(at / 1000), CancellationToken.None) is { } bytes)
            {
                using var stream = new MemoryStream(bytes);
                images[index].Source = new Bitmap(stream);
            }
        }
    }

    private void LayoutFrames()
    {
        var width = strip.Bounds.Width / StripFrames;
        foreach (var child in frames.Children.OfType<Image>()) child.Width = Math.Max(1, width);
    }

    private double X(long milliseconds) => strip.Bounds.Width * (milliseconds - span.Lower) / Math.Max(1, span.Upper - span.Lower);

    private void Draw()
    {
        var right = Intro ? end : span.Upper;
        Canvas.SetLeft(startHandle, X(start) - 7);
        Canvas.SetTop(startHandle, -8);
        if (endHandle is not null)
        {
            Canvas.SetLeft(endHandle, X(end) - 7);
            Canvas.SetTop(endHandle, -8);
        }
        Canvas.SetLeft(selection, X(start));
        Canvas.SetTop(selection, -3);
        selection.Width = Math.Max(0, X(right) - X(start));
        selection.Height = 70;
        startLabel.Text = SegmentEditing.Label(start);
        endLabel.Text = SegmentEditing.Label(end);
        AutomationProperties.SetItemStatus(startHandle, SegmentEditing.Label(start));
        if (endHandle is not null) AutomationProperties.SetItemStatus(endHandle, SegmentEditing.Label(end));
    }

    private void Move(bool isStart, long value)
    {
        (start, end) = isStart ? SegmentEditing.Clamp(value, Intro ? end : span.Upper, span) : SegmentEditing.Clamp(start, value, span);
        if (!Intro) end = span.Upper;
        Draw();
        Show(isStart ? start : end);
    }

    private void Show(long milliseconds)
    {
        Canvas.SetLeft(playhead, X(milliseconds) - 1);
        Canvas.SetTop(playhead, -6);
        if (engine is not null && !looping) engine.Seek(milliseconds);
    }

    private void TogglePlay()
    {
        if (engine is null)
        {
            problem.Text = "Playing needs VLC on this computer; the handles still set the times.";
            problem.IsVisible = true;
            return;
        }
        looping = !looping;
        play.Content = looping ? "Pause" : "Play Selection";
        if (looping)
        {
            engine.Seek(start);
            engine.Play();
            loop.Start();
        }
        else
        {
            engine.Pause();
            loop.Stop();
        }
    }

    private void Follow()
    {
        if (engine is null) return;
        var now = engine.Time;
        Canvas.SetLeft(playhead, X(now) - 1);
        var stop = Intro ? end : Math.Min(span.Upper, start + 30_000);
        if (now >= stop) engine.Seek(start);
    }

    private async Task SaveAsync(bool clear)
    {
        var request = Intro
            ? new SetMediaSegmentsRequest(clear ? null : start, clear ? null : end, times.CreditsStartMilliseconds)
            : new SetMediaSegmentsRequest(times.IntroStartMilliseconds, times.IntroEndMilliseconds, clear ? null : start);
        MediaSegmentsResponse? saved = null;
        if (await scope.RunAsync(async () => saved = await scope.Client.SaveMediaSegmentsAsync(mediaId, request), problem) && saved is not null)
        {
            Saved = saved;
            scope.Sheets.Close(true);
        }
    }

    public async ValueTask DisposeAsync()
    {
        loop.Stop();
        surface.Frames = null;
        if (engine is not null)
        {
            engine.Unload();
            engine.Dispose();
            engine = null;
        }
        if (relay is not null) await relay.DisposeAsync();
        relay = null;
        if (ticket is not null && playback is not null)
        {
            try { await playback.RevokeAsync(ticket.Id, CancellationToken.None); }
            catch (Core.Api.AureliaApiException) { }
            ticket = null;
        }
        surface.Dispose();
    }
}

/// <summary>Server settings › Intros and Credits for the owner, refreshed every five seconds while shown.</summary>
public static class ServerSegmentsSection
{
    public static async Task<Control> BuildAsync(AdminScope scope)
    {
        var problem = Message();
        MediaSegmentSettingsResponse? settings = null;
        await scope.RunAsync(async () => settings = await scope.Client.ServerMediaSegmentsAsync(), problem);
        if (settings is null) return Section("Intros and Credits", Block(problem));
        var panel = Block();
        var bar = new ProgressBar { Minimum = 0, Maximum = 1, Height = 6, MinWidth = 260 };
        var status = Note("");
        var current = Note("");
        var movies = Note("");
        var series = new StackPanel { Spacing = 6 };
        var expander = new Expander { Header = "Series", Content = series, HorizontalAlignment = HorizontalAlignment.Stretch };
        var enabled = new CheckBox { Content = "Find Intros and Credits" };
        var pictures = new CheckBox { Content = "Look at Pictures Too" };
        ToolTip.SetTip(enabled, "Compares the sound of a season's episodes in the background, only while nobody watches.");
        ToolTip.SetTip(pictures, "Also reads small grey pictures of the episodes, for credits with changing music and intros under narration. Slower, more accurate.");
        var updating = false;
        Button? reanalyzeMovies = null;
        void Render(MediaSegmentSettingsResponse value)
        {
            settings = value;
            updating = true;
            enabled.IsChecked = value.Enabled;
            pictures.IsChecked = value.UsePictures;
            pictures.IsEnabled = value.Enabled;
            updating = false;
            bar.Value = SegmentEditing.Progress(value);
            status.Text = SegmentEditing.Status(value);
            current.Text = value.Running && value.CurrentTitle is { } title ? $"Now: {title}{(value.CurrentStep is { } step ? $" · {step}" : "")}" : "";
            current.IsVisible = current.Text.Length > 0;
            movies.Text = SegmentEditing.MovieStatus(value) ?? "";
            movies.IsVisible = movies.Text.Length > 0;
            if (reanalyzeMovies is not null) reanalyzeMovies.IsVisible = value.MovieCount > 0;
        }
        async Task Change(UpdateMediaSegmentSettingsRequest request)
        {
            MediaSegmentSettingsResponse? saved = null;
            if (await scope.RunAsync(async () => saved = await scope.Client.SaveServerMediaSegmentsAsync(request), problem) && saved is not null) Render(saved);
        }
        enabled.IsCheckedChanged += (_, _) => { if (!updating) _ = Change(new UpdateMediaSegmentSettingsRequest(enabled.IsChecked == true)); };
        pictures.IsCheckedChanged += (_, _) => { if (!updating) _ = Change(new UpdateMediaSegmentSettingsRequest(settings?.Enabled ?? true, pictures.IsChecked == true)); };
        async Task LoadSeries()
        {
            IReadOnlyList<MediaSegmentSeriesStatus>? list = null;
            if (!await scope.RunAsync(async () => list = await scope.Client.MediaSegmentSeriesAsync(), problem) || list is null) return;
            series.Children.Clear();
            foreach (var entry in list)
            {
                var reanalyze = Button("Re-analyze", async () =>
                {
                    MediaSegmentSettingsResponse? value = null;
                    if (await scope.RunAsync(async () => value = await scope.Client.ReanalyzeAllSegmentsAsync(entry.SeriesId), problem) && value is not null) Render(value);
                });
                ToolTip.SetTip(reanalyze, $"Has the server examine every episode of {entry.Title} again. Times set by hand stay.");
                series.Children.Add(new DockPanel
                {
                    Children =
                    {
                        reanalyze.Also(b => DockPanel.SetDock(b, Dock.Right)),
                        new StackPanel
                        {
                            Spacing = 2,
                            Children =
                            {
                                new TextBlock { Text = entry.Title, FontWeight = FontWeight.SemiBold },
                                Note($"{entry.WithIntro} of {entry.EpisodeCount} with intro · {entry.WithCredits} with credits{(entry.PendingCount > 0 ? $" · {entry.PendingCount} to examine" : "")}"),
                            },
                        },
                    },
                });
            }
            if (list.Count == 0) series.Children.Add(Note("No series yet."));
        }
        expander.Expanded += (_, _) => _ = LoadSeries();
        var everything = Button("Re-analyze Everything", async () =>
        {
            MediaSegmentSettingsResponse? value = null;
            if (await scope.RunAsync(async () => value = await scope.Client.ReanalyzeAllSegmentsAsync(null), problem) && value is not null) Render(value);
        });
        ToolTip.SetTip(everything, "Has the server examine every episode and movie again. Times set by hand stay.");
        reanalyzeMovies = Button("Re-analyze Movies", async () =>
        {
            MediaSegmentSettingsResponse? value = null;
            if (await scope.RunAsync(async () => value = await scope.Client.ReanalyzeMovieSegmentsAsync(), problem) && value is not null) Render(value);
        });
        ToolTip.SetTip(reanalyzeMovies, "Has the server look for every movie's credits again. Episodes and times set by hand stay.");
        panel.Children.Add(Note("The server finds where episodes' intros and credits are, in the background and only while nobody watches. Only the times are stored."));
        panel.Children.Add(enabled);
        panel.Children.Add(pictures);
        panel.Children.Add(bar);
        panel.Children.Add(status);
        panel.Children.Add(movies);
        panel.Children.Add(current);
        panel.Children.Add(expander);
        panel.Children.Add(Buttons(everything, reanalyzeMovies));
        panel.Children.Add(problem);
        Render(settings);
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        timer.Tick += async (_, _) =>
        {
            try { Render(await scope.Client.ServerMediaSegmentsAsync()); }
            catch (Core.Api.AureliaApiException) { }
        };
        var section = Section("Intros and Credits", panel);
        section.AttachedToVisualTree += (_, _) => timer.Start();
        section.DetachedFromVisualTree += (_, _) => timer.Stop();
        return section;
    }
}
