using Avalonia.Controls;
using Avalonia.Interactivity;
using Aurelia.Desktop.Core;

namespace Aurelia.Desktop.Views;

/// <summary>The app's own Settings, for this computer, as the Mac app's settings window.</summary>
public sealed partial class AppSettingsWindow : Window
{
    public AppSettingsWindow()
    {
        InitializeComponent();
        TitleBar.Extend(this, Root, top => SettingsContent.Margin = new Avalonia.Thickness(0, top, 0, 0));
    }

    internal AppSettingsWindow(PlaybackPreferencesModel model) : this() => DataContext = model;

    private void ForgetTracks(object? sender, RoutedEventArgs e) => (DataContext as PlaybackPreferencesModel)?.ForgetTrackChoices();

    private void RestoreDefaults(object? sender, RoutedEventArgs e) => (DataContext as PlaybackPreferencesModel)?.RestoreDefaults();
}
