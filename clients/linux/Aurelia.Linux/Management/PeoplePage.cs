using System.Globalization;
using Aurelia.Contracts;
using Aurelia.Linux.Controls;
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
/// address, a pairing code for another computer, and signed-in devices.
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
            AutomationProperties.SetName(edit, "Edit Profile " + user.Username);
            actions.Children.Add(edit);
            if (CanDelete(access))
            {
                var delete = Button("Delete Profile…", () => DeleteAsync(access), "destructive");
                AutomationProperties.SetName(delete, "Delete Profile " + user.Username);
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
                            new ProfileAvatar(user.Id, user.Username, 38),
                            new StackPanel
                            {
                                VerticalAlignment = VerticalAlignment.Center,
                                Spacing = 2,
                                Children =
                                {
                                    new TextBlock { Text = user.Username, FontWeight = FontWeight.SemiBold },
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
        if (!await scope.Sheets.ConfirmAsync($"Delete {access.User.Username}?",
            $"Favorites, playback progress and scene notes for {access.User.Username} will be permanently removed. Active sessions will end. Your media and shared library will stay unchanged.",
            "Delete Profile", destructive: true)) return;
        if (await scope.RunAsync(() => Client.DeleteProfileAsync(access.User.Id), message)) await ReloadAsync();
    }

    private async Task EditAsync(UserAccessSummary? existing)
    {
        ProfileEditorResponse? snapshot = null;
        if (existing is not null && !await scope.RunAsync(async () => snapshot = await Client.ProfileAsync(existing.User.Id), message)) return;
        var editor = new ProfileEditorSheet(scope, snapshot, scope.Session.Library?.Catalog ?? []);
        if (await scope.Sheets.ShowAsync(editor)) await ReloadAsync();
    }

    private void FillDevices(IReadOnlyList<DeviceSessionSummary> sessions)
    {
        devices.Children.Clear();
        var capabilities = scope.Session.Capabilities;
        devices.Children.Add(Heading("Apple TV and Web Browser"));
        devices.Children.Add(Note("Open Aurelia on the Apple TV or in a browser and choose this server. It shows an 8-digit code; enter it here to let the device in."));
        if (scope.IsOwner)
        {
            var approve = Button("Enter Code from Apple TV or Browser…", ApproveDeviceAsync, "primary");
            approve.IsEnabled = capabilities.Contains("device-authorization-v1");
            if (!approve.IsEnabled) devices.Children.Add(Note("Requires Aurelia Server 1.5.5."));
            devices.Children.Add(approve);
        }
        else
        {
            devices.Children.Add(Note("Only the owner can approve an Apple TV or a browser."));
        }
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
                : "Open this address in a browser on any device at home. The browser shows an 8-digit code; enter it with “Enter Code from Apple TV or Browser…”."));
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
        devices.Children.Add(Divider());
        devices.Children.Add(Heading("Another Computer"));
        devices.Children.Add(Note("Create a code here, then type it into Aurelia on the other computer when it connects to this server. A code works once and for five minutes."));
        var code = new StackPanel { Spacing = 8 };
        var create = new Button { Content = "Pair a Computer", Classes = { "primary" } };
        AutomationProperties.SetName(create, "Pair a Computer");
        create.Click += async (_, _) =>
        {
            PairingCodeResponse? pairing = null;
            if (!await scope.RunAsync(async () => pairing = await Client.CreatePairingCodeAsync(), message) || pairing is null) return;
            create.Content = "Create a New Code";
            ShowCode(code, pairing);
        };
        devices.Children.Add(code);
        devices.Children.Add(create);
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
                var revoke = Button("Revoke", async () =>
                {
                    if (!await scope.Sheets.ConfirmAsync($"Sign out {session.DeviceName}?", "The device has to be paired again to use this server. Its playback stops now.", "Revoke", destructive: true)) return;
                    if (await scope.RunAsync(() => Client.RevokeDeviceAsync(session.Id), message)) await ReloadAsync();
                }, "destructive");
                AutomationProperties.SetName(revoke, "Revoke " + session.DeviceName);
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

    /// <summary>The Mac's DeviceApprovalView: enter the code, check the device's name, then approve or deny.</summary>
    private async Task ApproveDeviceAsync()
    {
        var problem = Message();
        var codeBox = new TextBox { PlaceholderText = "8-digit code shown on the Apple TV or in the browser", MaxLength = 9, Width = 380 };
        AutomationProperties.SetName(codeBox, "Device Code");
        var body = new StackPanel { Spacing = 14, Width = 420 };
        var footer = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = "Cancel", Classes = { "chip" }, IsCancel = true };
        cancel.Click += (_, _) => scope.Sheets.Close(false);
        var proceed = new Button { Content = "Continue", Classes = { "primary" }, IsDefault = true, IsEnabled = false };
        codeBox.TextChanged += (_, _) => proceed.IsEnabled = DeviceCode(codeBox.Text) is not null;
        proceed.Click += async (_, _) =>
        {
            if (DeviceCode(codeBox.Text) is not { } code) return;
            DeviceAuthorizationPreview? preview = null;
            proceed.IsEnabled = false;
            if (!await scope.RunAsync(async () => preview = await Client.LookUpDeviceAsync(code), problem) || preview is null)
            {
                proceed.IsEnabled = true;
                return;
            }
            if (preview.State != DeviceAuthorizationState.Pending)
            {
                problem.Text = "This pairing request is no longer pending.";
                problem.IsVisible = true;
                return;
            }
            body.Children.Clear();
            body.Children.Add(new TextBlock { Text = "Approve Apple TV or Browser", FontSize = 18, FontWeight = FontWeight.Bold });
            body.Children.Add(Value("Device", preview.DeviceName).Also(r => r.Margin = new Thickness(0)));
            body.Children.Add(Value("Server", preview.ServerName).Also(r => r.Margin = new Thickness(0)));
            body.Children.Add(Note("Only approve the device showing this code."));
            body.Children.Add(new TextBlock { Text = code, FontFamily = new FontFamily("monospace"), FontSize = 22, FontWeight = FontWeight.SemiBold });
            body.Children.Add(problem);
            var deny = new Button { Content = "Deny", Classes = { "destructive" } };
            var approve = new Button { Content = "Approve", Classes = { "primary" }, IsDefault = true };
            async Task Answer(bool yes)
            {
                deny.IsEnabled = approve.IsEnabled = false;
                if (await scope.RunAsync(() => Client.AnswerDeviceAsync(preview.Id, yes), problem)) scope.Sheets.Close(yes);
                deny.IsEnabled = approve.IsEnabled = true;
            }
            deny.Click += async (_, _) => await Answer(false);
            approve.Click += async (_, _) => await Answer(true);
            footer.Children.Clear();
            footer.Children.Add(cancel);
            footer.Children.Add(deny);
            footer.Children.Add(approve);
            body.Children.Add(footer);
        };
        footer.Children.Add(cancel);
        footer.Children.Add(proceed);
        body.Children.Add(new TextBlock { Text = "Approve Apple TV or Browser", FontSize = 18, FontWeight = FontWeight.Bold });
        body.Children.Add(codeBox);
        body.Children.Add(problem);
        body.Children.Add(footer);
        if (await scope.Sheets.ShowAsync(body)) await ReloadAsync();
    }

    /// <summary>Eight digits, ignoring spaces and a dash as the devices show them.</summary>
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
    private UserRole role;
    private ProfileAccessMode mode;
    private string query = "";

    public ProfileEditorSheet(AdminScope scope, ProfileEditorResponse? snapshot, IReadOnlyList<CatalogItemSummary> catalog)
    {
        this.scope = scope;
        this.snapshot = snapshot;
        this.catalog = [.. catalog.Where(item => item.Kind is MediaKind.Movie or MediaKind.Series).OrderBy(item => item.Title, StringComparer.CurrentCultureIgnoreCase)];
        selected = [.. snapshot?.Access.TitleIds ?? []];
        role = snapshot?.User.Role ?? UserRole.User;
        mode = snapshot?.Access.Mode ?? ProfileAccessMode.SelectedTitles;
        Width = 620;
        MaxHeight = 640;
        name.Text = snapshot?.User.Username;
        name.IsEnabled = snapshot is null;
        enabled.IsChecked = snapshot?.IsEnabled ?? true;
        pinProtected.IsChecked = snapshot?.User.PinProtectionEnabled ?? true;
        AutomationProperties.SetName(name, "Profile Name");
        AutomationProperties.SetName(pin, "New PIN");
        AutomationProperties.SetName(confirm, "Confirm PIN");
        pinProtected.IsCheckedChanged += (_, _) => ShowPin();
        var roles = new ComboBox { ItemsSource = new[] { "User", "Administrator", "Owner" }, SelectedIndex = role switch { UserRole.Admin => 1, UserRole.Owner => 2, _ => 0 }, MinWidth = 200 };
        roles.SelectionChanged += (_, _) =>
        {
            role = roles.SelectedIndex switch { 1 => UserRole.Admin, 2 => UserRole.Owner, _ => UserRole.User };
            if (role != UserRole.User) pinProtected.IsChecked = true;
            ShowPin();
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
        ShowAccess();
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
                        new TextBlock { Text = snapshot is null ? "Create Profile" : snapshot.User.Username, FontSize = 20, FontWeight = FontWeight.Bold },
                        Note("Choose who can watch and what they can see."),
                    },
                }.Also(p => DockPanel.SetDock(p, Dock.Top)),
                new ScrollViewer
                {
                    HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                    Content = new StackPanel
                    {
                        Spacing = 16,
                        Children =
                        {
                            Section("Profile",
                                Row("Name", null, name.Also(n => n.Width = 240)),
                                Row("Role", "Administrators manage their allowed content. Owners manage the whole server.", roles),
                                Row("Profile Enabled", null, enabled)),
                            Section("PIN Protection",
                                Row("Require a Profile PIN", null, pinProtected),
                                Block(pin, confirm, pinNote)),
                            Section("Content Access", Block(access)),
                        },
                    },
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

    private void ShowAccess()
    {
        access.Children.Clear();
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
        if (snapshot is null && string.IsNullOrWhiteSpace(name.Text)) failure = "Enter a name for the profile.";
        else if (newPin is not null && !ProfilePin.IsValid(newPin)) failure = "Use a PIN with four to eight digits.";
        else if (newPin is not null && newPin != confirm.Text) failure = "The PINs do not match.";
        if (failure is not null)
        {
            problem.Text = failure;
            problem.IsVisible = true;
            return;
        }
        var ids = selected.Order().ToList();
        var worked = await scope.RunAsync(async () =>
        {
            if (snapshot is not null)
            {
                var changedAccess = mode != snapshot.Access.Mode || !selected.SetEquals(snapshot.Access.TitleIds);
                await scope.Client.SaveProfileAsync(snapshot.User.Id, new UpdateProfileRequest(snapshot.Revision, role, enabled.IsChecked == true, protectedNow, newPin,
                    changedAccess ? mode : null, changedAccess ? ids : null));
            }
            else
            {
                await scope.Client.CreateProfileAsync(new CreateUserRequest(name.Text!.Trim(), null, role, newPin, protectedNow,
                    role == UserRole.Owner ? ProfileAccessMode.EntireLibrary : mode, role == UserRole.Owner ? [] : ids, enabled.IsChecked == true));
            }
        }, problem);
        pin.Text = confirm.Text = "";
        if (worked) scope.Sheets.Close(true);
    }
}
