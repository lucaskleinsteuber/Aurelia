using Aurelia.Contracts;
using Aurelia.Linux.Core.Management;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using static Aurelia.Linux.Management.AdminScope;

namespace Aurelia.Linux.Management;

/// <summary>
/// Settings › Metadata › Subtitle Downloads, as on the Mac: the owner enters a free
/// OpenSubtitles API key, chooses languages, an optional account and automatic downloads.
/// Keys and passwords go to the server once and never come back.
/// </summary>
public sealed class SubtitleSettingsBlock : StackPanel
{
    private readonly AdminScope scope;
    private readonly TextBlock message = Message();
    private readonly StackPanel content = new() { Spacing = 10 };

    public SubtitleSettingsBlock(AdminScope scope)
    {
        this.scope = scope;
        Spacing = 10;
        Children.Add(Note("Find subtitles on OpenSubtitles.com with your own free API key. Downloaded subtitles are kept in the server's data folder, never next to your media."));
        Children.Add(content);
        Children.Add(message);
        Loading = ReloadAsync();
    }

    internal Task Loading { get; private set; }

    internal SubtitleProviderStatus? Status { get; private set; }

    public async Task ReloadAsync()
    {
        SubtitleProviderStatus? status = null;
        if (!await scope.RunAsync(async () => status = await scope.Client.SubtitleProviderAsync(), message)) return;
        Show(status);
    }

    private void Show(SubtitleProviderStatus? status)
    {
        Status = status;
        content.Children.Clear();
        if (status is null) return;
        if (!status.HasApiKey)
        {
            if (!scope.IsOwner)
            {
                content.Children.Add(Note("An owner sets up subtitle downloads."));
                return;
            }
            var key = new TextBox { PasswordChar = '•', PlaceholderText = "OpenSubtitles API Key" };
            AutomationProperties.SetName(key, "OpenSubtitles API Key");
            content.Children.Add(key);
            content.Children.Add(Note("Create a free account on opensubtitles.com, then add an API consumer under your profile to get a key."));
            content.Children.Add(Button("Turn On Subtitle Downloads", async () =>
            {
                var value = key.Text?.Trim() ?? "";
                key.Text = "";
                if (value.Length == 0) return;
                await SaveAsync(new UpdateSubtitleProviderRequest(true, DefaultLanguages(), false, value));
            }, "primary"));
            return;
        }

        content.Children.Add(Row("OpenSubtitles", status.Enabled ? "On" : "Off"));
        content.Children.Add(Row("Languages", SubtitleLanguages.Names(status.Languages)));
        if (status.RemainingDownloads is { } remaining) content.Children.Add(Row("Downloads Left Today", remaining.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        content.Children.Add(Row("Downloaded", status.DownloadedCount.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        if (scope.IsOwner)
        {
            var enabled = new ToggleSwitch { IsChecked = status.Enabled, OnContent = "Subtitle downloads", OffContent = "Subtitle downloads" };
            AutomationProperties.SetName(enabled, "Subtitle downloads");
            enabled.IsCheckedChanged += async (_, _) => await SaveAsync(Request(status, enabled: enabled.IsChecked == true));
            content.Children.Add(enabled);

            var languages = new WrapPanel { ItemSpacing = 6, LineSpacing = 6 };
            foreach (var code in SubtitleLanguages.Choices)
            {
                var chosen = status.Languages.Contains(code);
                var chip = new LanguageChip(SubtitleLanguages.Name(code), chosen);
                chip.Click += async (_, _) =>
                {
                    var next = SubtitleLanguages.Toggle(status.Languages, code);
                    if (ReferenceEquals(next, status.Languages)) { chip.IsChecked = chosen; return; }
                    await SaveAsync(Request(status, languages: next));
                };
                languages.Children.Add(chip);
            }
            content.Children.Add(new TextBlock { Text = "Languages (up to five)", FontWeight = FontWeight.SemiBold });
            content.Children.Add(languages);

            var automatic = new ToggleSwitch { IsChecked = status.Automatic, IsEnabled = status.Enabled, OnContent = "Download missing subtitles automatically", OffContent = "Download missing subtitles automatically" };
            AutomationProperties.SetName(automatic, "Download missing subtitles automatically");
            automatic.IsCheckedChanged += async (_, _) => await SaveAsync(Request(status, automatic: automatic.IsChecked == true));
            content.Children.Add(automatic);
            content.Children.Add(Note("Every six hours the server looks for matched movies and episodes without subtitles in these languages, in the file or beside it. Each title is checked at most once a week."));

            content.Children.Add(new Separator());
            if (status.HasAccount)
            {
                content.Children.Add(Row("Account", status.AccountName ?? "Signed in"));
                content.Children.Add(Button("Remove Account", async () =>
                {
                    SubtitleProviderStatus? next = null;
                    if (await scope.RunAsync(async () => next = await scope.Client.RemoveSubtitleAccountAsync(), message)) Show(next);
                }));
            }
            else
            {
                var name = new TextBox { PlaceholderText = "User Name", Width = 200 };
                var password = new TextBox { PasswordChar = '•', PlaceholderText = "Password", Width = 200 };
                AutomationProperties.SetName(name, "OpenSubtitles User Name");
                AutomationProperties.SetName(password, "OpenSubtitles Password");
                content.Children.Add(new TextBlock { Text = "OpenSubtitles Account (optional)", FontWeight = FontWeight.SemiBold });
                content.Children.Add(Note("Without an account OpenSubtitles allows only a few downloads a day. The password stays on the server."));
                content.Children.Add(new WrapPanel
                {
                    ItemSpacing = 8,
                    LineSpacing = 8,
                    Children =
                    {
                        name,
                        password,
                        Button("Save Account", async () =>
                        {
                            var user = name.Text?.Trim() ?? "";
                            var secret = password.Text ?? "";
                            password.Text = "";
                            if (user.Length == 0 || secret.Length == 0) return;
                            await SaveAsync(Request(status) with { AccountName = user, AccountPassword = secret });
                        }),
                    },
                });
            }
            content.Children.Add(new Separator());
            content.Children.Add(Button("Remove API Key", async () =>
            {
                if (!await scope.Sheets.ConfirmAsync("Remove the OpenSubtitles API key?", "Subtitles already downloaded stay. New subtitles are not downloaded until you add a key again.", "Remove API Key", destructive: true)) return;
                SubtitleProviderStatus? next = null;
                if (await scope.RunAsync(async () => next = await scope.Client.RemoveSubtitleKeyAsync(), message)) Show(next);
            }, "destructive"));
        }
        content.Children.Add(Note(status.Attribution));
    }

    internal static IReadOnlyList<string> DefaultLanguages()
    {
        var current = System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName;
        return SubtitleLanguages.Choices.Contains(current) && current != "en" ? [current, "en"] : ["en"];
    }

    private static UpdateSubtitleProviderRequest Request(SubtitleProviderStatus status, bool? enabled = null, IReadOnlyList<string>? languages = null, bool? automatic = null) =>
        new(enabled ?? status.Enabled, languages ?? status.Languages, automatic ?? status.Automatic);

    private async Task SaveAsync(UpdateSubtitleProviderRequest request)
    {
        SubtitleProviderStatus? next = null;
        if (await scope.RunAsync(async () => next = await scope.Client.SaveSubtitleProviderAsync(request), message)) Show(next);
    }

    private static DockPanel Row(string label, string value) => Settings.SettingsRows.Value(label, value).Also(row => row.Margin = new Thickness(0));

    /// <summary>A language chip that stays pressed while chosen.</summary>
    private sealed class LanguageChip : Avalonia.Controls.Primitives.ToggleButton
    {
        public LanguageChip(string label, bool chosen)
        {
            Content = label;
            IsChecked = chosen;
            Classes.Add("chip");
            AutomationProperties.SetName(this, label);
        }

        protected override Type StyleKeyOverride => typeof(Avalonia.Controls.Primitives.ToggleButton);
    }
}

/// <summary>
/// Edit Metadata › Subtitles: the subtitles downloaded for this movie or episode, and a search
/// on OpenSubtitles to add one. Players list them with the title's other subtitles.
/// </summary>
public sealed class SubtitlePanel : StackPanel
{
    private readonly AdminScope scope;
    private readonly Guid mediaId;
    private readonly TextBlock message = Message();
    private readonly StackPanel downloaded = new() { Spacing = 8 };
    private readonly StackPanel search = new() { Spacing = 8 };
    private readonly StackPanel results = new() { Spacing = 6 };
    private readonly ComboBox language = new() { MinWidth = 160 };
    private SubtitleProviderStatus? status;

    public SubtitlePanel(AdminScope scope, Guid mediaId)
    {
        this.scope = scope;
        this.mediaId = mediaId;
        Spacing = 12;
        AutomationProperties.SetName(language, "Subtitle Language");
        Children.Add(downloaded);
        Children.Add(search);
        Children.Add(message);
        Loading = LoadAsync();
    }

    internal Task Loading { get; private set; }

    private async Task LoadAsync()
    {
        try { status = await scope.Client.SubtitleProviderAsync(); }
        catch (Exception exception) when (exception is not OperationCanceledException) { status = null; }
        IReadOnlyList<DownloadedSubtitle> list = [];
        if (!await scope.RunAsync(async () => list = await scope.Client.DownloadedSubtitlesAsync(mediaId), message)) return;
        ShowDownloaded(list);
        search.Children.Clear();
        if (status is not { Enabled: true })
        {
            search.Children.Add(Note("Set up subtitle downloads in Settings › Metadata to search for subtitles."));
            return;
        }
        var codes = status.Languages.Concat(SubtitleLanguages.Choices.Where(code => !status.Languages.Contains(code))).ToList();
        language.ItemsSource = codes.Select(SubtitleLanguages.Name).ToList();
        language.Tag = codes;
        language.SelectedIndex = 0;
        search.Children.Add(new Separator());
        search.Children.Add(new WrapPanel
        {
            ItemSpacing = 8,
            LineSpacing = 8,
            Children = { language, Button("Search OpenSubtitles", SearchAsync, "primary") },
        });
        search.Children.Add(results);
        search.Children.Add(Note(status.Attribution));
    }

    private string Language => language.Tag is List<string> codes && language.SelectedIndex >= 0 ? codes[language.SelectedIndex] : "en";

    private void ShowDownloaded(IReadOnlyList<DownloadedSubtitle> list)
    {
        downloaded.Children.Clear();
        if (list.Count == 0)
        {
            downloaded.Children.Add(Note("No subtitles downloaded for this title."));
            return;
        }
        foreach (var subtitle in list)
        {
            var text = new StackPanel { Spacing = 2, Children = { new TextBlock { Text = subtitle.Title } } };
            if (subtitle.Release is { } release) text.Children.Add(Note(release));
            var row = new DockPanel { LastChildFill = true };
            var remove = Button("Remove", async () =>
            {
                if (await scope.RunAsync(() => scope.Client.RemoveSubtitleAsync(mediaId, subtitle.Id), message))
                    ShowDownloaded([.. list.Where(entry => entry.Id != subtitle.Id)]);
            }, "destructive");
            DockPanel.SetDock(remove, Dock.Right);
            row.Children.Add(remove);
            if (subtitle.Automatic)
            {
                var automatic = Note("Automatic").Also(note => { note.VerticalAlignment = VerticalAlignment.Center; note.Margin = new Thickness(0, 0, 10, 0); });
                DockPanel.SetDock(automatic, Dock.Right);
                row.Children.Add(automatic);
            }
            row.Children.Add(text);
            downloaded.Children.Add(row);
        }
    }

    private async Task SearchAsync()
    {
        var code = Language;
        IReadOnlyList<SubtitleCandidate> found = [];
        if (!await scope.RunAsync(async () => found = await scope.Client.SearchSubtitlesAsync(mediaId, code), message)) return;
        results.Children.Clear();
        if (found.Count == 0)
        {
            results.Children.Add(Note($"No subtitles found in {SubtitleLanguages.Name(code)}."));
            return;
        }
        foreach (var candidate in found.Take(15))
        {
            var row = new DockPanel { LastChildFill = true };
            var download = Button("Download", async () =>
            {
                DownloadedSubtitle? added = null;
                if (!await scope.RunAsync(async () => added = await scope.Client.DownloadSubtitleAsync(mediaId,
                        new DownloadSubtitleRequest(candidate.FileId, candidate.Language, candidate.Release, candidate.HearingImpaired, candidate.ForeignPartsOnly)), message)) return;
                IReadOnlyList<DownloadedSubtitle> list = [];
                if (await scope.RunAsync(async () => list = await scope.Client.DownloadedSubtitlesAsync(mediaId), message)) ShowDownloaded(list);
            });
            DockPanel.SetDock(download, Dock.Right);
            row.Children.Add(download);
            row.Children.Add(new StackPanel
            {
                Spacing = 2,
                Children =
                {
                    new TextBlock { Text = candidate.Release ?? SubtitleLanguages.Name(candidate.Language), TextTrimming = TextTrimming.CharacterEllipsis },
                    Note(SubtitleLanguages.Details(candidate)),
                },
            });
            results.Children.Add(row);
        }
    }
}
