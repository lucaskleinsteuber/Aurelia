using System.Collections.Specialized;
using System.ComponentModel;
using Aurelia.Contracts;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core.Flow;
using Avalonia;
using Avalonia.Animation;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Data;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Styling;

namespace Aurelia.Linux.Views;

/// <summary>"Who's watching?": the server's profiles, the PIN field and the first-time profile setup.</summary>
public sealed class ProfilePickerView : UserControl
{
    private readonly ProfilePickerModel model;
    private readonly AppSession session;
    private readonly WrapPanel grid = new() { HorizontalAlignment = HorizontalAlignment.Center, ItemSpacing = 28, LineSpacing = 28 };
    private readonly StackPanel picker;
    private readonly StackPanel pinEntry = new() { Spacing = 16, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly StackPanel setup;
    private readonly TextBox pin = new() { PasswordChar = '•', MaxLength = 8, Width = 200, FontSize = 22, HorizontalContentAlignment = HorizontalAlignment.Center };
    private readonly TextBlock error = new() { Foreground = new SolidColorBrush(Color.Parse("#FF6B6B")), HorizontalAlignment = HorizontalAlignment.Center, TextWrapping = TextWrapping.Wrap };
    private readonly ProgressBar loading = new() { IsIndeterminate = true, Width = 120, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly Action? forgotOwnerPin;
    private int shownFailures;

    /// <param name="forgotOwnerPin">On this computer's own server: resets the owner's PIN with the Server Password.</param>
    /// <param name="useAnotherServer">On this computer's own server: stops it and connects elsewhere.</param>
    public ProfilePickerView(ProfilePickerModel model, AppSession session, Action? forgotOwnerPin = null, Func<Task>? useAnotherServer = null)
    {
        this.forgotOwnerPin = forgotOwnerPin;
        this.model = model;
        this.session = session;
        DataContext = model;
        AutomationProperties.SetName(pin, "PIN");
        pin[!TextBox.TextProperty] = new Binding(nameof(ProfilePickerModel.Pin)) { Mode = BindingMode.TwoWay };
        pin.KeyDown += async (_, e) =>
        {
            if (e.Key == Avalonia.Input.Key.Enter) await model.SubmitPinAsync();
            else if (e.Key == Avalonia.Input.Key.Escape) model.CancelPin();
        };
        var otherServer = new Button { Content = "Use Another Server…", Classes = { "link" }, HorizontalAlignment = HorizontalAlignment.Center };
        var confirmOther = new Button { Content = "Forget This Server", Classes = { "link" }, HorizontalAlignment = HorizontalAlignment.Center, IsVisible = false };
        otherServer.Click += (_, _) =>
        {
            otherServer.IsVisible = false;
            confirmOther.IsVisible = true;
        };
        confirmOther.Content = useAnotherServer is null ? "Forget This Server" : "Stop This PC's Server and Connect Elsewhere";
        confirmOther.Click += async (_, _) =>
        {
            if (useAnotherServer is null) await session.DisconnectAsync();
            else await useAnotherServer();
        };
        picker = new StackPanel
        {
            Spacing = 34,
            Children =
            {
                new StackPanel { Spacing = 8, Children = { ScreenParts.Title("Who's watching?"), ScreenParts.Detail(model.ServerName) } },
                loading,
                grid,
                otherServer,
                confirmOther,
            },
        };
        setup = SetupForm();
        Content = ScreenParts.Backdrop(new ScrollViewer
        {
            Content = new StackPanel
            {
                Spacing = 24,
                Margin = new Thickness(40, 70, 40, 40),
                VerticalAlignment = VerticalAlignment.Center,
                Children = { picker, pinEntry, setup, error },
            },
        });
        model.PropertyChanged += OnModelChanged;
        model.Profiles.CollectionChanged += OnProfilesChanged;
        DetachedFromVisualTree += (_, _) =>
        {
            model.PropertyChanged -= OnModelChanged;
            model.Profiles.CollectionChanged -= OnProfilesChanged;
        };
        RebuildGrid();
        Update();
    }

    internal ProfilePickerModel Model => model;

    private StackPanel SetupForm()
    {
        var password = new TextBox { PasswordChar = '•', PlaceholderText = "Server Password", Width = 320 };
        var newPin = new TextBox { PasswordChar = '•', PlaceholderText = "Owner PIN (4–8 digits)", MaxLength = 8, Width = 320 };
        var confirm = new TextBox { PasswordChar = '•', PlaceholderText = "Confirm PIN", MaxLength = 8, Width = 320 };
        AutomationProperties.SetName(password, "Server Password");
        AutomationProperties.SetName(newPin, "Owner PIN");
        AutomationProperties.SetName(confirm, "Confirm PIN");
        var submit = new Button { Content = "Set Up Profiles", Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Center };
        submit.Click += async (_, _) => await model.SetUpAsync(password.Text ?? "", newPin.Text ?? "", confirm.Text ?? "");
        return new StackPanel
        {
            Spacing = 14,
            HorizontalAlignment = HorizontalAlignment.Center,
            Children =
            {
                ScreenParts.Symbol("IconPerson", 46),
                ScreenParts.Title("Set Up Viewing Profiles"),
                ScreenParts.Detail("Enter the server password and choose a PIN for the owner's profile. Everyone who watches gets their own profile."),
                password,
                newPin,
                confirm,
                submit,
            },
        };
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e) => Update();

    private void OnProfilesChanged(object? sender, NotifyCollectionChangedEventArgs e) => RebuildGrid();

    private void Update()
    {
        picker.IsVisible = !model.NeedsSetup && !model.IsEnteringPin;
        setup.IsVisible = model.NeedsSetup;
        pinEntry.IsVisible = model.IsEnteringPin;
        loading.IsVisible = model.IsLoading;
        error.Text = model.Error;
        error.IsVisible = model.Error is not null;
        if (model.IsEnteringPin && model.Selected is { } profile && (pinEntry.Tag as Guid?) != profile.Id) BuildPinEntry(profile);
        if (model.FailedAttempts != shownFailures)
        {
            shownFailures = model.FailedAttempts;
            _ = Shake();
        }
    }

    private void RebuildGrid()
    {
        grid.Children.Clear();
        foreach (var profile in model.Profiles)
        {
            var button = new Button
            {
                Classes = { "profile" },
                IsEnabled = ProfilePickerModel.CanChoose(profile),
                Content = new StackPanel
                {
                    Spacing = 12,
                    Children =
                    {
                        new ProfileAvatar(profile.Id, profile.Name, 96),
                        new TextBlock { Text = profile.Name, FontSize = 16, FontWeight = FontWeight.SemiBold, HorizontalAlignment = HorizontalAlignment.Center },
                        new TextBlock
                        {
                            Text = !ProfilePickerModel.CanChoose(profile) ? "Needs a PIN" : profile.Role switch
                            {
                                UserRole.Owner => "Owner",
                                UserRole.Admin => "Administrator",
                                _ => ProfilePickerModel.NeedsPin(profile) ? "PIN" : " ",
                            },
                            Classes = { "subdued" },
                            HorizontalAlignment = HorizontalAlignment.Center,
                        },
                    },
                },
            };
            AutomationProperties.SetName(button, profile.Name);
            button.Click += async (_, _) => await model.ChooseAsync(profile);
            grid.Children.Add(button);
        }
    }

    private void BuildPinEntry(WatchingProfile profile)
    {
        pinEntry.Tag = profile.Id;
        var submit = new Button { Content = "Open Profile", Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Center };
        submit.Click += async (_, _) => await model.SubmitPinAsync();
        var cancel = new Button { Content = "Back", Classes = { "link" }, HorizontalAlignment = HorizontalAlignment.Center };
        cancel.Click += (_, _) => model.CancelPin();
        pinEntry.Children.Clear();
        pinEntry.Children.Add(new ProfileAvatar(profile.Id, profile.Name, 110).Also(a => a.HorizontalAlignment = HorizontalAlignment.Center));
        pinEntry.Children.Add(ScreenParts.Title(profile.Name));
        pinEntry.Children.Add(ScreenParts.Detail("Enter your PIN."));
        pinEntry.Children.Add(pin);
        pinEntry.Children.Add(submit);
        if (forgotOwnerPin is not null && profile.Role == Aurelia.Contracts.UserRole.Owner)
        {
            var forgot = new Button { Content = "Forgot PIN?", Classes = { "link" }, HorizontalAlignment = HorizontalAlignment.Center };
            forgot.Click += (_, _) =>
            {
                model.CancelPin();
                forgotOwnerPin();
            };
            pinEntry.Children.Add(forgot);
        }
        pinEntry.Children.Add(cancel);
        Avalonia.Threading.Dispatcher.UIThread.Post(() => pin.Focus());
    }

    /// <summary>The PIN field shakes after a wrong PIN, as on the Mac.</summary>
    private async Task Shake()
    {
        var animation = new Animation
        {
            Duration = TimeSpan.FromMilliseconds(360),
            Children =
            {
                new KeyFrame { Cue = new Cue(0), Setters = { new Setter(TranslateTransform.XProperty, 0d) } },
                new KeyFrame { Cue = new Cue(0.2), Setters = { new Setter(TranslateTransform.XProperty, -12d) } },
                new KeyFrame { Cue = new Cue(0.4), Setters = { new Setter(TranslateTransform.XProperty, 10d) } },
                new KeyFrame { Cue = new Cue(0.6), Setters = { new Setter(TranslateTransform.XProperty, -6d) } },
                new KeyFrame { Cue = new Cue(0.8), Setters = { new Setter(TranslateTransform.XProperty, 3d) } },
                new KeyFrame { Cue = new Cue(1), Setters = { new Setter(TranslateTransform.XProperty, 0d) } },
            },
        };
        pin.RenderTransform ??= new TranslateTransform();
        await animation.RunAsync(pin);
        pin.Focus();
    }
}
