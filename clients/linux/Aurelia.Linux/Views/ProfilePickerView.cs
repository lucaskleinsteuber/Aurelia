using System.Collections.Specialized;
using System.ComponentModel;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Playback;
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

/// <summary>
/// "Who's watching?" as on the Mac: the profiles on a slowly drifting wash of color, the PIN in a
/// rounded field with an arrow, and the first-time profile setup. Choosing the picture again in
/// the PIN step (or Esc) returns to all profiles.
/// </summary>
public sealed class ProfilePickerView : UserControl
{
    private readonly ProfilePickerModel model;
    private readonly AppSession session;
    private readonly WrapPanel grid = new() { HorizontalAlignment = HorizontalAlignment.Center, ItemSpacing = 18, LineSpacing = 18 };
    private readonly StackPanel picker;
    private readonly StackPanel pinEntry = new() { Spacing = 22, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly StackPanel setup;
    private readonly TextBox pin = new() { PasswordChar = '•', MaxLength = 8, FontSize = 20, Classes = { "pinField" }, HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center };
    private readonly Button unlock = new() { Classes = { "pinArrow" } };
    private readonly Border pinCapsule = new() { Classes = { "pinCapsule" }, Width = 280, Height = 52, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock error = new() { Foreground = new SolidColorBrush(Color.Parse("#FFA94D")), HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 420 };
    private readonly Aurelia.Linux.Controls.Spinner loading = new() { HorizontalAlignment = HorizontalAlignment.Center };
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
        // The capsule is the field; the theme's own focused box inside it must not show.
        pin.TemplateApplied += (_, e) =>
        {
            if (e.NameScope.Find<Border>("PART_BorderElement") is { } box)
            {
                box.Background = Brushes.Transparent;
                box.BorderBrush = Brushes.Transparent;
                box.BorderThickness = new Thickness(0);
            }
        };
        pin[!TextBox.TextProperty] = new Binding(nameof(ProfilePickerModel.Pin)) { Mode = BindingMode.TwoWay };
        AutomationProperties.SetName(unlock, "Open Profile");
        ToolTip.SetTip(unlock, "Open Profile");
        unlock.Content = new PathIcon { Data = Application.Current?.FindResource("IconArrowRight") as Geometry, Width = 15, Height = 15 };
        unlock.Click += async (_, _) => await model.SubmitPinAsync();
        pin.PropertyChanged += (_, e) =>
        {
            if (e.Property == TextBox.TextProperty) unlock.IsEnabled = !string.IsNullOrEmpty(pin.Text);
        };
        unlock.IsEnabled = false;
        pinCapsule.Child = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("44,*,44"),
            Children = { pin.Also(p => Grid.SetColumn(p, 1)), unlock.Also(u => Grid.SetColumn(u, 2)) },
        };
        pin.GotFocus += (_, _) => pinCapsule.Classes.Set("focused", true);
        pin.LostFocus += (_, _) => pinCapsule.Classes.Set("focused", false);
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
                new StackPanel { Spacing = 8, Children = { new TextBlock { Text = "Who's watching?", FontSize = 40, FontWeight = FontWeight.Bold, LetterSpacing = -0.5, HorizontalAlignment = HorizontalAlignment.Center }, ScreenParts.Detail(model.ServerName) } },
                loading,
                grid,
                otherServer,
                confirmOther,
            },
        };
        setup = SetupForm();
        Content = new Panel
        {
            Children =
            {
                new AmbientBackground(animate: !session.Preferences.ReduceMotion),
                new ScrollViewer
        {
            Content = new StackPanel
            {
                Spacing = 24,
                Margin = new Thickness(40, 70, 40, 40),
                VerticalAlignment = VerticalAlignment.Center,
                Children = { picker, pinEntry, setup, error },
            },
                },
            },
        };
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
            var locked = ProfilePickerModel.NeedsPin(profile) || profile.NeedsPinSetup;
            var name = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 5,
                HorizontalAlignment = HorizontalAlignment.Center,
                Children = { new TextBlock { Text = profile.Name, FontSize = 16, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap, MaxWidth = 130, TextAlignment = TextAlignment.Center } },
            };
            if (locked) name.Children.Add(ScreenParts.Symbol("IconLock", 11, new SolidColorBrush(Color.FromArgb(0xA6, 0xFF, 0xFF, 0xFF))).Also(l => l.VerticalAlignment = VerticalAlignment.Center));
            var tile = new StackPanel { Spacing = 12, Children = { new ProfileAvatar(profile, 96).Also(a => a.HorizontalAlignment = HorizontalAlignment.Center), name } };
            // Screen time closes a children's profile until its wake time.
            if (ScreenTimeText.ClosedLabel(profile.ClosedUntil) is { } asleep)
            {
                tile.Opacity = 0.6;
                tile.Children.Add(new TextBlock { Text = asleep, Classes = { "subdued" }, FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center });
            }
            else if (!ProfilePickerModel.CanChoose(profile)) tile.Children.Add(new TextBlock { Text = "Set up PIN", Classes = { "subdued" }, FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center });
            var button = new Button
            {
                Classes = { "profile" },
                IsEnabled = ProfilePickerModel.CanChoose(profile),
                VerticalAlignment = VerticalAlignment.Top,
                Content = tile,
            };
            AutomationProperties.SetName(button, profile.Name);
            button.Click += async (_, _) => await model.ChooseAsync(profile);
            grid.Children.Add(button);
        }
    }

    private void BuildPinEntry(WatchingProfile profile)
    {
        pinEntry.Tag = profile.Id;
        var back = new Button { Classes = { "profileAvatar" }, HorizontalAlignment = HorizontalAlignment.Center, Content = new ProfileAvatar(profile, 96) };
        AutomationProperties.SetName(back, "Choose Another Profile");
        ToolTip.SetTip(back, "Choose another profile (Esc)");
        back.Click += (_, _) => model.CancelPin();
        pinEntry.Children.Clear();
        pinEntry.Children.Add(back);
        pinEntry.Children.Add(new StackPanel
        {
            Spacing = 6,
            Children =
            {
                new TextBlock { Text = profile.Name, FontSize = 22, FontWeight = FontWeight.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 360 },
                new TextBlock { Text = "Enter your PIN", Classes = { "subdued" }, FontSize = 14, HorizontalAlignment = HorizontalAlignment.Center },
            },
        });
        pin.Text = "";
        pinEntry.Children.Add(pinCapsule);
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
        pinCapsule.RenderTransform ??= new TranslateTransform();
        await animation.RunAsync(pinCapsule);
        pin.Focus();
    }
}
