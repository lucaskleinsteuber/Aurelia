using Aurelia.Contracts;
using Aurelia.Linux.Core.Management;
using Aurelia.Linux.Core.Playback;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Threading;
using static Aurelia.Linux.Management.AdminScope;
using static Aurelia.Linux.Settings.SettingsRows;

namespace Aurelia.Linux.Management;

/// <summary>
/// Edit Metadata › Subtitles › Subtitles from Speech: the server listens to the title with
/// whisper.cpp in the background and saves subtitles in the spoken language, or moves existing
/// subtitles onto the speech as a synced copy. The panel follows the job and can stop it.
/// </summary>
public sealed class SpeechPanel : StackPanel
{
    private readonly AdminScope scope;
    private readonly Guid mediaId;
    private readonly ComboBox spoken = new() { MinWidth = 160 };
    private readonly ComboBox tracks = new() { MinWidth = 220 };
    private readonly TextBlock problem = Message();
    private readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromSeconds(2) };
    private readonly Func<Task> reloadSubtitles;
    private List<LiveSubtitleTrack> subtitleTracks = [];

    public SpeechPanel(AdminScope scope, Guid mediaId, Func<Task> reloadSubtitles)
    {
        this.scope = scope;
        this.mediaId = mediaId;
        this.reloadSubtitles = reloadSubtitles;
        Spacing = 8;
        spoken.ItemsSource = SubtitleLanguages.Choices.Select(SubtitleLanguages.Name).ToList();
        spoken.SelectedIndex = Math.Max(0, SubtitleLanguages.Choices.ToList().IndexOf("en"));
        poll.Tick += async (_, _) => await RefreshAsync();
        DetachedFromVisualTree += (_, _) => poll.Stop();
        Children.Add(Note("Checking the server's speech recognition…"));
        _ = StartAsync();
    }

    private string SpokenCode => SubtitleLanguages.Choices[Math.Max(0, spoken.SelectedIndex)];

    private async Task StartAsync()
    {
        MediaSpeechResponse? state = null;
        if (!await scope.RunAsync(async () => state = await scope.Client.MediaSpeechAsync(mediaId), problem) || state is null)
        {
            Children.Clear();
            Children.Add(problem);
            return;
        }
        if (state is { Available: true, ModelReady: true }) await LoadTracksAsync();
        Show(state);
    }

    private async Task LoadTracksAsync()
    {
        if (scope.Session.Library is not { } library) return;
        var playback = new PlaybackClient(scope.Session.Api, library.Client);
        try
        {
            var ticket = await playback.StartAsync(mediaId, CancellationToken.None);
            try { subtitleTracks = [.. (await playback.SubtitlesAsync(ticket, CancellationToken.None)).Where(track => track.Supported)]; }
            finally { await playback.RevokeAsync(ticket.Id, CancellationToken.None); }
        }
        catch (Core.Api.AureliaApiException)
        {
            subtitleTracks = [];
        }
        tracks.ItemsSource = subtitleTracks.Select(track => string.Join(" · ", new[] { track.Title, track.Language }.Where(part => !string.IsNullOrWhiteSpace(part))) is { Length: > 0 } name ? name : "Subtitles").ToList();
        tracks.SelectedIndex = subtitleTracks.Count > 0 ? 0 : -1;
    }

    private async Task RefreshAsync()
    {
        try
        {
            var state = await scope.Client.MediaSpeechAsync(mediaId);
            if (!SpeechText.Running(state.Job)) await reloadSubtitles();
            Show(state);
        }
        catch (Core.Api.AureliaApiException) { }
    }

    private void Show(MediaSpeechResponse state)
    {
        Children.Clear();
        Children.Add(new TextBlock { Text = "Subtitles from Speech", FontWeight = Avalonia.Media.FontWeight.SemiBold });
        if (!state.Available)
        {
            poll.Stop();
            Children.Add(Note("The server needs whisper.cpp to listen (on Debian or Ubuntu: sudo apt install whisper.cpp)."));
            return;
        }
        if (!state.ModelReady)
        {
            poll.Stop();
            Children.Add(Note("Download a speech model first: Server › Speech Recognition."));
            return;
        }
        if (SpeechText.Running(state.Job))
        {
            Children.Add(new ProgressBar { Minimum = 0, Maximum = 1, Value = state.Job!.Progress, Height = 6 });
            Children.Add(Note(SpeechText.Line(state.Job)));
            var stop = Button("Stop", async () =>
            {
                if (await scope.RunAsync(() => scope.Client.CancelSpeechAsync(mediaId), problem)) await RefreshAsync();
            });
            ToolTip.SetTip(stop, "Stops listening; nothing is saved.");
            Children.Add(Buttons(stop));
            Children.Add(problem);
            poll.Start();
            return;
        }
        poll.Stop();
        if (state.Job is { } finished) Children.Add(Note(SpeechText.Line(finished)));
        Children.Add(Note("The server listens to the title in the background and keeps only the finished subtitles."));
        var create = Button("Create Subtitles from Speech", () => Begin(new StartSpeechJobRequest(SpeechJobKind.Create, SpokenCode)), "primary");
        ToolTip.SetTip(create, "Has the server write subtitles in the spoken language from what is said.");
        Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { new TextBlock { Text = "Spoken Language", VerticalAlignment = VerticalAlignment.Center }, spoken, create } });
        var sync = Button("Sync to Speech", () =>
        {
            if (tracks.SelectedIndex < 0 || tracks.SelectedIndex >= subtitleTracks.Count) return Task.CompletedTask;
            var track = subtitleTracks[tracks.SelectedIndex];
            var language = track.Language is { Length: >= 2 } code ? code[..2] : SpokenCode;
            return Begin(new StartSpeechJobRequest(SpeechJobKind.Sync, language, SubtitleIndex: track.Index));
        });
        ToolTip.SetTip(sync, "Moves the chosen subtitles so they appear when the words are said, also for another frame rate or cut. Saved as a synced copy; the original stays.");
        sync.IsEnabled = subtitleTracks.Count > 0;
        Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { new TextBlock { Text = "Subtitles", VerticalAlignment = VerticalAlignment.Center }, tracks, sync } });
        Children.Add(problem);
    }

    private async Task Begin(StartSpeechJobRequest request)
    {
        MediaSpeechResponse? state = null;
        if (await scope.RunAsync(async () => state = await scope.Client.StartSpeechAsync(mediaId, request), problem) && state is not null) Show(state);
    }
}

/// <summary>Server › Speech Recognition for the owner: whisper.cpp, the model to download or remove, and jobs.</summary>
public static class ServerSpeechSection
{
    public static async Task<Control> BuildAsync(AdminScope scope)
    {
        var problem = Message();
        ServerSpeechSettings? settings = null;
        await scope.RunAsync(async () => settings = await scope.Client.ServerSpeechAsync(), problem);
        if (settings is null) return Section("Speech Recognition", Block(problem));
        var panel = Block();
        var choice = "small";
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        async Task Act(Func<Task<ServerSpeechSettings>> action)
        {
            ServerSpeechSettings? value = null;
            if (await scope.RunAsync(async () => value = await action(), problem) && value is not null) Render(value);
        }
        void Render(ServerSpeechSettings value)
        {
            settings = value;
            panel.Children.Clear();
            panel.Children.Add(Note("The server writes subtitles from what is said and moves existing subtitles onto the speech, with whisper.cpp. Sound stays in memory; only the finished subtitles are kept."));
            if (!value.Available)
            {
                panel.Children.Add(Note("whisper.cpp isn't installed on this server. On Debian or Ubuntu: sudo apt install whisper.cpp."));
            }
            else if (value.Downloading is { } download)
            {
                panel.Children.Add(new ProgressBar { Minimum = 0, Maximum = Math.Max(1, download.TotalBytes), Value = download.ReceivedBytes, Height = 6 });
                panel.Children.Add(Note($"Downloading the {download.Name} model… {SpeechText.Bytes(download.ReceivedBytes)} of {SpeechText.Bytes(download.TotalBytes)}"));
                panel.Children.Add(Buttons(Button("Stop Download", () => Act(scope.Client.RemoveSpeechModelAsync))));
            }
            else if (value.Model is { } model)
            {
                var label = value.Models.FirstOrDefault(entry => entry.Name == model)?.Label ?? model;
                panel.Children.Add(new TextBlock { Text = $"Model: {label} · {SpeechText.Bytes(value.ModelBytes)}" });
                var remove = Button("Remove Model", async () =>
                {
                    if (await scope.Sheets.ConfirmAsync("Remove the speech model?", "Subtitles from speech then stay off until a model is downloaded again.", "Remove Model", destructive: true))
                        await Act(scope.Client.RemoveSpeechModelAsync);
                }, "destructive");
                ToolTip.SetTip(remove, "Deletes the model from the server's data folder. Subtitles already written stay.");
                panel.Children.Add(Buttons(remove));
            }
            else
            {
                foreach (var entry in value.Models)
                {
                    var radio = new RadioButton { GroupName = "speech-model", Content = $"{entry.Label} · {entry.Description}", IsChecked = entry.Name == choice };
                    radio.IsCheckedChanged += (_, _) => { if (radio.IsChecked == true) choice = entry.Name; };
                    panel.Children.Add(radio);
                }
                var start = Button("Download Model", () => Act(() => scope.Client.DownloadSpeechModelAsync(choice)), "primary");
                ToolTip.SetTip(start, "Downloads the chosen model once from whisper.cpp's model page into the server's data folder.");
                panel.Children.Add(Buttons(start));
            }
            if (value.DownloadError is { } error) panel.Children.Add(Note(error));
            foreach (var job in value.Jobs.Where(SpeechText.Running))
            {
                var cancel = Button("Cancel", async () =>
                {
                    if (await scope.RunAsync(() => scope.Client.CancelSpeechAsync(job.MediaId), problem)) await Act(scope.Client.ServerSpeechAsync);
                });
                panel.Children.Add(new DockPanel
                {
                    Children =
                    {
                        cancel.Also(b => DockPanel.SetDock(b, Dock.Right)),
                        new TextBlock { Text = $"{(job.Kind == SpeechJobKind.Sync ? "Syncing" : "Listening to")} {job.Title} · {SpeechText.Line(job)}", VerticalAlignment = VerticalAlignment.Center },
                    },
                });
            }
            panel.Children.Add(problem);
        }
        Render(settings);
        timer.Tick += async (_, _) =>
        {
            try { Render(await scope.Client.ServerSpeechAsync()); }
            catch (Core.Api.AureliaApiException) { }
        };
        var section = Section("Speech Recognition", panel);
        section.AttachedToVisualTree += (_, _) => timer.Start();
        section.DetachedFromVisualTree += (_, _) => timer.Stop();
        return section;
    }
}
