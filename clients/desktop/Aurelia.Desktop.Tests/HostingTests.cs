using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless.XUnit;
using Avalonia.Interactivity;
using Avalonia.Threading;
using Aurelia.Contracts;
using Aurelia.Desktop.Core;
using Aurelia.Desktop.Views;
using Xunit;

namespace Aurelia.Desktop.Tests;

/// <summary>
/// When the server runs: keeping it running in the notification area, starting at sign-in, keeping the
/// PC awake, one Aurelia per person, and Quit. Windows is scripted; nothing is registered on this computer.
/// </summary>
public sealed class HostingTests
{
    private const string Password = "synthetic server password";

    private static HostingPreferencesStore TemporaryStore() =>
        new(Path.Combine(Path.GetTempPath(), "aurelia-desktop-hosting-" + Guid.NewGuid().ToString("N"), "hosting.json"));

    [Fact]
    public void ANewServerKeepsRunningAndStartsAtSignInUntilThePersonChangesIt()
    {
        var server = new FakeLocalServerHost();
        var store = TemporaryStore();
        var system = new FakeSystemHosting();
        var hosting = new HostingController(server, store, system, new HostingPreferences(true, true, false), action => action());

        // Nothing is registered before the server is set up.
        server.Move(LocalServerState.SetupRequired);
        Assert.Null(store.Load());
        Assert.Equal(SignInStart.Off, system.StartAtSignIn);
        Assert.False(hosting.RunsInBackground);
        Assert.Equal("Aurelia Server is waiting for setup", hosting.StatusText);

        server.SetUp = true;
        server.Move(LocalServerState.Running);
        Assert.Equal(new HostingPreferences(true, true, false), store.Load());
        Assert.Equal(SignInStart.On, system.StartAtSignIn);
        Assert.True(hosting.RunsInBackground);
        Assert.Equal("Aurelia Server is running", hosting.StatusText);

        // Awake only while the server runs.
        Assert.False(system.Awake);
        hosting.KeepAwake = true;
        Assert.True(system.Awake);
        server.Move(LocalServerState.Stopped);
        Assert.False(system.Awake);
        Assert.False(hosting.RunsInBackground);
        server.Move(LocalServerState.Running);
        Assert.True(system.Awake);

        // Starting at sign-in needs a server that keeps running.
        hosting.KeepRunning = false;
        Assert.False(hosting.StartAtSignIn);
        Assert.Equal(SignInStart.Off, system.StartAtSignIn);
        hosting.StartAtSignIn = true;
        Assert.False(hosting.StartAtSignIn);
        Assert.False(hosting.RunsInBackground);
        hosting.KeepRunning = true;
        hosting.StartAtSignIn = true;
        Assert.Equal(SignInStart.On, system.StartAtSignIn);
        Assert.Equal(new HostingPreferences(true, true, true), store.Load());

        // Turned off in Task Manager: Aurelia follows and does not turn it on again by itself.
        system.TurnOffInWindows();
        server.Move(LocalServerState.Restarting);
        server.Move(LocalServerState.Running);
        Assert.False(hosting.StartAtSignIn);
        Assert.Equal(SignInStart.TurnedOffInWindows, system.StartAtSignIn);
        Assert.False(store.Load()!.StartAtSignIn);
        hosting.StartAtSignIn = true;
        Assert.Equal(SignInStart.On, system.StartAtSignIn);

        // Connecting elsewhere: Windows no longer starts Aurelia, and the PC may sleep.
        hosting.HostingEnded();
        Assert.Equal(SignInStart.Off, system.StartAtSignIn);
        Assert.False(system.Awake);

        // A later start of the app keeps the saved choices instead of the defaults.
        var later = new HostingController(server, store, system, new HostingPreferences(false, false, false), action => action());
        Assert.True(later.KeepRunning);
        Assert.True(later.KeepAwake);
    }

    [Fact]
    public void StartRequestsComeFromTheCommandLine()
    {
        Assert.Equal(StartRequest.Open, StartRequests.From([]));
        Assert.Equal(StartRequest.Background, StartRequests.From(["--background"]));
        Assert.Equal(StartRequest.Quit, StartRequests.From(["--background", "--QUIT"]));
    }

    [Fact]
    public async Task OnlyOneAureliaRunsAndLaterStartsHandItTheirRequest()
    {
        var name = "AureliaDesktopTest" + Guid.NewGuid().ToString("N")[..12];
        var cancellation = TestContext.Current.CancellationToken;
        Assert.False(await AppInstance.SendAsync(StartRequest.Open, TimeSpan.FromMilliseconds(500), name));

        // The running Aurelia holds its claim on its own thread, as Program.Main does.
        using var claimed = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        AppInstance? first = null;
        var owner = new Thread(() =>
        {
            first = AppInstance.TryClaim(name);
            claimed.Set();
            release.Wait(cancellation);
            first?.Dispose();
        });
        owner.Start();
        claimed.Wait(cancellation);
        Assert.NotNull(first);
        Assert.Null(AppInstance.TryClaim(name));

        var requests = new List<StartRequest>();
        first.Listen(request =>
        {
            lock (requests) requests.Add(request);
            return Task.CompletedTask;
        });
        Assert.True(await AppInstance.SendAsync(StartRequest.Open, TimeSpan.FromSeconds(10), name));
        Assert.True(await AppInstance.SendAsync(StartRequest.Quit, TimeSpan.FromSeconds(10), name));
        Assert.Equal([StartRequest.Open, StartRequest.Quit], requests);

        release.Set();
        owner.Join();
        using var next = AppInstance.TryClaim(name);
        Assert.NotNull(next);
    }

    private sealed record Hosted(MainWindow Window, FakeLocalServerHost Server, HostingController Hosting, FakeSystemHosting System,
        HostSetupFlow Host);

    private static async Task<Hosted> StartHostedAsync()
    {
        var local = FakeServerApi.Saved() with { Address = new Uri("https://127.0.0.1:43111"), LocalHost = true };
        var api = new FakeServerApi();
        var store = new ConnectionStore(new MemorySecretStore());
        store.Save(local);
        var modes = new AppModeStore(Path.Combine(Path.GetTempPath(), "aurelia-desktop-mode-" + Guid.NewGuid().ToString("N"), "app-mode.json"));
        modes.Save(AppMode.Host);
        var server = new FakeLocalServerHost { SetUp = true };
        var system = new FakeSystemHosting();
        var hosting = new HostingController(server, TemporaryStore(), system, new HostingPreferences(true, true, false),
            action => Dispatcher.UIThread.Post(action));
        var management = new FakeManagement();
        var host = new HostSetupFlow(server, api, store, modes, (_, _) => management, "Synthetic PC", action => Dispatcher.UIThread.Post(action));
        var flow = new ConnectionFlow(api, store, new NoServerDiscovery(), "Synthetic PC", action => action(), delay: (_, _) => Task.CompletedTask);
        var window = new MainWindow(flow, _ => new FakeLibraryApi(), _ => new FakeEngineFactory(), MainWindowTests.TemporarySettings(),
            startOnOpen: false, artworkCache: _ => null, host: host, modes: modes, store: store,
            serverSettings: (connection, session) => new ServerSettingsModel(server, api, connection, session, _ => management,
                action => Dispatcher.UIThread.Post(action), hosting),
            hosting: hosting)
        { Width = 1280, Height = 800 };
        window.Show();
        await window.StartAsync();
        await MainWindowTests.WaitFor(() => window.Flow.ShowsProfiles);
        return new Hosted(window, server, hosting, system, host);
    }

    [AvaloniaFact]
    public async Task ClosingTheWindowKeepsTheServerRunningUntilAureliaQuits()
    {
        var hosted = await StartHostedAsync();
        var window = hosted.Window;
        Assert.Equal(SignInStart.On, hosted.System.StartAtSignIn);

        // The window goes to the notification area; the server keeps running for the Apple TV.
        window.Close();
        await MainWindowTests.WaitFor(() => !window.IsVisible);
        Assert.Equal(LocalServerState.Running, hosted.Server.State);
        Assert.DoesNotContain("stop", hosted.Server.Calls);

        // It opens again where it was, without starting the server a second time.
        window.Show();
        await window.StartAsync();
        Assert.True(window.Flow.ShowsProfiles);
        Assert.Single(hosted.Server.Calls, call => call == "start");

        // Without keeping it running, closing the window quits Aurelia and stops the server cleanly.
        hosted.Hosting.KeepRunning = false;
        window.Close();
        await MainWindowTests.WaitFor(() => hosted.Server.State == LocalServerState.Stopped);
        Assert.Contains("stop", hosted.Server.Calls);
        Assert.False(window.IsVisible);
    }

    [AvaloniaFact]
    public async Task TheNotificationAreaIconOpensAndQuitsAurelia()
    {
        var hosted = await StartHostedAsync();
        var shutDown = false;
        using var shell = new DesktopShell(Application.Current!, hosted.Window, () => shutDown = true);
        Assert.True(shell.ShowsTrayIcon);
        Assert.Equal("Aurelia Server is running", shell.TrayStatus);

        hosted.Window.Close();
        await MainWindowTests.WaitFor(() => !hosted.Window.IsVisible);
        Assert.True(shell.ShowsTrayIcon);
        await shell.HandleAsync(StartRequest.Open);
        Assert.True(hosted.Window.IsVisible);

        hosted.Server.Move(LocalServerState.Restarting);
        Dispatcher.UIThread.RunJobs();
        Assert.Equal("Aurelia Server is starting…", shell.TrayStatus);
        hosted.Server.Move(LocalServerState.Running);

        // Quit, as the installer asks before it replaces the app: the server stops, then the app ends.
        await shell.HandleAsync(StartRequest.Quit);
        Assert.Equal(LocalServerState.Stopped, hosted.Server.State);
        Assert.True(shell.HasEnded);
        Assert.False(shell.ShowsTrayIcon);
        await MainWindowTests.WaitFor(() => shutDown);
    }

    [AvaloniaFact]
    public async Task ServerSettingsChooseWhenTheServerRuns()
    {
        var connection = FakeServerApi.Saved() with { Address = new Uri("https://127.0.0.1:43111"), LocalHost = true };
        var server = new FakeLocalServerHost { SetUp = true };
        var system = new FakeSystemHosting();
        var hosting = new HostingController(server, TemporaryStore(), system, new HostingPreferences(true, true, false),
            action => Dispatcher.UIThread.Post(action));
        server.Move(LocalServerState.Running);
        Dispatcher.UIThread.RunJobs();
        var session = new ProfileSessionResponse(new UserSummary(FakeServerApi.Owner.Id, "Alex", UserRole.Owner, DateTimeOffset.UtcNow),
            Guid.NewGuid(), "synthetic-profile-token-0123456789-abcdef", DateTimeOffset.UtcNow.AddHours(12));
        var model = new ServerSettingsModel(server, new FakeServerApi(), connection, session, _ => new FakeManagement(),
            action => Dispatcher.UIThread.Post(action), hosting, publicNetwork: () => true);
        var window = new ServerSettingsWindow(model) { Width = 900, Height = 900 };
        window.Show();
        await MainWindowTests.WaitFor(() => model.IsUnlocked && !model.IsBusy);
        MainWindowTests.Settle(window, "settings-hosting");

        // Windows marks this network Public: the owner is told how to let devices in.
        Assert.True(window.FindControl<StackPanel>("PublicNetworkHint")!.IsVisible);
        Assert.True(window.FindControl<Border>("HostingGroup")!.IsVisible);
        var keepRunning = window.FindControl<CheckBox>("KeepRunningToggle")!;
        var signIn = window.FindControl<CheckBox>("StartAtSignInToggle")!;
        var awake = window.FindControl<CheckBox>("KeepAwakeToggle")!;
        Assert.True(keepRunning.IsChecked);
        Assert.True(signIn.IsChecked);
        Assert.False(awake.IsChecked);
        Assert.Equal(SignInStart.On, system.StartAtSignIn);

        awake.IsChecked = true;
        Assert.True(system.Awake);
        keepRunning.IsChecked = false;
        Dispatcher.UIThread.RunJobs();
        Assert.False(signIn.IsChecked);
        Assert.False(signIn.IsEnabled);
        Assert.Equal(SignInStart.Off, system.StartAtSignIn);
        Assert.Equal("The server stops when you close Aurelia.", window.FindControl<TextBlock>("HostingExplanation")!.Text);
        MainWindowTests.Settle(window, "settings-hosting-off");
        window.Close();
    }

    [AvaloniaFact]
    public async Task ANewOwnerLearnsThatTheServerKeepsRunning()
    {
        var api = new FakeServerApi { ManagementSetupRequired = true };
        var store = new ConnectionStore(new MemorySecretStore());
        var modes = new AppModeStore(Path.Combine(Path.GetTempPath(), "aurelia-desktop-mode-" + Guid.NewGuid().ToString("N"), "app-mode.json"));
        var server = new FakeLocalServerHost();
        var hosting = new HostingController(server, TemporaryStore(), new FakeSystemHosting(), new HostingPreferences(true, true, false),
            action => Dispatcher.UIThread.Post(action));
        var host = new HostSetupFlow(server, api, store, modes, (_, _) => new FakeManagement(), "Synthetic PC", action => Dispatcher.UIThread.Post(action));
        var flow = new ConnectionFlow(api, store, new NoServerDiscovery(), "Synthetic PC", action => action(), delay: (_, _) => Task.CompletedTask);
        var window = new MainWindow(flow, _ => new FakeLibraryApi(), _ => new FakeEngineFactory(), MainWindowTests.TemporarySettings(),
            startOnOpen: false, artworkCache: _ => null, host: host, modes: modes, store: store, hosting: hosting)
        { Width = 1280, Height = 800 };
        window.Show();
        await host.ChooseHostAsync();
        await MainWindowTests.WaitFor(() => host.ShowsOwnerSetup);
        await host.SetUpAsync(Password, Password);
        await host.CreatePinAsync("5682", "5682", null);
        await MainWindowTests.WaitFor(() => host.ShowsStorage);
        var view = window.FindControl<HostSetupView>("HostSetup")!;
        MainWindowTests.Settle(window, "host-storage-background");
        Assert.True(view.FindControl<TextBlock>("BackgroundNote")!.IsVisible);
        Assert.Contains("keeps running", host.BackgroundNote, StringComparison.Ordinal);
    }
}
