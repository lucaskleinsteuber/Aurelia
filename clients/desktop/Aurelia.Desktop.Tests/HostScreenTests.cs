using Avalonia.Controls;
using Avalonia.Headless.XUnit;
using Avalonia.Interactivity;
using Avalonia.Threading;
using Aurelia.Contracts;
using Aurelia.Desktop.Core;
using Aurelia.Desktop.Views;
using Xunit;

namespace Aurelia.Desktop.Tests;

/// <summary>"Set Up This PC" and Server Settings with a scripted server, rendered off screen; nothing starts.</summary>
public sealed class HostScreenTests
{
    private const string Password = "synthetic server password";

    private sealed record Setup(MainWindow Window, HostSetupFlow Host, FakeLocalServerHost Server, FakeManagement Management,
        FakeServerApi Api, ConnectionStore Store, AppModeStore Modes);

    private static Setup Create(StoredConnection? saved = null, AppMode? mode = null)
    {
        var api = new FakeServerApi { ManagementSetupRequired = saved is null };
        var store = new ConnectionStore(new MemorySecretStore());
        if (saved is not null) store.Save(saved);
        var modes = new AppModeStore(Path.Combine(Path.GetTempPath(), "aurelia-desktop-mode-" + Guid.NewGuid().ToString("N"), "app-mode.json"));
        if (mode is { } chosen) modes.Save(chosen);
        var server = new FakeLocalServerHost { SetUp = saved is not null };
        var management = new FakeManagement();
        // Background work reports back on the UI thread, as in the app.
        var host = new HostSetupFlow(server, api, store, modes, (_, _) => management, "Synthetic PC", action => Dispatcher.UIThread.Post(action));
        var flow = new ConnectionFlow(api, store, new NoServerDiscovery(), "Synthetic PC", action => action(), delay: (_, _) => Task.CompletedTask);
        var window = new MainWindow(flow, _ => new FakeLibraryApi(), _ => new FakeEngineFactory(), MainWindowTests.TemporarySettings(),
            startOnOpen: false, artworkCache: _ => null, host: host, modes: modes, store: store,
            serverSettings: (connection, session) => new ServerSettingsModel(server, api, connection, session, _ => management,
                action => Dispatcher.UIThread.Post(action)))
        { Width = 1280, Height = 800 };
        window.Show();
        return new Setup(window, host, server, management, api, store, modes);
    }

    private static void Click(Window window, string name) =>
        window.FindControl<Button>(name)!.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));

    private static T Find<T>(Control root, string name) where T : Control => root.FindControl<T>(name)!;

    [AvaloniaFact]
    public async Task AFirstStartSetsUpThisComputerAsTheServer()
    {
        var setup = Create();
        var window = setup.Window;
        var view = Find<HostSetupView>(window, "HostSetup");
        await window.StartAsync();
        MainWindowTests.Settle(window, "host-choose");
        Assert.True(view.IsVisible);
        Assert.False(Find<Grid>(window, "Welcome").IsVisible);
        Assert.True(Find<StackPanel>(view, "ChooseStep").IsVisible);

        Find<Button>(view, "ChooseHostButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await MainWindowTests.WaitFor(() => setup.Host.ShowsOwnerSetup);
        MainWindowTests.Settle(window, "host-owner");
        Assert.Equal(AppMode.Host, setup.Modes.Load());
        Assert.True(Find<StackPanel>(view, "OwnerStep").IsVisible);

        Find<TextBox>(view, "SetupPassword").Text = Password;
        Find<TextBox>(view, "SetupConfirmation").Text = "a different password";
        Find<Button>(view, "SetupButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await MainWindowTests.WaitFor(() => setup.Host.HasError);
        Assert.Equal("The passwords do not match.", Find<TextBlock>(view, "ErrorText").Text);
        Find<TextBox>(view, "SetupConfirmation").Text = Password;
        Find<Button>(view, "SetupButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await MainWindowTests.WaitFor(() => setup.Host.ShowsCreatePin);
        MainWindowTests.Settle(window, "host-pin");
        Assert.Equal("", Find<TextBox>(view, "SetupPassword").Text);
        Assert.Contains("setup Synthetic PC Server", setup.Server.Calls[^1], StringComparison.Ordinal);
        // The password from setup confirms the PIN, so it is not asked again.
        Assert.False(Find<TextBox>(view, "PinPassword").IsVisible);
        Assert.True(setup.Store.Load()!.LocalHost);

        Find<TextBox>(view, "NewPin").Text = "5682";
        Find<TextBox>(view, "NewPinConfirmation").Text = "5682";
        Find<Button>(view, "PinButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await MainWindowTests.WaitFor(() => setup.Host.ShowsStorage);
        Assert.Contains("initialize 5682", setup.Api.Calls);

        view.FolderSource = () => Task.FromResult<IReadOnlyList<string>>([@"D:\Media\Movies", @"E:\TV Shows"]);
        Find<Button>(view, "ChooseFoldersButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await MainWindowTests.WaitFor(() => setup.Host.Locations.Count == 2);
        MainWindowTests.Settle(window, "host-storage");
        Assert.Equal(2, Find<ItemsControl>(view, "Locations").ItemCount);

        setup.Management.ScanPollsUntilDone = 2;
        Find<Button>(view, "ImportButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await MainWindowTests.WaitFor(() => setup.Host.ShowsScanning);
        MainWindowTests.Settle(window, "host-scanning");
        Assert.Equal(2, setup.Management.Calls.Count(call => call.StartsWith("add ", StringComparison.Ordinal)));
        Assert.Equal(2, setup.Management.Calls.Count(call => call.StartsWith("scan ", StringComparison.Ordinal)));

        // When the scan is done the owner's library opens, with Server Settings in the sidebar.
        for (var attempt = 0; attempt < 100 && !window.Flow.ShowsLibrary; attempt++)
        {
            Dispatcher.UIThread.RunJobs();
            await Task.Delay(50);
        }
        await MainWindowTests.WaitFor(() => window.LibraryModel?.Rows.Count > 0);
        MainWindowTests.Settle(window, "host-library");
        var library = Find<LibraryView>(window, "Library");
        Assert.True(library.IsVisible);
        Assert.False(view.IsVisible);
        Assert.True(Find<Button>(library, "ServerSettingsButton").IsVisible);
    }

    [AvaloniaFact]
    public async Task ALaterStartGoesToTheProfilesAndARestartComesBack()
    {
        var local = FakeServerApi.Saved() with { Address = new Uri("https://127.0.0.1:43111"), LocalHost = true };
        var setup = Create(local, AppMode.Host);
        var window = setup.Window;
        await window.StartAsync();
        await MainWindowTests.WaitFor(() => window.Flow.ShowsProfiles);
        MainWindowTests.Settle(window, "host-profiles");
        Assert.True(Find<Button>(window, "AnotherServerButton").IsVisible);

        await window.Flow.ChooseProfileAsync(FakeServerApi.Owner);
        MainWindowTests.Settle(window, "host-pin-entry");
        Assert.True(Find<Button>(window, "ForgotPinButton").IsVisible);
        await window.Flow.SubmitPinAsync("5682");
        await MainWindowTests.WaitFor(() => window.LibraryModel is not null);

        // The server restarts: its profile sessions end, so the app waits and shows the profiles again.
        setup.Server.Move(LocalServerState.Restarting, "Aurelia Server stopped unexpectedly. Restarting…");
        MainWindowTests.Settle(window, "host-restarting");
        Assert.True(Find<HostSetupView>(window, "HostSetup").IsVisible);
        Assert.Null(window.LibraryModel);
        setup.Server.Move(LocalServerState.Running);
        await MainWindowTests.WaitFor(() => window.Flow.ShowsProfiles);
        Assert.False(Find<HostSetupView>(window, "HostSetup").IsVisible);

        // A server that cannot recover asks the person.
        setup.Server.Move(LocalServerState.Failed, "Aurelia Server stopped repeatedly. Choose Try Again.");
        MainWindowTests.Settle(window, "host-failed");
        Assert.True(setup.Host.ShowsFailed);
        Find<Button>(Find<HostSetupView>(window, "HostSetup"), "RetryButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await MainWindowTests.WaitFor(() => window.Flow.ShowsProfiles);
    }

    [AvaloniaFact]
    public async Task AForgottenOwnerPinIsResetWithTheServerPassword()
    {
        var local = FakeServerApi.Saved() with { Address = new Uri("https://127.0.0.1:43111"), LocalHost = true };
        var setup = Create(local, AppMode.Host);
        var window = setup.Window;
        await window.StartAsync();
        await MainWindowTests.WaitFor(() => window.Flow.ShowsProfiles);
        await window.Flow.ChooseProfileAsync(FakeServerApi.Owner);
        Click(window, "ForgotPinButton");
        var view = Find<HostSetupView>(window, "HostSetup");
        MainWindowTests.Settle(window, "host-reset-pin");
        Assert.True(Find<StackPanel>(view, "ResetStep").IsVisible);
        Find<TextBox>(view, "ResetPassword").Text = Password;
        Find<TextBox>(view, "ResetPin").Text = "2468";
        Find<TextBox>(view, "ResetPinConfirmation").Text = "2468";
        Find<Button>(view, "ResetButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await MainWindowTests.WaitFor(() => window.Flow.ShowsProfiles);
        Assert.Contains("reset 2468", setup.Server.Calls);
    }

    [AvaloniaFact]
    public async Task ConnectingElsewhereStopsThisComputersServer()
    {
        var local = FakeServerApi.Saved() with { Address = new Uri("https://127.0.0.1:43111"), LocalHost = true };
        var setup = Create(local, AppMode.Host);
        var window = setup.Window;
        await window.StartAsync();
        await MainWindowTests.WaitFor(() => window.Flow.ShowsProfiles);
        Click(window, "AnotherServerButton");
        await MainWindowTests.WaitFor(() => window.Flow.ShowsConnect);
        MainWindowTests.Settle(window, "host-connect-elsewhere");
        Assert.Equal(LocalServerState.Stopped, setup.Server.State);
        Assert.Equal(AppMode.Client, setup.Modes.Load());
        Assert.Null(setup.Store.Load());
        Assert.True(Find<Button>(window, "SetUpHereButton").IsVisible);
    }

    [AvaloniaFact]
    public async Task ANetworkTrialKeepsServerSettingsOpenThroughTheRestart()
    {
        var local = FakeServerApi.Saved() with { Address = new Uri("https://127.0.0.1:43111"), LocalHost = true };
        var setup = Create(local, AppMode.Host);
        var window = setup.Window;
        await window.StartAsync();
        await MainWindowTests.WaitFor(() => window.Flow.ShowsProfiles);
        await window.Flow.ChooseProfileAsync(FakeServerApi.Owner);
        await window.Flow.SubmitPinAsync("5682");
        await MainWindowTests.WaitFor(() => window.LibraryModel is not null);
        var library = Find<LibraryView>(window, "Library");
        Find<Button>(library, "ServerSettingsButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        var settings = window.SettingsWindow;
        Assert.NotNull(settings);
        var model = (ServerSettingsModel)settings.DataContext!;
        await MainWindowTests.WaitFor(() => model.IsUnlocked && !model.IsBusy);

        model.ServerName = "Renamed PC Server";
        Click(settings, "ApplyNetworkButton");
        await MainWindowTests.WaitFor(() => model.IsTrialPending);
        // The trial restarts the server: the library waits, the settings stay open for the confirmation.
        setup.Server.Move(LocalServerState.Restarting);
        MainWindowTests.Settle(window, "host-trial-restarting");
        Assert.Null(window.LibraryModel);
        Assert.Same(settings, window.SettingsWindow);
        setup.Server.Move(LocalServerState.Running);
        await MainWindowTests.WaitFor(() => window.Flow.ShowsProfiles);

        Find<TextBox>(settings, "ConfirmPin").Text = "5682";
        Find<TextBox>(settings, "ConfirmPassword").Text = Password;
        Click(settings, "ConfirmButton");
        await MainWindowTests.WaitFor(() => !model.IsTrialPending && !model.IsBusy);
        await MainWindowTests.WaitFor(() => window.LibraryModel is not null);
        Assert.Contains("confirm", setup.Management.Calls);
        Assert.True(window.Flow.ShowsLibrary);
        settings.Close();
    }

    [AvaloniaFact]
    public async Task ServerSettingsShowGeneralStorageAndDevices()
    {
        var connection = FakeServerApi.Saved() with { Address = new Uri("https://127.0.0.1:43111"), LocalHost = true };
        var server = new FakeLocalServerHost { SetUp = true };
        server.Move(LocalServerState.Running);
        var management = new FakeManagement { Locked = true };
        var session = new ProfileSessionResponse(new UserSummary(FakeServerApi.Owner.Id, "Alex", UserRole.Owner, DateTimeOffset.UtcNow),
            Guid.NewGuid(), "synthetic-profile-token-0123456789-abcdef", DateTimeOffset.UtcNow.AddHours(12));
        var replaced = new List<ProfileSessionResponse>();
        var model = new ServerSettingsModel(server, new FakeServerApi(), connection, session, _ => management,
            action => Dispatcher.UIThread.Post(action));
        model.SessionReplaced += replaced.Add;
        var window = new ServerSettingsWindow(model) { Width = 900, Height = 640 };
        window.Show();
        await MainWindowTests.WaitFor(() => model.IsLocked && !model.IsBusy);
        MainWindowTests.Settle(window, "settings-locked");
        Assert.True(Find<Border>(window, "UnlockCard").IsVisible);

        Find<TextBox>(window, "UnlockPassword").Text = "wrong password";
        Click(window, "UnlockButton");
        await MainWindowTests.WaitFor(() => model.HasError);
        Assert.Equal("The Server Password is not correct.", model.Error);
        Find<TextBox>(window, "UnlockPassword").Text = Password;
        Click(window, "UnlockButton");
        await MainWindowTests.WaitFor(() => model.IsUnlocked && !model.IsBusy);
        MainWindowTests.Settle(window, "settings-general");
        Assert.Equal("Running", Find<TextBlock>(window, "StateText").Text);
        Assert.Equal("https://192.168.1.40:43111", Find<SelectableTextBlock>(window, "AddressText").Text);
        Assert.Equal("AAAA-AAAA-AAAA-AAAA-AAAA-AAAA", Find<SelectableTextBlock>(window, "FingerprintText").Text);

        // Turning network access off needs an explicit confirmation, then a trial with PIN and password.
        model.LanAccessEnabled = false;
        MainWindowTests.Settle(window, "settings-network-off");
        Assert.True(Find<CheckBox>(window, "DisconnectConfirmation").IsVisible);
        Click(window, "ApplyNetworkButton");
        await MainWindowTests.WaitFor(() => model.HasError);
        model.ConfirmDisconnect = true;
        Click(window, "ApplyNetworkButton");
        await MainWindowTests.WaitFor(() => model.IsTrialPending);
        MainWindowTests.Settle(window, "settings-network-trial");
        Assert.Contains("trial Synthetic PC Server false True", management.Calls);
        Find<TextBox>(window, "ConfirmPin").Text = "5682";
        Find<TextBox>(window, "ConfirmPassword").Text = Password;
        server.Move(LocalServerState.Restarting);
        server.Move(LocalServerState.Running);
        Click(window, "ConfirmButton");
        await MainWindowTests.WaitFor(() => !model.IsTrialPending && !model.IsBusy);
        Assert.Contains("confirm", management.Calls);
        Assert.Single(replaced);

        model.Section = SettingsSection.Storage;
        MainWindowTests.Settle(window, "settings-storage");
        Assert.Equal(2, Find<ItemsControl>(window, "StorageList").ItemCount);
        management.ScanPollsUntilDone = 10;
        window.FolderSource = () => Task.FromResult<string?>(@"F:\Kids");
        Click(window, "AddStorageButton");
        await MainWindowTests.WaitFor(() => model.Storage.Count == 3);
        MainWindowTests.Settle(window, "settings-storage-added");
        Assert.Contains(@"add F:\Kids Automatic", management.Calls);
        Assert.Contains(model.Storage, row => row.IsScanning);

        model.Section = SettingsSection.Devices;
        model.DeviceCode = "4815 1623";
        Click(window, "LookUpButton");
        await MainWindowTests.WaitFor(() => model.HasPendingDevice);
        MainWindowTests.Settle(window, "settings-devices");
        Assert.Equal("Living Room Apple TV wants to connect to this server.", Find<TextBlock>(window, "PendingDevice").Text);
        Assert.Equal(2, Find<ItemsControl>(window, "DeviceList").ItemCount);
        Click(window, "ApproveButton");
        await MainWindowTests.WaitFor(() => !model.HasPendingDevice);
        Assert.Contains("approve", management.Calls);
        Assert.Equal("Living Room Apple TV can now connect.", model.Notice);
        window.Close();
    }
}
