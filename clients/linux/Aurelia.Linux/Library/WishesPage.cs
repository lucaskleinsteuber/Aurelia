using Aurelia.Contracts;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Library;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;

namespace Aurelia.Linux.Library;

/// <summary>
/// Family Wishes: search via the server's metadata provider (when enabled) or write a free-text
/// request, add "Me Too" support to open wishes, and for administrators mark titles added or
/// declined without loading the entire catalog unnecessarily.
/// </summary>
public sealed class WishesPage : LibraryPageBase, IDisposable
{
    private const int DecodedPosterCacheLimit = 60;
    private static readonly IBrush CardBackground = new SolidColorBrush(Color.FromArgb(0x16, 0xFF, 0xFF, 0xFF));
    private static readonly IBrush ComposerBackground = new SolidColorBrush(Color.FromArgb(0x1E, 0xFF, 0xFF, 0xFF));
    private static readonly IBrush PillBackground = new SolidColorBrush(Color.FromArgb(0x28, 0xFF, 0xFF, 0xFF));
    private static readonly IBrush ErrorForeground = new SolidColorBrush(Color.Parse("#FF8A8A"));

    private readonly Dictionary<string, Bitmap> decodedPosters = [];
    private readonly LinkedList<string> decodedPosterOrder = new();

    private readonly TextBox searchBox = new TextBox { PlaceholderText = "Search for a movie or TV show…", Width = 320 }.WithGlass();
    private readonly TextBox freeTitleBox = new TextBox { PlaceholderText = "Title", Width = 280 }.WithGlass();
    private readonly TextBox freeYearBox = new TextBox { PlaceholderText = "Year (optional)", Width = 140 }.WithGlass();
    private readonly TextBox noteBox = new TextBox { PlaceholderText = "Optional note for the family (e.g. director's cut)…", Width = 440 }.WithGlass();

    private WishState? stateFilter = WishState.Open;
    private MediaKind composerKind = MediaKind.Movie;
    private bool composerOpen;
    private bool showManualForm;
    private bool loading;
    private bool searching;
    private bool providerEnabled = true;
    private string? statusMessage;
    private string? errorMessage;
    private WishAlreadyInLibraryProblem? conflictProblem;
    private IReadOnlyList<WishSummary> wishes = [];
    private IReadOnlyList<WishSearchHit> searchResults = [];
    private Guid? editingResolveId;
    private WishState editingTargetState = WishState.Fulfilled;
    private string editingNote = "";
    private int shownLimit = WishPresentation.PageSize;
    private CancellationTokenSource? searchCts;
    private CancellationTokenSource? loadCts;

    public WishesPage(LibraryContext context) : base(context)
    {
        AutomationProperties.SetName(searchBox, "Search for a wish");
        AutomationProperties.SetName(freeTitleBox, "Wish title");
        AutomationProperties.SetName(freeYearBox, "Wish release year");
        AutomationProperties.SetName(noteBox, "Wish note");

        searchBox.KeyDown += (_, e) =>
        {
            if (e.Key is Key.Enter or Key.Return && providerEnabled)
            {
                _ = SearchAsync();
                e.Handled = true;
            }
        };

        AttachedToVisualTree += (_, _) => _ = LoadWishesAsync(markSeenIfUnread: true);
        DetachedFromVisualTree += (_, _) => Dispose();
    }

    public void Dispose()
    {
        loadCts?.Cancel();
        loadCts?.Dispose();
        loadCts = null;
        searchCts?.Cancel();
        searchCts?.Dispose();
        searchCts = null;
    }

    internal IReadOnlyList<WishSummary> LoadedWishes => wishes;

    internal WishState? SelectedStateFilter => stateFilter;

    internal bool IsComposerOpen => composerOpen;

    protected override void OnStoreChanged()
    {
        // Only reload the list on external store updates when the page is active in the visual tree.
        if (this.VisualRoot is not null && !loading)
            _ = LoadWishesAsync(markSeenIfUnread: false);
    }

    protected override Control Build()
    {
        var page = new StackPanel { Spacing = 20, Margin = new Thickness(0, 64, 0, 48) };
        page.Children.Add(Header());
        page.Children.Add(FiltersBar());
        if (conflictProblem is { } existing)
            page.Children.Add(ConflictBanner(existing));
        if (!string.IsNullOrEmpty(errorMessage))
            page.Children.Add(NoticeText(errorMessage, isError: true));
        else if (!string.IsNullOrEmpty(statusMessage))
            page.Children.Add(NoticeText(statusMessage, isError: false));
        if (composerOpen)
            page.Children.Add(ComposerCard());
        page.Children.Add(WishesList());
        return page;
    }

    private DockPanel Header()
    {
        var addButton = new Button
        {
            Content = composerOpen ? "Close" : "+ Make a Wish",
            Classes = { composerOpen ? "chip" : "primary" },
            VerticalAlignment = VerticalAlignment.Center,
        };
        addButton.Click += (_, _) =>
        {
            composerOpen = !composerOpen;
            errorMessage = null;
            conflictProblem = null;
            if (composerOpen && !providerEnabled) showManualForm = true;
            Rebuild();
        };

        var refresh = new Button { Content = "Refresh", Classes = { "chip" }, VerticalAlignment = VerticalAlignment.Center };
        refresh.Click += (_, _) => _ = LoadWishesAsync(markSeenIfUnread: true);

        return new DockPanel
        {
            Margin = Inset(),
            LastChildFill = false,
            Children =
            {
                new StackPanel
                {
                    Spacing = 4,
                    Children =
                    {
                        PageTitle("Wishes"),
                        new TextBlock
                        {
                            Text = Context.Store.IsWishAdmin
                                ? "Titles requested by the household. Mark wishes as added when they join the library."
                                : "Ask for a movie or TV show to add to the library.",
                            Classes = { "subdued" },
                        },
                    },
                }.Also(p => DockPanel.SetDock(p, Dock.Left)),
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 10,
                    VerticalAlignment = VerticalAlignment.Center,
                    Children = { refresh, addButton },
                }.Also(p => DockPanel.SetDock(p, Dock.Right)),
            },
        };
    }

    private StackPanel FiltersBar()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = Inset() };
        (WishState? Filter, string Label)[] choices =
        [
            (WishState.Open, "Open"),
            (WishState.Fulfilled, "Added"),
            (WishState.Declined, "Declined"),
            (null, "All"),
        ];
        foreach (var (filter, label) in choices)
        {
            var button = new ToggleButton
            {
                Content = label,
                Classes = { "chip" },
                IsChecked = stateFilter == filter,
            };
            button.Click += (_, _) =>
            {
                stateFilter = filter;
                shownLimit = WishPresentation.PageSize;
                editingResolveId = null;
                _ = LoadWishesAsync(markSeenIfUnread: true);
            };
            row.Children.Add(button);
        }
        return row;
    }

    private TextBlock NoticeText(string message, bool isError) => new()
    {
        Text = message,
        Margin = Inset(),
        Foreground = isError ? ErrorForeground : Brushes.White,
        Classes = { isError ? "" : "subdued" },
        TextWrapping = TextWrapping.Wrap,
        MaxWidth = 680,
    };

    private Border ConflictBanner(WishAlreadyInLibraryProblem existing)
    {
        var openTitle = new Button { Content = $"Open \"{existing.Title}\"", Classes = { "primary" } };
        openTitle.Click += (_, _) => _ = OpenLibraryItemAsync(existing.MediaId);
        return new Border
        {
            Margin = Inset(),
            Padding = new Thickness(16),
            CornerRadius = new CornerRadius(12),
            Background = ComposerBackground,
            MaxWidth = 720,
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = new DockPanel
            {
                LastChildFill = true,
                Children =
                {
                    openTitle.Also(b => DockPanel.SetDock(b, Dock.Right)),
                    new StackPanel
                    {
                        Spacing = 4,
                        Margin = new Thickness(0, 0, 16, 0),
                        Children =
                        {
                            new TextBlock { Text = "Already in the library", FontWeight = FontWeight.SemiBold },
                            new TextBlock { Text = existing.Message, Classes = { "subdued" }, TextWrapping = TextWrapping.Wrap },
                        },
                    },
                },
            },
        };
    }

    private Border ComposerCard()
    {
        DetachParent(searchBox);
        DetachParent(freeTitleBox);
        DetachParent(freeYearBox);
        DetachParent(noteBox);

        var movieChip = new ToggleButton { Content = "Movie", Classes = { "chip" }, IsChecked = composerKind == MediaKind.Movie };
        movieChip.Click += (_, _) => { composerKind = MediaKind.Movie; Rebuild(); };
        var seriesChip = new ToggleButton { Content = "TV Show", Classes = { "chip" }, IsChecked = composerKind == MediaKind.Series };
        seriesChip.Click += (_, _) => { composerKind = MediaKind.Series; Rebuild(); };

        var body = new StackPanel { Spacing = 14 };
        body.Children.Add(new TextBlock { Text = "New Wish", FontSize = 18, FontWeight = FontWeight.SemiBold });
        body.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { movieChip, seriesChip } });

        if (providerEnabled)
        {
            var searchBtn = new Button
            {
                Content = searching ? "Searching…" : "Search",
                Classes = { "primary" },
                IsEnabled = !searching,
            };
            searchBtn.Click += (_, _) => _ = SearchAsync();

            var manualToggle = new Button
            {
                Content = showManualForm ? "Hide Manual Entry" : "Add Manually Instead",
                Classes = { "link" },
            };
            manualToggle.Click += (_, _) => { showManualForm = !showManualForm; Rebuild(); };

            body.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { searchBox, searchBtn, manualToggle } });
            body.Children.Add(noteBox);

            if (searchResults.Count > 0)
            {
                var resultsList = new StackPanel { Spacing = 8 };
                foreach (var hit in searchResults) resultsList.Children.Add(SearchHitRow(hit));
                body.Children.Add(resultsList);
            }
        }

        if (!providerEnabled || showManualForm)
        {
            var submit = new Button { Content = "Send Wish", Classes = { "primary" } };
            submit.Click += (_, _) => _ = SubmitManualWishAsync();
            body.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { freeTitleBox, freeYearBox } });
            if (!providerEnabled) body.Children.Add(noteBox);
            body.Children.Add(submit);
        }

        return new Border
        {
            Margin = Inset(),
            Padding = new Thickness(18),
            CornerRadius = new CornerRadius(12),
            Background = ComposerBackground,
            MaxWidth = 820,
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = body,
        };
    }

    private Border SearchHitRow(WishSearchHit hit)
    {
        Control action;
        if (hit.AlreadyInLibrary && hit.ExistingMediaId is { } mediaId)
        {
            var openBtn = new Button { Content = "In Library", Classes = { "chip" } };
            openBtn.Click += (_, _) => _ = OpenLibraryItemAsync(mediaId);
            action = openBtn;
        }
        else if (hit.AlreadyWished && hit.ExistingWishId is { } wishId)
        {
            if (hit.SupportedByCaller)
            {
                action = new TextBlock { Text = "Already Wished", Classes = { "subdued" }, VerticalAlignment = VerticalAlignment.Center };
            }
            else
            {
                var meToo = new Button { Content = "+ Me Too", Classes = { "chip" } };
                meToo.Click += (_, _) => _ = ToggleSupportAsync(wishId, supported: true);
                action = meToo;
            }
        }
        else
        {
            var wishBtn = new Button { Content = "Wish This", Classes = { "primary" } };
            wishBtn.Click += (_, _) => _ = SubmitSearchHitAsync(hit);
            action = wishBtn;
        }

        var meta = WishPresentation.KindLabel(hit.Kind) + (hit.Year is { } year ? $" · {year}" : "");
        return new Border
        {
            Padding = new Thickness(12),
            CornerRadius = new CornerRadius(10),
            Background = CardBackground,
            Child = new DockPanel
            {
                LastChildFill = true,
                Children =
                {
                    PosterThumbnail(hit.PosterPath, hit.Kind, width: 42, height: 63).Also(p =>
                    {
                        p.Margin = new Thickness(0, 0, 12, 0);
                        DockPanel.SetDock(p, Dock.Left);
                    }),
                    action.Also(b =>
                    {
                        b.Margin = new Thickness(12, 0, 0, 0);
                        DockPanel.SetDock(b, Dock.Right);
                    }),
                    new StackPanel
                    {
                        Spacing = 3,
                        VerticalAlignment = VerticalAlignment.Center,
                        Children =
                        {
                            new TextBlock { Text = hit.Title, FontWeight = FontWeight.SemiBold },
                            new TextBlock { Text = meta, Classes = { "subdued" }, FontSize = 12 },
                            hit.Overview is { Length: > 0 } overview
                                ? new TextBlock { Text = overview, Classes = { "subdued" }, FontSize = 12, MaxLines = 2, TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis }
                                : new Panel(),
                        },
                    },
                },
            },
        };
    }

    private Control WishesList()
    {
        if (loading && wishes.Count == 0)
        {
            return new TextBlock { Text = "Loading wishes…", Classes = { "subdued" }, Margin = Inset(20) };
        }
        if (wishes.Count == 0)
        {
            var subtitle = stateFilter switch
            {
                WishState.Open => "No open wishes yet.",
                WishState.Fulfilled => "No added wishes yet.",
                WishState.Declined => "No declined wishes.",
                _ => "No wishes yet.",
            };
            return EmptyState(subtitle, "Make a wish above when you'd like to see a movie or TV show added.");
        }

        var stack = new StackPanel { Spacing = 12, Margin = Inset(), MaxWidth = 860, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var wish in wishes.Take(shownLimit))
        {
            stack.Children.Add(WishCard(wish));
        }
        var remaining = wishes.Count - shownLimit;
        if (remaining > 0)
        {
            var more = new Button { Content = $"Show More ({remaining} remaining)", Classes = { "chip" }, HorizontalAlignment = HorizontalAlignment.Left };
            more.Click += (_, _) =>
            {
                shownLimit += WishPresentation.PageSize;
                Rebuild();
            };
            stack.Children.Add(more);
        }
        return stack;
    }

    private Border WishCard(WishSummary wish)
    {
        var currentUser = Context.Store.Client.Profile.User;
        var isOwnerOrAdmin = Context.Store.IsWishAdmin;
        var isOwnWish = wish.UserId == currentUser.Id;
        var titleText = wish.Year is { } year ? $"{wish.Title} ({year})" : wish.Title;

        var badges = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        badges.Children.Add(BadgePill(WishPresentation.KindLabel(wish.Kind)));
        badges.Children.Add(BadgePill(WishPresentation.StateLabel(wish.State)));
        if (wish.AgeRating is { Length: > 0 } rating) badges.Children.Add(BadgePill(rating));
        if (wish.State == WishState.Fulfilled && isOwnWish && wish.SeenByWisherAt is null) badges.Children.Add(BadgePill("New"));

        var details = new StackPanel { Spacing = 4 };
        details.Children.Add(new TextBlock { Text = titleText, FontSize = 16, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap });
        details.Children.Add(badges);
        details.Children.Add(new TextBlock
        {
            Text = $"Requested by {wish.UserName}",
            Classes = { "subdued" },
            FontSize = 12,
        });
        var supporters = WishPresentation.SupportersLine(wish);
        if (supporters.Length > 0)
            details.Children.Add(new TextBlock { Text = supporters, Classes = { "subdued" }, FontSize = 12, TextWrapping = TextWrapping.Wrap });
        if (wish.Note is { Length: > 0 } note)
            details.Children.Add(new TextBlock { Text = $"Note: {note}", FontSize = 13, TextWrapping = TextWrapping.Wrap });
        if (wish.Overview is { Length: > 0 } overview)
            details.Children.Add(new TextBlock { Text = overview, Classes = { "subdued" }, FontSize = 12, MaxLines = 3, TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis });
        if (wish.State != WishState.Open && (wish.ResolvedByUserName is { Length: > 0 } || wish.ResolutionNote is { Length: > 0 }))
        {
            var resolved = wish.State == WishState.Fulfilled ? "Added" : "Declined";
            var by = wish.ResolvedByUserName is { Length: > 0 } adminName ? $" by {adminName}" : "";
            var rnote = wish.ResolutionNote is { Length: > 0 } rn ? $": {rn}" : "";
            details.Children.Add(new TextBlock { Text = $"{resolved}{by}{rnote}", Classes = { "subdued" }, FontSize = 12, TextWrapping = TextWrapping.Wrap });
        }

        var actions = new StackPanel { Spacing = 6, Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (wish.State == WishState.Open)
        {
            if (wish.CanSupport)
            {
                var meToo = new Button
                {
                    Content = wish.SupportedByCaller ? "Withdraw Me Too" : "Me Too",
                    Classes = { wish.SupportedByCaller ? "chip" : "primary" },
                };
                meToo.Click += (_, _) => _ = ToggleSupportAsync(wish.Id, !wish.SupportedByCaller);
                actions.Children.Add(meToo);
            }
            if (isOwnerOrAdmin)
            {
                var fulfill = new Button { Content = "Mark Added", Classes = { "primary" } };
                fulfill.Click += (_, _) => _ = UpdateWishStateAsync(wish.Id, WishState.Fulfilled, note: null, mediaId: null);
                actions.Children.Add(fulfill);

                var decline = new Button { Content = "Decline", Classes = { "chip" } };
                decline.Click += (_, _) =>
                {
                    editingResolveId = wish.Id;
                    editingTargetState = WishState.Declined;
                    editingNote = "";
                    Rebuild();
                };
                actions.Children.Add(decline);
            }
        }
        else if (wish.State == WishState.Fulfilled && wish.FulfilledMediaItemId is { } mediaId)
        {
            var openTitle = new Button { Content = "Open Title", Classes = { "primary" } };
            openTitle.Click += (_, _) => _ = OpenLibraryItemAsync(mediaId);
            actions.Children.Add(openTitle);
        }

        if (isOwnerOrAdmin && wish.State != WishState.Open)
        {
            var reopen = new Button { Content = "Reopen", Classes = { "chip" } };
            reopen.Click += (_, _) => _ = UpdateWishStateAsync(wish.Id, WishState.Open, note: null, mediaId: null);
            actions.Children.Add(reopen);
        }

        if (isOwnWish || isOwnerOrAdmin)
        {
            var remove = new Button { Content = "Remove", Classes = { "chip" } };
            remove.Click += (_, _) => _ = RemoveWishAsync(wish, confirm: !isOwnWish);
            actions.Children.Add(remove);
        }

        var container = new StackPanel { Spacing = 10 };
        container.Children.Add(new DockPanel
        {
            LastChildFill = true,
            Children =
            {
                PosterThumbnail(wish.PosterPath, wish.Kind, width: 64, height: 96).Also(p =>
                {
                    p.Margin = new Thickness(0, 0, 14, 0);
                    DockPanel.SetDock(p, Dock.Left);
                }),
                actions.Also(a =>
                {
                    a.Margin = new Thickness(12, 0, 0, 0);
                    DockPanel.SetDock(a, Dock.Right);
                }),
                details,
            },
        });

        if (isOwnerOrAdmin && wish.State == WishState.Open && wish.Suggestions.Count > 0)
        {
            var suggestionsRow = new WrapPanel { Orientation = Orientation.Horizontal };
            suggestionsRow.Children.Add(new TextBlock
            {
                Text = "Possible match: ",
                Classes = { "subdued" },
                FontSize = 12,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 4, 6, 4),
            });
            foreach (var match in wish.Suggestions)
            {
                var label = match.Year is { } my ? $"{match.Title} ({my})" : match.Title;
                var linkButton = new Button
                {
                    Content = $"Link \"{label}\"",
                    Classes = { "chip" },
                    Margin = new Thickness(0, 2, 6, 2),
                };
                linkButton.Click += (_, _) => _ = UpdateWishStateAsync(wish.Id, WishState.Fulfilled, note: null, mediaId: match.MediaId);
                suggestionsRow.Children.Add(linkButton);
            }
            container.Children.Add(suggestionsRow);
        }

        if (isOwnerOrAdmin && editingResolveId == wish.Id)
        {
            var noteInput = new TextBox { PlaceholderText = "Optional reason or note…", Text = editingNote, Width = 360 }.WithGlass();
            noteInput.TextChanged += (_, _) => editingNote = noteInput.Text ?? "";
            var confirmDecline = new Button { Content = "Confirm Decline", Classes = { "primary" } };
            confirmDecline.Click += (_, _) => _ = UpdateWishStateAsync(wish.Id, editingTargetState, editingNote, mediaId: null);
            var cancelDecline = new Button { Content = "Cancel", Classes = { "chip" } };
            cancelDecline.Click += (_, _) => { editingResolveId = null; Rebuild(); };
            container.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 8,
                Children = { noteInput, confirmDecline, cancelDecline },
            });
        }

        return new Border
        {
            Padding = new Thickness(14),
            CornerRadius = new CornerRadius(12),
            Background = CardBackground,
            Child = container,
        };
    }

    private static Border BadgePill(string text) => new()
    {
        Padding = new Thickness(8, 2),
        CornerRadius = new CornerRadius(8),
        Background = PillBackground,
        Child = new TextBlock { Text = text, FontSize = 11, FontWeight = FontWeight.SemiBold },
    };

    private LazyWishPoster PosterThumbnail(string? posterPath, MediaKind kind, double width, double height) =>
        new(Context.Store, posterPath, kind, width, height, TryGetDecoded, RememberDecoded);

    private Bitmap? TryGetDecoded(string posterPath)
    {
        if (!decodedPosters.TryGetValue(posterPath, out var bitmap)) return null;
        decodedPosterOrder.Remove(posterPath);
        decodedPosterOrder.AddFirst(posterPath);
        return bitmap;
    }

    private void RememberDecoded(string posterPath, Bitmap bitmap)
    {
        if (decodedPosters.ContainsKey(posterPath))
            decodedPosterOrder.Remove(posterPath);
        decodedPosters[posterPath] = bitmap;
        decodedPosterOrder.AddFirst(posterPath);
        while (decodedPosters.Count > DecodedPosterCacheLimit && decodedPosterOrder.Last is { } oldest)
        {
            decodedPosters.Remove(oldest.Value);
            decodedPosterOrder.RemoveLast();
        }
    }

    internal async Task LoadWishesAsync(bool markSeenIfUnread)
    {
        loadCts?.Cancel();
        loadCts?.Dispose();
        loadCts = new CancellationTokenSource();
        var token = loadCts.Token;
        loading = true;
        errorMessage = null;
        Rebuild();
        try
        {
            var response = await Context.Store.Client.WishesAsync(stateFilter, token);
            if (token.IsCancellationRequested) return;
            wishes = response.Wishes;
            providerEnabled = response.ProviderEnabled;
            Context.Store.UpdateWishSummary(new(response.OpenCount, response.NewlyFulfilledCount));
            if (markSeenIfUnread && response.NewlyFulfilledCount > 0)
            {
                await Context.Store.Client.MarkWishesSeenAsync(token);
                Context.Store.UpdateWishSummary(new(response.OpenCount, 0));
            }
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (AureliaApiException failure)
        {
            errorMessage = failure.Message;
        }
        finally
        {
            loading = false;
            Rebuild();
        }
    }

    private async Task SearchAsync()
    {
        var query = (searchBox.Text ?? "").Trim();
        if (query.Length == 0)
        {
            searchResults = [];
            Rebuild();
            return;
        }
        searchCts?.Cancel();
        searchCts?.Dispose();
        searchCts = new CancellationTokenSource();
        var token = searchCts.Token;
        searching = true;
        errorMessage = null;
        conflictProblem = null;
        Rebuild();
        try
        {
            var response = await Context.Store.Client.SearchWishesAsync(query, composerKind, token);
            if (token.IsCancellationRequested) return;
            searchResults = response.Results;
            providerEnabled = response.ProviderEnabled;
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (AureliaApiException failure)
        {
            errorMessage = failure.Message;
        }
        finally
        {
            searching = false;
            Rebuild();
        }
    }

    private Task SubmitSearchHitAsync(WishSearchHit hit) =>
        SubmitRequestAsync(new CreateWishRequest(
            hit.Kind,
            hit.Title,
            hit.Year,
            hit.Provider,
            hit.ProviderMediaId,
            hit.Overview,
            hit.PosterPath,
            TrimOrNull(noteBox.Text)));

    private Task SubmitManualWishAsync()
    {
        var title = (freeTitleBox.Text ?? "").Trim();
        if (title.Length == 0)
        {
            errorMessage = "Enter a title.";
            Rebuild();
            return Task.CompletedTask;
        }
        var year = WishPresentation.ParseYear(freeYearBox.Text, out var yearError);
        if (yearError is not null)
        {
            errorMessage = yearError;
            Rebuild();
            return Task.CompletedTask;
        }
        return SubmitRequestAsync(new CreateWishRequest(
            composerKind,
            title,
            year,
            Note: TrimOrNull(noteBox.Text)));
    }

    private async Task SubmitRequestAsync(CreateWishRequest request)
    {
        errorMessage = null;
        statusMessage = null;
        conflictProblem = null;
        try
        {
            var outcome = await Context.Store.Client.CreateWishAsync(request, CancellationToken.None);
            switch (outcome.Status)
            {
                case CreateWishStatus.AlreadyInLibrary:
                    conflictProblem = outcome.Existing;
                    break;
                case CreateWishStatus.MergedSupport:
                    statusMessage = "Added your \"Me Too\" support to the existing wish.";
                    composerOpen = false;
                    searchResults = [];
                    break;
                default:
                    statusMessage = "Wish sent.";
                    composerOpen = false;
                    freeTitleBox.Text = "";
                    freeYearBox.Text = "";
                    noteBox.Text = "";
                    searchResults = [];
                    break;
            }
            await LoadWishesAsync(markSeenIfUnread: false);
        }
        catch (AureliaApiException failure)
        {
            errorMessage = failure.Message;
            Rebuild();
        }
    }

    private async Task ToggleSupportAsync(Guid wishId, bool supported)
    {
        errorMessage = null;
        try
        {
            await Context.Store.Client.SetWishSupportAsync(wishId, supported, CancellationToken.None);
            await LoadWishesAsync(markSeenIfUnread: false);
        }
        catch (AureliaApiException failure)
        {
            errorMessage = failure.Message;
            Rebuild();
        }
    }

    private async Task UpdateWishStateAsync(Guid wishId, WishState state, string? note, Guid? mediaId)
    {
        errorMessage = null;
        try
        {
            await Context.Store.Client.UpdateWishStateAsync(wishId, new UpdateWishStateRequest(state, TrimOrNull(note), mediaId), CancellationToken.None);
            editingResolveId = null;
            editingNote = "";
            await LoadWishesAsync(markSeenIfUnread: false);
        }
        catch (AureliaApiException failure)
        {
            errorMessage = failure.Message;
            Rebuild();
        }
    }

    private async Task RemoveWishAsync(WishSummary wish, bool confirm)
    {
        if (confirm && !await Context.Navigator.ConfirmAsync("Remove Wish?", $"Remove \"{wish.Title}\" from the family wishes list?", "Remove", destructive: true))
            return;
        errorMessage = null;
        try
        {
            await Context.Store.Client.DeleteWishAsync(wish.Id, CancellationToken.None);
            await LoadWishesAsync(markSeenIfUnread: false);
        }
        catch (AureliaApiException failure)
        {
            errorMessage = failure.Message;
            Rebuild();
        }
    }

    private async Task OpenLibraryItemAsync(Guid mediaId)
    {
        var item = Context.Store.Catalog.FirstOrDefault(entry => entry.Id == mediaId);
        if (item is null)
        {
            try
            {
                item = await Context.Store.Client.SummaryAsync(mediaId, CancellationToken.None);
            }
            catch (AureliaApiException failure)
            {
                errorMessage = failure.Message;
                Rebuild();
                return;
            }
        }
        Context.OpenDetail(item);
    }

    private static string? TrimOrNull(string? text)
    {
        var trimmed = (text ?? "").Trim();
        return trimmed.Length > 0 ? trimmed : null;
    }

    private static void DetachParent(Control control)
    {
        if (control.Parent is Panel panel) panel.Children.Remove(control);
    }

    /// <summary>Loads a proxied wish poster only after the row nears the visible viewport.</summary>
    private sealed class LazyWishPoster : Border, IDisposable
    {
        private readonly LibraryStore store;
        private readonly string? posterPath;
        private readonly Func<string, Bitmap?> tryMemoryBitmap;
        private readonly Action<string, Bitmap> rememberBitmap;
        private CancellationTokenSource? fetchCts;
        private bool started;

        public LazyWishPoster(
            LibraryStore store,
            string? posterPath,
            MediaKind kind,
            double width,
            double height,
            Func<string, Bitmap?> tryMemoryBitmap,
            Action<string, Bitmap> rememberBitmap)
        {
            this.store = store;
            this.posterPath = posterPath;
            this.tryMemoryBitmap = tryMemoryBitmap;
            this.rememberBitmap = rememberBitmap;

            Width = width;
            Height = height;
            CornerRadius = new CornerRadius(6);
            ClipToBounds = true;
            Background = new SolidColorBrush(Color.FromArgb(0x22, 0xFF, 0xFF, 0xFF));

            if (!string.IsNullOrWhiteSpace(posterPath) && tryMemoryBitmap(posterPath) is { } cached)
            {
                Child = new Image { Source = cached, Stretch = Stretch.UniformToFill };
                started = true;
                return;
            }

            Child = new PathIcon
            {
                Data = Application.Current?.FindResource(kind == MediaKind.Series ? "IconTvShows" : "IconMovies") as Geometry,
                Width = 20,
                Height = 20,
                Foreground = new SolidColorBrush(Color.FromArgb(0x88, 0xFF, 0xFF, 0xFF)),
            };

            EffectiveViewportChanged += (_, e) =>
            {
                if (!started && e.EffectiveViewport.Width > 0 && e.EffectiveViewport.Height > 0)
                    StartLoad();
            };
            DetachedFromVisualTree += (_, _) => Dispose();
        }

        public void Dispose()
        {
            fetchCts?.Cancel();
            fetchCts?.Dispose();
            fetchCts = null;
        }

        private void StartLoad()
        {
            if (started || string.IsNullOrWhiteSpace(posterPath)) return;
            started = true;
            fetchCts = new CancellationTokenSource();
            var token = fetchCts.Token;
            var path = posterPath;
            _ = LoadAsync(path, token);
        }

        private async Task LoadAsync(string path, CancellationToken token)
        {
            try
            {
                var bytes = store.WishPosters.TryMemory(store.Client, path)
                    ?? await store.WishPosters.LoadAsync(store.Client, path, token);
                if (token.IsCancellationRequested || bytes is not { Length: > 0 }) return;
                Bitmap? decoded = null;
                try
                {
                    using var stream = new MemoryStream(bytes, writable: false);
                    decoded = Bitmap.DecodeToWidth(stream, 130);
                }
                catch (Exception error) when (error is ArgumentException or InvalidOperationException or NotSupportedException or IOException)
                {
                    return;
                }
                if (token.IsCancellationRequested) return;
                Dispatcher.UIThread.Post(() =>
                {
                    if (token.IsCancellationRequested) return;
                    rememberBitmap(path, decoded);
                    Child = new Image { Source = decoded, Stretch = Stretch.UniformToFill };
                });
            }
            catch (OperationCanceledException)
            {
            }
        }
    }
}
