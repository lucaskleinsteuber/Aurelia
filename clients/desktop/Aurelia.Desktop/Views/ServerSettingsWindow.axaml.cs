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
        TitleBar.Extend(this, Root, top => SettingsSidebar.Margin = new Avalonia.Thickness(14, 22 + (OperatingSystem.IsMacOS() ? top : 0), 14, 18));
    }

    internal ServerSettingsWindow(ServerSettingsModel model) : this()
    {
        DataContext = model;
        // The sidebar follows the section, also when it changes from elsewhere.
        model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ServerSettingsModel.Section)) Sections.SelectedIndex = (int)model.Section;
        };
        Opened += async (_, _) =>
        {
            await model.OpenAsync();
            model.WatchScans();
            if (model.IsLocked) UnlockPassword.Focus();
        };
        Closed += (_, _) => model.Dispose();
        model.ImportPreviewRequested += library =>
        {
            var preview = new ImportPreviewModel(() => model.Administration, library);
            preview.Confirmed += () => _ = model.RefreshStorageAsync();
            PreviewWindow = new ImportPreviewWindow(preview);
            PreviewWindow.Closed += (_, _) => PreviewWindow = null;
            PreviewWindow.Show(this);
        };
    }

    /// <summary>The Import Preview window while one is open.</summary>
    internal ImportPreviewWindow? PreviewWindow { get; private set; }

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

    private void ReviewImport(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model && (sender as Control)?.DataContext is StorageRow row) model.ReviewImport(row);
    }

    private void Reimport(object? sender, RoutedEventArgs e)
    {
        if (Model is not { } model || sender is not Control { DataContext: ExcludedMediaSummary item } anchor) return;
        Confirm(anchor, $"Reimport {item.RelativePath}? It is scanned again and returns to the library.", "Reimport",
            () => model.Maintenance.ReimportAsync(item));
    }

    private void BeginReset(object? sender, RoutedEventArgs e) => Model?.Maintenance.BeginReset();

    private void CancelReset(object? sender, RoutedEventArgs e) => Model?.Maintenance.CancelReset();

    private async void ReviewReset(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.Maintenance.ReviewResetAsync();
    }

    private void ConfirmReset(object? sender, RoutedEventArgs e)
    {
        if (Model is not { } model || sender is not Control anchor) return;
        Confirm(anchor, "Permanently reset the selected storage locations? This cannot be undone. Your video files are not changed.", "Reset",
            model.Maintenance.ResetAsync);
    }

    /// <summary>Saves without a dialog, for tests; the app uses the system save dialog.</summary>
    internal Func<string, Task<Stream?>>? SaveTarget { get; set; }

    /// <summary>Chooses a backup without a dialog, for tests; the app uses the system file picker.</summary>
    internal Func<Task<ChosenFile?>>? BackupSource { get; set; }

    private async Task<Stream?> ChooseSaveAsync(string suggestedName, string kind, string pattern)
    {
        if (SaveTarget is { } target) return await target(suggestedName);
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Save",
            SuggestedFileName = suggestedName,
            FileTypeChoices = [new FilePickerFileType(kind) { Patterns = [pattern] }],
        });
        return file is null ? null : await file.OpenWriteAsync();
    }

    private async Task<ChosenFile?> ChooseBackupAsync()
    {
        if (BackupSource is { } source) return await source();
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Choose an Aurelia Backup",
            AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType("Aurelia Backups") { Patterns = ["*.aureliabackup"] }, FilePickerFileTypes.All],
        });
        if (files.Count == 0) return null;
        var properties = await files[0].GetBasicPropertiesAsync();
        return new ChosenFile(await files[0].OpenReadAsync(), (long)(properties.Size ?? 0), files[0].Name);
    }

    private async void BackUpNow(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.Operations.BackUpNowAsync();
    }

    private async void VerifyBackup(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model && (sender as Control)?.DataContext is ServerBackupItem backup) await model.Operations.VerifyAsync(backup);
    }

    private async void ExportBackup(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model)
            await model.Operations.ExportAsync(() => ChooseSaveAsync($"Aurelia Server {DateTime.Now:yyyy-MM-dd}.aureliabackup", "Aurelia Backup", "*.aureliabackup"));
    }

    private async void PrepareRestore(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.Operations.PrepareRestoreAsync(ChooseBackupAsync);
    }

    private void ApplyRestore(object? sender, RoutedEventArgs e)
    {
        if (Model is not { } model || sender is not Control anchor) return;
        Confirm(anchor, "Replace this server with the backup now? This cannot be undone.", "Restore", model.Operations.ApplyRestoreAsync);
    }

    private void CancelRestore(object? sender, RoutedEventArgs e) => Model?.Operations.CancelRestore();

    private async void SaveProvider(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.Operations.SaveProviderAsync();
    }

    private void RemoveToken(object? sender, RoutedEventArgs e)
    {
        if (Model is not { } model || sender is not Control anchor) return;
        Confirm(anchor, "Remove the TMDB token from the server? Details already found stay.", "Remove", model.Operations.RemoveTokenAsync);
    }

    private async void Enrich(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.Operations.EnrichAsync();
    }

    private async void RefreshEvents(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model) await model.Operations.LoadEventsAsync();
    }

    private async void ExportDiagnostics(object? sender, RoutedEventArgs e)
    {
        if (Model is { } model)
            await model.Operations.ExportDiagnosticsAsync(() => ChooseSaveAsync($"Aurelia Diagnostics {DateTime.Now:yyyy-MM-dd}.json", "JSON", "*.json"));
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
