using System.Text.Json.Nodes;
using Aurelia.Contracts;
using Aurelia.Desktop.Core;

namespace Aurelia.Desktop.Tests;

/// <summary>A scripted bundled server: the test decides its state; nothing starts.</summary>
internal sealed class FakeLocalServerHost : ILocalServerHost
{
    public event Action? Changed;

    public LocalServerState State { get; private set; } = LocalServerState.Stopped;
    public string? Message { get; private set; }
    public ServerInfoResponse? Info { get; private set; }
    public LocalServerSettings Settings { get; set; } = new("Synthetic PC Server", true, 43111);
    public Uri SecureAddress => new($"https://127.0.0.1:{Settings.LanHttpsPort}");
    public bool SetUp { get; set; }
    public LocalServerState StartsAs { get; set; } = LocalServerState.SetupRequired;
    public List<string> Calls { get; } = [];

    public Task StartAsync()
    {
        Calls.Add("start");
        Move(SetUp ? LocalServerState.Running : StartsAs);
        return Task.CompletedTask;
    }

    public Task RestartAsync()
    {
        Calls.Add("restart");
        Move(LocalServerState.Restarting);
        Move(LocalServerState.Running);
        return Task.CompletedTask;
    }

    public Task StopAsync()
    {
        Calls.Add("stop");
        Move(LocalServerState.Stopped);
        return Task.CompletedTask;
    }

    public Task<AuthenticationResponse> SetUpOwnerAsync(string serverName, string ownerName, string password, string deviceName, CancellationToken cancellation)
    {
        Calls.Add($"setup {serverName} {ownerName}");
        SetUp = true;
        Move(LocalServerState.Restarting);
        Move(LocalServerState.Running);
        return Task.FromResult(Owner(ownerName));
    }

    public Task<AuthenticationResponse> SignInAsync(string ownerName, string password, string deviceName, CancellationToken cancellation) =>
        password == "synthetic server password"
            ? Task.FromResult(Owner(ownerName))
            : Task.FromException<AuthenticationResponse>(new AureliaApiException(401, "invalid_credentials", "The credentials are incorrect."));

    public Task ResetOwnerPinAsync(string password, string pin, CancellationToken cancellation)
    {
        Calls.Add("reset " + pin);
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    /// <summary>Moves the server as a real one would, telling the app.</summary>
    public void Move(LocalServerState state, string? message = null)
    {
        State = state;
        Message = message;
        Info = new ServerInfoResponse(FakeServerApi.ServerId, Settings.ServerName, "1.7.16", SetUp, Settings.LanAccessEnabled, Settings.LanHttpsPort, null, null);
        Changed?.Invoke();
    }

    private static AuthenticationResponse Owner(string name) => new(new UserSummary(FakeServerApi.Owner.Id, name, UserRole.Owner, DateTimeOffset.UtcNow),
        Guid.NewGuid(), "synthetic-device-token-0123456789-abcdef", DateTimeOffset.UtcNow.AddDays(90));
}

/// <summary>Scripted owner management with synthetic storage locations and devices.</summary>
internal sealed class FakeManagement : IServerManagement
{
    public bool Locked { get; set; }
    public List<string> Calls { get; } = [];
    public List<LibrarySummary> Libraries { get; } =
    [
        Library("Movies", @"D:\Media\Movies", LibraryKind.Movies, scanned: true),
        Library("TV Shows", @"E:\TV Shows", LibraryKind.TvShows, scanned: true, available: false),
    ];
    public List<LibraryScanSummary> Scans { get; } = [];
    public int ScanPollsUntilDone { get; set; } = 1;

    public Task<DateTimeOffset> UnlockAsync(string password, CancellationToken cancellation)
    {
        if (password != "synthetic server password")
            return Task.FromException<DateTimeOffset>(new AureliaApiException(401, "invalid_management_password", "Incorrect."));
        Locked = false;
        return Task.FromResult(DateTimeOffset.UtcNow.AddMinutes(10));
    }

    public Task<ServerStatusResponse> StatusAsync(CancellationToken cancellation) => Guard(new ServerStatusResponse("running", "1.7.16", 120, 0, 1 << 20, 2,
        Libraries.Count, 1L << 40, DateTime.UtcNow.AddYears(9), ["192.168.1.40"],
        new ServerReadinessSummary("degraded", [new ServerComponentStatus("media", "degraded")], DateTimeOffset.UtcNow), []));

    public Task<ServerSettingsDocument> SettingsAsync(CancellationToken cancellation) => Guard(new ServerSettingsDocument(new JsonObject
    {
        ["version"] = 2,
        ["serverName"] = "Synthetic PC Server",
        ["lanAccessEnabled"] = true,
        ["lanHttpsPort"] = 43111,
    }, false));

    public Task<IReadOnlyList<LibrarySummary>> LibrariesAsync(CancellationToken cancellation) => Guard<IReadOnlyList<LibrarySummary>>([.. Libraries]);

    public Task<IReadOnlyList<LibraryScanSummary>> ActiveScansAsync(CancellationToken cancellation)
    {
        if (ScanPollsUntilDone-- <= 0) Scans.Clear();
        return Guard<IReadOnlyList<LibraryScanSummary>>([.. Scans]);
    }

    public Task<LibrarySummary> AddLibraryAsync(string? name, string path, LibraryKind kind, CancellationToken cancellation)
    {
        Calls.Add($"add {path} {kind}");
        var library = Library(name ?? Path.GetFileName(path), path, kind, scanned: false);
        Libraries.Add(library);
        return Guard(library);
    }

    public Task<LibraryScanSummary> ScanAsync(Guid library, CancellationToken cancellation)
    {
        Calls.Add("scan " + Libraries.Single(value => value.Id == library).Name);
        var scan = new LibraryScanSummary(Guid.NewGuid(), library, LibraryScanState.Running, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, null,
            240, 96, 0, 0, 0, 0, null, []);
        Scans.Add(scan);
        return Guard(scan);
    }

    public Task RemoveLibraryAsync(Guid library, CancellationToken cancellation)
    {
        Calls.Add("remove " + library);
        Libraries.RemoveAll(value => value.Id == library);
        return Guard(0);
    }

    public Task<DeviceAuthorizationPreview> LookUpDeviceAsync(string code, CancellationToken cancellation) =>
        Guard(new DeviceAuthorizationPreview(Guid.NewGuid(), "Living Room Apple TV", FakeServerApi.ServerId, "Synthetic PC Server",
            DeviceAuthorizationState.Pending, DateTimeOffset.UtcNow.AddMinutes(5)));

    public Task AnswerDeviceAsync(Guid request, bool approve, CancellationToken cancellation)
    {
        Calls.Add(approve ? "approve" : "deny");
        return Guard(0);
    }

    public Task<IReadOnlyList<DeviceSessionSummary>> DevicesAsync(CancellationToken cancellation) => Guard<IReadOnlyList<DeviceSessionSummary>>(
    [
        new(Guid.NewGuid(), FakeServerApi.Owner.Id, "Synthetic PC", DateTimeOffset.UtcNow.AddDays(-3), DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddDays(87), null, true),
        new(Guid.NewGuid(), FakeServerApi.Owner.Id, "Living Room Apple TV", DateTimeOffset.UtcNow.AddDays(-30), DateTimeOffset.UtcNow.AddHours(-2),
            DateTimeOffset.UtcNow.AddDays(60), null, false),
    ]);

    public Task RemoveDeviceAsync(Guid session, CancellationToken cancellation)
    {
        Calls.Add("remove device");
        return Guard(0);
    }

    public Task<ServerOperationStatus> TryNetworkAsync(JsonObject settings, bool confirmDisconnect, CancellationToken cancellation)
    {
        Calls.Add($"trial {settings["serverName"]} {settings["lanAccessEnabled"]} {confirmDisconnect}");
        return Guard(new ServerOperationStatus(Guid.NewGuid(), "network", "awaitingConfirmation", DateTimeOffset.UtcNow.AddSeconds(60), 43111));
    }

    public Task ConfirmNetworkAsync(Guid operation, CancellationToken cancellation)
    {
        Calls.Add("confirm");
        return Guard(0);
    }

    public static readonly Guid GuestId = Guid.Parse("00000000-0000-0000-0000-0000000000e2");
    public List<(UserAccessSummary Access, ProfileAccessMode Mode, List<Guid> Titles, long Revision)> Users { get; } =
    [
        (new UserAccessSummary(new UserSummary(FakeServerApi.Owner.Id, "Alex", UserRole.Owner, DateTimeOffset.UtcNow), true, []),
            ProfileAccessMode.EntireLibrary, [], 1),
        (new UserAccessSummary(new UserSummary(GuestId, "Kim", UserRole.User, DateTimeOffset.UtcNow, ProfileAccessMode.SelectedTitles, false),
            true, []), ProfileAccessMode.SelectedTitles, [FakeLibraryApi.MovieId], 4),
    ];
    public long EditorRevision { get; private set; } = 2;
    public MediaEditorValues EditorValues { get; private set; } = new("Synthetic Movie", 2020, "A synthetic movie for tests.", 104, 12,
        ["Drama"], [], null, [], new EditorArtwork(AssetId: Guid.Parse("00000000-0000-0000-0000-0000000000f1")), null);
    public List<string> EditorOverrides { get; private set; } = [];
    public List<Guid> DiscardedUploads { get; } = [];
    public ImportPreviewSummary? ImportSummary { get; set; }
    public List<ServerBackupItem> Backups { get; } = [new("aurelia-auto.db", "automatic", DateTimeOffset.UtcNow.AddHours(-6), 3_400_000)];
    public MetadataProviderStatus Provider { get; set; } = new(false, false, "en-US", 0, 1L << 30, "TMDB",
        "This product uses the TMDB API but is not endorsed or certified by TMDB.");
    public List<string> Uploaded { get; } = [];

    public async Task DownloadAsync(string path, Stream destination, CancellationToken cancellation)
    {
        Calls.Add("download " + path.Split('/')[^2]);
        if (Locked) throw new AureliaApiException(403, "management_locked", "Unlock server management.");
        await destination.WriteAsync("synthetic encrypted backup"u8.ToArray(), cancellation);
    }

    public async Task UploadAsync(string path, Stream content, long length, CancellationToken cancellation)
    {
        using var copy = new MemoryStream();
        await content.CopyToAsync(copy, cancellation);
        Uploaded.Add($"{path} {copy.Length}");
    }

    /// <summary>The generic management requests the library, the editor and Profiles send, answered from memory.</summary>
    public Task<T> SendAsync<T>(HttpMethod method, string path, object? body, CancellationToken cancellation)
    {
        var route = path.Split('?', 2)[0];
        Calls.Add($"{method.Method} {route}");
        var parts = route.Split('/', StringSplitOptions.RemoveEmptyEntries);
        object? result = null;
        if (method == HttpMethod.Get && route == "/api/v1/server/users")
            result = Users.Select(user => user.Access with { User = user.Access.User with { AccessMode = user.Mode } }).ToList();
        else if (route == "/api/v1/users" && body is CreateUserRequest create)
        {
            var user = new UserSummary(Guid.NewGuid(), create.Username, create.Role, DateTimeOffset.UtcNow, create.AccessMode ?? ProfileAccessMode.EntireLibrary,
                create.PinProtectionEnabled ?? true);
            Users.Add((new UserAccessSummary(user, create.IsEnabled, []), user.AccessMode, [.. create.TitleIds ?? []], 1));
            Calls.Add($"create {create.Username} {create.Role} {create.Pin} {create.AccessMode} {create.TitleIds?.Count}");
            result = user;
        }
        else if (parts is ["api", "v1", "users", var id, "profile"] && Users.FindIndex(user => user.Access.User.Id == Guid.Parse(id)) is var index and >= 0)
        {
            var current = Users[index];
            if (body is UpdateProfileRequest update)
            {
                current = (current.Access with { IsEnabled = update.IsEnabled, User = current.Access.User with { Role = update.Role, PinProtectionEnabled = update.PinProtectionEnabled } },
                    update.AccessMode ?? current.Mode, [.. update.TitleIds ?? current.Titles], current.Revision + 1);
                Users[index] = current;
                Calls.Add($"update {current.Access.User.Username} {update.Role} {update.Pin} {update.AccessMode} {update.TitleIds?.Count}");
            }
            result = new ProfileEditorResponse(current.Access.User with { AccessMode = current.Mode }, current.Access.IsEnabled,
                new ProfileTitleAccessResponse(current.Mode, current.Titles, current.Revision), current.Revision);
        }
        else if (method == HttpMethod.Delete && parts is ["api", "v1", "users", var removed])
            Users.RemoveAll(user => user.Access.User.Id == Guid.Parse(removed));
        else if (method == HttpMethod.Get && route == "/api/v1/catalog/items")
        {
            IReadOnlyList<CatalogItemSummary> items = path.Contains("kind=movie", StringComparison.Ordinal) ? [FakeLibraryApi.Movie, FakeLibraryApi.SecondMovie] : [FakeLibraryApi.Series];
            result = new PagedResponse<CatalogItemSummary>(items, 0, 200, items.Count);
        }
        else if (parts is ["api", "v1", "media", var media, "editor"])
        {
            if (body is SaveMediaEditorRequest save)
            {
                if (save.Revision != EditorRevision) return Task.FromException<T>(new AureliaApiException(409, "editor_conflict", "Changed."));
                EditorRevision++;
                EditorValues = save.Values with
                {
                    Poster = save.Values.Poster?.UploadId is not null ? new EditorArtwork(AssetId: Guid.NewGuid()) : save.Values.Poster,
                };
                EditorOverrides = [.. save.OverrideFields];
            }
            result = new MediaEditorDocument(Guid.Parse(media), Guid.NewGuid(), MediaKind.Movie, EditorRevision, EditorValues, EditorOverrides,
                "/Volumes/Synthetic/Movies/Synthetic Movie (2020).mkv", "Synthetic Movie (2020).mkv",
                new MediaEditorValues("Synthetic Movie", 2020, "A synthetic movie for tests.", 104, 12, ["Drama"], [], null, [],
                    new EditorArtwork(AssetId: Guid.Parse("00000000-0000-0000-0000-0000000000f1")), null));
        }
        else if (method == HttpMethod.Get && parts is ["api", "v1", "media", _, "editor", "uploads" or "artwork", _])
            result = Png();
        else if (method == HttpMethod.Delete && parts is ["api", "v1", "media", _, "editor", "uploads", var upload])
            DiscardedUploads.Add(Guid.Parse(upload));
        else if (parts is ["api", "v1", "libraries", _, "import-preview", ..])
        {
            ImportSummary ??= new ImportPreviewSummary(Guid.NewGuid(), Libraries[0].Id, "r1", "ready",
                new ImportPreviewCounts(3, 1, 1, 1, 0, 0, 1, 0, 0), [],
                [new ImportPreviewTarget("Synthetic Series", "Synthetic Series", MediaKind.Series, [1])]);
            if (body is ImportAssignmentsRequest assign)
            {
                Calls.Add($"assign {string.Join(",", assign.Assignments.Select(change => $"{change.RelativePath}={change.Kind}"))}");
                ImportSummary = ImportSummary with { Revision = assign.Revision + "+", Counts = ImportSummary.Counts with { Pending = 0, Ignored = 1 } };
            }
            result = parts[^1] switch
            {
                "items" => new ImportPreviewPage(ImportSummary,
                [
                    new ImportPreviewItem("Synthetic Movie (2020)/Synthetic Movie (2020).mkv", "Synthetic Movie", MediaKind.Movie, null, null, null, null,
                        ImportPreviewItemStatus.Recognized, "Recognized from the folder name."),
                    new ImportPreviewItem("Synthetic Series/S01E01.mkv", "Pilot", MediaKind.Episode, "Synthetic Series", 1, 1, null,
                        ImportPreviewItemStatus.Recognized, "Season and episode in the file name."),
                    new ImportPreviewItem("Odd Things/clip0001.mkv", "clip0001", null, null, null, null, null,
                        ImportSummary.Counts.Pending > 0 ? ImportPreviewItemStatus.Pending : ImportPreviewItemStatus.Ignored,
                        "Aurelia could not tell what this is."),
                ], 3, 0, 200),
                "confirm" => new LibraryScanSummary(Guid.NewGuid(), Libraries[0].Id, LibraryScanState.Queued, DateTimeOffset.UtcNow, null, null,
                    0, 0, 0, 0, 0, 0, null, []),
                _ => (object)ImportSummary,
            };
        }
        else if (method == HttpMethod.Get && parts is ["api", "v1", "libraries", var library, "exclusions"])
            result = Guid.Parse(library) == Libraries[0].Id
                ? new List<ExcludedMediaSummary> { new(Guid.NewGuid(), Libraries[0].Id, "Old Cuts/Removed Movie (1999).mkv", false) }
                : new List<ExcludedMediaSummary>();
        else if (route == "/api/v1/libraries/reset/preview")
            result = new ResetLibraryPreview([Libraries[0].Id], "reset-1", 42, 40, 120, 1);
        else if (method == HttpMethod.Post && route == "/api/v1/libraries")
        {
            var location = (CreateLibraryRequest)body!;
            Calls.Add($"add {location.Path} {location.Kind}" + (location.RequireImportPreview || location.CombineExisting
                ? $" review={location.RequireImportPreview} combine={location.CombineExisting}" : ""));
            var added = Library(Path.GetFileName(location.Path), location.Path, location.Kind, scanned: false) with { ImportPreviewRequired = location.RequireImportPreview };
            Libraries.Add(added);
            result = added;
        }
        else if (method == HttpMethod.Get && route == "/api/v1/server/backups")
            result = Backups.ToList();
        else if (route == "/api/v1/server/backups/database")
        {
            Backups.Insert(0, new ServerBackupItem("aurelia-manual.db", "manual", DateTimeOffset.UtcNow, 3_500_000));
            result = new { name = "aurelia-manual.db" };
        }
        else if (parts is ["api", "v1", "server", "backups", _, "verify"])
            result = new BackupVerification(true, "ok", 12);
        else if (route == "/api/v1/server/backups/export")
            result = new BackupExport(Guid.NewGuid(), 4_200_000);
        else if (method == HttpMethod.Delete && parts is ["api", "v1", "server", "backups", "transfers", _])
            result = null;
        else if (route == "/api/v1/server/backups/restore/prepare")
            result = new PreparedServerRestore(Guid.NewGuid(), FakeServerApi.ServerId, true);
        else if (parts is ["api", "v1", "server", "backups", "restore", _, "apply"])
            result = new { state = "restarting" };
        else if (route == "/api/v1/server/diagnostics")
            result = new List<ServerEventItem>
            {
                new(DateTimeOffset.UtcNow.AddMinutes(-5), "library_unavailable", "warning"),
                new(DateTimeOffset.UtcNow.AddHours(-1), "server_started", "info"),
            };
        else if (route == "/api/v1/metadata/provider")
        {
            if (body is UpdateMetadataProviderRequest update)
                Provider = Provider with { Enabled = update.Enabled, HasToken = Provider.HasToken || update.Token is not null };
            result = Provider;
        }
        else if (route == "/api/v1/metadata/provider/token")
            result = Provider = Provider with { HasToken = false, Enabled = false };
        else if (route == "/api/v1/metadata/jobs")
            result = new MetadataJobSummary(Guid.NewGuid(), null, null, MetadataJobState.Queued, 2, 0, 0, 0, 0, null, DateTimeOffset.UtcNow, null, null);
        else if (method == HttpMethod.Delete && parts is ["api", "v1", "media", var title])
            result = new LibraryMutationResult(Guid.NewGuid(), "pending", 1, null);
        else
            return Task.FromException<T>(new AureliaApiException(404, "not_found", "No fake route for " + route));
        return Guard((T)result!);
    }

    public Task<T> SendBytesAsync<T>(HttpMethod method, string path, byte[] content, string contentType, CancellationToken cancellation)
    {
        Calls.Add($"upload {content.Length}");
        object result = new EditorUploadSummary(Guid.NewGuid(), path, 400, 600);
        return Guard((T)result);
    }

    private static byte[] Png()
    {
        using var bitmap = new SkiaSharp.SKBitmap(40, 60);
        bitmap.Erase(new SkiaSharp.SKColor(90, 120, 200));
        using var data = SkiaSharp.SKImage.FromBitmap(bitmap).Encode(SkiaSharp.SKEncodedImageFormat.Png, 90);
        return data.ToArray();
    }

    private Task<T> Guard<T>(T value) => Locked
        ? Task.FromException<T>(new AureliaApiException(403, "management_locked", "Unlock server management."))
        : Task.FromResult(value);

    private static LibrarySummary Library(string name, string path, LibraryKind kind, bool scanned, bool available = true) =>
        new(Guid.NewGuid(), name, path, kind, available ? LibraryAvailability.Available : LibraryAvailability.Unavailable,
            DateTimeOffset.UtcNow.AddDays(-10), scanned ? DateTimeOffset.UtcNow.AddHours(-3) : null, scanned ? DateTimeOffset.UtcNow.AddHours(-3) : null, null);
}

/// <summary>Start at sign-in and keeping awake as Windows would record them, without touching this computer.</summary>
internal sealed class FakeSystemHosting : ISystemHosting
{
    public bool CanStartAtSignIn => true;
    public SignInStart StartAtSignIn { get; private set; } = SignInStart.Off;
    public bool CanKeepAwake => true;
    public bool Awake { get; private set; }

    public void SetStartAtSignIn(bool enabled) => StartAtSignIn = enabled ? SignInStart.On : SignInStart.Off;
    public void KeepAwake(bool enabled) => Awake = enabled;

    /// <summary>The person turned Aurelia off in Task Manager's Startup apps.</summary>
    public void TurnOffInWindows() => StartAtSignIn = SignInStart.TurnedOffInWindows;
}
