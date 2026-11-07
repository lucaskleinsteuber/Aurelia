using Aurelia.Contracts;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Api;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Library;

/// <summary>Collections: smart lists and collections, then film series found in the library, each with "Save".</summary>
public sealed class CollectionsPage : LibraryPageBase
{
    private IReadOnlyList<CollectionSummary> franchises = [];

    public CollectionsPage(LibraryContext context) : base(context) =>
        AttachedToVisualTree += async (_, _) => await LoadFranchisesAsync();

    private async Task LoadFranchisesAsync()
    {
        try
        {
            franchises = await Context.Store.Client.FranchisesAsync(CancellationToken.None);
            Rebuild();
        }
        catch (AureliaApiException failure)
        {
            if (failure.Status != 404) Context.Store.Report(failure);
        }
    }

    protected override Control Build()
    {
        var collections = Context.Store.Collections;
        var create = new Button { Content = "New Collection", Classes = { "primary" } };
        create.Click += (_, _) => Context.Navigator.EditCollection(null, null);
        var page = new StackPanel { Spacing = 26, Margin = new Thickness(0, 64, 0, 48) };
        page.Children.Add(new DockPanel
        {
            Margin = Inset(),
            LastChildFill = false,
            Children =
            {
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Children = { PageTitle("Collections"), new TextBlock { Text = collections.Count.ToString(System.Globalization.CultureInfo.InvariantCulture), Classes = { "subdued" }, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 8) } } }.Also(p => DockPanel.SetDock(p, Dock.Left)),
                create.Also(c => DockPanel.SetDock(c, Dock.Right)),
            },
        });
        page.Children.Add(collections.Count == 0
            ? EmptyState("No Collections Yet", "Group titles into a collection, or make a smart list that fills itself by rules.")
            : Grid(collections.Select(c => MediaCards.Collection(Context, c))));
        var unsaved = franchises.Where(f => !collections.Any(c => c.Name == f.Name)).ToList();
        if (unsaved.Count > 0)
        {
            page.Children.Add(Section("Franchises in Library", Grid(unsaved.Select(Franchise)), unsaved.Count));
        }
        return page;
    }

    private StackPanel Franchise(CollectionSummary franchise)
    {
        var save = new Button { Content = "Save", Classes = { "chip" }, HorizontalAlignment = HorizontalAlignment.Left };
        save.Click += async (_, _) =>
        {
            save.IsEnabled = false;
            await Context.Store.SaveFranchiseAsync(franchise.Id);
            await LoadFranchisesAsync();
        };
        return new StackPanel { Spacing = 8, Children = { MediaCards.Collection(Context, franchise), save } };
    }
}

/// <summary>The profile's watchlist.</summary>
public sealed class WatchlistPage : LibraryPageBase
{
    private IReadOnlyList<CatalogItemSummary> items = [];
    private bool loaded;

    public WatchlistPage(LibraryContext context) : base(context) => AttachedToVisualTree += async (_, _) => await LoadAsync();

    protected override void OnStoreChanged() => _ = LoadAsync();

    private async Task LoadAsync()
    {
        try
        {
            items = (await Context.Store.Client.WatchlistAsync(CancellationToken.None)).Items;
        }
        catch (AureliaApiException failure)
        {
            Context.Store.Report(failure);
        }
        loaded = true;
        Rebuild();
    }

    protected override Control Build()
    {
        var page = new StackPanel { Spacing = 26, Margin = new Thickness(0, 64, 0, 48) };
        page.Children.Add(new StackPanel { Margin = Inset(), Children = { PageTitle("Watchlist") } });
        if (!loaded) return page;
        page.Children.Add(items.Count == 0
            ? EmptyState("Your Watchlist Is Empty", "Add movies and shows you want to watch later from their page or with a right click.")
            : Grid(items.Select(item => MediaCards.Poster(Context, item, Context.Store.Preferences.PosterWidth))));
        return page;
    }
}

/// <summary>A person from the cast or crew with every title of theirs in the library.</summary>
public sealed class PersonPage : LibraryPageBase
{
    private readonly string name;
    private readonly string? personKey;
    private PersonDetailResponse? person;
    private string? error;

    public PersonPage(LibraryContext context, string name, string? personKey) : base(context)
    {
        this.name = name;
        this.personKey = personKey;
        AttachedToVisualTree += async (_, _) => await LoadAsync();
    }

    private async Task LoadAsync()
    {
        try
        {
            person = await Context.Store.Client.PersonAsync(name, personKey, CancellationToken.None);
            error = null;
        }
        catch (AureliaApiException failure)
        {
            error = failure.Status == 404 ? "Aurelia found no titles with this person." : failure.Message;
            if (failure.IsAuthenticationFailure) Context.Store.Report(failure);
        }
        Rebuild();
    }

    protected override Control Build()
    {
        var photo = person?.Profile is { } profile
            ? new Border { Width = 84, Height = 84, CornerRadius = new CornerRadius(42), ClipToBounds = true, Child = new ArtworkImage(Context.Store, profile, 84) }
            : (Control)new PersonPlaceholder(84);
        var count = person?.Items.Count ?? 0;
        var page = new StackPanel { Spacing = 24, Margin = new Thickness(0, 64, 0, 48) };
        page.Children.Add(DetailChrome.BackButton(Context, Inset()));
        page.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 18,
            Margin = Inset(),
            Children =
            {
                photo,
                new StackPanel
                {
                    VerticalAlignment = VerticalAlignment.Center,
                    Spacing = 4,
                    Children =
                    {
                        new TextBlock { Text = person?.Subtitle ?? "", Classes = { "subdued" } },
                        PageTitle(person?.Name ?? name),
                        new TextBlock { Text = person is null ? "" : count == 1 ? "1 title in your library" : $"{count} titles in your library", Classes = { "subdued" } },
                    },
                },
            },
        });
        if (error is not null) page.Children.Add(EmptyState("Not Found", error));
        else if (person is not null) page.Children.Add(Grid(person.Items.Select(item => MediaCards.Poster(Context, item, Context.Store.Preferences.PosterWidth))));
        return page;
    }
}

/// <summary>A collection or smart list: hero with the first title's artwork, then its titles.</summary>
public sealed class CollectionDetailPage(LibraryContext context, CollectionSummary collection) : LibraryPageBase(context)
{
    private CollectionSummary Current => Context.Store.Collections.FirstOrDefault(c => c.Id == collection.Id) ?? collection;

    protected override Control Build()
    {
        var current = Current;
        var first = current.Items.Count > 0 ? current.Items[0] : null;
        var store = Context.Store;
        var canEdit = current.UserId == store.Client.Profile.User.Id || (current.IsShared && store.CanManageMedia);
        var count = current.TotalCount > 0 ? current.TotalCount : current.Items.Count;
        var text = new StackPanel
        {
            Spacing = 8,
            Margin = new Thickness(Leading, 0, PagePadding, 40),
            VerticalAlignment = VerticalAlignment.Bottom,
            Children =
            {
                new TextBlock { Text = current.IsSmart ? "SMART COLLECTION" : "COLLECTION", Classes = { "eyebrow" }, Foreground = new SolidColorBrush(Color.FromArgb(0xD9, 0xFF, 0xFF, 0xFF)) },
                new TextBlock { Text = current.Name, Classes = { "heroTitle" }, Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap },
                new TextBlock { Text = count == 1 ? "1 title" : $"{count} titles", Foreground = new SolidColorBrush(Color.FromArgb(0xD9, 0xFF, 0xFF, 0xFF)) },
            },
        };
        if (canEdit)
        {
            var edit = new Button { Content = "Edit", Classes = { "chip" }, HorizontalAlignment = HorizontalAlignment.Left };
            edit.Click += (_, _) => Context.Navigator.EditCollection(current, null);
            text.Children.Add(edit);
        }
        var hero = new Grid
        {
            Height = 460,
            Children =
            {
                new ArtworkImage(store, first is null ? current.Poster : LibraryCommon.LandscapeOf(first), 1920),
                new Border { Background = HomePage.HeroShade(0) },
                new Border { Background = HomePage.HeroShade(1) },
                DetailChrome.BackButton(Context, new Thickness(Leading, 64, 0, 0)).Also(b => b.VerticalAlignment = VerticalAlignment.Top),
                text,
            },
        };
        var page = new StackPanel { Spacing = 24, Margin = new Thickness(0, 0, 0, 48) };
        page.Children.Add(hero);
        page.Children.Add(Section("Titles", Grid(current.Items.Select(item => MediaCards.Poster(Context, item, store.Preferences.PosterWidth))), count));
        return page;
    }
}

internal static class LibraryCommon
{
    public static ArtworkSummary? LandscapeOf(CatalogItemSummary item) => item.Backdrop ?? item.Poster;
}
