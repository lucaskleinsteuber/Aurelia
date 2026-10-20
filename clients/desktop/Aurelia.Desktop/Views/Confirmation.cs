using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Desktop.Views;

/// <summary>A small confirmation next to the button that asked, instead of a separate dialog, as in Server Settings.</summary>
internal static class Confirmation
{
    public static Flyout Show(Control anchor, string question, string? explanation, string action, Func<Task> confirmed)
    {
        var flyout = new Flyout { Placement = PlacementMode.BottomEdgeAlignedRight };
        var button = new Button { Content = action, Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Right, Name = "ConfirmAction" };
        button.Click += async (_, _) =>
        {
            flyout.Hide();
            await confirmed();
        };
        var content = new StackPanel { Spacing = 10, Width = 320 };
        content.Children.Add(new TextBlock { Text = question, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap });
        if (explanation is not null) content.Children.Add(new TextBlock { Text = explanation, TextWrapping = TextWrapping.Wrap, Classes = { "secondary" } });
        content.Children.Add(button);
        flyout.Content = content;
        flyout.ShowAt(anchor);
        return flyout;
    }
}
