using Aurelia.Linux.Core.Flow;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Views;

/// <summary>The first screen: choose whether this computer runs the server or connects to one.</summary>
public sealed class WelcomeView : UserControl
{
    public WelcomeView(AppFlow flow)
    {
        var host = Choice("Set Up This PC", "Recommended · Aurelia starts and stops the server for you.", "IconComputer", recommended: true);
        host.Click += (_, _) => flow.ChooseMode(OperatingMode.Host);
        var client = Choice("Connect to an Existing Server", "For a server you run separately on another computer.", "IconNetwork", recommended: false);
        client.Click += (_, _) => flow.ChooseMode(OperatingMode.Client);
        Content = ScreenParts.Backdrop(new StackPanel
        {
            Spacing = 26,
            Margin = new Thickness(40),
            MaxWidth = 560,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                ScreenParts.Symbol("IconAurelia", 58),
                new StackPanel
                {
                    Spacing = 8,
                    Children =
                    {
                        ScreenParts.Title("Welcome to Aurelia"),
                        ScreenParts.Detail("Choose where your private media server should run."),
                    },
                },
                new StackPanel { Spacing = 14, Children = { host, client } },
            },
        });
    }

    internal static Button Choice(string title, string detail, string symbol, bool recommended)
    {
        var button = new Button
        {
            Classes = { "choice" },
            Content = new DockPanel
            {
                LastChildFill = true,
                Children =
                {
                    new Border { Classes = { "choiceSymbol" }, Child = ScreenParts.Symbol(symbol, 23, foreground: null) }.Also(b => DockPanel.SetDock(b, Dock.Left)),
                    ScreenParts.Symbol("IconChevronRight", 14, new SolidColorBrush(Color.FromArgb(0x59, 0xFF, 0xFF, 0xFF)))
                        .Also(c => { DockPanel.SetDock(c, Dock.Right); c.VerticalAlignment = VerticalAlignment.Center; }),
                    new StackPanel
                    {
                        Spacing = 4,
                        Margin = new Thickness(16, 0, 12, 0),
                        VerticalAlignment = VerticalAlignment.Center,
                        Children =
                        {
                            new TextBlock { Text = title, FontSize = 16, FontWeight = FontWeight.SemiBold },
                            new TextBlock { Text = detail, Classes = { "subdued" }, TextWrapping = TextWrapping.Wrap },
                        },
                    },
                },
            },
        };
        if (recommended) button.Classes.Add("recommended");
        AutomationProperties.SetName(button, title);
        return button;
    }
}

internal static class ControlExtensions
{
    /// <summary>Applies a setting to a control inside an object initializer.</summary>
    public static T Also<T>(this T control, Action<T> configure)
    {
        configure(control);
        return control;
    }
}
