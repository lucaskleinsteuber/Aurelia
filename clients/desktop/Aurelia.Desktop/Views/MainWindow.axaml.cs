using Avalonia.Controls;

namespace Aurelia.Desktop.Views;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        VersionLabel.Text = AppInfo.VersionLabel;
    }
}
