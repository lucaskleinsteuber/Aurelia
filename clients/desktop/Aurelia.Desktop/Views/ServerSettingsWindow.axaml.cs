using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Platform.Storage;
using Aurelia.Contracts;
using Aurelia.Desktop.Core;

namespace Aurelia.Desktop.Views;

/// <summary>Server Settings in its own window, as on the Mac. Password and PIN boxes are cleared after use.</summary>
public sealed partial class ServerSettingsWindow : Window
{
    public ServerSettingsWindow()
    {
        InitializeComponent();
    }

    internal ServerSettingsWindow(ServerSettingsModel model) : this()
    {
        DataContext = model;
        Opened += async (_, _) =>
        {
            await model.OpenAsync();
            model.WatchScans();
            if (model.IsLocked) UnlockPassword.Focus();
        };
        Closed += (_, _) => model.Dispose();
    }

    /// <summary>Chooses a folder without a dialog, for tests; the app uses the system folder picker.</summary>
    internal Func<Task<string?>>? FolderSource { get; set; }

    private ServerSettingsModel? Model => DataContext as ServerSettingsModel;

    private void SectionChanged(object? sender, SelectionChangedEventArgs e)
    {
        if (Model is { } model) model.Section = (SettingsSection)Math.Max(0, Sections.SelectedIndex);
    }

    private async void Unlock(object? sender, RoutedEventArgs e) => await UnlockAsync();

    private async void UnlockKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) await UnlockAsync();
    }

    private async Task UnlockAsync()
    {
        if (Model is not { } model) return;
        await model.UnlockAsync(UnlockPassword.Text ?? "");
        UnlockPassword.Text = "";
    }

    private async void ApplyNetwork(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.ApplyNetworkAsync();
    }

    private async void ConfirmNetwork(object? sender, RoutedEventArgs e)
    {
        if (Model is not { } model) return;
        await model.ConfirmNetworkAsync(ConfirmPin.Text, ConfirmPassword.Text ?? "");
        if (model.HasError) return;
        ConfirmPin.Text = "";
        ConfirmPassword.Text = "";
    }

    /// <summary>Windows Settings, where the network profile is changed from Public to Private.</summary>
    private void OpenNetworkSettings(object? sender, RoutedEventArgs e)
    {
        if (!OperatingSystem.IsWindows()) return;
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:network-status") { UseShellExecute = true })?.Dispose(); }
        catch (System.ComponentModel.Win32Exception) { }
    }

    private async void Restart(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.RestartAsync();
    }

    private async void AddStorage(object? sender, RoutedEventArgs e)
    {
        if (Model is not { } model || await PickFolderAsync() is not { } path) return;
        await model.AddStorageAsync(path, NewKind.SelectedIndex switch { 1 => LibraryKind.Movies, 2 => LibraryKind.TvShows, _ => LibraryKind.Automatic });
    }

    private async Task<string?> PickFolderAsync()
    {
        if (FolderSource is { } source) return await source();
        if (!StorageProvider.CanPickFolder) return null;
        var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = "Add Storage Location" });
        return folders.Count > 0 ? folders[0].TryGetLocalPath() : null;
    }

    private async void Scan(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model && (sender as Control)?.DataContext is StorageRow row) await model.ScanAsync(row);
    }

    private void Remove(object? sender, RoutedEventArgs e)
    {
        if (Model is not { } model || sender is not Control { DataContext: StorageRow row } anchor) return;
        Confirm(anchor, $"Remove {row.Name} from Aurelia? Its titles, progress and favorites go with it. The files stay where they are.",
            "Remove", () => model.RemoveStorageAsync(row));
    }

    private async void LookUp(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.LookUpDeviceAsync();
    }

    private async void DeviceCodeKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && Model is { } model) await model.LookUpDeviceAsync();
    }

    private async void Approve(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.AnswerDeviceAsync(approve: true);
    }

    private async void Deny(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.AnswerDeviceAsync(approve: false);
    }

    private void RemoveDevice(object? sender, RoutedEventArgs e)
    {
        if (Model is not { } model || sender is not Control { DataContext: DeviceRow row } anchor) return;
        Confirm(anchor, $"Remove {row.Session.DeviceName}? It needs a new approval to connect again.", "Remove",
            () => model.RemoveDeviceAsync(row));
    }

    private async void NewProfile(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.Profiles.BeginNewAsync();
    }

    private async void EditProfile(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model && (sender as Control)?.DataContext is ProfileRow row) await model.Profiles.BeginEditAsync(row);
    }

    private void RemoveProfile(object? sender, RoutedEventArgs e)
    {
        if (Model is not { } model || sender is not Control { DataContext: ProfileRow row } anchor) return;
        Confirm(anchor, $"Remove {row.Name}? Its progress, favorites and devices go with it. Movies and shows stay.", "Remove",
            () => model.Profiles.RemoveAsync(row));
    }

    private async void SaveProfile(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.Profiles.SaveAsync();
    }

    private void CancelProfile(object? sender, RoutedEventArgs e) => Model?.Profiles.CancelEdit();

    /// <summary>A small confirmation next to the button, instead of a separate dialog.</summary>
    private static void Confirm(Control anchor, string question, string action, Func<Task> confirmed)
    {
        var flyout = new Flyout { Placement = PlacementMode.BottomEdgeAlignedRight };
        var button = new Button { Content = action, Classes = { "primary" }, HorizontalAlignment = HorizontalAlignment.Right };
        button.Click += async (_, _) =>
        {
            flyout.Hide();
            await confirmed();
        };
        flyout.Content = new StackPanel
        {
            Spacing = 12,
            Width = 300,
            Children = { new TextBlock { Text = question, TextWrapping = Avalonia.Media.TextWrapping.Wrap }, button },
        };
        flyout.ShowAt(anchor);
    }
}
