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
/// Timeline preview pictures from the server (GET /media/{id}/scrub-previews/{seconds}), one per
/// interval of the timeline (at least 10 s, at most 720 per title), kept in memory while the title
/// plays: at most 120 pictures. The pointer's picture waits 90 ms, so sweeping across the timeline
/// asks only for where it rests.
/// </summary>
internal sealed class ScrubPreviews(PlaybackController controller)
{
    private const int MemoryLimit = 120;
    private readonly Dictionary<(Guid, long), Bitmap?> cache = [];
    private readonly LinkedList<(Guid, long)> order = new();
    private long requested = -1;

    public async Task<Bitmap?> GetAsync(long position)
    {
        if (controller.Item is not { } item || controller.Duration <= 0) return null;
        var interval = ScrubPreviewPlan.Interval(controller.Duration);
        var bucket = ScrubPreviewPlan.Bucket(position, interval);
        var key = (item.Id, bucket);
        if (cache.TryGetValue(key, out var known)) return known;
        requested = bucket;
        await Task.Delay(90);
        if (requested != bucket) return null;
        var seconds = (int)(ScrubPreviewPlan.SnapshotPosition(bucket, interval, controller.Duration) / 1000);
        var bytes = await controller.Client.ScrubPreviewAsync(item.Id, seconds, CancellationToken.None);
        Bitmap? picture = null;
        if (bytes is { Length: > 0 })
        {
            try
            {
                using var stream = new MemoryStream(bytes);
                picture = Bitmap.DecodeToWidth(stream, 320);
            }
            catch (Exception error) when (error is ArgumentException or InvalidOperationException)
            {
                picture = null;
            }
        }
        cache[key] = picture;
        order.AddLast(key);
        while (order.Count > MemoryLimit)
        {
            cache.Remove(order.First!.Value);
            order.RemoveFirst();
        }
        return picture;
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
