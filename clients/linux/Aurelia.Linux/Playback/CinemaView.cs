using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Playback;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;

namespace Aurelia.Linux.Playback;

/// <summary>
/// Cinema mode's pre-show over the player: one of Aurelia's made-up ads, trailers with a
/// "Coming Up" card and the film's name, then the curtain that opens onto the starting film.
/// Skip (→) moves on, Start Film (Enter) goes straight to the film, Escape closes the player.
/// </summary>
public sealed class CinemaView : UserControl, IDisposable
{
    private static readonly IBrush Velvet = new LinearGradientBrush
    {
        StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
        EndPoint = new RelativePoint(1, 0, RelativeUnit.Relative),
        GradientStops = { new GradientStop(Color.Parse("#5A0B12"), 0), new GradientStop(Color.Parse("#8E1622"), 0.5), new GradientStop(Color.Parse("#5A0B12"), 1) },
    };

    private readonly CinemaPreShow show;
    private readonly Action close;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private readonly Grid stage = new();
    private readonly TextBlock label = new() { FontSize = 11, FontWeight = FontWeight.SemiBold, LetterSpacing = 1.4, Foreground = Brushes.White };
    private readonly Border labelPill;
    private readonly Button skip = new() { Content = "Skip  →", Classes = { "chip" } };
    private readonly Button start = new() { Content = "Start Film  ↵", Classes = { "primary" } };
    private readonly VideoSurface trailerSurface = new() { Fills = false };
    private readonly List<(CinemaBeat Beat, TextBlock Text)> beats = [];
    private Border? leftHalf;
    private Border? rightHalf;
    private StackPanel? curtainTitle;
    private StackPanel? comingUp;
    private StackPanel? trailerCard;
    private CinemaAct? shown;

    public CinemaView(CinemaPreShow show, Action close)
    {
        this.show = show;
        this.close = close;
        Focusable = true;
        Background = Brushes.Black;
        labelPill = new Border
        {
            Child = label,
            Background = new SolidColorBrush(Color.FromArgb(90, 0, 0, 0)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(64, 255, 255, 255)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(10, 4),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(28, 28, 0, 0),
        };
        skip.Click += (_, _) => show.Skip();
        start.Click += (_, _) => show.StartFilm();
        ToolTip.SetTip(skip, "Moves on to the next part (→)");
        ToolTip.SetTip(start, "Leaves out the rest and starts the film (Enter)");
        AutomationProperties.SetName(skip, "Skip");
        AutomationProperties.SetName(start, "Start Film");
        var closeButton = new Button { Content = "✕", Classes = { "chip" }, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 28, 28, 0) };
        ToolTip.SetTip(closeButton, "Close the player (Escape)");
        AutomationProperties.SetName(closeButton, "Close");
        closeButton.Click += (_, _) => Close();
        var bar = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 10,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 28, 28),
            Children = { skip, start },
        };
        Content = new Grid { Children = { stage, labelPill, closeButton, bar } };
        AutomationProperties.SetName(this, "Cinema");
        show.Changed += Render;
        timer.Tick += (_, _) => Animate();
        KeyDown += OnKeyDown;
        timer.Start();
        Render();
    }

    private void Close()
    {
        show.Stop();
        close();
    }

    private void OnKeyDown(object? sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Escape:
                Close();
                break;
            case Key.Enter or Key.Return:
                show.StartFilm();
                break;
            case Key.Right when show.Act is not CinemaAct.Feature:
                show.Skip();
                break;
            default:
                return;
        }
        e.Handled = true;
    }

    private void Render()
    {
        var act = show.Act;
        var feature = act is CinemaAct.Feature;
        skip.IsVisible = start.IsVisible = act is not null && !feature;
        labelPill.IsVisible = act is CinemaAct.Ad or CinemaAct.Trailer;
        label.Text = act is CinemaAct.Ad ? "ADVERTISEMENT" : "TRAILER";
        trailerSurface.Frames = (show.TrailerEngine as VlcVideoEngine)?.Frames;
        if (!ReferenceEquals(act, shown))
        {
            shown = act;
            Build(act);
        }
        // Once the curtain opens, the film playing behind it shows through.
        Background = feature && show.CurtainOpensAt is not null ? Brushes.Transparent : Brushes.Black;
        Animate();
        Focus();
    }

    private void Build(CinemaAct? act)
    {
        stage.Children.Clear();
        beats.Clear();
        leftHalf = rightHalf = null;
        curtainTitle = comingUp = trailerCard = null;
        switch (act)
        {
            case CinemaAct.Ad ad:
                var lines = new StackPanel { Spacing = 18, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 900 };
                foreach (var beat in CinemaPlan.Script(ad.Which))
                {
                    var text = new TextBlock
                    {
                        Text = beat.Text,
                        Foreground = beat.Fine ? new SolidColorBrush(Color.FromArgb(150, 255, 255, 255)) : Brushes.White,
                        FontSize = beat.Big ? 54 : beat.Fine ? 13 : 30,
                        FontWeight = beat.Big ? FontWeight.Black : FontWeight.SemiBold,
                        TextWrapping = TextWrapping.Wrap,
                        TextAlignment = TextAlignment.Center,
                        Opacity = 0,
                        Transitions = [new Avalonia.Animation.DoubleTransition { Property = OpacityProperty, Duration = TimeSpan.FromMilliseconds(450) }],
                    };
                    if (beat.Fine)
                    {
                        text.VerticalAlignment = VerticalAlignment.Bottom;
                        text.Margin = new Thickness(40, 0, 40, 90);
                        stage.Children.Add(text);
                    }
                    else
                    {
                        lines.Children.Add(text);
                    }
                    beats.Add((beat, text));
                }
                AutomationProperties.SetName(lines, CinemaPlan.Title(ad.Which));
                stage.Children.Insert(0, new Border { Background = AdBackground(ad.Which) });
                stage.Children.Add(lines);
                break;
            case CinemaAct.Trailer trailer:
                var title = trailer.Entry.Title;
                var year = title.Year?.ToString(System.Globalization.CultureInfo.InvariantCulture);
                trailerCard = new StackPanel
                {
                    Spacing = 6,
                    HorizontalAlignment = HorizontalAlignment.Left,
                    VerticalAlignment = VerticalAlignment.Bottom,
                    Margin = new Thickness(40, 0, 0, 40),
                    MaxWidth = 560,
                    Children =
                    {
                        new TextBlock { Text = string.Join(" · ", new[] { "IN YOUR LIBRARY", year }.Where(s => s is not null)), FontSize = 12, FontWeight = FontWeight.Bold, LetterSpacing = 1.1, Foreground = new SolidColorBrush(Color.FromArgb(200, 255, 255, 255)) },
                        new TextBlock { Text = title.Title, FontSize = 34, FontWeight = FontWeight.Bold, Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap, MaxLines = 2 },
                        new TextBlock { Text = string.Join(" · ", title.Genres.Take(2)), FontSize = 14, FontWeight = FontWeight.SemiBold, Foreground = new SolidColorBrush(Color.FromArgb(190, 255, 255, 255)), IsVisible = title.Genres.Count > 0 },
                    },
                };
                comingUp = new StackPanel
                {
                    Spacing = 14,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                    Children =
                    {
                        new TextBlock { Text = "COMING UP", FontSize = 13, FontWeight = FontWeight.Bold, LetterSpacing = 1.6, Foreground = new SolidColorBrush(Color.FromArgb(180, 255, 255, 255)), HorizontalAlignment = HorizontalAlignment.Center },
                        new TextBlock { Text = title.Title, FontSize = 44, FontWeight = FontWeight.Bold, Foreground = Brushes.White, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 900 },
                        new TextBlock { Text = year ?? "", FontSize = 15, FontWeight = FontWeight.SemiBold, Foreground = new SolidColorBrush(Color.FromArgb(150, 255, 255, 255)), HorizontalAlignment = HorizontalAlignment.Center, IsVisible = year is not null },
                    },
                };
                stage.Children.Add(trailerSurface);
                stage.Children.Add(new Border { Background = Shade(), IsHitTestVisible = false });
                stage.Children.Add(trailerCard);
                stage.Children.Add(new Border { Background = new SolidColorBrush(Color.Parse("#202326")), Child = comingUp });
                break;
            case CinemaAct.Feature feature:
                leftHalf = new Border { Background = Velvet, HorizontalAlignment = HorizontalAlignment.Left };
                rightHalf = new Border { Background = Velvet, HorizontalAlignment = HorizontalAlignment.Right };
                curtainTitle = new StackPanel
                {
                    Spacing = 10,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                    Children =
                    {
                        new TextBlock { Text = "AURELIA CINEMA PRESENTS", FontSize = 14, FontWeight = FontWeight.Bold, LetterSpacing = 2, Foreground = new SolidColorBrush(Color.FromArgb(210, 255, 236, 200)), HorizontalAlignment = HorizontalAlignment.Center },
                        new TextBlock { Text = feature.Title, FontSize = 52, FontWeight = FontWeight.Bold, Foreground = Brushes.White, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 1000 },
                    },
                };
                stage.Children.Add(leftHalf);
                stage.Children.Add(rightHalf);
                stage.Children.Add(curtainTitle);
                break;
        }
    }

    /// <summary>Lines in and out on the ad's script, the Coming Up card and the curtain's opening.</summary>
    private void Animate()
    {
        var age = (DateTimeOffset.UtcNow - show.ActStarted).TotalSeconds;
        foreach (var (beat, text) in beats) text.Opacity = age >= beat.From && age < beat.Until ? 1 : 0;
        if (comingUp?.Parent is Border card) card.IsVisible = !show.TrailerPlaying || age < CinemaPlan.ComingUpSeconds;
        if (trailerCard is not null) trailerCard.IsVisible = show.TrailerPlaying && age >= CinemaPlan.ComingUpSeconds;
        if (leftHalf is not null && rightHalf is not null && curtainTitle is not null)
        {
            var width = Bounds.Width / 2;
            var progress = show.CurtainOpensAt is { } opens ? Math.Clamp((age - opens) / CinemaPlan.CurtainOpeningSeconds, 0, 1) : 0;
            var eased = progress * progress * (3 - 2 * progress);
            leftHalf.Width = rightHalf.Width = Math.Max(0, width * (1 - eased));
            curtainTitle.Opacity = 1 - Math.Min(1, eased * 2);
        }
    }

    private static RadialGradientBrush AdBackground(CinemaAd ad) => new()
    {
        GradientStops =
        {
            new GradientStop(ad switch { CinemaAd.Popcorn => Color.Parse("#7A2E0E"), CinemaAd.Phones => Color.Parse("#1B2340"), _ => Color.Parse("#2E5E8C") }, 0),
            new GradientStop(Color.Parse("#0B0C0E"), 1),
        },
    };

    private static LinearGradientBrush Shade() => new()
    {
        StartPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
        EndPoint = new RelativePoint(0.55, 0.45, RelativeUnit.Relative),
        GradientStops = { new GradientStop(Color.FromArgb(166, 0, 0, 0), 0), new GradientStop(Color.FromArgb(64, 0, 0, 0), 0.5), new GradientStop(Colors.Transparent, 1) },
    };

    public void Dispose()
    {
        timer.Stop();
        show.Changed -= Render;
        trailerSurface.Frames = null;
        trailerSurface.Dispose();
    }
}
