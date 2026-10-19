using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Platform.Storage;
using Aurelia.Contracts;
using Aurelia.Desktop.Core;

namespace Aurelia.Desktop.Views;

/// <summary>The "Set Up This PC" steps. Passwords and PINs stay in their boxes and are cleared after use.</summary>
public sealed partial class HostSetupView : UserControl
{
    public HostSetupView()
    {
        InitializeComponent();
        HostChoiceTitle.Text = OperatingSystem.IsWindows() ? "Set Up This PC" : "Set Up This Computer";
        OwnerTitle.Text = HostChoiceTitle.Text;
    }

    /// <summary>Chooses folders without a dialog, for tests; the app uses the system folder picker.</summary>
    internal Func<Task<IReadOnlyList<string>>>? FolderSource { get; set; }

    private HostSetupFlow? Flow => DataContext as HostSetupFlow;

    protected override void OnDataContextChanged(EventArgs e)
    {
        base.OnDataContextChanged(e);
        // Windows asks once whether the server may use the network; it is expected, not a warning.
        FirewallHint.IsVisible = OperatingSystem.IsWindows() && Flow?.Host.Settings.LanAccessEnabled == true;
    }

    private async void ChooseHost(object? sender, RoutedEventArgs e)
    {
        if (Flow is { } flow) await flow.ChooseHostAsync();
    }

    private void ChooseClient(object? sender, RoutedEventArgs e) => Flow?.ChooseClient();

    private async void Retry(object? sender, RoutedEventArgs e)
    {
        if (Flow is { } flow) await flow.RetryAsync();
    }

    private async void UseAnotherServer(object? sender, RoutedEventArgs e)
    {
        if (Flow is { } flow) await flow.UseAnotherServerAsync();
    }

    private void ToggleAdvanced(object? sender, RoutedEventArgs e)
    {
        AdvancedPanel.IsVisible = !AdvancedPanel.IsVisible;
        AdvancedButton.Content = AdvancedPanel.IsVisible ? "Advanced ˅" : "Advanced ›";
    }

    private async void SetUp(object? sender, RoutedEventArgs e) => await SetUpAsync();

    private async void SetupKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) await SetUpAsync();
    }

    private async Task SetUpAsync()
    {
        if (Flow is not { } flow) return;
        await flow.SetUpAsync(SetupPassword.Text ?? "", SetupConfirmation.Text ?? "");
        if (!flow.ShowsOwnerSetup)
        {
            SetupPassword.Text = "";
            SetupConfirmation.Text = "";
        }
        if (flow.ShowsCreatePin) NewPin.Focus();
    }

    private async void SignIn(object? sender, RoutedEventArgs e) => await SignInAsync();

    private async void SignInKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) await SignInAsync();
    }

    private async Task SignInAsync()
    {
        if (Flow is not { } flow) return;
        await flow.SignInAsync(SignInPassword.Text ?? "");
        SignInPassword.Text = "";
    }

    private async void CreatePin(object? sender, RoutedEventArgs e) => await CreatePinAsync();

    private async void PinKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) await CreatePinAsync();
    }

    private async Task CreatePinAsync()
    {
        if (Flow is not { } flow) return;
        await flow.CreatePinAsync(NewPin.Text ?? "", NewPinConfirmation.Text ?? "", PinPassword.Text);
        if (flow.HasError) return;
        NewPin.Text = "";
        NewPinConfirmation.Text = "";
        PinPassword.Text = "";
    }

    private async void ResetPinClicked(object? sender, RoutedEventArgs e)
    {
        if (Flow is not { } flow) return;
        await flow.ResetPinAsync(ResetPassword.Text ?? "", ResetPin.Text ?? "", ResetPinConfirmation.Text ?? "");
        if (flow.HasError) return;
        ResetPassword.Text = "";
        ResetPin.Text = "";
        ResetPinConfirmation.Text = "";
    }

    private void CancelReset(object? sender, RoutedEventArgs e) => Flow?.CancelPinReset();

    private async void ChooseFolders(object? sender, RoutedEventArgs e)
    {
        if (Flow is not { } flow) return;
        flow.AddLocations(await PickFoldersAsync());
    }

    internal async Task<IReadOnlyList<string>> PickFoldersAsync()
    {
        if (FolderSource is { } source) return await source();
        if (TopLevel.GetTopLevel(this)?.StorageProvider is not { CanPickFolder: true } storage) return [];
        var folders = await storage.OpenFolderPickerAsync(new FolderPickerOpenOptions
        {
            Title = "Choose Storage Locations",
            AllowMultiple = true,
        });
        return [.. folders.Select(folder => folder.TryGetLocalPath()).OfType<string>()];
    }

    private void KindChanged(object? sender, SelectionChangedEventArgs e)
    {
        if (sender is ComboBox { DataContext: StorageDraft location } box)
            HostSetupFlow.SetKind(location, box.SelectedIndex switch { 1 => LibraryKind.Movies, 2 => LibraryKind.TvShows, _ => LibraryKind.Automatic });
    }

    private void RemoveLocation(object? sender, RoutedEventArgs e)
    {
        if ((sender as Control)?.DataContext is StorageDraft location) Flow?.RemoveLocation(location);
    }

    private async void Import(object? sender, RoutedEventArgs e)
    {
        if (Flow is { } flow) await flow.ImportAsync();
    }

    private void SkipStorage(object? sender, RoutedEventArgs e) => Flow?.SkipStorage();

    private void ContinueToLibrary(object? sender, RoutedEventArgs e) => Flow?.ContinueToLibrary();
}
