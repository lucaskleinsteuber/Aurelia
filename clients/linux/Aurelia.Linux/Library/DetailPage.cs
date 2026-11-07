using System.Globalization;
using Aurelia.Contracts;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Playback;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Library;

/// <summary>Shared pieces of the detail pages.</summary>
internal static class DetailChrome
{
    public static Button BackButton(LibraryContext context, Thickness margin)
    {
        var back = new Button
        {
            Classes = { "heroAction" },
            Margin = margin,
            HorizontalAlignment = HorizontalAlignment.Left,
            Content = new PathIcon { Data = Application.Current?.FindResource("IconChevronLeft") as Geometry, Width = 16, Height = 16 },
        };
        AutomationProperties.SetName(back, "Back");
        ToolTip.SetTip(back, "Back (Alt+Left)");
        back.Click += (_, _) => context.Navigator.Back();
        return back;
    }
}

/// <summary>
/// A movie or TV show, as on the Mac: the hero with Play/Resume, favorites, watchlist and more
/// actions; seasons with their episodes; the film series it belongs to; trailers and extras; cast
/// and crew; and the title's information.
/// </summary>
public sealed class DetailPage : LibraryPageBase
{
    public const double HeroHeight = 540;

    private readonly CatalogItemSummary initial;
    private CatalogDetailPresentation? detail;
    private PlaybackPlanResponse? plan;
    private string? error;
    private int? season;

    public DetailPage(LibraryContext context, CatalogItemSummary item) : base(context)
    {
        initial = item;
        if (context.Store.PreparedDetail(item.Id) is { } prepared)
            (detail, plan) = prepared;
        AttachedToVisualTree += async (_, _) => await LoadAsync();
    }

    public CatalogDetailPresentation? Detail => detail;

    public CatalogItemSummary Item => detail?.Item ?? initial;

    protected override void OnStoreChanged() => _ = LoadAsync();

    private async Task LoadAsync()
    {
        var client = Context.Store.Client;
        try
        {
            var detailTask = client.DetailAsync(initial.Id, CancellationToken.None);
            var planTask = client.Supports("library-state-v1") && initial.Kind is MediaKind.Movie or MediaKind.Series or MediaKind.Episode
                ? client.PlaybackPlanAsync(initial.Id, CancellationToken.None)
                : Task.FromResult<PlaybackPlanResponse>(null!);
            await Task.WhenAll(detailTask, planTask);
            detail = detailTask.Result;
            plan = planTask.Result;
            season ??= plan?.Target is { Kind: MediaKind.Episode, SeasonNumber: { } target } ? target : (detail.Seasons.Count > 0 ? detail.Seasons[0].Number : null);
            error = null;
        }
        catch (AureliaApiException failure)
        {
            if (failure.IsAuthenticationFailure) Context.Store.Report(failure);
            error = failure.Status == 404 ? "This title is no longer in the library." : failure.Message;
        }
        Rebuild();
    }

    protected override Control Build()
    {
        var page = new StackPanel { Spacing = 30, Margin = new Thickness(0, 0, 0, 56) };
        page.Children.Add(Hero());
        if (error is not null)
        {
            page.Children.Add(EmptyState("Title Unavailable", error));
            return page;
        }
        if (detail is null)
        {
            page.Children.Add(new ProgressBar { IsIndeterminate = true, Width = 160, Margin = Inset(), HorizontalAlignment = HorizontalAlignment.Left });
            return page;
        }
        if (detail.Seasons.Count > 0) page.Children.Add(Seasons());
        if (detail.Franchise is { Items.Count: > 1 } franchise) page.Children.Add(Franchise(franchise));
        var prefix = Item.Kind == MediaKind.Series ? "Series " : "";
        var trailers = detail.Supplements.Where(s => s.Item.Kind == MediaKind.Trailer).ToList();
        var extras = detail.Supplements.Where(s => s.Item.Kind != MediaKind.Trailer).ToList();
        if (trailers.Count > 0)
            page.Children.Add(Section(prefix + "Trailers", Shelf(prefix + "Trailers", trailers.Select(s => MediaCards.Landscape(Context, s.Item, 360, s.Category.ToUpperInvariant(), plays: true))), trailers.Count));
        if (extras.Count > 0)
            page.Children.Add(Section(prefix + "Extras", Shelf(prefix + "Extras", extras.Select(s => MediaCards.Landscape(Context, s.Item, 360, s.Category.ToUpperInvariant(), plays: true))), extras.Count));
        var people = CastAndCrew(detail.Metadata.Credits);
        if (people.Count > 0)
            page.Children.Add(Section("Cast & Crew", Shelf("Cast & Crew", people.Select(p => MediaCards.Person(Context, p.Credit, p.Role))), people.Count));
        page.Children.Add(About());
        return page;
    }

    private Grid Hero()
    {
        var item = Item;
        var metadata = detail?.Metadata;
        var line = new List<string> { item.Kind == MediaKind.Series ? "TV SHOW" : item.Kind.ToString().ToUpperInvariant() };
        if (item.Year is { } year) line.Add(year.ToString(CultureInfo.InvariantCulture));
        if (metadata?.RuntimeMinutes is { } minutes && item.Kind != MediaKind.Series) line.Add($"{minutes} MIN");
        if (metadata?.FskAge is { } fsk) line.Add($"FSK {fsk}");
        var text = new StackPanel
        {
            Spacing = 12,
            MaxWidth = 700,
            Margin = new Thickness(Leading, 0, PagePadding, 44),
            VerticalAlignment = VerticalAlignment.Bottom,
            HorizontalAlignment = HorizontalAlignment.Left,
            Children =
            {
                new TextBlock { Text = string.Join(" · ", line), Classes = { "eyebrow" }, Foreground = new SolidColorBrush(Color.FromArgb(0xD9, 0xFF, 0xFF, 0xFF)) },
                new TextBlock { Text = item.Title, Classes = { "heroTitle" }, Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap },
                new TextBlock { Text = string.Join("  ·  ", (metadata?.Genres ?? item.Genres).Take(3)), FontWeight = FontWeight.SemiBold, Foreground = Brushes.White },
                new TextBlock { Text = metadata?.Overview ?? item.Overview ?? "", Foreground = new SolidColorBrush(Color.FromArgb(0xE6, 0xFF, 0xFF, 0xFF)), TextWrapping = TextWrapping.Wrap, MaxLines = 4, TextTrimming = TextTrimming.WordEllipsis, LineHeight = 21 },
                Actions(item),
            },
        };
        if (item.Availability != MediaAvailability.Available && item.Kind != MediaKind.Series)
        {
            text.Children.Insert(4, new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0x99, 0x5A, 0x3A, 0x10)),
                CornerRadius = new CornerRadius(12),
                Padding = new Thickness(12, 6),
                HorizontalAlignment = HorizontalAlignment.Left,
                Child = new TextBlock { Text = "This title is offline. Its files are not reachable right now.", Foreground = Brushes.White },
            });
        }
        var starring = metadata?.Credits.Where(c => c.Department == "Acting").OrderBy(c => c.Order).Take(3).Select(c => c.Name).ToList();
        if (starring is { Count: > 0 } && Bounds.Width >= 1040)
            text.Children.Add(new TextBlock { Text = "Starring " + string.Join(", ", starring), Classes = { "subdued" }, Foreground = new SolidColorBrush(Color.FromArgb(0xB3, 0xFF, 0xFF, 0xFF)) });
        return new Grid
        {
            Height = HeroHeight,
            Children =
            {
                new ArtworkImage(Context.Store, metadata?.Backdrop ?? item.Backdrop ?? metadata?.Still ?? item.Poster, 1920),
                new Border { Background = HomePage.HeroShade(0) },
                new Border { Background = HomePage.HeroShade(1) },
                DetailChrome.BackButton(Context, new Thickness(Leading, 64, 0, 0)).Also(b => b.VerticalAlignment = VerticalAlignment.Top),
                text,
            },
        };
    }

    private StackPanel Actions(CatalogItemSummary item)
    {
        var store = Context.Store;
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Margin = new Thickness(0, 6, 0, 0) };
        var target = plan?.Target ?? (LibraryPresentation.IsPlayable(item) ? item : null);
        var label = plan?.Action switch
        {
            PlaybackPlanAction.Resume => "Resume",
            PlaybackPlanAction.PlayAgain => "Play Again",
            _ => "Play",
        };
        if (plan?.Target is { Kind: MediaKind.Episode, SeasonNumber: { } s, EpisodeNumber: { } e }) label += $" S{s:00} E{e:00}";
        var play = new Button
        {
            Classes = { "primary" },
            IsEnabled = target is not null && LibraryPresentation.IsPlayable(target),
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 8,
                Children =
                {
                    new PathIcon { Data = Application.Current?.FindResource("IconPlay") as Geometry, Width = 14, Height = 14 },
                    new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center },
                },
            },
        };
        AutomationProperties.SetName(play, label);
        play.Click += (_, _) =>
        {
            if (target is not null) Context.Play(target, resume: plan?.Action == PlaybackPlanAction.Resume);
        };
        actions.Children.Add(play);
        if (item.Kind is MediaKind.Movie or MediaKind.Series)
        {
            actions.Children.Add(RoundAction(item.IsFavorite ? "IconFavorite" : "IconFavoriteOutline", item.IsFavorite ? "Remove from Favorites" : "Add to Favorites",
                () => _ = store.SetFavoriteAsync(item, !item.IsFavorite)));
            if (store.Client.SupportsWatchlist)
            {
                var listed = store.IsWatchlisted(item.Id);
                actions.Children.Add(RoundAction(listed ? "IconWatchlist" : "IconBookmarkOutline", listed ? "Remove from Watchlist" : "Add to Watchlist",
                    () => _ = store.SetWatchlistAsync(item.Id, !listed)));
            }
        }
        if (Context.Navigator.Remote is { } remote && target is not null && LibraryPresentation.IsPlayable(target))
        {
            // Play On appears only while another Aurelia player is open to receive the title.
            var playOn = RoundAction("IconNetwork", "Play On…", () => { });
            playOn.IsVisible = false;
            actions.Children.Add(playOn);
            _ = OfferPlayOnAsync(playOn, remote, target);
        }
        // Parties others started for this title or one of its episodes, to join with one click.
        var ids = new HashSet<Guid> { item.Id };
        if (detail is not null) foreach (var each in detail.Seasons.SelectMany(s => s.Episodes)) ids.Add(each.Item.Id);
        _ = OfferWatchTogetherAsync(actions, ids);
        var more = RoundAction("IconMore", "More Actions", () => { });
        more.Flyout = new MenuFlyout { ItemsSource = MediaMenu.Items(Context, item, onDetail: true) };
        actions.Children.Add(more);
        if (item.WatchState == CatalogWatchState.Completed)
            actions.Children.Add(new TextBlock { Text = "Watched", VerticalAlignment = VerticalAlignment.Center, Foreground = new SolidColorBrush(Color.FromArgb(0xCC, 0xFF, 0xFF, 0xFF)), Margin = new Thickness(6, 0) });
        return actions;
    }

    private async Task OfferWatchTogetherAsync(Panel actions, HashSet<Guid> ids)
    {
        var parties = await Context.Navigator.WatchPartiesAsync();
        foreach (var party in parties.Where(party => ids.Contains(party.MediaId)))
        {
            var join = new Button { Content = "Join " + party.HostName, Classes = { "chip" }, VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetName(join, "Watch Together with " + party.HostName);
            ToolTip.SetTip(join, $"Watch {party.Title} together with {party.HostName}");
            join.Click += (_, _) => _ = Context.Navigator.JoinWatchTogetherAsync(party);
            actions.Children.Insert(Math.Min(1, actions.Children.Count), join);
        }
    }

    private static async Task OfferPlayOnAsync(Button playOn, RemotePlayback remote, CatalogItemSummary target)
    {
        IReadOnlyList<RemotePlayerDevice> players;
        try
        {
            players = await remote.PlayersAsync();
        }
        catch (Exception failure) when (failure is HttpRequestException or TaskCanceledException)
        {
            return;
        }
        playOn.IsVisible = players.Count > 0;
        playOn.Flyout = new MenuFlyout
        {
            ItemsSource = players.Select(device => MenuItem("Play on " + device.DeviceName, () => _ = remote.PlayAsync(device, target))).Cast<Control>().ToList(),
        };
    }

    private StackPanel Seasons()
    {
        var seasons = detail!.Seasons;
        var current = seasons.FirstOrDefault(s => s.Number == season) ?? seasons[0];
        var watched = current.Episodes.Count > 0 && current.Episodes.All(e => e.Item.WatchState == CatalogWatchState.Completed);
        // As on the Mac: the season's name is the menu, with the seasons and the watch choices in it.
        var menuItems = new List<Control>();
        foreach (var choice in seasons)
        {
            var entry = new MenuItem { Header = SeasonName(choice), ToggleType = MenuItemToggleType.Radio, IsChecked = choice.Number == current.Number };
            entry.Click += (_, _) =>
            {
                if (choice.Number == season) return;
                season = choice.Number;
                Rebuild();
            };
            menuItems.Add(entry);
        }
        if (current.Episodes.Count > 0)
        {
            menuItems.Add(new Separator());
            menuItems.Add(MenuItem(watched ? "Mark Season as Unwatched" : "Mark Season as Watched", () => _ = MediaMenu.MarkAsync(Context, Item.Id, WatchStateScope.Season, !watched, current.Number)));
            menuItems.Add(MenuItem("Mark Series as Watched", () => _ = MediaMenu.MarkAsync(Context, Item.Id, WatchStateScope.Series, true)));
            menuItems.Add(MenuItem("Mark Series as Unwatched", () => _ = MediaMenu.MarkAsync(Context, Item.Id, WatchStateScope.Series, false)));
        }
        var picker = new Button
        {
            Classes = { "seasonMenu" },
            Margin = new Thickness(Math.Max(0, Inset().Left - 8), 0, 0, 0),
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 8,
                Children =
                {
                    new TextBlock { Text = SeasonName(current), Classes = { "sectionTitle" }, VerticalAlignment = VerticalAlignment.Center },
                    new PathIcon { Data = Application.Current?.FindResource("IconChevronDown") as Geometry, Width = 11, Height = 11, VerticalAlignment = VerticalAlignment.Center },
                },
            },
            Flyout = new MenuFlyout { ItemsSource = menuItems, Placement = Avalonia.Controls.PlacementMode.BottomEdgeAlignedLeft },
        };
        AutomationProperties.SetName(picker, "Season");
        ToolTip.SetTip(picker, "Choose a season");
        var header = new DockPanel { LastChildFill = false, Margin = new Thickness(0, 0, Inset().Left, 0) };
        header.Children.Add(picker.Also(p => DockPanel.SetDock(p, Dock.Left)));
        var count = new TextBlock { Text = current.Episodes.Count == 1 ? "1 episode" : $"{current.Episodes.Count} episodes", Classes = { "subdued" }, VerticalAlignment = VerticalAlignment.Center };
        header.Children.Add(count.Also(c => DockPanel.SetDock(c, Dock.Right)));
        if (watched)
            header.Children.Add(new TextBlock { Text = "Watched", Classes = { "subdued" }, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 14, 0) }.Also(w => DockPanel.SetDock(w, Dock.Right)));
        var section = new StackPanel { Spacing = 12, Children = { header } };
        section.Children.Add(Shelf(SeasonName(current), current.Episodes.Select(e => MediaCards.Landscape(Context, e.Item, 420, $"EPISODE {e.EpisodeNumber}", plays: true))));
        if (current.Supplements.Count > 0)
            section.Children.Add(Shelf(SeasonName(current) + " Extras", current.Supplements.Select(s => MediaCards.Landscape(Context, s.Item, 360, s.Category.ToUpperInvariant(), plays: true))));
        return section;
    }

    private StackPanel Franchise(CollectionSummary franchise)
    {
        var save = new Button { Content = "Save as Collection", Classes = { "chip" }, Margin = Inset(), HorizontalAlignment = HorizontalAlignment.Left };
        save.Click += async (_, _) =>
        {
            save.IsEnabled = false;
            await Context.Store.SaveFranchiseAsync(franchise.Id);
        };
        var already = Context.Store.Collections.Any(c => c.Name == franchise.Name);
        var section = Section($"Part of the {franchise.Name}", Shelf(franchise.Name, franchise.Items.Select(item => MediaCards.Poster(Context, item, 154))), franchise.Items.Count);
        if (!already) section.Children.Insert(1, save);
        return section;
    }

    private StackPanel About()
    {
        var metadata = detail!.Metadata;
        var item = Item;
        var facts = new List<(string Label, string Value)>();
        if (item.Kind == MediaKind.Series)
        {
            facts.Add(("Seasons", detail.Seasons.Count.ToString(CultureInfo.InvariantCulture)));
            facts.Add(("Episodes", detail.Seasons.Sum(s => s.Episodes.Count).ToString(CultureInfo.InvariantCulture)));
        }
        else if (metadata.RuntimeMinutes is { } minutes)
        {
            facts.Add(("Runtime", minutes >= 60 ? $"{minutes / 60} h {minutes % 60} min" : $"{minutes} min"));
        }
        if (item.Kind == MediaKind.Series ? metadata.ReleaseDate is not null : item.Year is not null)
            facts.Add((item.Kind == MediaKind.Series ? "Released" : "Release Year", item.Kind == MediaKind.Series ? metadata.ReleaseDate! : item.Year!.Value.ToString(CultureInfo.InvariantCulture)));
        if (metadata.Genres.Count > 0) facts.Add(("Genres", string.Join(", ", metadata.Genres)));
        if (metadata.Studios.Count > 0) facts.Add(("Studio", string.Join(", ", metadata.Studios.Take(3))));
        if (metadata.Countries.Count > 0) facts.Add(("Country of Origin", string.Join(", ", metadata.Countries)));
        if (metadata.FskAge is { } fsk) facts.Add(("FSK", fsk.ToString(CultureInfo.InvariantCulture)));
        var grid = new WrapPanel { ItemSpacing = 40, LineSpacing = 16 };
        foreach (var (label, value) in facts)
        {
            grid.Children.Add(new StackPanel
            {
                Width = 220,
                Spacing = 4,
                Children =
                {
                    new TextBlock { Text = label, Classes = { "subdued" }, FontSize = 12 },
                    new TextBlock { Text = value, TextWrapping = TextWrapping.Wrap },
                },
            });
        }
        var about = new StackPanel { Spacing = 16, Margin = Inset() };
        if (metadata.Overview is { Length: > 0 } overview)
        {
            about.Children.Add(SectionTitle("About"));
            about.Children.Add(new TextBlock { Text = overview, TextWrapping = TextWrapping.Wrap, MaxWidth = 820, HorizontalAlignment = HorizontalAlignment.Left, LineHeight = 21 });
        }
        about.Children.Add(SectionTitle("Information"));
        about.Children.Add(grid);
        return about;
    }

    /// <summary>One entry per person, with all their roles, actors first in billing order (Mac: CreditPresentation).</summary>
    internal static List<(CreditSummary Credit, string Role)> CastAndCrew(IReadOnlyList<CreditSummary> credits) =>
        [.. credits
            .GroupBy(c => c.PersonKey ?? c.Name, StringComparer.OrdinalIgnoreCase)
            .Select(group =>
            {
                var ordered = group.OrderBy(c => c.Department == "Acting" ? 0 : 1).ThenBy(c => c.Order).ToList();
                var roles = ordered.Select(c => c.Department == "Acting" ? c.Character ?? "Actor" : c.Job ?? c.Department).Where(r => r.Length > 0).Distinct();
                return (Credit: ordered[0], Role: string.Join(", ", roles));
            })
            .OrderBy(entry => entry.Credit.Department == "Acting" ? 0 : 1)
            .ThenBy(entry => entry.Credit.Order)];

    private static string SeasonName(SeasonPresentation season) => season.Number == 0 ? "Specials" : $"Season {season.Number}";

    private static Button RoundAction(string icon, string label, Action action)
    {
        var button = new Button
        {
            Classes = { "heroAction" },
            Content = new PathIcon { Data = Application.Current?.FindResource(icon) as Geometry, Width = 16, Height = 16 },
        };
        AutomationProperties.SetName(button, label);
        ToolTip.SetTip(button, label);
        button.Click += (_, _) => action();
        return button;
    }

    private static MenuItem MenuItem(string header, Action action)
    {
        var item = new MenuItem { Header = header };
        item.Click += (_, _) => action();
        return item;
    }
}
