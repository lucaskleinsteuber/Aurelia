using Aurelia.Linux.Core.Platform;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Chrome;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;

namespace Aurelia.Linux.Controls;

/// <summary>
/// Aurelia's own window buttons, drawn over the content because the window has no title bar. They
/// are plain round Linux-style buttons placed where the desktop puts its buttons (KDE, GNOME), never
/// imitations of the Mac's colored buttons. Moving the window is handled by <see cref="AppWindowBehavior"/>.
/// </summary>
public sealed class WindowChrome : Panel
{
    public const double ButtonSize = 26;
    public const double Spacing = 8;
    public const double Inset = 14;

    private readonly StackPanel left = Cluster(HorizontalAlignment.Left);
    private readonly StackPanel right = Cluster(HorizontalAlignment.Right);
    private Window? window;

    public WindowChrome()
    {
        Children.Add(left);
        Children.Add(right);
    }

    public WindowButtonLayout Layout { get; private set; } = WindowButtonLayout.Default;

    /// <summary>How much room the buttons take at the window's left edge (0 when they are on the right).</summary>
    public double LeadingWidth => ClusterWidth(Layout.Left);

    public void Attach(Window owner, WindowButtonLayout layout)
    {
        window = owner;
        Layout = layout;
        Fill(left, layout.Left);
        Fill(right, layout.Right);
        owner.PropertyChanged += (_, change) =>
        {
            if (change.Property == Window.WindowStateProperty) UpdateState();
        };
        UpdateState();
    }

    internal IEnumerable<Button> Buttons => left.Children.Concat(right.Children).OfType<Button>();

    private static double ClusterWidth(IReadOnlyList<WindowButton> buttons) =>
        buttons.Count == 0 ? 0 : Inset + buttons.Count * ButtonSize + (buttons.Count - 1) * Spacing;

    private static StackPanel Cluster(HorizontalAlignment alignment) => new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = Spacing,
        HorizontalAlignment = alignment,
        VerticalAlignment = VerticalAlignment.Top,
        Margin = new Thickness(Inset, 14, Inset, 0),
    };

    private void Fill(StackPanel cluster, IReadOnlyList<WindowButton> buttons)
    {
        cluster.Children.Clear();
        foreach (var kind in buttons)
        {
            var button = new Button
            {
                Classes = { "windowButton" },
                Tag = kind,
                Content = new PathIcon { Width = 12, Height = 12 },
            };
            WindowDecorationProperties.SetElementRole(button, kind switch
            {
                WindowButton.Close => WindowDecorationsElementRole.CloseButton,
                WindowButton.Minimize => WindowDecorationsElementRole.MinimizeButton,
                _ => WindowDecorationsElementRole.MaximizeButton,
            });
            button.Click += (_, _) => Press(kind);
            cluster.Children.Add(button);
        }
    }

    private void Press(WindowButton kind)
    {
        if (window is null) return;
        switch (kind)
        {
            case WindowButton.Close:
                window.Close();
                break;
            case WindowButton.Minimize:
                window.WindowState = WindowState.Minimized;
                break;
            default:
                window.WindowState = window.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
                break;
        }
    }

    private void UpdateState()
    {
        var state = window?.WindowState ?? WindowState.Normal;
        // Full screen shows only the content; the buttons return when it ends.
        IsVisible = state != WindowState.FullScreen;
        foreach (var button in Buttons)
        {
            var kind = (WindowButton)button.Tag!;
            var (label, icon) = kind switch
            {
                WindowButton.Close => ("Close Window", "IconWindowClose"),
                WindowButton.Minimize => ("Minimize Window", "IconWindowMinimize"),
                _ when state == WindowState.Maximized => ("Restore Window", "IconWindowRestore"),
                _ => ("Maximize Window", "IconWindowMaximize"),
            };
            AutomationProperties.SetName(button, label);
            ToolTip.SetTip(button, label);
            ((PathIcon)button.Content!).Data = Application.Current?.FindResource(icon) as Geometry;
        }
    }
}
