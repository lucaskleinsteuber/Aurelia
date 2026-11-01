using Aurelia.Contracts;
using Aurelia.Linux.Core.Management;
using Aurelia.Linux.Core.Settings;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using static Aurelia.Linux.Management.AdminScope;
using static Aurelia.Linux.Settings.SettingsRows;

namespace Aurelia.Linux.Management;

/// <summary>A storage location to add: a folder on the server, with an optional name and its kind.</summary>
public sealed record StorageLocationDraft(string Path, string? Name, LibraryKind Kind)
{
    public string SuggestedName => System.IO.Path.GetFileName(Path.TrimEnd('/', '\\')) is { Length: > 0 } name ? name : Path;
}

/// <summary>
/// The Library settings for owners and administrators who manage the whole library, as the Mac's
/// Library category and Manage Media window: storage locations on the server with scans, monitoring
/// and import previews, trailer reviews, Library Health, offline titles and the Danger Zone.
/// Media files are only ever read: removing a location never changes them.
/// </summary>
public sealed class LibraryPage : StackPanel
{
    private readonly AdminScope scope;
    private readonly GeneralPreferences preferences;
    private readonly Action refreshLibrary;
    private readonly TextBlock message = Message();
    private readonly StackPanel locations = new() { Spacing = 0 };
    private readonly StackPanel scans = new() { Spacing = 6 };
    private readonly StackPanel reviews = new() { Spacing = 8 };
    private readonly StackPanel drafts = new() { Spacing = 6 };
    private readonly List<StorageLocationDraft> pending = [];
    private readonly DispatcherTimer poll;
    private IReadOnlyList<LibrarySummary> libraries = [];
    private LibraryKind newKind = LibraryKind.Automatic;

    public LibraryPage(AdminScope scope, GeneralPreferences preferences, Action refreshLibrary)
    {
        this.scope = scope;
        this.preferences = preferences;
        this.refreshLibrary = refreshLibrary;
        Spacing = 22;
        var name = new TextBox { PlaceholderText = "Library name (optional)", Width = 260 };
        AutomationProperties.SetName(name, "Library Name");
        var analyze = Button("Analyze and Preview", () => AddAsync(name), "primary");
        Children.Add(message);
        Children.Add(Section("Storage Locations", Block(
            Note("Aurelia recognizes movies and TV shows automatically in each location. Automatic monitoring keeps reachable locations current. Offline media remains in your library."),
            locations,
            new TextBlock { Text = "Add Storage Locations", FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 8, 0, 0) },
            Note("Choose one or more folders or drives on the server. Aurelia reads their directory structure and leaves every media file untouched."),
            drafts,
            new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 10,
                Children =
                {
                    name,
                    Choice("Type", null, [(LibraryKind.Automatic, "Movies and TV Shows"), (LibraryKind.Movies, "Movies"), (LibraryKind.TvShows, "TV Shows")], newKind, kind => newKind = kind).Also(r => r.Margin = new Thickness(0)),
                },
            },
            Buttons(Button("Choose Folders on the Server…", ChooseFoldersAsync), analyze))));
        Children.Add(Section("Scan Activity", Block(scans)));
        Children.Add(Section("Trailer Reviews", Block(Note("Review trailers that could not be safely matched to a movie."), reviews)));
        Children.Add(Section("Library Health & Maintenance", Block(
            Note("Inspect duplicate titles, manage missing or offline files, resolve unmatched metadata and reimport excluded items."),
            Button("Open Library Health…", () => scope.Sheets.ShowAsync(new LibraryHealthSheet(scope, libraries, refreshLibrary))))));
        Children.Add(Section("Catalog Visibility",
            Toggle("Hide Offline Titles", "On this computer, hides titles whose file or drive is unavailable. Their details and progress stay.",
                preferences.HideOfflineTitles, value => { preferences.HideOfflineTitles = value; refreshLibrary(); })));
        Children.Add(DangerZone());
        poll = new DispatcherTimer(TimeSpan.FromSeconds(3), DispatcherPriority.Background, async (_, _) => await ShowScansAsync());
        AttachedToVisualTree += (_, _) => poll.Start();
        DetachedFromVisualTree += (_, _) => poll.Stop();
        ShowDrafts();
        Loading = ReloadAsync();
    }

    internal Task Loading { get; private set; }

    private ManagementClient Client => scope.Client;

    public async Task ReloadAsync()
    {
        await scope.RunAsync(async () => libraries = await Client.LibrariesAsync(), message);
        FillLocations();
        await ShowScansAsync();
        await ShowReviewsAsync();
    }

    private void FillLocations()
    {
        locations.Children.Clear();
        if (libraries.Count == 0) locations.Children.Add(Note("No storage locations yet."));
        foreach (var library in libraries)
        {
            var state = library.ImportPreviewRequired ? "Awaiting import confirmation" : Availability(library);
            var scan = Button("Rescan", async () => { if (await scope.RunAsync(() => Client.ScanAsync(library.Id), message)) await ShowScansAsync(); });
            scan.IsEnabled = !library.ImportPreviewRequired;
            AutomationProperties.SetName(scan, "Rescan " + library.Name);
            var preview = Button(library.ImportPreviewRequired ? "Review Import…" : "Preview…", () => PreviewAsync(library), library.ImportPreviewRequired ? "primary" : "chip");
            AutomationProperties.SetName(preview, "Import Preview " + library.Name);
            var remove = Button("Remove", () => RemoveAsync(library), "destructive");
            AutomationProperties.SetName(remove, "Remove " + library.Name);
            var monitoring = new CheckBox { Content = "Automatically detect changes in this storage location", IsChecked = library.MonitoringEnabled, FontSize = 12 };
            monitoring.IsCheckedChanged += async (_, _) =>
            {
                if (!await scope.RunAsync(() => Client.SetMonitoringAsync(library.Id, monitoring.IsChecked == true), message)) monitoring.IsChecked = library.MonitoringEnabled;
            };
            locations.Children.Add(new StackPanel
            {
                Spacing = 4,
                Margin = new Thickness(0, 6),
                Children =
                {
                    new DockPanel
                    {
                        Children =
                        {
                            Buttons(preview, scan, remove).Also(b => { DockPanel.SetDock(b, Dock.Right); b.VerticalAlignment = VerticalAlignment.Center; }),
                            new StackPanel
                            {
                                Spacing = 2,
                                Children =
                                {
                                    new TextBlock { Text = library.Name, FontWeight = FontWeight.SemiBold },
                                    new TextBlock { Text = library.Path, Classes = { "subdued" }, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis },
                                    new TextBlock { Text = $"{KindName(library.Kind)} · {state}", Classes = { "subdued" }, FontSize = 12 },
                                },
                            },
                        },
                    },
                    monitoring,
                },
            });
        }
    }

    internal static string Availability(LibrarySummary library) => library.Health switch
    {
        LibraryHealthStatus.WaitingForStorage => "Waiting for storage",
        LibraryHealthStatus.PermissionDenied => "Aurelia Server may not read this folder",
        LibraryHealthStatus.Error => library.LastError ?? "Error",
        _ => library.Availability switch
        {
            LibraryAvailability.Available => "Available",
            LibraryAvailability.Unavailable => "Offline",
            LibraryAvailability.Error => library.LastError ?? "Error",
            _ => "Not checked yet",
        },
    };

    internal static string KindName(LibraryKind kind) => kind switch
    {
        LibraryKind.Movies => "Movies",
        LibraryKind.TvShows => "TV Shows",
        _ => "Movies and TV Shows",
    };

    private void ShowDrafts()
    {
        drafts.Children.Clear();
        foreach (var draft in pending.ToList())
        {
            var remove = Button("Remove", () =>
            {
                pending.Remove(draft);
                ShowDrafts();
                return Task.CompletedTask;
            });
            AutomationProperties.SetName(remove, "Remove " + draft.SuggestedName);
            drafts.Children.Add(new DockPanel
            {
                Children =
                {
                    remove.Also(b => DockPanel.SetDock(b, Dock.Right)),
                    new StackPanel { Children = { new TextBlock { Text = draft.SuggestedName }, new TextBlock { Text = draft.Path, Classes = { "subdued" }, FontSize = 12 } } },
                },
            });
        }
    }

    private async Task ChooseFoldersAsync()
    {
        var picker = new ServerFolderPicker(scope);
        if (await scope.Sheets.ShowAsync(picker) && picker.Chosen is { } path && pending.All(d => d.Path != path))
        {
            pending.Add(new StorageLocationDraft(path, null, newKind));
            ShowDrafts();
        }
    }

    /// <summary>Registers the chosen folders, each waiting for an import preview, and opens the first preview.</summary>
    private async Task AddAsync(TextBox name)
    {
        if (pending.Count == 0)
        {
            message.Text = "Choose a folder on the server first.";
            message.IsVisible = true;
            return;
        }
        LibrarySummary? first = null;
        var label = string.IsNullOrWhiteSpace(name.Text) ? null : name.Text.Trim();
        var worked = await scope.RunAsync(async () =>
        {
            foreach (var draft in pending.ToList())
            {
                var created = await Client.CreateLibraryAsync(new CreateLibraryRequest(pending.Count == 1 ? label : null, draft.Path, newKind, RequireImportPreview: true));
                first ??= created;
                pending.Remove(draft);
            }
        }, message);
        ShowDrafts();
        if (worked) name.Text = "";
        await ReloadAsync();
        if (first is not null) await PreviewAsync(libraries.FirstOrDefault(l => l.Id == first.Id) ?? first);
    }

    private async Task PreviewAsync(LibrarySummary library)
    {
        var sheet = new ImportPreviewSheet(scope, new ImportPreviewModel(Client, library));
        if (await scope.Sheets.ShowAsync(sheet))
        {
            refreshLibrary();
        }
        await ReloadAsync();
    }

    private async Task RemoveAsync(LibrarySummary library)
    {
        if (!await scope.Sheets.ConfirmAsync($"Remove {library.Name}?",
            "Its titles leave Aurelia. Removing a location never deletes or changes media files.", "Remove from Aurelia", destructive: true)) return;
        if (await scope.RunAsync(() => Client.RemoveLibraryAsync(library.Id), message))
        {
            refreshLibrary();
            await ReloadAsync();
        }
    }

    private async Task ShowScansAsync()
    {
        IReadOnlyList<LibraryScanSummary> active = [];
        if (!await scope.RunAsync(async () => active = await Client.ActiveScansAsync())) return;
        scans.Children.Clear();
        if (active.Count == 0)
        {
            scans.Children.Add(Note("No scans are running."));
            return;
        }
        foreach (var scan in active)
        {
            var name = libraries.FirstOrDefault(l => l.Id == scan.LibraryId)?.Name ?? "Storage Location";
            var progress = new ProgressBar { Minimum = 0, Maximum = Math.Max(1, scan.FilesDiscovered), Value = scan.FilesProcessed, IsIndeterminate = scan.FilesDiscovered == 0, Height = 4 };
            var cancel = Button("Cancel", async () => { if (await scope.RunAsync(() => Client.CancelScanAsync(scan.Id), message)) await ShowScansAsync(); });
            AutomationProperties.SetName(cancel, "Cancel Scan " + name);
            scans.Children.Add(new StackPanel
            {
                Spacing = 4,
                Children =
                {
                    new DockPanel
                    {
                        Children =
                        {
                            cancel.Also(b => DockPanel.SetDock(b, Dock.Right)),
                            new TextBlock { Text = $"{name} · {ScanPhase(scan)}", VerticalAlignment = VerticalAlignment.Center },
                        },
                    },
                    progress,
                    Note($"Found {scan.FilesDiscovered} · Added {scan.AddedFiles} · Updated {scan.UpdatedFiles} · Missing {scan.MissingFiles} · Skipped {scan.SkippedFiles}"),
                },
            });
        }
    }

    internal static string ScanPhase(LibraryScanSummary scan) => scan.State switch
    {
        LibraryScanState.WaitingForStorage => "Waiting for Storage",
        LibraryScanState.Queued => "Queued",
        LibraryScanState.Running => scan.Phase is { Length: > 0 } phase && phase != "Queued" ? phase : "Scanning",
        _ => scan.State.ToString(),
    } + (scan.Attempt > 1 ? $" · Attempt {scan.Attempt}" : "");

    private async Task ShowReviewsAsync()
    {
        var all = new List<(LibrarySummary Library, LibraryImportReviewSummary Review)>();
        await scope.RunAsync(async () =>
        {
            foreach (var library in libraries)
            {
                foreach (var review in await Client.ImportReviewsAsync(library.Id))
                {
                    if (review.State == LibraryImportReviewState.Pending) all.Add((library, review));
                }
            }
        }, message);
        reviews.Children.Clear();
        if (all.Count == 0) reviews.Children.Add(Note("Nothing to review."));
        foreach (var (library, review) in all)
        {
            var search = new TextBox { PlaceholderText = "Search movies in this location", Width = 260 };
            AutomationProperties.SetName(search, "Search Movies for " + review.DetectedTitle);
            var results = new StackPanel { Spacing = 4 };
            var problem = Message();
            reviews.Children.Add(new StackPanel
            {
                Spacing = 6,
                Children =
                {
                    new TextBlock { Text = review.DetectedTitle, FontWeight = FontWeight.SemiBold },
                    Note(review.RelativePath + " · " + review.Reason),
                    new StackPanel
                    {
                        Orientation = Orientation.Horizontal,
                        Spacing = 8,
                        Children =
                        {
                            search,
                            Button("Search Movies", async () =>
                            {
                                results.Children.Clear();
                                var query = search.Text?.Trim() ?? "";
                                var movies = (scope.Session.Library?.Catalog ?? [])
                                    .Where(item => item.Kind == MediaKind.Movie && item.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase))
                                    .Take(8).ToList();
                                if (movies.Count == 0) results.Children.Add(Note("No movies matched that search in this location."));
                                foreach (var movie in movies)
                                {
                                    results.Children.Add(new DockPanel
                                    {
                                        Children =
                                        {
                                            Button("Assign to Movie", async () =>
                                            {
                                                if (await scope.RunAsync(() => Client.ResolveImportReviewAsync(library.Id, review.Id, new UpdateLibraryImportReviewRequest(LibraryImportReviewAction.AssignToMovie, movie.Id)), problem))
                                                    await ShowReviewsAsync();
                                            }).Also(b => DockPanel.SetDock(b, Dock.Right)),
                                            new TextBlock { Text = movie.Title + (movie.Year is { } year ? $" ({year})" : ""), VerticalAlignment = VerticalAlignment.Center },
                                        },
                                    });
                                }
                                await Task.CompletedTask;
                            }),
                            Button("Ignore", async () =>
                            {
                                if (await scope.RunAsync(() => Client.ResolveImportReviewAsync(library.Id, review.Id, new UpdateLibraryImportReviewRequest(LibraryImportReviewAction.Ignore)), problem))
                                    await ShowReviewsAsync();
                            }),
                        },
                    },
                    results,
                    problem,
                },
            });
        }
    }

    private StackPanel DangerZone()
    {
        var reset = Button("Reset Library…", async () =>
        {
            if (await scope.Sheets.ShowAsync(new LibraryResetSheet(scope, libraries)))
            {
                refreshLibrary();
                await ReloadAsync();
            }
        }, "destructive");
        AutomationProperties.SetName(reset, "Reset Library");
        return new StackPanel
        {
            Spacing = 8,
            Children =
            {
                new TextBlock { Text = "Danger Zone", FontWeight = FontWeight.SemiBold, Foreground = new SolidColorBrush(Color.Parse("#FF6B6B")), Margin = new Thickness(4, 0) },
                new Border
                {
                    Classes = { "card" },
                    BorderBrush = new SolidColorBrush(Color.FromArgb(0x66, 0xFF, 0x6B, 0x6B)),
                    BorderThickness = new Thickness(1),
                    Child = Block(
                        Note("These operations are destructive and cannot be undone. They require the Server Password."),
                        new DockPanel
                        {
                            Children =
                            {
                                reset.Also(b => { DockPanel.SetDock(b, Dock.Right); b.VerticalAlignment = VerticalAlignment.Center; }),
                                new StackPanel
                                {
                                    Spacing = 2,
                                    Children =
                                    {
                                        new TextBlock { Text = "Reset Media Library", FontWeight = FontWeight.SemiBold },
                                        Note("Removes all indexed titles, scan history, progress and metadata from Aurelia. Media files on disk are never touched."),
                                    },
                                },
                            },
                        }),
                },
            },
        };
    }
}

/// <summary>The Mac's ServerFolderPicker: folders listed from the server, one level at a time.</summary>
public sealed class ServerFolderPicker : UserControl
{
    private readonly AdminScope scope;
    private readonly StackPanel list = new() { Spacing = 2 };
    private readonly TextBlock location = new() { Classes = { "subdued" }, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock problem = Message();
    private readonly Button choose = new() { Content = "Choose This Folder", Classes = { "primary" }, IsDefault = true, IsEnabled = false };
    private readonly Button up = new() { Content = "Parent Folder", Classes = { "chip" }, IsEnabled = false };
    private ServerFolderListing? listing;

    public ServerFolderPicker(AdminScope scope)
    {
        this.scope = scope;
        Width = 560;
        Height = 480;
        var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
        cancel.Click += (_, _) => scope.Sheets.Close(false);
        choose.Click += (_, _) =>
        {
            Chosen = listing?.Path;
            scope.Sheets.Close(Chosen is not null);
        };
        up.Click += async (_, _) => await OpenAsync(listing?.Parent);
        Content = new DockPanel
        {
            Children =
            {
                new StackPanel
                {
                    Spacing = 6,
                    Margin = new Thickness(0, 0, 0, 10),
                    Children =
                    {
                        new TextBlock { Text = $"Folders on {scope.ServerName}", FontSize = 18, FontWeight = FontWeight.Bold },
                        new DockPanel { Children = { up.Also(b => DockPanel.SetDock(b, Dock.Right)), location } },
                    },
                }.Also(p => DockPanel.SetDock(p, Dock.Top)),
                new StackPanel
                {
                    Spacing = 8,
                    Margin = new Thickness(0, 10, 0, 0),
                    Children =
                    {
                        problem,
                        new DockPanel
                        {
                            Children =
                            {
                                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { cancel, choose } }.Also(p => DockPanel.SetDock(p, Dock.Right)),
                                Note("Folders are listed from the server. Their media files are only read."),
                            },
                        },
                    },
                }.Also(p => DockPanel.SetDock(p, Dock.Bottom)),
                new Border { Classes = { "card" }, Padding = new Thickness(6), Child = new ScrollViewer { Content = list } },
            },
        };
        Loading = OpenAsync(null);
    }

    internal Task Loading { get; }

    public string? Chosen { get; private set; }

    internal async Task OpenAsync(string? path)
    {
        ServerFolderListing? next = null;
        if (!await scope.RunAsync(async () => next = await scope.Client.FoldersAsync(path), problem) || next is null) return;
        listing = next;
        location.Text = next.Path ?? "Usual places for drives and media";
        up.IsEnabled = next.Path is not null;
        choose.IsEnabled = next.Path is not null;
        var folderName = next.Path is null ? null : System.IO.Path.GetFileName(next.Path.TrimEnd('/'));
        choose.Content = next.Path is null ? "Choose This Folder" : $"Choose “{(string.IsNullOrEmpty(folderName) ? next.Path : folderName)}”";
        list.Children.Clear();
        foreach (var folder in next.Folders)
        {
            var open = new Button { Content = "📁  " + folder.Name, Classes = { "link" }, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
            AutomationProperties.SetName(open, folder.Name);
            open.Click += async (_, _) => await OpenAsync(folder.Path);
            list.Children.Add(open);
        }
        if (next.Folders.Count == 0) list.Children.Add(Note("No folders here."));
    }
}

/// <summary>
/// The Mac's ImportPreviewView: every file and folder the server recognized, filters and search,
/// assignments for selected items, and confirmation. Nothing is imported before confirming.
/// </summary>
public sealed class ImportPreviewSheet : UserControl
{
    private readonly AdminScope scope;
    private readonly ImportPreviewModel model;
    private readonly StackPanel rows = new() { Spacing = 2 };
    private readonly TextBlock counts = new() { Classes = { "subdued" }, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock problem = Message();
    private readonly TextBox search = new() { PlaceholderText = "Search titles, folders or filenames", Width = 300 };
    private readonly HashSet<string> selected = [];
    private readonly Button edit = new() { Content = "Edit Assignment…", Classes = { "chip" }, IsEnabled = false };
    private readonly Button automatic = new() { Content = "Use Automatic Detection", Classes = { "chip" }, IsEnabled = false };
    private readonly Button confirm;
    private ImportPreviewFilter filter = ImportPreviewFilter.All;

    public ImportPreviewSheet(AdminScope scope, ImportPreviewModel model)
    {
        this.scope = scope;
        this.model = model;
        Width = 820;
        Height = 600;
        AutomationProperties.SetName(search, "Search Import Preview");
        search.TextChanged += (_, _) => Fill();
        confirm = new Button { Content = model.ConfirmLabel, Classes = { "primary" }, IsEnabled = false };
        AutomationProperties.SetName(confirm, "Confirm Import");
        confirm.Click += async (_, _) =>
        {
            confirm.IsEnabled = false;
            if (await scope.RunAsync(() => model.ConfirmAsync(), problem)) scope.Sheets.Close(true);
            else confirm.IsEnabled = model.CanConfirm;
        };
        edit.Click += async (_, _) => await EditAsync();
        automatic.Click += async (_, _) =>
        {
            var items = Selected();
            await RunAsync(() => model.ApplyAsync([.. items.Select(item => new ImportAssignmentUpdate(item.RelativePath, item.IsDirectory, null, UseAutomaticDetection: true))]));
        };
        var close = new Button { Content = "Close", Classes = { "chip" }, IsCancel = true };
        close.Click += async (_, _) =>
        {
            if (model.HasDraftChanges && !await scope.Sheets.ConfirmAsync("Discard this unconfirmed preview?",
                "Your active library and video files are unchanged. New locations remain paused until an import is confirmed.", "Discard Preview", destructive: true)) return;
            scope.Sheets.Close(false);
        };
        var again = new Button { Content = "Analyze Again", Classes = { "chip" } };
        again.Click += async (_, _) =>
        {
            if (model.HasDraftChanges && !await scope.Sheets.ConfirmAsync("Discard draft assignments and analyze again?",
                "This reloads saved assignments and current source files. Your active library remains unchanged.", "Discard and Analyze Again", destructive: true)) return;
            await RunAsync(model.AnalyzeAsync);
        };
        var filters = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        foreach (var option in Enum.GetValues<ImportPreviewFilter>())
        {
            var chip = new ToggleButton { Content = FilterName(option), Classes = { "chip" }, IsChecked = option == filter };
            chip.Click += (_, _) =>
            {
                filter = option;
                foreach (var other in filters.Children.OfType<ToggleButton>()) other.IsChecked = other == chip;
                Fill();
            };
            filters.Children.Add(chip);
        }
        Content = new DockPanel
        {
            Children =
            {
                new StackPanel
                {
                    Spacing = 8,
                    Margin = new Thickness(0, 0, 0, 10),
                    Children =
                    {
                        new TextBlock { Text = "Import Preview · " + model.Library.Name, FontSize = 20, FontWeight = FontWeight.Bold },
                        counts,
                        Note("No catalog entries are imported until you confirm this preview."),
                        new WrapPanel { ItemSpacing = 8, LineSpacing = 8, Children = { search, filters } },
                        Buttons(edit, automatic),
                    },
                }.Also(p => DockPanel.SetDock(p, Dock.Top)),
                new StackPanel
                {
                    Spacing = 8,
                    Margin = new Thickness(0, 10, 0, 0),
                    Children =
                    {
                        problem,
                        new DockPanel
                        {
                            Children =
                            {
                                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { again, confirm } }.Also(p => DockPanel.SetDock(p, Dock.Right)),
                                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { close, Note("Unresolved files stay in review. Video files are never changed.").Also(n => n.VerticalAlignment = VerticalAlignment.Center) } },
                            },
                        },
                    },
                }.Also(p => DockPanel.SetDock(p, Dock.Bottom)),
                new Border { Classes = { "card" }, Padding = new Thickness(6), Child = new ScrollViewer { Content = rows } },
            },
        };
        rows.Children.Add(Note("Analyzing filenames and folder structure…"));
        Loading = RunAsync(model.AnalyzeAsync);
    }

    internal Task Loading { get; }

    internal static string FilterName(ImportPreviewFilter filter) => filter switch
    {
        ImportPreviewFilter.NeedsReview => "Needs Review",
        _ => filter.ToString(),
    };

    private async Task RunAsync(Func<Task> action)
    {
        await scope.RunAsync(action, problem);
        selected.RemoveWhere(path => model.Items.All(item => item.RelativePath != path));
        Fill();
    }

    private List<ImportPreviewItem> Selected() => [.. model.Items.Where(item => selected.Contains(item.RelativePath))];

    private void Fill()
    {
        if (model.Summary is { Counts: var c })
        {
            counts.Text = $"{c.Files} files · {c.Movies} movies · {c.Series} series · {c.Episodes} episodes · {c.Extras} extras · {c.Trailers} trailers"
                + (c.Pending > 0 ? $" · {c.Pending} need review" : "") + (c.Errors > 0 ? $" · {c.Errors} errors" : "");
        }
        confirm.IsEnabled = model.CanConfirm;
        edit.IsEnabled = automatic.IsEnabled = selected.Count > 0;
        rows.Children.Clear();
        var visible = model.Visible(search.Text?.Trim() ?? "", filter);
        foreach (var item in visible.Take(500))
        {
            var depth = item.RelativePath.Count(c => c == '/');
            var box = new CheckBox { IsChecked = selected.Contains(item.RelativePath), VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetName(box, "Select " + item.RelativePath);
            box.IsCheckedChanged += (_, _) =>
            {
                if (box.IsChecked == true) selected.Add(item.RelativePath);
                else selected.Remove(item.RelativePath);
                edit.IsEnabled = automatic.IsEnabled = selected.Count > 0;
            };
            var detail = (item.Kind?.ToString() ?? "Unassigned")
                + (item.SeasonNumber is { } season ? $" · S{season}" : "") + (item.EpisodeNumber is { } episode ? $" E{episode}" : "")
                + (item.Category is { Length: > 0 } category ? " · " + category : "") + " · " + item.Reason;
            var status = item.Status switch
            {
                ImportPreviewItemStatus.Pending => "Needs Review",
                ImportPreviewItemStatus.Error => "Error",
                ImportPreviewItemStatus.Ignored => "Ignored",
                _ => "",
            };
            rows.Children.Add(new DockPanel
            {
                Margin = new Thickness(depth * 18, 2, 4, 2),
                Children =
                {
                    new TextBlock { Text = status, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Foreground = new SolidColorBrush(Color.Parse(item.Status == ImportPreviewItemStatus.Error ? "#FF6B6B" : "#FFB36B")) }.Also(t => DockPanel.SetDock(t, Dock.Right)),
                    box.Also(b => DockPanel.SetDock(b, Dock.Left)),
                    new StackPanel
                    {
                        Children =
                        {
                            new TextBlock { Text = (item.IsDirectory ? "📁 " : "") + item.Title, TextTrimming = TextTrimming.CharacterEllipsis },
                            new TextBlock { Text = detail, Classes = { "subdued" }, FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis },
                        },
                    },
                },
            });
        }
        if (visible.Count == 0 && model.Summary is not null) rows.Children.Add(Note("Nothing matches."));
        if (visible.Count > 500) rows.Children.Add(Note($"Showing 500 of {visible.Count}. Search to narrow the list."));
    }

    /// <summary>The Mac's ImportAssignmentEditor for the selected items.</summary>
    private async Task EditAsync()
    {
        var items = Selected();
        if (items.Count == 0 || model.Summary is not { } summary) return;
        var first = items[0];
        var choice = ImportPreviewModel.Choice(first.Kind);
        string? parentPath = first.ParentRelativePath;
        var entireSeries = first.SeasonNumber is null;
        var season = new TextBox { Text = first.SeasonNumber?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "1", Width = 80 };
        var episode = new TextBox { Text = first.EpisodeNumber?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "1", Width = 80, PlaceholderText = "Episode number" };
        var category = new TextBox { Text = first.Category ?? "", PlaceholderText = "Category (optional)", Width = 260 };
        var title = new TextBox { Text = items.Count == 1 && !first.IsDirectory ? first.Title : "", PlaceholderText = "Title", Width = 260, IsVisible = items.Count == 1 && !first.IsDirectory };
        AutomationProperties.SetName(season, "Season");
        AutomationProperties.SetName(episode, "Episode");
        AutomationProperties.SetName(category, "Category");
        AutomationProperties.SetName(title, "Title");
        var problemText = Message();
        var body = new StackPanel { Spacing = 10 };
        void Build()
        {
            body.Children.Clear();
            body.Children.Add(Choice("Import as", null, [.. Enum.GetValues<ImportContentChoice>().Select(c => (c, ImportPreviewModel.Label(c)))], choice, value => { choice = value; Build(); }).Also(r => r.Margin = new Thickness(0)));
            if (ImportPreviewModel.NeedsParent(choice))
            {
                var targets = summary.Targets.Where(t => choice != ImportContentChoice.Episode || t.Kind == MediaKind.Series).ToList();
                body.Children.Add(Choice("Belongs to", null, [(null, "Choose a movie or series"), .. targets.Select(t => ((string?)t.RelativePath, $"{t.Title} · {(t.Kind == MediaKind.Series ? "Series" : "Movie")}"))],
                    parentPath, value => { parentPath = value; Build(); }).Also(r => r.Margin = new Thickness(0)));
                var parent = summary.Targets.FirstOrDefault(t => t.RelativePath == parentPath);
                if (choice == ImportContentChoice.Episode)
                {
                    body.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { new TextBlock { Text = "Season", VerticalAlignment = VerticalAlignment.Center }, season, new TextBlock { Text = "Episode", VerticalAlignment = VerticalAlignment.Center }, episode } });
                }
                else if (parent?.Kind == MediaKind.Series)
                {
                    body.Children.Add(Toggle("Entire Series", null, entireSeries, value => { entireSeries = value; Build(); }).Also(r => r.Margin = new Thickness(0)));
                    if (!entireSeries)
                    {
                        var seasons = new WrapPanel { ItemSpacing = 6, LineSpacing = 6 };
                        foreach (var number in parent.SeasonNumbers)
                        {
                            var pick = new Button { Content = $"Season {number}", Classes = { "chip" } };
                            pick.Click += (_, _) => season.Text = number.ToString(System.Globalization.CultureInfo.InvariantCulture);
                            seasons.Children.Add(pick);
                        }
                        body.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { new TextBlock { Text = "Season", VerticalAlignment = VerticalAlignment.Center }, season } });
                        if (parent.SeasonNumbers.Count > 0) body.Children.Add(seasons);
                    }
                }
                body.Children.Add(category);
            }
            body.Children.Add(title);
            body.Children.Add(Note("Folder rules are inherited. Individual file assignments take precedence. Unnumbered episodes are only numbered when you explicitly choose TV Show · Force Import."));
            body.Children.Add(problemText);
        }
        Build();
        var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
        cancel.Click += (_, _) => scope.Sheets.Close(false);
        var save = new Button { Content = "Save Assignment", Classes = { "primary" }, IsDefault = true };
        save.Click += async (_, _) =>
        {
            var (changes, failure) = ImportPreviewModel.Assign(items, summary.Targets, choice, parentPath, entireSeries,
                season.Text?.Trim() ?? "", episode.Text?.Trim() ?? "", category.Text?.Trim() ?? "", title.Text?.Trim() ?? "");
            if (changes is null)
            {
                problemText.Text = failure;
                problemText.IsVisible = true;
                return;
            }
            save.IsEnabled = false;
            if (await scope.RunAsync(() => model.ApplyAsync(changes), problemText)) scope.Sheets.Close(true);
            save.IsEnabled = true;
        };
        if (await scope.Sheets.ShowAsync(new StackPanel
        {
            Spacing = 14,
            Width = 560,
            Children =
            {
                new TextBlock { Text = items.Count == 1 ? "Edit Import Assignment" : $"Edit {items.Count} Import Assignments", FontSize = 18, FontWeight = FontWeight.Bold },
                body,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel, save } },
            },
        }))
        {
            selected.Clear();
            Fill();
        }
    }
}

/// <summary>The Mac's LibraryResetSheet: choose libraries, see what goes, confirm with the Server Password.</summary>
public sealed class LibraryResetSheet : UserControl
{
    public LibraryResetSheet(AdminScope scope, IReadOnlyList<LibrarySummary> libraries)
    {
        Width = 520;
        var chosen = new HashSet<Guid>(libraries.Select(l => l.Id));
        var summary = new TextBlock { FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap };
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap, IsVisible = false };
        var problem = Message();
        ResetLibraryPreview? preview = null;
        var reset = new Button { Content = "Reset Selected Libraries…", Classes = { "destructive" }, IsEnabled = false };
        async Task PreviewAsync()
        {
            preview = null;
            reset.IsEnabled = false;
            summary.Text = "";
            if (chosen.Count == 0) return;
            if (await scope.RunAsync(async () => preview = await scope.Client.PreviewResetAsync([.. chosen]), problem) && preview is not null)
            {
                summary.Text = $"{preview.Titles} catalog entries · {preview.Artwork} artwork assets · {preview.StorageLocations} storage locations";
                reset.IsEnabled = true;
            }
        }
        var boxes = new StackPanel { Spacing = 4 };
        foreach (var library in libraries)
        {
            var box = new CheckBox { Content = library.Name, IsChecked = true };
            box.IsCheckedChanged += async (_, _) =>
            {
                if (box.IsChecked == true) chosen.Add(library.Id);
                else chosen.Remove(library.Id);
                await PreviewAsync();
            };
            boxes.Children.Add(box);
        }
        var close = new Button { Content = "Close", Classes = { "chip" }, IsCancel = true };
        var done = false;
        close.Click += (_, _) => scope.Sheets.Close(done);
        reset.Click += async (_, _) =>
        {
            if (preview is null) return;
            if (!await scope.Sheets.ConfirmAsync("Permanently reset the selected libraries?",
                "Titles, progress, favorites and metadata of these libraries are removed. Your video files are never changed.", "Reset Selected Libraries", destructive: true)) return;
            reset.IsEnabled = false;
            LibraryMutationResult? result = null;
            if (!await scope.RunAsync(async () => result = await scope.Client.ResetAsync(new ResetLibraryRequest(preview.LibraryIds, preview.Revision)), problem) || result is null)
            {
                reset.IsEnabled = true;
                return;
            }
            done = true;
            status.IsVisible = true;
            for (var attempt = 0; attempt < 60 && result.State != "completed" && result.Error is null; attempt++)
            {
                status.Text = "Catalog removed. Waiting for managed artwork cleanup…";
                status.Foreground = new SolidColorBrush(Color.Parse("#FFB36B"));
                await Task.Delay(1000);
                var id = result.Id;
                await scope.RunAsync(async () => result = await scope.Client.OperationAsync(id), problem);
            }
            status.Text = result.Error ?? (result.State == "completed" ? "Reset complete. Your video files were not changed." : "Catalog removed. Waiting for managed artwork cleanup…");
            status.Foreground = new SolidColorBrush(Color.Parse(result.State == "completed" ? "#4CD964" : "#FFB36B"));
        };
        Content = new StackPanel
        {
            Spacing = 14,
            Children =
            {
                new TextBlock { Text = "Reset Library", FontSize = 18, FontWeight = FontWeight.Bold },
                Note("Videos, accounts, device sessions, server settings and TLS identity are never deleted. Existing backups are retained and may contain earlier library data."),
                boxes,
                summary,
                status,
                problem,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { close, reset } },
            },
        };
        Loading = PreviewAsync();
    }

    internal Task Loading { get; }
}
