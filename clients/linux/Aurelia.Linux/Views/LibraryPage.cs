using Aurelia.Linux.Core;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Views;

/// <summary>
/// A library page. This first build has no server connection yet, so each page shows its title and
/// says what will appear there; Home also shows the full-bleed hero beneath the sidebar.
/// </summary>
public sealed class LibraryPage : UserControl
{
    public static readonly StyledProperty<double> SidebarOverlapProperty =
        AvaloniaProperty.Register<LibraryPage, double>(nameof(SidebarOverlap));

    private readonly StackPanel inset = new() { Spacing = 30 };
    private readonly StackPanel heroText = new() { Spacing = 14, MaxWidth = 680, HorizontalAlignment = HorizontalAlignment.Left };

    public LibraryPage(LibraryDestination destination)
    {
        Destination = destination;
        var page = new StackPanel();
        if (destination == LibraryDestination.Home)
        {
            page.Children.Add(Hero());
            inset.Children.Add(Shelf("Continue Watching"));
            inset.Children.Add(Shelf("Recently Added"));
        }
        else
        {
            inset.Margin = new Thickness(0, 64, 0, 0);
            inset.Children.Add(new TextBlock { Text = destination.Title(), Classes = { "pageTitle" } });
            inset.Children.Add(EmptyState(destination));
        }
        page.Children.Add(inset);
        Content = new ScrollViewer
        {
            Content = page,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        UpdateInsets();
    }

    public LibraryDestination Destination { get; }

    /// <summary>How far the sidebar reaches over the page; content starts beside it.</summary>
    public double SidebarOverlap
    {
        get => GetValue(SidebarOverlapProperty);
        set => SetValue(SidebarOverlapProperty, value);
    }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == SidebarOverlapProperty) UpdateInsets();
    }

    private void UpdateInsets()
    {
        var leading = SidebarOverlap + 32;
        inset.Margin = new Thickness(leading, inset.Margin.Top, 32, 48);
        heroText.Margin = new Thickness(leading, 0, 32, 56);
    }

    private Grid Hero()
    {
        heroText.Children.Add(new TextBlock { Text = "AURELIA FOR LINUX · PREVIEW", Classes = { "eyebrow", "subdued" } });
        heroText.Children.Add(new TextBlock { Text = "Welcome to Aurelia", Classes = { "heroTitle" }, TextWrapping = TextWrapping.Wrap });
        heroText.Children.Add(new TextBlock
        {
            Text = "This first test build shows Aurelia's design on Linux. Connecting to your server, "
                + "your library and the player follow in the next builds.",
            TextWrapping = TextWrapping.Wrap,
            FontSize = 15,
            LineHeight = 22,
        });
        heroText.Children.Add(new Button
        {
            Content = "Connect to a Server",
            Classes = { "primary" },
            IsEnabled = false,
            Margin = new Thickness(0, 8, 0, 0),
        });
        return new Grid
        {
            Height = 520,
            Children =
            {
                // Placeholder artwork in Aurelia's icon colors until real hero artwork arrives.
                new Border
                {
                    Background = new RadialGradientBrush
                    {
                        Center = new RelativePoint(0.72, 0.38, RelativeUnit.Relative),
                        GradientOrigin = new RelativePoint(0.72, 0.38, RelativeUnit.Relative),
                        RadiusX = new RelativeScalar(0.55, RelativeUnit.Relative),
                        RadiusY = new RelativeScalar(0.9, RelativeUnit.Relative),
                        GradientStops =
                        {
                            new GradientStop(Color.Parse("#5B7CFF"), 0),
                            new GradientStop(Color.Parse("#3B2F9E"), 0.45),
                            new GradientStop(Color.Parse("#14161C"), 1),
                        },
                    },
                },
                // Fades the artwork into the canvas so the shelves below continue seamlessly.
                new Border
                {
                    Background = new LinearGradientBrush
                    {
                        StartPoint = new RelativePoint(0.5, 0.35, RelativeUnit.Relative),
                        EndPoint = new RelativePoint(0.5, 1, RelativeUnit.Relative),
                        GradientStops =
                        {
                            new GradientStop(Color.FromArgb(0, 32, 35, 38), 0),
                            new GradientStop(Color.FromArgb(255, 32, 35, 38), 1),
                        },
                    },
                },
                new Panel { Children = { heroText }, VerticalAlignment = VerticalAlignment.Bottom },
            },
        };
    }

    private static StackPanel Shelf(string title)
    {
        var cards = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 20 };
        for (var index = 0; index < 4; index++)
        {
            cards.Children.Add(new Border { Classes = { "card" }, Width = 300, Height = 170, Opacity = 0.55 - index * 0.1 });
        }
        return new StackPanel
        {
            Spacing = 14,
            Children =
            {
                new TextBlock { Text = title, Classes = { "sectionTitle" } },
                new ScrollViewer
                {
                    Content = cards,
                    HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
                    VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                },
            },
        };
    }

    private static Border EmptyState(LibraryDestination destination) => new Border
    {
        Classes = { "card" },
        Padding = new Thickness(28),
        MaxWidth = 620,
        HorizontalAlignment = HorizontalAlignment.Left,
        Child = new StackPanel
        {
            Spacing = 8,
            Children =
            {
                new TextBlock { Text = "Not connected yet", FontSize = 17, FontWeight = FontWeight.SemiBold },
                new TextBlock
                {
                    Text = $"{destination.Title()} fills in once Aurelia is connected to a server.",
                    Classes = { "subdued" },
                    TextWrapping = TextWrapping.Wrap,
                },
            },
        },
    };
}
