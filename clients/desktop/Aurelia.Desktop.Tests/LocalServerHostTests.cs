using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using Aurelia.Contracts;
using Aurelia.Desktop.Core;
using Xunit;

namespace Aurelia.Desktop.Tests;

/// <summary>
/// "Set Up This PC" with the real server build hosted by the app: setup, PIN, first storage
/// location and scan, Server Settings, a confirmed and an unconfirmed network change, recovery
/// after the server dies, a restart of the app, and an owner PIN reset. The server listens on
/// 127.0.0.1 only (network access stays off), keeps its data in a temporary folder and sees only
/// synthetic media made by the test.
/// </summary>
public sealed class LocalServerHostTests : IAsyncDisposable
{
    private const string Password = "synthetic local host password";
    private readonly string root = Path.Combine(Path.GetTempPath(), "aurelia-desktop-host-" + Guid.NewGuid().ToString("N"));
    private LocalServerOptions options;

    public LocalServerHostTests()
    {
        Directory.CreateDirectory(root);
        options = new LocalServerOptions(SyntheticServer.Executable ?? "", Path.Combine(root, "Server"), Path.Combine(root, "Logs"),
            FreePort(), FreePort(), DefaultLanAccess: false, "Synthetic Desktop Host");
        while (options.DefaultHttpsPort == options.HttpPort) options = options with { DefaultHttpsPort = FreePort() };
    }

    public ValueTask DisposeAsync()
    {
        try { Directory.Delete(root, recursive: true); }
        catch (IOException) { }
        return ValueTask.CompletedTask;
    }

    [Fact]
    public async Task SetsUpManagesRecoversAndReopensItsOwnServer()
    {
        Assert.SkipWhen(SyntheticServer.Executable is null, "Run scripts/test-desktop.sh, which builds the server for this test.");
        var cancellation = TestContext.Current.CancellationToken;
        var media = Path.Combine(root, "Media", "Synthetic Movie (2020)");
        Directory.CreateDirectory(media);
        SyntheticMedia.WriteAvi(Path.Combine(media, "Synthetic Movie (2020).avi"), [40, 200], secondsPerLevel: 5);
        using var api = new AureliaServerApi();
        var secrets = new MemorySecretStore();
        var store = new ConnectionStore(secrets);
        var modes = new AppModeStore(Path.Combine(root, "app-mode.json"));
        IServerManagement Management(StoredConnection connection, ProfileSessionResponse session) =>
            new ServerManagementClient(api, connection, session.Token);

        var host = new LocalServerHost(options);
        try
        {
            var flow = new HostSetupFlow(host, api, store, modes, Management, "Synthetic PC", action => action());
            var ready = new TaskCompletionSource<(StoredConnection Connection, ProfileSessionResponse? Session)>();
            flow.Ready += (connection, session) => ready.TrySetResult((connection, session));
            flow.ShowChoice();
            await flow.ChooseHostAsync();
            Assert.Equal(AppMode.Host, modes.Load());
            Assert.Equal(LocalServerState.SetupRequired, host.State);
            Assert.Equal(HostPhase.OwnerSetup, flow.Phase);
            Assert.Equal("Synthetic Desktop Host", flow.ServerName);

            await flow.SetUpAsync("too short", "too short");
            Assert.Equal("Use at least 12 characters for the Server Password.", flow.Error);
            flow.OwnerName = "Synthetic Owner";
            await flow.SetUpAsync(Password, Password);
            Assert.Null(flow.Error);
            Assert.Equal(HostPhase.CreatePin, flow.Phase);
            Assert.Equal(LocalServerState.Running, host.State);
            var saved = store.Load();
            Assert.NotNull(saved);
            Assert.True(saved.LocalHost);
            Assert.Equal(host.SecureAddress, saved.Address);

            await flow.CreatePinAsync("5682", "5682", password: null);
            Assert.Null(flow.Error);
            Assert.Equal(HostPhase.Storage, flow.Phase);
            flow.AddLocations([Path.Combine(root, "Media")]);
            await flow.ImportAsync();
            Assert.Null(flow.Error);
            var (connection, session) = await ready.Task.WaitAsync(TimeSpan.FromSeconds(60), cancellation);
            Assert.NotNull(session);
            using (var library = new LibraryClient(api, connection, session))
            {
                var movies = await library.BrowseAsync(MediaKind.Movie, new CatalogFilter(), 0, 50, cancellation);
                var movie = Assert.Single(movies.Items, item => item.Title == "Synthetic Movie");
                // Watched and the filters, as the real server understands them.
                var state = await library.WatchStateAsync(movie.Id, WatchStateScope.Title, null, cancellation);
                Assert.Equal(CatalogWatchState.Unplayed, state.WatchState);
                await library.SetWatchedAsync(movie.Id, true, WatchStateScope.Title, null, state.StateToken, cancellation);
                Assert.Contains((await library.BrowseAsync(MediaKind.Movie, new CatalogFilter(Watch: WatchFilter.Watched), 0, 50, cancellation)).Items,
                    item => item.Id == movie.Id && item.Progress?.IsCompleted == true);
                Assert.DoesNotContain((await library.BrowseAsync(MediaKind.Movie, new CatalogFilter(Watch: WatchFilter.Unwatched), 0, 50, cancellation)).Items,
                    item => item.Id == movie.Id);
                Assert.Single((await library.BrowseAsync(MediaKind.Movie,
                    new CatalogFilter(CatalogSort.DateAdded, Descending: true, Year: movie.Year), 0, 50, cancellation)).Items);
                var stale = library.SetWatchedAsync(movie.Id, false, WatchStateScope.Title, null, state.StateToken, cancellation);
                Assert.Equal("library_state_conflict", (await Assert.ThrowsAsync<AureliaApiException>(() => stale)).Code);
            }

            // Server Settings: management is still unlocked from setup.
            using (var settings = new ServerSettingsModel(host, api, connection, session, replacement => Management(connection, replacement), action => action()))
            {
                var replaced = new List<ProfileSessionResponse>();
                settings.SessionReplaced += replaced.Add;
                await settings.OpenAsync();
                Assert.False(settings.IsLocked);
                Assert.Equal("Running", settings.StateText);
                Assert.Equal("Only this computer", settings.Addresses);
                Assert.Single(settings.Storage);
                Assert.Contains(settings.Devices, device => device.Session.IsCurrent);

                // A renamed server, tried and confirmed on the restarted server with PIN and password.
                settings.ServerName = "Renamed Synthetic Host";
                Assert.True(settings.HasNetworkChange);
                await settings.ApplyNetworkAsync();
                Assert.Null(settings.Error);
                Assert.True(settings.IsTrialPending);
                await settings.ConfirmNetworkAsync("5682", Password);
                Assert.Null(settings.Error);
                Assert.False(settings.IsTrialPending);
                Assert.Single(replaced);
                Assert.Equal("Renamed Synthetic Host", settings.ServerName);
                Assert.Equal("Renamed Synthetic Host", (await api.ServerInfoAsync(connection, cancellation)).Name);
                session = replaced[0];
            }

            // Profiles, details and removal, with the real server's management unlock and approvals.
            var admin = Management(connection, session);
            var people = new ProfilesModel(() => admin);
            await people.LoadAsync();
            Assert.Null(people.Error);
            Assert.Single(people.Profiles);
            await people.BeginNewAsync();
            people.Name = "Synthetic Guest";
            people.Pin = "2468";
            people.PinConfirmation = "2468";
            people.AccessIndex = 1;
            people.Titles.Single(title => title.Title == "Synthetic Movie").IsSelected = true;
            await people.SaveAsync();
            Assert.Null(people.Error);
            var guest = Assert.Single(people.Profiles, row => row.Name == "Synthetic Guest");
            Assert.Equal("User · PIN · Selected titles", guest.Details);
            await people.BeginEditAsync(guest);
            Assert.True(people.Titles.Single(title => title.Title == "Synthetic Movie").IsSelected);
            people.AccessIndex = 0;
            people.PinProtection = false;
            await people.SaveAsync();
            Assert.Null(people.Error);
            Assert.Equal("User · No PIN · Entire library", Assert.Single(people.Profiles, row => row.Name == "Synthetic Guest").Details);
            await people.RemoveAsync(people.Profiles.Single(row => row.Name == "Synthetic Guest"));
            Assert.Null(people.Error);
            Assert.Single(people.Profiles);

            var access = new ManagementAccess(admin, _ => Task.FromResult<string?>(Password));
            using (var titles = new LibraryClient(api, connection, session))
            {
                var movie = (await titles.BrowseAsync(MediaKind.Movie, new CatalogFilter(), 0, 50, cancellation)).Items.Single();
                var editor = new MetadataEditorModel(access, movie.Id);
                await editor.LoadAsync();
                Assert.True(editor.IsLoaded);
                editor.Title = "Edited Synthetic Movie";
                await editor.ChooseImageAsync(poster: true, SyntheticMedia.Png(300, 450));
                Assert.Null(editor.Error);
                Assert.True(editor.PosterIsManual);
                await editor.SaveAsync();
                Assert.Null(editor.Error);
                Assert.Equal("Edited Synthetic Movie", (await titles.DetailAsync(movie.Id, cancellation)).Metadata.Title);
                editor.UseAutomatic("title");
                await editor.SaveAsync();
                Assert.Null(editor.Error);
                Assert.Equal("Synthetic Movie", (await titles.DetailAsync(movie.Id, cancellation)).Metadata.Title);

                // Scene notes, private to the profile.
                var noteId = Guid.NewGuid();
                await titles.SaveSceneNoteAsync(movie.Id, noteId, new SaveSceneNoteRequest(60_000, 90_000, "Synthetic scene", 0), cancellation);
                var note = Assert.Single(await titles.SceneNotesAsync(movie.Id, cancellation));
                Assert.Equal("Synthetic scene", note.Text);
                await titles.RemoveSceneNoteAsync(movie.Id, noteId, note.Revision, cancellation);
                Assert.Empty(await titles.SceneNotesAsync(movie.Id, cancellation));

                var model = new LibraryModel(titles) { Management = access };
                await model.OpenDetailAsync(movie.Id);
                await model.RemoveDetailAsync();
                Assert.Null(model.Error);
                Assert.Empty((await titles.BrowseAsync(MediaKind.Movie, new CatalogFilter(), 0, 50, cancellation)).Items);
            }

            // A server that dies is started again on its own.
            var first = host.ProcessId;
            Assert.NotNull(first);
            Process.GetProcessById(first.Value).Kill();
            await WaitForAsync(() => host.State == LocalServerState.Running && host.ProcessId is { } next && next != first, cancellation);
        }
        finally
        {
            await host.DisposeAsync();
        }
        Assert.Equal(LocalServerState.Stopped, host.State);

        // The app opens again: the server is set up, so the profiles come next.
        await using var reopened = new LocalServerHost(options);
        var again = new HostSetupFlow(reopened, api, store, modes, Management, "Synthetic PC", action => action());
        var profiles = new TaskCompletionSource<ProfileSessionResponse?>();
        again.Ready += (_, session) => profiles.TrySetResult(session);
        await again.StartAsync();
        Assert.Null(await profiles.Task.WaitAsync(TimeSpan.FromSeconds(30), cancellation));
        Assert.Equal(LocalServerState.Running, reopened.State);
        await WaitForAsync(() => !again.IsBusy, cancellation);

        // A forgotten owner PIN: the Server Password sets a new one on this computer only.
        again.BeginPinReset();
        await again.ResetPinAsync("not the password", "1234", "1234");
        Assert.Equal("The Server Password is not correct.", again.Error);
        await again.ResetPinAsync(Password, "1234", "1234");
        Assert.Null(again.Error);
        var local = store.Load()!;
        var picker = await api.ProfilesAsync(local, cancellation);
        var owner = picker.Profiles.Single(profile => profile.Role == UserRole.Owner);
        Assert.NotNull(await api.UnlockProfileAsync(local, owner.Id, "1234", cancellation));
    }

    [Fact]
    public async Task AnUnconfirmedNetworkChangeReturnsToThePreviousSettings()
    {
        Assert.SkipWhen(SyntheticServer.Executable is null, "Run scripts/test-desktop.sh, which builds the server for this test.");
        var cancellation = TestContext.Current.CancellationToken;
        using var api = new AureliaServerApi();
        var store = new ConnectionStore(new MemorySecretStore());
        await using var host = new LocalServerHost(options);
        var flow = new HostSetupFlow(host, api, store, new AppModeStore(Path.Combine(root, "app-mode.json")),
            (connection, session) => new ServerManagementClient(api, connection, session.Token), "Synthetic PC", action => action());
        var ready = new TaskCompletionSource<ProfileSessionResponse?>();
        flow.Ready += (_, session) => ready.TrySetResult(session);
        await flow.ChooseHostAsync();
        flow.OwnerName = "Synthetic Owner";
        await flow.SetUpAsync(Password, Password);
        await flow.CreatePinAsync("5682", "5682", null);
        flow.SkipStorage();
        var session = await ready.Task.WaitAsync(TimeSpan.FromSeconds(30), cancellation);
        var connection = store.Load()!;
        using var settings = new ServerSettingsModel(host, api, connection, session!,
            replacement => new ServerManagementClient(api, connection, replacement.Token), action => action());
        await settings.OpenAsync();
        settings.ServerName = "Never Confirmed";
        await settings.ApplyNetworkAsync();
        Assert.True(settings.IsTrialPending);
        await WaitForAsync(() => host.State == LocalServerState.Running && host.Settings.ServerName == "Never Confirmed", cancellation);

        // Nobody confirms: after the minute the host writes the previous settings back and restarts.
        await WaitForAsync(() => host.Settings.ServerName == "Synthetic Desktop Host", cancellation, TimeSpan.FromSeconds(90));
        string? name = null;
        for (var attempt = 0; attempt < 200 && name != "Synthetic Desktop Host"; attempt++)
        {
            try { name = (await api.ServerInfoAsync(connection, cancellation)).Name; }
            catch (AureliaApiException) { }
            if (name != "Synthetic Desktop Host") await Task.Delay(200, cancellation);
        }
        Assert.Equal("Synthetic Desktop Host", name);
        // The server may answer a moment before the host has read its info and reports it running.
        await WaitForAsync(() => host.State == LocalServerState.Running, cancellation, TimeSpan.FromSeconds(10));
    }

    [Fact]
    public async Task StorageIsReviewedBeforeAddingAndExcludedSourcesComeBack()
    {
        Assert.SkipWhen(SyntheticServer.Executable is null, "Run scripts/test-desktop.sh, which builds the server for this test.");
        var cancellation = TestContext.Current.CancellationToken;
        var media = Path.Combine(root, "Review");
        Directory.CreateDirectory(Path.Combine(media, "Synthetic Movie (2020)"));
        Directory.CreateDirectory(Path.Combine(media, "Odd Things"));
        SyntheticMedia.WriteAvi(Path.Combine(media, "Synthetic Movie (2020)", "Synthetic Movie (2020).avi"), [40, 200], secondsPerLevel: 5);
        SyntheticMedia.WriteAvi(Path.Combine(media, "Odd Things", "clip0001.avi"), [90], secondsPerLevel: 5);
        using var api = new AureliaServerApi();
        var store = new ConnectionStore(new MemorySecretStore());
        await using var host = new LocalServerHost(options);
        var flow = new HostSetupFlow(host, api, store, new AppModeStore(Path.Combine(root, "app-mode.json")),
            (connection, session) => new ServerManagementClient(api, connection, session.Token), "Synthetic PC", action => action());
        var ready = new TaskCompletionSource<ProfileSessionResponse?>();
        flow.Ready += (_, session) => ready.TrySetResult(session);
        await flow.ChooseHostAsync();
        flow.OwnerName = "Synthetic Owner";
        await flow.SetUpAsync(Password, Password);
        await flow.CreatePinAsync("5682", "5682", null);
        flow.SkipStorage();
        var session = (await ready.Task.WaitAsync(TimeSpan.FromSeconds(30), cancellation))!;
        var connection = store.Load()!;
        using var settings = new ServerSettingsModel(host, api, connection, session,
            replacement => new ServerManagementClient(api, connection, replacement.Token), action => action());
        await settings.OpenAsync();
        Assert.False(settings.IsLocked);

        // Reviewed first: nothing reaches the library until the preview is confirmed.
        LibrarySummary? waiting = null;
        settings.ImportPreviewRequested += library => waiting = library;
        settings.ReviewNewStorage = true;
        await settings.AddStorageAsync(media, LibraryKind.Movies);
        Assert.Null(settings.Error);
        Assert.NotNull(waiting);
        Assert.True(Assert.Single(settings.Storage).WaitsForReview);
        var preview = new ImportPreviewModel(() => settings.Administration, waiting);
        await preview.AnalyzeAsync();
        Assert.Null(preview.Error);
        Assert.True(preview.IsAnalyzed);
        Assert.Contains(preview.Items, row => row.Title == "Synthetic Movie");
        var odd = preview.Items.Single(row => row.Path.Contains("clip0001", StringComparison.Ordinal));
        odd.IsSelected = true;
        preview.ChoiceIndex = 5;
        await preview.AssignAsync();
        Assert.Null(preview.Error);
        Assert.Equal("Ignored", preview.Items.Single(row => row.Path.Contains("clip0001", StringComparison.Ordinal)).StatusText);
        var confirmed = false;
        preview.Confirmed += () => confirmed = true;
        await preview.ConfirmAsync();
        Assert.Null(preview.Error);
        Assert.True(confirmed);
        using var titles = new LibraryClient(api, connection, session);
        CatalogItemSummary? movie = null;
        await WaitForAsync(() =>
        {
            movie = titles.BrowseAsync(MediaKind.Movie, new CatalogFilter(), 0, 50, cancellation).GetAwaiter().GetResult().Items.SingleOrDefault();
            return movie is not null;
        }, cancellation);
        Assert.Equal("Synthetic Movie", movie!.Title);

        // Removed titles stay out of scans until reimported.
        var model = new LibraryModel(titles) { Management = new ManagementAccess(settings.Administration, _ => Task.FromResult<string?>(Password)) };
        await model.OpenDetailAsync(movie.Id);
        await model.RemoveDetailAsync();
        Assert.Null(model.Error);
        await settings.RefreshStorageAsync();
        await settings.Maintenance.LoadExclusionsAsync();
        Assert.Equal(settings.Maintenance.Exclusions.Count, settings.Maintenance.Exclusions.Select(item => item.Id).Distinct().Count());
        var excluded = Assert.Single(settings.Maintenance.Exclusions, item => item.RelativePath.Contains("Synthetic Movie", StringComparison.Ordinal));
        await settings.Maintenance.ReimportAsync(excluded);
        Assert.Null(settings.Maintenance.Error);
        await WaitForAsync(() => titles.BrowseAsync(MediaKind.Movie, new CatalogFilter(), 0, 50, cancellation).GetAwaiter().GetResult().Items.Count == 1,
            cancellation);

        // A reset is reviewed before it removes the location and its catalog; the files stay.
        settings.Maintenance.BeginReset();
        settings.Maintenance.ResetChoices.Single().IsSelected = true;
        await settings.Maintenance.ReviewResetAsync();
        Assert.Null(settings.Maintenance.Error);
        Assert.StartsWith("1 catalog entries", settings.Maintenance.ResetSummary, StringComparison.Ordinal);
        await settings.Maintenance.ResetAsync();
        Assert.Null(settings.Maintenance.Error);
        await WaitForAsync(() => settings.Storage.Count == 0, cancellation);
        Assert.True(File.Exists(Path.Combine(media, "Synthetic Movie (2020)", "Synthetic Movie (2020).avi")));
    }

    [Fact]
    public async Task BackupsAreMadeExportedAndRestoredThroughTheHost()
    {
        Assert.SkipWhen(SyntheticServer.Executable is null, "Run scripts/test-desktop.sh, which builds the server for this test.");
        var cancellation = TestContext.Current.CancellationToken;
        using var api = new AureliaServerApi();
        var store = new ConnectionStore(new MemorySecretStore());
        await using var host = new LocalServerHost(options);
        var flow = new HostSetupFlow(host, api, store, new AppModeStore(Path.Combine(root, "app-mode.json")),
            (connection, session) => new ServerManagementClient(api, connection, session.Token), "Synthetic PC", action => action());
        var ready = new TaskCompletionSource<ProfileSessionResponse?>();
        flow.Ready += (_, session) => ready.TrySetResult(session);
        await flow.ChooseHostAsync();
        flow.OwnerName = "Synthetic Owner";
        await flow.SetUpAsync(Password, Password);
        await flow.CreatePinAsync("5682", "5682", null);
        flow.SkipStorage();
        var session = (await ready.Task.WaitAsync(TimeSpan.FromSeconds(30), cancellation))!;
        var connection = store.Load()!;
        var admin = new ServerManagementClient(api, connection, session.Token);
        var operations = new ServerOperationsModel(() => admin);

        await operations.LoadBackupsAsync();
        Assert.Null(operations.Error);
        var before = operations.Backups.Count;
        await operations.BackUpNowAsync();
        Assert.Null(operations.Error);
        Assert.Equal(before + 1, operations.Backups.Count);
        await operations.VerifyAsync(operations.Backups[0]);
        Assert.Null(operations.Error);

        // Diagnostics, and the metadata status (saving a token is not tried here: the server checks it with TMDB online).
        await operations.LoadEventsAsync();
        Assert.Null(operations.Error);
        var diagnostics = new MemoryStream();
        await operations.ExportDiagnosticsAsync(() => Task.FromResult<Stream?>(diagnostics));
        Assert.Null(operations.Error);
        Assert.Contains("\"formatVersion\"", System.Text.Encoding.UTF8.GetString(diagnostics.ToArray()), StringComparison.Ordinal);
        await operations.LoadProviderAsync();
        Assert.Null(operations.Error);
        Assert.False(operations.Provider?.HasToken);

        // An encrypted copy of the server as it is now.
        var exported = new MemoryStream();
        operations.ExportPassphrase = "a synthetic backup passphrase";
        operations.ExportConfirmation = "a synthetic backup passphrase";
        await operations.ExportAsync(() => Task.FromResult<Stream?>(exported));
        Assert.Null(operations.Error);
        var backup = exported.ToArray();
        Assert.True(backup.Length > 1000);

        // A profile added afterwards is gone once the backup is restored.
        var people = new ProfilesModel(() => admin);
        await people.BeginNewAsync();
        people.Name = "Added Later";
        people.PinProtection = false;
        await people.SaveAsync();
        Assert.Null(people.Error);
        Assert.Equal(2, people.Profiles.Count);

        operations.RestorePassphrase = "the wrong passphrase";
        await operations.PrepareRestoreAsync(() => Task.FromResult<ChosenFile?>(new ChosenFile(new MemoryStream(backup), backup.Length, "Synthetic.aureliabackup")));
        Assert.NotNull(operations.Error);
        Assert.False(operations.AwaitsRestoreConfirmation);
        operations.RestorePassphrase = "a synthetic backup passphrase";
        await operations.PrepareRestoreAsync(() => Task.FromResult<ChosenFile?>(new ChosenFile(new MemoryStream(backup), backup.Length, "Synthetic.aureliabackup")));
        Assert.Null(operations.Error);
        Assert.True(operations.AwaitsRestoreConfirmation);
        await operations.ApplyRestoreAsync();
        Assert.Null(operations.Error);

        // The host stops the server, applies the verified backup and starts it again; every device signs in again.
        await WaitForAsync(() => host.State == LocalServerState.Restarting, cancellation, TimeSpan.FromSeconds(30));
        await WaitForAsync(() => host.State == LocalServerState.Running, cancellation, TimeSpan.FromSeconds(120));
        Assert.True((await Assert.ThrowsAsync<AureliaApiException>(() => api.ProfilesAsync(connection, cancellation))).IsAuthenticationFailure);
        var owner = await host.SignInAsync("Synthetic Owner", Password, "Synthetic PC", cancellation);
        var again = connection with { DeviceToken = owner.Token, DeviceSessionId = owner.SessionId };
        var profiles = await api.ProfilesAsync(again, cancellation);
        Assert.DoesNotContain(profiles.Profiles, profile => profile.Name == "Added Later");
        Assert.Single(profiles.Profiles);

    }

    [Fact]
    public async Task AMissingServerIsReportedInsteadOfStarted()
    {
        await using var host = new LocalServerHost(options with { Executable = Path.Combine(root, "missing", "Aurelia.Server") });
        await host.StartAsync();
        Assert.Equal(LocalServerState.Failed, host.State);
        Assert.Contains("missing", host.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task TheControlChannelAnswersOnlyItsSecretPath()
    {
        Assert.SkipWhen(SyntheticServer.Executable is null, "Run scripts/test-desktop.sh, which builds the server for this test.");
        await using var host = new LocalServerHost(options);
        await host.StartAsync();
        var address = new UriBuilder("http", "127.0.0.1", ControlPort(host)).Uri;
        using var client = new HttpClient { BaseAddress = address };
        var cancellation = TestContext.Current.CancellationToken;
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync("/guess/hosting-status", cancellation)).StatusCode);
        var status = await client.GetAsync($"/{host.ControlSecret}/hosting-status", cancellation);
        Assert.Equal(HttpStatusCode.OK, status.StatusCode);
        Assert.Contains("\"backgroundEnabled\":false", await status.Content.ReadAsStringAsync(cancellation), StringComparison.Ordinal);
        // Owners on other devices see how this computer runs its server.
        host.Hosting = () => new HostingPreferences(KeepRunning: true, StartAtSignIn: true, KeepAwake: false);
        var hosting = await (await client.GetAsync($"/{host.ControlSecret}/hosting-status", cancellation)).Content.ReadAsStringAsync(cancellation);
        Assert.Contains("\"backgroundEnabled\":true", hosting, StringComparison.Ordinal);
        Assert.Contains("\"startAtLogin\":true", hosting, StringComparison.Ordinal);
        Assert.Contains("\"preventIdleSleep\":false", hosting, StringComparison.Ordinal);
        // A trial the server did not record is refused.
        using var trial = new StringContent($"{{\"id\":\"{Guid.NewGuid()}\"}}", System.Text.Encoding.UTF8, "application/json");
        Assert.Equal(HttpStatusCode.NotFound, (await client.PostAsync($"/{host.ControlSecret}/network-trial", trial, cancellation)).StatusCode);
    }

    private static int ControlPort(LocalServerHost host)
    {
        // The server learns the channel from its environment; the test reads it the same way the host built it.
        var field = typeof(LocalServerHost).GetField("control", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!;
        var channel = (HostControlChannel)field.GetValue(host)!;
        return channel.Address.Port;
    }

    private static async Task WaitForAsync(Func<bool> condition, CancellationToken cancellation, TimeSpan? limit = null)
    {
        var deadline = DateTimeOffset.UtcNow + (limit ?? TimeSpan.FromSeconds(45));
        while (!condition())
        {
            if (DateTimeOffset.UtcNow > deadline) throw new TimeoutException("The local server did not reach the expected state.");
            await Task.Delay(100, cancellation);
        }
    }

    private static int FreePort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }
}
