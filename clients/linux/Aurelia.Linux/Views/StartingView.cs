using Avalonia.Controls;
using Avalonia.Layout;

namespace Aurelia.Linux.Views;

/// <summary>Shown for the moment Aurelia reads its saved state, like the Mac app's start screen.</summary>
public sealed class StartingView : UserControl
{
    public StartingView()
    {
        Content = ScreenParts.Backdrop(new StackPanel
        {
            Spacing = 22,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                ScreenParts.Symbol("IconAurelia", 46),
                new TextBlock { Text = "Starting Aurelia…", Classes = { "subdued" }, HorizontalAlignment = HorizontalAlignment.Center },
                new ProgressBar { IsIndeterminate = true, Width = 120 },
            },
        });
    }
}
