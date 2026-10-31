using Aurelia.Linux.Core.Flow;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;

namespace Aurelia.Linux.Views;

/// <summary>Stands in for a screen that a later test build brings, with a way back to the welcome choice.</summary>
public sealed class PreviewNoticeView : UserControl
{
    public PreviewNoticeView(AppFlow flow, string title, string detail)
    {
        var back = new Button { Content = "Back", Classes = { "link" }, HorizontalAlignment = HorizontalAlignment.Center };
        back.Click += (_, _) => flow.ReturnToWelcome();
        Content = ScreenParts.Backdrop(new StackPanel
        {
            Spacing = 18,
            Margin = new Thickness(40),
            VerticalAlignment = VerticalAlignment.Center,
            Children = { ScreenParts.Symbol("IconAurelia", 46), ScreenParts.Title(title), ScreenParts.Detail(detail), back },
        });
    }
}
