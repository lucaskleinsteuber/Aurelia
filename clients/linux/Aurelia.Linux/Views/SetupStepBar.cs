using Aurelia.Linux.Core.Flow;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Views;

/// <summary>
/// The guided setup's progress above each setup screen: finished steps get a check, the current one is
/// highlighted. "Skip Assistant" keeps the setup screens but drops the guidance and the tour.
/// </summary>
public sealed class SetupStepBar : Border
{
    public SetupStepBar(AppFlow flow, SetupStep current)
    {
        Current = current;
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Top;
        Margin = new Thickness(0, 16, 0, 0);
        Padding = new Thickness(16, 8);
        CornerRadius = new CornerRadius(20);
        Background = new SolidColorBrush(Color.FromArgb(0xB8, 0x1C, 0x1E, 0x22));
        BorderBrush = new SolidColorBrush(Color.FromArgb(0x1F, 0xFF, 0xFF, 0xFF));
        BorderThickness = new Thickness(1);
        AutomationProperties.SetName(this, "Setup Progress");
        var steps = flow.Guide.Steps(flow.Mode);
        var index = Math.Max(0, IndexOf(steps, current));
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        for (var position = 0; position < steps.Count; position++)
        {
            if (position > 0) row.Children.Add(new Border { Width = 18, Height = 1, VerticalAlignment = VerticalAlignment.Center, Background = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)) });
            row.Children.Add(Step(position + 1, SetupGuide.Title(steps[position]), position < index, position == index));
        }
        var skip = new Button { Content = "Skip Assistant", Classes = { "link" }, FontSize = 12, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        skip.Click += (_, _) => flow.Guide.Skip();
        row.Children.Add(skip);
        Child = row;
    }

    public SetupStep Current { get; }

    private static int IndexOf(IReadOnlyList<SetupStep> steps, SetupStep step)
    {
        for (var index = 0; index < steps.Count; index++)
        {
            if (steps[index] == step) return index;
        }
        return -1;
    }

    private static StackPanel Step(int number, string title, bool done, bool current)
    {
        var accent = Application.Current?.FindResource("AureliaAccentBrush") as IBrush ?? Brushes.DodgerBlue;
        Control mark = done
            ? new PathIcon { Data = Application.Current?.FindResource("IconCheck") as Geometry, Width = 10, Height = 10, Foreground = Brushes.White }
            : new TextBlock { Text = number.ToString(System.Globalization.CultureInfo.InvariantCulture), FontSize = 11, FontWeight = FontWeight.SemiBold, Foreground = Brushes.White };
        mark.HorizontalAlignment = HorizontalAlignment.Center;
        mark.VerticalAlignment = VerticalAlignment.Center;
        return new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Children =
            {
                new Border
                {
                    Width = 20,
                    Height = 20,
                    CornerRadius = new CornerRadius(10),
                    Background = done || current ? accent : new SolidColorBrush(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF)),
                    Child = mark,
                },
                new TextBlock
                {
                    Text = title,
                    FontSize = 12,
                    FontWeight = current ? FontWeight.SemiBold : FontWeight.Normal,
                    Opacity = current ? 1 : 0.7,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            },
        };
    }
}
