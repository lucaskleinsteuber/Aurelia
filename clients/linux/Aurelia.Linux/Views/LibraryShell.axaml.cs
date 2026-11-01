using System.ComponentModel;
using Aurelia.Contracts;
using Aurelia.Linux.Controls;
using Aurelia.Linux.Core;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Playback;
using Aurelia.Linux.Library;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Chrome;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Views;

/// <summary>A row in the sidebar.</summary>
public sealed record SidebarItem(LibraryDestination Destination, string Title, Geometry? Icon);

/// <summary>
/// The window's frame: the blurred sidebar with the library pages, and the page beside it. Pages
/// stay full height beneath the sidebar, like the Mac app's. Each sidebar page stays alive while
/// another is shown, so its scroll position and artwork stay; detail pages open over it and Back
/// (or Alt+Left) returns.
/// </summary>
public sealed partial class LibraryShell : UserControl, ILibraryNavigator
{
    public const double MinimumSidebarWidth = 210;
    public const double MaximumSidebarWidth = 300;

    private readonly Dictionary<LibraryDestination, LibraryPageBase> pages = [];
    private readonly List<LibraryPageBase> details = [];
    private double sidebarWidth;
    private double? resizeStartWidth;
    private double resizeStartX;
    private bool sidebarVisible = true;
    private double leadingInset;
    private AppSession? session;
    private LibraryContext? context;
    private bool restoring;
    private RemotePlayback? remote;

    public LibraryShell()
    {
        InitializeComponent();
        SidebarBackdrop.Source = PageLayer;
        sidebarWidth = Sidebar.Width;
        BuildSidebar(SidebarLayout.Default, supportsWatchlist: true);
        SidebarList.SelectionChanged += (_, _) =>
        {
            if (restoring) return;
            details.Clear();
            ShowCurrentPage();
            if (context is { } open)
                open.Store.Preferences.SaveLastDestination(open.Store.Client.Server.ServerId, open.Store.Client.Profile.User.Id, Destination);
            if (Destination == LibraryDestination.Home && context is { } current) _ = current.Store.RefreshHomeAsync();
        };
        SidebarToggle.Click += (_, _) => SidebarVisible = !SidebarVisible;
        SettingsButton.Click += (_, _) => SettingsRequested?.Invoke();
        ProfileButton.Click += async (_, _) =>
        {
            if (session is not null) await session.SwitchProfileAsync();
        };
        WindowDecorationProperties.SetElementRole(SidebarToggle, WindowDecorationsElementRole.User);
        SidebarResizeHandle.PointerPressed += (_, e) =>
        {
            resizeStartWidth = sidebarWidth;
            resizeStartX = e.GetPosition(this).X;
            e.Pointer.Capture(SidebarResizeHandle);
            e.Handled = true;
        };
        SidebarResizeHandle.PointerMoved += (_, e) =>
        {
            if (resizeStartWidth is { } start) SidebarWidth = start + e.GetPosition(this).X - resizeStartX;
        };
        SidebarResizeHandle.PointerReleased += (_, e) =>
        {
            resizeStartWidth = null;
            e.Pointer.Capture(null);
        };
        ErrorDismiss.Click += (_, _) => context?.Store.ClearError();
        ErrorRetry.Click += async (_, _) =>
        {
            if (context is null) return;
            context.Store.ClearError();
            await context.Store.RefreshAsync();
        };
        KeyDown += OnKeyDown;
        RemoteBack.Click += (_, _) => _ = remote?.SendAsync("skip", -10);
        RemoteForward.Click += (_, _) => _ = remote?.SendAsync("skip", 10);
        RemotePlayPause.Click += (_, _) => _ = remote?.SendAsync(remote.Device?.IsPaused == true ? "resume" : "pause");
        RemoteStop.Click += (_, _) => _ = remote?.SendAsync("stop");
        SidebarList.SelectedIndex = 0;
        ShowCurrentPage();
        UpdateSidebarLayout();
    }

    internal IReadOnlyList<SidebarItem> SidebarItems => (IReadOnlyList<SidebarItem>)SidebarList.ItemsSource!;

    public LibraryDestination Destination
    {
        get => (SidebarList.SelectedItem as SidebarItem)?.Destination ?? LibraryDestination.Home;
        set => SidebarList.SelectedItem = SidebarItems.FirstOrDefault(item => item.Destination == value);
    }

    public double SidebarWidth
    {
        get => sidebarWidth;
        set
        {
            sidebarWidth = Math.Clamp(value, MinimumSidebarWidth, MaximumSidebarWidth);
            Sidebar.Width = sidebarWidth;
            UpdateSidebarLayout();
        }
    }

    public bool SidebarVisible
    {
        get => sidebarVisible;
        set
        {
            if (sidebarVisible == value) return;
            sidebarVisible = value;
            UpdateSidebarLayout();
        }
    }

    /// <summary>Room taken by window buttons at the left edge; the sidebar toggle sits beside them while the sidebar is hidden.</summary>
    public double LeadingInset
    {
        get => leadingInset;
        set
        {
            leadingInset = value;
            UpdateSidebarLayout();
        }
    }

    /// <summary>The connection whose profile shows at the foot of the sidebar and whose library the pages show.</summary>
    public AppSession? Session
    {
        get => session;
        set
        {
            if (session is not null) session.PropertyChanged -= OnSessionChanged;
            session = value;
            if (session is not null) session.PropertyChanged += OnSessionChanged;
            ShowProfile();
            AttachLibrary(session?.Library);
        }
    }

    /// <summary>The page shown now: the open detail page, or the sidebar page.</summary>
    internal LibraryPageBase? CurrentPage => PageHost.Content as LibraryPageBase;

    internal SheetHost SheetHost => Sheets;

    public RemotePlayback? Remote => remote;

    /// <summary>Shows the remote control while another device plays a title sent from here.</summary>
    public void AttachRemote(RemotePlayback playback)
    {
        if (remote is not null) remote.PropertyChanged -= OnRemoteChanged;
        remote = playback;
        remote.PropertyChanged += OnRemoteChanged;
        UpdateRemote();
    }

    private void OnRemoteChanged(object? sender, PropertyChangedEventArgs e) => UpdateRemote();

    private void UpdateRemote()
    {
        var device = remote?.Device;
        RemoteBar.IsVisible = device is not null;
        if (device is null) return;
        RemoteDevice.Text = "Playing on " + device.DeviceName;
        RemoteTitle.Text = device.Title ?? "";
        RemotePlayPauseIcon.Data = Icon(device.IsPaused ? "IconPlay" : "IconPause");
    }

    internal int DetailDepth => details.Count;

    public void OpenDetail(CatalogItemSummary item)
    {
        if (context is null) return;
        Push(new DetailPage(context, item));
    }

    public void OpenCollection(CollectionSummary collection)
    {
        if (context is null) return;
        Push(new CollectionDetailPage(context, collection));
    }

    public void OpenPerson(string name, string? personKey)
    {
        if (context is null) return;
        Push(new PersonPage(context, name, personKey));
    }

    public void Back()
    {
        if (details.Count == 0) return;
        details.RemoveAt(details.Count - 1);
        ShowCurrentPage();
    }

    /// <summary>Raised by the gear next to the profile; the window opens Settings.</summary>
    public event Action? SettingsRequested;

    /// <summary>Lists the keyboard shortcuts, as the Mac app's Keyboard Shortcuts sheet.</summary>
    public void ShowShortcuts()
    {
        var rows = new (string Keys, string Action)[]
        {
            ("Ctrl+F", "Search the library"), ("F9", "Show or hide the sidebar"), ("Alt+Left, Esc", "Back from a title"),
            ("Ctrl+,", "Settings"), ("F11", "Full screen"), ("Ctrl+Q", "Quit"),
            ("Space", "Play or pause"), ("Left / Right", "Seek back or forward"), ("M", "Mute"), ("F", "Full screen in the player"),
            ("P / N", "Previous or next episode"), ("Esc", "Leave full screen, then close the player"),
        };
        var list = new StackPanel { Spacing = 6, Width = 440 };
        list.Children.Add(new TextBlock { Text = "Keyboard Shortcuts", FontSize = 18, FontWeight = FontWeight.Bold, Margin = new Thickness(0, 0, 0, 6) });
        foreach (var (keys, action) in rows)
        {
            list.Children.Add(new DockPanel
            {
                Children =
                {
                    new TextBlock { Text = keys, FontWeight = FontWeight.SemiBold, Width = 140 }.Also(t => DockPanel.SetDock(t, Dock.Left)),
                    new TextBlock { Text = action, Classes = { "subdued" } },
                },
            });
        }
        var done = new Button { Content = "Done", Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0), IsDefault = true };
        done.Click += (_, _) => Sheets.Close(true);
        list.Children.Add(done);
        _ = Sheets.ShowAsync(list);
    }

    /// <summary>Raised when a page asks to play a title; the window opens the player.</summary>
    public event Action<CatalogItemSummary, bool>? PlayRequested;

    public void Play(CatalogItemSummary item, bool fromLastPosition) => PlayRequested?.Invoke(item, fromLastPosition);

    public void EditCollection(CollectionSummary? collection, CatalogItemSummary? preselected)
    {
        if (context is null) return;
        _ = Sheets.ShowAsync(new CollectionEditorSheet(context, Sheets, collection, preselected));
    }

    public Task<bool> ConfirmAsync(string title, string message, string confirmLabel, bool destructive) =>
        Sheets.ConfirmAsync(title, message, confirmLabel, destructive);

    /// <summary>Applies a changed sidebar layout from Settings › Sidebar.</summary>
    public void ReloadSidebar()
    {
        if (context is null) return;
        BuildSidebar(context.Store.Preferences.Sidebar(), context.Store.Client.SupportsWatchlist);
        ShowCurrentPage();
    }

    /// <summary>Builds the pages again after a display setting changed (poster size, watched titles).</summary>
    public void RebuildPages()
    {
        foreach (var page in pages.Values) page.Rebuild();
        foreach (var page in details) page.Rebuild();
    }

    /// <summary>Ctrl+F: from Home or a detail page it opens Library; otherwise it focuses the page's search.</summary>
    public void FindInLibrary()
    {
        if (context is null) return;
        details.Clear();
        if (Destination is not (LibraryDestination.Library or LibraryDestination.Movies or LibraryDestination.TvShows or LibraryDestination.RecentlyAdded))
            Destination = LibraryDestination.Library;
        ShowCurrentPage();
        if (CurrentPage is BrowsePage browse) Avalonia.Threading.Dispatcher.UIThread.Post(browse.FocusSearch);
    }

    private void OnKeyDown(object? sender, KeyEventArgs e)
    {
        if (Sheets.IsShowing) return;
        if (e.Key == Key.F && e.KeyModifiers == KeyModifiers.Control)
        {
            FindInLibrary();
            e.Handled = true;
        }
        else if (e.Key == Key.Oem2 && e.KeyModifiers == KeyModifiers.Control)
        {
            ShowShortcuts();
            e.Handled = true;
        }
        else if ((e.Key == Key.Left && e.KeyModifiers == KeyModifiers.Alt) || (e.Key == Key.Escape && details.Count > 0))
        {
            Back();
            e.Handled = true;
        }
    }

    private void OnSessionChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppSession.Library)) AttachLibrary(session?.Library);
        if (e.PropertyName == nameof(AppSession.Profile)) ShowProfile();
    }

    private void AttachLibrary(LibraryStore? store)
    {
        if (context?.Store is { } old) old.PropertyChanged -= OnStoreChanged;
        pages.Clear();
        details.Clear();
        context = store is null ? null : new LibraryContext(store, this);
        if (store is not null)
        {
            store.PropertyChanged += OnStoreChanged;
            BuildSidebar(store.Preferences.Sidebar(), store.Client.SupportsWatchlist);
            RestoreDestination(store);
        }
        ShowCurrentPage();
        UpdateError();
    }

    private void OnStoreChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(LibraryStore.Error)) UpdateError();
    }

    private void UpdateError()
    {
        var message = context?.Store.Error;
        ErrorBanner.IsVisible = message is not null;
        ErrorText.Text = message;
    }

    /// <summary>The start screen preference, or the last page for this server and profile, as on the Mac.</summary>
    private void RestoreDestination(LibraryStore store)
    {
        var prefs = store.Preferences;
        LibraryDestination target = prefs.StartScreen switch
        {
            "home" or "continueWatching" => LibraryDestination.Home,
            "library" => LibraryDestination.Library,
            "movies" => LibraryDestination.Movies,
            "series" => LibraryDestination.TvShows,
            "collections" => LibraryDestination.Collections,
            "watchlist" => store.Client.SupportsWatchlist ? LibraryDestination.Watchlist : LibraryDestination.Library,
            "recentlyAdded" => LibraryDestination.RecentlyAdded,
            _ => prefs.LastDestination(store.Client.Server.ServerId, store.Client.Profile.User.Id) ?? LibraryDestination.Home,
        };
        if (target == LibraryDestination.Watchlist && !store.Client.SupportsWatchlist) target = LibraryDestination.Home;
        restoring = true;
        Destination = SidebarItems.Any(item => item.Destination == target) ? target : SidebarItems.Count > 0 ? SidebarItems[0].Destination : LibraryDestination.Library;
        restoring = false;
    }

    private void BuildSidebar(SidebarLayout layout, bool supportsWatchlist)
    {
        var selected = SidebarList.SelectedItem as SidebarItem;
        restoring = true;
        SidebarList.ItemsSource = layout.VisibleItems(supportsWatchlist)
            .Select(destination => new SidebarItem(destination, destination.Title(), Icon(destination)))
            .ToList();
        SidebarList.SelectedItem = SidebarItems.FirstOrDefault(item => item.Destination == selected?.Destination) ?? (SidebarItems.Count > 0 ? SidebarItems[0] : null);
        restoring = false;
    }

    private void Push(LibraryPageBase page)
    {
        details.Add(page);
        ShowCurrentPage();
    }

    private void ShowCurrentPage()
    {
        if (context is null)
        {
            PageHost.Content = new TextBlock
            {
                Text = "Loading your library…",
                Classes = { "subdued" },
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
            return;
        }
        var page = details.Count > 0 ? details[^1] : PageFor(Destination);
        page.SidebarOverlap = sidebarVisible ? sidebarWidth : 0;
        PageHost.Content = page;
    }

    private LibraryPageBase PageFor(LibraryDestination destination)
    {
        if (pages.TryGetValue(destination, out var existing)) return existing;
        LibraryPageBase page = destination switch
        {
            LibraryDestination.Home => new HomePage(context!),
            LibraryDestination.Library => new BrowsePage(context!, BrowseSection.Library),
            LibraryDestination.Movies => new BrowsePage(context!, BrowseSection.Movies),
            LibraryDestination.TvShows => new BrowsePage(context!, BrowseSection.TvShows),
            LibraryDestination.RecentlyAdded => new BrowsePage(context!, BrowseSection.RecentlyAdded),
            LibraryDestination.Collections => new CollectionsPage(context!),
            LibraryDestination.Watchlist => new WatchlistPage(context!),
            LibraryDestination.History => new HistoryPage(context!),
            _ => new StatisticsPage(context!),
        };
        page.Rebuild();
        pages[destination] = page;
        return page;
    }

    private void ShowProfile()
    {
        ProfileFooter.Children.Clear();
        if (session?.Profile is { } profile)
        {
            ProfileFooter.Children.Add(new ProfileAvatar(profile.User.Id, profile.User.Username, 30));
            ProfileFooter.Children.Add(new TextBlock { Text = profile.User.Username, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center });
            AutomationProperties.SetName(ProfileButton, $"Switch Profile, {profile.User.Username}");
        }
        else
        {
            ProfileFooter.Children.Add(ConnectionLabel);
        }
    }

    private void UpdateSidebarLayout()
    {
        Sidebar.IsVisible = sidebarVisible;
        // The toggle sits at the sidebar's top right, or at the window's edge while it is hidden.
        SidebarToggle.Margin = new Thickness(sidebarVisible ? sidebarWidth - 46 : Math.Max(12, leadingInset + 4), 10, 0, 0);
        var label = sidebarVisible ? "Hide Sidebar" : "Show Sidebar";
        AutomationProperties.SetName(SidebarToggle, label);
        ToolTip.SetTip(SidebarToggle, $"{label} (F9)");
        if (CurrentPage is { } page) page.SidebarOverlap = sidebarVisible ? sidebarWidth : 0;
    }

    internal static Geometry? Icon(LibraryDestination destination) => Icon("Icon" + destination);

    private static Geometry? Icon(string key) => Application.Current?.FindResource(key) as Geometry;
}
