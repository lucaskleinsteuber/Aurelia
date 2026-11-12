using System.Globalization;
using Aurelia.Contracts;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Library;
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
            : Grid(collections, c => MediaCards.Collection(Context, c)));
        var unsaved = franchises.Where(f => !collections.Any(c => c.Name == f.Name)).ToList();
        if (unsaved.Count > 0)
        {
            page.Children.Add(Section("Franchises in Library", Grid(unsaved, Franchise), unsaved.Count));
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
            : Grid(items, item => MediaCards.Poster(Context, item, Context.Store.Preferences.PosterWidth)));
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
        else if (person is not null) page.Children.Add(Grid(person.Items, item => MediaCards.Poster(Context, item, Context.Store.Preferences.PosterWidth)));
        return page;
    }
}

/// <summary>A Box Set or smart collection: cover + backdrop hero, description, ordered members with seasons/episodes, and Play/Resume queue.</summary>
public sealed class CollectionDetailPage : LibraryPageBase
{
    private readonly CollectionSummary collection;
    private readonly HashSet<Guid> expandedMembers = [];
    private CollectionDetail? detail;
    private bool updating;

    public CollectionDetailPage(LibraryContext context, CollectionSummary collection) : base(context)
    {
        this.collection = collection;
        AttachedToVisualTree += async (_, _) => await LoadAsync();
    }

    private CollectionSummary Current => Context.Store.Collections.FirstOrDefault(c => c.Id == collection.Id) ?? collection;

    protected override void OnStoreChanged() => _ = LoadAsync();

    private async Task LoadAsync()
    {
        try
        {
            detail = await Context.Store.Client.CollectionAsync(collection.Id, CancellationToken.None);
        }
        catch (AureliaApiException failure) when (!failure.IsAuthenticationFailure)
        {
            // Keep basic summary fallback when offline or pre-v3 server.
        }
        Rebuild();
    }

    protected override Control Build()
    {
        var current = Current;
        var store = Context.Store;
        var canEdit = detail?.CanEdit ?? BoxSetPresentation.CanEditCollection(current, store);
        var posterArt = detail?.Poster ?? current.Poster ?? (current.Items.Count > 0 ? current.Items[0].Poster : null);
        var backdropArt = detail?.Backdrop ?? current.Backdrop ?? (current.Items.Count > 0 ? LibraryCommon.LandscapeOf(current.Items[0]) : current.Poster);
        var name = detail?.Name ?? current.Name;
        var overview = detail?.Overview ?? current.Overview;
        var provider = detail?.Provider ?? current.Provider;
        var isSmart = detail?.IsSmart ?? current.IsSmart;
        var total = detail?.ItemCount ?? (current.ItemCount > 0 ? current.ItemCount : current.TotalCount > 0 ? current.TotalCount : current.Items.Count);
        var watched = detail?.WatchedCount ?? current.WatchedCount;
        var statsText = detail is not null ? BoxSetPresentation.StatsLine(detail) : BoxSetPresentation.CardSubtitle(current);

        var eyebrowParts = new List<string>
        {
            BoxSetPresentation.ProviderLabel(provider)?.ToUpperInvariant() ?? (isSmart ? "SMART COLLECTION" : "COLLECTION"),
        };
        if (detail is { Genres.Count: > 0 })
        {
            eyebrowParts.Add(string.Join(" · ", detail.Genres.Take(3)).ToUpperInvariant());
        }

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Margin = new Thickness(0, 6, 0, 0) };
        var playlist = detail is not null ? BoxSetPresentation.PlayableItems(detail) : [];
        if (playlist.Count > 0 && detail is not null)
        {
            var play = new Button
            {
                Content = BoxSetPresentation.PlayLabel(detail.NextItem),
                Classes = { "primary" },
            };
            play.Click += async (_, _) =>
            {
                var next = detail.NextItem;
                try
                {
                    next = await store.Client.CollectionNextAsync(current.Id, CancellationToken.None);
                }
                catch (AureliaApiException)
                {
                }
                var target = next?.Item ?? playlist[0];
                var resume = next?.Resume ?? false;
                Context.PlayCollection(playlist, target, resume);
            };
            actions.Children.Add(play);
        }

        if (provider is not null && !canEdit)
        {
            var saveCopy = new Button { Content = "Save as Collection", Classes = { "chip" } };
            saveCopy.Click += async (_, _) =>
            {
                saveCopy.IsEnabled = false;
                var copied = await store.SaveFranchiseAsync(current.Id);
                if (copied is not null) Context.OpenCollection(copied);
                else saveCopy.IsEnabled = true;
            };
            actions.Children.Add(saveCopy);
        }

        if (canEdit)
        {
            var edit = new Button { Content = "Edit", Classes = { "chip" } };
            edit.Click += (_, _) => Context.Navigator.EditCollection(current, null, null);
            actions.Children.Add(edit);
        }

        var text = new StackPanel
        {
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Bottom,
            Children =
            {
                new TextBlock { Text = string.Join("  ·  ", eyebrowParts), Classes = { "eyebrow" }, Foreground = new SolidColorBrush(Color.FromArgb(0xD9, 0xFF, 0xFF, 0xFF)) },
                new TextBlock { Text = name, Classes = { "heroTitle" }, Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap },
                overview is { Length: > 0 }
                    ? new TextBlock { Text = overview, Foreground = new SolidColorBrush(Color.FromArgb(0xD9, 0xFF, 0xFF, 0xFF)), TextWrapping = TextWrapping.Wrap, MaxWidth = 640, MaxLines = 3 }
                    : new Panel(),
                new TextBlock { Text = statsText, Foreground = new SolidColorBrush(Color.FromArgb(0xCC, 0xFF, 0xFF, 0xFF)) },
                total > 0 && watched > 0
                    ? new ProgressBar
                    {
                        Minimum = 0,
                        Maximum = total,
                        Value = Math.Min(watched, total),
                        Width = 260,
                        Height = 5,
                        HorizontalAlignment = HorizontalAlignment.Left,
                    }
                    : new Panel(),
                actions,
            },
        };

        var cover = new Border
        {
            Width = 140,
            Height = 210,
            CornerRadius = new CornerRadius(14),
            ClipToBounds = true,
            VerticalAlignment = VerticalAlignment.Bottom,
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x38, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            Child = new ArtworkImage(store, posterArt, 320),
        };

        var heroContent = new DockPanel
        {
            Margin = new Thickness(Leading, 0, PagePadding, 36),
            VerticalAlignment = VerticalAlignment.Bottom,
            Children =
            {
                cover.Also(c => { DockPanel.SetDock(c, Dock.Left); c.Margin = new Thickness(0, 0, 24, 0); }),
                text,
            },
        };

        var hero = new Grid
        {
            Height = 490,
            Children =
            {
                new ArtworkImage(store, backdropArt, 1920),
                new Border { Background = HomePage.HeroShade(0) },
                new Border { Background = HomePage.HeroShade(1) },
                DetailChrome.BackButton(Context, new Thickness(Leading, 64, 0, 0)).Also(b => b.VerticalAlignment = VerticalAlignment.Top),
                heroContent,
            },
        };

        var page = new StackPanel { Spacing = 24, Margin = new Thickness(0, 0, 0, 48) };
        page.Children.Add(hero);

        if (detail is null)
        {
            page.Children.Add(Section("In This Collection", Grid(current.Items, item => MediaCards.Poster(Context, item, store.Preferences.PosterWidth)), total));
        }
        else if (detail.Members.Count == 0)
        {
            page.Children.Add(EmptyState("No Titles Yet", canEdit
                ? "Edit this collection or use Add to Collection on any title."
                : "Matching titles will appear here automatically."));
        }
        else
        {
            var list = new StackPanel { Spacing = 10, Margin = Inset() };
            var canReorder = canEdit && !isSmart;
            for (var index = 0; index < detail.Members.Count; index++)
            {
                list.Children.Add(MemberRow(detail, detail.Members[index], index, detail.Members.Count, playlist, canReorder));
            }
            var sortLabel = detail.SortMode switch
            {
                "release" => "Sorted by Release Date",
                "title" => "Sorted by Title",
                _ => "Custom Order",
            };
            var heading = new DockPanel
            {
                Margin = Inset(),
                LastChildFill = false,
                Children =
                {
                    new TextBlock { Text = $"In This Collection ({total})", Classes = { "sectionTitle" } }.Also(t => DockPanel.SetDock(t, Dock.Left)),
                    new TextBlock { Text = sortLabel, Classes = { "subdued" }, VerticalAlignment = VerticalAlignment.Bottom }.Also(t => DockPanel.SetDock(t, Dock.Right)),
                },
            };
            page.Children.Add(new StackPanel { Spacing = 12, Children = { heading, list } });
        }
        return page;
    }

    private Border MemberRow(
        CollectionDetail currentDetail,
        CollectionMember member,
        int index,
        int totalMembers,
        IReadOnlyList<CatalogItemSummary> playlist,
        bool canReorder)
    {
        var store = Context.Store;
        var episodes = member.Episodes ?? [];
        var hasEpisodes = episodes.Count > 0;
        var expanded = expandedMembers.Contains(member.Id);
        var title = member.SeasonNumber is { } s
            ? $"{member.Title} · {(s == 0 ? "Specials" : $"Season {s}")}"
            : member.Title;
        var subParts = new List<string>
        {
            member.SeasonNumber is not null ? $"{member.ItemCount ?? episodes.Count} episodes" : member.Kind.ToString(),
        };
        if (member.Item?.Year is { } year) subParts.Add(year.ToString(CultureInfo.InvariantCulture));
        if ((member.ItemCount ?? 1) > 1 && member.WatchedCount is { } wc) subParts.Add($"{wc} of {member.ItemCount} watched");
        else if ((member.WatchedCount ?? 0) > 0) subParts.Add("Watched");

        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        var firstPlayable = hasEpisodes ? (episodes.Count > 0 ? episodes[0] : null) : member.Item is { Kind: MediaKind.Movie or MediaKind.Episode } ? member.Item : null;
        if (firstPlayable is not null)
        {
            var playBtn = new Button { Content = "Play", Classes = { "chip" } };
            playBtn.Click += (_, _) =>
            {
                var resume = firstPlayable.Progress is { IsCompleted: false, PositionMilliseconds: > 0 }
                    || firstPlayable.WatchState == CatalogWatchState.InProgress;
                Context.PlayCollection(playlist, firstPlayable, resume);
            };
            controls.Children.Add(playBtn);
        }

        var openBtn = new Button { Content = "Details", Classes = { "chip" } };
        openBtn.Click += (_, _) =>
        {
            if (member.Item is { } target) Context.OpenDetail(target);
        };
        controls.Children.Add(openBtn);

        if (hasEpisodes)
        {
            var toggleBtn = new Button { Content = expanded ? "Hide Episodes" : $"Episodes ({episodes.Count})", Classes = { "chip" } };
            toggleBtn.Click += (_, _) =>
            {
                if (!expandedMembers.Add(member.Id)) expandedMembers.Remove(member.Id);
                Rebuild();
            };
            controls.Children.Add(toggleBtn);
        }

        if (canReorder)
        {
            var up = new Button { Content = "▲", Classes = { "chip" }, IsEnabled = !updating && index > 0 };
            var down = new Button { Content = "▼", Classes = { "chip" }, IsEnabled = !updating && index < totalMembers - 1 };
            var remove = new Button { Content = "Remove", Classes = { "chip" }, IsEnabled = !updating };
            up.Click += async (_, _) => await ReorderAsync(currentDetail, index, index - 1);
            down.Click += async (_, _) => await ReorderAsync(currentDetail, index, index + 1);
            remove.Click += async (_, _) =>
            {
                updating = true;
                Rebuild();
                await store.RemoveFromCollectionAsync(currentDetail.Id, member.MediaId, member.SeasonNumber);
                updating = false;
                await LoadAsync();
            };
            controls.Children.Add(up);
            controls.Children.Add(down);
            controls.Children.Add(remove);
        }

        var header = new DockPanel
        {
            LastChildFill = true,
            Children =
            {
                new TextBlock { Text = $"{index + 1}.", Width = 28, VerticalAlignment = VerticalAlignment.Center, Classes = { "subdued" } }.Also(n => DockPanel.SetDock(n, Dock.Left)),
                new Border
                {
                    Width = 44,
                    Height = 66,
                    CornerRadius = new CornerRadius(6),
                    ClipToBounds = true,
                    Margin = new Thickness(0, 0, 14, 0),
                    Child = new ArtworkImage(store, member.Item?.Poster ?? member.Item?.Backdrop, 160),
                }.Also(p => DockPanel.SetDock(p, Dock.Left)),
                controls.Also(c => DockPanel.SetDock(c, Dock.Right)),
                new StackPanel
                {
                    Spacing = 4,
                    VerticalAlignment = VerticalAlignment.Center,
                    Children =
                    {
                        new TextBlock { Text = title, FontWeight = FontWeight.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis },
                        new TextBlock { Text = string.Join(" · ", subParts), Classes = { "subdued" }, FontSize = 12 },
                    },
                },
            },
        };

        var cardBody = new StackPanel { Spacing = 10, Children = { header } };
        if (expanded && hasEpisodes)
        {
            cardBody.Children.Add(new Separator());
            var epStack = new StackPanel { Spacing = 6, Margin = new Thickness(42, 0, 0, 0) };
            foreach (var ep in episodes)
            {
                var code = ep.SeasonNumber is { } es && ep.EpisodeNumber is { } en
                    ? $"S{es:00} E{en:00}"
                    : "Episode";
                var epPlay = new Button { Content = "Play", Classes = { "chip" } };
                epPlay.Click += (_, _) =>
                {
                    var resume = ep.Progress is { IsCompleted: false, PositionMilliseconds: > 0 }
                        || ep.WatchState == CatalogWatchState.InProgress;
                    Context.PlayCollection(playlist, ep, resume);
                };
                var row = new DockPanel
                {
                    Children =
                    {
                        new TextBlock { Text = code, Width = 72, Classes = { "subdued" }, VerticalAlignment = VerticalAlignment.Center }.Also(t => DockPanel.SetDock(t, Dock.Left)),
                        epPlay.Also(b => DockPanel.SetDock(b, Dock.Right)),
                        new TextBlock { Text = ep.Title, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis },
                    },
                };
                MediaMenu.Attach(row, Context, ep);
                epStack.Children.Add(row);
            }
            cardBody.Children.Add(epStack);
        }

        return new Border
        {
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(12),
            Background = new SolidColorBrush(Color.FromArgb(0x14, 0xFF, 0xFF, 0xFF)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x1F, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            Child = cardBody,
        };
    }

    private async Task ReorderAsync(CollectionDetail currentDetail, int fromIndex, int toIndex)
    {
        if (fromIndex < 0 || toIndex < 0 || fromIndex >= currentDetail.Members.Count || toIndex >= currentDetail.Members.Count || fromIndex == toIndex) return;
        var reordered = currentDetail.Members.ToList();
        var moved = reordered[fromIndex];
        reordered.RemoveAt(fromIndex);
        reordered.Insert(toIndex, moved);
        updating = true;
        Rebuild();
        var updated = await Context.Store.UpdateCollectionOrderAsync(
            currentDetail.Id,
            [.. reordered.Select(m => new CollectionMemberInput(m.MediaId, m.SeasonNumber))],
            sortMode: "custom");
        updating = false;
        if (updated is not null) detail = updated;
        Rebuild();
    }
}

internal static class LibraryCommon
{
    public static ArtworkSummary? LandscapeOf(CatalogItemSummary item) => item.Backdrop ?? item.Poster;
}
