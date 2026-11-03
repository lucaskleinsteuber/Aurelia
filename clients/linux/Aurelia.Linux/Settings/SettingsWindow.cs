using Aurelia.Contracts;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Platform;
using Aurelia.Linux.Core.Hosting;
using Aurelia.Linux.Core.Playback;
using Aurelia.Linux.Core.Settings;
using Aurelia.Linux.Core.Updates;
using Aurelia.Linux.Library;
using Aurelia.Linux.Management;
using Aurelia.Linux.Views;
using Avalonia.Threading;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using static Aurelia.Linux.Settings.SettingsRows;

namespace Aurelia.Linux.Settings;

public enum SettingsCategory
{
    General,
    Sidebar,
    Activity,
    Playback,
    Library,
    Metadata,
    ProfilesAndDevices,
    Server,
    Updates,
    Advanced,
}

/// <summary>
/// Aurelia's settings, as the Mac app's Settings window: a list of categories with a search field
/// and the chosen category beside it. Library and Metadata appear for owners and administrators,
/// Server only for the owner, whose requests alone the server accepts there.
/// </summary>
public sealed class SettingsWindow : Window
{
    private static readonly Dictionary<SettingsCategory, string[]> Keywords = new()
    {
        [SettingsCategory.General] = ["start", "screen", "poster", "size", "watched", "motion", "rest", "sleep", "server", "appearance"],
        [SettingsCategory.Sidebar] = ["sidebar", "order", "pages", "hide", "show", "reset"],
        [SettingsCategory.Activity] = ["history", "statistics", "watch time", "streak", "year"],
        [SettingsCategory.Playback] = ["resume", "next", "episode", "up next", "sleep", "night", "rate", "speed", "volume", "seek", "audio", "subtitle", "language", "track", "controls"],
        [SettingsCategory.Library] = ["storage", "location", "folder", "scan", "import", "health", "duplicate", "offline", "reset", "monitor"],
        [SettingsCategory.Metadata] = ["tmdb", "metadata", "artwork", "match", "review", "enrich", "token"],
        [SettingsCategory.ProfilesAndDevices] = ["profile", "pin", "lock", "switch", "device", "pair", "code", "apple tv", "browser", "revoke"],
        [SettingsCategory.Server] = ["server", "health", "backup", "restore", "power", "update", "restart", "diagnostics", "network", "limits", "scrub", "preview", "maintenance"],
        [SettingsCategory.Updates] = ["update", "version", "release"],
        [SettingsCategory.Advanced] = ["server", "address", "fingerprint", "connection", "disconnect", "pair"],
    };

    private readonly AppSession session;
    private readonly AppServices services;
    private readonly LibraryShell? shell;
    private readonly ListBox categories = new() { Classes = { "sidebar" } };
    private readonly ScrollViewer content = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    private readonly SheetHost sheets = new();
    private System.Action? detachUpdater;

    public Func<Task<bool>>? InstallUpdate { get; set; }

    public System.Action? QuitAfterUpdate { get; set; }

    private readonly TextBox search = new() { PlaceholderText = "Search settings…", Margin = new Thickness(12, 0, 12, 10) };

    public SettingsWindow(AppSession session, LibraryShell? shell, AppServices services, SettingsCategory category = SettingsCategory.General)
    {
        this.session = session;
        this.shell = shell;
        this.services = services;
        Closed += (_, _) => detachUpdater?.Invoke();
        Title = "Aurelia Settings";
        Width = 920;
        Height = 680;
        MinWidth = 840;
        MinHeight = 620;
        Background = Application.Current?.FindResource("AureliaCanvasBrush") as IBrush;
        if (OperatingSystem.IsLinux())
        {
            ExtendClientAreaToDecorationsHint = true;
            WindowDecorations = WindowDecorations.BorderOnly;
        }
        var chrome = new WindowChrome();
        chrome.Attach(this, services.ButtonLayout);
        AppWindowBehavior.Attach(this);
        AutomationProperties.SetName(search, "Search Settings");
        search.TextChanged += (_, _) => FillCategories();
        categories.SelectionChanged += (_, _) => ShowSelected();
        KeyBindings.Add(new KeyBinding { Gesture = new KeyGesture(Key.W, KeyModifiers.Control), Command = new RelayCommand(Close) });
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape && !sheets.IsShowing) Close();
        };
        var navigation = new Grid
        {
            Width = 230,
            HorizontalAlignment = HorizontalAlignment.Left,
            Background = new SolidColorBrush(Color.Parse("#1B1E21")),
            Children =
            {
                new DockPanel
                {
                    Children =
                    {
                        new StackPanel { Margin = new Thickness(0, 58, 0, 0), Children = { search } }.Also(p => DockPanel.SetDock(p, Dock.Top)),
                        categories,
                    },
                },
            },
        };
        Content = new Panel
        {
            Children =
            {
                new DockPanel { Children = { navigation.Also(n => DockPanel.SetDock(n, Dock.Left)), content } },
                chrome,
                sheets,
            },
        };
        FillCategories();
        Category = category;
    }

    public SettingsCategory Category
    {
        get => (categories.SelectedItem as ListBoxItem)?.Tag is SettingsCategory current ? current : SettingsCategory.General;
        set => categories.SelectedItem = categories.Items.OfType<ListBoxItem>().FirstOrDefault(item => (SettingsCategory)item.Tag! == value);
    }

    internal Control? Page => content.Content as Control;

    internal SheetHost Sheets => sheets;

    internal IReadOnlyList<SettingsCategory> VisibleCategories => [.. categories.Items.OfType<ListBoxItem>().Select(item => (SettingsCategory)item.Tag!)];

    public static string CategoryName(SettingsCategory category) => category switch
    {
        SettingsCategory.ProfilesAndDevices => "Profiles and Devices",
        _ => category.ToString(),
    };

    /// <summary>The categories whose name or keywords contain the search text.</summary>
    public static IReadOnlyList<SettingsCategory> Matching(string? text)
    {
        var query = (text ?? "").Trim();
        return [.. Enum.GetValues<SettingsCategory>().Where(category => query.Length == 0
            || CategoryName(category).Contains(query, StringComparison.CurrentCultureIgnoreCase)
            || Keywords[category].Any(keyword => keyword.Contains(query, StringComparison.CurrentCultureIgnoreCase)))];
    }

    private void FillCategories()
    {
        var selected = Category;
        categories.Items.Clear();
        foreach (var category in Matching(search.Text).Where(IsAvailable))
        {
            categories.Items.Add(new ListBoxItem { Content = CategoryName(category), Tag = category });
        }
        Category = selected;
        if (categories.SelectedItem is null && categories.Items.Count > 0) categories.SelectedIndex = 0;
    }

    private void ShowSelected()
    {
        detachUpdater?.Invoke();
        detachUpdater = null;
        if (categories.SelectedItem is not ListBoxItem { Tag: SettingsCategory category }) return;
        var page = new StackPanel { Spacing = 22, Margin = new Thickness(36, 58, 36, 40), MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Left };
        page.Children.Add(PageTitle(CategoryName(category)));
        switch (category)
        {
            case SettingsCategory.General: General(page); break;
            case SettingsCategory.Sidebar: Sidebar(page); break;
            case SettingsCategory.Activity: Activity(page); break;
            case SettingsCategory.Playback: Playback(page); break;
            case SettingsCategory.Library: page.Children.Add(new LibraryPage(Admin(), Prefs, Refresh)); break;
            case SettingsCategory.Metadata: page.Children.Add(new MetadataPage(Admin())); break;
            case SettingsCategory.ProfilesAndDevices: Profiles(page); break;
            case SettingsCategory.Server: page.Children.Add(new ServerPage(Admin(), session.Server is { LocallyManaged: true } ? LocalHosting() : null)); break;
            case SettingsCategory.Updates: Updates(page); break;
            default: Advanced(page); break;
        }
        content.Content = page;
    }

    private GeneralPreferences Prefs => session.Preferences;

    private AdminScope? admin;

    /// <summary>One management scope per window, so the Server Password prompt opens over this window.</summary>
    private AdminScope Admin() => admin ??= new AdminScope(session, sheets);

    /// <summary>Like the Mac: Library for those who manage storage, Metadata for administrators, Server for the owner.</summary>
    internal bool IsAvailable(SettingsCategory category) => IsAvailable(category, session.Library is null ? null : session.Profile?.User);

    /// <param name="user">The open profile, or null while no library is open.</param>
    public static bool IsAvailable(SettingsCategory category, UserSummary? user)
    {
        var manages = user?.Role is UserRole.Owner or UserRole.Admin;
        return category switch
        {
            SettingsCategory.Library => manages && (user!.Role == UserRole.Owner || user.AccessMode != ProfileAccessMode.SelectedTitles),
            SettingsCategory.Metadata => manages,
            SettingsCategory.Server => manages && user!.Role == UserRole.Owner,
            _ => true,
        };
    }

    /// <summary>Raised when the hosting choices change, so the window updates its icon and keep-awake lock.</summary>
    public event Action? HostingChanged;

    /// <summary>The Mac's "When the Server Runs" for the server this computer hosts.</summary>
    private StackPanel LocalHosting()
    {
        var current = HostingSettings.Read(Prefs.Store);
        var hosting = services.HostingSystem;
        DockPanel? login = null;
        StackPanel? section = null;
        var problem = AdminScope.Message();
        async void Save(HostingPreferences updated)
        {
            if (section is not null) section.IsEnabled = false;
            problem.IsVisible = false;
            try
            {
                updated = updated with { StartAtSignIn = updated.KeepRunning && updated.StartAtSignIn };
                if (hosting is not null && (updated.KeepRunning != current.KeepRunning || updated.StartAtSignIn != current.StartAtSignIn))
                    await hosting.ConfigureBackgroundAsync(updated.KeepRunning, updated.StartAtSignIn);
                current = updated;
                HostingSettings.Write(Prefs.Store, current);
            }
            catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or InvalidOperationException or Tmds.DBus.Protocol.DBusExceptionBase)
            {
                problem.Text = failure.Message;
                problem.IsVisible = true;
                // Rebuild from saved values after a denied desktop permission request.
                ShowSelected();
                if (content.Content is StackPanel page)
                {
                    var failureMessage = AdminScope.Message();
                    failureMessage.Text = failure.Message;
                    failureMessage.IsVisible = true;
                    page.Children.Add(failureMessage);
                }
                return;
            }
            finally
            {
                if (section is not null) section.IsEnabled = true;
            }
            if (login is not null)
            {
                login.IsEnabled = current.KeepRunning;
                if (!current.KeepRunning && login.Children.OfType<ToggleSwitch>().FirstOrDefault() is { IsChecked: true } toggle) toggle.IsChecked = false;
            }
            HostingChanged?.Invoke();
        }
        login = Toggle("Start Automatically When You Log In", "Aurelia starts in the background and keeps the server running.", current.StartAtSignIn, value => Save(current with { StartAtSignIn = value }));
        login.IsEnabled = current.KeepRunning;
        var rows = new List<Control>
        {
            Choice("Run the Server", null, [(false, "Only while Aurelia is open"), (true, "Also when Aurelia is closed")], current.KeepRunning,
                value => Save(current with { KeepRunning = value })),
            login,
            Toggle("Keep This PC Awake While the Server Runs", null, current.KeepAwake, value => Save(current with { KeepAwake = value })),
        };
        var notes = new StackPanel { Spacing = 6, Margin = new Thickness(16, 8) };
        notes.Children.Add(AdminScope.Note("The server can't be reached while this PC is asleep or turned off. Open Aurelia from the application launcher to return to its window. A notification-area icon is also shown where the desktop supports it."));
        if (HostingSettings.FirewallHint(session.Server!.Address.Port) is { } hint) notes.Children.Add(new SelectableTextBlock { Text = hint, Classes = { "subdued" }, FontSize = 12, TextWrapping = TextWrapping.Wrap });
        rows.Add(notes);
        rows.Add(problem);
        return section = Section("When the Server Runs", [.. rows]);
    }

    private void General(StackPanel page)
    {
        var prefs = Prefs;
        page.Children.Add(Section("Library",
            Choice("Default Start Screen", "The page Aurelia opens with.",
                [("lastScreen", "Last Screen Used"), ("home", "Home"), ("library", "Library"), ("movies", "Movies"), ("series", "TV Shows"), ("collections", "Collections"), ("watchlist", "Watchlist"), ("recentlyAdded", "Recently Added")],
                prefs.StartScreen, value => prefs.StartScreen = value),
            Choice("Poster Size", null, [(PosterSize.Compact, "Compact"), (PosterSize.Standard, "Standard"), (PosterSize.Large, "Large")],
                prefs.PosterSize, value => { prefs.PosterSize = value; Refresh(); }),
            Toggle("Show Watched Titles in Rows", "Rows on Home also list titles you finished.", prefs.ShowWatchedInRows, value => { prefs.ShowWatchedInRows = value; Refresh(); }),
            Row("Sidebar", "Choose the sidebar's pages and their order.", Action("Configure Sidebar…", () => Category = SettingsCategory.Sidebar))));
        page.Children.Add(Section("Motion and Appearance",
            Toggle("Reduce Motion", "Fewer animations when pages change.", prefs.ReduceMotion, value => prefs.ReduceMotion = value),
            Value("Appearance", "Dark Cinema")));
        var minutes = Choice("Rest After", null, [.. GeneralPreferences.RestMinuteChoices.Select(m => (m, $"{m} Minutes"))], prefs.RestMinutes, value => prefs.RestMinutes = value);
        minutes.IsEnabled = prefs.RestsWhenUnused;
        page.Children.Add(Section("Server",
            Toggle("Let the Server Rest When Unused",
                "When nothing plays and nobody uses Aurelia, it lets go of a server on another computer so the server can save power.",
                prefs.RestsWhenUnused, value => { prefs.RestsWhenUnused = value; minutes.IsEnabled = value; }),
            minutes));
    }

    private void Sidebar(StackPanel page)
    {
        var prefs = Prefs;
        var layout = prefs.Sidebar();
        var rows = new List<Control>
        {
            Choice("Startup Screen", null,
                [("lastScreen", "Last Screen Used"), ("home", "Home"), ("library", "Library"), ("movies", "Movies"), ("series", "TV Shows"), ("collections", "Collections"), ("watchlist", "Watchlist"), ("recentlyAdded", "Recently Added")],
                prefs.StartScreen, value => prefs.StartScreen = value),
        };
        var order = layout.Order.ToList();
        for (var index = 0; index < order.Count; index++)
        {
            var destination = order[index];
            var position = index;
            var visible = !layout.Hidden.Contains(destination);
            var up = new Button { Content = "▲", Classes = { "link" }, IsEnabled = position > 0 };
            var down = new Button { Content = "▼", Classes = { "link" }, IsEnabled = position < order.Count - 1 };
            AutomationProperties.SetName(up, "Move Up, " + destination.Title());
            AutomationProperties.SetName(down, "Move Down, " + destination.Title());
            var show = new ToggleSwitch { IsChecked = visible, OnContent = "", OffContent = "" };
            AutomationProperties.SetName(show, "Show " + destination.Title());
            up.Click += (_, _) => SaveSidebar(Move(order, position, -1), layout.Hidden);
            down.Click += (_, _) => SaveSidebar(Move(order, position, 1), layout.Hidden);
            show.IsCheckedChanged += (_, _) =>
            {
                var hidden = new HashSet<LibraryDestination>(layout.Hidden);
                if (show.IsChecked == true) hidden.Remove(destination);
                else hidden.Add(destination);
                // At least one page stays in the sidebar.
                if (order.All(hidden.Contains))
                {
                    show.IsChecked = true;
                    return;
                }
                SaveSidebar(order, hidden);
            };
            rows.Add(new DockPanel
            {
                Margin = new Thickness(16, 6),
                Children =
                {
                    new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Children = { up, down, show } }.Also(p => DockPanel.SetDock(p, Dock.Right)),
                    new StackPanel
                    {
                        Orientation = Orientation.Horizontal,
                        Spacing = 12,
                        Children =
                        {
                            new PathIcon { Data = Application.Current?.FindResource("Icon" + destination) as Geometry, Width = 18, Height = 18, Foreground = Application.Current?.FindResource("AureliaAccentBrush") as IBrush },
                            new TextBlock { Text = destination.Title(), VerticalAlignment = VerticalAlignment.Center },
                        },
                    },
                },
            });
        }
        page.Children.Add(Section(null, [.. rows]));
        page.Children.Add(Action("Reset Sidebar to Defaults", () =>
        {
            prefs.ResetSidebar();
            shell?.ReloadSidebar();
            ShowSelected();
        }));
    }

    private static List<LibraryDestination> Move(List<LibraryDestination> order, int index, int by)
    {
        var moved = order.ToList();
        var target = Math.Clamp(index + by, 0, moved.Count - 1);
        (moved[index], moved[target]) = (moved[target], moved[index]);
        return moved;
    }

    private void SaveSidebar(IReadOnlyList<LibraryDestination> order, IReadOnlySet<LibraryDestination> hidden)
    {
        Prefs.SaveSidebar(new SidebarLayout(order, hidden));
        shell?.ReloadSidebar();
        ShowSelected();
    }

    private void Activity(StackPanel page)
    {
        if (session.Library is not { } library)
        {
            page.Children.Add(new TextBlock { Text = "Open a profile to see its activity.", Classes = { "subdued" } });
            return;
        }
        var prefs = Prefs;
        var statistics = new ToggleButton { Content = "Statistics", Classes = { "chip" }, IsChecked = prefs.ActivityPage == "statistics" };
        var history = new ToggleButton { Content = "History", Classes = { "chip" }, IsChecked = prefs.ActivityPage == "history" };
        statistics.Click += (_, _) => { prefs.ActivityPage = "statistics"; ShowSelected(); };
        history.Click += (_, _) => { prefs.ActivityPage = "history"; ShowSelected(); };
        page.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { statistics, history } });
        var context = new LibraryContext(library, new SettingsNavigator(sheets));
        LibraryPageBase activity = prefs.ActivityPage == "history" ? new HistoryPage(context, showsTitle: false) : new StatisticsPage(context, showsTitle: false);
        activity.SidebarOverlap = -32;
        activity.Margin = new Thickness(-36, -16, -36, 0);
        page.Children.Add(activity);
    }

    private void Playback(StackPanel page)
    {
        var current = PlaybackPreferences.Load(Prefs.Store);
        void Save(PlaybackPreferences updated) => updated.Save(Prefs.Store);
        page.Children.Add(Section("Playing",
            Toggle("Automatic Resume", "Continue where you stopped.", current.AutomaticResume, value => Save(PlaybackPreferences.Load(Prefs.Store) with { AutomaticResume = value })),
            Choice("Start Over If Barely Started", null, [(0, "Never"), (30, "First 30 Seconds"), (60, "First Minute"), (120, "First 2 Minutes")],
                current.ResumeThresholdSeconds, value => Save(PlaybackPreferences.Load(Prefs.Store) with { ResumeThresholdSeconds = value })),
            Toggle("Automatically Play Next Episode", null, current.AutoplayNextEpisode, value => Save(PlaybackPreferences.Load(Prefs.Store) with { AutoplayNextEpisode = value })),
            Choice("Up Next Countdown", null, [.. PlaybackPreferences.Countdowns.Select(s => (s, $"{s} Seconds"))],
                current.UpNextCountdownSeconds, value => Save(PlaybackPreferences.Load(Prefs.Store) with { UpNextCountdownSeconds = value })),
            Toggle("Prevent Sleep During Playback", "The screen stays on while a title plays.", current.PreventSleep, value => Save(PlaybackPreferences.Load(Prefs.Store) with { PreventSleep = value }))));
        var volume = new Slider { Minimum = 0, Maximum = 1, Value = current.DefaultVolume, Width = 200 };
        volume.PropertyChanged += (_, e) =>
        {
            if (e.Property == RangeBase.ValueProperty) Save(PlaybackPreferences.Load(Prefs.Store) with { DefaultVolume = volume.Value });
        };
        var seek = new NumericUpDown { Minimum = 5, Maximum = 60, Increment = 5, Value = current.SeekIntervalSeconds, Width = 140, FormatString = "0 s" };
        seek.ValueChanged += (_, _) => Save(PlaybackPreferences.Load(Prefs.Store) with { SeekIntervalSeconds = (int)(seek.Value ?? 10) });
        page.Children.Add(Section("Sound and Controls",
            Choice("Dialogue Boost", "Emphasize speech locally.", [.. Enum.GetValues<DialogueBoost>().Select(value => (value, value.ToString()))],
                current.DialogueBoost, value => Save(PlaybackPreferences.Load(Prefs.Store) with { DialogueBoost = value })),
            Choice("Volume Leveling", "Reduce loud/quiet differences; Sleep applies stronger leveling.", [.. Enum.GetValues<VolumeLeveling>().Select(value => (value, value.ToString()))],
                current.EffectiveLeveling, value => Save(PlaybackPreferences.Load(Prefs.Store) with { VolumeLeveling = value, NightMode = value != VolumeLeveling.Off })),
            Choice("Default Playback Rate", null, [.. PlayerPolicy.Rates.Select(r => (r, r == 1 ? "Standard" : r.ToString("0.##", System.Globalization.CultureInfo.InvariantCulture) + "×"))],
                current.DefaultRate, value => Save(PlaybackPreferences.Load(Prefs.Store) with { DefaultRate = value })),
            Row("Default Volume", null, volume),
            Choice("Hide Controls After", null, [.. PlaybackPreferences.HideDelays.Select(s => (s, $"{s} Seconds"))],
                current.ControlsHideDelaySeconds, value => Save(PlaybackPreferences.Load(Prefs.Store) with { ControlsHideDelaySeconds = value })),
            Row("Seek Interval", "How far the arrow keys and skip buttons jump.", seek)));
        var languages = new List<(string, string)> { ("en", "English"), ("de", "German"), ("fr", "French"), ("es", "Spanish"), ("it", "Italian"), ("ja", "Japanese") };
        page.Children.Add(Section("Languages",
            Choice("Default Audio Language", null, [("original", "Original"), .. languages], current.DefaultAudioLanguage,
                value => Save(PlaybackPreferences.Load(Prefs.Store) with { DefaultAudioLanguage = value })),
            Choice("Default Subtitle Language", null, [("off", "File Default"), .. languages], current.DefaultSubtitleLanguage,
                value => Save(PlaybackPreferences.Load(Prefs.Store) with { DefaultSubtitleLanguage = value }))));
        page.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 10,
            Children =
            {
                Action("Forget Track Choices", () =>
                {
                    if (session.Profile is { } profile) new TrackMemory(Prefs.Store, profile.User.Id).Forget();
                }),
                Action("Restore Playback Defaults", () =>
                {
                    new PlaybackPreferences().Save(Prefs.Store);
                    ShowSelected();
                }),
            },
        });
    }

    private void Profiles(StackPanel page)
    {
        if (session.Profile is not { } profile || session.Server is not { } server)
        {
            page.Children.Add(new TextBlock { Text = "No profile is open.", Classes = { "subdued" } });
            return;
        }
        var role = profile.User.Role switch { UserRole.Owner => "Owner", UserRole.Admin => "Administrator", _ => "Profile" };
        page.Children.Add(Section("Current Profile", new DockPanel
        {
            Margin = new Thickness(16, 12),
            Children =
            {
                Action("Switch Profile", () => { Close(); _ = session.SwitchProfileAsync(); }).Also(b => DockPanel.SetDock(b, Dock.Right)),
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 12,
                    Children =
                    {
                        new ProfileAvatar(profile.User.Id, profile.User.Username, 44),
                        new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children = { new TextBlock { Text = profile.User.Username, FontWeight = FontWeight.SemiBold }, new TextBlock { Text = role, Classes = { "subdued" } } } },
                    },
                },
            },
        }));
        var mandatory = profile.User.Role is UserRole.Owner or UserRole.Admin;
        var protectedNow = mandatory || profile.User.PinProtectionEnabled;
        var currentPin = new TextBox { PasswordChar = '•', PlaceholderText = "Current PIN", MaxLength = 8, Width = 220, IsVisible = protectedNow };
        var newPin = new TextBox { PasswordChar = '•', PlaceholderText = "New PIN (4–8 digits)", MaxLength = 8, Width = 220 };
        var confirm = new TextBox { PasswordChar = '•', PlaceholderText = "Confirm New PIN", MaxLength = 8, Width = 220 };
        AutomationProperties.SetName(currentPin, "Current PIN");
        AutomationProperties.SetName(newPin, "New PIN");
        AutomationProperties.SetName(confirm, "Confirm New PIN");
        var problem = new TextBlock { Foreground = new SolidColorBrush(Color.Parse("#FF8A8A")), IsVisible = false, TextWrapping = TextWrapping.Wrap };
        async Task Apply(bool enabled)
        {
            problem.IsVisible = false;
            if (enabled && (!ProfilePin.IsValid(newPin.Text) || newPin.Text != confirm.Text))
            {
                problem.Text = !ProfilePin.IsValid(newPin.Text) ? "Enter a new PIN with four to eight digits." : "The new PINs do not match.";
                problem.IsVisible = true;
                return;
            }
            try
            {
                await session.Api.UpdateOwnPinAsync(server, profile, new UpdateOwnPinProtectionRequest(enabled,
                    protectedNow ? currentPin.Text : null, enabled ? newPin.Text : null), CancellationToken.None);
                // Like the Mac app, a PIN change locks the profile: it opens again with the new PIN.
                Close();
                await session.SwitchProfileAsync();
            }
            catch (AureliaApiException failure)
            {
                problem.Text = failure.Code == "invalid_profile_pin" ? "The current PIN is not correct." : failure.Message;
                problem.IsVisible = true;
            }
        }
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        var apply = new Button { Content = protectedNow ? "Change PIN & Lock Profile" : "Enable PIN & Lock Profile", Classes = { "primary" } };
        apply.Click += async (_, _) => await Apply(true);
        actions.Children.Add(apply);
        if (protectedNow && !mandatory)
        {
            var remove = new Button { Content = "Remove PIN Protection", Classes = { "chip" } };
            remove.Click += async (_, _) => await Apply(false);
            actions.Children.Add(remove);
        }
        page.Children.Add(Section("PIN", new StackPanel
        {
            Spacing = 10,
            Margin = new Thickness(16, 12),
            Children =
            {
                new TextBlock
                {
                    Text = mandatory ? "Owner and administrator profiles always need a PIN." : "A PIN keeps others from opening this profile.",
                    Classes = { "subdued" },
                    TextWrapping = TextWrapping.Wrap,
                },
                currentPin,
                newPin,
                confirm,
                problem,
                actions,
            },
        }));
        if (profile.User.Role == UserRole.Owner && session.Library is not null) page.Children.Add(new PeoplePage(Admin()));
    }

    private void Updates(StackPanel page)
    {
        page.Children.Add(Section(null,
            Value("Installed Version", AppInfo.DisplayVersion),
            Toggle("Check for Updates Automatically", "Once a day, Aurelia looks for a newer version.",
                Prefs.Store.Read<bool?>("automaticUpdateChecks") ?? true, value => Prefs.Store.Write("automaticUpdateChecks", value))));
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap, Classes = { "subdued" } };
        var notes = new TextBlock { TextWrapping = TextWrapping.Wrap, MaxHeight = 220 };
        var check = new Button { Content = "Check for Updates", Classes = { "chip" } };
        var install = new Button { Content = "Download & Install…", Classes = { "primary" }, IsVisible = false };
        if (services.Updater is { } updater)
        {
            void RefreshUpdate()
            {
                status.Text = updater.Status;
                notes.Text = updater.Available?.Notes;
                notes.IsVisible = !string.IsNullOrWhiteSpace(notes.Text);
                check.IsEnabled = !updater.IsBusy && !updater.RestartRequired;
                install.IsEnabled = !updater.IsBusy;
                install.IsVisible = updater.Available is not null || updater.RestartRequired;
                install.Content = updater.RestartRequired ? "Quit Aurelia" : "Download & Install…";
            }
            System.ComponentModel.PropertyChangedEventHandler changed = (_, _) => Dispatcher.UIThread.Post(RefreshUpdate);
            updater.PropertyChanged += changed;
            detachUpdater = () => updater.PropertyChanged -= changed;
            RefreshUpdate();
            check.Click += async (_, _) => await updater.CheckAsync(userInitiated: true);
            install.Click += async (_, _) =>
            {
                if (updater.RestartRequired) { QuitAfterUpdate?.Invoke(); return; }
                if (updater.Available is not { } release || !await sheets.ConfirmAsync("Install Aurelia " + release.Version + "?",
                    "Aurelia downloads the package and checks its SHA-256 checksum. Your package manager then asks for authorization. Playback and this computer's server stop before installation; your library and settings stay. Quit and reopen Aurelia afterwards.", "Install Update", false)) return;
                if (InstallUpdate is { } action) await action();
                else await updater.InstallAsync();
            };
        }
        else
        {
            status.Text = "Updates are unavailable in this test session.";
            check.IsEnabled = false;
        }
        page.Children.Add(status);
        page.Children.Add(notes);
        page.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { check, install } });
        if (services.Updater is { } betaUpdater)
        {
            var beta = Toggle("Beta updates", "Get test versions before everyone else. They may have bugs. Turn this off to stay on the stable version from the next stable release on.",
                betaUpdater.BetaUpdatesEnabled, value => { betaUpdater.SetBetaUpdates(value); ShowSelected(); });
            beta.IsEnabled = !betaUpdater.IsBusy && !betaUpdater.RestartRequired;
            page.Children.Add(Section("Beta", beta));
        }
        if (services.Updater is { } feedUpdater)
        {
            var source = Toggle("Public Update Test", "Use Aurelia’s temporary public test feed without reading your saved GitHub token.",
                feedUpdater.PublicUpdateTestEnabled, value => { feedUpdater.SetPublicUpdateTest(value); ShowSelected(); });
            source.IsEnabled = !feedUpdater.IsBusy && !feedUpdater.RestartRequired;
            page.Children.Add(Section("Advanced", source));
        }
        if (services.UpdateTokens is { } tokens && services.Updater?.PublicUpdateTestEnabled != true)
        {
            var token = new TextBox { PasswordChar = '•', PlaceholderText = "GitHub token", MinWidth = 250 };
            AutomationProperties.SetName(token, "GitHub Update Token");
            var message = new TextBlock { TextWrapping = TextWrapping.Wrap, Classes = { "subdued" } };
            var save = new Button { Content = "Save Token", Classes = { "chip" } };
            var remove = new Button { Content = "Remove Token", Classes = { "chip" } };
            save.Click += async (_, _) =>
            {
                if (string.IsNullOrWhiteSpace(token.Text)) { message.Text = "Enter a token first."; return; }
                try
                {
                    await tokens.SaveAsync(token.Text.Trim(), CancellationToken.None);
                    token.Text = "";
                    message.Text = "The token is saved in your desktop keyring.";
                }
                catch (CredentialStoreUnavailableException error) { message.Text = error.Message; }
            };
            remove.Click += async (_, _) =>
            {
                try { await tokens.DeleteAsync(CancellationToken.None); message.Text = "The saved token was removed."; }
                catch (CredentialStoreUnavailableException error) { message.Text = error.Message; }
            };
            page.Children.Add(Section("GitHub Access", new StackPanel
            {
                Spacing = 10,
                Margin = new Thickness(16, 12),
                Children =
                {
                    new TextBlock { Text = $"For a private repository, use a fine-grained GitHub token with Contents: Read-only access to {AppRelease.Repository}. It stays in your desktop keyring and is sent only to GitHub's API.", TextWrapping = TextWrapping.Wrap, Classes = { "subdued" } },
                    token, new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { save, remove } }, message,
                },
            }));
        }
    }

    private void Advanced(StackPanel page)
    {
        if (session.Server is not { } server)
        {
            page.Children.Add(new TextBlock { Text = "Aurelia is not connected to a server.", Classes = { "subdued" } });
            return;
        }
        page.Children.Add(Section("Server Connection",
            Value("Server", server.Name),
            Value("Address", server.Address.Authority),
            Value("Fingerprint", ServerIdentity.Display(server.Fingerprint)),
            Value("Signed In", session.Profile?.User.Username ?? "Paired Device")));
        var disconnect = new Button { Content = "Disconnect This PC…", Classes = { "destructive" } };
        disconnect.Click += async (_, _) =>
        {
            if (!await sheets.ConfirmAsync("Disconnect this PC?", $"Aurelia forgets {server.Name} on this computer and removes the pairing on the server. Connect again with a new pairing code.", "Disconnect", destructive: true)) return;
            Close();
            await session.DisconnectAsync();
        };
        page.Children.Add(disconnect);
    }

    private void Refresh() => shell?.RebuildPages();

    /// <summary>Activity inside Settings stays in Settings; titles are opened from the library pages.</summary>
    private sealed class SettingsNavigator(SheetHost sheets) : ILibraryNavigator
    {
        public RemotePlayback? Remote => null;

        public void OpenDetail(CatalogItemSummary item)
        {
        }

        public void OpenCollection(CollectionSummary collection)
        {
        }

        public void OpenPerson(string name, string? personKey)
        {
        }

        public void Back()
        {
        }

        public void Play(CatalogItemSummary item, bool fromLastPosition)
        {
        }

        public void EditCollection(CollectionSummary? collection, CatalogItemSummary? preselected)
        {
        }

        public Task<bool> ConfirmAsync(string title, string message, string confirmLabel, bool destructive) =>
            sheets.ConfirmAsync(title, message, confirmLabel, destructive);
    }
}
