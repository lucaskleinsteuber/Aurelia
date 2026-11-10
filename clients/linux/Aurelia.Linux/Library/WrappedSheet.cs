using Aurelia.Contracts;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Playback;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;

namespace Aurelia.Linux.Library;

/// <summary>
/// Wrapped: the year as slides, like a story, in a phone-shaped sheet. Each slide runs for six
/// seconds; a click on the right or the right arrow moves on, on the left goes back, Space pauses
/// and Escape closes. With Reduce Motion the slides wait for a click and numbers do not count up.
/// </summary>
public sealed class WrappedSheet : UserControl
{
    private readonly LibraryContext context;
    private readonly SheetHost host;
    private readonly int year;
    private readonly int? month;
    private readonly bool reduceMotion;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(50) };
    private readonly Grid frame = new() { ClipToBounds = true };
    private IReadOnlyList<WrappedSlide> slides = [];
    private int index;
    private double progress;
    private bool held;
    private DateTime countStarted;
    private TextBlock? number;
    private ProgressBar[] bars = [];

    public WrappedSheet(LibraryContext context, SheetHost host, int year, int? month = null)
    {
        this.context = context;
        this.host = host;
        this.year = year;
        this.month = month;
        reduceMotion = context.Store.Preferences.ReduceMotion;
        Focusable = true;
        Content = frame;
        frame.Children.Add(new Aurelia.Linux.Controls.Spinner { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        timer.Tick += (_, _) => Tick();
        KeyDown += OnKeyDown;
        AttachedToVisualTree += async (_, _) =>
        {
            Focus();
            await LoadAsync();
        };
        DetachedFromVisualTree += (_, _) => timer.Stop();
    }

    private async Task LoadAsync()
    {
        try
        {
            slides = (await context.Store.Client.WrappedAsync(year, month, CancellationToken.None)).Slides;
        }
        catch (Exception failure) when (failure is AureliaApiException or HttpRequestException or TaskCanceledException)
        {
            var close = new Button { Content = "Close", Classes = { "primary" } };
            close.Click += (_, _) => host.Close(false);
            frame.Children.Clear();
            frame.Children.Add(new StackPanel
            {
                Spacing = 14,
                Margin = new Thickness(28),
                VerticalAlignment = VerticalAlignment.Center,
                Children =
                {
                    new TextBlock { Text = "Wrapped didn't load.", FontSize = 26, FontWeight = FontWeight.Black },
                    new TextBlock { Text = failure.Message, TextWrapping = TextWrapping.Wrap },
                    close,
                },
            });
            return;
        }
        if (slides.Count == 0)
        {
            host.Close(false);
            return;
        }
        Show();
        timer.Start();
    }

    private void Go(bool forward)
    {
        if (WrappedStory.Step(index, slides.Count, forward) is not { } next)
        {
            host.Close(true);
            return;
        }
        index = next;
        Show();
    }

    private void Tick()
    {
        if (number is not null && WrappedStory.CountTarget(slides[index].BigNumber) is { } target)
        {
            var fraction = (DateTime.UtcNow - countStarted).TotalSeconds / 1.1;
            number.Text = WrappedStory.CountValue(target, fraction).ToString(System.Globalization.CultureInfo.InvariantCulture);
            if (fraction >= 1) number = null;
        }
        if (reduceMotion || held) return;
        progress = Math.Min(1, progress + timer.Interval.TotalSeconds / WrappedStory.SlideTime.TotalSeconds);
        if (bars.Length > index) bars[index].Value = progress;
        if (progress >= 1) Go(true);
    }

    private void OnKeyDown(object? sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Right: Go(true); break;
            case Key.Left: Go(false); break;
            case Key.Space: held = !held; break;
            default: return;
        }
        e.Handled = true;
    }

    private void Show()
    {
        var slide = slides[index];
        var accent = WrappedStory.For(slide.Accent);
        var ink = new SolidColorBrush(Color.Parse(accent.Ink));
        var field = new SolidColorBrush(Color.Parse(accent.Field));
        progress = 0;
        frame.Children.Clear();
        frame.Background = field;
        if (slide.Poster is { } backdrop)
            frame.Children.Add(new ArtworkImage(context.Store, backdrop, 320) { Opacity = 0.25, Effect = new BlurEffect { Radius = 40 } });

        // A column in the middle of the whole window; the colour fills the rest.
        var content = new StackPanel
        {
            Spacing = 14,
            Margin = new Thickness(40, 70, 40, 40),
            MaxWidth = 820,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        content.Children.Add(new TextBlock { Text = slide.Eyebrow, Foreground = ink, FontSize = 19, FontWeight = FontWeight.Bold, Opacity = 0.8 });
        if (slide.Kind != "summary" && slide.Poster is { } poster)
        {
            content.Children.Add(new Border
            {
                Width = 130,
                Height = 195,
                CornerRadius = new CornerRadius(12),
                ClipToBounds = true,
                HorizontalAlignment = HorizontalAlignment.Left,
                RenderTransform = new RotateTransform(-3),
                Child = new ArtworkImage(context.Store, poster, 130),
            });
        }
        content.Children.Add(new TextBlock { Text = slide.Headline, Foreground = ink, FontSize = 46, FontWeight = FontWeight.Black, TextWrapping = TextWrapping.Wrap, LetterSpacing = -1 });
        if (slide.Kind == "summary")
        {
            if (slide.Posters is { Count: > 0 } posters)
            {
                var grid = new UniformGrid { Columns = posters.Count == 1 ? 1 : 2, Width = 220, HorizontalAlignment = HorizontalAlignment.Left };
                foreach (var each in posters.Take(4))
                    grid.Children.Add(new Border { Height = 150, Margin = new Thickness(4), CornerRadius = new CornerRadius(8), ClipToBounds = true, Child = new ArtworkImage(context.Store, each, 110) });
                content.Children.Add(grid);
            }
            foreach (var fact in slide.Facts ?? [])
            {
                content.Children.Add(new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 14,
                    Children =
                    {
                        new TextBlock { Text = fact.Label, Foreground = ink, Opacity = 0.72, Width = 90 },
                        new TextBlock { Text = fact.Value, Foreground = ink, FontWeight = FontWeight.Heavy, TextWrapping = TextWrapping.Wrap, MaxWidth = 250 },
                    },
                });
            }
        }
        number = null;
        if (slide.BigNumber is { } big)
        {
            var shown = new TextBlock { Text = big, Foreground = ink, FontSize = 170, FontWeight = FontWeight.Black, LetterSpacing = -9, Margin = new Thickness(-4, -10, 0, -14) };
            AutomationProperties.SetName(shown, slide.Unit is { } u ? $"{big} {u}" : big);
            content.Children.Add(shown);
            if (!reduceMotion && WrappedStory.CountTarget(big) is > 1)
            {
                number = shown;
                shown.Text = "0";
                countStarted = DateTime.UtcNow;
            }
            if (slide.Unit is { } unit) content.Children.Add(new TextBlock { Text = unit, Foreground = ink, FontSize = 24, FontWeight = FontWeight.Heavy });
        }
        if (slide.Detail is { } detail) content.Children.Add(new TextBlock { Text = detail, Foreground = ink, FontSize = 21, TextWrapping = TextWrapping.Wrap });
        content.Children.Add(new Border
        {
            Background = new SolidColorBrush(Color.Parse(accent.Sticker)),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(16, 10),
            Margin = new Thickness(0, 8, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Left,
            RenderTransform = new RotateTransform(-2.5),
            Child = new TextBlock { Text = slide.Quip, Foreground = field, FontSize = 21, FontWeight = FontWeight.Heavy, TextWrapping = TextWrapping.Wrap, MaxWidth = 640 },
        });
        frame.Children.Add(content);

        // Click areas: the left third goes back, the rest moves on.
        var back = new Border { Background = Brushes.Transparent, Cursor = new Cursor(StandardCursorType.Hand) };
        var forward = new Border { Background = Brushes.Transparent, Cursor = new Cursor(StandardCursorType.Hand) };
        back.PointerReleased += (_, _) => Go(false);
        forward.PointerReleased += (_, _) => Go(true);
        var areas = new Grid { ColumnDefinitions = new ColumnDefinitions("*,2*"), Margin = new Thickness(0, 60, 0, 0) };
        Grid.SetColumn(forward, 1);
        areas.Children.Add(back);
        areas.Children.Add(forward);
        frame.Children.Add(areas);

        var top = new DockPanel { VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(14, 12, 8, 0) };
        var close = new Button { Content = "✕", Foreground = ink, Background = Brushes.Transparent, FontSize = 16, IsCancel = true };
        AutomationProperties.SetName(close, "Close Wrapped");
        close.Click += (_, _) => host.Close(true);
        DockPanel.SetDock(close, Dock.Right);
        top.Children.Add(close);
        var barRow = new UniformGrid { Rows = 1, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 4, 8, 0) };
        bars = slides.Select((_, at) => new ProgressBar
        {
            Minimum = 0,
            Maximum = 1,
            Value = at < index ? 1 : at == index && reduceMotion ? 1 : 0,
            Height = 3,
            MinHeight = 3,
            Margin = new Thickness(2, 0),
            Foreground = ink,
            Background = new SolidColorBrush(Color.Parse(accent.Ink), 0.28),
        }).ToArray();
        foreach (var bar in bars) barRow.Children.Add(bar);
        top.Children.Add(barRow);
        frame.Children.Add(top);
    }
}

/// <summary>"Your October Wrapped is here": the newest ready month, in Statistics and, in its first week, on Home.</summary>
public static class MonthlyWrappedButton
{
    public static Button Create(LibraryContext context, Thickness margin)
    {
        var ready = WrappedStory.ReadyMonth(DateTime.Now);
        var ink = new SolidColorBrush(Color.Parse("#22000F"));
        var button = new Button
        {
            Classes = { "card" },
            Margin = margin,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = new Border
            {
                Background = new SolidColorBrush(Color.Parse("#FF4D88")),
                CornerRadius = new CornerRadius(14),
                Padding = new Thickness(16, 12),
                Child = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 14,
                    Children =
                    {
                        new TextBlock { Text = ready.Name[..3], FontSize = 26, FontWeight = FontWeight.Black, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center },
                        new StackPanel
                        {
                            VerticalAlignment = VerticalAlignment.Center,
                            Children =
                            {
                                new TextBlock { Text = $"Your {ready.Name} Wrapped is here", FontWeight = FontWeight.Bold, Foreground = ink },
                                new TextBlock { Text = "Last month in slides. It's worse than you think.", FontSize = 13, Foreground = ink, Opacity = 0.85 },
                            },
                        },
                    },
                },
            },
        };
        AutomationProperties.SetName(button, $"Your {ready.Name} Wrapped");
        button.Click += (_, _) => _ = context.Navigator.ShowWrappedAsync(ready.Year, ready.Month);
        return button;
    }
}
