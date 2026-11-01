using System.Net;
using System.Net.Sockets;
using System.Text.Json.Nodes;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Hosting;
using Aurelia.Linux.Core.Management;
using Aurelia.Linux.Core.Settings;
using Xunit;

namespace Aurelia.Linux.IntegrationTests;

/// <summary>
/// "Set Up This PC" with the real server executable started by the app, as on the owner's PC: setup
/// with a Server Password, the profiles with the owner PIN, a storage location of one-byte synthetic
/// files, a restart and "Welcome Back", recovery after the server dies, an owner PIN reset, and a
/// second server on the same port. The server listens on 127.0.0.1 only and keeps its data in a
/// temporary folder.
/// </summary>
public sealed class HostingFlowTests : IAsyncDisposable
{
    private const string Password = "synthetic local host password";
    private readonly string root = Path.Combine(Path.GetTempPath(), "aurelia-linux-host-" + Guid.NewGuid().ToString("N"));
    private readonly LocalServerOptions options;

    public HostingFlowTests()
    {
        Directory.CreateDirectory(root);
        var http = FreePort();
        var https = FreePort();
        while (https == http) https = FreePort();
        options = new LocalServerOptions(Executable ?? "", Path.Combine(root, "server"), Path.Combine(root, "logs"), http, https,
            DefaultLanAccess: false, "Synthetic Linux Host");
    }

    /// <summary>The server executable built beside these tests (the project references the server).</summary>
    private static string? Executable =>
        Environment.GetEnvironmentVariable("AURELIA_TEST_SERVER") is { Length: > 0 } custom ? custom
        : File.Exists(Path.Combine(AppContext.BaseDirectory, "Aurelia.Server")) ? Path.Combine(AppContext.BaseDirectory, "Aurelia.Server") : null;

    public ValueTask DisposeAsync()
    {
        try
        {
            Directory.Delete(root, recursive: true);
        }
        catch (IOException)
        {
        }
        return ValueTask.CompletedTask;
    }

    private static int FreePort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    private sealed record Rig(LocalServerHost Host, HostSetupModel Model, AppSession Session, AppFlow Flow, MemoryCredentialStore Keyring, AureliaApi Api) : IAsyncDisposable
    {
        public async ValueTask DisposeAsync()
        {
            await Host.DisposeAsync();
            Api.Dispose();
        }
    }

    private Rig Start(MemoryCredentialStore? keyring = null)
    {
        var settings = new MemorySettingsStore();
        settings.Write(AppFlow.OperatingModeKey, "host");
        var flow = new AppFlow(settings);
        var api = new AureliaApi(new PinnedServerTransport());
        keyring ??= new MemoryCredentialStore();
        var session = new AppSession(flow, api, keyring, new ServerWakeUp(api, new NoWakeOnLan(), () => [], TimeProvider.System), "Synthetic PC");
        var host = new LocalServerHost(options);
        var model = new HostSetupModel(host, session, flow, keyring, action => action());
        return new Rig(host, model, session, flow, keyring, api);
    }

    private static async Task WaitAsync(Func<bool> done, string what)
    {
        for (var attempt = 0; attempt < 600 && !done(); attempt++) await Task.Delay(100);
        Assert.True(done(), "Timed out waiting for " + what);
    }

    [Fact]
    public async Task NetworkTrialsConfirmOnTheNewAddressAndRollBackWhenTheyExpire()
    {
        Assert.SkipWhen(Executable is null, "The server executable was not built beside the tests.");
        await using var rig = Start();
        await rig.Session.StartAsync(rig.Model.StartAsync);
        await WaitAsync(() => rig.Model.Phase == HostPhase.OwnerSetup, "owner setup");
        rig.Model.OwnerName = "Synthetic Owner";
        await rig.Model.SetUpAsync(Password);
        var picker = new ProfilePickerModel(rig.Session);
        await picker.LoadAsync();
        await picker.SetUpAsync(Password, "5682", "5682");
        rig.Session.CompleteInitialLibrarySetup();
        var management = new ManagementClient(rig.Api, rig.Session.Library!.Client, _ => Task.FromResult<string?>(Password));
        var stored = (await management.SettingsAsync())["stored"]!.AsObject();
        var port = FreePort();
        while (port == options.HttpPort || port == options.DefaultHttpsPort || port == 43110) port = FreePort();
        var trial = new NetworkTrial(rig.Api, rig.Session.Server!, rig.Session.Profile!);
        var operation = await trial.StartAsync(management, NetworkTrial.Settings(stored, "Confirmed Synthetic Host", false, port, false, ""), false);
        rig.Session.BeginNetworkConfirmation(operation.ConfirmBefore!.Value);
        try
        {
            var confirmed = await trial.ConfirmAsync("5682", Password, rig.Session.Capabilities, TestContext.Current.CancellationToken);
            await rig.Session.AcceptConfirmedNetworkAsync(confirmed);
            Assert.Equal(port, rig.Keyring.Server!.Address.Port);
            Assert.Equal(port, rig.Host.Settings.LanHttpsPort);
            Assert.Equal(AppScreen.Library, rig.Flow.Screen);
            var journalPath = Path.Combine(options.DataDirectory, "host-operation.json");
            var journal = JsonNode.Parse(await File.ReadAllTextAsync(journalPath, TestContext.Current.CancellationToken))!;
            Assert.Equal("completed", journal["state"]!.GetValue<string>());

            // A second, unconfirmed trial is expired in the isolated journal. This exercises the
            // production watchdog and rollback, without making the test wait a full minute.
            management = new ManagementClient(rig.Api, rig.Session.Library!.Client, _ => Task.FromResult<string?>(Password));
            stored = (await management.SettingsAsync())["stored"]!.AsObject();
            var temporaryPort = FreePort();
            while (temporaryPort == options.HttpPort || temporaryPort == port || temporaryPort == 43110) temporaryPort = FreePort();
            var abandoned = new NetworkTrial(rig.Api, rig.Session.Server!, rig.Session.Profile!);
            operation = await abandoned.StartAsync(management, NetworkTrial.Settings(stored, "Abandoned Synthetic Host", false, temporaryPort, false, ""), false);
            rig.Session.BeginNetworkConfirmation(operation.ConfirmBefore!.Value);
            var pid = rig.Host.ProcessId;
            await WaitAsync(() => rig.Host.ProcessId != pid && rig.Host.State == LocalServerState.Running, "the trial restart");
            journal = JsonNode.Parse(await File.ReadAllTextAsync(journalPath, TestContext.Current.CancellationToken))!;
            journal["confirmBefore"] = DateTimeOffset.UtcNow.AddSeconds(-1).ToString("O");
            var temporary = journalPath + ".test";
            await File.WriteAllTextAsync(temporary, journal.ToJsonString(), TestContext.Current.CancellationToken);
            File.Move(temporary, journalPath, overwrite: true);
            await WaitAsync(() => rig.Host.Settings.LanHttpsPort == port && rig.Host.State == LocalServerState.Running, "automatic network rollback");
            Assert.Equal("Confirmed Synthetic Host", rig.Host.Settings.ServerName);
            Assert.Equal(port, rig.Keyring.Server!.Address.Port);
            journal = JsonNode.Parse(await File.ReadAllTextAsync(journalPath, TestContext.Current.CancellationToken))!;
            Assert.Equal("rolledBack", journal["state"]!.GetValue<string>());
            Assert.Null(journal["previousSettings"]);
        }
        finally
        {
            await rig.Session.SwitchProfileAsync();
        }
    }

    [Fact]
    public async Task SetsUpAndReopensThisComputersServer()
    {
        Assert.SkipWhen(Executable is null, "The server executable was not built beside the tests.");
        var keyring = new MemoryCredentialStore();
        StoredServer stored;
        await using (var rig = Start(keyring))
        {
            await rig.Session.StartAsync(rig.Model.StartAsync);
            await WaitAsync(() => rig.Model.Phase == HostPhase.OwnerSetup, "owner setup");
            Assert.Equal(AppScreen.HostSetup, rig.Flow.Screen);
            Assert.Equal("Synthetic Linux Host", rig.Model.ServerName);

            await rig.Model.SetUpAsync("too short");
            Assert.Equal("Use at least 12 characters for the Server Password.", rig.Model.Error);
            rig.Model.OwnerName = "Synthetic Owner";
            rig.Model.HttpsPort = options.DefaultHttpsPort;
            await rig.Model.SetUpAsync(Password);
            Assert.Null(rig.Model.Error);
            Assert.Equal(AppScreen.ProfilePicker, rig.Flow.Screen);
            Assert.True(rig.Session.NeedsInitialLibrarySetup);
            stored = Assert.IsType<StoredServer>(keyring.Server);
            Assert.True(stored.LocallyManaged);
            Assert.Equal(rig.Host.SecureAddress, stored.Address);
            Assert.Equal(LocalServerState.Running, rig.Host.State);

            // The profile picker sets up the owner's PIN with the Server Password, over pinned HTTPS.
            var picker = new ProfilePickerModel(rig.Session);
            await picker.LoadAsync();
            Assert.True(picker.NeedsSetup);
            await picker.SetUpAsync(Password, "5682", "5682");
            Assert.Null(picker.Error);
            await WaitAsync(() => rig.Flow.Screen == AppScreen.InitialLibrarySetup, "the first storage screen");
            Assert.Equal("Synthetic Owner", rig.Session.Profile?.User.Username);

            // The first storage location, read from one-byte synthetic files.
            var media = Path.Combine(root, "media", "Movies");
            Directory.CreateDirectory(media);
            await File.WriteAllBytesAsync(Path.Combine(media, "Synthetic Voyage (2020).mkv"), [1], TestContext.Current.CancellationToken);
            var management = new Core.Management.ManagementClient(rig.Api, rig.Session.Library!.Client, _ => Task.FromResult<string?>(Password));
            var library = await management.CreateLibraryAsync(new CreateLibraryRequest("Movies", media, LibraryKind.Movies));
            await management.ScanAsync(library.Id);
            rig.Session.CompleteInitialLibrarySetup();
            Assert.Equal(AppScreen.Library, rig.Flow.Screen);
            var capabilities = await management.CapabilitiesAsync();
            Assert.True(capabilities.NativeHostOperations);
            Assert.False(capabilities.LinuxPackage);

            // A restart asked for in Server settings goes through the host and back to the picker.
            await management.RestartAsync();
            await WaitAsync(() => rig.Flow.Screen == AppScreen.ProfilePicker, "the picker after the restart");
            Assert.Null(rig.Session.Profile);
            Assert.Equal(LocalServerState.Running, rig.Host.State);

            // A crash: the host starts the server again by itself.
            var pid = rig.Host.ProcessId;
            Assert.NotNull(pid);
            System.Diagnostics.Process.GetProcessById(pid.Value).Kill();
            await WaitAsync(() => rig.Host.ProcessId is { } next && next != pid && rig.Host.State == LocalServerState.Running, "recovery");
            await WaitAsync(() => rig.Flow.Screen == AppScreen.ProfilePicker, "the picker after recovery");
        }

        // Aurelia opened again: the saved credential leads straight to the profiles.
        await using (var rig = Start(keyring))
        {
            await rig.Session.StartAsync(rig.Model.StartAsync);
            await WaitAsync(() => rig.Flow.Screen == AppScreen.ProfilePicker, "the saved server's profiles");

            // A forgotten owner PIN: the Server Password sets a new one through the private host channel.
            rig.Model.BeginPinReset();
            await rig.Model.ResetPinAsync("wrong password, long enough", "2468", "2468");
            Assert.Equal("The Server Password is not correct.", rig.Model.Error);
            await rig.Model.ResetPinAsync(Password, "2468", "2468");
            Assert.Null(rig.Model.Error);
            var picker = new ProfilePickerModel(rig.Session);
            await picker.LoadAsync();
            var owner = picker.Profiles.Single(p => p.Role == UserRole.Owner);
            await picker.ChooseAsync(owner);
            picker.Pin = "2468";
            await picker.SubmitPinAsync();
            Assert.Equal(AppScreen.Library, rig.Flow.Screen);
        }

        // Without the saved credential: "Welcome Back" asks for the owner and the Server Password.
        await using (var rig = Start(new MemoryCredentialStore()))
        {
            await rig.Session.StartAsync(rig.Model.StartAsync);
            await WaitAsync(() => rig.Model.Phase == HostPhase.SignIn, "Welcome Back");
            rig.Model.OwnerName = "Synthetic Owner";
            await rig.Model.SignInAsync("not the password at all");
            Assert.Equal("The owner name or Server Password is not correct.", rig.Model.Error);
            await rig.Model.SignInAsync(Password);
            Assert.Null(rig.Model.Error);
            Assert.Equal(AppScreen.ProfilePicker, rig.Flow.Screen);
            Assert.Equal(stored.ServerId, rig.Keyring.Server?.ServerId);
            Assert.Equal(stored.Fingerprint, rig.Keyring.Server?.Fingerprint);
        }
        var settings = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(options.DataDirectory, "server-settings.json"), TestContext.Current.CancellationToken))!;
        Assert.Equal(options.DefaultHttpsPort, settings["lanHttpsPort"]!.GetValue<int>());
        Assert.False(settings["lanAccessEnabled"]!.GetValue<bool>());
    }

    [Fact]
    public async Task AnotherServerOnThePortIsOfferedInsteadOfStartingASecond()
    {
        Assert.SkipWhen(Executable is null, "The server executable was not built beside the tests.");
        await using var first = Start();
        await first.Session.StartAsync(first.Model.StartAsync);
        await WaitAsync(() => first.Model.Phase == HostPhase.OwnerSetup, "the first server");

        await using var second = Start();
        await second.Session.StartAsync(second.Model.StartAsync);
        await WaitAsync(() => second.Model.Phase == HostPhase.PortInUse, "the port in use");
        Assert.Equal(LocalServerState.PortInUse, second.Host.State);
        Assert.Equal("Synthetic Linux Host", second.Host.OtherServer?.Name);
        Assert.Null(second.Host.ProcessId);
    }

    [Fact]
    public async Task AMissingServerIsReported()
    {
        await using var rig = Start();
        var missing = new LocalServerHost(options with { Executable = Path.Combine(root, "nothing-here") });
        var model = new HostSetupModel(missing, rig.Session, rig.Flow, rig.Keyring, action => action());
        await model.StartAsync();
        Assert.Equal(HostPhase.Failed, model.Phase);
        Assert.Contains("missing", model.StatusMessage, StringComparison.Ordinal);
        await missing.DisposeAsync();
    }
}
