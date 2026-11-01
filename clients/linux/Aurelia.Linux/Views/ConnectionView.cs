using System.Collections.Specialized;
using System.ComponentModel;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Data;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Views;

/// <summary>
/// Connect to a server, as on the Mac: servers nearby or a typed address, then compare the key
/// fingerprint with the one the server shows and enter the eight-digit pairing code.
/// </summary>
public sealed class ConnectionView : UserControl
{
    private readonly ConnectionModel model;
    private readonly StackPanel nearby = new() { Spacing = 10 };
    private readonly TextBlock searching = new() { Text = "Looking for servers on your network…", Classes = { "subdued" }, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly Control chooser;
    private readonly Control verifier;
    private readonly TextBlock error = new() { Foreground = new SolidColorBrush(Color.Parse("#FF6B6B")), TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center };

    public ConnectionView(ConnectionModel model, AppFlow flow)
    {
        this.model = model;
        DataContext = model;
        chooser = Chooser(flow);
        verifier = Verifier();
        Content = ScreenParts.Backdrop(new ScrollViewer
        {
            Content = new StackPanel
            {
                Spacing = 22,
                Margin = new Thickness(40, 70, 40, 40),
                MaxWidth = 560,
                VerticalAlignment = VerticalAlignment.Center,
                Children = { chooser, verifier, error },
            },
        });
        model.PropertyChanged += OnModelChanged;
        model.Nearby.CollectionChanged += OnNearbyChanged;
        DetachedFromVisualTree += (_, _) =>
        {
            model.PropertyChanged -= OnModelChanged;
            model.Nearby.CollectionChanged -= OnNearbyChanged;
            model.Dispose();
        };
        RebuildNearby();
        Update();
    }

    internal ConnectionModel Model => model;

    private StackPanel Chooser(AppFlow flow)
    {
        var address = new TextBox { PlaceholderText = "Address, for example 192.168.1.20", MinWidth = 300 };
        address[!TextBox.TextProperty] = new Binding(nameof(ConnectionModel.Address)) { Mode = BindingMode.TwoWay };
        AutomationProperties.SetName(address, "Server Address");
        var connect = new Button { Content = "Connect", Classes = { "primary" } };
        connect.Click += async (_, _) => await model.ConnectAsync();
        address.KeyDown += async (_, e) =>
        {
            if (e.Key == Avalonia.Input.Key.Enter) await model.ConnectAsync();
        };
        var advanced = new Expander
        {
            Header = "Advanced",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Content = new StackPanel
            {
                Spacing = 10,
                Children =
                {
                    new TextBlock { Text = "Enter the address of a server that is not listed.", Classes = { "subdued" }, TextWrapping = TextWrapping.Wrap },
                    new DockPanel { Children = { connect.Also(c => { DockPanel.SetDock(c, Dock.Right); c.Margin = new Thickness(10, 0, 0, 0); }), address } },
                },
            },
        };
        var back = new Button { Content = "Back", Classes = { "link" }, HorizontalAlignment = HorizontalAlignment.Center };
        back.Click += (_, _) => flow.ReturnToWelcome();
        return new StackPanel
        {
            Spacing = 22,
            Children =
            {
                ScreenParts.Symbol("IconNetwork", 50),
                new StackPanel { Spacing = 8, Children = { ScreenParts.Title("Connect to Your Server"), ScreenParts.Detail("Choose your Aurelia server. Servers on this network appear here.") } },
                new TextBlock { Text = "SERVERS NEARBY", Classes = { "eyebrow", "subdued" } },
                searching,
                nearby,
                advanced,
                back,
            },
        };
    }

    private StackPanel Verifier()
    {
        var name = new TextBlock { FontSize = 22, FontWeight = FontWeight.Bold, HorizontalAlignment = HorizontalAlignment.Center, TextWrapping = TextWrapping.Wrap };
        name[!TextBlock.TextProperty] = new Binding("Inspected.Info.Name");
        var address = new TextBlock { Classes = { "subdued" }, HorizontalAlignment = HorizontalAlignment.Center };
        address[!TextBlock.TextProperty] = new Binding("Inspected.Address.Authority");
        var fingerprint = new TextBlock { FontSize = 20, FontFamily = new FontFamily("monospace"), FontWeight = FontWeight.SemiBold, HorizontalAlignment = HorizontalAlignment.Center };
        fingerprint[!TextBlock.TextProperty] = new Binding(nameof(ConnectionModel.DisplayFingerprint));
        AutomationProperties.SetName(fingerprint, "Server Fingerprint");
        var matches = new CheckBox { Content = "The fingerprints match", HorizontalAlignment = HorizontalAlignment.Center };
        matches[!ToggleButton.IsCheckedProperty] = new Binding(nameof(ConnectionModel.FingerprintsMatch)) { Mode = BindingMode.TwoWay };
        var code = new TextBox { PlaceholderText = "Pairing code", MaxLength = 8, FontSize = 22, HorizontalContentAlignment = HorizontalAlignment.Center, Width = 220, HorizontalAlignment = HorizontalAlignment.Center };
        code[!TextBox.TextProperty] = new Binding(nameof(ConnectionModel.Code)) { Mode = BindingMode.TwoWay };
        AutomationProperties.SetName(code, "Pairing Code");
        var pair = new Button { Content = "Pair This PC", Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Center };
        pair[!IsEnabledProperty] = new Binding(nameof(ConnectionModel.CanPair));
        pair.Click += async (_, _) => await model.PairAsync();
        code.KeyDown += async (_, e) =>
        {
            if (e.Key == Avalonia.Input.Key.Enter) await model.PairAsync();
        };
        var back = new Button { Content = "Back", Classes = { "link" }, HorizontalAlignment = HorizontalAlignment.Center };
        back.Click += (_, _) => model.Back();
        return new StackPanel
        {
            Spacing = 16,
            Children =
            {
                ScreenParts.Symbol("IconServer", 46),
                new StackPanel { Spacing = 4, Children = { name, address } },
                new Border
                {
                    Classes = { "card" },
                    Padding = new Thickness(24),
                    Child = new StackPanel
                    {
                        Spacing = 12,
                        Children =
                        {
                            new TextBlock { Text = "1. Compare the fingerprint", FontWeight = FontWeight.SemiBold },
                            new TextBlock
                            {
                                Text = "It must match the fingerprint the server shows: in Aurelia on the Mac under Settings › Advanced, or with “aurelia status” on a Linux server.",
                                Classes = { "subdued" },
                                TextWrapping = TextWrapping.Wrap,
                            },
                            fingerprint,
                            matches,
                            new Separator { Margin = new Thickness(0, 6) },
                            new TextBlock { Text = "2. Enter the pairing code", FontWeight = FontWeight.SemiBold },
                            new TextBlock
                            {
                                Text = "Create a code on the server: in Aurelia on the Mac under Settings › Profiles and Devices › Pair a Mac, or with “sudo aurelia pair” on a Linux server.",
                                Classes = { "subdued" },
                                TextWrapping = TextWrapping.Wrap,
                            },
                            code,
                        },
                    },
                },
                pair,
                back,
            },
        };
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e) => Update();

    private void OnNearbyChanged(object? sender, NotifyCollectionChangedEventArgs e) => RebuildNearby();

    private void Update()
    {
        chooser.IsVisible = !model.IsVerifying;
        verifier.IsVisible = model.IsVerifying;
        error.Text = model.Error;
        error.IsVisible = model.Error is not null;
        IsEnabled = true;
        Cursor = model.IsBusy ? new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Wait) : null;
    }

    private void RebuildNearby()
    {
        nearby.Children.Clear();
        foreach (var server in model.Nearby)
        {
            var button = WelcomeView.Choice(server.Name, server.Address.Authority, "IconServer", recommended: false);
            button.Click += async (_, _) => await model.ChooseAsync(server);
            nearby.Children.Add(button);
        }
        searching.IsVisible = model.Nearby.Count == 0;
    }
}
