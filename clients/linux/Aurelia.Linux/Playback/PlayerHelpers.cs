using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Playback;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;

namespace Aurelia.Linux.Playback;

/// <summary>
/// Timeline stills: prefer the server's prepared picture, otherwise decode a silent local still
/// through its own authenticated loopback relay. Pictures stay in a bounded memory cache for the
/// current title. A new pointer request cancels stale work; closing releases every bitmap.
/// </summary>
internal sealed class ScrubPreviews(PlaybackController controller) : IDisposable
{
    private const int MemoryLimit = 120;
    private readonly Dictionary<long, Bitmap?> cache = [];
    private readonly LinkedList<long> order = new();
    private CancellationTokenSource? request;
    private Guid? mediaId;
    private bool disposed;
    private Task decoderWork = Task.CompletedTask;

    internal int CachedPictures => cache.Values.Count(picture => picture is not null);

    public async Task<Bitmap?> GetAsync(long position)
    {
        if (disposed || controller.Item is not { } item || controller.Duration <= 0) return null;
        if (mediaId != item.Id)
        {
            request?.Cancel();
            Clear();
            mediaId = item.Id;
        }
        var interval = ScrubPreviewPlan.Interval(controller.Duration);
        var bucket = ScrubPreviewPlan.Bucket(position, interval);
        request?.Cancel();
        if (cache.TryGetValue(bucket, out var known)) return known ?? Nearest(bucket, interval);
        using var current = new CancellationTokenSource();
        request = current;
        try
        {
            await Task.Delay(90, current.Token);
            var at = ScrubPreviewPlan.SnapshotPosition(bucket, interval, controller.Duration);
            byte[]? bytes;
            try { bytes = await controller.Client.ScrubPreviewAsync(item.Id, (int)(at / 1000), current.Token); }
            catch (AureliaApiException) { bytes = null; }
            current.Token.ThrowIfCancellationRequested();
            Bitmap? picture = Decode(bytes);
            if (picture is null && controller.PreviewDecoders is { } factory && controller.CreatePreviewRelay() is { } relay)
            {
                await using (relay)
                {
                    // Only one native preview decoder at a time. Cancelled pointer requests wait
                    // for the previous decoder to stop before the newest one can open.
                    await decoderWork.WaitAsync(current.Token);
                    current.Token.ThrowIfCancellationRequested();
                    using var decoder = factory.CreatePreviewDecoder();
                    var capture = decoder.CaptureAsync(relay.Start(), at, current.Token);
                    decoderWork = capture;
                    try
                    {
                        if (await capture is { } frame && !current.IsCancellationRequested) picture = Decode(frame);
                    }
                    finally
                    {
                        if (decoderWork == capture) decoderWork = Task.CompletedTask;
                    }
                }
            }
            if (disposed || current.IsCancellationRequested || controller.Item?.Id != item.Id)
            {
                picture?.Dispose();
                return null;
            }
            cache[bucket] = picture;
            order.AddLast(bucket);
            while (order.Count > MemoryLimit)
            {
                if (cache.Remove(order.First!.Value, out var old)) old?.Dispose();
                order.RemoveFirst();
            }
            return picture ?? Nearest(bucket, interval);
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        catch (Exception failure) when (failure is IOException or InvalidOperationException or ArgumentException or LibVLCSharp.Shared.VLCException)
        {
            return disposed ? null : Nearest(bucket, interval);
        }
        finally
        {
            if (request == current) request = null;
        }
    }

    private Bitmap? Nearest(long bucket, long interval) =>
        ScrubPreviewPlan.Nearest(bucket, interval, at => cache.GetValueOrDefault(at) is not null) is { } found ? cache[found] : null;

    private static Bitmap? Decode(byte[]? bytes)
    {
        if (bytes is not { Length: > 0 }) return null;
        try
        {
            using var stream = new MemoryStream(bytes);
            return Bitmap.DecodeToWidth(stream, 320);
        }
        // Avalonia's codec wrapper can dereference an absent codec for corrupt image bytes.
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or IOException or NotSupportedException or NullReferenceException)
        {
            return null;
        }
    }

    private static WriteableBitmap? Decode(ScrubPreviewFrame frame)
    {
        if (frame.Width is <= 0 or > 320 || frame.Height is <= 0 or > 320 || frame.Pixels.Length != (long)frame.Width * frame.Height * 4) return null;
        var bitmap = new WriteableBitmap(new PixelSize(frame.Width, frame.Height), new Vector(96, 96), Avalonia.Platform.PixelFormat.Bgra8888, Avalonia.Platform.AlphaFormat.Opaque);
        using var buffer = bitmap.Lock();
        for (var row = 0; row < frame.Height; row++)
            System.Runtime.InteropServices.Marshal.Copy(frame.Pixels, row * frame.Width * 4, buffer.Address + row * buffer.RowBytes, frame.Width * 4);
        return bitmap;
    }

    public void Dispose()
    {
        disposed = true;
        Reset();
    }

    public void Reset()
    {
        request?.Cancel();
        request = null;
        mediaId = null;
        Clear();
    }

    private void Clear()
    {
        foreach (var picture in cache.Values) picture?.Dispose();
        cache.Clear();
        order.Clear();
    }
}

/// <summary>
/// Scene notes, as the Mac's popover: mark the current moment or a time range with an optional
/// note, edit or remove notes, jump to them, and see them as cues while playing. Notes are
/// private to the profile; playback keeps running.
/// </summary>
internal sealed class SceneNotes(PlaybackController controller)
{
    private readonly SceneNoteCues cues = new();
    private readonly StackPanel list = new() { Spacing = 10 };
    private readonly StackPanel draftPanel = new() { Spacing = 9, IsVisible = false };
    private readonly Button create = new() { Content = "Mark Current Position", Classes = { "chip" } };
    private readonly TextBlock problem = new() { Foreground = new SolidColorBrush(Color.Parse("#FFB45C")), FontSize = 12, TextWrapping = TextWrapping.Wrap, IsVisible = false };
    private readonly TextBox start = new() { PlaceholderText = "m:ss or h:mm:ss", Width = 170 };
    private readonly TextBox end = new() { PlaceholderText = "m:ss or h:mm:ss", Width = 170 };
    private readonly TextBox text = new() { PlaceholderText = "Note (optional)", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 64, MaxLength = 2000 };
    private readonly Button moment = new() { Content = "Moment", Classes = { "chip" } };
    private readonly Button range = new() { Content = "Time Range", Classes = { "chip" } };
    private readonly StackPanel endRow = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private SceneNoteSummary? editing;
    private bool isRange;
    private Guid? loadedFor;

    public event Action<IReadOnlyList<string>>? CuesChanged;

    public async Task LoadAsync()
    {
        if (controller.Item is not { } item) return;
        loadedFor = item.Id;
        try
        {
            cues.Replace(await controller.Client.NotesAsync(item.Id, CancellationToken.None));
            ShowProblem(null);
        }
        catch (AureliaApiException failure)
        {
            if (cues.Notes.Count == 0) cues.Replace([]);
            ShowProblem(failure.Message);
        }
        Fill();
    }

    public void Advance(long position)
    {
        if (controller.Item?.Id != loadedFor)
        {
            _ = LoadAsync();
            return;
        }
        CuesChanged?.Invoke([.. cues.Advance(position, DateTimeOffset.UtcNow).Select(n => n.Text)]);
    }

    public StackPanel Editor()
    {
        AutomationProperties.SetName(start, "Start");
        AutomationProperties.SetName(end, "End");
        AutomationProperties.SetName(text, "Note");
        AutomationProperties.SetName(create, "Mark Current Position");
        create.Click += (_, _) => BeginDraft(null);
        moment.Click += (_, _) => SetRange(false);
        range.Click += (_, _) => SetRange(true);
        var cancel = new Button { Content = "Cancel", Classes = { "chip" } };
        cancel.Click += (_, _) => EndDraft();
        var save = new Button { Content = "Save", Classes = { "primary" } };
        save.Click += async (_, _) =>
        {
            save.IsEnabled = false;
            await SaveAsync();
            save.IsEnabled = true;
        };
        endRow.Children.Add(Label("End"));
        endRow.Children.Add(end);
        endRow.Children.Add(UseCurrent(end));
        draftPanel.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { moment, range } });
        draftPanel.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { Label("Start"), start, UseCurrent(start) } });
        draftPanel.Children.Add(endRow);
        draftPanel.Children.Add(text);
        draftPanel.Children.Add(new DockPanel { Children = { save.Also(b => DockPanel.SetDock(b, Dock.Right)), cancel.Also(b => { b.HorizontalAlignment = HorizontalAlignment.Left; }) } });
        var reload = new Button { Classes = { "link" }, Content = "Reload" };
        ToolTip.SetTip(reload, "Reload scene notes without replacing your draft");
        reload.Click += async (_, _) => await LoadAsync();
        return new StackPanel
        {
            Spacing = 12,
            Width = 340,
            Children =
            {
                new DockPanel
                {
                    Children =
                    {
                        reload.Also(r => DockPanel.SetDock(r, Dock.Right)),
                        new TextBlock { Text = "Scene Notes", FontWeight = FontWeight.Bold, FontSize = 16, VerticalAlignment = VerticalAlignment.Center },
                    },
                },
                create,
                draftPanel,
                problem,
                new Border { Height = 1, Background = new SolidColorBrush(Color.FromArgb(0x1F, 0xFF, 0xFF, 0xFF)) },
                new ScrollViewer { Content = list, MaxHeight = 220 },
                new TextBlock { Text = "Private to your profile. Playback keeps running.", Classes = { "subdued" }, FontSize = 11 },
            },
        };
    }

    /// <summary>Reads "m:ss" or "h:mm:ss" (also plain seconds) as milliseconds.</summary>
    internal static long? ParseTime(string? value)
    {
        var parts = (value ?? "").Trim().Split(':');
        if (parts.Length is < 1 or > 3 || parts.Any(part => part.Length == 0 || !part.All(char.IsAsciiDigit))) return null;
        long seconds = 0;
        foreach (var part in parts)
        {
            if (!long.TryParse(part, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var number)) return null;
            seconds = seconds * 60 + number;
        }
        if (parts.Length > 1 && parts.Skip(1).Any(part => part.Length != 2 || int.Parse(part, System.Globalization.CultureInfo.InvariantCulture) > 59)) return null;
        return seconds * 1000;
    }

    private static TextBlock Label(string value) => new() { Text = value, Width = 38, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };

    private Button UseCurrent(TextBox target)
    {
        var button = new Button { Classes = { "link" }, Content = "Now" };
        ToolTip.SetTip(button, "Use current playback position");
        AutomationProperties.SetName(button, "Use Current Position");
        button.Click += (_, _) => target.Text = PlayerPolicy.TimeLabel(controller.Position);
        return button;
    }

    private void BeginDraft(SceneNoteSummary? note)
    {
        editing = note;
        start.Text = PlayerPolicy.TimeLabel(note?.StartMilliseconds ?? controller.Position);
        end.Text = note?.EndMilliseconds is { } until ? PlayerPolicy.TimeLabel(until) : PlayerPolicy.TimeLabel(controller.Position + 30_000);
        text.Text = note?.Text ?? "";
        SetRange(note?.EndMilliseconds is not null);
        create.IsVisible = false;
        draftPanel.IsVisible = true;
        ShowProblem(null);
        Avalonia.Threading.Dispatcher.UIThread.Post(() => text.Focus());
    }

    private void SetRange(bool value)
    {
        isRange = value;
        endRow.IsVisible = value;
        moment.Classes.Set("selected", !value);
        range.Classes.Set("selected", value);
    }

    private void EndDraft()
    {
        editing = null;
        draftPanel.IsVisible = false;
        create.IsVisible = true;
    }

    private async Task SaveAsync()
    {
        if (controller.Item is not { } item) return;
        if (ParseTime(start.Text) is not { } from)
        {
            ShowProblem("Enter the start as m:ss or h:mm:ss.");
            return;
        }
        long? until = null;
        if (isRange)
        {
            if (ParseTime(end.Text) is not { } to || to <= from)
            {
                ShowProblem("Enter an end after the start, as m:ss or h:mm:ss.");
                return;
            }
            until = to;
        }
        try
        {
            await controller.Client.SaveNoteAsync(item.Id, editing?.Id ?? Guid.NewGuid(),
                new SaveSceneNoteRequest(from, until, (text.Text ?? "").Trim(), editing?.Revision ?? 0), CancellationToken.None);
            EndDraft();
            await LoadAsync();
        }
        catch (AureliaApiException failure)
        {
            ShowProblem(failure.Message);
        }
    }

    private void ShowProblem(string? message)
    {
        problem.Text = message;
        problem.IsVisible = message is not null;
    }

    private void Fill()
    {
        list.Children.Clear();
        if (cues.Notes.Count == 0) list.Children.Add(new TextBlock { Text = "No scene notes yet.", Classes = { "subdued" } });
        foreach (var note in cues.Notes)
        {
            var time = PlayerPolicy.TimeLabel(note.StartMilliseconds) + (note.EndMilliseconds is { } until ? " – " + PlayerPolicy.TimeLabel(until) : "");
            var label = string.IsNullOrWhiteSpace(note.Text) ? "Marked scene" : note.Text;
            var jump = new Button
            {
                Classes = { "plain" },
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Content = new StackPanel
                {
                    Spacing = 2,
                    Children =
                    {
                        new TextBlock { Text = time, FontSize = 11, Classes = { "subdued" } },
                        new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap, MaxLines = 3 },
                    },
                },
            };
            ToolTip.SetTip(jump, "Jump to this scene");
            AutomationProperties.SetName(jump, $"{time}, {label}");
            jump.Click += (_, _) => controller.SeekTo(note.StartMilliseconds);
            var more = new Button { Classes = { "link" }, Content = "•••" };
            AutomationProperties.SetName(more, "More for Note at " + PlayerPolicy.TimeLabel(note.StartMilliseconds));
            var edit = new MenuItem { Header = "Edit" };
            edit.Click += (_, _) => BeginDraft(note);
            var remove = new MenuItem { Header = "Remove", Classes = { "destructive" } };
            remove.Click += async (_, _) =>
            {
                try
                {
                    await controller.Client.DeleteNoteAsync(note.MediaId, note.Id, note.Revision, CancellationToken.None);
                    await LoadAsync();
                }
                catch (AureliaApiException failure)
                {
                    ShowProblem(failure.Message);
                }
            };
            var menu = new MenuFlyout { ItemsSource = new List<Control> { edit, remove } };
            more.Click += (_, _) => menu.ShowAt(more);
            list.Children.Add(new DockPanel
            {
                Children =
                {
                    more.Also(r => { DockPanel.SetDock(r, Dock.Right); r.VerticalAlignment = VerticalAlignment.Top; }),
                    jump,
                },
            });
        }
    }
}
