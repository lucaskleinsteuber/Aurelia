using Aurelia.Linux.Core.Flow;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Views;

/// <summary>
/// The setup assistant's start: "New to Aurelia?", how Aurelia works in one picture, then three quick
/// questions that set up the rest: where the media lives, who watches, and which other devices follow.
/// "I Know Aurelia" or "Skip Introduction" lead to the plain welcome choice instead.
/// </summary>
public sealed class IntroductionView : UserControl
{
    public enum Page
    {
        Welcome,
        HowItWorks,
        MediaLocation,
        Audience,
        Devices,
    }

    private readonly AppFlow flow;
    private readonly bool replay;
    private readonly ContentControl host = new();
    private readonly StackPanel dots = new() { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
    private SetupDevices devices;

    /// <param name="replay">Settings › About › Show Introduction: only the explanation, then <paramref name="closed"/>.</param>
    public IntroductionView(AppFlow flow, bool replay = false, Action? closed = null)
    {
        this.flow = flow;
        this.replay = replay;
        Closed = closed;
        devices = flow.Guide.Devices;
        Content = ScreenParts.Backdrop(new ScrollViewer
        {
            Content = new StackPanel
            {
                Spacing = 28,
                Margin = new Thickness(40, 70, 40, 40),
                MaxWidth = 620,
                VerticalAlignment = VerticalAlignment.Center,
                Children = { host, dots },
            },
        });
        Show(replay ? Page.HowItWorks : Page.Welcome);
    }

    public Page Current { get; private set; }

    private Action? Closed { get; }

    internal void Show(Page page)
    {
        Current = page;
        host.Content = page switch
        {
            Page.Welcome => WelcomePage(),
            Page.HowItWorks => HowItWorksPage(),
            Page.MediaLocation => MediaPage(),
            Page.Audience => AudiencePage(),
            _ => DevicesPage(),
        };
        if (host.Content is Control shown) Controls.Motion.Appear(shown, rise: 12, fromScale: 0.99);
        dots.Children.Clear();
        dots.IsVisible = page != Page.Welcome && !replay;
        foreach (var each in new[] { Page.HowItWorks, Page.MediaLocation, Page.Audience, Page.Devices })
        {
            dots.Children.Add(new Border
            {
                Width = each == page ? 22 : 8,
                Height = 8,
                CornerRadius = new CornerRadius(4),
                Background = each == page ? Application.Current?.FindResource("AureliaAccentBrush") as IBrush : new SolidColorBrush(Color.FromArgb(0x47, 0xFF, 0xFF, 0xFF)),
            });
        }
    }

    private StackPanel WelcomePage()
    {
        var guided = Primary("Show Me Around");
        guided.Click += (_, _) => Show(Page.HowItWorks);
        var skip = new Button { Content = "I Know Aurelia", Classes = { "link" }, HorizontalAlignment = HorizontalAlignment.Center };
        skip.Click += (_, _) => flow.SkipIntroduction();
        return Column(
            ScreenParts.Symbol("IconAurelia", 64),
            Heading("Welcome to Aurelia", "Your movies and shows, on every screen at home. New here? A few steps set everything up with you."),
            new StackPanel { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, Children = { guided, skip } });
    }

    private StackPanel HowItWorksPage()
    {
        var next = Primary(replay ? "Done" : "Continue");
        next.Click += (_, _) =>
        {
            if (replay) Closed?.Invoke();
            else Show(Page.MediaLocation);
        };
        var steps = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,*,Auto,*"), HorizontalAlignment = HorizontalAlignment.Stretch };
        steps.Children.Add(Station("IconComputer", "Your Files", "Movies and shows stay where they are. Aurelia never changes them.").Also(c => Grid.SetColumn(c, 0)));
        steps.Children.Add(Arrow().Also(c => Grid.SetColumn(c, 1)));
        steps.Children.Add(Station("IconServer", "Aurelia Server", "Runs on one computer, sorts everything and finds posters.").Also(c => Grid.SetColumn(c, 2)));
        steps.Children.Add(Arrow().Also(c => Grid.SetColumn(c, 3)));
        steps.Children.Add(Station("IconTvShows", "Every Screen", "Apple TV, iPhone, iPad, computers and the browser play from it.").Also(c => Grid.SetColumn(c, 4)));
        var children = new List<Control> { Heading("How Aurelia Works", "One computer serves your library. Everything else just watches."), steps, Center(next) };
        if (!replay) children.Add(Back(Page.Welcome));
        return Column([.. children]);
    }

    private StackPanel MediaPage()
    {
        var here = WelcomeView.Choice("On This Computer", "This PC becomes your server. Recommended when the files are on its drives.", "IconComputer", recommended: true);
        here.Click += (_, _) => Show(Page.Audience);
        var elsewhere = WelcomeView.Choice("On Another Computer", "An Aurelia Server already runs there. This PC connects to it.", "IconNetwork", recommended: false);
        elsewhere.Click += (_, _) => flow.StartGuidedSetup(OperatingMode.Client);
        var help = ScreenParts.Detail("Choose the computer whose drives hold the movies and shows. It should be on when you watch. You can change this later in Settings.");
        help.IsVisible = false;
        var unsure = new Button { Content = "Not Sure?", Classes = { "link" }, HorizontalAlignment = HorizontalAlignment.Center };
        unsure.Click += (_, _) => help.IsVisible = !help.IsVisible;
        return Column(
            Heading("Where Are Your Movies and Shows?", "Aurelia runs where your files are."),
            new StackPanel { Spacing = 14, Children = { here, elsewhere } },
            new StackPanel { Spacing = 8, Children = { unsure, help } },
            Back(Page.HowItWorks));
    }

    private StackPanel AudiencePage()
    {
        var me = WelcomeView.Choice("Just Me", "One profile, protected with your PIN.", "IconPerson", recommended: flow.Guide.Audience == SetupAudience.JustMe);
        me.Click += (_, _) =>
        {
            flow.Guide.Audience = SetupAudience.JustMe;
            Show(Page.Devices);
        };
        var several = WelcomeView.Choice("Several People", "Everyone gets a profile. Children's profiles show only what suits their age.", "IconPeople",
            recommended: flow.Guide.Audience == SetupAudience.SeveralPeople);
        several.Click += (_, _) =>
        {
            flow.Guide.Audience = SetupAudience.SeveralPeople;
            Show(Page.Devices);
        };
        return Column(
            Heading("Who Watches?", "Each person keeps their own progress, favorites and watchlist."),
            new StackPanel { Spacing = 14, Children = { me, several } },
            Back(Page.MediaLocation));
    }

    private StackPanel DevicesPage()
    {
        var chips = new WrapPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var (device, label) in new[] { (SetupDevices.AppleTv, "Apple TV"), (SetupDevices.PhoneOrTablet, "iPhone or iPad"), (SetupDevices.Computer, "Another Computer"), (SetupDevices.WebBrowser, "Web Browser") })
        {
            var chip = new Button { Content = label, Classes = { "chip" }, Margin = new Thickness(5), Padding = new Thickness(16, 9) };
            AutomationProperties.SetName(chip, label);
            void Paint() => chip.Classes.Set("selected", devices.HasFlag(device));
            Paint();
            chip.Click += (_, _) =>
            {
                devices ^= device;
                Paint();
            };
            chips.Children.Add(chip);
        }
        var next = Primary("Set Up This PC");
        next.Click += (_, _) =>
        {
            flow.Guide.Devices = devices;
            flow.StartGuidedSetup(OperatingMode.Host);
        };
        return Column(
            Heading("Which Other Devices Will You Use?", "Pick any. At the end, Aurelia shows how to connect each one."),
            chips,
            Center(next),
            Back(Page.Audience));
    }

    private static StackPanel Column(params Control[] children)
    {
        var column = new StackPanel { Spacing = 26 };
        foreach (var child in children) column.Children.Add(child);
        return column;
    }

    private static StackPanel Heading(string title, string detail) => new()
    {
        Spacing = 8,
        Children = { ScreenParts.Title(title), ScreenParts.Detail(detail) },
    };

    private static Button Primary(string label)
    {
        var button = new Button { Content = label, Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Center, MinWidth = 200, IsDefault = true };
        AutomationProperties.SetName(button, label);
        return button;
    }

    private static Control Center(Control control)
    {
        control.HorizontalAlignment = HorizontalAlignment.Center;
        return control;
    }

    private Button Back(Page page)
    {
        var back = new Button { Content = "Back", Classes = { "link" }, HorizontalAlignment = HorizontalAlignment.Center };
        back.Click += (_, _) => Show(page);
        return back;
    }

    private static StackPanel Station(string symbol, string title, string detail) => new()
    {
        Spacing = 10,
        Margin = new Thickness(6, 0),
        Children =
        {
            new Border
            {
                Width = 64,
                Height = 64,
                CornerRadius = new CornerRadius(18),
                HorizontalAlignment = HorizontalAlignment.Center,
                Background = Application.Current?.FindResource("AureliaRaisedSurfaceBrush") as IBrush,
                Child = ScreenParts.Symbol(symbol, 30).Also(icon => icon.VerticalAlignment = VerticalAlignment.Center),
            },
            new TextBlock { Text = title, FontWeight = FontWeight.SemiBold, HorizontalAlignment = HorizontalAlignment.Center },
            new TextBlock { Text = detail, Classes = { "subdued" }, FontSize = 12, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center },
        },
    };

    private static PathIcon Arrow() => ScreenParts.Symbol("IconChevronRight", 16, new SolidColorBrush(Color.FromArgb(0x66, 0xFF, 0xFF, 0xFF)))
        .Also(icon => icon.Margin = new Thickness(0, 24, 0, 0));
}
