using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Hosting;
using Aurelia.Linux.Core.Platform;
using Aurelia.Linux.Core.Settings;
using Aurelia.Linux.Management;
using Aurelia.Linux.Settings;
using Aurelia.Linux.Views;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.VisualTree;
using Xunit;

using static Aurelia.Linux.Tests.TestWindows;

namespace Aurelia.Linux.Tests;

/// <summary>The production hosting screens, with an invented server and no subprocess or desktop access.</summary>
public sealed class HostingScreenTests
{
    private const string Password = "synthetic server password";

    internal static StoredServer Saved() => new(FakeServer.ServerId, "This PC's Server", new Uri("https://127.0.0.1:43111"),
        FakeServer.Fingerprint, "synthetic-device-token-0000000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30), LocallyManaged: true);

    private static string Json<T>(T value) => JsonSerializer.Serialize(value, AureliaJson.Options);

    private static FakeServer WithUnlock(FakeServer server) => server.Answer("POST", $"/api/v1/profiles/{FakeLibrary.OwnerId}/unlock",
        Json(new ProfileSessionResponse(new UserSummary(FakeLibrary.OwnerId, "Lucas", UserRole.Owner, DateTimeOffset.UtcNow), Guid.NewGuid(),
            "synthetic-profile-token-00000000000000000001", DateTimeOffset.UtcNow.AddHours(12))));

    private static MainWindow Show(ScriptedHost host, FakeServer server, MemoryCredentialStore? keyring = null, IHostingSystem? system = null)
    {
        var settings = new MemorySettingsStore();
        settings.Write(AppFlow.OperatingModeKey, "host");
        var services = AppServices.ForTests(settings, transport: server, credentials: keyring, host: host);
        if (system is not null) services = services with { HostingSystem = system };
        var window = TestWindows.Show(services);
        FakeLibrary.Pump(() => window.Flow.Screen == AppScreen.HostSetup && window.Hosting?.Phase != HostPhase.Starting
            || window.Flow.Screen == AppScreen.ProfilePicker);
        return window;
    }

    private static IEnumerable<T> Visible<T>(Control root) where T : Control =>
        root.GetVisualDescendants().OfType<T>().Where(c => c.IsEffectivelyVisible);

    private static Button Button(Control root, string text) => Visible<Button>(root).Single(b => b.Content as string == text);

    private static TextBox Field(Control root, string name) => Visible<TextBox>(root).Single(t => AutomationProperties.GetName(t) == name);

    private static bool Shows(Control root, string text) => Visible<TextBlock>(root).Any(t => t.Text?.Contains(text, StringComparison.Ordinal) == true);

    private static void Click(Button button)
    {
        button.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Avalonia.Controls.Button.ClickEvent));
        FakeLibrary.Pump(() => false, rounds: 10);
    }

    private static void Snapshot(Control shown, string name)
    {
        using var frame = HostOf(shown).CaptureRenderedFrame()!;
        TestWindows.SaveSnapshot(frame, name);
    }

    [AvaloniaFact]
    public void SetsUpThisPcOpensItsOwnerAndOffersTheFirstStorageLocations()
    {
        var server = WithUnlock(FakeLibrary.Create(pictures: false))
            .Replace("GET", "/api/v1/profiles", """{"formatVersion":2,"minimumClientVersion":"1.0","managementSetupRequired":true,"profiles":[]}""")
            .Answer("POST", "/api/v1/profiles/initialize", "{}");
        var host = new ScriptedHost(LocalServerState.SetupRequired);
        var keyring = new MemoryCredentialStore();
        var window = Show(host, server, keyring);
        Assert.True(Shows(window, "Set Up This PC"));
        var next = Button(window, "Continue");
        Assert.False(next.IsEnabled);
        Field(window, "Server Password").Text = "short";
        FakeLibrary.Pump(() => false, rounds: 3);
        Assert.False(next.IsEnabled);
        Assert.True(Shows(window, "Use at least 12 characters."));
        Field(window, "Server Password").Text = Password;
        // The names are filled in and visible at once; there is nothing hidden under "Advanced".
        Assert.Empty(Visible<Expander>(window));
        Assert.False(string.IsNullOrWhiteSpace(Field(window, "Owner Name").Text));
        Field(window, "Server Name").Text = "Synthetic Studio";
        Field(window, "Owner Name").Text = "Lucas";
        FakeLibrary.Pump(() => false, rounds: 3);
        Assert.True(next.IsEnabled);
        Snapshot(window, "host-owner-setup");
        Click(next);
        Assert.Equal(("Synthetic Studio", "Lucas", Password, 43111), host.Setup);
        Assert.True(keyring.Server?.LocallyManaged);
        Assert.Equal(AppScreen.ProfilePicker, window.Flow.Screen);
        Assert.True(window.Session.NeedsInitialLibrarySetup);

        server.Replace("GET", "/api/v1/profiles", Json(new ProfilePickerResponse(2, "1.0", false,
            [new WatchingProfile(FakeLibrary.OwnerId, "Lucas", UserRole.Owner, false, true)])));
        Field(window, "Server Password").Text = Password;
        Field(window, "Owner PIN").Text = "2468";
        Field(window, "Confirm PIN").Text = "2468";
        Click(Button(window, "Set Up Profiles"));
        Assert.Equal(AppScreen.InitialLibrarySetup, window.Flow.Screen);
        Assert.Equal(FakeLibrary.OwnerId, window.Session.Profile?.User.Id);
        Assert.Contains("\"pin\":\"2468\"", server.Bodies[$"POST /api/v1/profiles/{FakeLibrary.OwnerId}/unlock"], StringComparison.Ordinal);
        var storage = Assert.IsType<InitialLibrarySetupView>(window.CurrentScreen);
        Assert.True(Shows(window, "Choose Storage Locations"));
        Assert.False(Button(window, "Analyze and Preview").IsEnabled);
        storage.Add(["/synthetic/Movies", "/synthetic/Shows", "/synthetic/Movies"]);
        Assert.Equal(2, storage.Drafts.Count);
        Assert.True(Button(window, "Analyze and Preview").IsEnabled);
        Click(Visible<Button>(window).Single(b => AutomationProperties.GetName(b) == "Remove Movies"));
        Assert.Equal("/synthetic/Shows", Assert.Single(storage.Drafts).Path);
        Snapshot(window, "host-first-storage");
        Click(Button(window, "Skip for Now"));
        Assert.Equal(AppScreen.Library, window.Flow.Screen);
        Assert.False(window.Session.NeedsInitialLibrarySetup);
        Assert.DoesNotContain("POST /api/v1/libraries", server.Requests);
        window.Quit();
    }

    [AvaloniaFact]
    public void WelcomeBackRejectsThePasswordThenRemembersTheLocalConnection()
    {
        var host = new ScriptedHost(LocalServerState.Running);
        var keyring = new MemoryCredentialStore();
        var window = Show(host, FakeLibrary.Create(pictures: false), keyring);
        Assert.True(Shows(window, "Welcome Back"));
        Field(window, "Owner Name").Text = "Lucas";
        Field(window, "Server Password").Text = "wrong";
        Click(Button(window, "Sign In"));
        Assert.True(Shows(window, "The owner name or Server Password is not correct."));
        Assert.Null(keyring.Server);
        Snapshot(window, "host-welcome-back");
        Field(window, "Server Password").Text = Password;
        Click(Button(window, "Sign In"));
        Assert.Equal(AppScreen.ProfilePicker, window.Flow.Screen);
        Assert.True(keyring.Server?.LocallyManaged);
        Assert.Equal(1, host.Starts);
        Assert.False(window.Session.NeedsInitialLibrarySetup);
        window.Quit();
    }

    [AvaloniaFact]
    public void FirstStorageLocationsWaitForTheImportPreviewToBeConfirmed()
    {
        var libraryId = Guid.Parse("b0000000-0000-4000-8000-000000000001");
        var previewId = Guid.Parse("d0000000-0000-4000-8000-000000000001");
        var library = new LibrarySummary(libraryId, "Movies", "/synthetic/Movies", LibraryKind.Automatic, LibraryAvailability.Available,
            DateTimeOffset.UtcNow, null, null, null, ImportPreviewRequired: true);
        var confirmPath = $"/api/v1/libraries/{libraryId}/import-preview/{previewId}/confirm";
        var server = ManagementScreenTests.Server()
            .Answer("POST", "/api/v1/libraries", Json(library))
            .Replace("GET", "/api/v1/libraries", Json(new[] { library }))
            .Answer("GET", "/api/v1/libraries", "[]")
            .Answer("POST", confirmPath, "{}");
        var window = Show(new ScriptedHost(LocalServerState.Running), server, new MemoryCredentialStore { Server = Saved() });
        window.Session.NeedsInitialLibrarySetup = true;
        window.Session.OpenProfile(new ProfileSession(new UserSummary(FakeLibrary.OwnerId, "Lucas", UserRole.Owner, DateTimeOffset.UtcNow),
            Guid.NewGuid(), "synthetic-profile-token-00000000000000000001", DateTimeOffset.UtcNow.AddHours(12)));
        var storage = Assert.IsType<InitialLibrarySetupView>(window.CurrentScreen);
        storage.Add(["/synthetic/Movies"]);
        FakeLibrary.Pump(() => false, rounds: 3);
        Click(Button(window, "Analyze and Preview"));
        Assert.True(storage.Sheets.IsShowing);
        Assert.True(Shows(window, "Gamma Lights"));
        Assert.Contains("\"requireImportPreview\":true", server.Bodies["POST /api/v1/libraries"], StringComparison.Ordinal);
        Assert.Empty(storage.Drafts);
        Assert.DoesNotContain("POST " + confirmPath, server.Requests);
        Assert.Equal(AppScreen.InitialLibrarySetup, window.Flow.Screen);
        Snapshot(window, "host-first-import-preview");
        Click(Button(window, "Import Recognized Items"));
        Assert.Contains("POST " + confirmPath, server.Requests);
        Assert.Equal(AppScreen.Library, window.Flow.Screen);
        Assert.False(window.Session.NeedsInitialLibrarySetup);
        window.Quit();
    }

    [AvaloniaFact]
    public void ForgotPinChecksConfirmationAndPasswordBeforeReturningToThePicker()
    {
        var host = new ScriptedHost(LocalServerState.Running);
        var window = Show(host, FakeLibrary.Create(pictures: false), new MemoryCredentialStore { Server = Saved() });
        Click(Visible<Button>(window).Single(b => AutomationProperties.GetName(b) == "Lucas"));
        Click(Button(window, "Forgot PIN?"));
        Assert.Equal(HostPhase.ResetPin, window.Hosting?.Phase);
        Assert.True(Shows(window, "Reset Owner PIN"));
        Field(window, "Server Password").Text = Password;
        Field(window, "New PIN").Text = "2468";
        Field(window, "Confirm PIN").Text = "2469";
        Click(Button(window, "Set New PIN"));
        Assert.True(Shows(window, "The PINs do not match."));
        Assert.Equal(0, host.Resets);
        Field(window, "Confirm PIN").Text = "2468";
        Field(window, "Server Password").Text = "wrong";
        Click(Button(window, "Set New PIN"));
        Assert.True(Shows(window, "The Server Password is not correct."));
        Snapshot(window, "host-reset-pin");
        Field(window, "Server Password").Text = Password;
        Click(Button(window, "Set New PIN"));
        Assert.Equal("2468", host.NewPin);
        Assert.Equal(AppScreen.ProfilePicker, window.Flow.Screen);
        Assert.Null(window.Session.Profile);
        window.Quit();
    }

    [AvaloniaFact]
    public void AServerAlreadyOnThePortOffersTheExistingServer()
    {
        var host = new ScriptedHost(LocalServerState.PortInUse);
        var window = Show(host, FakeLibrary.Create(pictures: false));
        Assert.True(Shows(window, "Aurelia Server Is Already Running"));
        Assert.Equal(1, host.Starts);
        Snapshot(window, "host-port-in-use");
        Click(Button(window, "Connect to It"));
        Assert.Equal(OperatingMode.Client, window.Flow.Mode);
        var connection = Assert.IsType<ConnectionView>(window.CurrentScreen);
        Assert.Equal("127.0.0.1", connection.Model.Address);
        window.Quit();
    }

    [AvaloniaFact]
    public void AMissingServerExplainsTheFailureAndRetries()
    {
        var host = new ScriptedHost(LocalServerState.Failed);
        var window = Show(host, FakeLibrary.Create(pictures: false));
        Assert.True(Shows(window, "Server Host Needs Attention"));
        Assert.True(Shows(window, "The bundled server is missing."));
        Snapshot(window, "host-missing-server");
        host.AfterStart = LocalServerState.SetupRequired;
        Click(Button(window, "Try Again"));
        Assert.Equal(1, host.Restarts);
        Assert.True(Shows(window, "Set Up This PC"));
        Click(Button(window, "Connect to Another Server"));
        Assert.Equal(1, host.Stops);
        Assert.Equal(AppScreen.Connection, window.Flow.Screen);
        window.Quit();
    }

    [AvaloniaFact]
    public void LocalHostingSettingsKeepLoginAndBackgroundChoicesConsistent()
    {
        var server = ManagementScreenTests.Server().Replace("GET", "/api/v1/server/capabilities",
            Json(new ServerManagementCapabilities(true, false, false, "linux", false)));
        var host = new ScriptedHost(LocalServerState.Running);
        var system = new NoHostingSystem();
        var window = Show(host, server, new MemoryCredentialStore { Server = Saved() }, system);
        window.Session.OpenProfile(new ProfileSession(new UserSummary(FakeLibrary.OwnerId, "Lucas", UserRole.Owner, DateTimeOffset.UtcNow),
            Guid.NewGuid(), "synthetic-profile-token-00000000000000000001", DateTimeOffset.UtcNow.AddHours(12)));
        FakeLibrary.Pump(() => window.Shell is not null);
        var settings = window.OpenSettings(SettingsCategory.Server);
        FakeLibrary.Pump(() => settings.Page?.GetVisualDescendants().OfType<TextBlock>().Any(t => t.Text == "When the Server Runs") == true);
        Assert.True(Shows(settings, "When the Server Runs"));
        var login = Visible<ToggleSwitch>(settings).Single(t => AutomationProperties.GetName(t) == "Start Automatically When You Log In");
        Assert.False(login.IsEffectivelyEnabled);
        var mode = Visible<ComboBox>(settings).Single(c => AutomationProperties.GetName(c) == "Run the Server");
        mode.SelectedIndex = 1;
        Assert.True(window.KeepsRunning);
        Assert.True(login.IsEffectivelyEnabled);
        login.IsChecked = true;
        Assert.True(system.StartsAtLogin);
        var awake = Visible<ToggleSwitch>(settings).Single(t => AutomationProperties.GetName(t) == "Keep This PC Awake While the Server Runs");
        awake.IsChecked = true;
        FakeLibrary.Pump(() => system.AwakeRequests > 0);
        Assert.True(system.AwakeRequests > 0);
        Snapshot(settings, "host-running-settings");
        mode.SelectedIndex = 0;
        Assert.False(window.KeepsRunning);
        Assert.False(system.StartsAtLogin);
        Assert.False(login.IsChecked);
        Assert.False(HostingSettings.Read(window.Session.Preferences.Store).StartAtSignIn);
        window.Quit();
    }

    [Fact]
    public void FirewallHintsUseTheConfiguredPortWithoutChangingTheSystem()
    {
        Assert.Contains("ufw allow 45222/tcp", HostingSettings.FirewallHint(45222, path => path == "/usr/sbin/ufw"), StringComparison.Ordinal);
        Assert.Contains("--add-port=45222/tcp", HostingSettings.FirewallHint(45222, path => path == "/usr/bin/firewall-cmd"), StringComparison.Ordinal);
        Assert.Null(HostingSettings.FirewallHint(45222, _ => false));
    }

    [Fact]
    public async Task FlatpakUsesTheDesktopPortalForLoginAndInhibition()
    {
        var folder = Path.Combine(Path.GetTempPath(), "aurelia-portal-test-" + Guid.NewGuid().ToString("N"));
        var paths = AppPaths.FromEnvironment(key => key == "HOME" ? folder : null);
        var portal = new ScriptedPortal();
        var system = new LinuxHostingSystem(paths, portal);
        await system.ConfigureBackgroundAsync(keepRunning: true, startAtLogin: true);
        Assert.True(system.StartsAtLogin);
        Assert.True(portal.Autostart);
        using (await system.KeepAwakeAsync("Synthetic host")) Assert.Equal("Synthetic host", portal.Reason);
        Assert.True(portal.Released);
        await system.ConfigureBackgroundAsync(keepRunning: false, startAtLogin: true);
        Assert.False(system.StartsAtLogin);
        Assert.False(portal.Autostart);
        Assert.False(Directory.Exists(folder));
        portal.Allow = false;
        await Assert.ThrowsAsync<InvalidOperationException>(() => system.ConfigureBackgroundAsync(true, true));
        Assert.False(system.StartsAtLogin);
    }

    [AvaloniaFact]
    public void DeniedBackgroundPermissionKeepsTheSavedHostingChoice()
    {
        var server = ManagementScreenTests.Server().Replace("GET", "/api/v1/server/capabilities",
            Json(new ServerManagementCapabilities(true, false, false, "linux", false)));
        var window = Show(new ScriptedHost(LocalServerState.Running), server, new MemoryCredentialStore { Server = Saved() }, new DeniedHostingSystem());
        window.Session.OpenProfile(new ProfileSession(new UserSummary(FakeLibrary.OwnerId, "Lucas", UserRole.Owner, DateTimeOffset.UtcNow),
            Guid.NewGuid(), "synthetic-profile-token-00000000000000000001", DateTimeOffset.UtcNow.AddHours(12)));
        FakeLibrary.Pump(() => window.Shell is not null);
        var settings = window.OpenSettings(SettingsCategory.Server);
        FakeLibrary.Pump(() => Shows(settings, "When the Server Runs"));
        Visible<ComboBox>(settings).Single(c => AutomationProperties.GetName(c) == "Run the Server").SelectedIndex = 1;
        FakeLibrary.Pump(() => Shows(settings, "Permission denied by the synthetic desktop."));
        Assert.True(Shows(settings, "Permission denied by the synthetic desktop."));
        Assert.False(HostingSettings.Read(window.Session.Preferences.Store).KeepRunning);
        Assert.False(window.KeepsRunning);
        Assert.Equal(0, Visible<ComboBox>(settings).Single(c => AutomationProperties.GetName(c) == "Run the Server").SelectedIndex);
        window.Quit();
    }

    private sealed class ScriptedPortal : IDesktopHostingPortal
    {
        public bool Allow { get; set; } = true;
        public bool Autostart { get; private set; }
        public string? Reason { get; private set; }
        public bool Released { get; private set; }

        public Task<(bool Background, bool Autostart)> RequestBackgroundAsync(bool autostart)
        {
            Autostart = Allow && autostart;
            return Task.FromResult((Allow, Autostart));
        }

        public Task<IDisposable?> InhibitAsync(string reason)
        {
            Reason = reason;
            return Task.FromResult<IDisposable?>(new Release(() => Released = true));
        }

        private sealed class Release(Action release) : IDisposable
        {
            public void Dispose() => release();
        }
    }

    private sealed class DeniedHostingSystem : IHostingSystem
    {
        public bool StartsAtLogin => false;
        public Task ConfigureBackgroundAsync(bool keepRunning, bool startAtLogin) =>
            Task.FromException(new InvalidOperationException("Permission denied by the synthetic desktop."));
        public Task<IDisposable?> KeepAwakeAsync(string reason) => Task.FromResult<IDisposable?>(null);
    }

    internal sealed class ScriptedHost(LocalServerState afterStart) : ILocalServerHost
    {
        public event Action? Changed;
        public LocalServerState State { get; private set; }
        public LocalServerState AfterStart { get; set; } = afterStart;
        public string? Message => State == LocalServerState.Failed ? "The bundled server is missing." : null;
        public LocalServerSettings Settings => new("This PC's Server", true, 43111);
        public Uri SecureAddress => new("https://127.0.0.1:43111");
        public ServerInfoResponse? Info => new(FakeServer.ServerId, Settings.ServerName, "1.26.3", State == LocalServerState.Running,
            true, 43111, FakeServer.Fingerprint, ServerIdentity.Display(FakeServer.Fingerprint), Capabilities);
        public IReadOnlyList<string> Capabilities { get; init; } = ["library-state-v1"];
        public ServerInfoResponse? OtherServer => State == LocalServerState.PortInUse ? Info : null;
        public int Starts { get; private set; }
        public int Restarts { get; private set; }
        public int Stops { get; private set; }
        public int Resets { get; private set; }
        public string? NewPin { get; private set; }
        public (string ServerName, string OwnerName, string Password, int Port)? Setup { get; private set; }

        public Task StartAsync()
        {
            Starts++;
            State = AfterStart;
            Changed?.Invoke();
            return Task.CompletedTask;
        }

        public Task RestartAsync()
        {
            Restarts++;
            return StartAsync();
        }

        public Task StopAsync()
        {
            Stops++;
            State = LocalServerState.Stopped;
            return Task.CompletedTask;
        }

        public Task<AuthenticationResponse> SetUpOwnerAsync(string serverName, string ownerName, string password, int httpsPort, string deviceName, CancellationToken cancellation)
        {
            Setup = (serverName, ownerName, password, httpsPort);
            State = LocalServerState.Running;
            return Task.FromResult(Authentication());
        }

        public Task<AuthenticationResponse> SignInAsync(string ownerName, string password, string deviceName, CancellationToken cancellation) =>
            password == Password ? Task.FromResult(Authentication()) : Task.FromException<AuthenticationResponse>(new AureliaApiException(401, "invalid_credentials", "Rejected"));

        public Task ResetOwnerPinAsync(string password, string pin, CancellationToken cancellation)
        {
            Resets++;
            if (password != Password) return Task.FromException(new AureliaApiException(403, "invalid_password", "Rejected"));
            NewPin = pin;
            return Task.CompletedTask;
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;

        private static AuthenticationResponse Authentication() => new(new UserSummary(FakeLibrary.OwnerId, "Lucas", UserRole.Owner, DateTimeOffset.UtcNow),
            Guid.NewGuid(), "synthetic-device-token-0000000000000000000001", DateTimeOffset.UtcNow.AddDays(30));
    }
}
