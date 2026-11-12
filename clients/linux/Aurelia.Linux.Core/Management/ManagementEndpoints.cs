using System.Text.Json.Nodes;
using Aurelia.Contracts;

namespace Aurelia.Linux.Core.Management;

/// <summary>The owner and administrator endpoints the management screens use, grouped like the Mac app's screens.</summary>
public sealed partial class ManagementClient
{
    // Server status, settings and operations (owner).
    public Task<ServerStatusResponse> StatusAsync() => GetAsync<ServerStatusResponse>("/api/v1/server/status");

    public Task<ServerHealthResponse> HealthAsync() => GetAsync<ServerHealthResponse>("/api/v1/server/health");

    public Task<ServerManagementCapabilities> CapabilitiesAsync() => GetAsync<ServerManagementCapabilities>("/api/v1/server/capabilities");

    /// <summary>The server's settings as JSON, so fields this app does not know are kept when saving.</summary>
    public Task<JsonObject> SettingsAsync() => GetAsync<JsonObject>("/api/v1/server/settings");

    public Task<JsonObject> SaveSettingsAsync(JsonObject stored) => SendAsync<JsonObject>(HttpMethod.Put, "/api/v1/server/settings", stored);

    public Task<JsonNode> RestartAsync() => SendAsync<JsonNode>(HttpMethod.Post, "/api/v1/server/operations/restart", null);

    public Task<ServerPowerSettings> PowerAsync() => GetAsync<ServerPowerSettings>("/api/v1/server/power");

    public Task<ServerPowerSettings> SavePowerAsync(UpdateServerPowerSettingsRequest request) =>
        SendAsync<ServerPowerSettings>(HttpMethod.Put, "/api/v1/server/power", request);

    public Task<ServerUpdateStatus> UpdatesAsync() => GetAsync<ServerUpdateStatus>("/api/v1/server/updates");

    public Task<ServerUpdateStatus> CheckUpdatesAsync() => SendAsync<ServerUpdateStatus>(HttpMethod.Post, "/api/v1/server/updates/check", null);

    public Task<ServerUpdateStatus> InstallUpdateAsync() => SendAsync<ServerUpdateStatus>(HttpMethod.Post, "/api/v1/server/updates/install", null);

    public Task<TranscodingStatusResponse> TranscodingAsync() => GetAsync<TranscodingStatusResponse>("/api/v1/server/transcoding");

    // Speech recognition on the server ("server-speech-v1").
    public Task<MediaSpeechResponse> MediaSpeechAsync(Guid mediaId) => GetAsync<MediaSpeechResponse>($"/api/v1/media/{mediaId}/speech");

    public Task<MediaSpeechResponse> StartSpeechAsync(Guid mediaId, StartSpeechJobRequest request) =>
        SendAsync<MediaSpeechResponse>(HttpMethod.Post, $"/api/v1/media/{mediaId}/speech", request);

    public Task CancelSpeechAsync(Guid mediaId) => SendAsync<JsonNode>(HttpMethod.Delete, $"/api/v1/media/{mediaId}/speech", null);

    public Task<ServerSpeechSettings> ServerSpeechAsync() => GetAsync<ServerSpeechSettings>("/api/v1/server/speech");

    public Task<ServerSpeechSettings> DownloadSpeechModelAsync(string name) =>
        SendAsync<ServerSpeechSettings>(HttpMethod.Post, "/api/v1/server/speech/model", new DownloadSpeechModelRequest(name));

    public Task<ServerSpeechSettings> RemoveSpeechModelAsync() => SendAsync<ServerSpeechSettings>(HttpMethod.Delete, "/api/v1/server/speech/model", null);

    // Intro and credits ("media-segments-v2").
    public Task<MediaSegmentsResponse> MediaSegmentsAsync(Guid mediaId) => GetAsync<MediaSegmentsResponse>($"/api/v1/media/{mediaId}/segments");

    public Task<MediaSegmentsResponse> SaveMediaSegmentsAsync(Guid mediaId, SetMediaSegmentsRequest request) =>
        SendAsync<MediaSegmentsResponse>(HttpMethod.Put, $"/api/v1/media/{mediaId}/segments", request);

    public Task<MediaSegmentsResponse> ResetMediaSegmentsAsync(Guid mediaId) =>
        SendAsync<MediaSegmentsResponse>(HttpMethod.Delete, $"/api/v1/media/{mediaId}/segments", null);

    public Task ReanalyzeMediaSegmentsAsync(Guid mediaId) => SendAsync<JsonNode>(HttpMethod.Post, $"/api/v1/media/{mediaId}/segments/reanalyze", null);

    public Task<MediaSegmentSettingsResponse> ServerMediaSegmentsAsync() => GetAsync<MediaSegmentSettingsResponse>("/api/v1/server/media-segments");

    public Task<MediaSegmentSettingsResponse> SaveServerMediaSegmentsAsync(UpdateMediaSegmentSettingsRequest request) =>
        SendAsync<MediaSegmentSettingsResponse>(HttpMethod.Put, "/api/v1/server/media-segments", request);

    public Task<IReadOnlyList<MediaSegmentSeriesStatus>> MediaSegmentSeriesAsync() =>
        GetAsync<IReadOnlyList<MediaSegmentSeriesStatus>>("/api/v1/server/media-segments/series");

    public Task<MediaSegmentSettingsResponse> ReanalyzeAllSegmentsAsync(Guid? seriesId) =>
        SendAsync<MediaSegmentSettingsResponse>(HttpMethod.Post, "/api/v1/server/media-segments/reanalyze", new ReanalyzeMediaSegmentsRequest(seriesId));

    /// <summary>Looks for every movie's credits again (servers from 2.11.0).</summary>
    public Task<MediaSegmentSettingsResponse> ReanalyzeMovieSegmentsAsync() =>
        SendAsync<MediaSegmentSettingsResponse>(HttpMethod.Post, "/api/v1/server/media-segments/reanalyze", new ReanalyzeMediaSegmentsRequest(Movies: true));

    public Task<ScrubPreviewSettingsResponse> ScrubPreviewsAsync() => GetAsync<ScrubPreviewSettingsResponse>("/api/v1/server/scrub-previews");

    public Task<ScrubPreviewSettingsResponse> SaveScrubPreviewsAsync(UpdateScrubPreviewSettingsRequest request) =>
        SendAsync<ScrubPreviewSettingsResponse>(HttpMethod.Put, "/api/v1/server/scrub-previews", request);

    public Task DeleteScrubPreviewsAsync() => SendAsync<JsonNode>(HttpMethod.Delete, "/api/v1/server/scrub-previews", null);

    public Task<IReadOnlyList<ServerEventSummary>> DiagnosticsAsync() => GetAsync<IReadOnlyList<ServerEventSummary>>("/api/v1/server/diagnostics");

    public Task<byte[]> ExportDiagnosticsAsync() => DownloadAsync("/api/v1/server/diagnostics/export");

    public Task<ServerJobHistory> JobsAsync() => GetAsync<ServerJobHistory>("/api/v1/server/jobs");

    /// <summary>Tries new network settings for 60 seconds; they are kept only after <see cref="ConfirmNetworkAsync"/> over the new connection.</summary>
    public Task<JsonObject> TryNetworkAsync(object request) => SendAsync<JsonObject>(HttpMethod.Post, "/api/v1/server/operations/network", request);

    public Task<HostOperationStatus> StartNetworkTrialAsync(JsonObject settings, bool confirmDisconnect) =>
        SendAsync<HostOperationStatus>(HttpMethod.Post, "/api/v1/server/operations/network", new { settings, confirmRemoteAccessDisabled = confirmDisconnect });

    public Task<JsonNode> ConfirmNetworkAsync(Guid operation, CancellationToken cancellation = default) =>
        SendAsync<JsonNode>(HttpMethod.Post, $"/api/v1/server/operations/{operation}/confirm", null, cancellation);

    // Backups (owner).
    public Task<IReadOnlyList<ServerBackupSummary>> BackupsAsync() => GetAsync<IReadOnlyList<ServerBackupSummary>>("/api/v1/server/backups");

    public Task<JsonObject> BackUpNowAsync() => SendAsync<JsonObject>(HttpMethod.Post, "/api/v1/server/backups/database", null);

    public Task<JsonNode> VerifyBackupAsync(string name) => SendAsync<JsonNode>(HttpMethod.Post, $"/api/v1/server/backups/{Uri.EscapeDataString(name)}/verify", null);

    /// <summary>Exports an encrypted backup with a passphrase and downloads it; the transfer is removed afterwards.</summary>
    public async Task<byte[]> ExportBackupAsync(string passphrase)
    {
        var started = await SendAsync<BackupExportResult>(HttpMethod.Post, "/api/v1/server/backups/export", new { passphrase });
        var id = started.Id.ToString();
        var bytes = await DownloadAsync($"/api/v1/server/backups/transfers/{Uri.EscapeDataString(id)}");
        try
        {
            await SendAsync<JsonNode>(HttpMethod.Delete, $"/api/v1/server/backups/transfers/{Uri.EscapeDataString(id)}", null);
        }
        catch (Api.AureliaApiException)
        {
        }
        return bytes;
    }

    /// <summary>Uploads a backup and has the server check it; returns the prepared restore.</summary>
    public async Task<PreparedRestore> PrepareRestoreAsync(byte[] backup, string passphrase, bool acceptDifferentServer)
    {
        var upload = Guid.NewGuid();
        await SendBytesAsync<JsonNode>(HttpMethod.Put, $"/api/v1/server/backups/uploads/{upload}", backup, "application/octet-stream");
        return await SendAsync<PreparedRestore>(HttpMethod.Post, "/api/v1/server/backups/restore/prepare",
            new { uploadId = upload, passphrase, revokeAllSessions = true, acceptDifferentServerIdentity = acceptDifferentServer });
    }

    /// <summary>Applies a prepared restore; it needs the Server Password and restarts the server.</summary>
    public Task<JsonNode> ApplyRestoreAsync(Guid restoreId) =>
        SendAsync<JsonNode>(HttpMethod.Post, $"/api/v1/server/backups/restore/{restoreId}/apply", null);

    // Devices and pairing.
    public Task<PairingCodeResponse> CreatePairingCodeAsync() => SendAsync<PairingCodeResponse>(HttpMethod.Post, "/api/v1/auth/pairings", new CreatePairingCodeRequest());

    public Task<DeviceAuthorizationPreview> LookUpDeviceAsync(string code) =>
        SendAsync<DeviceAuthorizationPreview>(HttpMethod.Post, "/api/v1/server/device-pairings/lookup", new DeviceAuthorizationLookupRequest(code));

    public Task<JsonNode> AnswerDeviceAsync(Guid id, bool approve) =>
        SendAsync<JsonNode>(HttpMethod.Post, $"/api/v1/server/device-pairings/{id}/{(approve ? "approve" : "deny")}", null);

    public Task<IReadOnlyList<DeviceSessionSummary>> DevicesAsync() => GetAsync<IReadOnlyList<DeviceSessionSummary>>("/api/v1/auth/sessions");

    public Task RevokeDeviceAsync(Guid id) => SendAsync<JsonNode>(HttpMethod.Delete, $"/api/v1/auth/sessions/{id}", null);

    // Profiles (owner).
    public Task<IReadOnlyList<UserAccessSummary>> UsersAsync() => GetAsync<IReadOnlyList<UserAccessSummary>>("/api/v1/server/users");

    public Task<ProfileEditorResponse> ProfileAsync(Guid id) => GetAsync<ProfileEditorResponse>($"/api/v1/users/{id}/profile");

    public Task<ProfileEditorResponse> SaveProfileAsync(Guid id, UpdateProfileRequest request) =>
        SendAsync<ProfileEditorResponse>(HttpMethod.Put, $"/api/v1/users/{id}/profile", request);

    public Task<UserSummary> RenameProfileAsync(Guid id, string name) =>
        SendAsync<UserSummary>(HttpMethod.Put, $"/api/v1/users/{id}/name", new UpdateProfileNameRequest(name));

    public Task<UserSummary> SetProfilePictureAsync(Guid id, string? builtin) =>
        SendAsync<UserSummary>(HttpMethod.Put, $"/api/v1/users/{id}/picture", new UpdateProfilePictureRequest(builtin));

    public Task<UserSummary> UploadProfilePhotoAsync(Guid id, byte[] image) =>
        SendBytesAsync<UserSummary>(HttpMethod.Put, $"/api/v1/users/{id}/picture/photo", image, "application/octet-stream");

    public Task<ProfileAgeLimitResponse> AgeLimitAsync(Guid id) => GetAsync<ProfileAgeLimitResponse>($"/api/v1/users/{id}/age-limit");

    public Task<ProfileAgeLimitResponse> SaveAgeLimitAsync(Guid id, UpdateProfileAgeLimitRequest request) =>
        SendAsync<ProfileAgeLimitResponse>(HttpMethod.Put, $"/api/v1/users/{id}/age-limit", request);

    public Task<ProfileScreenTimeResponse> ScreenTimeAsync(Guid id) => GetAsync<ProfileScreenTimeResponse>($"/api/v1/users/{id}/screen-time");

    public Task<ProfileScreenTimeResponse> SaveScreenTimeAsync(Guid id, UpdateProfileScreenTimeRequest request) =>
        SendAsync<ProfileScreenTimeResponse>(HttpMethod.Put, $"/api/v1/users/{id}/screen-time", request);

    public Task<ProfileScreenTimeResponse> GrantScreenTimeAsync(Guid id, GrantScreenTimeRequest request) =>
        SendAsync<ProfileScreenTimeResponse>(HttpMethod.Post, $"/api/v1/users/{id}/screen-time/today", request);

    public Task<UserSummary> CreateProfileAsync(CreateUserRequest request) => SendAsync<UserSummary>(HttpMethod.Post, "/api/v1/users", request);

    public Task ResetPinAsync(Guid id, string pin) => SendAsync<JsonNode>(HttpMethod.Put, $"/api/v1/users/{id}/pin", new ResetProfilePinRequest(pin));

    public Task DeleteProfileAsync(Guid id) => SendAsync<JsonNode>(HttpMethod.Delete, $"/api/v1/users/{id}", null);

    // Storage locations and scans (administrator with the whole library).
    public Task<IReadOnlyList<LibrarySummary>> LibrariesAsync() => GetAsync<IReadOnlyList<LibrarySummary>>("/api/v1/libraries");

    public Task<LibrarySummary> CreateLibraryAsync(CreateLibraryRequest request) => SendAsync<LibrarySummary>(HttpMethod.Post, "/api/v1/libraries", request);

    public Task RemoveLibraryAsync(Guid id) => SendAsync<JsonNode>(HttpMethod.Delete, $"/api/v1/libraries/{id}", null);

    public Task<LibrarySummary> SetMonitoringAsync(Guid id, bool enabled) =>
        SendAsync<LibrarySummary>(HttpMethod.Put, $"/api/v1/libraries/{id}/monitoring", new UpdateLibraryMonitoringRequest(enabled));

    public Task<LibraryScanSummary> ScanAsync(Guid libraryId) => SendAsync<LibraryScanSummary>(HttpMethod.Post, $"/api/v1/libraries/{libraryId}/scans", null);

    public Task<LibraryScanSummary> ScanStatusAsync(Guid scanId) => GetAsync<LibraryScanSummary>($"/api/v1/scans/{scanId}");

    public Task CancelScanAsync(Guid scanId) => SendAsync<JsonNode>(HttpMethod.Delete, $"/api/v1/scans/{scanId}", null);

    public Task<IReadOnlyList<LibraryScanSummary>> ActiveScansAsync() => GetAsync<IReadOnlyList<LibraryScanSummary>>("/api/v1/libraries/scans");

    public Task<ServerFolderListing> FoldersAsync(string? path) =>
        GetAsync<ServerFolderListing>("/api/v1/libraries/folders" + (path is null ? "" : "?path=" + Uri.EscapeDataString(path)));

    public Task<IReadOnlyList<ExcludedMediaSummary>> ExclusionsAsync(Guid libraryId) => GetAsync<IReadOnlyList<ExcludedMediaSummary>>($"/api/v1/libraries/{libraryId}/exclusions");

    public Task ReimportAsync(Guid libraryId, Guid excludedId) => SendAsync<JsonNode>(HttpMethod.Delete, $"/api/v1/libraries/{libraryId}/exclusions/{excludedId}", null);

    public Task<IReadOnlyList<LibraryImportReviewSummary>> ImportReviewsAsync(Guid libraryId) =>
        GetAsync<IReadOnlyList<LibraryImportReviewSummary>>($"/api/v1/libraries/{libraryId}/import-reviews");

    public Task<LibraryImportReviewSummary> ResolveImportReviewAsync(Guid libraryId, Guid reviewId, UpdateLibraryImportReviewRequest request) =>
        SendAsync<LibraryImportReviewSummary>(HttpMethod.Put, $"/api/v1/libraries/{libraryId}/import-reviews/{reviewId}", request);

    // Import preview: nothing is imported until the preview is confirmed.
    public Task<ImportPreviewSummary> AnalyzeImportAsync(Guid libraryId) =>
        SendAsync<ImportPreviewSummary>(HttpMethod.Post, $"/api/v1/libraries/{libraryId}/import-preview", null);

    public Task<ImportPreviewPage> ImportItemsAsync(Guid libraryId, Guid previewId, int offset, int limit, string? filter) =>
        GetAsync<ImportPreviewPage>($"/api/v1/libraries/{libraryId}/import-preview/{previewId}/items?offset={offset}&limit={limit}"
            + (string.IsNullOrEmpty(filter) ? "" : "&filter=" + Uri.EscapeDataString(filter)));

    public Task<ImportAssignmentsSummary> ImportAssignmentsAsync(Guid libraryId) =>
        GetAsync<ImportAssignmentsSummary>($"/api/v1/libraries/{libraryId}/import-assignments");

    public Task<ImportPreviewSummary> UpdateImportAsync(Guid libraryId, Guid previewId, ImportAssignmentsRequest request) =>
        SendAsync<ImportPreviewSummary>(HttpMethod.Put, $"/api/v1/libraries/{libraryId}/import-preview/{previewId}/assignments", request);

    public Task<LibraryScanSummary> ConfirmImportAsync(Guid libraryId, Guid previewId, string revision) =>
        SendAsync<LibraryScanSummary>(HttpMethod.Post, $"/api/v1/libraries/{libraryId}/import-preview/{previewId}/confirm", new ConfirmImportPreviewRequest(revision));

    // Library Health.
    public Task<IReadOnlyList<DuplicateGroup>> DuplicatesAsync() => GetAsync<IReadOnlyList<DuplicateGroup>>("/api/v1/library/health/duplicates");

    public Task<IReadOnlyList<OfflineTitleSummary>> OfflineAsync(int days) => GetAsync<IReadOnlyList<OfflineTitleSummary>>($"/api/v1/library/health/offline?days={days}");

    public Task<IReadOnlyList<UnmatchedTitleSummary>> UnmatchedAsync() => GetAsync<IReadOnlyList<UnmatchedTitleSummary>>("/api/v1/library/health/unmatched");

    public Task<JsonNode> MergeAsync(MergeMediaRequest request) => SendAsync<JsonNode>(HttpMethod.Post, "/api/v1/library/health/merge", request);

    public Task RemoveEntryAsync(Guid mediaId) => SendAsync<JsonNode>(HttpMethod.Delete, $"/api/v1/library/health/entries/{mediaId}", null);

    // Reset (needs the Server Password).
    public Task<ResetLibraryPreview> PreviewResetAsync(IReadOnlyList<Guid> libraryIds) =>
        SendAsync<ResetLibraryPreview>(HttpMethod.Post, "/api/v1/libraries/reset/preview", libraryIds);

    public Task<LibraryMutationResult> ResetAsync(ResetLibraryRequest request) => SendAsync<LibraryMutationResult>(HttpMethod.Post, "/api/v1/libraries/reset", request);

    public Task<LibraryMutationResult> OperationAsync(Guid id) => GetAsync<LibraryMutationResult>($"/api/v1/library-operations/{id}");

    // Subtitle downloads (OpenSubtitles).
    public Task<SubtitleProviderStatus> SubtitleProviderAsync() => GetAsync<SubtitleProviderStatus>("/api/v1/metadata/subtitles");

    public Task<SubtitleProviderStatus> SaveSubtitleProviderAsync(UpdateSubtitleProviderRequest request) =>
        SendAsync<SubtitleProviderStatus>(HttpMethod.Put, "/api/v1/metadata/subtitles", request);

    public Task<SubtitleProviderStatus> RemoveSubtitleKeyAsync() => SendAsync<SubtitleProviderStatus>(HttpMethod.Delete, "/api/v1/metadata/subtitles/key", null);

    public Task<SubtitleProviderStatus> RemoveSubtitleAccountAsync() => SendAsync<SubtitleProviderStatus>(HttpMethod.Delete, "/api/v1/metadata/subtitles/account", null);

    public Task<IReadOnlyList<DownloadedSubtitle>> DownloadedSubtitlesAsync(Guid mediaId) =>
        GetAsync<IReadOnlyList<DownloadedSubtitle>>($"/api/v1/media/{mediaId}/subtitles");

    public Task<IReadOnlyList<SubtitleCandidate>> SearchSubtitlesAsync(Guid mediaId, string language) =>
        GetAsync<IReadOnlyList<SubtitleCandidate>>($"/api/v1/media/{mediaId}/subtitles/search?language={Uri.EscapeDataString(language)}");

    public Task<DownloadedSubtitle> DownloadSubtitleAsync(Guid mediaId, DownloadSubtitleRequest request) =>
        SendAsync<DownloadedSubtitle>(HttpMethod.Post, $"/api/v1/media/{mediaId}/subtitles", request);

    public Task RemoveSubtitleAsync(Guid mediaId, Guid subtitleId) =>
        SendAsync<JsonNode>(HttpMethod.Delete, $"/api/v1/media/{mediaId}/subtitles/{subtitleId}", null);

    // Metadata and TMDB.
    public Task<MetadataProviderStatus> ProviderAsync() => GetAsync<MetadataProviderStatus>("/api/v1/metadata/provider");

    public Task<MetadataProviderStatus> SaveProviderAsync(UpdateMetadataProviderRequest request) =>
        SendAsync<MetadataProviderStatus>(HttpMethod.Put, "/api/v1/metadata/provider", request);

    public Task RemoveProviderTokenAsync() => SendAsync<JsonNode>(HttpMethod.Delete, "/api/v1/metadata/provider/token", null);

    public Task<MetadataJobSummary> StartMetadataJobAsync(StartMetadataJobRequest request) =>
        SendAsync<MetadataJobSummary>(HttpMethod.Post, "/api/v1/metadata/jobs", request);

    public Task<IReadOnlyList<MetadataJobSummary>> MetadataJobsAsync(bool activeOnly) =>
        GetAsync<IReadOnlyList<MetadataJobSummary>>($"/api/v1/metadata/jobs?activeOnly={(activeOnly ? "true" : "false")}&limit=20");

    public Task<MetadataJobSummary> RetryMetadataJobAsync(Guid id) => SendAsync<MetadataJobSummary>(HttpMethod.Post, $"/api/v1/metadata/jobs/{id}/retry", null);

    public Task CancelMetadataJobAsync(Guid id) => SendAsync<JsonNode>(HttpMethod.Delete, $"/api/v1/metadata/jobs/{id}", null);

    public Task<IReadOnlyList<MetadataReviewSummary>> ReviewsAsync() => GetAsync<IReadOnlyList<MetadataReviewSummary>>("/api/v1/metadata/reviews");

    public Task<JsonNode> PruneArtworkAsync() => SendAsync<JsonNode>(HttpMethod.Post, "/api/v1/metadata/artwork/prune", null);

    public Task<IReadOnlyList<MetadataCandidateSummary>> SearchMatchesAsync(Guid mediaId, string query) =>
        GetAsync<IReadOnlyList<MetadataCandidateSummary>>($"/api/v1/media/{mediaId}/metadata/search?query={Uri.EscapeDataString(query)}");

    public Task<JsonNode> SelectMatchAsync(Guid mediaId, SelectMetadataMatchRequest request) =>
        SendAsync<JsonNode>(HttpMethod.Put, $"/api/v1/media/{mediaId}/metadata/match", request);

    public Task ClearMatchAsync(Guid mediaId) => SendAsync<JsonNode>(HttpMethod.Delete, $"/api/v1/media/{mediaId}/metadata/match", null);

    public Task<MediaEditorDocument> EditorAsync(Guid mediaId) => GetAsync<MediaEditorDocument>($"/api/v1/media/{mediaId}/editor");

    public Task<MediaEditorDocument> SaveEditorAsync(Guid mediaId, SaveMediaEditorRequest request) =>
        SendAsync<MediaEditorDocument>(HttpMethod.Put, $"/api/v1/media/{mediaId}/editor", request);

    /// <summary>Uploads a JPEG, PNG or HEIC image up to 20 MB; the server decodes it and keeps it as a draft for this title.</summary>
    public Task<EditorUploadSummary> UploadArtworkAsync(Guid mediaId, byte[] image) =>
        SendBytesAsync<EditorUploadSummary>(HttpMethod.Post, $"/api/v1/media/{mediaId}/editor/uploads", image, "application/octet-stream");

    public Task<byte[]> EditorArtworkAsync(Guid mediaId, Guid assetId) => DownloadAsync($"/api/v1/media/{mediaId}/editor/artwork/{assetId}");

    public Task<byte[]> EditorUploadAsync(Guid mediaId, Guid uploadId) => DownloadAsync($"/api/v1/media/{mediaId}/editor/uploads/{uploadId}");

    public Task<ServerFileListing> EditorFilesAsync(Guid mediaId, string? path) =>
        GetAsync<ServerFileListing>($"/api/v1/media/{mediaId}/editor/files" + (path is null ? "" : "?path=" + Uri.EscapeDataString(path)));

    /// <summary>Removes a title from the library; the server asks for the Server Password.</summary>
    public Task RemoveTitleAsync(Guid mediaId) => SendAsync<JsonNode>(HttpMethod.Delete, $"/api/v1/media/{mediaId}", null);
}
