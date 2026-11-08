using Aurelia.Linux.Controls;
using System.ComponentModel;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Library;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Library;

/// <summary>
/// Library, Movies, TV Shows and Recently Added: title, count, search, sort and filter chips, then
/// a poster grid. Library and Recently Added group movies, TV shows and episodes; the Library page
/// shows the collections shelf while no search or filter is active.
/// </summary>
public sealed class BrowsePage : LibraryPageBase
{
    private readonly TextBox search = new TextBox { PlaceholderText = "Search", Width = 260 }.WithGlass();
    private readonly string title;

    public BrowsePage(LibraryContext context, BrowseSection section) : base(context)
    {
        Model = new BrowseModel(context.Store, section);
        title = section switch
        {
            BrowseSection.Movies => "Movies",
            BrowseSection.TvShows => "TV Shows",
            BrowseSection.RecentlyAdded => "Recently Added",
            _ => "Library",
        };
        search.PlaceholderText = "Search " + title;
        AutomationProperties.SetName(search, "Search " + title);
        search.TextChanged += (_, _) => Model.Search = search.Text ?? "";
        Model.PropertyChanged += OnModelChanged;
        AttachedToVisualTree += (_, _) => _ = Model.LoadAsync();
    }

    public BrowseModel Model { get; }

    /// <summary>Ctrl+F lands here.</summary>
    public void FocusSearch() => search.Focus();

    protected override void OnStoreChanged() => _ = Model.LoadAsync(quietly: true);

    protected override Control Build()
    {
        var page = new StackPanel { Spacing = 22, Margin = new Thickness(0, 64, 0, 48) };
        page.Children.Add(Header());
        page.Children.Add(Filters());
        page.Children.Add(Results());
        return page;
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        // IsLoading too: a filter answered from the cache keeps the same items, and only the end of
        // loading then replaces the spinner.
        if (e.PropertyName is nameof(BrowseModel.Items) or nameof(BrowseModel.Error) or nameof(BrowseModel.Query) or nameof(BrowseModel.IsLoading)) Rebuild();
    }

    private DockPanel Header()
    {
        if (search.Parent is Panel old) old.Children.Remove(search);
        // As tall as the search field beside it, with its text centered.
        var sort = new Button { Classes = { "chip" }, Content = SortLabel(), Flyout = SortFlyout(), VerticalAlignment = VerticalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Center, CornerRadius = new CornerRadius(10), Padding = new Thickness(16, 0) };
        AutomationProperties.SetName(sort, "Sort");
        return new DockPanel
        {
            Margin = Inset(),
            LastChildFill = false,
            Children =
            {
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 12,
                    Children =
                    {
                        PageTitle(title),
                        new TextBlock { Text = Model.Items.Count.ToString(System.Globalization.CultureInfo.InvariantCulture), Classes = { "subdued" }, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 8) },
                    },
                }.Also(p => DockPanel.SetDock(p, Dock.Left)),
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { search, sort } }.Also(p => DockPanel.SetDock(p, Dock.Right)),
            },
        };
    }

    private WrapPanel Filters()
    {
        var query = Model.Query;
        var chips = new WrapPanel { Margin = Inset(), ItemSpacing = 8, LineSpacing = 8 };
        if (Model.Section is BrowseSection.Library or BrowseSection.RecentlyAdded)
        {
            chips.Children.Add(Chip("All", query.Kind is null, () => Model.Query = query with { Kind = null }));
            chips.Children.Add(Chip("Movies", query.Kind == MediaKind.Movie, () => Model.Query = query with { Kind = MediaKind.Movie }));
            chips.Children.Add(Chip("TV Shows", query.Kind == MediaKind.Series, () => Model.Query = query with { Kind = MediaKind.Series }));
        }
        chips.Children.Add(Chip("Favorites", query.FavoritesOnly, () => Model.Query = query with { FavoritesOnly = !query.FavoritesOnly }));
        if (Context.Store.Client.Supports("library-state-v1"))
        {
            chips.Children.Add(Chip("Unwatched", query.WatchState == CatalogWatchState.Unplayed, () => ToggleWatchState(CatalogWatchState.Unplayed)));
            chips.Children.Add(Chip("In Progress", query.WatchState == CatalogWatchState.InProgress, () => ToggleWatchState(CatalogWatchState.InProgress)));
            chips.Children.Add(Chip("Watched", query.WatchState == CatalogWatchState.Completed, () => ToggleWatchState(CatalogWatchState.Completed)));
        }
        chips.Children.Add(new Button { Classes = { "chip" }, Content = query.Genre ?? "Genre", Flyout = GenreFlyout() });
        chips.Children.Add(new Button { Classes = { "chip" }, Content = YearLabel(query), Flyout = YearFlyout() });
        if (query.HasFilters)
        {
            var clear = new Button { Content = "Clear", Classes = { "link" } };
            clear.Click += (_, _) => Model.ClearFilters();
            chips.Children.Add(clear);
        }
        return chips;
    }

    private void ToggleWatchState(CatalogWatchState state) =>
        Model.Query = Model.Query with { WatchState = Model.Query.WatchState == state ? null : state };

    private Control Results()
    {
        if (Model.Error is { } failure)
        {
            var retry = new Button { Content = "Try Again", Classes = { "primary" } };
            retry.Click += (_, _) => _ = Model.LoadAsync();
            return EmptyState("Library Unavailable", failure, retry);
        }
        var items = LibraryPresentation.Visible(Model.Items, keepWatched: true, showWatched: true, Context.Store.Preferences.HideOfflineTitles);
        if (items.Count == 0)
        {
            if (Model.IsLoading) return new Aurelia.Linux.Controls.Spinner { Margin = Inset(120), HorizontalAlignment = HorizontalAlignment.Center };
            return Model.IsSearching || Model.Query.HasFilters
                ? EmptyState("No Results", "No titles match. Try another search or fewer filters.")
                : EmptyState("No Media Yet", Context.Store.CanManageMedia ? "Add a folder with movies or TV shows on the server." : "Titles appear here once the server's owner adds media.");
        }
        var width = Context.Store.Preferences.PosterWidth;
        var results = new StackPanel { Spacing = 30 };
        if (Model.Section == BrowseSection.Library && !Model.IsSearching && !Model.Query.HasFilters && Context.Store.Collections.Count > 0)
        {
            results.Children.Add(Section("Collections", Shelf("Collections", Context.Store.Collections, c => MediaCards.Collection(Context, c)), Context.Store.Collections.Count));
        }
        var grouped = Model.Section is BrowseSection.Library || (Model.Section == BrowseSection.RecentlyAdded && items.Any(item => item.Kind == MediaKind.Episode));
        if (!grouped)
        {
            results.Children.Add(Grid(items, item => MediaCards.Poster(Context, item, width)));
            return results;
        }
        void Group(string name, IEnumerable<CatalogItemSummary> group, Func<CatalogItemSummary, Control> card)
        {
            var list = group.ToList();
            if (list.Count > 0) results.Children.Add(Section(name, Grid(list, card), list.Count));
        }
        Group("Movies", items.Where(item => item.Kind == MediaKind.Movie), item => MediaCards.Poster(Context, item, width));
        Group("TV Shows", items.Where(item => item.Kind == MediaKind.Series), item => MediaCards.Poster(Context, item, width));
        Group("Episodes", items.Where(item => item.Kind == MediaKind.Episode), item => MediaCards.Landscape(Context, item, 300, plays: true));
        return results;
    }

    private string SortLabel() => Model.Query.Sort switch
    {
        BrowseSort.Title => "Title",
        BrowseSort.DateAdded => "Recently Added",
        BrowseSort.ReleaseYear => "Release Year",
        BrowseSort.LastWatched => "Last Watched",
        _ => Model.IsSearching ? "Relevance" : "Default",
    };

    private Flyout SortFlyout()
    {
        var panel = new StackPanel { Spacing = 4, MinWidth = 200 };
        foreach (var (sort, label) in new[] { (BrowseSort.Default, Model.IsSearching ? "Relevance" : "Default"), (BrowseSort.Title, "Title"), (BrowseSort.DateAdded, "Recently Added"), (BrowseSort.ReleaseYear, "Release Year"), (BrowseSort.LastWatched, "Last Watched") })
        {
            var option = new RadioButton { Content = label, GroupName = "sort", IsChecked = Model.Query.Sort == sort };
            option.IsCheckedChanged += (_, _) =>
            {
                if (option.IsChecked == true && Model.Query.Sort != sort) Model.Query = Model.Query with { Sort = sort };
            };
            panel.Children.Add(option);
        }
        panel.Children.Add(new Separator());
        var ascending = new RadioButton { Content = "Ascending", GroupName = "direction", IsChecked = !Model.Query.Descending, IsEnabled = Model.Query.Sort != BrowseSort.Default };
        var descending = new RadioButton { Content = "Descending", GroupName = "direction", IsChecked = Model.Query.Descending, IsEnabled = Model.Query.Sort != BrowseSort.Default };
        ascending.IsCheckedChanged += (_, _) => { if (ascending.IsChecked == true && Model.Query.Descending) Model.Query = Model.Query with { Descending = false }; };
        descending.IsCheckedChanged += (_, _) => { if (descending.IsChecked == true && !Model.Query.Descending) Model.Query = Model.Query with { Descending = true }; };
        panel.Children.Add(ascending);
        panel.Children.Add(descending);
        return new Flyout { Content = panel, Placement = PlacementMode.BottomEdgeAlignedRight };
    }

    private Flyout GenreFlyout()
    {
        var chips = new WrapPanel { ItemSpacing = 6, LineSpacing = 6, MaxWidth = 420 };
        foreach (var genre in Model.Genres)
        {
            chips.Children.Add(Chip(genre, Model.Query.Genre == genre, () => Model.Query = Model.Query with { Genre = Model.Query.Genre == genre ? null : genre }));
        }
        if (chips.Children.Count == 0) chips.Children.Add(new TextBlock { Text = "No genres yet.", Classes = { "subdued" } });
        return new Flyout { Content = new ScrollViewer { Content = chips, MaxHeight = 320 } };
    }

    private Flyout YearFlyout()
    {
        var years = Model.Years.Select(y => (object)y).Prepend("Any").ToList();
        var from = new ComboBox { ItemsSource = years, SelectedItem = Model.Query.YearFrom is { } f ? f : "Any", MinWidth = 110 };
        var to = new ComboBox { ItemsSource = years, SelectedItem = Model.Query.YearTo is { } t ? t : "Any", MinWidth = 110 };
        AutomationProperties.SetName(from, "From Year");
        AutomationProperties.SetName(to, "To Year");
        void Apply()
        {
            int? start = from.SelectedItem as int?;
            int? end = to.SelectedItem as int?;
            // From never comes after To.
            if (start is { } s && end is { } e && s > e) (start, end) = (e, s);
            Model.Query = Model.Query with { YearFrom = start, YearTo = end };
        }
        from.SelectionChanged += (_, _) => Apply();
        to.SelectionChanged += (_, _) => Apply();
        var any = new Button { Content = "Any Year", Classes = { "link" } };
        any.Click += (_, _) => Model.Query = Model.Query with { YearFrom = null, YearTo = null };
        return new Flyout
        {
            Content = new StackPanel
            {
                Spacing = 8,
                Children =
                {
                    new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { new TextBlock { Text = "From", VerticalAlignment = VerticalAlignment.Center }, from, new TextBlock { Text = "To", VerticalAlignment = VerticalAlignment.Center }, to } },
                    any,
                },
            },
        };
    }

    private static string YearLabel(BrowseQuery query) => (query.YearFrom, query.YearTo) switch
    {
        ({ } from, { } to) when from == to => from.ToString(System.Globalization.CultureInfo.InvariantCulture),
        ({ } from, { } to) => $"{from}–{to}",
        ({ } from, null) => $"From {from}",
        (null, { } to) => $"Until {to}",
        _ => "Year",
    };

    private static ToggleButton Chip(string label, bool on, Action toggle)
    {
        var chip = new ToggleButton { Classes = { "chip" }, Content = label, IsChecked = on };
        AutomationProperties.SetName(chip, label);
        chip.Click += (_, _) => toggle();
        return chip;
    }
}
