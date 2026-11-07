using System.Net;
using System.Text.Json;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Management;
using Aurelia.Linux.Library;
using Aurelia.Linux.Management;
using Aurelia.Linux.Settings;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.VisualTree;
using Xunit;

namespace Aurelia.Linux.Tests;

/// <summary>The owner's management screens with a scripted server and invented data.</summary>
public sealed class ManagementScreenTests
{
    private static readonly Guid LibraryId = Guid.Parse("b0000000-0000-4000-8000-000000000001");
    private static readonly Guid ProfileId = Guid.Parse("22222222-0000-4000-8000-000000000002");
    private static readonly Guid PreviewId = Guid.Parse("d0000000-0000-4000-8000-000000000001");

    private static string Json<T>(T value) => JsonSerializer.Serialize(value, AureliaJson.Options);

    /// <summary>The invented library plus answers for every management request.</summary>
    internal static FakeServer Server()
    {
        var now = DateTimeOffset.UtcNow;
        var readiness = new ServerReadinessSummary("ready", [new ServerComponentStatus("database", "ready")], now);
        var library = new LibrarySummary(LibraryId, "Films", "/srv/media/Films", LibraryKind.Movies, LibraryAvailability.Available, now.AddDays(-30), now.AddHours(-2), now.AddHours(-2), null);
        var waiting = library with { Id = Guid.NewGuid(), Name = "New Drive", Path = "/mnt/new", ImportPreviewRequired = true };
        var mia = new UserSummary(ProfileId, "Mia", UserRole.User, now, ProfileAccessMode.SelectedTitles, PinProtectionEnabled: false);
        var owner = new UserSummary(FakeLibrary.OwnerId, "Lucas", UserRole.Owner, now, ProfileAccessMode.EntireLibrary);
        var item = new ImportPreviewItem("Gamma Lights (2022).mkv", "Gamma Lights", MediaKind.Movie, null, null, null, null, ImportPreviewItemStatus.Recognized, "Movie name and year");
        var pending = new ImportPreviewItem("Extras/Making Of.mkv", "Making Of", null, null, null, null, null, ImportPreviewItemStatus.Pending, "No title found");
        var summary = new ImportPreviewSummary(PreviewId, LibraryId, "r1", "ready", new ImportPreviewCounts(2, 1, 0, 0, 0, 0, 1, 0, 0), [],
            [new ImportPreviewTarget("Gamma Lights (2022).mkv", "Gamma Lights", MediaKind.Movie, [])]);
        var settings = """
            {"stored":{"version":2,"serverName":"Living Room Server","lanAccessEnabled":true,"lanHttpsPort":43111,"revision":4,"pairingEnabled":true,
              "deviceSessionDays":90,"globalStreamLimit":32,"userStreamLimit":4,"bonjourEnabled":true,"allowedNetworks":null,"monitoringEnabled":true,
              "reconciliationMinutes":360,"maintenanceStartHour":0,"maintenanceEndHour":24,"jobQueueLimit":1000,"automaticBackupsEnabled":true,
              "backupIntervalHours":24,"dailyBackupsRetained":7,"weeklyBackupsRetained":4,"eventRetentionDays":30,"maximumEvents":10000,"futureField":"kept"},
             "active":{"serverName":"Living Room Server","lanAccessEnabled":true,"lanHttpsPort":43111},"restartRequired":false}
            """;
        return FakeLibrary.Create(pictures: false)
            .Answer("GET", "/api/v1/server/status", Json(new ServerStatusResponse("ready", "1.26.3 (120)", 93_600, 1, 52_000_000, 3, 1, 420_000_000_000, DateTime.UtcNow.AddYears(1), ["192.168.1.20"], readiness, [])))
            .Answer("GET", "/api/v1/server/health", Json(new ServerHealthResponse(93_600, 420_000_000_000, 52_000_000, 4, 12_000_000, 0, 0, 1, 0,
                new ServerHealthScanSummary(Guid.NewGuid(), "completed", now.AddHours(-2), now.AddHours(-2), 12, 3, 0, 1, 0), new ServerHealthBackgroundJobs(0, 0, 0),
                [new ServerHealthEvent(now.AddMinutes(-20), "scan_slow", "warning", null)], new ServerHealthBackupSummary(true, false, now.AddHours(-3), 6, 300_000_000, now, now))))
            .Answer("GET", "/api/v1/server/capabilities", Json(new ServerManagementCapabilities(false, true, true, "linux", true)))
            .Answer("GET", "/api/v1/server/settings", settings)
            .Answer("PUT", "/api/v1/server/settings", settings)
            .Answer("GET", "/api/v1/server/updates", Json(new ServerUpdateStatus(true, "1.26.2 (119)", "1.26.3 (120)", true, "idle", now.AddHours(-1), null)))
            .Answer("GET", "/api/v1/server/power", Json(new ServerPowerSettings(true, "sleep", 30, "17:00", "23:00")))
            .Answer("GET", "/api/v1/server/scrub-previews", Json(new ScrubPreviewSettingsResponse(true, "afterImport", 10, 500, 4, 12_000_000, 0, 2, 4, 6, false)))
            .Answer("GET", "/api/v1/server/backups", """[{"name":"aurelia-manual-1.db","kind":"manual","createdAt":"2026-10-31T20:00:00Z","bytes":5200000}]""")
            .Answer("GET", "/api/v1/server/jobs", """{"scans":[],"metadata":[]}""")
            .Answer("GET", "/api/v1/server/diagnostics", """[{"at":"2026-10-31T20:00:00Z","code":"scan_slow","severity":"warning"}]""")
            .Answer("GET", "/api/v1/server/users", Json(new[] { new UserAccessSummary(owner, true, []), new UserAccessSummary(mia, true, []) }))
            .Answer("GET", "/api/v1/auth/sessions", Json(new[]
            {
                new DeviceSessionSummary(Guid.NewGuid(), FakeLibrary.OwnerId, "This PC", now.AddDays(-3), now, now.AddDays(80), null, true),
                new DeviceSessionSummary(Guid.NewGuid(), FakeLibrary.OwnerId, "Living Room Apple TV", now.AddDays(-9), now.AddHours(-5), now.AddDays(80), null, false),
            }))
            .Answer("POST", "/api/v1/auth/pairings", Json(new PairingCodeResponse("48151623", now.AddMinutes(5))))
            .Answer("GET", $"/api/v1/users/{ProfileId}/profile", Json(new ProfileEditorResponse(mia, true, new ProfileTitleAccessResponse(ProfileAccessMode.SelectedTitles, [FakeLibrary.MovieA], 2), 2)))
            .Answer("GET", "/api/v1/libraries", Json(new[] { library, waiting }))
            .Answer("GET", "/api/v1/libraries/scans", "[]")
            .Answer("GET", $"/api/v1/libraries/{LibraryId}/import-reviews", "[]")
            .Answer("GET", $"/api/v1/libraries/{waiting.Id}/import-reviews", "[]")
            .Answer("GET", "/api/v1/libraries/folders", Json(new ServerFolderListing(null, null, [new ServerFolder("media", "/srv/media"), new ServerFolder("mnt", "/mnt")])))
            .Answer("POST", $"/api/v1/libraries/{LibraryId}/import-preview", Json(summary))
            .Answer("GET", $"/api/v1/libraries/{LibraryId}/import-preview/{PreviewId}/items", Json(new ImportPreviewPage(summary, [item, pending], 2, 0, 200)))
            .Answer("GET", $"/api/v1/libraries/{LibraryId}/import-assignments", Json(new ImportAssignmentsSummary("r1", [])))
            .Answer("GET", "/api/v1/metadata/provider", Json(new MetadataProviderStatus(true, true, "en-US", 80_000_000, 2_000_000_000, "TMDB", "This product uses the TMDB API but is not endorsed or certified by TMDB.")))
            .Answer("GET", "/api/v1/metadata/jobs", "[]")
            .Answer("GET", "/api/v1/metadata/subtitles", Json(new SubtitleProviderStatus(true, true, false, null, ["de", "en"], true, "OpenSubtitles",
                "Subtitles from OpenSubtitles.com", 17, null, null, 3)))
            .Answer("GET", "/api/v1/library/health/duplicates", "[]");
    }

    private static (Views.MainWindow Window, SettingsWindow Settings, FakeServer Server) Open(SettingsCategory category, FakeServer? server = null)
    {
        server ??= Server();
        var window = FakeLibrary.ShowLibrary(server);
        var settings = window.OpenSettings(category);
        FakeLibrary.Pump(() => false, rounds: 40);
        return (window, settings, server);
    }

    [AvaloniaFact]
    public void TheMetadataEditorShowsItsSectionsAsCards()
    {
        var credits = new[] { new EditorCredit(Guid.NewGuid(), "Diane Mercer", "Acting", null, "Commander Vale", null), new EditorCredit(Guid.NewGuid(), "Owen Hart", "Directing", "Director", null, null) };
        var values = new MediaEditorValues("Quiet Orbit", 2024, "An invented story about a quiet orbit.", 112, 12, ["Science Fiction", "Drama"], ["Invented Pictures"], "Germany", credits, null, null);
        var server = Server().Answer("GET", $"/api/v1/media/{FakeLibrary.MovieA}/editor",
            Json(new MediaEditorDocument(FakeLibrary.MovieA, LibraryId, MediaKind.Movie, 3, values, ["title"], "/srv/media/Films/Quiet Orbit (2024).mkv", "Quiet Orbit (2024).mkv", values)));
        var window = FakeLibrary.ShowLibrary(server);
        var movie = window.Session.Library!.Catalog.Single(item => item.Id == FakeLibrary.MovieA);
        _ = window.Shell!.ManageTitleAsync(movie, TitleAction.EditMetadata);
        FakeLibrary.Pump(() => window.Shell.SheetHost.Current is not null && All<TextBox>(window.Shell.SheetHost).Any(t => t.Text == "Quiet Orbit"), rounds: 200);
        var texts = All<TextBlock>(window.Shell.SheetHost).Select(t => t.Text).ToList();
        Assert.Contains("Title and Year", texts);
        Assert.Contains("Cast and Crew", texts);
        Assert.Contains("Release Year", texts);
        Assert.Contains(All<Button>(window.Shell.SheetHost), b => AutomationProperties.GetName(b) == "Use Automatic Value title");
        Assert.Contains(All<Button>(window.Shell.SheetHost), b => AutomationProperties.GetName(b) == "Move Diane Mercer Down");
        Snapshot(window, "metadata-editor");
    }

    [AvaloniaFact]
    public void TheMetadataEditorSearchesAndDownloadsSubtitles()
    {
        var values = new MediaEditorValues("Quiet Orbit", 2024, null, 112, null, [], [], null, [], null, null);
        var kept = new DownloadedSubtitle(Guid.NewGuid(), "en", "English · Downloaded", false, false, "OpenSubtitles", "Quiet.Orbit.2024.1080p", DateTimeOffset.UtcNow, true);
        var added = kept with { Id = Guid.NewGuid(), Language = "de", Title = "German (SDH) · Downloaded", HearingImpaired = true, Automatic = false };
        var subtitles = $"/api/v1/media/{FakeLibrary.MovieA}/subtitles";
        var server = Server()
            .Answer("GET", $"/api/v1/media/{FakeLibrary.MovieA}/editor",
                Json(new MediaEditorDocument(FakeLibrary.MovieA, LibraryId, MediaKind.Movie, 3, values, [], "/srv/media/Films/Quiet Orbit (2024).mkv", "Quiet Orbit (2024).mkv", values)))
            .Answer("GET", subtitles, Json(new[] { kept }))
            .Answer("GET", subtitles, Json(new[] { kept, added }))
            .Answer("GET", subtitles + "/search", Json(new[] { new SubtitleCandidate("101", "de", "Quiet.Orbit.German.SDH", true, true, false, false, 1204, true) }))
            .Answer("POST", subtitles, Json(added));
        var window = FakeLibrary.ShowLibrary(server);
        var movie = window.Session.Library!.Catalog.Single(item => item.Id == FakeLibrary.MovieA);
        _ = window.Shell!.ManageTitleAsync(movie, TitleAction.EditMetadata);
        FakeLibrary.Pump(() => window.Shell.SheetHost.Current is not null && All<Button>(window.Shell.SheetHost).Any(b => b.Content as string == "Search OpenSubtitles"), rounds: 200);
        var host = window.Shell.SheetHost;
        Assert.Contains(All<TextBlock>(host), t => t.Text == "Subtitles");
        Assert.Contains(All<TextBlock>(host), t => t.Text == "English · Downloaded");
        Assert.Contains(All<TextBlock>(host), t => t.Text == "Automatic");
        var language = All<ComboBox>(host).Single(box => AutomationProperties.GetName(box) == "Subtitle Language");
        Assert.Equal("German", language.SelectedItem);

        All<Button>(host).Single(b => b.Content as string == "Search OpenSubtitles").RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        FakeLibrary.Pump(() => All<TextBlock>(host).Any(t => t.Text == "Quiet.Orbit.German.SDH"), rounds: 100);
        Assert.Contains(server.RequestUris, uri => uri == $"GET {subtitles}/search?language=de");
        Assert.Contains(All<TextBlock>(host), t => t.Text?.StartsWith("Matches this file · SDH · Trusted · 1,204 downloads", StringComparison.Ordinal) == true);

        All<Button>(host).Single(b => b.Content as string == "Download").RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        FakeLibrary.Pump(() => All<TextBlock>(host).Any(t => t.Text == "German (SDH) · Downloaded"), rounds: 100);
        Assert.Contains("\"fileId\":\"101\"", server.Bodies[$"POST {subtitles}"], StringComparison.Ordinal);
        Snapshot(window, "metadata-editor-subtitles");
    }

    private static void Snapshot(Window window, string name)
    {
        using var frame = window.CaptureRenderedFrame()!;
        TestWindows.SaveSnapshot(frame, name);
    }

    private static Control? Sheet(SettingsWindow settings) => (settings.Sheets.Current as Border)?.Child;

    private static IEnumerable<T> All<T>(Control root) where T : Control => root.GetVisualDescendants().OfType<T>().Where(c => c.IsEffectivelyVisible);

    private static Button NamedButton(Control root, string name) =>
        All<Button>(root).First(b => AutomationProperties.GetName(b) == name || b.Content as string == name);

    private static void Click(Button button)
    {
        button.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        FakeLibrary.Pump(() => false, rounds: 30);
    }

    private static bool Shows(Control root, string text) => All<TextBlock>(root).Any(t => t.Text?.Contains(text, StringComparison.Ordinal) == true);

    [Fact]
    public void CategoriesFollowTheRole()
    {
        var now = DateTimeOffset.UtcNow;
        var owner = new UserSummary(Guid.NewGuid(), "Owner", UserRole.Owner, now);
        var admin = new UserSummary(Guid.NewGuid(), "Admin", UserRole.Admin, now, ProfileAccessMode.EntireLibrary);
        var limited = admin with { AccessMode = ProfileAccessMode.SelectedTitles };
        var viewer = new UserSummary(Guid.NewGuid(), "Viewer", UserRole.User, now);
        Assert.True(SettingsWindow.IsAvailable(SettingsCategory.Server, owner));
        Assert.False(SettingsWindow.IsAvailable(SettingsCategory.Server, admin));
        Assert.True(SettingsWindow.IsAvailable(SettingsCategory.Library, admin));
        Assert.False(SettingsWindow.IsAvailable(SettingsCategory.Library, limited));
        Assert.True(SettingsWindow.IsAvailable(SettingsCategory.Metadata, limited));
        Assert.False(SettingsWindow.IsAvailable(SettingsCategory.Metadata, viewer));
        Assert.True(SettingsWindow.IsAvailable(SettingsCategory.Playback, viewer));
        Assert.False(SettingsWindow.IsAvailable(SettingsCategory.Library, null));
    }

    [AvaloniaFact]
    public void TheOwnerSeesAndUsesTheServerSettings()
    {
        var (_, settings, server) = Open(SettingsCategory.Server);
        Assert.Contains(SettingsCategory.Server, settings.VisibleCategories);
        var page = settings.Page!;
        Assert.True(Shows(page, "Your Server"));
        Assert.True(Shows(page, "Linux Server"));
        Assert.True(Shows(page, "Server Health"));
        Assert.True(Shows(page, "Aurelia Server 1.26.3 (120) is available."));
        Assert.True(Shows(page, "Last backup:"));
        Assert.True(NamedButton(page, "Restart Server").IsEnabled);
        Snapshot(settings, "settings-server");

        var pairing = All<ToggleSwitch>(page).Single(t => AutomationProperties.GetName(t) == "Allow New Devices to Connect");
        pairing.IsChecked = false;
        FakeLibrary.Pump(() => server.Bodies.ContainsKey("PUT /api/v1/server/settings"), rounds: 40);
        var saved = JsonDocument.Parse(server.Bodies["PUT /api/v1/server/settings"]).RootElement;
        Assert.False(saved.GetProperty("pairingEnabled").GetBoolean());
        Assert.Equal("kept", saved.GetProperty("futureField").GetString());

        var advanced = All<Expander>(page).Single(e => e.Header as string == "Advanced Settings");
        advanced.IsExpanded = true;
        FakeLibrary.Pump(() => false, rounds: 40);
        Assert.True(Shows(page, "Sign-In & Streaming Limits"));
        Assert.True(Shows(page, "sudo aurelia setup"));
        Assert.True(Shows(page, "scan_slow"));
        Snapshot(settings, "settings-server-advanced");
    }

    [AvaloniaFact]
    public void ProfilesAndDevicesListPeopleAndMakeCodes()
    {
        var (_, settings, server) = Open(SettingsCategory.ProfilesAndDevices);
        var page = settings.Page!;
        FakeLibrary.Pump(() => Shows(page, "Mia"), rounds: 40);
        Assert.True(Shows(page, "Mia"));
        Assert.True(Shows(page, "No PIN · Selected Titles"));
        Assert.True(Shows(page, "Living Room Apple TV"));
        Assert.Contains(All<Button>(page), b => AutomationProperties.GetName(b) == "Delete Profile Mia");
        Assert.DoesNotContain(All<Button>(page), b => AutomationProperties.GetName(b) == "Delete Profile Lucas");
        Click(NamedButton(page, "Pair a Computer"));
        Assert.True(Shows(page, "Valid for"));
        Assert.Contains(All<SelectableTextBlock>(page), t => t.Text == "48151623");
        Snapshot(settings, "settings-profiles-devices");

        Click(NamedButton(page, "Edit Profile Mia"));
        var editor = Assert.IsType<ProfileEditorSheet>(Sheet(settings));
        Assert.True(Shows(editor, "1 selected"));
        Snapshot(settings, "profile-editor");
        Assert.Contains("GET /api/v1/users/" + ProfileId + "/profile", server.Requests);
    }

    [AvaloniaFact]
    public void AManagementLockAsksForTheServerPasswordOverTheEditor()
    {
        var server = Server()
            .Answer("PUT", $"/api/v1/users/{ProfileId}/profile", """{"code":"management_locked","message":"Unlock server management with the Server Password. Access lasts ten minutes."}""", HttpStatusCode.Forbidden)
            .Answer("PUT", $"/api/v1/users/{ProfileId}/profile", """{"code":"approval_required","message":"Authorize this exact change."}""", HttpStatusCode.Forbidden)
            .Answer("PUT", $"/api/v1/users/{ProfileId}/profile", Json(new ProfileEditorResponse(new UserSummary(ProfileId, "Mia", UserRole.Admin, DateTimeOffset.UtcNow), true,
                new ProfileTitleAccessResponse(ProfileAccessMode.SelectedTitles, [FakeLibrary.MovieA], 3), 3)))
            .Answer("POST", "/api/v1/management/unlock", Json(new ManagementUnlockResponse(DateTimeOffset.UtcNow.AddMinutes(10))))
            .Answer("POST", "/api/v1/management/approval", Json(new AdministrationApprovalResponse("approval-synthetic-token", DateTimeOffset.UtcNow.AddMinutes(2))));
        var (_, settings, _) = Open(SettingsCategory.ProfilesAndDevices, server);
        var page = settings.Page!;
        FakeLibrary.Pump(() => Shows(page, "Mia"), rounds: 40);
        Click(NamedButton(page, "Edit Profile Mia"));
        var editor = Assert.IsType<ProfileEditorSheet>(Sheet(settings));
        All<ComboBox>(editor).First(c => AutomationProperties.GetName(c) == "Role").SelectedIndex = 1;
        All<TextBox>(editor).Single(t => AutomationProperties.GetName(t) == "New PIN").Text = "2468";
        All<TextBox>(editor).Single(t => AutomationProperties.GetName(t) == "Confirm PIN").Text = "2468";
        Click(All<Button>(editor).Single(b => b.Content as string == "Save"));

        // The editor stays open below the prompt.
        var prompt = Sheet(settings)!;
        Assert.True(Shows(prompt, "Unlock Server Management"));
        Assert.False(Shows(prompt, "network trial"));
        Snapshot(settings, "server-password-prompt");
        All<TextBox>(prompt).Single(t => AutomationProperties.GetName(t) == "Server Password").Text = "synthetic server password";
        Click(All<Button>(prompt).Single(b => b.Content as string == "Unlock"));
        FakeLibrary.Pump(() => !settings.Sheets.IsShowing, rounds: 60);

        Assert.False(settings.Sheets.IsShowing);
        Assert.Contains("synthetic server password", server.Bodies["POST /api/v1/management/unlock"], StringComparison.Ordinal);
        var approval = JsonDocument.Parse(server.Bodies["POST /api/v1/management/approval"]).RootElement;
        Assert.Equal($"PUT /api/v1/users/{ProfileId}/profile", approval.GetProperty("action").GetString());
        var body = server.Bodies[$"PUT /api/v1/users/{ProfileId}/profile"];
        Assert.Equal(ManagementClient.PayloadHash(System.Text.Encoding.UTF8.GetBytes(body)), approval.GetProperty("payloadHash").GetString());
        Assert.Equal(3, server.Requests.Count(r => r == $"PUT /api/v1/users/{ProfileId}/profile"));
    }

    [AvaloniaFact]
    public void TheLibrarySettingsShowLocationsAndTheImportPreview()
    {
        var (_, settings, server) = Open(SettingsCategory.Library);
        var page = settings.Page!;
        FakeLibrary.Pump(() => Shows(page, "/srv/media/Films"), rounds: 40);
        Assert.True(Shows(page, "Movies · Available"));
        Assert.True(Shows(page, "Awaiting import confirmation"));
        Assert.True(Shows(page, "Danger Zone"));
        Snapshot(settings, "settings-library");

        Click(NamedButton(page, "Choose Folders on the Server…"));
        var picker = Assert.IsType<ServerFolderPicker>(Sheet(settings));
        Assert.Contains(All<Button>(picker), b => AutomationProperties.GetName(b) == "media");
        settings.Sheets.Close(false);

        Click(NamedButton(page, "Import Preview Films"));
        var preview = Assert.IsType<ImportPreviewSheet>(Sheet(settings));
        FakeLibrary.Pump(() => Shows(preview, "Gamma Lights"), rounds: 40);
        Assert.True(Shows(preview, "2 files · 1 movies"));
        Assert.True(Shows(preview, "Needs Review"));
        Snapshot(settings, "import-preview");
        Assert.Contains($"POST /api/v1/libraries/{LibraryId}/import-preview", server.Requests);
    }

    [AvaloniaFact]
    public void TheMetadataSettingsShowTmdb()
    {
        var (_, settings, _) = Open(SettingsCategory.Metadata);
        var page = settings.Page!;
        FakeLibrary.Pump(() => Shows(page, "Enabled"), rounds: 40);
        Assert.True(Shows(page, "TMDB"));
        Assert.Contains(All<Button>(page), b => b.Content as string == "Remove TMDB Token");
        FakeLibrary.Pump(() => Shows(page, "Downloads Left Today"), rounds: 40);
        Assert.True(Shows(page, "Subtitle Downloads"));
        Assert.True(Shows(page, "German, English"));
        Assert.Contains(All<ToggleSwitch>(page), toggle => AutomationProperties.GetName(toggle) == "Download missing subtitles automatically" && toggle.IsChecked == true);
        Assert.Contains(All<Button>(page), b => b.Content as string == "Remove API Key");
        Snapshot(settings, "settings-metadata");
    }

    [AvaloniaFact]
    public void TitleMenusOfferAdministratorActions()
    {
        var server = Server();
        var window = FakeLibrary.ShowLibrary(server);
        var context = new LibraryContext(window.Session.Library!, window.Shell!);
        var movie = window.Session.Library!.Catalog.First(item => item.Kind == MediaKind.Movie);
        var headers = MediaMenu.Items(context, movie, onDetail: true).OfType<MenuItem>().Select(item => item.Header as string).ToList();
        Assert.Contains("Edit Metadata…", headers);
        Assert.Contains("Find Metadata Match…", headers);
        Assert.Contains("Remove from Library…", headers);
        Assert.DoesNotContain("Find Metadata Match…", MediaMenu.Items(context, movie).OfType<MenuItem>().Select(item => item.Header as string));
    }

    [Fact]
    public void ImportAssignmentsFollowTheMacRules()
    {
        var file = new ImportPreviewItem("Show/Bonus.mkv", "Bonus", null, null, null, null, null, ImportPreviewItemStatus.Pending, "");
        var folder = file with { RelativePath = "Show/Extras", IsDirectory = true };
        ImportPreviewTarget[] targets = [new("Show", "Cobalt Station", MediaKind.Series, [1, 2]), new("Film.mkv", "Alpha", MediaKind.Movie, [])];
        Assert.NotNull(ImportPreviewModel.Assign([file], targets, ImportContentChoice.Extra, null, true, "1", "1", "", "").Problem);
        Assert.NotNull(ImportPreviewModel.Assign([file], targets, ImportContentChoice.Episode, "Film.mkv", true, "1", "1", "", "").Problem);
        Assert.NotNull(ImportPreviewModel.Assign([file, folder], targets, ImportContentChoice.Episode, "Show", true, "1", "1", "", "").Problem);
        Assert.NotNull(ImportPreviewModel.Assign([file], targets, ImportContentChoice.Episode, "Show", true, "100", "1", "", "").Problem);
        var (episode, _) = ImportPreviewModel.Assign([file], targets, ImportContentChoice.Episode, "Show", true, "2", "7", "", "Bonus Episode");
        Assert.Equal(new ImportAssignmentUpdate("Show/Bonus.mkv", false, MediaKind.Episode, "Show", 2, 7, null, "Bonus Episode"), Assert.Single(episode!));
        var (extras, _) = ImportPreviewModel.Assign([folder], targets, ImportContentChoice.Extra, "Show", false, "1", "", "Featurettes", "ignored");
        Assert.Equal(new ImportAssignmentUpdate("Show/Extras", true, MediaKind.Extra, "Show", 1, null, "Featurettes"), Assert.Single(extras!));
        var (ignored, _) = ImportPreviewModel.Assign([file], targets, ImportContentChoice.Ignore, null, true, "", "", "x", "");
        Assert.Null(Assert.Single(ignored!).Kind);
    }

    [Fact]
    public void EditorRulesCropsAndSmallFormats()
    {
        var values = new MediaEditorValues("Alpha", 2020, null, 100, null, [], [], null, [], null, null);
        Assert.Null(MetadataEditing.Problem(values));
        Assert.NotNull(MetadataEditing.Problem(values with { Title = " " }));
        Assert.NotNull(MetadataEditing.Problem(values with { ReleaseYear = 1700 }));
        Assert.NotNull(MetadataEditing.Problem(values with { RuntimeMinutes = 0 }));
        Assert.NotNull(MetadataEditing.Problem(values with { Credits = [new EditorCredit(Guid.NewGuid(), "", "Acting", null, null, null)] }));
        Assert.Equal(["Drama", "Action"], MetadataEditing.List("Drama, Action, drama,"));
        var overrides = MetadataEditing.Overrides(values with { Title = "Alpha Cut" }, values, ["overview"], new HashSet<string> { "overview" });
        Assert.Equal(["title"], overrides);

        // A 2:3 poster from a 1600×900 picture: full height, centered.
        var crop = MetadataEditing.Crop(1600, 900, 0, 2.0 / 3, 1, 0.5, 0.5);
        Assert.Equal(1, crop.Height, 6);
        Assert.Equal(900 * 2.0 / 3 / 1600, crop.Width, 6);
        Assert.Equal((1 - crop.Width) / 2, crop.X, 6);
        var turned = MetadataEditing.Crop(1600, 900, 90, 2.0 / 3, 2, 0, 1);
        Assert.Equal(90, turned.Rotation);
        Assert.True(turned.Y + turned.Height <= 1.000001 && turned.X == 0);

        Assert.Equal("48151623", PeoplePage.DeviceCode("4815-1623"));
        Assert.Null(PeoplePage.DeviceCode("4815162"));
        Assert.True(ServerPage.IsTime("07:30"));
        Assert.False(ServerPage.IsTime("7:30"));
        Assert.Equal("2 hours", ServerPage.IdleLabel(120));
        Assert.Equal("45 minutes", ServerPage.IdleLabel(45));
        Assert.Equal("2 GB", ServerPage.FormatCap(2000));
        Assert.Equal("250 MB", ServerPage.FormatCap(250));
        Assert.Equal("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", ManagementClient.PayloadHash([]));

        var remote = BrowserAddress.Resolve(new Uri("https://192.168.1.20:43111"), null, null);
        Assert.Equal("https://192.168.1.20:43111/", remote.Url.ToString());
        Assert.False(remote.ThisComputerOnly);
        var local = BrowserAddress.Resolve(new Uri("https://127.0.0.1:43110"), true, 43111, () => "192.168.1.30");
        Assert.Equal("https://192.168.1.30:43111/", local.Url.ToString());
        Assert.True(BrowserAddress.Resolve(new Uri("https://127.0.0.1:43110"), false, null, () => "192.168.1.30").ThisComputerOnly);
    }
}
