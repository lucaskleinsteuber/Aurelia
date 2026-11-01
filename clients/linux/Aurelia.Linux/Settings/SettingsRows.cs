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

    public static StackPanel Section(string? title, params Control[] rows)
    {
        var card = new StackPanel { Spacing = 0 };
        for (var index = 0; index < rows.Length; index++)
        {
            if (index > 0) card.Children.Add(new Border { Height = 1, Background = Application.Current?.FindResource("AureliaHairlineBrush") as IBrush, Margin = new Thickness(16, 0) });
            card.Children.Add(rows[index]);
        }
        var section = new StackPanel { Spacing = 8 };
        if (title is not null) section.Children.Add(new TextBlock { Text = title, FontWeight = FontWeight.SemiBold, Classes = { "subdued" }, Margin = new Thickness(4, 0) });
        section.Children.Add(new Border { Classes = { "card" }, Padding = new Thickness(0, 4), Child = card });
        return section;
    }

    public static DockPanel Row(string label, string? detail, Control control)
    {
        var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center, Children = { new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap } } };
        if (detail is not null) text.Children.Add(new TextBlock { Text = detail, Classes = { "subdued" }, FontSize = 12, TextWrapping = TextWrapping.Wrap });
        control.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetName(control, label);
        return new DockPanel
        {
            Margin = new Thickness(16, 10),
            Children = { control.Also(c => { DockPanel.SetDock(c, Dock.Right); c.Margin = new Thickness(16, 0, 0, 0); }), text },
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

    public static Button Action(string label, Action action, string classes = "chip")
    {
        var button = new Button { Content = label, Classes = { classes } };
        button.Click += (_, _) => action();
        return button;
    }
}
