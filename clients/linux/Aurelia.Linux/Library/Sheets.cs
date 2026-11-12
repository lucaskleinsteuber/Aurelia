using System.ComponentModel;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Management;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Data;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;

namespace Aurelia.Linux.Library;

/// <summary>
/// Shows one sheet at a time over the window, dimming what is behind it: confirmations and
/// editors. Escape cancels, as Return confirms in the Mac app's sheets.
/// </summary>
public sealed class SheetHost : Panel
{
    // Sheets stack: the Server Password prompt can open above an editor and return to it.
    private readonly Stack<(Control Frame, TaskCompletionSource<bool> Result)> open = new();

    public SheetHost()
    {
        IsVisible = false;
        Background = new SolidColorBrush(Color.FromArgb(0x99, 0, 0, 0));
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close(false);
                e.Handled = true;
            }
        };
    }

    public bool IsShowing => IsVisible;

    internal Control? Current => open.Count > 0 ? open.Peek().Frame : null;

    /// <param name="fullWindow">Covers the whole window instead of floating as a card, for Movie
    /// Night and Wrapped.</param>
    public Task<bool> ShowAsync(Control sheet, bool fullWindow = false)
    {
        if (open.Count > 0) open.Peek().Frame.IsVisible = false;
        var frame = fullWindow
            ? new Border { Child = sheet }
            : new Border
            {
                Classes = { "sheet" },
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Child = sheet,
            };
        var result = new TaskCompletionSource<bool>();
        open.Push((frame, result));
        Children.Add(frame);
        IsVisible = true;
        Aurelia.Linux.Controls.Motion.Appear(frame, rise: fullWindow ? 0 : 12, fromScale: fullWindow ? 1.02 : 0.98);
        Avalonia.Threading.Dispatcher.UIThread.Post(() => sheet.GetVisualDescendantsOfType<TextBox>().FirstOrDefault()?.Focus());
        return result.Task;
    }

    /// <summary>Closes the topmost sheet; the one below it, if any, shows again.</summary>
    public void Close(bool result)
    {
        if (open.Count == 0)
        {
            IsVisible = false;
            return;
        }
        var (frame, pending) = open.Pop();
        Children.Remove(frame);
        if (open.Count > 0) open.Peek().Frame.IsVisible = true;
        else IsVisible = false;
        pending.TrySetResult(result);
    }

    /// <summary>A question with a confirm and a Cancel button.</summary>
    public Task<bool> ConfirmAsync(string title, string message, string confirmLabel, bool destructive)
    {
        var confirm = new Button { Content = confirmLabel, Classes = { destructive ? "destructive" : "primary" }, IsDefault = true };
        var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
        confirm.Click += (_, _) => Close(true);
        cancel.Click += (_, _) => Close(false);
        return ShowAsync(new StackPanel
        {
            Spacing = 14,
            Width = 420,
            Children =
            {
                new TextBlock { Text = title, FontSize = 18, FontWeight = FontWeight.Bold, TextWrapping = TextWrapping.Wrap },
                new TextBlock { Text = message, Classes = { "subdued" }, TextWrapping = TextWrapping.Wrap },
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel, confirm } },
            },
        });
    }
}

internal static class VisualExtensions
{
    public static IEnumerable<T> GetVisualDescendantsOfType<T>(this Visual visual) where T : Visual =>
        Avalonia.VisualTree.VisualExtensions.GetVisualDescendants(visual).OfType<T>();
}

/// <summary>The collection editor sheet: metadata, artwork upload/crop, sort mode, members (movies, series, seasons, episodes) or smart rules.</summary>
public sealed class CollectionEditorSheet : UserControl
{
    private readonly CollectionEditorModel model;
    private readonly LibraryContext context;
    private readonly SheetHost host;
    private readonly StackPanel body = new() { Spacing = 12 };
    private readonly TextBlock problem = new() { Foreground = new SolidColorBrush(Color.Parse("#FF8A8A")) };
    private readonly TextBlock preview = new() { Classes = { "subdued" } };
    private readonly TextBlock artworkStatus = new() { Classes = { "subdued" }, FontSize = 12 };
    private readonly ComboBox sortBox = new() { MinWidth = 180 };
    private readonly Button save = new() { Content = "Save", Classes = { "primary" }, IsDefault = true };
    private readonly Dictionary<Guid, CatalogDetailPresentation> expandedSeries = [];
    private readonly HashSet<Guid> openSeriesIds = [];
    private string filter = "";

    public CollectionEditorSheet(LibraryContext context, SheetHost host, CollectionSummary? existing, CatalogItemSummary? preselected, int? preselectedSeasonNumber = null)
    {
        this.context = context;
        this.host = host;
        model = new CollectionEditorModel(context.Store.Catalog, existing, preselected, context.Store.CanManageMedia, preselectedSeasonNumber);
        DataContext = model;
        Width = 760;
        Height = 720;

        var nameBox = new TextBox { PlaceholderText = "Name" };
        nameBox[!TextBox.TextProperty] = new Binding(nameof(CollectionEditorModel.Name)) { Mode = BindingMode.TwoWay };
        AutomationProperties.SetName(nameBox, "Collection Name");

        var overviewBox = new TextBox
        {
            PlaceholderText = "Optional description of this collection…",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 56,
            MaxHeight = 110,
        };
        overviewBox[!TextBox.TextProperty] = new Binding(nameof(CollectionEditorModel.Overview)) { Mode = BindingMode.TwoWay };
        AutomationProperties.SetName(overviewBox, "Description");

        var standard = new ToggleButton { Content = "Box Set", Classes = { "chip" }, IsChecked = !model.IsSmart };
        var smart = new ToggleButton { Content = "Smart List", Classes = { "chip" }, IsChecked = model.IsSmart };
        ConfigureSortBox();
        standard.Click += (_, _) => { model.IsSmart = false; smart.IsChecked = false; standard.IsChecked = true; ConfigureSortBox(); BuildBody(); };
        smart.Click += (_, _) => { model.IsSmart = true; standard.IsChecked = false; smart.IsChecked = true; ConfigureSortBox(); BuildBody(); };

        var chooseCover = new Button { Content = "Choose Cover (2:3)…", Classes = { "chip" } };
        var clearCover = new Button { Content = "Automatic Cover", Classes = { "chip" } };
        var chooseBackdrop = new Button { Content = "Choose Backdrop (16:9)…", Classes = { "chip" } };
        var clearBackdrop = new Button { Content = "Automatic Backdrop", Classes = { "chip" } };
        chooseCover.Click += async (_, _) => await PickArtworkAsync("poster", 2.0 / 3.0);
        clearCover.Click += (_, _) => { model.RemovePoster = true; UpdateArtworkStatus(); };
        chooseBackdrop.Click += async (_, _) => await PickArtworkAsync("backdrop", 16.0 / 9.0);
        clearBackdrop.Click += (_, _) => { model.RemoveBackdrop = true; UpdateArtworkStatus(); };

        var shared = new CheckBox { Content = "Shared Collection (visible to all profiles)", IsVisible = model.CanShare };
        shared[!ToggleButton.IsCheckedProperty] = new Binding(nameof(CollectionEditorModel.IsShared)) { Mode = BindingMode.TwoWay };
        var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
        cancel.Click += (_, _) => host.Close(false);
        save.Click += async (_, _) => await SaveAsync();
        var footer = new DockPanel { LastChildFill = false };
        if (existing is not null)
        {
            var delete = new Button { Content = "Delete Collection", Classes = { "destructive" } };
            delete.Click += async (_, _) =>
            {
                host.Close(false);
                if (await context.Navigator.ConfirmAsync($"Delete “{existing.Name}”?", "The titles stay in the library.", "Delete", destructive: true))
                {
                    await context.Store.DeleteCollectionAsync(existing.Id);
                    context.Navigator.Back();
                }
            };
            footer.Children.Add(delete.Also(d => DockPanel.SetDock(d, Dock.Left)));
        }
        footer.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { cancel, save } }.Also(p => DockPanel.SetDock(p, Dock.Right)));
        Content = new DockPanel
        {
            Children =
            {
                new StackPanel
                {
                    Spacing = 10,
                    Children =
                    {
                        new TextBlock { Text = existing is null ? "New Collection" : "Edit Collection", FontSize = 20, FontWeight = FontWeight.Bold },
                        nameBox,
                        overviewBox,
                        new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { standard, smart, sortBox } },
                        new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { chooseCover, clearCover, chooseBackdrop, clearBackdrop } },
                        artworkStatus,
                    },
                }.Also(p => DockPanel.SetDock(p, Dock.Top)),
                new StackPanel { Spacing = 8, Margin = new Thickness(0, 10, 0, 0), Children = { shared, problem, footer } }.Also(p => DockPanel.SetDock(p, Dock.Bottom)),
                new ScrollViewer { Content = body, Margin = new Thickness(0, 12, 0, 0) },
            },
        };
        model.PropertyChanged += OnModelChanged;
        UpdateArtworkStatus();
        BuildBody();
        Update();
        if (existing is not null)
        {
            AttachedToVisualTree += async (_, _) => await LoadDetailAsync(existing.Id);
        }
    }

    internal CollectionEditorModel Model => model;

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e) => Update();

    private void ConfigureSortBox()
    {
        var options = model.IsSmart
            ? new (string Value, string Label)[] { ("release", "Release Date"), ("title", "Title") }
            : [("custom", "Custom Order"), ("release", "Release Date"), ("title", "Title")];
        sortBox.ItemsSource = options.Select(o => o.Label).ToList();
        var index = Math.Max(0, Array.FindIndex(options, o => o.Value == model.SortMode));
        sortBox.SelectedIndex = index;
        sortBox.SelectionChanged += (_, _) =>
        {
            if (sortBox.SelectedIndex >= 0 && sortBox.SelectedIndex < options.Length)
            {
                model.SortMode = options[sortBox.SelectedIndex].Value;
            }
        };
    }

    private void UpdateArtworkStatus()
    {
        var coverText = model.PosterDraft is not null ? "Custom Cover" : (model.RemovePoster ? "Automatic Cover" : (model.Existing?.Poster is not null ? "Server Cover" : "Automatic Cover"));
        var bgText = model.BackdropDraft is not null ? "Custom Backdrop" : (model.RemoveBackdrop ? "Automatic Backdrop" : (model.Existing?.Backdrop is not null ? "Server Backdrop" : "Automatic Backdrop"));
        artworkStatus.Text = $"{coverText} · {bgText}";
    }

    private async Task LoadDetailAsync(Guid collectionId)
    {
        var loaded = await context.Store.CollectionAsync(collectionId);
        if (loaded is null) return;
        model.LoadDetail(loaded);
        ConfigureSortBox();
        BuildBody();
    }

    private async Task PickArtworkAsync(string kind, double aspect)
    {
        var storage = TopLevel.GetTopLevel(this)?.StorageProvider;
        if (storage is null) return;
        var files = await storage.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            AllowMultiple = false,
            Title = kind == "poster" ? "Choose Collection Cover" : "Choose Collection Backdrop",
            FileTypeFilter = [new FilePickerFileType("Images") { Patterns = ["*.jpg", "*.jpeg", "*.png", "*.heic", "*.webp"] }],
        });
        if (files.Count == 0) return;
        byte[] bytes;
        await using (var stream = await files[0].OpenReadAsync())
        {
            if (stream.CanSeek && stream.Length > 20 * 1024 * 1024)
            {
                problem.Text = "Choose an image up to 20 MB.";
                problem.IsVisible = true;
                return;
            }
            using var copy = new MemoryStream();
            await stream.CopyToAsync(copy);
            bytes = copy.ToArray();
        }
        var crop = new CropSheet(host, bytes, aspect, null, kind == "poster" ? "Crop Collection Cover" : "Crop Collection Backdrop", "Use Crop");
        var confirmed = await host.ShowAsync(crop);
        if (!confirmed) return;

        Guid? uploadId = null;
        if (model.Existing is { } existing)
        {
            try
            {
                var uploaded = await context.Store.Client.UploadCollectionEditorImageAsync(existing.Id, bytes, CancellationToken.None);
                uploadId = uploaded.Id;
            }
            catch (AureliaApiException failure)
            {
                problem.Text = failure.Message;
                problem.IsVisible = true;
                return;
            }
        }
        var draft = new CollectionArtworkDraft(uploadId, bytes, crop.Result);
        if (kind == "poster") model.PosterDraft = draft;
        else model.BackdropDraft = draft;
        UpdateArtworkStatus();
    }

    private void Update()
    {
        problem.Text = model.Problem;
        problem.IsVisible = model.Problem is not null && (model.Name.Length > 0 || model.SelectedMembers.Count > 0);
        save.IsEnabled = model.CanSave;
        preview.Text = model.MatchingCount == 1 ? "Matching 1 title" : $"Matching {model.MatchingCount} titles";
    }

    private void BuildBody()
    {
        body.Children.Clear();
        if (model.IsSmart) BuildRules();
        else BuildTitles();
    }

    private void BuildTitles()
    {
        var search = new TextBox { PlaceholderText = "Find titles, seasons, or episodes…", Text = filter };
        AutomationProperties.SetName(search, "Find Titles");
        var list = new StackPanel { Spacing = 4 };
        void Fill()
        {
            list.Children.Clear();
            for (var index = 0; index < model.SelectedMembers.Count; index++)
            {
                var currentIndex = index;
                var member = model.SelectedMembers[currentIndex];
                var up = new Button { Content = "▲", Classes = { "link" }, IsEnabled = currentIndex > 0 };
                var down = new Button { Content = "▼", Classes = { "link" }, IsEnabled = currentIndex < model.SelectedMembers.Count - 1 };
                var remove = new Button { Content = "✕", Classes = { "link" } };
                AutomationProperties.SetName(up, "Move Up, " + member.Title);
                AutomationProperties.SetName(down, "Move Down, " + member.Title);
                up.Click += (_, _) => { model.MoveMember(currentIndex, -1); ConfigureSortBox(); Fill(); };
                down.Click += (_, _) => { model.MoveMember(currentIndex, 1); ConfigureSortBox(); Fill(); };
                remove.Click += (_, _) => { model.RemoveMemberAt(currentIndex); Fill(); };
                var row = new DockPanel();
                row.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Children = { new TextBlock { Text = member.TypeLabel, Classes = { "subdued" }, FontSize = 11, VerticalAlignment = VerticalAlignment.Center }, up, down, remove } }.Also(p => DockPanel.SetDock(p, Dock.Right)));
                row.Children.Add(new TextBlock { Text = $"{currentIndex + 1}. {member.Title}", VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
                list.Children.Add(row);
            }
            if (model.SelectedMembers.Count > 0) list.Children.Add(new Separator { Margin = new Thickness(0, 6) });
            foreach (var candidate in model.Candidates.Where(c => filter.Length == 0 || c.Title.Contains(filter, StringComparison.CurrentCultureIgnoreCase)).Take(200))
            {
                var check = new CheckBox
                {
                    IsChecked = model.ContainsMember(candidate.Id, null),
                    Content = $"{candidate.Title}{(candidate.Year is { } y ? $" ({y})" : "")} · {(candidate.Kind == MediaKind.Movie ? "Movie" : "TV Show")}",
                };
                check.IsCheckedChanged += (_, _) => { model.Toggle(candidate); Fill(); };
                var row = new DockPanel();
                if (candidate.Kind == MediaKind.Series)
                {
                    var expand = new Button { Content = openSeriesIds.Contains(candidate.Id) ? "Hide Seasons" : "Seasons…", Classes = { "link" } };
                    expand.Click += async (_, _) =>
                    {
                        if (!openSeriesIds.Add(candidate.Id)) openSeriesIds.Remove(candidate.Id);
                        else if (!expandedSeries.ContainsKey(candidate.Id))
                        {
                            try
                            {
                                expandedSeries[candidate.Id] = await context.Store.Client.DetailAsync(candidate.Id, CancellationToken.None);
                            }
                            catch (AureliaApiException)
                            {
                            }
                        }
                        Fill();
                    };
                    row.Children.Add(expand.Also(e => DockPanel.SetDock(e, Dock.Right)));
                }
                row.Children.Add(check);
                list.Children.Add(row);

                if (candidate.Kind == MediaKind.Series && openSeriesIds.Contains(candidate.Id) && expandedSeries.TryGetValue(candidate.Id, out var seriesDetail))
                {
                    foreach (var season in seriesDetail.Seasons)
                    {
                        var seasonTitle = $"{candidate.Title} · {(season.Number == 0 ? "Specials" : $"Season {season.Number}")}";
                        var seasonCheck = new CheckBox
                        {
                            Margin = new Thickness(24, 0, 0, 0),
                            IsChecked = model.ContainsMember(candidate.Id, season.Number),
                            Content = $"{(season.Number == 0 ? "Specials (Season 0)" : $"Season {season.Number}")} ({season.Episodes.Count} episodes)",
                        };
                        seasonCheck.IsCheckedChanged += (_, _) => { model.ToggleMember(candidate.Id, season.Number, seasonTitle, MediaKind.Series); Fill(); };
                        list.Children.Add(seasonCheck);

                        foreach (var episode in season.Episodes)
                        {
                            var epCode = $"S{episode.SeasonNumber:00}E{episode.EpisodeNumber:00}";
                            var epTitle = $"{candidate.Title} · {epCode} · {episode.Item.Title}";
                            var epCheck = new CheckBox
                            {
                                Margin = new Thickness(44, 0, 0, 0),
                                IsChecked = model.ContainsMember(episode.Item.Id, null),
                                Content = $"{epCode} · {episode.Item.Title}",
                            };
                            epCheck.IsCheckedChanged += (_, _) => { model.ToggleMember(episode.Item.Id, null, epTitle, MediaKind.Episode, episode.Item); Fill(); };
                            list.Children.Add(epCheck);
                        }
                    }
                }
            }
        }
        search.TextChanged += (_, _) => { filter = search.Text ?? ""; Fill(); };
        Fill();
        body.Children.Add(search);
        body.Children.Add(list);
    }

    private void BuildRules()
    {
        Control Field(string label, Control input) => new DockPanel
        {
            Children = { new TextBlock { Text = label, Width = 150, VerticalAlignment = VerticalAlignment.Center }.Also(t => DockPanel.SetDock(t, Dock.Left)), input },
        };
        TextBox Text(string property, string placeholder)
        {
            var box = new TextBox { PlaceholderText = placeholder };
            box[!TextBox.TextProperty] = new Binding(property) { Mode = BindingMode.TwoWay };
            AutomationProperties.SetName(box, placeholder);
            return box;
        }
        ComboBox Choice(string property, (string Value, string Label)[] options)
        {
            var box = new ComboBox { ItemsSource = options.Select(o => o.Label).ToList(), MinWidth = 200 };
            var current = typeof(CollectionEditorModel).GetProperty(property)!.GetValue(model)?.ToString();
            box.SelectedIndex = Math.Max(0, Array.FindIndex(options, o => o.Value == current));
            box.SelectionChanged += (_, _) =>
            {
                if (box.SelectedIndex < 0) return;
                var info = typeof(CollectionEditorModel).GetProperty(property)!;
                var value = options[box.SelectedIndex].Value;
                info.SetValue(model, info.PropertyType == typeof(int) ? int.Parse(value, System.Globalization.CultureInfo.InvariantCulture) : info.PropertyType == typeof(bool) ? value == "true" : value);
            };
            return box;
        }
        var favorites = new CheckBox { Content = "Favorites Only" };
        favorites[!ToggleButton.IsCheckedProperty] = new Binding(nameof(CollectionEditorModel.FavoritesOnly)) { Mode = BindingMode.TwoWay };
        body.Children.Add(Field("Match", Choice(nameof(CollectionEditorModel.MatchAny), [("false", "All rules (AND)"), ("true", "Any rule (OR)")])));
        body.Children.Add(Field("Media Type", Choice(nameof(CollectionEditorModel.Kind), [("all", "Movies and TV Shows"), ("movie", "Movies"), ("series", "TV Shows")])));
        body.Children.Add(Field("Genre", Text(nameof(CollectionEditorModel.Genres), "For example Comedy, Drama")));
        body.Children.Add(Field("Min Year", Text(nameof(CollectionEditorModel.YearMin), "Any")));
        body.Children.Add(Field("Max Year", Text(nameof(CollectionEditorModel.YearMax), "Any")));
        body.Children.Add(Field("Min Rating", Text(nameof(CollectionEditorModel.RatingMin), "0–10")));
        body.Children.Add(Field("Watched", Choice(nameof(CollectionEditorModel.Watched), [("any", "Any"), ("unwatched", "Unwatched"), ("watched", "Watched")])));
        body.Children.Add(Field("Added Within", Choice(nameof(CollectionEditorModel.AddedWithinDays), [("0", "Any Time"), ("30", "30 Days"), ("90", "90 Days"), ("365", "One Year")])));
        body.Children.Add(Field("Title Contains", Text(nameof(CollectionEditorModel.TitleContains), "Any text")));
        body.Children.Add(favorites);
        body.Children.Add(preview);
    }

    private async Task SaveAsync()
    {
        if (!model.CanSave) return;
        save.IsEnabled = false;
        var saved = await context.Store.SaveCollectionAsync(
            model.Existing?.Id,
            model.Request(),
            model.PosterDraft,
            model.BackdropDraft,
            model.RemovePoster,
            model.RemoveBackdrop);
        if (saved is not null) host.Close(true);
        else save.IsEnabled = true;
    }
}
