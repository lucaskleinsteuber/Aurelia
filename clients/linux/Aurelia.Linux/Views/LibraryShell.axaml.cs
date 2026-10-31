using Aurelia.Linux.Core;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Media;

namespace Aurelia.Linux.Views;

/// <summary>A row in the sidebar.</summary>
public sealed record SidebarItem(LibraryDestination Destination, string Title, Geometry? Icon);

/// <summary>
/// The window's frame: the blurred sidebar with the library pages, and the page beside it. Pages
/// stay full height beneath the sidebar, like the Mac app's.
/// </summary>
public sealed partial class LibraryShell : UserControl
{
    private readonly double sidebarWidth;
    private bool sidebarVisible = true;

    public LibraryShell()
    {
        InitializeComponent();
        SidebarBackdrop.Source = PageLayer;
        sidebarWidth = Sidebar.Width;

        SidebarList.ItemsSource = SidebarLayout.Default.VisibleItems(supportsWatchlist: true)
            .Select(destination => new SidebarItem(destination, destination.Title(), Icon(destination)))
            .ToList();
        SidebarList.SelectionChanged += (_, _) => ShowSelectedPage();
        SidebarToggle.Click += (_, _) => SidebarVisible = !SidebarVisible;
        SidebarList.SelectedIndex = 0;
        ShowSelectedPage();
        UpdateSidebarLayout();
    }

    internal IReadOnlyList<SidebarItem> SidebarItems => (IReadOnlyList<SidebarItem>)SidebarList.ItemsSource!;

    public LibraryDestination Destination
    {
        get => (SidebarList.SelectedItem as SidebarItem)?.Destination ?? LibraryDestination.Home;
        set => SidebarList.SelectedItem = SidebarItems.FirstOrDefault(item => item.Destination == value);
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

    /// <summary>The page shown now.</summary>
    internal LibraryPage? CurrentPage => PageHost.Content as LibraryPage;

    private void ShowSelectedPage()
    {
        PageHost.Content = new LibraryPage(Destination) { SidebarOverlap = sidebarVisible ? sidebarWidth : 0 };
    }

    private void UpdateSidebarLayout()
    {
        Sidebar.IsVisible = sidebarVisible;
        // The toggle sits at the sidebar's top right, or at the window's edge while it is hidden.
        SidebarToggle.Margin = new Thickness(sidebarVisible ? sidebarWidth - 46 : 12, 12, 0, 0);
        var label = sidebarVisible ? "Hide Sidebar" : "Show Sidebar";
        AutomationProperties.SetName(SidebarToggle, label);
        ToolTip.SetTip(SidebarToggle, $"{label} (F9)");
        if (CurrentPage is { } page) page.SidebarOverlap = sidebarVisible ? sidebarWidth : 0;
    }

    internal static Geometry? Icon(LibraryDestination destination) =>
        Application.Current?.FindResource("Icon" + destination) as Geometry;
}
