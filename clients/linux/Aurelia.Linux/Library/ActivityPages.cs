using System.Globalization;
using Aurelia.Contracts;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Library;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Library;

/// <summary>What this profile watched, newest first and grouped by day, with removal and "Clear History".</summary>
public sealed class HistoryPage : LibraryPageBase
{
    private const int PageSize = 50;
    private readonly List<WatchHistoryItem> entries = [];
    private int total;
    private bool loaded;
    private readonly bool showsTitle;

    public HistoryPage(LibraryContext context, bool showsTitle = true) : base(context)
    {
        this.showsTitle = showsTitle;
        AttachedToVisualTree += async (_, _) => await LoadAsync(reset: true);
    }

    protected override void OnStoreChanged()
    {
    }

    private async Task LoadAsync(bool reset)
    {
        try
        {
            var page = await Context.Store.Client.HistoryAsync(reset ? 0 : entries.Count, PageSize, CancellationToken.None);
            if (reset) entries.Clear();
            entries.AddRange(page.Items);
            total = page.Total;
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
        var page = new StackPanel { Spacing = 20, Margin = new Thickness(0, showsTitle ? 64 : 16, 0, 48) };
        var header = new DockPanel { Margin = Inset(), LastChildFill = false };
        if (showsTitle) header.Children.Add(PageTitle("History").Also(t => DockPanel.SetDock(t, Dock.Left)));
        if (entries.Count > 0)
        {
            var clear = new Button { Content = "Clear History…", Classes = { "chip" } };
            clear.Click += async (_, _) =>
            {
                if (!await Context.Navigator.ConfirmAsync("Clear your viewing history?", "Your history and statistics start again from now. Watched marks and progress stay.", "Clear History", destructive: true)) return;
                try
                {
                    await Context.Store.Client.ClearHistoryAsync(CancellationToken.None);
                    await LoadAsync(reset: true);
                }
                catch (AureliaApiException failure)
                {
                    Context.Store.Report(failure);
                }
            };
            header.Children.Add(clear.Also(c => DockPanel.SetDock(c, Dock.Right)));
        }
        page.Children.Add(header);
        if (!loaded) return page;
        if (entries.Count == 0)
        {
            page.Children.Add(EmptyState("No Viewing Activity Yet", "What you watch on this profile appears here."));
            return page;
        }
        var now = DateTimeOffset.Now;
        foreach (var day in entries.GroupBy(e => ActivityFormat.Day(e.WatchedAt, now)))
        {
            var list = new StackPanel { Spacing = 6, Margin = Inset() };
            list.Children.Add(new TextBlock { Text = day.Key, Classes = { "sectionTitle" }, FontSize = 17, Margin = new Thickness(0, 10, 0, 4) });
            foreach (var entry in day) list.Children.Add(Row(entry));
            page.Children.Add(list);
        }
        if (entries.Count < total)
        {
            var more = new Button { Content = "Show More", Classes = { "chip" }, Margin = Inset(), HorizontalAlignment = HorizontalAlignment.Left };
            more.Click += async (_, _) => await LoadAsync(reset: false);
            page.Children.Add(more);
        }
        return page;
    }

    private Border Row(WatchHistoryItem entry)
    {
        var poster = new Border { Width = 40, Height = 60, CornerRadius = new CornerRadius(6), ClipToBounds = true, Child = new ArtworkImage(Context.Store, entry.Poster, 40) };
        var details = new StackPanel
        {
            Spacing = 2,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                new TextBlock { Text = entry.Title, FontWeight = FontWeight.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis },
                new TextBlock { Text = string.Join(" · ", new[] { entry.Eyebrow, ActivityFormat.Time(entry.WatchedAt) }.Where(t => !string.IsNullOrEmpty(t))), Classes = { "subdued" }, FontSize = 12 },
                new TextBlock { Text = "Watched " + ActivityFormat.Duration(TimeSpan.FromSeconds(entry.SecondsWatched)), Classes = { "subdued" }, FontSize = 12 },
            },
        };
        var state = entry.IsCompleted
            ? new TextBlock { Text = "Finished", Foreground = new SolidColorBrush(Color.Parse("#7EE08A")), VerticalAlignment = VerticalAlignment.Center }
            : (Control)new ProgressBar { Width = 90, Minimum = 0, Maximum = Math.Max(1, entry.DurationMilliseconds), Value = entry.PositionMilliseconds, VerticalAlignment = VerticalAlignment.Center };
        var remove = new Button { Content = "Remove", Classes = { "link" }, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(remove, "Remove from History, " + entry.Title);
        remove.Click += async (_, _) =>
        {
            try
            {
                await Context.Store.Client.RemoveHistoryEntryAsync(entry.Id, CancellationToken.None);
                entries.Remove(entry);
                total--;
                Rebuild();
            }
            catch (AureliaApiException failure)
            {
                Context.Store.Report(failure);
            }
        };
        var open = new Button { Content = "Open Title", Classes = { "link" }, VerticalAlignment = VerticalAlignment.Center };
        open.Click += async (_, _) =>
        {
            try
            {
                Context.OpenDetail(await Context.Store.Client.SummaryAsync(entry.MediaId, CancellationToken.None));
            }
            catch (AureliaApiException failure)
            {
                Context.Store.Report(failure);
            }
        };
        return new Border
        {
            Classes = { "card" },
            Padding = new Thickness(12),
            CornerRadius = new CornerRadius(12),
            MaxWidth = 900,
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = new DockPanel
            {
                Children =
                {
                    poster.Also(p => DockPanel.SetDock(p, Dock.Left)),
                    new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Children = { state, open, remove } }.Also(p => DockPanel.SetDock(p, Dock.Right)),
                    details.Also(d => d.Margin = new Thickness(12, 0)),
                },
            },
        };
    }
}

/// <summary>Watch time, streaks, the last twelve weeks, top titles and genres, and a year in review.</summary>
public sealed class StatisticsPage : LibraryPageBase
{
    private UserStatistics? statistics;
    private YearInReview? review;
    private int? year;
    private bool loaded;
    private readonly bool showsTitle;

    public StatisticsPage(LibraryContext context, bool showsTitle = true) : base(context)
    {
        this.showsTitle = showsTitle;
        AttachedToVisualTree += async (_, _) => await LoadAsync();
    }

    protected override void OnStoreChanged()
    {
    }

    private async Task LoadAsync()
    {
        try
        {
            statistics = await Context.Store.Client.StatisticsAsync(CancellationToken.None);
            year ??= statistics.YearsAvailable.Count > 0 ? statistics.YearsAvailable.Max() : null;
            review = year is { } chosen ? await Context.Store.Client.YearInReviewAsync(chosen, CancellationToken.None) : null;
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
        var page = new StackPanel { Spacing = 26, Margin = new Thickness(0, showsTitle ? 64 : 16, 0, 48) };
        if (showsTitle) page.Children.Add(new StackPanel { Margin = Inset(), Children = { PageTitle("Statistics") } });
        if (!loaded) return page;
        if (statistics is not { } stats || stats.TotalHoursWatched <= 0)
        {
            page.Children.Add(EmptyState("No Viewing Activity Yet", "Statistics appear once this profile has watched something."));
            return page;
        }
        page.Children.Add(new WrapPanel
        {
            Margin = Inset(),
            ItemSpacing = 16,
            LineSpacing = 16,
            Children =
            {
                Tile("Total Watch Time", ActivityFormat.Hours(stats.TotalHoursWatched)),
                Tile("Past 7 Days", ActivityFormat.Hours(stats.HoursPast7Days)),
                Tile("Past 30 Days", ActivityFormat.Hours(stats.HoursPast30Days)),
                Tile("Current Streak", Days(stats.CurrentStreakDays)),
                Tile("Longest Streak", Days(stats.LongestStreakDays)),
                Tile("Finished", ActivityFormat.Percent(stats.CompletionRate)),
                Tile("Watches Most", $"{stats.BusiestWeekday}, {stats.BusiestTimeOfDay}".Trim(' ', ',')),
            },
        });
        page.Children.Add(Section("Last 12 Weeks", WeekChart(stats.HoursByWeek.TakeLast(12).ToList())));
        page.Children.Add(new WrapPanel
        {
            Margin = Inset(),
            ItemSpacing = 40,
            LineSpacing = 24,
            Children = { Ranking("Most Watched", stats.TopTitles.Take(5)), Ranking("Favorite Genres", stats.TopGenres.Take(5)) },
        });
        if (stats.YearsAvailable.Count > 0) page.Children.Add(YearInReview(stats));
        return page;
    }

    private static string Days(int days) => days == 1 ? "1 day" : $"{days} days";

    private static Border Tile(string label, string value) => new()
    {
        Classes = { "card" },
        Padding = new Thickness(18),
        Width = 200,
        Child = new StackPanel
        {
            Spacing = 6,
            Children =
            {
                new TextBlock { Text = label, Classes = { "subdued" }, FontSize = 12 },
                new TextBlock { Text = value, FontSize = 22, FontWeight = FontWeight.Bold, TextWrapping = TextWrapping.Wrap },
            },
        },
    };

    private StackPanel WeekChart(List<PeriodHours> weeks)
    {
        var peak = Math.Max(0.1, weeks.Count == 0 ? 0 : weeks.Max(w => w.Hours));
        var bars = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Margin = Inset(), Height = 180, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var week in weeks)
        {
            var bar = new Rectangle
            {
                Width = 36,
                Height = Math.Max(3, 140 * week.Hours / peak),
                RadiusX = 6,
                RadiusY = 6,
                Fill = Application.Current?.FindResource("AureliaAccentBrush") as IBrush,
                VerticalAlignment = VerticalAlignment.Bottom,
            };
            ToolTip.SetTip(bar, $"{week.Period}: {ActivityFormat.Hours(week.Hours)}");
            AutomationProperties.SetName(bar, $"{week.Period}, {ActivityFormat.Hours(week.Hours)}");
            bars.Children.Add(new DockPanel
            {
                Children =
                {
                    new TextBlock { Text = ShortWeek(week.Period), FontSize = 10, Classes = { "subdued" }, HorizontalAlignment = HorizontalAlignment.Center }.Also(t => DockPanel.SetDock(t, Dock.Bottom)),
                    bar,
                },
            });
        }
        return bars;
    }

    private static string ShortWeek(string period) => period.Contains("-W", StringComparison.Ordinal) ? "W" + period[(period.IndexOf("-W", StringComparison.Ordinal) + 2)..] : period;

    private static StackPanel Ranking(string title, IEnumerable<NamedCount> entries)
    {
        var list = entries.ToList();
        var peak = Math.Max(1, list.Count == 0 ? 1 : list.Max(e => e.Hours ?? e.Count));
        var panel = new StackPanel { Spacing = 10, Width = 380, Children = { SectionTitle(title) } };
        foreach (var entry in list)
        {
            var value = entry.Hours ?? entry.Count;
            panel.Children.Add(new StackPanel
            {
                Spacing = 4,
                Children =
                {
                    new DockPanel
                    {
                        Children =
                        {
                            new TextBlock { Text = entry.Hours is { } hours ? ActivityFormat.Hours(hours) : entry.Count.ToString(CultureInfo.InvariantCulture), Classes = { "subdued" } }.Also(t => DockPanel.SetDock(t, Dock.Right)),
                            new TextBlock { Text = entry.Name, TextTrimming = TextTrimming.CharacterEllipsis },
                        },
                    },
                    new Rectangle { Height = 6, RadiusX = 3, RadiusY = 3, HorizontalAlignment = HorizontalAlignment.Left, Width = Math.Max(6, 380 * value / peak), Fill = Application.Current?.FindResource("AureliaAccentBrush") as IBrush },
                },
            });
        }
        if (list.Count == 0) panel.Children.Add(new TextBlock { Text = "Nothing yet.", Classes = { "subdued" } });
        return panel;
    }

    private StackPanel YearInReview(UserStatistics stats)
    {
        var picker = new ComboBox { ItemsSource = stats.YearsAvailable.OrderDescending().ToList(), SelectedItem = year, MinWidth = 110 };
        AutomationProperties.SetName(picker, "Year");
        picker.SelectionChanged += async (_, _) =>
        {
            if (picker.SelectedItem is int chosen && chosen != year)
            {
                year = chosen;
                try
                {
                    review = await Context.Store.Client.YearInReviewAsync(chosen, CancellationToken.None);
                }
                catch (AureliaApiException failure)
                {
                    Context.Store.Report(failure);
                }
                Rebuild();
            }
        };
        var tiles = new WrapPanel { ItemSpacing = 16, LineSpacing = 16 };
        if (review is { } r)
        {
            tiles.Children.Add(Tile("Watch Time", ActivityFormat.Hours(r.TotalHoursWatched)));
            tiles.Children.Add(Tile("Titles", r.TitlesWatched.ToString(CultureInfo.InvariantCulture)));
            tiles.Children.Add(Tile("Movies", r.MoviesWatched.ToString(CultureInfo.InvariantCulture)));
            tiles.Children.Add(Tile("Episodes", r.EpisodesWatched.ToString(CultureInfo.InvariantCulture)));
            if (r.TopGenre is { } genre) tiles.Children.Add(Tile("Favorite Genre", genre));
            if (r.TopTitle is { } top) tiles.Children.Add(Tile("Most Watched", top));
            if (r.BusiestDay is { } day) tiles.Children.Add(Tile("Busiest Day", r.BusiestDayHours is { } hours ? $"{day} ({ActivityFormat.Hours(hours)})" : day));
        }
        return new StackPanel
        {
            Spacing = 14,
            Margin = Inset(),
            Children =
            {
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Children = { SectionTitle("Year in Review"), picker } },
                tiles,
            },
        };
    }
}
