using System.Globalization;
using Aurelia.Contracts;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Management;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input.Platform;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using static Aurelia.Linux.Management.AdminScope;
using static Aurelia.Linux.Settings.SettingsRows;

namespace Aurelia.Linux.Management;

/// <summary>
/// The owner's part of Profiles and Devices, as on the Mac: every profile with its role, PIN and
/// access, the profile editor, and the devices: approving an Apple TV or browser code, the browser
/// address, the pairing code every new device asks for, and signed-in devices.
/// </summary>
public sealed class PeoplePage : StackPanel
{
    private readonly AdminScope scope;
    private readonly TextBlock message = Message();
    private readonly StackPanel profiles = new() { Spacing = 0 };
    private readonly StackPanel devices = new() { Spacing = 12 };
    private IReadOnlyList<UserAccessSummary> users = [];
    private DispatcherTimer? codeTimer;

    public PeoplePage(AdminScope scope)
    {
        this.scope = scope;
        Spacing = 22;
        Children.Add(message);
        Children.Add(Section("Profiles", Block(
            Note("Everyone who watches gets a profile. Choose what each profile can see; owners always see everything."),
            profiles,
            Button("Create Profile…", () => EditAsync(null), "primary"),
            Note("New profiles start without access to any titles until you choose them."))));
        Children.Add(Section("Devices", Block(Note("Connect another computer, an Apple TV or a web browser to this server, and sign out devices you no longer use."), devices)));
        DetachedFromVisualTree += (_, _) => codeTimer?.Stop();
        Loading = ReloadAsync();
    }

    internal Task Loading { get; private set; }

    private ManagementClient Client => scope.Client;

    public async Task ReloadAsync()
    {
        IReadOnlyList<DeviceSessionSummary> sessions = [];
        await scope.RunAsync(async () =>
        {
            users = await Client.UsersAsync();
            sessions = await Client.DevicesAsync();
        }, message);
        FillProfiles();
        FillDevices(sessions);
    }

    private void FillProfiles()
    {
        profiles.Children.Clear();
        foreach (var access in users)
        {
            var user = access.User;
            var pin = user.NeedsPinSetup ? "PIN setup required" : user.PinProtectionEnabled ? "PIN protected" : "No PIN";
            var content = user.Role == UserRole.Owner || user.AccessMode == ProfileAccessMode.EntireLibrary ? "Entire Library"
                : user.AccessMode == ProfileAccessMode.SelectedTitles ? "Selected Titles" : "Existing Storage Grants";
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
            var edit = Button("Edit Profile…", () => EditAsync(access));
            AutomationProperties.SetName(edit, "Edit Profile " + ProfileVisuals.ShownName(user));
            actions.Children.Add(edit);
            if (CanDelete(access))
            {
                var delete = Button("Delete Profile…", () => DeleteAsync(access), "destructive");
                AutomationProperties.SetName(delete, "Delete Profile " + ProfileVisuals.ShownName(user));
                actions.Children.Add(delete);
            }
            profiles.Children.Add(new DockPanel
            {
                Margin = new Thickness(0, 6),
                Children =
                {
                    actions.Also(a => DockPanel.SetDock(a, Dock.Right)),
                    new StackPanel
                    {
                        Orientation = Orientation.Horizontal,
                        Spacing = 12,
                        Children =
                        {
                            new ProfileAvatar(user, 38),
                            new StackPanel
                            {
                                VerticalAlignment = VerticalAlignment.Center,
                                Spacing = 2,
                                Children =
                                {
                                    new TextBlock { Text = ProfileVisuals.ShownName(user), FontWeight = FontWeight.SemiBold },
                                    new TextBlock { Text = $"{RoleName(user.Role)} · {(access.IsEnabled ? "Enabled" : "Disabled")}", Classes = { "subdued" }, FontSize = 12 },
                                    new TextBlock { Text = $"{pin} · {content}", Classes = { "subdued" }, FontSize = 12 },
                                },
                            },
                        },
                    },
                },
            });
        }
    }

    internal static string RoleName(UserRole role) => role switch
    {
        UserRole.Owner => "Owner",
        UserRole.Admin => "Administrator",
        _ => "User",
    };

    /// <summary>The owner can delete any other profile, but never the last enabled owner.</summary>
    private bool CanDelete(UserAccessSummary access) =>
        scope.IsOwner && access.User.Id != scope.User.Id
        && (access.User.Role != UserRole.Owner || !access.IsEnabled || users.Count(u => u.User.Role == UserRole.Owner && u.IsEnabled) > 1);

    private async Task DeleteAsync(UserAccessSummary access)
    {
        if (!await scope.Sheets.ConfirmAsync($"Delete {ProfileVisuals.ShownName(access.User)}?",
            $"Favorites, playback progress and scene notes for {ProfileVisuals.ShownName(access.User)} will be permanently removed. Active sessions will end. Your media and shared library will stay unchanged.",
            "Delete Profile", destructive: true)) return;
        if (await scope.RunAsync(() => Client.DeleteProfileAsync(access.User.Id), message)) await ReloadAsync();
    }

    private async Task EditAsync(UserAccessSummary? existing)
    {
        ProfileEditorResponse? snapshot = null;
        ProfileAgeLimitResponse? ageLimit = null;
        if (existing is not null && !await scope.RunAsync(async () =>
            {
                snapshot = await Client.ProfileAsync(existing.User.Id);
                // Servers before children's profiles have no age limits; the editor then hides that section.
                if (scope.Session.Capabilities.Contains(ServerFeatures.AgeLimits)) ageLimit = await Client.AgeLimitAsync(existing.User.Id);
            }, message)) return;
        var editor = new ProfileEditorSheet(scope, snapshot, scope.Session.Library?.Catalog ?? [], ageLimit);
        if (await scope.Sheets.ShowAsync(editor)) await ReloadAsync();
    }

    private void FillDevices(IReadOnlyList<DeviceSessionSummary> sessions)
    {
        devices.Children.Clear();
        var capabilities = scope.Session.Capabilities;
        // Every device pairs the same way: this computer shows a code, the new device asks for it.
        devices.Children.Add(Heading("Add a Device"));
        devices.Children.Add(Note("This computer shows the code; you type it on the new device: another Mac or Linux computer, an iPhone, iPad, Apple TV or a web browser."));
        devices.Children.Add(Note("1. Click Create Code.\n2. Open Aurelia on the new device and choose this server.\n3. Type the code there. A code works once and for five minutes."));
        var code = new StackPanel { Spacing = 8 };
        var create = new Button { Content = "Create Code", Classes = { "primary" } };
        AutomationProperties.SetName(create, "Create Code");
        create.Click += async (_, _) =>
        {
            PairingCodeResponse? pairing = null;
            if (!await scope.RunAsync(async () => pairing = await Client.CreatePairingCodeAsync(), message) || pairing is null) return;
            create.Content = "Create a New Code";
            ShowCode(code, pairing);
        };
        devices.Children.Add(code);
        if (scope.IsOwner) devices.Children.Add(create);
        else devices.Children.Add(Note("Only the owner can add a device."));
        devices.Children.Add(Divider());
        devices.Children.Add(Heading("Web Browser"));
        if (!capabilities.Contains("web-app-v1"))
        {
            devices.Children.Add(Note("Using Aurelia in a web browser requires Aurelia Server 1.10.0."));
        }
        else
        {
            var address = BrowserAddress.Resolve(Client.Library.Server.Address, null, null);
            devices.Children.Add(Note(address.ThisComputerOnly
                ? "Open this address in a browser on this computer. To use Aurelia in browsers on other devices, turn on home network access for this server."
                : "Open this address in a browser on any device at home. The browser asks for a code; create one above."));
            var text = address.Url.ToString().TrimEnd('/');
            devices.Children.Add(new Border
            {
                Classes = { "card" },
                Padding = new Thickness(12),
                Child = new DockPanel
                {
                    Children =
                    {
                        Buttons(
                            Button("Copy", () => CopyAsync(text)),
                            Button("Open", async () =>
                            {
                                if (TopLevel.GetTopLevel(this)?.Launcher is { } launcher) await launcher.LaunchUriAsync(address.Url);
                            })).Also(b => DockPanel.SetDock(b, Dock.Right)),
                        new SelectableTextBlock { Text = text, FontFamily = new FontFamily("monospace"), VerticalAlignment = VerticalAlignment.Center },
                    },
                },
            });
            if (!address.ThisComputerOnly)
            {
                devices.Children.Add(Note("The first time, the browser warns that the connection isn’t private, because the server signs its own certificate. Continue to the page to use Aurelia."));
            }
        }
        var active = sessions.Where(s => s.RevokedAt is null && s.ExpiresAt > DateTimeOffset.UtcNow).ToList();
        if (active.Count == 0) return;
        devices.Children.Add(Divider());
        devices.Children.Add(Heading("Signed-In Devices"));
        foreach (var session in active)
        {
            var row = new DockPanel
            {
                Children =
                {
                    new StackPanel
                    {
                        Children =
                        {
                            new TextBlock { Text = session.DeviceName },
                            new TextBlock { Text = session.IsCurrent ? "This device" : "Last used " + Date(session.LastSeenAt), Classes = { "subdued" }, FontSize = 12 },
                        },
                    },
                },
            };
            if (!session.IsCurrent)
            {
                var revoke = Button("Sign Out", async () =>
                {
                    if (!await scope.Sheets.ConfirmAsync($"Sign out {session.DeviceName}?", "The device needs a new code to use this server again. Its playback stops now.", "Sign Out", destructive: true)) return;
                    if (await scope.RunAsync(() => Client.RevokeDeviceAsync(session.Id), message)) await ReloadAsync();
                }, "destructive");
                AutomationProperties.SetName(revoke, "Sign Out " + session.DeviceName);
                row.Children.Insert(0, revoke.Also(b => DockPanel.SetDock(b, Dock.Right)));
            }
            devices.Children.Add(row);
        }
    }

    private void ShowCode(StackPanel host, PairingCodeResponse pairing)
    {
        codeTimer?.Stop();
        var digits = new SelectableTextBlock { Text = pairing.Code, FontFamily = new FontFamily("monospace"), FontSize = 22, FontWeight = FontWeight.Bold };
        var expiry = new TextBlock { Classes = { "subdued" }, FontSize = 12 };
        var copy = Button("Copy", () => CopyAsync(pairing.Code));
        void Tick()
        {
            var remaining = (int)Math.Ceiling(Math.Max(0, (pairing.ExpiresAt - DateTimeOffset.UtcNow).TotalSeconds));
            if (remaining == 0)
            {
                expiry.Text = "This code has expired. Create a new one.";
                digits.TextDecorations = TextDecorations.Strikethrough;
                copy.IsEnabled = false;
                codeTimer?.Stop();
                return;
            }
            expiry.Text = string.Format(CultureInfo.InvariantCulture, "Valid for {0}:{1:00}, until {2:HH:mm}", remaining / 60, remaining % 60, pairing.ExpiresAt.ToLocalTime());
        }
        Tick();
        codeTimer = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) => Tick());
        codeTimer.Start();
        host.Children.Clear();
        host.Children.Add(new Border
        {
            Classes = { "card" },
            Padding = new Thickness(12),
            Child = new DockPanel
            {
                Children =
                {
                    copy.Also(b => DockPanel.SetDock(b, Dock.Right)),
                    new StackPanel { Spacing = 2, Children = { digits, expiry } },
                },
            },
        });
    }

    private async Task CopyAsync(string text)
    {
        if (TopLevel.GetTopLevel(this)?.Clipboard is { } clipboard) await clipboard.SetTextAsync(text);
    }

    internal static string? DeviceCode(string? text)
    {
        var digits = new string((text ?? "").Where(c => c is not (' ' or '-')).ToArray());
        return digits.Length == 8 && digits.All(char.IsAsciiDigit) ? digits : null;
    }

    private static TextBlock Heading(string text) => new() { Text = text, FontWeight = FontWeight.SemiBold };

    private static Border Divider() => new() { Height = 1, Background = Application.Current?.FindResource("AureliaHairlineBrush") as IBrush };
}

/// <summary>The Mac's ServerProfileEditor: name, role, enabled, PIN protection and content access, saved together.</summary>
public sealed class ProfileEditorSheet : UserControl
{
    private readonly AdminScope scope;
    private readonly ProfileEditorResponse? snapshot;
    private readonly IReadOnlyList<CatalogItemSummary> catalog;
    private readonly HashSet<Guid> selected;
    private readonly TextBlock problem = Message();
    private readonly StackPanel access = new() { Spacing = 10 };
    private readonly StackPanel titles = new() { Spacing = 4 };
    private readonly TextBlock count = new() { Classes = { "subdued" }, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBox name = new() { PlaceholderText = "Name" };
    private readonly TextBox pin = new() { PasswordChar = '•', PlaceholderText = "New PIN (optional)", MaxLength = 8 };
    private readonly TextBox confirm = new() { PasswordChar = '•', PlaceholderText = "Confirm PIN", MaxLength = 8 };
    private readonly ToggleSwitch enabled = new() { OnContent = "", OffContent = "" };
    private readonly ToggleSwitch pinProtected = new() { OnContent = "", OffContent = "" };
    private readonly TextBlock pinNote = Note("");
    private readonly ProfileAgeLimitResponse? ageSnapshot;
    private readonly bool ageLimits;
    private readonly ProfilePicturePicker picture;
    private readonly ToggleSwitch child = new() { OnContent = "", OffContent = "" };
    private readonly StackPanel childOptions = new() { Spacing = 10 };
    private readonly HashSet<Guid> allowed;
    private readonly HashSet<Guid> hidden;
    private UserRole role;
    private ProfileAccessMode mode;
    private int ageLimit;
    private string query = "";
    private string exceptionQuery = "";

    /// <summary>The age steps of a children's profile, after the German FSK ratings.</summary>
    public static IReadOnlyList<(int Value, string Label)> AgeSteps { get; } =
    [
        (0, "Under 6 · FSK 0"),
        (6, "6 to 11 · up to FSK 6"),
        (12, "12 to 15 · up to FSK 12"),
        (16, "16 or 17 · up to FSK 16"),
    ];

    public ProfileEditorSheet(AdminScope scope, ProfileEditorResponse? snapshot, IReadOnlyList<CatalogItemSummary> catalog, ProfileAgeLimitResponse? ageLimit = null)
    {
        this.scope = scope;
        this.snapshot = snapshot;
        ageSnapshot = ageLimit;
        ageLimits = scope.Session.Capabilities.Contains(ServerFeatures.AgeLimits);
        allowed = [.. ageLimit?.AllowedTitleIds ?? []];
        hidden = [.. ageLimit?.HiddenTitleIds ?? []];
        this.ageLimit = ageLimit?.AgeLimit ?? 6;
        child.IsChecked = ageLimit?.AgeLimit is not null;
        AutomationProperties.SetName(child, "Children's Profile");
        picture = new ProfilePicturePicker(snapshot?.User.Id, () => string.IsNullOrWhiteSpace(name.Text) ? "?" : name.Text, snapshot?.User.PictureKey, snapshot?.User.PictureRevision ?? 0);
        name.TextChanged += (_, _) => picture.Refresh();
        child.IsCheckedChanged += (_, _) =>
        {
            ShowChild();
            ShowAccess();
        };
        this.catalog = [.. catalog.Where(item => item.Kind is MediaKind.Movie or MediaKind.Series).OrderBy(item => item.Title, StringComparer.CurrentCultureIgnoreCase)];
        selected = [.. snapshot?.Access.TitleIds ?? []];
        role = snapshot?.User.Role ?? UserRole.User;
        mode = snapshot?.Access.Mode ?? ProfileAccessMode.SelectedTitles;
        Width = 620;
        MaxHeight = 640;
        name.Text = snapshot is null ? null : ProfileVisuals.ShownName(snapshot.User);
        enabled.IsChecked = snapshot?.IsEnabled ?? true;
        pinProtected.IsChecked = snapshot?.User.PinProtectionEnabled ?? true;
        AutomationProperties.SetName(name, "Profile Name");
        AutomationProperties.SetName(pin, "New PIN");
        AutomationProperties.SetName(confirm, "Confirm PIN");
        AutomationProperties.SetName(pinProtected, "Require a Profile PIN");
        pinProtected.IsCheckedChanged += (_, _) => ShowPin();
        var roles = new ComboBox { ItemsSource = new[] { "User", "Administrator", "Owner" }, SelectedIndex = role switch { UserRole.Admin => 1, UserRole.Owner => 2, _ => 0 }, MinWidth = 200 };
        roles.SelectionChanged += (_, _) =>
        {
            role = roles.SelectedIndex switch { 1 => UserRole.Admin, 2 => UserRole.Owner, _ => UserRole.User };
            if (role != UserRole.User) pinProtected.IsChecked = true;
            if (role != UserRole.User) child.IsChecked = false;
            ShowPin();
            ShowChild();
            ShowAccess();
        };
        var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
        cancel.Click += (_, _) => scope.Sheets.Close(false);
        var save = new Button { Content = snapshot is null ? "Create Profile" : "Save", Classes = { "primary" }, IsDefault = true };
        save.Click += async (_, _) =>
        {
            save.IsEnabled = false;
            await SaveAsync();
            save.IsEnabled = true;
        };
        ShowPin();
        ShowChild();
        ShowAccess();
        var sections = new StackPanel
        {
            Spacing = 16,
            Children =
            {
                Section("Profile",
                    Row("Name", "The name everyone sees. An owner keeps signing in with the original name.", name.Also(n => n.Width = 240)),
                    Row("Role", "Administrators manage their allowed content. Owners manage the whole server.", roles),
                    Row("Profile Enabled", null, enabled)),
                Section("Picture", Block(picture)),
                Section("PIN Protection",
                    Row("Require a Profile PIN", null, pinProtected),
                    Block(pin, confirm, pinNote)),
            },
        };
        if (ageLimits) sections.Children.Add(Section("Children's Profile", Row("Children's Profile", "Shows only what is approved for the child's age.", child), Block(childOptions)));
        sections.Children.Add(Section("Content Access", Block(access)));
        Content = new DockPanel
        {
            Children =
            {
                new StackPanel
                {
                    Spacing = 10,
                    Margin = new Thickness(0, 14, 0, 0),
                    Children =
                    {
                        problem,
                        new DockPanel
                        {
                            Children =
                            {
                                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { cancel, save } }.Also(p => DockPanel.SetDock(p, Dock.Right)),
                                Note("Changes are saved together. Media files are never changed."),
                            },
                        },
                    },
                }.Also(p => DockPanel.SetDock(p, Dock.Bottom)),
                new StackPanel
                {
                    Spacing = 4,
                    Margin = new Thickness(0, 0, 0, 12),
                    Children =
                    {
                        new TextBlock { Text = snapshot is null ? "Create Profile" : ProfileVisuals.ShownName(snapshot.User), FontSize = 20, FontWeight = FontWeight.Bold },
                        Note("Choose who can watch and what they can see."),
                    },
                }.Also(p => DockPanel.SetDock(p, Dock.Top)),
                new ScrollViewer
                {
                    HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                    Content = sections,
                },
            },
        };
    }

    private void ShowPin()
    {
        var mandatory = role != UserRole.User;
        pinProtected.IsEnabled = !mandatory;
        var protectedNow = pinProtected.IsChecked == true;
        pin.IsVisible = confirm.IsVisible = protectedNow;
        pin.PlaceholderText = snapshot is null ? "PIN (4–8 digits)" : "New PIN (optional)";
        pinNote.Text = mandatory ? "Owner and administrator profiles always require a PIN."
            : !protectedNow ? "Anyone on a paired device can open this profile and see its favorites, progress and notes."
            : snapshot is null ? "Enter a PIN, or leave both fields empty to choose it when the profile is first opened."
            : "Leave both fields empty to keep the current PIN. Changing it locks active sessions.";
        if (!protectedNow) pin.Text = confirm.Text = "";
    }

    private bool IsChild => ageLimits && child.IsChecked == true && role == UserRole.User;

    /// <summary>The age step, and the titles allowed anyway or always hidden, of a children's profile.</summary>
    private void ShowChild()
    {
        child.IsEnabled = role == UserRole.User;
        childOptions.Children.Clear();
        if (!ageLimits) return;
        if (role != UserRole.User)
        {
            childOptions.Children.Add(Note("Only profiles without server access can be children's profiles."));
            return;
        }
        if (!IsChild) return;
        childOptions.Children.Add(Choice("Age", "Titles rated above this age, and titles without a rating, are hidden.", AgeSteps, ageLimit, value => ageLimit = value)
            .Also(r => r.Margin = new Thickness(0)));
        var search = new TextBox { PlaceholderText = "Search films and series for exceptions", Text = exceptionQuery };
        AutomationProperties.SetName(search, "Search Exceptions");
        var list = new StackPanel { Spacing = 4 };
        void Fill()
        {
            list.Children.Clear();
            var matching = catalog.Where(item => exceptionQuery.Length > 0 ? item.Title.Contains(exceptionQuery, StringComparison.CurrentCultureIgnoreCase)
                : allowed.Contains(item.Id) || hidden.Contains(item.Id)).Take(200).ToList();
            foreach (var item in matching)
            {
                var state = allowed.Contains(item.Id) ? 1 : hidden.Contains(item.Id) ? 2 : 0;
                var choice = new ComboBox { ItemsSource = new[] { "By Age", "Allow Anyway", "Always Hide" }, SelectedIndex = state, MinWidth = 150 };
                AutomationProperties.SetName(choice, "Exception " + item.Title);
                var id = item.Id;
                choice.SelectionChanged += (_, _) =>
                {
                    allowed.Remove(id);
                    hidden.Remove(id);
                    if (choice.SelectedIndex == 1) allowed.Add(id);
                    if (choice.SelectedIndex == 2) hidden.Add(id);
                };
                list.Children.Add(new DockPanel
                {
                    Children =
                    {
                        choice.Also(c => DockPanel.SetDock(c, Dock.Right)),
                        new TextBlock
                        {
                            Text = (item.Kind == MediaKind.Series ? "TV · " : "Film · ") + item.Title + (item.Year is { } year ? $" ({year})" : ""),
                            VerticalAlignment = VerticalAlignment.Center,
                            TextTrimming = TextTrimming.CharacterEllipsis,
                        },
                    },
                });
            }
            if (matching.Count == 0) list.Children.Add(Note(exceptionQuery.Length == 0 ? "No exceptions. Search for a title to allow or hide it." : "No matching titles."));
        }
        search.TextChanged += (_, _) =>
        {
            exceptionQuery = search.Text ?? "";
            Fill();
        };
        childOptions.Children.Add(search);
        childOptions.Children.Add(new Border { Classes = { "card" }, Padding = new Thickness(10), Child = new ScrollViewer { MaxHeight = 190, Content = list } });
        Fill();
    }

    private void ShowAccess()
    {
        access.Children.Clear();
        if (IsChild)
        {
            access.Children.Add(Note("A children's profile can watch the whole library, limited by its age."));
            return;
        }
        // The count and the title list move into the rebuilt rows.
        if (count.Parent is Panel row) row.Children.Remove(count);
        if (titles.Parent is ScrollViewer list) list.Content = null;
        var options = new List<(ProfileAccessMode Mode, string Label)>();
        if (snapshot?.Access.Mode == ProfileAccessMode.LegacyLibraries) options.Add((ProfileAccessMode.LegacyLibraries, "Existing Storage Grants"));
        options.Add((ProfileAccessMode.EntireLibrary, "Entire Library"));
        options.Add((ProfileAccessMode.SelectedTitles, "Selected Titles"));
        var effective = role == UserRole.Owner ? ProfileAccessMode.EntireLibrary : mode;
        var chooser = Choice("Can Watch", null, options, effective, value => { mode = value; ShowAccess(); }).Also(r => r.Margin = new Thickness(0));
        chooser.IsEnabled = role != UserRole.Owner;
        access.Children.Add(chooser);
        if (effective == ProfileAccessMode.EntireLibrary)
        {
            access.Children.Add(Note("Includes all existing titles and titles added later."));
            return;
        }
        if (effective == ProfileAccessMode.LegacyLibraries)
        {
            access.Children.Add(Note("Existing storage grants stay unchanged unless you select another access mode."));
            return;
        }
        var search = new TextBox { PlaceholderText = "Search films and series", Text = query };
        AutomationProperties.SetName(search, "Search Titles");
        search.TextChanged += (_, _) =>
        {
            query = search.Text ?? "";
            FillTitles();
        };
        access.Children.Add(new DockPanel { Children = { count.Also(c => { DockPanel.SetDock(c, Dock.Right); c.Margin = new Thickness(10, 0, 0, 0); }), search } });
        access.Children.Add(new Border { Classes = { "card" }, Padding = new Thickness(10), Child = new ScrollViewer { MaxHeight = 190, Content = titles } });
        access.Children.Add(Note("A series includes all current and future seasons, episodes, extras and trailers."));
        FillTitles();
    }

    private void FillTitles()
    {
        titles.Children.Clear();
        count.Text = $"{selected.Count} selected";
        var matching = catalog.Where(item => query.Length == 0 || item.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase)).Take(300).ToList();
        foreach (var item in matching)
        {
            var box = new CheckBox
            {
                IsChecked = selected.Contains(item.Id),
                Content = (item.Kind == MediaKind.Series ? "TV · " : "Film · ") + item.Title + (item.Year is { } year ? $" ({year})" : ""),
            };
            box.IsCheckedChanged += (_, _) =>
            {
                if (box.IsChecked == true) selected.Add(item.Id);
                else selected.Remove(item.Id);
                count.Text = $"{selected.Count} selected";
            };
            titles.Children.Add(box);
        }
        if (matching.Count == 0) titles.Children.Add(Note(query.Length == 0 ? "No films or series available." : "No matching titles."));
    }

    private async Task SaveAsync()
    {
        problem.IsVisible = false;
        var protectedNow = pinProtected.IsChecked == true;
        var newPin = protectedNow && !string.IsNullOrEmpty(pin.Text) ? pin.Text : null;
        string? failure = null;
        if (string.IsNullOrWhiteSpace(name.Text)) failure = "Enter a name for the profile.";
        else if (newPin is not null && !ProfilePin.IsValid(newPin)) failure = "Use a PIN with four to eight digits.";
        else if (newPin is not null && newPin != confirm.Text) failure = "The PINs do not match.";
        if (failure is not null)
        {
            problem.Text = failure;
            problem.IsVisible = true;
            return;
        }
        var ids = selected.Order().ToList();
        var shownName = name.Text!.Trim();
        var isChild = IsChild;
        var worked = await scope.RunAsync(async () =>
        {
            Guid id;
            if (snapshot is not null)
            {
                id = snapshot.User.Id;
                // A children's profile always sees the whole library, narrowed by age on the server.
                var wanted = isChild ? ProfileAccessMode.EntireLibrary : mode;
                var changedAccess = !isChild && (wanted != snapshot.Access.Mode || !selected.SetEquals(snapshot.Access.TitleIds));
                await scope.Client.SaveProfileAsync(id, new UpdateProfileRequest(snapshot.Revision, role, enabled.IsChecked == true, protectedNow, newPin,
                    changedAccess ? wanted : null, changedAccess ? ids : null));
                if (shownName != ProfileVisuals.ShownName(snapshot.User)) await scope.Client.RenameProfileAsync(id, shownName);
            }
            else
            {
                var created = await scope.Client.CreateProfileAsync(new CreateUserRequest(shownName, null, role, newPin, protectedNow,
                    role == UserRole.Owner || isChild ? ProfileAccessMode.EntireLibrary : mode, role == UserRole.Owner || isChild ? [] : ids, enabled.IsChecked == true,
                    PictureKey: ProfilePictures.IsBuiltin(picture.Key) ? picture.Key : null, AgeLimit: isChild ? ageLimit : null));
                id = created.Id;
            }
            if (picture.Photo is { } photo) await scope.Client.UploadProfilePhotoAsync(id, photo);
            else if (snapshot is not null && picture.Changed) await scope.Client.SetProfilePictureAsync(id, ProfilePictures.IsBuiltin(picture.Key) ? picture.Key : null);
            if (ageLimits && role == UserRole.User)
            {
                int? limit = isChild ? ageLimit : null;
                var unchanged = ageSnapshot is not null && ageSnapshot.AgeLimit == limit && allowed.SetEquals(ageSnapshot.AllowedTitleIds) && hidden.SetEquals(ageSnapshot.HiddenTitleIds);
                var newPlain = snapshot is null && (!isChild || (allowed.Count == 0 && hidden.Count == 0));
                if (!unchanged && !newPlain && (snapshot is not null || isChild))
                {
                    // The current revision: saving the profile above may already have moved it.
                    var current = await scope.Client.AgeLimitAsync(id);
                    await scope.Client.SaveAgeLimitAsync(id, new UpdateProfileAgeLimitRequest(limit, [.. allowed.Where(_ => isChild)], [.. hidden.Where(_ => isChild)], current.Revision));
                }
            }
        }, problem);
        pin.Text = confirm.Text = "";
        if (worked) scope.Sheets.Close(true);
    }
}
