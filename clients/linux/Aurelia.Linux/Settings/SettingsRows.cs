using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Settings;

/// <summary>The building blocks of the settings pages: grouped sections with labeled rows, as on the Mac.</summary>
internal static class SettingsRows
{
    public static TextBlock PageTitle(string text) => new() { Text = text, FontSize = 26, FontWeight = FontWeight.Bold, Margin = new Thickness(0, 0, 0, 6) };

    /// <summary>A group of rows in one card, its title with a symbol at the top inside it, as the Mac's settings sections.</summary>
    public static StackPanel Section(string? title, params Control[] rows)
    {
        var card = new StackPanel { Spacing = 0 };
        if (title is not null)
        {
            var heading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Margin = new Thickness(16, 12, 16, 4) };
            if (SectionIcon(title) is { } icon)
                heading.Children.Add(new PathIcon { Data = Application.Current?.FindResource(icon) as Geometry, Width = 15, Height = 15, Foreground = new SolidColorBrush(Color.FromArgb(0x99, 0xFF, 0xFF, 0xFF)), VerticalAlignment = VerticalAlignment.Center });
            heading.Children.Add(new TextBlock { Text = title, FontSize = 15, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center });
            card.Children.Add(heading);
        }
        for (var index = 0; index < rows.Length; index++)
        {
            if (index > 0) card.Children.Add(new Border { Height = 1, Background = Application.Current?.FindResource("AureliaHairlineBrush") as IBrush, Margin = new Thickness(16, 0) });
            card.Children.Add(rows[index]);
        }
        return new StackPanel { Spacing = 8, Children = { new Border { Classes = { "card" }, Padding = new Thickness(0, 4, 0, 6), Child = card } } };
    }

    /// <summary>
    /// Text and buttons of one section as a single padded block, so they line up with the
    /// section's title instead of touching the card's edge with a line between each of them.
    /// </summary>
    public static StackPanel Padded(params Control[] children)
    {
        var panel = new StackPanel { Spacing = 10, Margin = new Thickness(16, 6, 16, 10) };
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    /// <summary>A button inside a settings card: a rounded, lighter capsule that stands out from the card.</summary>
    public static Button CardButton(string label)
    {
        var button = new Button { Content = label, Classes = { "cardAction" }, HorizontalAlignment = HorizontalAlignment.Left };
        AutomationProperties.SetName(button, label);
        return button;
    }

    /// <summary>A symbol for a section, where one fits; others show their title alone.</summary>
    internal static string? SectionIcon(string title) => title switch
    {
        "Playing" => "IconPlay",
        "Sound and Controls" => "IconVolume",
        "Languages" or "Subtitle Downloads" => "IconSubtitles",
        "Motion and Appearance" => "IconSparkle",
        "Library" or "Storage Locations" or "Library Maintenance" or "Library Health & Maintenance" or "Catalog Visibility" => "IconLibrary",
        "Server" or "Server Details" or "Server Connection" or "Hosting" or "When the Server Runs" => "IconServer",
        "Server Updates" or "Beta" => "IconDownload",
        "Network" or "Sign-In & Streaming Limits" => "IconNetwork",
        "Power Saving" => "IconSleep",
        "Profile" or "Profiles" or "Current Profile" or "PIN" or "PIN Protection" or "Content Access" => "IconPerson",
        "Devices" or "Devices & Backups" or "Backup Details" => "IconComputer",
        "Movie & TV Information" or "Trailer Reviews" => "IconSparkle",
        "Scrub Previews" => "IconMovies",
        "Diagnostics" or "Scan Activity" => "IconStatistics",
        "Continue Watching" or "Recently Added" => "IconRecentlyAdded",
        "Favorites" => "IconFavorite",
        "Collections" or "Franchises in Library" => "IconCollections",
        "Advanced" => "IconSliders",
        "What's New in This Version" or "Getting Started" => "IconSparkle",
        "Source Code" => "IconComputer",
        _ => null,
    };

    public static DockPanel Row(string label, string? detail, Control control)
    {
        var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center, Children = { new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap } } };
        if (detail is not null) text.Children.Add(new TextBlock { Text = detail, Classes = { "subdued" }, FontSize = 12, TextWrapping = TextWrapping.Wrap });
        control.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetName(control, label);
        return new DockPanel
        {
            Margin = new Thickness(16, 10),
            Children = { control.Also(c => { DockPanel.SetDock(c, Dock.Right); // A switch without text still keeps a 12 px gap for it on its right; take it back so the
                // switch ends where the menus and buttons of the other rows end.
                c.Margin = new Thickness(16, 0, c is ToggleSwitch ? -12 : 0, 0); }), text },
        };
    }

    public static DockPanel Toggle(string label, string? detail, bool value, Action<bool> changed)
    {
        var toggle = new ToggleSwitch { IsChecked = value, OnContent = "", OffContent = "" };
        toggle.IsCheckedChanged += (_, _) => changed(toggle.IsChecked == true);
        return Row(label, detail, toggle);
    }

    public static DockPanel Choice<T>(string label, string? detail, IReadOnlyList<(T Value, string Label)> options, T value, Action<T> changed)
    {
        var box = new ComboBox { ItemsSource = options.Select(o => o.Label).ToList(), MinWidth = 200 };
        box.SelectedIndex = Math.Max(0, options.ToList().FindIndex(o => EqualityComparer<T>.Default.Equals(o.Value, value)));
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedIndex >= 0) changed(options[box.SelectedIndex].Value);
        };
        return Row(label, detail, box);
    }

    public static DockPanel Value(string label, string value) =>
        Row(label, null, new TextBlock { Text = value, Classes = { "subdued" }, TextWrapping = TextWrapping.Wrap, MaxWidth = 360, TextAlignment = TextAlignment.Right });

    public static Button Action(string label, Action action, string classes = "cardAction")
    {
        var button = new Button { Content = label, Classes = { classes } };
        button.Click += (_, _) => action();
        return button;
    }
}
