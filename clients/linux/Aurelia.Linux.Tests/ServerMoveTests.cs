using System.Net;
using System.Text;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Flow;
using Aurelia.Linux.Core.Hosting;
using Aurelia.Linux.Core.Moving;
using Aurelia.Linux.Core.Settings;
using Xunit;

namespace Aurelia.Linux.Tests;

/// <summary>Moving a server to another computer (docs/SERVER_MOVE.md): the rules without a screen, with invented data only.</summary>
public sealed class ServerMoveTextTests
{
    private static SetupMoveLocation Location(string name, params MoveSuggestion[] suggestions) =>
        new(Guid.NewGuid(), name, "/synthetic/old/" + name, 415, suggestions);

    [Fact]
    public void MoveCodesAreTwelveLettersAndDigitsInGroupsOfFour()
    {
        Assert.Equal("ABCD-EFGH-JKMN", ServerMoveText.FormatCode("abcd efgh-jkmn"));
        Assert.Equal("ABCD-E", ServerMoveText.FormatCode("abcde"));
        Assert.Equal("ABCD-EFGH-JKMN", ServerMoveText.FormatCode("ABCDEFGHJKMNPQ"));
        Assert.Equal("", ServerMoveText.FormatCode(null));
        Assert.False(ServerMoveText.IsCompleteCode("abcd-efgh-jkm"));
        Assert.True(ServerMoveText.IsCompleteCode("abcdefghjkmn"));
    }

    [Fact]
    public void MatchCountsAndProgressReadLikeTheMacs()
    {
        Assert.Equal("412 of 415 sample files found", ServerMoveText.MatchText(412, 415));
        Assert.Equal("All 415 sample files found", ServerMoveText.MatchText(415, 415));
        Assert.Equal("None of 1 sample file found", ServerMoveText.MatchText(0, 1));
        Assert.Equal("This location had no files to compare.", ServerMoveText.MatchText(0, 0));
        Assert.Equal((0.5, "5.0 MB of 10 MB"), ServerMoveText.Progress(new SetupMoveProgress(5 * 1024 * 1024, 10 * 1024 * 1024)));
        Assert.Null(ServerMoveText.Progress(new SetupMoveProgress(2048)).Fraction);
        var unknown = JsonSerializer.Deserialize<SetupMoveStatus>("""{"state":"fetching","progress":{"received":2048,"expected":null}}""", AureliaJson.Options)!;
        Assert.Equal("2.0 KB received", ServerMoveText.Progress(unknown.Progress).Text);
        Assert.Contains("Waiting", ServerMoveText.Progress(null).Text, StringComparison.Ordinal);
        Assert.Equal(1, ServerMoveText.Progress(new SetupMoveProgress(300, 100)).Fraction);
    }

    [Fact]
    public void EachLocationStartsWithItsBestSuggestionOrLater()
    {
        var movies = Location("Movies", new("/mnt/b", 3), new("/mnt/a", 412), new("/mnt/c", 412));
        Assert.Equal(["/mnt/a", "/mnt/c", "/mnt/b"], ServerMoveText.Ranked(movies.Suggestions).Select(s => s.Path));
        Assert.Equal(new MoveChoice(MoveChoiceKind.Suggestion, "/mnt/a"), ServerMoveText.InitialChoice(movies));
        Assert.Equal(MoveChoice.Later, ServerMoveText.InitialChoice(Location("Shows", new MoveSuggestion("/mnt/x", 0))));
        Assert.Equal(MoveChoice.Later, ServerMoveText.InitialChoice(Location("Empty")));
    }

    [Fact]
    public void TheFinishPayloadMapsEveryLocationToAFolderOrToNullForLater()
    {
        var movies = Location("Movies", new MoveSuggestion("/mnt/media/Movies", 412));
        var shows = Location("Shows");
        var kids = Location("Kids");
        var (request, problem) = ServerMoveText.Mappings([movies, shows, kids],
            new Dictionary<Guid, MoveChoice> { [kids.Id] = new(MoveChoiceKind.Folder, " /srv/kids ") });
        Assert.Null(problem);
        Assert.Equal([new MoveMapping(movies.Id, "/mnt/media/Movies"), new MoveMapping(shows.Id, null), new MoveMapping(kids.Id, "/srv/kids")], request!.Mappings);
        var json = JsonSerializer.Serialize(request, AureliaJson.Options);
        Assert.Contains($"{{\"id\":\"{shows.Id}\",\"path\":null}}", json, StringComparison.Ordinal);
        Assert.Contains("Kids", ServerMoveText.Mappings([kids], new Dictionary<Guid, MoveChoice> { [kids.Id] = new(MoveChoiceKind.Folder, "") }).Problem, StringComparison.Ordinal);
        Assert.Contains("starting with /", ServerMoveText.Mappings([kids], new Dictionary<Guid, MoveChoice> { [kids.Id] = new(MoveChoiceKind.Folder, "relative/kids") }).Problem, StringComparison.Ordinal);
        Assert.Empty(ServerMoveText.Mappings([], new Dictionary<Guid, MoveChoice>()).Request!.Mappings);
    }

    [Fact]
    public void TheOldServersStateOffersOnlyTheActionsThatFit()
    {
        var now = DateTimeOffset.Parse("2026-11-15T10:00:00Z", System.Globalization.CultureInfo.InvariantCulture);
        Assert.Equal([ServerMoveAction.Start], ServerMoveText.OwnerView(null, now).Actions);
        var network = ServerMoveText.OwnerView(new ServerMoveStatus("waiting", "network", now.AddMinutes(14).AddSeconds(30)), now);
        Assert.Contains("14:30", network.Summary, StringComparison.Ordinal);
        Assert.Equal([ServerMoveAction.NewCode, ServerMoveAction.Cancel], network.Actions);
        Assert.Contains("expired", ServerMoveText.OwnerView(new ServerMoveStatus("waiting", "network", now.AddMinutes(-1)), now).Summary, StringComparison.Ordinal);
        Assert.Equal([ServerMoveAction.MarkMoved, ServerMoveAction.Cancel], ServerMoveText.OwnerView(new ServerMoveStatus("waiting", "file"), now).Actions);
        Assert.Equal([ServerMoveAction.Cancel], ServerMoveText.OwnerView(new ServerMoveStatus("transferring"), now).Actions);
        var moved = ServerMoveText.OwnerView(new ServerMoveStatus("moved", MovedTo: new MovedServer(Guid.NewGuid(), "Synthetic Basement", [])), now);
        Assert.Equal([ServerMoveAction.Undo], moved.Actions);
        Assert.Contains("Synthetic Basement", moved.Summary, StringComparison.Ordinal);
        Assert.Equal("1:00:05", ServerMoveText.Countdown(TimeSpan.FromSeconds(3605)));
    }

    [Fact]
    public void OnlyHttpsAddressesOfTheSameServerAreFollowed()
    {
        var id = Guid.NewGuid();
        var moved = new MovedServer(id, "Synthetic Basement",
            ["https://192.168.1.40:43111/", "http://192.168.1.40:43110", "javascript:alert(1)", "https://user:secret@192.168.1.41:43111", "https://192.168.1.40:43111", "https://[fd00::5]:43111"]);
        Assert.Equal(["https://192.168.1.40:43111/", "https://[fd00::5]:43111/"], moved.Followable(id, []).Select(a => a.ToString()));
        Assert.Equal(["https://[fd00::5]:43111/"], moved.Followable(id, [new Uri("https://192.168.1.40:43111")]).Select(a => a.ToString()));
        Assert.Empty(moved.Followable(Guid.NewGuid(), []));
    }
}

/// <summary>Storage Location Moved…: what may be confirmed, and when force is sent.</summary>
public sealed class RelocateModelTests
{
    [Fact]
    public void ASuggestionCanBeConfirmedATypedFolderOnlyAfterItsPreview()
    {
        var model = new RelocateModel();
        model.Load(new RelocateSuggestions(20, [new MoveSuggestion("/mnt/b", 2), new MoveSuggestion("/mnt/a", 19)]));
        Assert.Equal("/mnt/a", model.Suggestions[0].Path);
        Assert.False(model.Decision.CanConfirm);
        model.Choose(model.Suggestions[0]);
        Assert.Equal(("/mnt/a", false), model.Request);
        Assert.Equal("19 of 20 sample files found", model.Decision.Text);
        model.Path = "/srv/elsewhere";
        Assert.Null(model.Request);
        model.Previewed("/srv/elsewhere", new MoveMatch(20, 20));
        Assert.Equal(("/srv/elsewhere", false), model.Request);
    }

    [Fact]
    public void AFolderWithoutAnyMatchingFileNeedsASecondConfirmationThenForce()
    {
        var model = new RelocateModel { Path = "/srv/empty" };
        model.Previewed("/srv/empty", new MoveMatch(20, 0));
        Assert.True(model.Decision.NeedsSecondConfirmation);
        Assert.False(model.Decision.CanConfirm);
        Assert.Contains("wrong folder", model.Decision.Text, StringComparison.Ordinal);
        model.ConfirmedEmpty = true;
        Assert.Equal(("/srv/empty", true), model.Request);
        // Another folder takes the confirmation back.
        model.Path = "/srv/empty2";
        Assert.False(model.ConfirmedEmpty);
        Assert.Null(model.Request);
    }
}

/// <summary>
/// Servers at several addresses, each with its own key: an address nobody answers at is
/// unreachable, and a key other than the pinned one fails the handshake like the real transport.
/// </summary>
internal sealed class AddressedServers : IServerTransport
{
    public const string OtherFingerprint = "F0E1D2C3B4A5968778695A4B3C2D1E0FF0E1D2C3B4A5968778695A4B3C2D1E0F";

    private readonly Dictionary<string, (string Fingerprint, Dictionary<string, (HttpStatusCode, string)> Answers)> servers = new(StringComparer.OrdinalIgnoreCase);

    public List<string> Requests { get; } = [];

    public AddressedServers At(string address, string fingerprint, params (string Route, HttpStatusCode Status, string Body)[] answers)
    {
        var key = new Uri(address).GetLeftPart(UriPartial.Authority);
        servers[key] = (fingerprint, answers.ToDictionary(a => a.Route, a => (a.Status, a.Body)));
        return this;
    }

    public static string Info(Guid id, string name, string? moved = null, string fingerprint = FakeServer.Fingerprint) => $$"""
        {"serverId":"{{id}}","name":"{{name}}","version":"2.18.0","isSetup":true,"lanAccessEnabled":true,"lanHttpsPort":43111,
         "publicKeyFingerprint":"{{fingerprint}}","capabilities":["library-state-v1"]{{(moved is null ? "" : ",\"moved\":" + moved)}}}
        """;

    public HttpClient CreateClient(Uri address, string? expectedFingerprint, CapturedFingerprint? captured, TimeSpan timeout) =>
        new(new Handler(this, address.GetLeftPart(UriPartial.Authority), expectedFingerprint)) { BaseAddress = address, Timeout = timeout };

    private sealed class Handler(AddressedServers owner, string authority, string? expected) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var route = request.Method.Method + " " + request.RequestUri!.AbsolutePath;
            lock (owner.Requests) owner.Requests.Add(authority + " " + route);
            if (!owner.servers.TryGetValue(authority, out var server))
                throw new HttpRequestException(HttpRequestError.ConnectionError, "Connection refused");
            if (expected is not null && !ServerIdentity.Matches(expected, server.Fingerprint))
                throw new HttpRequestException(HttpRequestError.SecureConnectionError, "Key rejected", new System.Security.Authentication.AuthenticationException("Key rejected"));
            var (status, body) = server.Answers.TryGetValue(route, out var answer) ? answer : (HttpStatusCode.NotFound, "{}");
            return Task.FromResult(new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") });
        }
    }
}

/// <summary>Following a server that moved: only the same server with the same key, keeping the sign-in.</summary>
public sealed class FollowMovedServerTests
{
    private static readonly Guid Id = Guid.Parse("7a1d2c3b-0000-4000-8000-0000000000bb");
    private const string Old = "https://192.168.1.20:43111";
    private const string New = "https://192.168.1.40:43111";
    private const string Profiles = """{"formatVersion":2,"minimumClientVersion":"1.0","managementSetupRequired":false,"profiles":[]}""";

    private static StoredServer Saved() => new(Id, "Living Room Server", new Uri(Old), FakeServer.Fingerprint,
        "synthetic-device-token-000000000000000000000001", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30));

    private static string Moved(Guid? id = null) => $$"""{"serverId":"{{id ?? Id}}","name":"Synthetic Basement","addresses":["{{New}}"]}""";

    private static (AppSession Session, AppFlow Flow, MemoryCredentialStore Keyring) Session(IServerTransport transport, TimeProvider? time = null)
    {
        var flow = new AppFlow(new MemorySettingsStore());
        var api = new AureliaApi(transport);
        var keyring = new MemoryCredentialStore { Server = Saved() };
        var session = new AppSession(flow, api, keyring, new ServerWakeUp(api, new NoWakeOnLan(), () => [], time ?? TimeProvider.System), "Test PC", time);
        return (session, flow, keyring);
    }

    [Fact]
    public async Task TheSameServerWithTheSameKeyIsFollowedAndKeepsItsSignIn()
    {
        var servers = new AddressedServers()
            .At(Old, FakeServer.Fingerprint, ("GET /api/v1/server/info", HttpStatusCode.OK, AddressedServers.Info(Id, "Living Room Server", Moved())))
            .At(New, FakeServer.Fingerprint, ("GET /api/v1/server/info", HttpStatusCode.OK, AddressedServers.Info(Id, "Living Room Server")),
                ("GET /api/v1/profiles", HttpStatusCode.OK, Profiles));
        var (session, flow, keyring) = Session(servers);
        await session.StartAsync();
        Assert.Equal(AppScreen.ProfilePicker, flow.Screen);
        Assert.Equal(new Uri(New), keyring.Server!.Address);
        Assert.Equal(Saved().DeviceToken, keyring.Server.DeviceToken);
        Assert.Equal(FakeServer.Fingerprint, keyring.Server.Fingerprint);
        Assert.Null(session.MovedAway);
    }

    [Fact]
    public async Task ADifferentKeyAtTheNewAddressIsRefusedAndSaidPlainly()
    {
        var servers = new AddressedServers()
            .At(Old, FakeServer.Fingerprint, ("GET /api/v1/server/info", HttpStatusCode.OK, AddressedServers.Info(Id, "Living Room Server", Moved())))
            .At(New, AddressedServers.OtherFingerprint, ("GET /api/v1/server/info", HttpStatusCode.OK, AddressedServers.Info(Id, "Living Room Server")));
        var (session, flow, keyring) = Session(servers);
        await session.StartAsync();
        Assert.Equal(AppScreen.ServerUnreachable, flow.Screen);
        Assert.Equal(new Uri(Old), keyring.Server!.Address);
        Assert.Equal("Synthetic Basement", session.MovedAway?.Name);
        Assert.Contains("different key", session.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AnotherServerIdIsNeverTriedAndASilentNewComputerIsWaitedFor()
    {
        var time = new ManualTime();
        var servers = new AddressedServers()
            .At(Old, FakeServer.Fingerprint, ("GET /api/v1/server/info", HttpStatusCode.OK, AddressedServers.Info(Id, "Living Room Server", Moved(Guid.NewGuid()))))
            .At(New, FakeServer.Fingerprint, ("GET /api/v1/server/info", HttpStatusCode.OK, AddressedServers.Info(Id, "Living Room Server")));
        var (session, flow, keyring) = Session(servers, time);
        var starting = session.StartAsync();
        for (var round = 0; round < 200 && !starting.IsCompleted; round++)
        {
            time.Advance(ServerWakeUp.PollInterval);
            await Task.Delay(1, TestContext.Current.CancellationToken);
        }
        await starting;
        Assert.DoesNotContain(servers.Requests, request => request.StartsWith(New, StringComparison.Ordinal));
        Assert.Equal(AppScreen.ServerUnreachable, flow.Screen);
        Assert.Equal(new Uri(Old), keyring.Server!.Address);
        Assert.Contains("doesn't answer yet", session.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task A409ServerMovedSaysWhereItWentAndTheSessionFollows()
    {
        var servers = new AddressedServers()
            .At(Old, FakeServer.Fingerprint, ("GET /api/v1/server/info", HttpStatusCode.OK, AddressedServers.Info(Id, "Living Room Server")),
                ("GET /api/v1/profiles", HttpStatusCode.Conflict, $$"""{"code":"server_moved","message":"This server moved.","movedTo":{{Moved()}}}"""))
            .At(New, FakeServer.Fingerprint, ("GET /api/v1/server/info", HttpStatusCode.OK, AddressedServers.Info(Id, "Living Room Server")),
                ("GET /api/v1/profiles", HttpStatusCode.OK, Profiles));
        var (session, flow, keyring) = Session(servers);
        await session.StartAsync();
        var failure = await Assert.ThrowsAsync<AureliaApiException>(() => session.Api.ProfilesAsync(session.Server!, TestContext.Current.CancellationToken));
        Assert.True(failure.IsServerMoved);
        Assert.Equal("Synthetic Basement", failure.MovedTo?.Name);
        Assert.Equal([New], failure.MovedTo?.Addresses);
        // The old server still answers its public info; once it says it moved, the session follows.
        servers.At(Old, FakeServer.Fingerprint, ("GET /api/v1/server/info", HttpStatusCode.OK, AddressedServers.Info(Id, "Living Room Server", Moved())));
        session.HandleSessionFailure(failure);
        for (var round = 0; round < 200 && keyring.Server!.Address != new Uri(New); round++) await Task.Delay(5, TestContext.Current.CancellationToken);
        Assert.Equal(new Uri(New), keyring.Server!.Address);
        Assert.Equal(Saved().DeviceToken, keyring.Server.DeviceToken);
        Assert.Equal(AppScreen.ProfilePicker, flow.Screen);
    }
}

/// <summary>A saved server reached at another address it announces nearby: only with the same id and key.</summary>
public sealed class ServerWakeUpTests
{
    private static readonly Guid Id = Guid.Parse("7a1d2c3b-0000-4000-8000-0000000000cc");

    private static StoredServer Saved(string? hosting = null) => new(Id, "Living Room Server", new Uri("https://192.168.1.20:43111"), FakeServer.Fingerprint,
        "synthetic-device-token-000000000000000000000002", Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(30), WakeOnLanAddresses: ["aa:bb:cc:dd:ee:01"], Hosting: hosting);

    private sealed class CountingWakeOnLan : IWakeOnLan
    {
        public int Sent { get; private set; }

        public Task SendAsync(IReadOnlyList<string> hardwareAddresses, string? lastKnownHost, CancellationToken cancellation)
        {
            Sent++;
            return Task.CompletedTask;
        }
    }

    [Fact]
    public async Task ANewAddressOnTheNetworkIsUsedOnlyForTheSameIdAndKey()
    {
        var servers = new AddressedServers()
            .At("https://192.168.1.77:43111", AddressedServers.OtherFingerprint, ("GET /api/v1/server/info", HttpStatusCode.OK, AddressedServers.Info(Id, "Impostor", fingerprint: AddressedServers.OtherFingerprint)))
            .At("https://192.168.1.50:43111", FakeServer.Fingerprint, ("GET /api/v1/server/info", HttpStatusCode.OK, AddressedServers.Info(Id, "Living Room Server")));
        using var api = new AureliaApi(servers);
        // An impostor announcing the same id with another key is skipped, never used.
        DiscoveredServer[] nearby =
        [
            new(Guid.NewGuid(), "Someone Else", new Uri("https://192.168.1.60:43111")),
            new(Id, "Living Room Server", new Uri("https://192.168.1.77:43111")),
            new(Id, "Living Room Server", new Uri("https://192.168.1.50:43111")),
        ];
        var reached = await new ServerWakeUp(api, new NoWakeOnLan(), () => nearby, TimeProvider.System)
            .ReachAsync(Saved(), _ => { }, TestContext.Current.CancellationToken);
        Assert.Equal(new Uri("https://192.168.1.50:43111"), reached?.Server.Address);
        Assert.Equal(Saved().DeviceToken, reached?.Server.DeviceToken);
        Assert.DoesNotContain(servers.Requests, request => request.Contains("192.168.1.60", StringComparison.Ordinal));
    }

    [Fact]
    public async Task AServerInsideTheAppIsNeverWokenOverTheNetwork()
    {
        var time = new ManualTime();
        var wake = new CountingWakeOnLan();
        using var api = new AureliaApi(new AddressedServers());
        var reaching = new ServerWakeUp(api, wake, () => [], time).ReachAsync(Saved("linuxApp"), _ => { }, TestContext.Current.CancellationToken);
        for (var round = 0; round < 100 && !reaching.IsCompleted; round++)
        {
            time.Advance(ServerWakeUp.PollInterval);
            await Task.Delay(1, TestContext.Current.CancellationToken);
        }
        Assert.Null(await reaching);
        Assert.Equal(0, wake.Sent);
    }
}

/// <summary>"Move from another Aurelia server" while this PC's new server has no owner.</summary>
public sealed class HostSetupMoveTests
{
    private static readonly Guid MoviesId = Guid.Parse("e0000000-0000-4000-8000-000000000001");
    private static readonly Guid ShowsId = Guid.Parse("e0000000-0000-4000-8000-000000000002");

    internal sealed class ScriptedMove : ISetupMoveChannel
    {
        private readonly Queue<SetupMoveStatus> statuses = new();

        public SetupMoveStatus Last { get; set; } = new("idle");
        public (Uri Address, string Code)? Network { get; private set; }
        public (string Bytes, string Passphrase)? File { get; private set; }
        public FinishMoveRequest? Finished { get; private set; }
        public List<(Guid Id, string Path)> Previews { get; } = [];
        public int Discards { get; private set; }

        public ScriptedMove Then(params SetupMoveStatus[] next)
        {
            foreach (var status in next) statuses.Enqueue(status);
            return this;
        }

        public Task<SetupMoveStatus> StatusAsync(CancellationToken cancellation)
        {
            if (statuses.Count > 0) Last = statuses.Dequeue();
            return Task.FromResult(Last);
        }

        public Task StartNetworkAsync(Uri address, string code, CancellationToken cancellation)
        {
            Network = (address, code);
            return Task.CompletedTask;
        }

        public async Task OpenFileAsync(Stream file, string passphrase, CancellationToken cancellation)
        {
            using var reader = new StreamReader(file);
            File = (await reader.ReadToEndAsync(cancellation), passphrase);
            if (passphrase != "synthetic passphrase") throw new AureliaApiException(400, "invalid_passphrase", "Wrong");
        }

        public Task<MoveMatch> PreviewAsync(Guid locationId, string path, CancellationToken cancellation)
        {
            Previews.Add((locationId, path));
            return Task.FromResult(new MoveMatch(20, 18));
        }

        public Task FinishAsync(FinishMoveRequest request, CancellationToken cancellation)
        {
            Finished = request;
            return Task.CompletedTask;
        }

        public Task DiscardAsync(CancellationToken cancellation)
        {
            Discards++;
            Last = new("idle");
            return Task.CompletedTask;
        }
    }

    internal static SetupMoveStatus Received() => new("received", Source: new SetupMoveSource(Guid.NewGuid(), "Synthetic Attic"), Locations:
    [
        new SetupMoveLocation(MoviesId, "Movies", "/synthetic/old/Movies", 415, [new MoveSuggestion("/mnt/other", 2), new MoveSuggestion("/mnt/media/Movies", 412)]),
        new SetupMoveLocation(ShowsId, "Shows", "/synthetic/old/Shows", 20, []),
    ]);

    private static (HostSetupModel Model, HostingScreenTests.ScriptedHost Host) Model(ScriptedMove move)
    {
        var settings = new MemorySettingsStore();
        settings.Write(AppFlow.OperatingModeKey, "host");
        var flow = new AppFlow(settings);
        var keyring = new MemoryCredentialStore();
        var api = new AureliaApi(new FakeServer());
        var session = new AppSession(flow, api, keyring, new ServerWakeUp(api, new NoWakeOnLan(), () => [], TimeProvider.System), "Test PC");
        var host = new HostingScreenTests.ScriptedHost(LocalServerState.SetupRequired) { SetupMove = move };
        var model = new HostSetupModel(host, session, flow, keyring, action => action(),
            () => [new DiscoveredServer(Guid.NewGuid(), "Synthetic Attic", new Uri("https://192.168.1.20:43111"))])
        {
            MovePollInterval = TimeSpan.FromMilliseconds(1),
        };
        return (model, host);
    }

    private static async Task Until(Func<bool> done)
    {
        for (var round = 0; round < 400 && !done(); round++) await Task.Delay(2, TestContext.Current.CancellationToken);
        Assert.True(done());
    }

    [Fact]
    public async Task OverTheNetworkTheDataArrivesTheFoldersAreChosenAndTheMovedServerSignsIn()
    {
        var move = new ScriptedMove().Then(new SetupMoveStatus("idle"), new SetupMoveStatus("idle"),
            new SetupMoveStatus("fetching", new SetupMoveProgress(1, 4), Source: new SetupMoveSource(Guid.NewGuid(), "Synthetic Attic")), Received());
        var (model, host) = Model(move);
        await model.StartAsync();
        Assert.Equal(HostPhase.OwnerSetup, model.Phase);
        Assert.True(model.CanMove);
        Assert.Equal("Synthetic Attic", Assert.Single(model.NearbyServers).Name);

        await model.BeginMoveAsync();
        Assert.Equal(HostPhase.MoveStart, model.Phase);
        await model.StartNetworkMoveAsync("192.168.1.20", "abcd efgh jkm");
        Assert.Contains("12-character", model.Error, StringComparison.Ordinal);
        await model.StartNetworkMoveAsync("192.168.1.20", "abcd efgh jkmn");
        Assert.Equal((new Uri("https://192.168.1.20:43111"), "ABCD-EFGH-JKMN"), move.Network);
        await Until(() => model.Phase == HostPhase.MoveLocations);
        Assert.Equal("Synthetic Attic", model.MoveSource);
        Assert.Equal(new MoveChoice(MoveChoiceKind.Suggestion, "/mnt/media/Movies"), model.MoveChoices[MoviesId]);
        Assert.Equal(MoveChoice.Later, model.MoveChoices[ShowsId]);

        await model.PreviewMoveFolderAsync(ShowsId, " /srv/shows ");
        Assert.Equal((ShowsId, "/srv/shows"), Assert.Single(move.Previews));
        Assert.Equal("18 of 20 sample files found", model.MovePreviews[ShowsId]);
        model.ChooseMoveFolder(ShowsId, new MoveChoice(MoveChoiceKind.Folder, "relative"));
        await model.FinishMoveAsync();
        Assert.Contains("starting with /", model.Error, StringComparison.Ordinal);
        Assert.Null(move.Finished);
        model.ChooseMoveFolder(ShowsId, new MoveChoice(MoveChoiceKind.Folder, "/srv/shows"));

        // The server reports "done" and keeps waiting: this app restarts it, as after creating an owner.
        host.AfterStart = LocalServerState.Running;
        move.Then(new SetupMoveStatus("done"));
        await model.FinishMoveAsync();
        Assert.Equal([new MoveMapping(MoviesId, "/mnt/media/Movies"), new MoveMapping(ShowsId, "/srv/shows")], move.Finished!.Mappings);
        await Until(() => model.Phase == HostPhase.SignIn);
        Assert.Equal(1, host.Restarts);
        Assert.True(model.MovedIn);
    }

    [Fact]
    public async Task AMovingFileIsOpenedWithItsPassphraseAndAFailureReturnsToTheStart()
    {
        var move = new ScriptedMove();
        var (model, _) = Model(move);
        await model.StartAsync();
        await model.BeginMoveAsync();
        using (var wrong = new MemoryStream("synthetic moving file"u8.ToArray()))
            await model.StartFileMoveAsync(wrong, "not it");
        Assert.Equal("The passphrase doesn't open this moving file.", model.Error);
        Assert.Equal(HostPhase.MoveStart, model.Phase);

        move.Then(new SetupMoveStatus("fetching"), new SetupMoveStatus("failed", Error: "The synthetic bundle is damaged."));
        using (var right = new MemoryStream("synthetic moving file"u8.ToArray()))
            await model.StartFileMoveAsync(right, "synthetic passphrase");
        Assert.Equal(("synthetic moving file", "synthetic passphrase"), move.File);
        await Until(() => model.Phase == HostPhase.MoveStart && model.Error is not null);
        Assert.Equal("The synthetic bundle is damaged.", model.Error);

        await model.CancelMoveAsync();
        Assert.Equal(HostPhase.OwnerSetup, model.Phase);
        Assert.Equal(1, move.Discards);
    }

    [Fact]
    public async Task AMoveAlreadyUnderWayIsPickedUpWhereItIs()
    {
        var move = new ScriptedMove { Last = Received() };
        var (model, _) = Model(move);
        await model.StartAsync();
        await model.BeginMoveAsync();
        await Until(() => model.Phase == HostPhase.MoveLocations);
        Assert.Equal(2, model.MoveLocations.Count);
    }
}

public sealed class ServerHostingKindTests
{
    [Fact]
    public void WhereTheServerRunsDecidesWhatTheServerSettingsOffer()
    {
        Assert.Equal(Core.Management.ServerHosting.LinuxPackage, Core.Management.ServerHostingKind.From(new ServerManagementCapabilities(true, false, false, "linux", true)));
        Assert.Equal(Core.Management.ServerHosting.MacApp, Core.Management.ServerHostingKind.From(new ServerManagementCapabilities(true, true, true, "macos", false)));
        Assert.Equal(Core.Management.ServerHosting.DesktopApp, Core.Management.ServerHostingKind.From(new ServerManagementCapabilities(true, true, true, "linux", false)));
        Assert.Equal(Core.Management.ServerHosting.Other, Core.Management.ServerHostingKind.From(new ServerManagementCapabilities(false, true, true, "linux", false)));
        Assert.Equal(Core.Management.ServerHosting.Other, Core.Management.ServerHostingKind.From(null));
        Assert.Equal("Aurelia on a PC", Core.Management.ServerHostingKind.Location(Core.Management.ServerHosting.DesktopApp));
        Assert.Null(Core.Management.ServerHostingKind.Location(Core.Management.ServerHosting.Other));
    }
}
