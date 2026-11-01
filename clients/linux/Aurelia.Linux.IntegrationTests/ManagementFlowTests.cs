using System.Text.Json.Nodes;
using Aurelia.Contracts;
using Aurelia.Linux.Core.Api;
using Aurelia.Linux.Core.Connection;
using Aurelia.Linux.Core.Library;
using Aurelia.Linux.Core.Management;
using Xunit;

namespace Aurelia.Linux.IntegrationTests;

/// <summary>
/// The owner and administrator requests of the management screens against the real server:
/// approvals, the Server Password unlock, settings, profiles, devices, storage, import previews,
/// Library Health, metadata, backups and diagnostics. Only synthetic one-byte files are read.
/// </summary>
public sealed class ManagementFlowTests : IDisposable
{
    private readonly RealServer server = new();
    private readonly AureliaApi api;
    private readonly List<string> prompts = [];
    private string? password = RealServer.OwnerPassword;

    public ManagementFlowTests() => api = new AureliaApi(server.Transport);

    public void Dispose()
    {
        api.Dispose();
        server.Dispose();
    }

    private async Task<ManagementClient> OpenAsync()
    {
        var (device, opened) = await server.SeedLibraryAsync();
        var inspected = await api.InspectAsync(RealServer.Address, TestContext.Current.CancellationToken);
        var stored = new StoredServer(inspected.Info.ServerId, inspected.Info.Name, inspected.Address, inspected.Fingerprint,
            device.Token, device.SessionId, device.ExpiresAt, device.User);
        var profile = new ProfileSession(opened.User, opened.SessionId, opened.Token, opened.ExpiresAt);
        var library = new LibraryClient(api, stored, profile, inspected.Info.Capabilities ?? []);
        return new ManagementClient(api, library, reason =>
        {
            prompts.Add(reason);
            return Task.FromResult(password);
        });
    }

    [Fact]
    public async Task ReadsTheServerAndSavesSettingsKeepingUnknownFields()
    {
        var client = await OpenAsync();
        var status = await client.StatusAsync();
        Assert.False(string.IsNullOrEmpty(status.Version));
        var health = await client.HealthAsync();
        Assert.True(health.DatabaseBytes > 0);
        var capabilities = await client.CapabilitiesAsync();
        Assert.False(capabilities.LinuxPackage);
        Assert.NotEqual(ServerHosting.LinuxPackage, ServerHostingKind.From(capabilities));

        var configuration = await client.SettingsAsync();
        var stored = (JsonObject)configuration["stored"]!.DeepClone();
        var revision = stored["revision"]!.GetValue<long>();
        stored["userStreamLimit"] = 3;
        stored["pairingEnabled"] = false;
        var saved = await client.SaveSettingsAsync(stored);
        Assert.Equal(3, saved["stored"]!["userStreamLimit"]!.GetValue<int>());
        Assert.False(saved["stored"]!["pairingEnabled"]!.GetValue<bool>());
        Assert.True(saved["stored"]!["revision"]!.GetValue<long>() > revision);
        // Every field the server knows survives the round trip, also those the app does not show.
        Assert.Equal(stored["maximumEvents"]!.GetValue<int>(), saved["stored"]!["maximumEvents"]!.GetValue<int>());

        var previews = await client.ScrubPreviewsAsync();
        var updated = await client.SaveScrubPreviewsAsync(new UpdateScrubPreviewSettingsRequest("onOpenOrPlay", 20, 250));
        Assert.Equal("onOpenOrPlay", updated.Mode);
        Assert.Equal(250, updated.StorageCapMegabytes);
        Assert.NotNull(previews);

        var power = await client.PowerAsync();
        Assert.False(power.Available);
        var updates = await client.UpdatesAsync();
        Assert.False(updates.Available);
        Assert.NotNull(await client.JobsAsync());
        Assert.NotNull(await client.DiagnosticsAsync());
        Assert.NotEmpty(await client.ExportDiagnosticsAsync());
    }

    [Fact]
    public async Task BacksUpListsAndVerifies()
    {
        var client = await OpenAsync();
        var earlier = (await client.BackupsAsync()).Count;
        await client.BackUpNowAsync();
        var backups = await client.BackupsAsync();
        Assert.Equal(earlier + 1, backups.Count);
        var backup = backups.First(b => b.Kind == "manual");
        Assert.Equal("manual", backup.Kind);
        Assert.True(backup.Bytes > 0);
        Assert.NotNull(await client.VerifyBackupAsync(backup.Name));
    }

    [Fact]
    public async Task ManagesProfilesWithTheServerPasswordWhenAsked()
    {
        var client = await OpenAsync();
        var created = await client.CreateProfileAsync(new CreateUserRequest("Mia", null, UserRole.User, "2468", true, ProfileAccessMode.SelectedTitles, [], true));
        var users = await client.UsersAsync();
        Assert.Contains(users, u => u.User.Id == created.Id && u.User.AccessMode == ProfileAccessMode.SelectedTitles);

        var editor = await client.ProfileAsync(created.Id);
        var catalog = await client.Library.BrowseAsync(new BrowseQuery(), null, TestContext.Current.CancellationToken);
        var title = catalog.First(item => item.Kind == MediaKind.Movie).Id;
        var saved = await client.SaveProfileAsync(created.Id, new UpdateProfileRequest(editor.Revision, UserRole.User, true, true, null, ProfileAccessMode.SelectedTitles, [title]));
        Assert.Equal([title], saved.Access.TitleIds);

        // Making the profile an administrator is a protected change: the client gets an approval
        // for exactly this request, after unlocking management with the Server Password if needed.
        var promoted = await client.SaveProfileAsync(created.Id, new UpdateProfileRequest(saved.Revision, UserRole.Admin, true, true, null));
        Assert.Equal(UserRole.Admin, promoted.User.Role);

        await client.DeleteProfileAsync(created.Id);
        Assert.DoesNotContain(await client.UsersAsync(), u => u.User.Id == created.Id);
    }

    [Fact]
    public async Task AWrongServerPasswordIsReportedAndCancellingStops()
    {
        var client = await OpenAsync();
        password = "not the password";
        var wrong = await Assert.ThrowsAsync<AureliaApiException>(() => client.UnlockAsync("test", TestContext.Current.CancellationToken));
        Assert.Equal("invalid_credentials", wrong.Code);
        password = null;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => client.UnlockAsync("test", TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task PairsDevicesAndListsSessions()
    {
        var client = await OpenAsync();
        var code = await client.CreatePairingCodeAsync();
        Assert.Equal(8, code.Code.Length);
        Assert.True(code.ExpiresAt > DateTimeOffset.UtcNow);
        var devices = await client.DevicesAsync();
        Assert.Contains(devices, d => d.IsCurrent);
        var unknown = await Assert.ThrowsAsync<AureliaApiException>(() => client.LookUpDeviceAsync("00000000"));
        Assert.Equal(404, unknown.Status);
    }

    [Fact]
    public async Task AddsAStorageLocationThroughTheImportPreview()
    {
        var client = await OpenAsync();
        var folders = await client.FoldersAsync(server.MediaDirectory);
        Assert.Contains(folders.Folders, f => f.Name == "Movies");

        var extra = Path.Combine(server.MediaDirectory, "More Films");
        Directory.CreateDirectory(extra);
        await File.WriteAllBytesAsync(Path.Combine(extra, "Gamma Lights (2022).mkv"), [5], TestContext.Current.CancellationToken);
        var library = await client.CreateLibraryAsync(new CreateLibraryRequest("More Films", extra, LibraryKind.Movies, RequireImportPreview: true));
        Assert.True(library.ImportPreviewRequired);

        var preview = new ImportPreviewModel(client, library);
        await preview.AnalyzeAsync();
        var item = Assert.Single(preview.Items, i => !i.IsDirectory);
        Assert.Equal(MediaKind.Movie, item.Kind);
        Assert.Equal("Import Recognized Items", preview.ConfirmLabel);

        var (changes, problem) = ImportPreviewModel.Assign([item], preview.Summary!.Targets, ImportContentChoice.Movie, null, true, "", "", "", "Gamma Lights Restored");
        Assert.Null(problem);
        await preview.ApplyAsync(changes!);
        Assert.True(preview.HasDraftChanges);
        Assert.Single(preview.Visible("", ImportPreviewFilter.Manual));
        Assert.True(preview.CanConfirm);

        var scan = await preview.ConfirmAsync();
        Assert.NotNull(scan);
        for (var attempt = 0; attempt < 200; attempt++)
        {
            if ((await client.ScanStatusAsync(scan.Id)).State == LibraryScanState.Completed) break;
            await Task.Delay(50, TestContext.Current.CancellationToken);
        }
        var libraries = await client.LibrariesAsync();
        Assert.False(libraries.Single(l => l.Id == library.Id).ImportPreviewRequired);
        var monitored = await client.SetMonitoringAsync(library.Id, false);
        Assert.False(monitored.MonitoringEnabled);
        Assert.Empty(await client.ImportReviewsAsync(library.Id));

        await client.RemoveLibraryAsync(library.Id);
        Assert.DoesNotContain(await client.LibrariesAsync(), l => l.Id == library.Id);
        Assert.True(File.Exists(Path.Combine(extra, "Gamma Lights (2022).mkv")));
    }

    [Fact]
    public async Task RemovesATitleKeepsItsFileAndReimportsIt()
    {
        var client = await OpenAsync();
        var catalog = await client.Library.BrowseAsync(new BrowseQuery(), null, TestContext.Current.CancellationToken);
        var beta = catalog.Single(item => item.Title.StartsWith("Beta", StringComparison.Ordinal));
        var file = Path.Combine(server.MediaDirectory, "Movies", "Beta Harbor (2021).mkv");
        var before = (new FileInfo(file).Length, File.GetLastWriteTimeUtc(file));

        // Removing a title needs the Server Password; the client asks for it only when the server does.
        await client.RemoveTitleAsync(beta.Id);
        Assert.NotEmpty(prompts);
        Assert.Equal(before, (new FileInfo(file).Length, File.GetLastWriteTimeUtc(file)));
        var after = await client.Library.BrowseAsync(new BrowseQuery(), null, TestContext.Current.CancellationToken);
        Assert.DoesNotContain(after, item => item.Id == beta.Id);

        var movies = (await client.LibrariesAsync()).Single(l => l.Kind == LibraryKind.Movies);
        var excluded = Assert.Single(await client.ExclusionsAsync(movies.Id));
        await client.ReimportAsync(movies.Id, excluded.Id);
        Assert.Empty(await client.ExclusionsAsync(movies.Id));
    }

    [Fact]
    public async Task ReadsLibraryHealthAndPreviewsAReset()
    {
        var client = await OpenAsync();
        Assert.Empty(await client.DuplicatesAsync());
        Assert.Empty(await client.OfflineAsync(7));
        Assert.NotNull(await client.UnmatchedAsync());
        var libraries = await client.LibrariesAsync();
        var preview = await client.PreviewResetAsync([.. libraries.Select(l => l.Id)]);
        Assert.Equal(2, preview.StorageLocations);
        Assert.True(preview.Titles >= 3);
    }

    [Fact]
    public async Task EditsMetadataAndKeepsManualChanges()
    {
        var client = await OpenAsync();
        var provider = await client.ProviderAsync();
        Assert.False(provider.HasToken);
        Assert.Empty(await client.ReviewsAsync());

        var catalog = await client.Library.BrowseAsync(new BrowseQuery(), null, TestContext.Current.CancellationToken);
        var alpha = catalog.Single(item => item.Title.StartsWith("Alpha", StringComparison.Ordinal));
        var document = await client.EditorAsync(alpha.Id);
        var values = document.Values with { Title = "Alpha Voyage: Director's Cut", Genres = ["Adventure"], FskAge = 12 };
        Assert.Null(MetadataEditing.Problem(values));
        var overrides = MetadataEditing.Overrides(values, document.AutomaticValues, document.OverrideFields, new HashSet<string>());
        Assert.Contains("title", overrides);
        var saved = await client.SaveEditorAsync(alpha.Id, new SaveMediaEditorRequest(document.Revision, values, overrides));
        Assert.Equal("Alpha Voyage: Director's Cut", saved.Values.Title);
        Assert.Contains("fsk", saved.OverrideFields);

        var stale = await Assert.ThrowsAsync<AureliaApiException>(() => client.SaveEditorAsync(alpha.Id, new SaveMediaEditorRequest(document.Revision, values, overrides)));
        Assert.Equal("editor_conflict", stale.Code);
        var files = await client.EditorFilesAsync(alpha.Id, null);
        Assert.Contains(files.Entries, e => e.Name == "Alpha Voyage (2020).mkv");
    }
}
