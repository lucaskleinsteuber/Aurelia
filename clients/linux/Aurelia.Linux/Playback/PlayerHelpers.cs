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

/// <summary>Scene notes: loaded for the title, shown as cues while playing, added and removed in a flyout.</summary>
internal sealed class SceneNotes(PlaybackController controller)
{
    private readonly SceneNoteCues cues = new();
    private readonly StackPanel list = new() { Spacing = 6 };
    private readonly TextBox entry = new() { PlaceholderText = "Note at this moment", Width = 300, MaxLength = 2000 };
    private Guid? loadedFor;

    public event Action<IReadOnlyList<string>>? CuesChanged;

    public async Task LoadAsync()
    {
        if (controller.Item is not { } item) return;
        loadedFor = item.Id;
        try
        {
            cues.Replace(await controller.Client.NotesAsync(item.Id, CancellationToken.None));
        }
        catch (AureliaApiException)
        {
            cues.Replace([]);
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
        AutomationProperties.SetName(entry, "New Scene Note");
        var add = new Button { Content = "Add Note", Classes = { "primary" } };
        add.Click += async (_, _) => await AddAsync();
        entry.KeyDown += async (_, e) =>
        {
            if (e.Key == Avalonia.Input.Key.Enter) await AddAsync();
        };
        return new StackPanel
        {
            Spacing = 10,
            Width = 340,
            Children =
            {
                new TextBlock { Text = "Scene Notes", FontWeight = FontWeight.Bold, FontSize = 16 },
                new ScrollViewer { Content = list, MaxHeight = 260 },
                entry,
                add,
            },
        };
    }

    private async Task AddAsync()
    {
        if (controller.Item is not { } item || string.IsNullOrWhiteSpace(entry.Text)) return;
        try
        {
            await controller.Client.SaveNoteAsync(item.Id, Guid.NewGuid(),
                new SaveSceneNoteRequest(controller.Position, null, entry.Text.Trim(), 0), CancellationToken.None);
            entry.Text = "";
            await LoadAsync();
        }
        catch (AureliaApiException)
        {
        }
    }

    private void Fill()
    {
        list.Children.Clear();
        if (cues.Notes.Count == 0) list.Children.Add(new TextBlock { Text = "No notes for this title yet.", Classes = { "subdued" } });
        foreach (var note in cues.Notes)
        {
            var jump = new Button { Content = PlayerPolicy.TimeLabel(note.StartMilliseconds), Classes = { "link" } };
            jump.Click += (_, _) => controller.SeekTo(note.StartMilliseconds);
            var remove = new Button { Content = "Delete", Classes = { "link" } };
            AutomationProperties.SetName(remove, "Delete Note at " + PlayerPolicy.TimeLabel(note.StartMilliseconds));
            remove.Click += async (_, _) =>
            {
                try
                {
                    await controller.Client.DeleteNoteAsync(note.MediaId, note.Id, note.Revision, CancellationToken.None);
                    await LoadAsync();
                }
                catch (AureliaApiException)
                {
                }
            };
            list.Children.Add(new DockPanel
            {
                Children =
                {
                    jump.Also(j => DockPanel.SetDock(j, Dock.Left)),
                    remove.Also(r => DockPanel.SetDock(r, Dock.Right)),
                    new TextBlock { Text = note.Text, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center },
                },
            });
        }
    }
}
