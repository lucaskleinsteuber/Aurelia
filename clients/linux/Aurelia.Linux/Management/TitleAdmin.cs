using System.Globalization;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Management;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using static Aurelia.Linux.Management.AdminScope;
using static Aurelia.Linux.Settings.SettingsRows;

namespace Aurelia.Linux.Management;

/// <summary>Administrator actions on one title: edit, match, remove. Media files are never changed.</summary>
public static class TitleAdmin
{
    public static async Task<bool> RemoveAsync(AdminScope scope, CatalogItemSummary item)
    {
        if (!await scope.Sheets.ConfirmAsync($"Remove {item.Title}?",
            "Aurelia metadata, images, favorites and playback history for this title and its associated content will be removed for all users. Video files are never changed. Future scans will keep this source excluded.",
            "Remove from Library", destructive: true)) return false;
        var problem = Message();
        if (await scope.RunAsync(() => scope.Client.RemoveTitleAsync(item.Id), problem)) return true;
        await scope.Sheets.ConfirmAsync("Library Action Failed", problem.Text ?? "", "OK", destructive: false);
        return false;
    }
}

/// <summary>The Mac's MetadataMatchSheet: search TMDB, compare matches, use one or remove the match.</summary>
public sealed class MetadataMatchSheet : UserControl
{
    public MetadataMatchSheet(AdminScope scope, Guid mediaId, string title)
    {
        Width = 600;
        Height = 560;
        var query = new TextBox { Text = title, PlaceholderText = "Title" };
        AutomationProperties.SetName(query, "Search Metadata");
        var results = new StackPanel { Spacing = 8 };
        var problem = Message();
        var changed = false;
        async Task SearchAsync()
        {
            results.Children.Clear();
            results.Children.Add(Note("Searching metadata…"));
            IReadOnlyList<MetadataCandidateSummary> candidates = [];
            var worked = await scope.RunAsync(async () => candidates = await scope.Client.SearchMatchesAsync(mediaId, query.Text?.Trim() ?? ""), problem);
            results.Children.Clear();
            if (!worked) return;
            if (candidates.Count == 0) results.Children.Add(Note("No matches. Try another title."));
            foreach (var candidate in candidates)
            {
                var use = Button("Use Match", async () =>
                {
                    if (await scope.RunAsync(() => scope.Client.SelectMatchAsync(mediaId, new SelectMetadataMatchRequest(candidate.ProviderMediaId, candidate.MediaType)), problem))
                    {
                        changed = true;
                        scope.Sheets.Close(true);
                    }
                }, "primary");
                AutomationProperties.SetName(use, $"Use Match {candidate.Title}");
                results.Children.Add(Candidate(candidate, use));
            }
        }
        var search = Button("Search", SearchAsync, "primary");
        var remove = Button("Remove Match", async () =>
        {
            if (await scope.RunAsync(() => scope.Client.ClearMatchAsync(mediaId), problem))
            {
                changed = true;
                scope.Sheets.Close(true);
            }
        }, "destructive");
        var done = new Button { Content = "Done", Classes = { "chip" }, IsCancel = true };
        done.Click += (_, _) => scope.Sheets.Close(changed);
        Content = new DockPanel
        {
            Children =
            {
                new StackPanel
                {
                    Spacing = 10,
                    Margin = new Thickness(0, 0, 0, 10),
                    Children =
                    {
                        new TextBlock { Text = "Find Metadata Match", FontSize = 18, FontWeight = FontWeight.Bold },
                        Note("Type a title to find matches, then choose the correct result. Saved manual changes stay in place."),
                        new DockPanel { Children = { search.Also(b => { DockPanel.SetDock(b, Dock.Right); b.Margin = new Thickness(8, 0, 0, 0); }), query } },
                    },
                }.Also(p => DockPanel.SetDock(p, Dock.Top)),
                new StackPanel
                {
                    Spacing = 8,
                    Margin = new Thickness(0, 10, 0, 0),
                    Children = { problem, new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { remove, done } } },
                }.Also(p => DockPanel.SetDock(p, Dock.Bottom)),
                new ScrollViewer { Content = results },
            },
        };
        Loading = SearchAsync();
    }

    internal Task Loading { get; }

    internal static Control Candidate(MetadataCandidateSummary candidate, Control action) => new Border
    {
        Classes = { "card" },
        Padding = new Thickness(12),
        Child = new DockPanel
        {
            Children =
            {
                action.Also(a => { DockPanel.SetDock(a, Dock.Right); a.VerticalAlignment = VerticalAlignment.Center; }),
                new StackPanel
                {
                    Spacing = 2,
                    Children =
                    {
                        new TextBlock { Text = candidate.Title + (candidate.Year is { } year ? $" ({year})" : ""), FontWeight = FontWeight.SemiBold },
                        new TextBlock { Text = $"{(candidate.MediaType == "tv" ? "TV Show" : "Movie")} · {(int)Math.Round(candidate.Confidence * 100)}% match", Classes = { "subdued" }, FontSize = 12 },
                        new TextBlock { Text = candidate.Overview ?? "", Classes = { "subdued" }, FontSize = 12, TextWrapping = TextWrapping.Wrap, MaxLines = 3, TextTrimming = TextTrimming.CharacterEllipsis },
                    },
                },
            },
        },
    };
}

/// <summary>The Mac's MetadataReviewQueueSheet: uncertain matches with their candidates.</summary>
public sealed class ReviewQueueSheet : UserControl
{
    private readonly AdminScope scope;
    private readonly StackPanel list = new() { Spacing = 12 };
    private readonly TextBlock problem = Message();

    public ReviewQueueSheet(AdminScope scope)
    {
        this.scope = scope;
        Width = 640;
        Height = 580;
        var done = new Button { Content = "Done", Classes = { "primary" }, IsDefault = true };
        done.Click += (_, _) => scope.Sheets.Close(true);
        Content = new DockPanel
        {
            Children =
            {
                new StackPanel
                {
                    Spacing = 4,
                    Margin = new Thickness(0, 0, 0, 10),
                    Children = { new TextBlock { Text = "Review Queue", FontSize = 18, FontWeight = FontWeight.Bold }, Note("Resolve uncertain metadata matches.") },
                }.Also(p => DockPanel.SetDock(p, Dock.Top)),
                new StackPanel { Spacing = 8, Margin = new Thickness(0, 10, 0, 0), Children = { problem, done.Also(d => d.HorizontalAlignment = HorizontalAlignment.Right) } }.Also(p => DockPanel.SetDock(p, Dock.Bottom)),
                new ScrollViewer { Content = list },
            },
        };
        Loading = FillAsync();
    }

    internal Task Loading { get; }

    private async Task FillAsync()
    {
        IReadOnlyList<MetadataReviewSummary> reviews = [];
        if (!await scope.RunAsync(async () => reviews = await scope.Client.ReviewsAsync(), problem)) return;
        list.Children.Clear();
        var open = reviews.Where(r => r.State == MetadataReviewState.NeedsReview).ToList();
        if (open.Count == 0)
        {
            list.Children.Add(new StackPanel
            {
                Spacing = 4,
                Margin = new Thickness(0, 40),
                HorizontalAlignment = HorizontalAlignment.Center,
                Children = { new TextBlock { Text = "Nothing to Review", FontSize = 16, FontWeight = FontWeight.SemiBold, HorizontalAlignment = HorizontalAlignment.Center }, Note("Items that need a decision will appear here.") },
            });
            return;
        }
        foreach (var review in open)
        {
            var group = new StackPanel { Spacing = 6, Children = { new TextBlock { Text = review.Title, FontWeight = FontWeight.SemiBold }, Note(review.Reason) } };
            foreach (var candidate in review.Candidates.Take(3))
            {
                group.Children.Add(MetadataMatchSheet.Candidate(candidate, Button("Use Match", async () =>
                {
                    if (await scope.RunAsync(() => scope.Client.SelectMatchAsync(review.MediaId, new SelectMetadataMatchRequest(candidate.ProviderMediaId, candidate.MediaType)), problem))
                        await FillAsync();
                }, "primary")));
            }
            group.Children.Add(Button("Search Manually…", async () =>
            {
                if (await scope.Sheets.ShowAsync(new MetadataMatchSheet(scope, review.MediaId, review.Title))) await FillAsync();
            }));
            list.Children.Add(group);
        }
    }
}

/// <summary>
/// The Mac's MetadataEditorSheet: title, year, overview, runtime, FSK, genres, studios, country,
/// cast and crew, poster and backdrop with crops, the TMDB match and the source file. Manual
/// changes survive scans and provider refreshes; the video file is never changed.
/// </summary>
public sealed class MetadataEditorSheet : UserControl
{
    private static readonly string[] Departments = ["Acting", "Directing", "Writing", "Production", "Sound", "Camera", "Editing", "Art", "Crew"];

    private readonly AdminScope scope;
    private readonly Guid mediaId;
    private readonly StackPanel body = new() { Spacing = 18, Margin = new Thickness(0, 0, 16, 0) };
    private readonly TextBlock problem = Message();
    private readonly HashSet<string> reset = [];
    private MediaEditorDocument? document;
    private List<EditorCredit> credits = [];
    private EditorArtwork? poster;
    private EditorArtwork? backdrop;
    private string? relativeSource;
    private readonly TextBox title = new() { PlaceholderText = "Title" };
    private readonly TextBox year = new() { PlaceholderText = "Year", Width = 100 };
    private readonly TextBox overview = new() { PlaceholderText = "Overview", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 130, VerticalContentAlignment = VerticalAlignment.Top };
    private readonly TextBox runtime = new() { PlaceholderText = "Runtime in Minutes", Width = 160 };
    private readonly ComboBox fsk = new() { MinWidth = 160 };
    private readonly TextBox genres = new() { PlaceholderText = "Genres, separated by commas" };
    private readonly TextBox studios = new() { PlaceholderText = "Studios, separated by commas" };
    private readonly TextBox country = new() { PlaceholderText = "Country of Origin", Width = 200 };

    public MetadataEditorSheet(AdminScope scope, Guid mediaId)
    {
        this.scope = scope;
        this.mediaId = mediaId;
        Width = 700;
        Height = 640;
        AutomationProperties.SetName(title, "Title");
        AutomationProperties.SetName(year, "Year");
        AutomationProperties.SetName(overview, "Overview");
        AutomationProperties.SetName(runtime, "Runtime in Minutes");
        AutomationProperties.SetName(fsk, "FSK");
        AutomationProperties.SetName(genres, "Genres");
        AutomationProperties.SetName(studios, "Studios");
        AutomationProperties.SetName(country, "Country of Origin");
        fsk.ItemsSource = new[] { MetadataEditing.FskLabel(null) }.Concat(MetadataEditing.FskAges.Select(age => MetadataEditing.FskLabel(age))).ToList();
        var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
        cancel.Click += async (_, _) =>
        {
            if (IsDirty && !await scope.Sheets.ConfirmAsync("Discard unsaved changes?", "Your existing metadata and images have not been changed.", "Discard", destructive: true)) return;
            scope.Sheets.Close(false);
        };
        var save = new Button { Content = "Save", Classes = { "primary" }, IsDefault = true };
        save.Click += async (_, _) =>
        {
            save.IsEnabled = false;
            await SaveAsync();
            save.IsEnabled = true;
        };
        Content = new DockPanel
        {
            Children =
            {
                new StackPanel
                {
                    Spacing = 4,
                    Margin = new Thickness(0, 0, 0, 12),
                    Children = { new TextBlock { Text = "Edit Metadata", FontSize = 20, FontWeight = FontWeight.Bold }, Note("Changes apply to this title. Your video files stay in place.") },
                }.Also(p => DockPanel.SetDock(p, Dock.Top)),
                new StackPanel
                {
                    Spacing = 8,
                    Margin = new Thickness(0, 12, 0, 0),
                    Children =
                    {
                        problem,
                        new DockPanel
                        {
                            Children =
                            {
                                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { cancel, save } }.Also(p => DockPanel.SetDock(p, Dock.Right)),
                                Note("Manual changes survive scans and provider refreshes."),
                            },
                        },
                    },
                }.Also(p => DockPanel.SetDock(p, Dock.Bottom)),
                new ScrollViewer { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = body },
            },
        };
        body.Children.Add(Note("Loading editor…"));
        Loading = LoadAsync();
    }

    internal Task Loading { get; }

    private bool IsDirty => document is not null && (reset.Count > 0 || Values() != document.Values);

    private async Task LoadAsync()
    {
        if (!await scope.RunAsync(async () => document = await scope.Client.EditorAsync(mediaId), problem) || document is null) return;
        var values = document.Values;
        title.Text = values.Title;
        year.Text = values.ReleaseYear?.ToString(CultureInfo.InvariantCulture);
        overview.Text = values.Overview;
        runtime.Text = values.RuntimeMinutes?.ToString(CultureInfo.InvariantCulture);
        fsk.SelectedIndex = values.FskAge is { } age ? Array.IndexOf(MetadataEditing.FskAges, age) + 1 : 0;
        genres.Text = string.Join(", ", values.Genres);
        studios.Text = string.Join(", ", values.Studios);
        country.Text = values.Country;
        credits = [.. values.Credits];
        poster = values.Poster;
        backdrop = values.Backdrop;
        relativeSource = null;
        reset.Clear();
        Build();
    }

    private void Build()
    {
        body.Children.Clear();
        if (document is null) return;
        title.MinWidth = 0;
        year.Width = 120;
        runtime.Width = 150;
        body.Children.Add(Card(Group("Title and Year", "IconNote",
            Field("Title", title, "title"),
            new WrapPanel
            {
                ItemSpacing = 24,
                LineSpacing = 14,
                Children = { Field("Release Year", year, "releaseYear"), Field("FSK", fsk, "fsk"), Field("Runtime in Minutes", runtime, "runtimeMinutes") },
            })));
        body.Children.Add(Card(Group("Overview", "IconLibrary", Field("Overview", overview, "overview"))));
        body.Children.Add(Card(Group("Genres", "IconSparkle", Field("Genres", genres, "genres"), Note("Separate genres with commas."))));
        body.Children.Add(Card(Group("Production and Release", "IconMovies",
            Field("Studios", studios, "studios"),
            Field("Country of Origin", country, "country"),
            Note("Choose one country. Foreign content ratings are not automatically converted to FSK."))));
        body.Children.Add(Card(CastAndCrew()));
        body.Children.Add(Card(Group("Artwork", "IconCollections",
            ArtworkRow("Poster", poster, 2.0 / 3, value => poster = value, "poster"),
            ArtworkRow("Backdrop", backdrop, 16.0 / 9, value => backdrop = value, "backdrop"))));
        body.Children.Add(Card(Group("Match with TMDB", "IconSearch",
            Note("Find the correct movie or series. Saved manual changes stay in place."),
            Button("Find Metadata Match…", async () =>
            {
                if (IsDirty && !await scope.Sheets.ConfirmAsync("Discard this draft to find a match?",
                    "Saved manual changes stay in place. Unsaved changes in this form will be discarded.", "Discard Draft and Find Match", destructive: true)) return;
                if (await scope.Sheets.ShowAsync(new MetadataMatchSheet(scope, mediaId, document.Values.Title))) await LoadAsync();
            }))));
        var source = new List<Control>
        {
            new TextBlock { Text = document.Kind == MediaKind.Series ? "Series Folder" : "Video File", FontWeight = FontWeight.SemiBold },
            new SelectableTextBlock { Text = relativeSource ?? document.RelativeSourcePath, FontFamily = new FontFamily("monospace"), FontSize = 12, TextWrapping = TextWrapping.Wrap },
        };
        if (document.Kind is MediaKind.Movie or MediaKind.Episode)
        {
            source.Add(Button("Choose Server File…", ChooseFileAsync));
            source.Add(Note("Select an existing video in this title's storage location. No video is uploaded, moved or modified."));
        }
        else
        {
            source.Add(Note("Edit an individual episode to change its video file."));
        }
        body.Children.Add(Card(Group("Source", "IconServer", [.. source])));
    }

    /// <summary>A section of the editor as on the Mac: a card with a symbol and a title.</summary>
    private static StackPanel Group(string heading, string icon, params Control[] children)
    {
        var panel = new StackPanel
        {
            Spacing = 14,
            Children =
            {
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 10,
                    Children =
                    {
                        new PathIcon { Data = Application.Current?.FindResource(icon) as Geometry, Width = 16, Height = 16, Foreground = new SolidColorBrush(Color.FromArgb(0xA6, 0xFF, 0xFF, 0xFF)), VerticalAlignment = VerticalAlignment.Center },
                        new TextBlock { Text = heading, FontSize = 17, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center },
                    },
                },
            },
        };
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    private static Border Card(Control content) => new() { Classes = { "card" }, Padding = new Thickness(20, 18), Child = content };

    /// <summary>A field with its name above it and, once changed by hand, "Use Automatic Value" beside the name.</summary>
    private StackPanel Field(string label, Control field, string override_) => new()
    {
        Spacing = 6,
        Children =
        {
            new DockPanel
            {
                LastChildFill = false,
                Children =
                {
                    new TextBlock { Text = label, FontSize = 12.5, FontWeight = FontWeight.SemiBold, Classes = { "subdued" }, VerticalAlignment = VerticalAlignment.Center },
                    Automatic(override_).Also(b => { DockPanel.SetDock(b, Dock.Right); b.Margin = new Thickness(12, 0, 0, 0); b.FontSize = 12; }),
                },
            },
            field,
        },
    };

    /// <summary>"Use Automatic Value": drops the manual change of one field when saving.</summary>
    private Button Automatic(string field)
    {
        var button = new Button { Content = "Use Automatic Value", Classes = { "link" }, IsVisible = document!.OverrideFields.Contains(field) && !reset.Contains(field) };
        AutomationProperties.SetName(button, "Use Automatic Value " + field);
        button.Click += (_, _) =>
        {
            reset.Add(field);
            var automatic = document.AutomaticValues;
            switch (field)
            {
                case "title": title.Text = automatic.Title; break;
                case "releaseYear": year.Text = automatic.ReleaseYear?.ToString(CultureInfo.InvariantCulture); break;
                case "overview": overview.Text = automatic.Overview; break;
                case "runtimeMinutes": runtime.Text = automatic.RuntimeMinutes?.ToString(CultureInfo.InvariantCulture); break;
                case "fsk": fsk.SelectedIndex = automatic.FskAge is { } age ? Array.IndexOf(MetadataEditing.FskAges, age) + 1 : 0; break;
                case "genres": genres.Text = string.Join(", ", automatic.Genres); break;
                case "studios": studios.Text = string.Join(", ", automatic.Studios); break;
                case "country": country.Text = automatic.Country; break;
                case "credits": credits = [.. automatic.Credits]; break;
                case "poster": poster = automatic.Poster; break;
                case "backdrop": backdrop = automatic.Backdrop; break;
            }
            Build();
        };
        return button;
    }

    private StackPanel CastAndCrew()
    {
        var panel = Group("Cast and Crew", "IconPerson", Note("Changes apply to this title only."));
        if (credits.Count == 0) panel.Children.Add(Note("No cast or crew. Add a person to begin."));
        for (var index = 0; index < credits.Count; index++)
        {
            var position = index;
            var credit = credits[index];
            var name = new TextBox { Text = credit.Name, PlaceholderText = "Name", Width = 200 };
            var department = new ComboBox { ItemsSource = Departments.Contains(credit.Department) ? Departments : [.. Departments, credit.Department], SelectedItem = credit.Department, MinWidth = 130 };
            var job = new TextBox { Text = credit.Job, PlaceholderText = "Job / Role", Width = 140 };
            var character = new TextBox { Text = credit.Character, PlaceholderText = "Character / Name in Film", Width = 200 };
            AutomationProperties.SetName(name, $"Person {index + 1} Name");
            AutomationProperties.SetName(character, $"Person {index + 1} Character");
            void Update() => credits[position] = credits[position] with
            {
                Name = name.Text ?? "",
                Department = department.SelectedItem as string ?? "Acting",
                Job = string.IsNullOrWhiteSpace(job.Text) ? null : job.Text.Trim(),
                Character = string.IsNullOrWhiteSpace(character.Text) ? null : character.Text.Trim(),
            };
            name.TextChanged += (_, _) => Update();
            job.TextChanged += (_, _) => Update();
            character.TextChanged += (_, _) => Update();
            department.SelectionChanged += (_, _) => Update();
            var up = IconButton("IconChevronUp", index > 0);
            var down = IconButton("IconChevronDown", index < credits.Count - 1);
            var remove = IconButton("IconWindowClose", true);
            AutomationProperties.SetName(up, $"Move {credit.Name} Up");
            AutomationProperties.SetName(down, $"Move {credit.Name} Down");
            AutomationProperties.SetName(remove, $"Remove {credit.Name}");
            up.Click += (_, _) => { (credits[position - 1], credits[position]) = (credits[position], credits[position - 1]); Build(); };
            down.Click += (_, _) => { (credits[position + 1], credits[position]) = (credits[position], credits[position + 1]); Build(); };
            remove.Click += (_, _) => { credits.RemoveAt(position); Build(); };
            var image = Button(credit.Profile is null ? "Choose Image…" : "Replace Image…", async () =>
            {
                if (await ChooseImageAsync(1, credit.Profile) is { } chosen)
                {
                    credits[position] = credits[position] with { Profile = chosen };
                    Build();
                }
            });
            panel.Children.Add(new Border
            {
                Classes = { "nestedCard" },
                Padding = new Thickness(12),
                Child = new DockPanel
                {
                    Children =
                    {
                        new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Top, Children = { up, down, remove } }.Also(p => DockPanel.SetDock(p, Dock.Right)),
                        new StackPanel
                        {
                            Spacing = 6,
                            Children =
                            {
                                new WrapPanel { ItemSpacing = 8, LineSpacing = 6, Children = { name, department, job } },
                                new WrapPanel { ItemSpacing = 8, LineSpacing = 6, Children = { character, image } },
                            },
                        },
                    },
                },
            });
        }
        panel.Children.Add(Buttons(Button("Add Person", () =>
        {
            credits.Add(new EditorCredit(Guid.NewGuid(), "", "Acting", null, null, null));
            Build();
            return Task.CompletedTask;
        }), Automatic("credits")));
        return panel;
    }

    private static Button IconButton(string icon, bool enabled) => new()
    {
        Classes = { "iconSmall" },
        IsEnabled = enabled,
        Content = new PathIcon { Data = Application.Current?.FindResource(icon) as Geometry, Width = 12, Height = 12 },
    };

    private StackPanel ArtworkRow(string label, EditorArtwork? current, double aspect, Action<EditorArtwork?> set, string field)
    {
        var state = current switch
        {
            null => "No image",
            { UploadId: not null } => "New image" + (current.Crop is null ? "" : ", cropped"),
            { Crop: not null } => "Cropped image",
            _ => "Current image",
        };
        var crop = Button("Crop…", async () =>
        {
            if (current is null) return;
            var bytes = await ImageBytesAsync(current);
            if (bytes is null) return;
            var sheet = new CropSheet(scope, bytes, aspect, current.Crop);
            if (await scope.Sheets.ShowAsync(sheet))
            {
                set(current with { Crop = sheet.Result });
                Build();
            }
        });
        crop.IsEnabled = current is not null;
        AutomationProperties.SetName(crop, "Crop " + label);
        var choose = Button("Choose Image…", async () =>
        {
            if (await ChooseImageAsync(aspect, null) is { } chosen)
            {
                set(chosen);
                Build();
            }
        });
        AutomationProperties.SetName(choose, "Choose " + label);
        var remove = Button("Remove Image", () =>
        {
            set(null);
            Build();
            return Task.CompletedTask;
        });
        remove.IsEnabled = current is not null;
        AutomationProperties.SetName(remove, "Remove " + label);
        return new StackPanel
        {
            Spacing = 6,
            Children =
            {
                new TextBlock { Text = $"{label} · {state}" },
                Buttons(choose, crop, remove, Automatic(field)),
            },
        };
    }

    private async Task<byte[]?> ImageBytesAsync(EditorArtwork artwork)
    {
        byte[]? bytes = null;
        await scope.RunAsync(async () => bytes = artwork.UploadId is { } upload
            ? await scope.Client.EditorUploadAsync(mediaId, upload)
            : artwork.AssetId is { } asset ? await scope.Client.EditorArtworkAsync(mediaId, asset) : null, problem);
        return bytes;
    }

    /// <summary>Uploads a chosen image as a draft and lets the person crop it right away.</summary>
    private async Task<EditorArtwork?> ChooseImageAsync(double aspect, EditorArtwork? replacing)
    {
        var storage = TopLevel.GetTopLevel(this)?.StorageProvider;
        if (storage is null) return null;
        var files = await storage.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            AllowMultiple = false,
            Title = "Choose Image",
            FileTypeFilter = [new FilePickerFileType("Images") { Patterns = ["*.jpg", "*.jpeg", "*.png", "*.heic", "*.webp"] }],
        });
        if (files.Count == 0) return replacing;
        byte[] bytes;
        await using (var stream = await files[0].OpenReadAsync())
        {
            if (stream.CanSeek && stream.Length > 20 * 1024 * 1024)
            {
                problem.Text = "Choose a JPEG, PNG or HEIC image up to 20 MB and 24 megapixels.";
                problem.IsVisible = true;
                return replacing;
            }
            using var copy = new MemoryStream();
            await stream.CopyToAsync(copy);
            bytes = copy.ToArray();
        }
        EditorUploadSummary? upload = null;
        if (!await scope.RunAsync(async () => upload = await scope.Client.UploadArtworkAsync(mediaId, bytes), problem) || upload is null) return replacing;
        var crop = new CropSheet(scope, bytes, aspect, null);
        var cropped = await scope.Sheets.ShowAsync(crop);
        return new EditorArtwork(UploadId: upload.Id, Crop: cropped ? crop.Result : null);
    }

    private async Task ChooseFileAsync()
    {
        var picker = new ServerFilePicker(scope, mediaId);
        if (await scope.Sheets.ShowAsync(picker) && picker.Chosen is { } path)
        {
            relativeSource = path;
            Build();
        }
    }

    private MediaEditorValues Values()
    {
        var values = document!.Values;
        return values with
        {
            Title = title.Text?.Trim() ?? "",
            ReleaseYear = int.TryParse(year.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var y) ? y : string.IsNullOrWhiteSpace(year.Text) ? null : -1,
            Overview = string.IsNullOrWhiteSpace(overview.Text) ? null : overview.Text.Trim(),
            RuntimeMinutes = int.TryParse(runtime.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var r) ? r : string.IsNullOrWhiteSpace(runtime.Text) ? null : -1,
            FskAge = fsk.SelectedIndex > 0 ? MetadataEditing.FskAges[fsk.SelectedIndex - 1] : null,
            Genres = MetadataEditing.List(genres.Text),
            Studios = MetadataEditing.List(studios.Text),
            Country = string.IsNullOrWhiteSpace(country.Text) ? null : country.Text.Trim(),
            Credits = [.. credits.Select(c => c with { Name = c.Name.Trim() })],
            Poster = poster,
            Backdrop = backdrop,
        };
    }

    private async Task SaveAsync()
    {
        if (document is null) return;
        var values = Values();
        if (MetadataEditing.Problem(values) is { } failure)
        {
            problem.Text = failure;
            problem.IsVisible = true;
            return;
        }
        var overrides = MetadataEditing.Overrides(values, document.AutomaticValues, document.OverrideFields, reset);
        var request = new SaveMediaEditorRequest(document.Revision, values, overrides, relativeSource);
        if (await scope.RunAsync(() => scope.Client.SaveEditorAsync(mediaId, request), problem))
        {
            scope.Sheets.Close(true);
            return;
        }
        if (problem.Text is { } text && text.Contains("changed on the server", StringComparison.Ordinal)
            && await scope.Sheets.ConfirmAsync("Reload and discard this draft?", "Another device may have changed this title. Copy any changes you want to keep before reloading.", "Reload", destructive: true))
        {
            await LoadAsync();
        }
    }
}

/// <summary>Chooses a video file in the title's storage location on the server.</summary>
public sealed class ServerFilePicker : UserControl
{
    private readonly AdminScope scope;
    private readonly Guid mediaId;
    private readonly StackPanel list = new() { Spacing = 2 };
    private readonly TextBlock location = new() { Classes = { "subdued" } };
    private readonly TextBlock problem = Message();
    private readonly Button up = new() { Content = "Parent Folder", Classes = { "chip" }, IsEnabled = false };
    private string current = "";

    public ServerFilePicker(AdminScope scope, Guid mediaId)
    {
        this.scope = scope;
        this.mediaId = mediaId;
        Width = 560;
        Height = 460;
        var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
        cancel.Click += (_, _) => scope.Sheets.Close(false);
        up.Click += async (_, _) => await OpenAsync(current.Contains('/', StringComparison.Ordinal) ? current[..current.LastIndexOf('/')] : "");
        Content = new DockPanel
        {
            Children =
            {
                new StackPanel
                {
                    Spacing = 6,
                    Margin = new Thickness(0, 0, 0, 10),
                    Children = { new TextBlock { Text = "Choose Server Video", FontSize = 18, FontWeight = FontWeight.Bold }, new DockPanel { Children = { up.Also(b => DockPanel.SetDock(b, Dock.Right)), location } } },
                }.Also(p => DockPanel.SetDock(p, Dock.Top)),
                new StackPanel
                {
                    Spacing = 8,
                    Margin = new Thickness(0, 10, 0, 0),
                    Children = { problem, new DockPanel { Children = { cancel.Also(b => DockPanel.SetDock(b, Dock.Right)), Note("Only files in this title's server storage are available.") } } },
                }.Also(p => DockPanel.SetDock(p, Dock.Bottom)),
                new Border { Classes = { "card" }, Padding = new Thickness(6), Child = new ScrollViewer { Content = list } },
            },
        };
        Loading = OpenAsync(null);
    }

    internal Task Loading { get; }

    public string? Chosen { get; private set; }

    private async Task OpenAsync(string? path)
    {
        ServerFileListing? listing = null;
        if (!await scope.RunAsync(async () => listing = await scope.Client.EditorFilesAsync(mediaId, path), problem) || listing is null) return;
        current = listing.RelativePath;
        location.Text = "Storage location / " + current;
        up.IsEnabled = current.Length > 0;
        list.Children.Clear();
        foreach (var entry in listing.Entries)
        {
            var button = new Button
            {
                Content = (entry.IsDirectory ? "📁  " : "🎞  ") + entry.Name + (entry.Bytes is { } bytes ? "  ·  " + Bytes(bytes) : ""),
                Classes = { "link" },
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
            };
            AutomationProperties.SetName(button, entry.Name);
            button.Click += async (_, _) =>
            {
                if (entry.IsDirectory)
                {
                    await OpenAsync(entry.RelativePath);
                    return;
                }
                Chosen = entry.RelativePath;
                scope.Sheets.Close(true);
            };
            list.Children.Add(button);
        }
        if (listing.Entries.Count == 0) list.Children.Add(Note("No videos here."));
    }
}

/// <summary>
/// The Mac's ArtworkCropSheet, with sliders instead of dragging: zoom and position the frame,
/// rotate in quarter turns. The original image is kept; only the crop is saved.
/// </summary>
public sealed class CropSheet : UserControl
{
    private const double Area = 360;

    public CropSheet(AdminScope scope, byte[] image, double aspect, ArtworkCrop? existing)
    {
        Bitmap? bitmap = null;
        try
        {
            bitmap = new Bitmap(new MemoryStream(image));
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or NotSupportedException or IOException)
        {
        }
        var rotation = existing?.Rotation ?? 0;
        var zoom = new Slider { Minimum = 1, Maximum = 4, Value = 1, Width = 240 };
        var x = new Slider { Minimum = 0, Maximum = 1, Value = 0.5, Width = 240 };
        var y = new Slider { Minimum = 0, Maximum = 1, Value = 0.5, Width = 240 };
        AutomationProperties.SetName(zoom, "Zoom");
        AutomationProperties.SetName(x, "Horizontal Position");
        AutomationProperties.SetName(y, "Vertical Position");
        var canvas = new Canvas { ClipToBounds = true };
        var frame = new Border { BorderBrush = Brushes.White, BorderThickness = new Thickness(2), Background = new SolidColorBrush(Color.FromArgb(0x22, 0xFF, 0xFF, 0xFF)), CornerRadius = new CornerRadius(aspect == 1 ? 999 : 0) };
        var picture = new LayoutTransformControl { Child = new Image { Source = bitmap, Stretch = Stretch.Fill } };
        canvas.Children.Add(picture);
        canvas.Children.Add(frame);
        if (existing is { } crop && bitmap is not null)
        {
            // Restore the sliders from a saved crop of the same shape.
            var full = MetadataEditing.Crop(bitmap.PixelSize.Width, bitmap.PixelSize.Height, rotation, aspect, 1, 0, 0);
            zoom.Value = Math.Clamp(full.Width / crop.Width, 1, 4);
            x.Value = crop.Width < 1 ? Math.Clamp(crop.X / (1 - crop.Width), 0, 1) : 0.5;
            y.Value = crop.Height < 1 ? Math.Clamp(crop.Y / (1 - crop.Height), 0, 1) : 0.5;
        }
        void Layout()
        {
            if (bitmap is null) return;
            var (w, h) = rotation is 90 or 270 ? (bitmap.PixelSize.Height, bitmap.PixelSize.Width) : (bitmap.PixelSize.Width, bitmap.PixelSize.Height);
            var scale = Math.Min(Area / w, Area / h);
            var (shownWidth, shownHeight) = (w * scale, h * scale);
            canvas.Width = shownWidth;
            canvas.Height = shownHeight;
            picture.LayoutTransform = new RotateTransform(rotation);
            ((Image)picture.Child!).Width = rotation is 90 or 270 ? shownHeight : shownWidth;
            ((Image)picture.Child!).Height = rotation is 90 or 270 ? shownWidth : shownHeight;
            Result = MetadataEditing.Crop(bitmap.PixelSize.Width, bitmap.PixelSize.Height, rotation, aspect, zoom.Value, x.Value, y.Value);
            Canvas.SetLeft(frame, Result.X * shownWidth);
            Canvas.SetTop(frame, Result.Y * shownHeight);
            frame.Width = Result.Width * shownWidth;
            frame.Height = Result.Height * shownHeight;
        }
        foreach (var slider in new[] { zoom, x, y })
        {
            slider.PropertyChanged += (_, e) =>
            {
                if (e.Property == RangeBase.ValueProperty) Layout();
            };
        }
        var rotate = new Button { Content = "Rotate 90°", Classes = { "chip" } };
        rotate.Click += (_, _) =>
        {
            rotation = (rotation + 90) % 360;
            Layout();
        };
        var resetButton = new Button { Content = "Reset", Classes = { "chip" } };
        resetButton.Click += (_, _) =>
        {
            rotation = 0;
            zoom.Value = 1;
            x.Value = y.Value = 0.5;
            Layout();
        };
        var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
        cancel.Click += (_, _) => scope.Sheets.Close(false);
        var use = new Button { Content = "Use Crop", Classes = { "primary" }, IsDefault = true, IsEnabled = bitmap is not null };
        use.Click += (_, _) => scope.Sheets.Close(true);
        Layout();
        Content = new StackPanel
        {
            Spacing = 12,
            Width = 640,
            Children =
            {
                new TextBlock { Text = "Crop Image", FontSize = 18, FontWeight = FontWeight.Bold },
                bitmap is null ? Note("This image cannot be shown here. It is kept as it is.") : new DockPanel
                {
                    Children =
                    {
                        new StackPanel
                        {
                            Spacing = 8,
                            Margin = new Thickness(16, 0, 0, 0),
                            Children =
                            {
                                new TextBlock { Text = "Zoom" }, zoom,
                                new TextBlock { Text = "Left – Right" }, x,
                                new TextBlock { Text = "Top – Bottom" }, y,
                                Buttons(rotate, resetButton),
                                Note("Original retained"),
                            },
                        }.Also(p => DockPanel.SetDock(p, Dock.Right)),
                        new Border { Width = Area, Height = Area, Child = canvas.Also(c => { c.HorizontalAlignment = HorizontalAlignment.Center; c.VerticalAlignment = VerticalAlignment.Center; }) },
                    },
                },
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel, use } },
            },
        };
        DetachedFromVisualTree += (_, _) => bitmap?.Dispose();
    }

    public ArtworkCrop? Result { get; private set; }
}

/// <summary>The Mac's LibraryHealthView: duplicates, offline titles, unmatched metadata and excluded items.</summary>
public sealed class LibraryHealthSheet : UserControl
{
    private readonly AdminScope scope;
    private readonly IReadOnlyList<LibrarySummary> libraries;
    private readonly Action refreshLibrary;
    private readonly StackPanel content = new() { Spacing = 10 };
    private readonly TextBlock problem = Message();
    private int offlineDays = 30;
    private Guid? excludedLibrary;

    public LibraryHealthSheet(AdminScope scope, IReadOnlyList<LibrarySummary> libraries, Action refreshLibrary)
    {
        this.scope = scope;
        this.libraries = libraries;
        this.refreshLibrary = refreshLibrary;
        excludedLibrary = libraries.Count > 0 ? libraries[0].Id : null;
        Width = 760;
        Height = 600;
        var tabs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        string[] names = ["Duplicates", "Offline Titles", "Unmatched Metadata", "Excluded Items"];
        Func<Task>[] pages = [DuplicatesAsync, OfflineAsync, UnmatchedAsync, ExcludedAsync];
        for (var index = 0; index < names.Length; index++)
        {
            var page = pages[index];
            var tab = new ToggleButton { Content = names[index], Classes = { "chip" }, IsChecked = index == 0 };
            tab.Click += async (_, _) =>
            {
                foreach (var other in tabs.Children.OfType<ToggleButton>()) other.IsChecked = other == tab;
                await page();
            };
            tabs.Children.Add(tab);
        }
        var done = new Button { Content = "Done", Classes = { "primary" }, IsDefault = true };
        done.Click += (_, _) => scope.Sheets.Close(true);
        Content = new DockPanel
        {
            Children =
            {
                new StackPanel
                {
                    Spacing = 10,
                    Margin = new Thickness(0, 0, 0, 12),
                    Children = { new TextBlock { Text = "Library Health & Maintenance", FontSize = 20, FontWeight = FontWeight.Bold }, tabs },
                }.Also(p => DockPanel.SetDock(p, Dock.Top)),
                new StackPanel { Spacing = 8, Margin = new Thickness(0, 12, 0, 0), Children = { problem, done.Also(d => d.HorizontalAlignment = HorizontalAlignment.Right) } }.Also(p => DockPanel.SetDock(p, Dock.Bottom)),
                new ScrollViewer { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = content },
            },
        };
        Loading = DuplicatesAsync();
    }

    internal Task Loading { get; }

    private void Start(string heading, string? detail, string loading)
    {
        content.Children.Clear();
        content.Children.Add(new TextBlock { Text = heading, FontSize = 16, FontWeight = FontWeight.SemiBold });
        if (detail is not null) content.Children.Add(Note(detail));
        content.Children.Add(Note(loading));
    }

    private void Empty(string title, string detail)
    {
        content.Children.RemoveAt(content.Children.Count - 1);
        content.Children.Add(new StackPanel
        {
            Spacing = 4,
            Margin = new Thickness(0, 30),
            HorizontalAlignment = HorizontalAlignment.Center,
            Children = { new TextBlock { Text = title, FontWeight = FontWeight.SemiBold, HorizontalAlignment = HorizontalAlignment.Center }, Note(detail) },
        });
    }

    private async Task DuplicatesAsync()
    {
        Start("Duplicate Titles", null, "Analyzing duplicates…");
        IReadOnlyList<DuplicateGroup> groups = [];
        if (!await scope.RunAsync(async () => groups = await scope.Client.DuplicatesAsync(), problem)) return;
        if (groups.Count == 0)
        {
            Empty("No Duplicates Found", "Your library has no duplicate media entries.");
            return;
        }
        content.Children.RemoveAt(content.Children.Count - 1);
        foreach (var group in groups)
        {
            var card = new StackPanel { Spacing = 6, Children = { new TextBlock { Text = group.Title + (group.Year is { } year ? $" ({year})" : "") + $" · {group.Items.Count} versions", FontWeight = FontWeight.SemiBold } } };
            var available = group.Items.FirstOrDefault(item => item.Availability == MediaAvailability.Available);
            foreach (var item in group.Items)
            {
                var row = new DockPanel
                {
                    Children =
                    {
                        new StackPanel
                        {
                            Children =
                            {
                                new TextBlock { Text = item.FileName, TextTrimming = TextTrimming.CharacterEllipsis },
                                Note((item.FileSize is { } size ? Bytes(size) + " · " : "") + (item.Availability == MediaAvailability.Available ? "Available" : "Missing")),
                            },
                        },
                    },
                };
                if (item.Availability != MediaAvailability.Available && available is not null)
                {
                    row.Children.Insert(0, Button("Move Watch Data…", async () =>
                    {
                        if (!await scope.Sheets.ConfirmAsync("Move watch data to the available copy?",
                            $"Favorites, progress, viewing history and collection memberships of every profile move to “{available.FileName}”. The missing copy is then removed from Aurelia. No file is touched.",
                            "Move and Remove Missing Copy", destructive: true)) return;
                        if (await scope.RunAsync(() => scope.Client.MergeAsync(new MergeMediaRequest(item.Id, available.Id)), problem))
                        {
                            refreshLibrary();
                            await DuplicatesAsync();
                        }
                    }).Also(b => DockPanel.SetDock(b, Dock.Right)));
                }
                card.Children.Add(row);
            }
            content.Children.Add(new Border { Classes = { "card" }, Padding = new Thickness(12), Child = card });
        }
    }

    private async Task OfflineAsync()
    {
        Start("Missing & Offline Titles", "Titles whose file has not been found for a while. Removing one deletes its favorites, progress and history for every profile; the file is never touched.", "Checking offline titles…");
        content.Children.Insert(2, Choice("Offline for", null, [(7, "7+ Days"), (30, "30+ Days"), (90, "90+ Days")], offlineDays, async days =>
        {
            offlineDays = days;
            await OfflineAsync();
        }).Also(r => r.Margin = new Thickness(0)));
        IReadOnlyList<OfflineTitleSummary> titles = [];
        if (!await scope.RunAsync(async () => titles = await scope.Client.OfflineAsync(offlineDays), problem)) return;
        if (titles.Count == 0)
        {
            Empty("No Offline Titles", "All media items in your library are reachable.");
            return;
        }
        content.Children.RemoveAt(content.Children.Count - 1);
        foreach (var title in titles)
        {
            var remove = Button("Remove…", async () =>
            {
                if (!await scope.Sheets.ConfirmAsync($"Remove “{title.Title}”?", "Its favorites, progress and history are removed for every profile. The file is never touched.", "Remove from Library", destructive: true)) return;
                if (await scope.RunAsync(() => scope.Client.RemoveEntryAsync(title.Id), problem))
                {
                    refreshLibrary();
                    await OfflineAsync();
                }
            }, "destructive");
            AutomationProperties.SetName(remove, "Remove " + title.Title);
            content.Children.Add(new DockPanel
            {
                Children =
                {
                    remove.Also(b => DockPanel.SetDock(b, Dock.Right)),
                    new StackPanel
                    {
                        Children =
                        {
                            new TextBlock { Text = title.Title + (title.Year is { } year ? $" ({year})" : "") },
                            Note($"Library: {title.LibraryName} · {title.FileName} · Offline for {title.DaysOffline} days"),
                        },
                    },
                },
            });
        }
    }

    private async Task UnmatchedAsync()
    {
        Start("Unmatched Metadata", "Files in your storage locations that have not been identified by TMDB.", "Finding unmatched titles…");
        IReadOnlyList<UnmatchedTitleSummary> titles = [];
        if (!await scope.RunAsync(async () => titles = await scope.Client.UnmatchedAsync(), problem)) return;
        if (titles.Count == 0)
        {
            Empty("All Titles Matched", "Every title in your library is matched to TMDB metadata.");
            return;
        }
        content.Children.RemoveAt(content.Children.Count - 1);
        foreach (var title in titles)
        {
            var match = Button("Match…", async () =>
            {
                if (await scope.Sheets.ShowAsync(new MetadataMatchSheet(scope, title.Id, title.Title)))
                {
                    refreshLibrary();
                    await UnmatchedAsync();
                }
            });
            AutomationProperties.SetName(match, "Match " + title.Title);
            content.Children.Add(new DockPanel
            {
                Children =
                {
                    match.Also(b => DockPanel.SetDock(b, Dock.Right)),
                    new StackPanel { Children = { new TextBlock { Text = title.Title + (title.Year is { } year ? $" ({year})" : "") }, Note($"{title.FileName} · {title.IssueReason}") } },
                },
            });
        }
    }

    private async Task ExcludedAsync()
    {
        Start("Excluded Items", "Removed sources stay excluded from scans until you explicitly reimport them.", "Loading excluded items…");
        if (libraries.Count == 0)
        {
            Empty("No Storage Locations", "Add a storage location first.");
            return;
        }
        content.Children.Insert(2, Choice("Storage Location", null, [.. libraries.Select(l => ((Guid?)l.Id, l.Name))], excludedLibrary, async id =>
        {
            excludedLibrary = id;
            await ExcludedAsync();
        }).Also(r => r.Margin = new Thickness(0)));
        if (excludedLibrary is not { } library) return;
        IReadOnlyList<ExcludedMediaSummary> excluded = [];
        if (!await scope.RunAsync(async () => excluded = await scope.Client.ExclusionsAsync(library), problem)) return;
        if (excluded.Count == 0)
        {
            Empty("No Excluded Items", "Nothing in this location is excluded.");
            return;
        }
        content.Children.RemoveAt(content.Children.Count - 1);
        foreach (var item in excluded)
        {
            var reimport = Button("Reimport…", async () =>
            {
                if (!await scope.Sheets.ConfirmAsync("Reimport this source?",
                    "This clears the source exclusion and starts a scan. Previously removed personal metadata and playback history are not restored.", "Reimport with Scan", destructive: false)) return;
                if (await scope.RunAsync(() => scope.Client.ReimportAsync(library, item.Id), problem))
                {
                    refreshLibrary();
                    await ExcludedAsync();
                }
            });
            AutomationProperties.SetName(reimport, "Reimport " + item.RelativePath);
            content.Children.Add(new DockPanel
            {
                Children =
                {
                    reimport.Also(b => DockPanel.SetDock(b, Dock.Right)),
                    new TextBlock { Text = (item.IsDirectory ? "📁 " : "") + item.RelativePath, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis },
                },
            });
        }
    }
}

/// <summary>The Metadata settings: TMDB with the owner's token, enrichment, the review queue and artwork.</summary>
public sealed class MetadataPage : StackPanel
{
    private readonly AdminScope scope;
    private readonly TextBlock message = Message();
    private readonly StackPanel provider = new() { Spacing = 10 };

    public MetadataPage(AdminScope scope)
    {
        this.scope = scope;
        Spacing = 22;
        Children.Add(message);
        Children.Add(Section("Movie & TV Information", Block(
            Note("Use your own TMDB API Read Access Token to download metadata and artwork. File paths are never sent."),
            provider)));
        Loading = ReloadAsync();
    }

    internal Task Loading { get; private set; }

    public async Task ReloadAsync()
    {
        provider.Children.Clear();
        var queue = Button("Review Queue", () => scope.Sheets.ShowAsync(new ReviewQueueSheet(scope)));
        if (!scope.IsOwner)
        {
            provider.Children.Add(Note("An owner manages the metadata provider and its credentials."));
            provider.Children.Add(Buttons(Button("Enrich Shared Libraries", EnrichAsync, "primary"), queue));
            provider.Children.Add(await JobAsync());
            return;
        }
        MetadataProviderStatus? status = null;
        if (!await scope.RunAsync(async () => status = await scope.Client.ProviderAsync(), message) || status is null) return;
        if (status.HasToken)
        {
            provider.Children.Add(Value("TMDB", status.Enabled ? "Enabled" : "Disabled").Also(r => r.Margin = new Thickness(0)));
            provider.Children.Add(Value("Artwork", Bytes(status.ArtworkBytes)).Also(r => r.Margin = new Thickness(0)));
            provider.Children.Add(Note(status.Attribution));
            provider.Children.Add(Buttons(
                Button("Enrich Library", EnrichAsync, "primary"),
                queue,
                Button("Remove Unused Artwork", async () =>
                {
                    if (await scope.RunAsync(() => scope.Client.PruneArtworkAsync(), message)) await ReloadAsync();
                }),
                Button("Remove TMDB Token", async () =>
                {
                    if (!await scope.Sheets.ConfirmAsync("Remove the TMDB token?", "Metadata already downloaded stays. New titles are not enriched until you add a token again.", "Remove TMDB Token", destructive: true)) return;
                    if (await scope.RunAsync(() => scope.Client.RemoveProviderTokenAsync(), message)) await ReloadAsync();
                }, "destructive")));
            provider.Children.Add(await JobAsync());
            return;
        }
        var token = new TextBox { PasswordChar = '•', PlaceholderText = "TMDB API Read Access Token" };
        AutomationProperties.SetName(token, "TMDB API Read Access Token");
        provider.Children.Add(token);
        provider.Children.Add(Button("Enable TMDB", async () =>
        {
            var value = token.Text?.Trim() ?? "";
            token.Text = "";
            if (value.Length == 0) return;
            if (await scope.RunAsync(() => scope.Client.SaveProviderAsync(new UpdateMetadataProviderRequest(true, "en-US", value)), message)) await ReloadAsync();
        }, "primary"));
    }

    private async Task EnrichAsync()
    {
        MetadataJobSummary? started = null;
        if (await scope.RunAsync(async () => started = await scope.Client.StartMetadataJobAsync(new StartMetadataJobRequest()), message))
        {
            followedJob = started?.Id;
            await ReloadAsync();
        }
    }

    private readonly StackPanel jobPanel = new() { Spacing = 4 };
    private Guid? followedJob;
    private bool polling;

    /// <summary>The running job with live progress; once a job started here ends, a plain "Done" line.</summary>
    private async Task<Control> JobAsync()
    {
        await RefreshJobAsync();
        return jobPanel;
    }

    private async Task RefreshJobAsync()
    {
        IReadOnlyList<MetadataJobSummary> jobs = [];
        await scope.RunAsync(async () => jobs = await scope.Client.MetadataJobsAsync(activeOnly: true));
        var job = jobs.Count > 0 ? jobs[0] : null;
        if (job is null && followedJob is { } id)
        {
            IReadOnlyList<MetadataJobSummary> recent = [];
            await scope.RunAsync(async () => recent = await scope.Client.MetadataJobsAsync(activeOnly: false));
            job = recent.FirstOrDefault(candidate => candidate.Id == id);
        }
        ShowJob(job);
        if (job is { State: MetadataJobState.Queued or MetadataJobState.Running } && !polling) _ = PollJobAsync();
    }

    private async Task PollJobAsync()
    {
        polling = true;
        try
        {
            // Polls while the page is shown; a page that never appears or is closed stops it.
            for (var hidden = 0; hidden < 5;)
            {
                await Task.Delay(TimeSpan.FromSeconds(1));
                if (TopLevel.GetTopLevel(jobPanel) is null)
                {
                    hidden++;
                    continue;
                }
                hidden = 0;
                IReadOnlyList<MetadataJobSummary> jobs = [];
                if (!await scope.RunAsync(async () => jobs = await scope.Client.MetadataJobsAsync(activeOnly: true))) return;
                if (jobs.Count > 0 && jobs[0] is { } running)
                {
                    followedJob = running.Id;
                    ShowJob(running);
                    continue;
                }
                await RefreshJobAsync();
                return;
            }
        }
        finally
        {
            polling = false;
        }
    }

    private void ShowJob(MetadataJobSummary? job)
    {
        jobPanel.Children.Clear();
        if (job is null) return;
        if (MetadataEditing.FinishedSummary(job) is { } summary)
        {
            var done = job.State == MetadataJobState.Completed;
            var color = new SolidColorBrush(Color.Parse(done ? "#30D158" : "#FF9F0A"));
            jobPanel.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 8,
                Children =
                {
                    new PathIcon { Data = Application.Current?.FindResource(done ? "IconCheck" : "IconOffline") as Geometry, Width = 14, Height = 14, Foreground = color, VerticalAlignment = VerticalAlignment.Center },
                    new TextBlock { Text = summary, Foreground = color, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center },
                },
            });
            AutomationProperties.SetName(jobPanel, summary);
            return;
        }
        followedJob = job.Id;
        jobPanel.Children.Add(new TextBlock { Text = $"Finding metadata: {job.ItemsProcessed} of {job.ItemsTotal}" });
        jobPanel.Children.Add(new ProgressBar { Minimum = 0, Maximum = Math.Max(1, job.ItemsTotal), Value = job.ItemsProcessed, Height = 4 });
        if (WaitingStatus(job) is { } waiting) jobPanel.Children.Add(Note(waiting));
        if (job.ItemsSkipped > 0) jobPanel.Children.Add(Note($"{job.ItemsSkipped} skipped"));
    }

    internal static string? WaitingStatus(MetadataJobSummary job)
    {
        if (job.State is not (MetadataJobState.Queued or MetadataJobState.Running) || (job.WaitReason is null && job.NextAttemptAt is null)) return null;
        var reason = job.WaitReason switch
        {
            "tmdb" => "Waiting for TMDB",
            "storage" => "Waiting for writable storage",
            _ => "Waiting",
        };
        return job.NextAttemptAt is { } next ? $"{reason} · Retry at {next.ToLocalTime():HH:mm}" : reason;
    }
}
