using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using Aurelia.Contracts;
using Aurelia.Linux.Core;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Management;
using Aurelia.Linux.Library;
using Aurelia.Linux.Management;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.VisualTree;
using Xunit;

namespace Aurelia.Linux.Tests;

public sealed class NetworkTrialTests
{
    private static readonly Guid OperationId = Guid.Parse("75a63f88-aaaa-4000-8000-000000000001");
    private static readonly UserSummary Owner = new(FakeLibrary.OwnerId, "Owner", UserRole.Owner, DateTimeOffset.UtcNow);
    private static readonly StoredServer Original = new(FakeServer.ServerId, "Old name", new Uri("https://127.0.0.1:43111"), FakeServer.Fingerprint,
        "synthetic-device-token-000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30), LocallyManaged: true);
    private static readonly ProfileSession Profile = new(Owner, Guid.NewGuid(), "synthetic-old-profile-token-00000000000001", DateTimeOffset.UtcNow.AddHours(12));
    private static JsonObject Stored => JsonNode.Parse("""{"version":2,"revision":12,"serverName":"Old name","lanAccessEnabled":true,"lanHttpsPort":43111,"futureField":{"keep":42}}""")!.AsObject();
    private static string Json<T>(T value) => JsonSerializer.Serialize(value, AureliaJson.Options);

    private static JsonObject Candidate(bool lan = true) => NetworkTrial.Settings(Stored, "New name", lan, 45111, true, "192.168.1.0/24\n10.0.0.0/8");

    private sealed class NetworkServer : IServerTransport
    {
        public FakeServer Old { get; } = FakeLibrary.Create(pictures: false);
        public FakeServer New { get; } = FakeServer.WithServerInfo("New name");
        public List<(Uri Address, string? Fingerprint)> Connections { get; } = [];

        public NetworkServer()
        {
            Old.Answer("POST", "/api/v1/server/operations/network", Json(new HostOperationStatus(OperationId, "network", "awaitingConfirmation", DateTimeOffset.UtcNow.AddSeconds(60), 45111)));
            New.Answer("POST", $"/api/v1/profiles/{Owner.Id}/unlock", Json(new ProfileSessionResponse(Owner, Guid.NewGuid(), "synthetic-new-profile-token-00000000000001", DateTimeOffset.UtcNow.AddHours(12))))
                .Answer("GET", "/api/v1/auth/me", "{}", HttpStatusCode.Unauthorized)
                .Answer("POST", "/api/v1/management/unlock", Json(new ManagementUnlockResponse(DateTimeOffset.UtcNow.AddMinutes(10))))
                .Answer("POST", $"/api/v1/server/operations/{OperationId}/confirm", "{}")
                .Answer("POST", "/api/v1/profile/end", "{}");
        }

        public HttpClient CreateClient(Uri address, string? expectedFingerprint, CapturedFingerprint? captured, TimeSpan timeout)
        {
            Connections.Add((address, expectedFingerprint));
            return (address.Port == 45111 ? New : Old).CreateClient(address, expectedFingerprint, captured, timeout);
        }
    }

    [Fact]
    public async Task ConfirmsThroughTheNewPinnedAddressWithFreshCredentials()
    {
        var server = new NetworkServer();
        using var api = new AureliaApi(server);
        var trial = new NetworkTrial(api, Original, Profile);
        var management = new ManagementClient(api, new LibraryClient(api, Original, Profile, []), _ => Task.FromResult<string?>(null));
        await trial.StartAsync(management, Candidate(), false);
        Assert.Equal(new Uri("https://127.0.0.1:45111"), trial.Candidate!.Address);
        var result = await trial.ConfirmAsync("2468", "synthetic server password", [], TestContext.Current.CancellationToken);
        Assert.Equal(trial.Candidate, result.Server);
        Assert.NotEqual(Profile.Token, result.Profile.Token);
        Assert.Contains($"POST /api/v1/server/operations/{OperationId}/confirm", server.New.Requests);
        Assert.DoesNotContain($"POST /api/v1/server/operations/{OperationId}/confirm", server.Old.Requests);
        Assert.All(server.Connections, connection => Assert.Equal(FakeServer.Fingerprint, connection.Fingerprint));
        var payload = JsonNode.Parse(server.Old.Bodies["POST /api/v1/server/operations/network"])!;
        Assert.Equal(42, payload["settings"]!["futureField"]!["keep"]!.GetValue<int>());
        Assert.Equal(12, payload["settings"]!["revision"]!.GetValue<int>());
        Assert.False(payload["confirmRemoteAccessDisabled"]!.GetValue<bool>());
        Assert.Contains("synthetic server password", server.New.Bodies["POST /api/v1/management/unlock"], StringComparison.Ordinal);
        Assert.DoesNotContain("POST /api/v1/profile/end", server.New.Requests);
    }

    [Fact]
    public async Task RejectsAnotherServerBeforeSendingThePinOrPassword()
    {
        var server = new NetworkServer();
        server.New.Replace("GET", "/api/v1/server/info", $$"""{"serverId":"{{Guid.NewGuid()}}","publicKeyFingerprint":"{{FakeServer.Fingerprint}}"}""");
        using var api = new AureliaApi(server);
        var trial = new NetworkTrial(api, Original, Profile);
        await trial.StartAsync(new ManagementClient(api, new LibraryClient(api, Original, Profile, []), _ => Task.FromResult<string?>(null)), Candidate(), false);
        var failure = await Assert.ThrowsAsync<AureliaApiException>(() => trial.ConfirmAsync("2468", "synthetic password", [], TestContext.Current.CancellationToken));
        Assert.Equal("identity_mismatch", failure.Code);
        Assert.Equal(["GET /api/v1/server/info"], server.New.Requests);
        Assert.Empty(server.New.Bodies);
    }

    [Fact]
    public async Task AFailedConfirmationEndsItsTemporaryProfile()
    {
        var server = new NetworkServer();
        server.New.Replace("POST", "/api/v1/management/unlock", """{"code":"invalid_password","message":"The password is wrong."}""", HttpStatusCode.Forbidden);
        using var api = new AureliaApi(server);
        var trial = new NetworkTrial(api, Original, Profile);
        await trial.StartAsync(new ManagementClient(api, new LibraryClient(api, Original, Profile, []), _ => Task.FromResult<string?>(null)), Candidate(), false);
        await Assert.ThrowsAsync<AureliaApiException>(() => trial.ConfirmAsync("2468", "wrong password", [], TestContext.Current.CancellationToken));
        Assert.Contains("POST /api/v1/profile/end", server.New.Requests);
        Assert.DoesNotContain($"POST /api/v1/server/operations/{OperationId}/confirm", server.New.Requests);
    }

    private sealed class Clock : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = DateTimeOffset.UtcNow;
        public override DateTimeOffset GetUtcNow() => Now;
    }

    [Fact]
    public async Task AnExpiredTrialCannotConfirmAndTheSavedConnectionStays()
    {
        var clock = new Clock();
        var server = new NetworkServer();
        using var api = new AureliaApi(server);
        var trial = new NetworkTrial(api, Original, Profile, clock);
        await trial.StartAsync(new ManagementClient(api, new LibraryClient(api, Original, Profile, []), _ => Task.FromResult<string?>(null)), Candidate(), false);
        clock.Now = trial.Operation!.ConfirmBefore!.Value.AddSeconds(1);
        var failure = await Assert.ThrowsAsync<AureliaApiException>(() => trial.ConfirmAsync("2468", "synthetic password", [], TestContext.Current.CancellationToken));
        Assert.Equal("network_confirmation_expired", failure.Code);
        Assert.Empty(server.New.Requests);
        Assert.Equal(43111, Original.Address.Port);
    }

    [Fact]
    public async Task RemoteClientsCannotTurnOffTheirOnlyConnection()
    {
        var server = new NetworkServer();
        using var api = new AureliaApi(server);
        var remote = Original with { LocallyManaged = false, Address = new Uri("https://192.168.1.20:43111") };
        var trial = new NetworkTrial(api, remote, Profile);
        var management = new ManagementClient(api, new LibraryClient(api, remote, Profile, []), _ => Task.FromResult<string?>(null));
        var failure = await Assert.ThrowsAsync<AureliaApiException>(() => trial.StartAsync(management, Candidate(lan: false), true));
        Assert.Equal("local_connection_required", failure.Code);
        Assert.Empty(server.Old.Requests);
    }

    [Theory]
    [InlineData("", 45111)]
    [InlineData("Name", 0)]
    [InlineData("Name", 43110)]
    [InlineData("Name", 65536)]
    public void InvalidNetworkDraftsNeverReachTheServer(string name, int port) =>
        Assert.Throws<AureliaApiException>(() => NetworkTrial.Settings(Stored, name, true, port, true, ""));

    [AvaloniaFact]
    public void TheNetworkEditorShowsTheTrialAndVerificationPrompt()
    {
        var transport = new NetworkServer();
        var credentials = new MemoryCredentialStore { Server = Original };
        var window = TestWindows.Show(AppServices.ForTests(transport: transport, credentials: credentials));
        FakeLibrary.Pump(() => window.Flow.Screen == AppScreen.ProfilePicker);
        window.Session.OpenProfile(Profile);
        FakeLibrary.Pump(() => window.Session.Library?.Home is not null);
        var sheets = new SheetHost();
        var scope = new AdminScope(window.Session, sheets);
        var section = new NetworkSettingsSection(scope, Stored, Stored, () => Task.CompletedTask);
        var panel = new Grid { Children = { section, sheets } };
        var editor = new Window { Width = 880, Height = 900, Content = panel };
        editor.Show();
        FakeLibrary.Pump(() => false, rounds: 10);
        section.GetVisualDescendants().OfType<TextBox>().Single(c => AutomationProperties.GetName(c) == "Server name").Text = "New name";
        section.GetVisualDescendants().OfType<NumericUpDown>().Single().Value = 45111;
        Click(section, "Try Network Settings (60-second rollback)");
        Assert.True(window.Session.NetworkConfirmationPending);
        Assert.Equal(43111, credentials.Server!.Address.Port);
        window.Session.ServerInterrupted();
        window.Session.HandleSessionFailure(new AureliaApiException(401, "profile_session_expired", "Expired"));
        Assert.Equal(Profile, window.Session.Profile);
        Assert.Contains(section.GetVisualDescendants().OfType<TextBlock>(), t => t.Text?.Contains("127.0.0.1:45111", StringComparison.Ordinal) == true);
        using (var frame = editor.CaptureRenderedFrame()!) TestWindows.SaveSnapshot(frame, "settings-network-trial");
        Click(section, "Verify New Connection & Keep Settings");
        Assert.True(sheets.IsShowing);
        sheets.GetVisualDescendants().OfType<TextBox>().Single(t => AutomationProperties.GetName(t) == "Profile PIN").Text = "2468";
        sheets.GetVisualDescendants().OfType<TextBox>().Single(t => AutomationProperties.GetName(t) == "Server Password").Text = "synthetic password";
        using (var frame = editor.CaptureRenderedFrame()!) TestWindows.SaveSnapshot(frame, "settings-network-verify");
        Click(sheets, "Verify & Keep Settings");
        FakeLibrary.Pump(() => credentials.Server?.Address.Port == 45111);
        Assert.Equal(45111, credentials.Server!.Address.Port);
        Assert.False(window.Session.NetworkConfirmationPending);
        Assert.NotEqual(Profile.Token, window.Session.Profile!.Token);
        editor.Close();
        window.Close();
    }

    private static void Click(Control root, string label)
    {
        root.GetVisualDescendants().OfType<Button>().Single(b => b.Content as string == label)
            .RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        FakeLibrary.Pump(() => false, rounds: 10);
    }
}
