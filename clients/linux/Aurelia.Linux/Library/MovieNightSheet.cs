using Aurelia.Contracts;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Playback;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;

namespace Aurelia.Linux.Library;

/// <summary>
/// Movie Night in a sheet: the lobby, the stack of posters to drag, click or swipe with the arrow
/// keys, and the match as a cinema ticket. Closing the sheet leaves the night; the shell plays
/// <see cref="PlayRequested"/> afterwards.
/// </summary>
public sealed class MovieNightSheet : UserControl, IDisposable
{
    private static readonly IBrush Yes = new SolidColorBrush(Color.Parse("#FFC93C"));
    private static readonly IBrush Nope = new SolidColorBrush(Color.Parse("#FF4D5A"));
    private static readonly IBrush Paper = new SolidColorBrush(Color.Parse("#F4EAD3"));
    private static readonly IBrush Stub = new SolidColorBrush(Color.Parse("#EADBB8"));
    private static readonly IBrush Ink = new SolidColorBrush(Color.Parse("#2B1D12"));

    private readonly LibraryContext context;
    private readonly SheetHost host;
    private readonly MovieNightSession session;
    private readonly ContentControl body = new();
    private bool dragging;
    private bool dirty;

    public MovieNightSheet(LibraryContext context, SheetHost host, MovieNightSummary? joining)
    {
        this.context = context;
        this.host = host;
        session = new MovieNightSession(context.Store.Client, Environment.MachineName is { Length: > 0 } name ? name : "Linux PC",
            action => Dispatcher.UIThread.Post(action));
        session.PropertyChanged += (_, _) => Refresh();
        Width = 600;
        Height = 760;
        Focusable = true;
        var leave = new Button { Content = "Leave", Classes = { "chip" } };
        leave.Click += (_, _) => host.Close(false);
        Content = new DockPanel
        {
            Children =
            {
                Docked(new DockPanel
                {
                    Margin = new Thickness(0, 0, 0, 16),
                    Children =
                    {
                        Docked(leave, Dock.Right),
                        new TextBlock { Text = "Movie Night", FontSize = 15, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center },
                    },
                }, Dock.Top),
                new ScrollViewer { Content = body },
            },
        };
        KeyDown += OnKeyDown;
        AttachedToVisualTree += async (_, _) =>
        {
            Focus();
            Render();
            if (joining is { } night) await session.JoinAsync(night.Id);
            else await session.StartAsync();
        };
    }

    /// <summary>The match to play once the sheet has closed.</summary>
    public CatalogItemSummary? PlayRequested { get; private set; }

    public Task LeaveAsync() => session.LeaveAsync();

    public void Dispose() => session.Dispose();

    private static T Docked<T>(T control, Dock dock) where T : Control
    {
        DockPanel.SetDock(control, dock);
        return control;
    }

    private void Refresh()
    {
        if (dragging)
        {
            dirty = true;
            return;
        }
        Render();
    }

    private void Render()
    {
        dirty = false;
        var page = new StackPanel { Spacing = 18 };
        if (session.Error is { } error)
        {
            page.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.Parse("#2EFF4D5A")),
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(12),
                Child = new TextBlock { Text = error, TextWrapping = TextWrapping.Wrap },
            });
        }
        page.Children.Add(session.Screen switch
        {
            MovieNightScreen.Lobby => Lobby(session.State!),
            MovieNightScreen.Swipe => Swipe(session.State!),
            MovieNightScreen.Waiting => Waiting(session.State!),
            MovieNightScreen.Match or MovieNightScreen.NoMatch => Result(session.State!),
            _ => new Aurelia.Linux.Controls.Spinner { Margin = new Thickness(0, 160, 0, 0), HorizontalAlignment = HorizontalAlignment.Center },
        });
        body.Content = page;
    }

    private static StackPanel Heading(string title, string? text)
    {
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(new TextBlock { Text = title, FontSize = 30, FontWeight = FontWeight.Heavy });
        if (text is not null) panel.Children.Add(new TextBlock { Text = text, Classes = { "subdued" }, FontSize = 15, TextWrapping = TextWrapping.Wrap });
        return panel;
    }

    private static StackPanel People(MovieNightState state, int deckSize = 0)
    {
        var list = new StackPanel();
        foreach (var member in state.Members)
        {
            var detail = string.Join(" · ", new[] { member.DeviceName, member.IsHost ? "started it" : null, member.IsVoting ? null : "only watches" }.OfType<string>());
            var row = new DockPanel { Margin = new Thickness(0, 8) };
            if (deckSize > 0 && member.IsVoting)
                row.Children.Add(Docked(new TextBlock { Text = $"{member.Swiped}/{deckSize}", Classes = { "subdued" }, VerticalAlignment = VerticalAlignment.Center }, Dock.Right));
            row.Children.Add(Docked(new Border
            {
                Width = 34,
                Height = 34,
                CornerRadius = new CornerRadius(17),
                Background = new SolidColorBrush(Color.Parse("#1FFFFFFF")),
                Margin = new Thickness(0, 0, 12, 0),
                Child = new TextBlock
                {
                    Text = member.Name.Trim() is { Length: > 0 } name ? name[..1].ToUpperInvariant() : "?",
                    FontWeight = FontWeight.Bold,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            }, Dock.Left));
            row.Children.Add(new StackPanel
            {
                Children =
                {
                    new TextBlock { Text = member.IsYou ? $"{member.Name} (you)" : member.Name, FontWeight = FontWeight.SemiBold },
                    new TextBlock { Text = detail, Classes = { "subdued" }, FontSize = 13 },
                },
            });
            list.Children.Add(row);
        }
        return list;
    }

    private static Button Action(string label, Func<Task> action, bool primary = false)
    {
        var button = new Button { Content = label, Classes = { primary ? "primary" : "chip" } };
        button.Click += async (_, _) => await action();
        return button;
    }

    private static WrapPanel Row(params Control?[] controls)
    {
        var row = new WrapPanel { ItemSpacing = 10, LineSpacing = 10 };
        foreach (var control in controls.OfType<Control>()) row.Children.Add(control);
        return row;
    }

    private StackPanel Lobby(MovieNightState state)
    {
        var voters = state.Members.Count(member => member.IsVoting);
        var me = state.Members.FirstOrDefault(member => member.IsYou);
        var host = state.Members.FirstOrDefault(member => member.IsHost);
        var page = new StackPanel { Spacing = 18 };
        page.Children.Add(Heading("Who's in?", voters == 0
            ? "Nobody is swiping yet. Open Aurelia on a phone and join this night."
            : $"{(voters == 1 ? "1 person is" : $"{voters} people are")} ready to swipe. Anyone else at home can join from Aurelia on their phone, in a browser or on the Apple TV."));
        page.Children.Add(People(state));
        if (me?.IsHost == true)
        {
            Button Chip(string label, bool selected, Func<Task> action)
            {
                var chip = Action(label, action);
                if (selected) chip.Classes.Add("selected");
                return chip;
            }
            page.Children.Add(Row(
                Chip("Movies", state.Kinds != "all", () => session.SettingsAsync("movies", state.Genre)),
                Chip("Movies and Shows", state.Kinds == "all", () => session.SettingsAsync("all", state.Genre))));
            if (state.GenreOptions.Count > 0)
            {
                var genres = Row(Chip("Any Genre", state.Genre is null, () => session.SettingsAsync(state.Kinds, null)));
                foreach (var genre in state.GenreOptions)
                    genres.Children.Add(Chip(genre, state.Genre == genre, () => session.SettingsAsync(state.Kinds, genre)));
                page.Children.Add(genres);
            }
            var deal = Action("Deal the Cards", session.DealAsync, primary: true);
            deal.IsEnabled = voters > 0;
            page.Children.Add(Row(deal, Action(me.IsVoting ? "Just Watch on This PC" : "Swipe Here Too", () => session.SetVotingAsync(!me.IsVoting))));
        }
        else
        {
            page.Children.Add(new TextBlock { Text = $"Waiting for {host?.Name ?? "the host"} to deal.", Classes = { "subdued" } });
            page.Children.Add(Row(Action(me?.IsVoting == true ? "Just Watch on This PC" : "Swipe Here Too", () => session.SetVotingAsync(!(me?.IsVoting ?? false)))));
        }
        return page;
    }

    private StackPanel Swipe(MovieNightState state)
    {
        var cards = session.Remaining.Take(3).ToList();
        var total = session.Deck.Count;
        var stack = new Grid { Width = 320, Height = 480, HorizontalAlignment = HorizontalAlignment.Center };
        for (var index = cards.Count - 1; index >= 0; index--)
        {
            var card = Card(cards[index]);
            if (index > 0)
            {
                card.RenderTransform = new TransformGroup
                {
                    Children = { new ScaleTransform(1 - index * 0.06, 1 - index * 0.06), new TranslateTransform(0, index * 24) },
                };
                card.Opacity = 1 - index * 0.25;
                card.IsHitTestVisible = false;
            }
            else
            {
                AttachDrag(card, cards[0]);
            }
            stack.Children.Add(card);
        }
        var others = state.Members.Where(member => member.IsVoting && !member.IsYou).ToList();
        var progress = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MinWidth = 110 };
        progress.Children.Add(new TextBlock { Text = $"{total - session.Remaining.Count + 1} of {total}", FontWeight = FontWeight.Bold, HorizontalAlignment = HorizontalAlignment.Center });
        if (others.Count > 0)
            progress.Children.Add(new TextBlock { Text = string.Join(" · ", others.Select(member => $"{member.Name} {member.Swiped}")), Classes = { "subdued" }, FontSize = 13, HorizontalAlignment = HorizontalAlignment.Center });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 26, HorizontalAlignment = HorizontalAlignment.Center };
        buttons.Children.Add(RoundButton("✕", "Nope", Nope, () => Fling(stack.Children.LastOrDefault() as Border, cards[0], false)));
        buttons.Children.Add(progress);
        buttons.Children.Add(RoundButton("♥", "Yes", Yes, () => Fling(stack.Children.LastOrDefault() as Border, cards[0], true)));
        return new StackPanel
        {
            Spacing = 22,
            Children =
            {
                stack,
                buttons,
                new TextBlock { Text = "Drag right if you'd watch it tonight, left if not. The arrow keys work too.", Classes = { "subdued" }, HorizontalAlignment = HorizontalAlignment.Center, TextWrapping = TextWrapping.Wrap },
            },
        };
    }

    private static Button RoundButton(string symbol, string name, IBrush color, Action action)
    {
        var button = new Button
        {
            Width = 62,
            Height = 62,
            CornerRadius = new CornerRadius(31),
            BorderBrush = color,
            BorderThickness = new Thickness(2),
            Background = Brushes.Transparent,
            Foreground = color,
            FontSize = 24,
            FontWeight = FontWeight.Bold,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
            Content = symbol,
        };
        AutomationProperties.SetName(button, name);
        button.Click += (_, _) => action();
        return button;
    }

    private Border Card(MovieNightCard card)
    {
        var info = new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(18) };
        info.Children.Add(new TextBlock { Text = card.Title, FontSize = 22, FontWeight = FontWeight.Heavy, TextWrapping = TextWrapping.Wrap });
        var meta = MovieNightRules.Meta(card);
        if (meta.Length > 0) info.Children.Add(new TextBlock { Text = meta, Classes = { "subdued" }, FontSize = 13 });
        if (card.Overview is { } overview)
            info.Children.Add(new TextBlock { Text = overview, FontSize = 13, TextWrapping = TextWrapping.Wrap, MaxLines = 3, TextTrimming = TextTrimming.CharacterEllipsis, Opacity = 0.85 });
        var like = Stamp("Yes!", Yes, -14, HorizontalAlignment.Left);
        var nope = Stamp("Nope", Nope, 14, HorizontalAlignment.Right);
        var border = new Border
        {
            CornerRadius = new CornerRadius(20),
            ClipToBounds = true,
            Background = new SolidColorBrush(Color.Parse("#282C2F")),
            Child = new Grid
            {
                Children =
                {
                    new ArtworkImage(context.Store, card.Poster ?? card.Backdrop, 320),
                    new Border
                    {
                        Background = new LinearGradientBrush
                        {
                            StartPoint = new RelativePoint(0, 0.35, RelativeUnit.Relative),
                            EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
                            GradientStops = { new GradientStop(Colors.Transparent, 0), new GradientStop(Color.Parse("#E6000000"), 0.6) },
                        },
                    },
                    info,
                    like,
                    nope,
                },
            },
            Tag = (like, nope),
        };
        AutomationProperties.SetName(border, card.Title);
        return border;
    }

    private static Border Stamp(string text, IBrush color, double angle, HorizontalAlignment side) => new()
    {
        BorderBrush = color,
        BorderThickness = new Thickness(4),
        CornerRadius = new CornerRadius(10),
        Padding = new Thickness(12, 0),
        Margin = new Thickness(24),
        HorizontalAlignment = side,
        VerticalAlignment = VerticalAlignment.Top,
        RenderTransform = new RotateTransform(angle),
        Opacity = 0,
        IsHitTestVisible = false,
        Child = new TextBlock { Text = text, Foreground = color, FontSize = 30, FontWeight = FontWeight.Black },
    };

    private static void Move(Border card, double dx, double dy)
    {
        card.RenderTransform = new TransformGroup { Children = { new RotateTransform(dx / 16), new TranslateTransform(dx, dy * 0.25) } };
        if (card.Tag is (Border like, Border nope))
        {
            var strength = Math.Min(1, Math.Abs(dx) / MovieNightRules.SwipeDistance);
            like.Opacity = dx > 0 ? strength : 0;
            nope.Opacity = dx < 0 ? strength : 0;
        }
    }

    private void AttachDrag(Border card, MovieNightCard movie)
    {
        Point? start = null;
        Point last = default;
        DateTime lastTime = default;
        double velocity = 0;
        card.Cursor = new Cursor(StandardCursorType.Hand);
        card.PointerPressed += (_, e) =>
        {
            if (!e.GetCurrentPoint(card).Properties.IsLeftButtonPressed) return;
            start = last = e.GetPosition(this);
            lastTime = DateTime.UtcNow;
            dragging = true;
            e.Pointer.Capture(card);
        };
        card.PointerMoved += (_, e) =>
        {
            if (start is not { } origin) return;
            var now = e.GetPosition(this);
            var elapsed = (DateTime.UtcNow - lastTime).TotalSeconds;
            if (elapsed > 0) velocity = (now.X - last.X) / elapsed;
            last = now;
            lastTime = DateTime.UtcNow;
            Move(card, now.X - origin.X, now.Y - origin.Y);
        };
        card.PointerReleased += (_, e) =>
        {
            if (start is not { } origin) return;
            start = null;
            e.Pointer.Capture(null);
            var dx = e.GetPosition(this).X - origin.X;
            if (MovieNightRules.Choice(dx, velocity, card.Bounds.Width) is { } like)
            {
                Fling(card, movie, like);
                return;
            }
            Move(card, 0, 0);
            dragging = false;
            if (dirty) Render();
        };
    }

    private void Fling(Border? card, MovieNightCard movie, bool like)
    {
        if (card is not null) Move(card, like ? 900 : -900, 60);
        dragging = false;
        _ = session.VoteAsync(movie, like);
    }

    private void OnKeyDown(object? sender, KeyEventArgs e)
    {
        if (session.Screen != MovieNightScreen.Swipe || session.Remaining is not { Count: > 0 } remaining) return;
        var card = remaining[0];
        if (e.Key is Key.Right or Key.Left)
        {
            _ = session.VoteAsync(card, e.Key == Key.Right);
            e.Handled = true;
        }
    }

    private StackPanel Waiting(MovieNightState state)
    {
        var me = state.Members.FirstOrDefault(member => member.IsYou);
        var slow = MovieNightRules.Slowpokes(state, session.Deck.Count);
        var page = new StackPanel { Spacing = 18 };
        page.Children.Add(Heading(me?.IsVoting == true ? "You're done." : "Swiping in progress",
            slow.Count == 0 ? "Counting the votes…" : "Now we wait for the slowpokes."));
        page.Children.Add(People(state, session.Deck.Count));
        page.Children.Add(Row(
            me?.IsVoting == true ? null : Action("Swipe Here Too", () => session.SetVotingAsync(true)),
            Action("Deal New Cards", session.DealAsync)));
        return page;
    }

    private StackPanel Result(MovieNightState state)
    {
        var outcome = state.Result!;
        var voters = state.Members.Where(member => member.IsVoting).Select(member => member.Name).ToList();
        var page = new StackPanel { Spacing = 18 };
        page.Children.Add(Ticket(outcome, voters));
        foreach (var award in outcome.Awards)
        {
            page.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.Parse("#282C2F")),
                CornerRadius = new CornerRadius(12),
                Padding = new Thickness(14),
                Child = new StackPanel
                {
                    Spacing = 4,
                    Children =
                    {
                        new TextBlock { Text = award.Title, Foreground = Yes, FontWeight = FontWeight.Bold },
                        new TextBlock { Text = award.Line, TextWrapping = TextWrapping.Wrap },
                    },
                },
            });
        }
        Button? play = null;
        if (outcome.Card is { } card)
        {
            play = Action("Play", async () =>
            {
                try
                {
                    PlayRequested = await context.Store.Client.SummaryAsync(card.MediaId, CancellationToken.None);
                    host.Close(true);
                }
                catch (Exception failure) when (failure is AureliaApiException or HttpRequestException or TaskCanceledException)
                {
                    session.Error = failure.Message;
                }
            }, primary: true);
            play.IsDefault = true;
        }
        page.Children.Add(Row(
            play,
            state.Phase == "match" ? Action("Keep Swiping", session.KeepSwipingAsync) : null,
            Action("Deal New Cards", session.DealAsync)));
        return page;
    }

    private Border Ticket(MovieNightResult outcome, List<string> voters)
    {
        var text = new StackPanel { Spacing = 8 };
        text.Children.Add(new TextBlock { Text = outcome.Headline, FontSize = 30, FontWeight = FontWeight.Black, Foreground = Ink });
        if (outcome.Card is { } card)
        {
            text.Children.Add(new TextBlock { Text = card.Title, FontSize = 20, FontWeight = FontWeight.Bold, Foreground = Ink, TextWrapping = TextWrapping.Wrap });
            var meta = MovieNightRules.Meta(card);
            if (meta.Length > 0) text.Children.Add(new TextBlock { Text = meta, Foreground = Ink, Opacity = 0.62 });
        }
        text.Children.Add(new TextBlock { Text = outcome.Line, Foreground = Ink, FontSize = 15, TextWrapping = TextWrapping.Wrap });
        var main = new DockPanel { Margin = new Thickness(20) };
        if (outcome.Card is { } poster)
        {
            main.Children.Add(Docked(new Border
            {
                Width = 120,
                Height = 180,
                CornerRadius = new CornerRadius(10),
                ClipToBounds = true,
                Margin = new Thickness(0, 0, 18, 0),
                VerticalAlignment = VerticalAlignment.Top,
                Child = new ArtworkImage(context.Store, poster.Poster ?? poster.Backdrop, 120),
            }, Dock.Left));
        }
        main.Children.Add(text);
        var ticket = new StackPanel { Children = { main } };
        if (outcome.Card is not null)
        {
            ticket.Children.Add(new Border
            {
                Background = Stub,
                Padding = new Thickness(20, 12),
                Child = new WrapPanel
                {
                    ItemSpacing = 10,
                    Children =
                    {
                        new TextBlock { Text = outcome.IsUnanimous ? $"Admit {voters.Count}" : $"{outcome.Likes} of {outcome.Voters} said yes", FontWeight = FontWeight.Black, Foreground = Ink },
                        new TextBlock { Text = string.Join(", ", voters), Foreground = Ink },
                    },
                },
            });
        }
        return new Border { Background = Paper, CornerRadius = new CornerRadius(18), ClipToBounds = true, Child = ticket };
    }
}
