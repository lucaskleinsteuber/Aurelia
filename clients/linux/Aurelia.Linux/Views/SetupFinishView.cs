using Aurelia.Contracts;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Management;
using Aurelia.Linux.Library;
using Aurelia.Linux.Management;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Views;

/// <summary>
/// The guided setup's last steps, once the library is ready: the people who watch too (when the owner said
/// "Several People"), then "You're All Set" with what was done and how to connect the other devices.
/// </summary>
public sealed class SetupFinishView : UserControl
{
    private readonly AppSession session;
    private readonly AppFlow flow;
    private readonly Action<bool> finished;
    private readonly SheetHost sheets = new();
    private readonly AdminScope scope;
    private readonly ContentControl host = new();
    private readonly SetupStepBarHost bar = new();
    private readonly List<UserSummary> added = [];

    /// <param name="finished">Called with true when the owner wants to see the device settings next.</param>
    public SetupFinishView(AppSession session, AppFlow flow, Action<bool> finished)
    {
        this.session = session;
        this.flow = flow;
        this.finished = finished;
        scope = new AdminScope(session, sheets);
        Content = new Panel
        {
            Children =
            {
                ScreenParts.Backdrop(new ScrollViewer
                {
                    Content = new StackPanel
                    {
                        Margin = new Thickness(40, 80, 40, 40),
                        MaxWidth = 640,
                        VerticalAlignment = VerticalAlignment.Center,
                        Children = { host },
                    },
                }),
                bar,
                sheets,
            },
        };
        if (OffersPeople) ShowPeople();
        else ShowDone();
    }

    internal SheetHost Sheets => sheets;

    internal bool ShowsPeople { get; private set; }

    internal IReadOnlyList<UserSummary> Added => added;

    private bool OffersPeople => flow.Mode == OperatingMode.Host && flow.Guide.Audience == SetupAudience.SeveralPeople
        && session.Profile?.User.Role == UserRole.Owner;

    private void Show(Control page, SetupStep step)
    {
        host.Content = page;
        bar.Child = new SetupStepBar(flow, step);
        Motion.Appear(page, rise: 12, fromScale: 0.99);
    }

    // People: name, picture, an optional PIN, a children's profile by age, and whether they may manage the server.
    private void ShowPeople()
    {
        ShowsPeople = true;
        var list = new StackPanel { Spacing = 8 };
        void FillList()
        {
            list.Children.Clear();
            foreach (var person in added)
            {
                var detail = person.AgeLimit is { } age ? $"Children's profile · up to FSK {age}"
                    : person.Role == UserRole.Admin ? "Can manage the server" : "Can watch everything";
                list.Children.Add(new Border
                {
                    Classes = { "card" },
                    Padding = new Thickness(12, 8),
                    Child = new StackPanel
                    {
                        Orientation = Orientation.Horizontal,
                        Spacing = 12,
                        Children =
                        {
                            new ProfileAvatar(person, 36),
                            new StackPanel
                            {
                                VerticalAlignment = VerticalAlignment.Center,
                                Children =
                                {
                                    new TextBlock { Text = ProfileVisuals.ShownName(person), FontWeight = FontWeight.SemiBold },
                                    new TextBlock { Text = detail, Classes = { "subdued" }, FontSize = 12 },
                                },
                            },
                        },
                    },
                });
            }
        }
        var name = new TextBox { PlaceholderText = "Name", MaxLength = 40 };
        AutomationProperties.SetName(name, "Person's Name");
        var picture = new ProfilePicturePicker(null, () => string.IsNullOrWhiteSpace(name.Text) ? "?" : name.Text, null, 0);
        name.TextChanged += (_, _) => picture.Refresh();
        var pin = new TextBox { PasswordChar = '•', PlaceholderText = "PIN (optional, 4–8 digits)", MaxLength = 8 };
        AutomationProperties.SetName(pin, "Person's PIN");
        var child = new ToggleSwitch { OnContent = "", OffContent = "" };
        AutomationProperties.SetName(child, "Children's Profile");
        var admin = new ToggleSwitch { OnContent = "", OffContent = "" };
        AutomationProperties.SetName(admin, "Can Manage the Server");
        var age = 6;
        var ageRow = Settings.SettingsRows.Choice("Age", "Titles above this age and titles without a rating are hidden.", ProfileEditorSheet.AgeSteps, age, value => age = value);
        ageRow.IsVisible = false;
        var ageSupported = session.Capabilities.Contains(ServerFeatures.AgeLimits);
        child.IsEnabled = ageSupported;
        child.IsCheckedChanged += (_, _) =>
        {
            ageRow.IsVisible = child.IsChecked == true;
            if (child.IsChecked == true) admin.IsChecked = false;
        };
        admin.IsCheckedChanged += (_, _) =>
        {
            if (admin.IsChecked == true) child.IsChecked = false;
        };
        var problem = AdminScope.Message();
        var add = new Button { Content = "Add Person", Classes = { "primary" } };
        AutomationProperties.SetName(add, "Add Person");
        add.Click += async (_, _) =>
        {
            problem.IsVisible = false;
            var wanted = (name.Text ?? "").Trim();
            var code = string.IsNullOrEmpty(pin.Text) ? null : pin.Text;
            string? failure = wanted.Length == 0 ? "Enter the person's name."
                : code is not null && !ProfilePin.IsValid(code) ? "Use a PIN with four to eight digits, or leave it empty."
                : admin.IsChecked == true && code is null ? "Someone who manages the server needs a PIN."
                : null;
            if (failure is not null)
            {
                problem.Text = failure;
                problem.IsVisible = true;
                return;
            }
            add.IsEnabled = false;
            UserSummary? created = null;
            var isChild = ageSupported && child.IsChecked == true;
            var role = admin.IsChecked == true ? UserRole.Admin : UserRole.User;
            await scope.RunAsync(async () =>
            {
                created = await scope.Client.CreateProfileAsync(new CreateUserRequest(wanted, null, role, code, code is not null,
                    ProfileAccessMode.EntireLibrary, [], true, PictureKey: ProfilePictures.IsBuiltin(picture.Key) ? picture.Key : null,
                    AgeLimit: isChild ? age : null));
                if (picture.Photo is { } photo) created = await scope.Client.UploadProfilePhotoAsync(created.Id, photo);
            }, problem);
            add.IsEnabled = true;
            if (created is null) return;
            added.Add(created);
            FillList();
            name.Text = pin.Text = "";
            child.IsChecked = admin.IsChecked = false;
        };
        var next = new Button { Content = "Continue", Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Center, MinWidth = 180 };
        AutomationProperties.SetName(next, "Continue");
        next.Click += (_, _) => ShowDone();
        var skip = new Button { Content = "Skip for Now", Classes = { "link" }, HorizontalAlignment = HorizontalAlignment.Center };
        skip.Click += (_, _) => ShowDone();
        var form = new Border
        {
            Classes = { "card" },
            Padding = new Thickness(20),
            Child = new StackPanel
            {
                Spacing = 12,
                Children =
                {
                    name,
                    picture,
                    pin,
                    Labeled("Children's Profile", ageSupported ? "Only what is approved for their age." : "Update the server to use children's profiles.", child),
                    ageRow,
                    Labeled("Can Manage the Server", "Adds storage, edits details and approves devices. Needs a PIN.", admin),
                    problem,
                    add,
                },
            },
        };
        Show(new StackPanel
        {
            Spacing = 22,
            Children =
            {
                ScreenParts.Symbol("IconPeople", 50),
                new StackPanel { Spacing = 8, Children = { ScreenParts.Title("Who Else Watches?"), ScreenParts.Detail("Add a profile for everyone at home. They pick it in “Who's watching?” on any device.") } },
                list,
                form,
                new StackPanel { Spacing = 8, Children = { next, skip } },
            },
        }, SetupStep.People);
    }

    private static DockPanel Labeled(string title, string detail, Control control) => new()
    {
        Children =
        {
            control.Also(c => { DockPanel.SetDock(c, Dock.Right); c.VerticalAlignment = VerticalAlignment.Center; }),
            new StackPanel
            {
                Spacing = 2,
                Children =
                {
                    new TextBlock { Text = title, FontWeight = FontWeight.SemiBold },
                    new TextBlock { Text = detail, Classes = { "subdued" }, FontSize = 12, TextWrapping = TextWrapping.Wrap },
                },
            },
        },
    };

    // You're All Set: what was done, how to connect each chosen device, then the library and its tour.
    private void ShowDone()
    {
        ShowsPeople = false;
        var serverName = session.Server?.Name ?? "your server";
        var checks = new StackPanel { Spacing = 10 };
        checks.Children.Add(Check(flow.Mode == OperatingMode.Host ? $"This PC runs your server, {serverName}." : $"This PC is connected to {serverName}."));
        if (session.Profile is { } profile) checks.Children.Add(Check($"Your profile, {ProfileVisuals.ShownName(profile.User)}, is protected with your PIN."));
        if (flow.Mode == OperatingMode.Host)
        {
            var titles = session.Library?.Catalog.Count ?? 0;
            checks.Children.Add(titles > 0
                ? Check(titles == 1 ? "One title is in your library." : $"{titles} titles are in your library.")
                : Check("Your media is still being added, or you skipped it. Add drives and folders anytime in Settings › Library.", done: false));
        }
        if (added.Count > 0) checks.Children.Add(Check(added.Count == 1 ? "One more person can watch." : $"{added.Count} more people can watch."));
        var cards = new StackPanel { Spacing = 12 };
        var devices = flow.Mode == OperatingMode.Host ? flow.Guide.Devices : SetupDevices.None;
        if (devices.HasFlag(SetupDevices.AppleTv))
            cards.Children.Add(DeviceCard("IconTvShows", "Apple TV", "Open Aurelia on the Apple TV.", $"Choose {serverName}.",
                "It shows a code: enter it here in Settings › Profiles and Devices."));
        if (devices.HasFlag(SetupDevices.PhoneOrTablet))
            cards.Children.Add(DeviceCard("IconPerson", "iPhone or iPad", "Open Aurelia on the iPhone or iPad.", $"Choose {serverName}.",
                "It shows a code: enter it here in Settings › Profiles and Devices."));
        if (devices.HasFlag(SetupDevices.Computer))
            cards.Children.Add(DeviceCard("IconComputer", "Another Computer", "Install Aurelia on it and choose Connect to an Existing Server.", $"Pick {serverName}.",
                "Create its pairing code here in Settings › Profiles and Devices › Pair a Computer."));
        if (devices.HasFlag(SetupDevices.WebBrowser) && session.Server is { } server)
        {
            var address = BrowserAddress.Resolve(server.Address, null, null).Url.ToString().TrimEnd('/');
            cards.Children.Add(DeviceCard("IconNetwork", "Web Browser", $"Open {address} in a browser at home.", "Accept the security notice once: it is your own server.",
                "Enter the code it shows here in Settings › Profiles and Devices."));
        }
        var start = new Button { Content = "Start Watching", Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Center, MinWidth = 200, IsDefault = true };
        AutomationProperties.SetName(start, "Start Watching");
        start.Click += (_, _) => finished(false);
        var children = new StackPanel
        {
            Spacing = 24,
            Children =
            {
                ScreenParts.Symbol("IconCheck", 50, Application.Current?.FindResource("AureliaAccentBrush") as IBrush),
                new StackPanel { Spacing = 8, Children = { ScreenParts.Title("You're All Set"), ScreenParts.Detail("Here is what Aurelia set up with you.") } },
                new Border { Classes = { "card" }, Padding = new Thickness(20, 16), Child = checks },
            },
        };
        if (cards.Children.Count > 0)
        {
            children.Children.Add(new TextBlock { Text = "CONNECT YOUR OTHER DEVICES", Classes = { "eyebrow", "subdued" } });
            children.Children.Add(cards);
            var openDevices = new Button { Content = "Open Profiles and Devices", Classes = { "chip" }, HorizontalAlignment = HorizontalAlignment.Center };
            openDevices.Click += (_, _) => finished(true);
            children.Children.Add(openDevices);
        }
        children.Children.Add(start);
        Show(children, SetupStep.Done);
    }

    private static StackPanel Check(string text, bool done = true) => new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = 12,
        Children =
        {
            new Border
            {
                Width = 22,
                Height = 22,
                CornerRadius = new CornerRadius(11),
                Background = done ? Application.Current?.FindResource("AureliaAccentBrush") as IBrush : new SolidColorBrush(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF)),
                Child = new PathIcon
                {
                    Data = Application.Current?.FindResource(done ? "IconCheck" : "IconPlus") as Geometry,
                    Width = 11,
                    Height = 11,
                    Foreground = Brushes.White,
                },
            },
            new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 520 },
        },
    };

    private static Border DeviceCard(string symbol, string title, params string[] steps)
    {
        var list = new StackPanel { Spacing = 6 };
        for (var index = 0; index < steps.Length; index++)
        {
            list.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 10,
                Children =
                {
                    new Border
                    {
                        Width = 20,
                        Height = 20,
                        CornerRadius = new CornerRadius(10),
                        Background = new SolidColorBrush(Color.FromArgb(0x24, 0xFF, 0xFF, 0xFF)),
                        Child = new TextBlock
                        {
                            Text = (index + 1).ToString(System.Globalization.CultureInfo.InvariantCulture),
                            FontSize = 11,
                            FontWeight = FontWeight.SemiBold,
                            HorizontalAlignment = HorizontalAlignment.Center,
                            VerticalAlignment = VerticalAlignment.Center,
                        },
                    },
                    new TextBlock { Text = steps[index], TextWrapping = TextWrapping.Wrap, MaxWidth = 470, VerticalAlignment = VerticalAlignment.Center },
                },
            });
        }
        return new Border
        {
            Classes = { "card" },
            Padding = new Thickness(18, 14),
            Child = new StackPanel
            {
                Spacing = 10,
                Children =
                {
                    new StackPanel
                    {
                        Orientation = Orientation.Horizontal,
                        Spacing = 10,
                        Children =
                        {
                            ScreenParts.Symbol(symbol, 20),
                            new TextBlock { Text = title, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center },
                        },
                    },
                    list,
                },
            },
        };
    }

    /// <summary>Holds the step bar at the top of the screen.</summary>
    private sealed class SetupStepBarHost : Decorator
    {
        public SetupStepBarHost()
        {
            VerticalAlignment = VerticalAlignment.Top;
            HorizontalAlignment = HorizontalAlignment.Center;
        }
    }
}
