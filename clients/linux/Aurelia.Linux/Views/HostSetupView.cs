using System.ComponentModel;
using System.Globalization;
using Aurelia.Linux.Core.Hosting;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Views;

/// <summary>
/// The Mac app's NativeHostSetupView for this computer's server: starting, "Set Up This PC" with the
/// Server Password (name, owner and port under Advanced), "Welcome Back", the owner's PIN reset, help
/// when the server cannot start, and another Aurelia Server already running here.
/// </summary>
public sealed class HostSetupView : UserControl
{
    private readonly HostSetupModel model;
    private readonly StackPanel body = new() { Spacing = 18, Width = 460, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock error = new() { Foreground = new SolidColorBrush(Color.Parse("#FFB36B")), TextWrapping = TextWrapping.Wrap, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center };
    private HostPhase? shown;

    /// <param name="connectToOther">Leaves hosting for the connection screen, prefilled with this computer when another server runs here.</param>
    public HostSetupView(HostSetupModel model, Action<bool> connectToOther)
    {
        this.model = model;
        ConnectToOther = connectToOther;
        Content = ScreenParts.Backdrop(new ScrollViewer
        {
            Content = new StackPanel
            {
                Spacing = 18,
                Margin = new Thickness(40, 70, 40, 40),
                VerticalAlignment = VerticalAlignment.Center,
                Children = { body, error },
            },
        });
        model.PropertyChanged += OnChanged;
        DetachedFromVisualTree += (_, _) => model.PropertyChanged -= OnChanged;
        Build();
    }

    internal HostSetupModel Model => model;

    private Action<bool> ConnectToOther { get; }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        error.Text = model.Error;
        error.IsVisible = model.Error is not null;
        if (e.PropertyName is nameof(HostSetupModel.Phase) or nameof(HostSetupModel.StatusTitle) or nameof(HostSetupModel.StatusMessage)
            && (shown != model.Phase || model.Phase is HostPhase.Starting or HostPhase.Failed or HostPhase.PortInUse)) Build();
    }

    private void Build()
    {
        shown = model.Phase;
        error.Text = model.Error;
        error.IsVisible = model.Error is not null;
        body.Children.Clear();
        switch (model.Phase)
        {
            case HostPhase.Starting:
                body.Children.Add(ScreenParts.Symbol("IconServer", 50));
                body.Children.Add(new ProgressBar { IsIndeterminate = true, Width = 140, HorizontalAlignment = HorizontalAlignment.Center });
                body.Children.Add(ScreenParts.Title(model.StatusTitle));
                if (model.StatusMessage is { } detail) body.Children.Add(ScreenParts.Detail(detail));
                return;
            case HostPhase.Failed:
                body.Children.Add(ScreenParts.Symbol("IconServer", 50, new SolidColorBrush(Color.Parse("#FF9F0A"))));
                body.Children.Add(ScreenParts.Title("Server Host Needs Attention"));
                body.Children.Add(ScreenParts.Detail(model.StatusMessage ?? "The server could not start."));
                body.Children.Add(Primary("Try Again", model.RetryAsync));
                break;
            case HostPhase.PortInUse:
                body.Children.Add(ScreenParts.Symbol("IconServer", 50));
                body.Children.Add(ScreenParts.Title("Aurelia Server Is Already Running"));
                body.Children.Add(ScreenParts.Detail((model.StatusMessage ?? "Another Aurelia Server runs on this computer.")
                    + " Connect to it, or stop it (sudo systemctl disable --now aurelia) and try again."));
                body.Children.Add(Primary("Connect to It", () =>
                {
                    ConnectToOther(true);
                    return Task.CompletedTask;
                }));
                body.Children.Add(Link("Try Again", model.RetryAsync));
                return;
            case HostPhase.OwnerSetup:
                OwnerSetup();
                break;
            case HostPhase.SignIn:
                SignIn();
                break;
            case HostPhase.ResetPin:
                ResetPin();
                return;
        }
        body.Children.Add(Link("Connect to Another Server", () =>
        {
            ConnectToOther(false);
            return Task.CompletedTask;
        }));
    }

    private void OwnerSetup()
    {
        var password = Secret("Server Password (at least 12 characters)", "Server Password");
        var show = new CheckBox { Content = "Show Password", HorizontalAlignment = HorizontalAlignment.Left };
        show.IsCheckedChanged += (_, _) => password.PasswordChar = show.IsChecked == true ? '\0' : '•';
        var hint = new TextBlock { Text = "Use at least 12 characters.", Foreground = new SolidColorBrush(Color.Parse("#FFB36B")), FontSize = 12, IsVisible = false };
        var name = Field(model.ServerName, "Server name", "Server Name");
        var owner = Field(model.OwnerName, "Owner", "Owner Name");
        var port = Field(model.HttpsPort.ToString(CultureInfo.InvariantCulture), "43111", "HTTPS Port");
        name.TextChanged += (_, _) => model.ServerName = name.Text ?? "";
        owner.TextChanged += (_, _) => model.OwnerName = owner.Text ?? "";
        var cont = new Button { Content = "Continue", Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Center, IsDefault = true, IsEnabled = false };
        AutomationProperties.SetName(cont, "Continue");
        void Check()
        {
            var length = password.Text?.Length ?? 0;
            hint.IsVisible = length is > 0 and < HostSetupModel.MinimumPasswordLength;
            cont.IsEnabled = length >= HostSetupModel.MinimumPasswordLength && model.HttpsPort is >= 1024 and <= 65535 && !model.IsBusy;
        }
        password.TextChanged += (_, _) => Check();
        port.TextChanged += (_, _) =>
        {
            model.HttpsPort = int.TryParse(port.Text, NumberStyles.None, CultureInfo.InvariantCulture, out var value) ? value : 0;
            Check();
        };
        cont.Click += async (_, _) =>
        {
            cont.IsEnabled = false;
            await model.SetUpAsync(password.Text ?? "");
            Check();
        };
        body.Children.Add(ScreenParts.Symbol("IconServer", 50));
        body.Children.Add(ScreenParts.Title("Set Up This PC"));
        body.Children.Add(ScreenParts.Detail("Choose a Server Password. Aurelia takes care of the server details."));
        body.Children.Add(password);
        body.Children.Add(show);
        body.Children.Add(hint);
        body.Children.Add(new Expander
        {
            Header = "Advanced",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Content = new Grid
            {
                ColumnDefinitions = new ColumnDefinitions("Auto,*"),
                RowDefinitions = new RowDefinitions("Auto,Auto,Auto"),
                RowSpacing = 10,
                ColumnSpacing = 12,
                Children =
                {
                    Label("Server Name", 0), name.Also(c => { Grid.SetColumn(c, 1); Grid.SetRow(c, 0); }),
                    Label("Owner Name", 1), owner.Also(c => { Grid.SetColumn(c, 1); Grid.SetRow(c, 1); }),
                    Label("HTTPS Port", 2), port.Also(c => { Grid.SetColumn(c, 1); Grid.SetRow(c, 2); }),
                },
            },
        });
        body.Children.Add(cont);
    }

    private void SignIn()
    {
        var owner = Field(model.OwnerName, "Owner name", "Owner Name");
        var password = Secret("Server Password", "Server Password");
        owner.TextChanged += (_, _) => model.OwnerName = owner.Text ?? "";
        var sign = new Button { Content = "Sign In", Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Center, IsDefault = true };
        sign.Click += async (_, _) =>
        {
            if (string.IsNullOrEmpty(owner.Text) || string.IsNullOrEmpty(password.Text)) return;
            sign.IsEnabled = false;
            await model.SignInAsync(password.Text);
            sign.IsEnabled = true;
        };
        body.Children.Add(ScreenParts.Symbol("IconServer", 50));
        body.Children.Add(ScreenParts.Title("Welcome Back"));
        body.Children.Add(ScreenParts.Detail("Sign in to the Aurelia server already stored on this PC."));
        body.Children.Add(owner);
        body.Children.Add(password);
        body.Children.Add(sign);
    }

    private void ResetPin()
    {
        var password = Secret("Server Password", "Server Password");
        var pin = Secret("New owner PIN (4–8 digits)", "New PIN");
        var confirm = Secret("Confirm PIN", "Confirm PIN");
        pin.MaxLength = confirm.MaxLength = 8;
        var save = new Button { Content = "Set New PIN", Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Center, IsDefault = true };
        save.Click += async (_, _) =>
        {
            save.IsEnabled = false;
            await model.ResetPinAsync(password.Text ?? "", pin.Text ?? "", confirm.Text ?? "");
            save.IsEnabled = true;
        };
        body.Children.Add(ScreenParts.Symbol("IconPerson", 50));
        body.Children.Add(ScreenParts.Title("Reset Owner PIN"));
        body.Children.Add(ScreenParts.Detail("Enter the Server Password of this PC's server and choose a new PIN for the owner's profile."));
        body.Children.Add(password);
        body.Children.Add(pin);
        body.Children.Add(confirm);
        body.Children.Add(save);
        body.Children.Add(Link("Cancel", () =>
        {
            model.CancelPinReset();
            return Task.CompletedTask;
        }));
    }

    private static TextBox Field(string text, string placeholder, string name)
    {
        var box = new TextBox { Text = text, PlaceholderText = placeholder };
        AutomationProperties.SetName(box, name);
        return box;
    }

    private static TextBox Secret(string placeholder, string name)
    {
        var box = new TextBox { PasswordChar = '•', PlaceholderText = placeholder };
        AutomationProperties.SetName(box, name);
        return box;
    }

    private static TextBlock Label(string text, int row) =>
        new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center }.Also(t => Grid.SetRow(t, row));

    private static Button Primary(string label, Func<Task> action)
    {
        var button = new Button { Content = label, Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Center };
        button.Click += async (_, _) => await action();
        return button;
    }

    private static Button Link(string label, Func<Task> action)
    {
        var button = new Button { Content = label, Classes = { "link" }, HorizontalAlignment = HorizontalAlignment.Center };
        button.Click += async (_, _) => await action();
        return button;
    }
}
