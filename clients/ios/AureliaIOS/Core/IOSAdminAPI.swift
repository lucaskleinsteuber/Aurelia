import Foundation

// Server administration requests, the same the Mac app and the browser send. Everything goes
// through `adminData`, which handles one-time approvals for protected changes.

extension IOSAPIClient {
  private func admin<Value: Decodable>(
    _ path: String, method: String = "GET", query: [URLQueryItem] = [], longRunning: Bool = false
  ) async throws -> Value {
    try Self.decodeAdmin(
      Value.self,
      data: await adminData(path, method: method, query: query, longRunning: longRunning))
  }
  private func admin<Value: Decodable>(
    _ path: String, method: String, json payload: some Encodable, longRunning: Bool = false
  ) async throws -> Value {
    try Self.decodeAdmin(
      Value.self,
      data: await adminData(
        path, method: method, body: JSONEncoder().encode(payload), longRunning: longRunning))
  }
  private func adminSend(_ path: String, method: String, longRunning: Bool = false) async throws {
    _ = try await adminData(path, method: method, longRunning: longRunning)
  }
  private func adminSend(_ path: String, method: String, json payload: some Encodable)
    async throws
  {
    _ = try await adminData(path, method: method, body: JSONEncoder().encode(payload))
  }
  private static func id(_ value: UUID) -> String { value.uuidString.lowercased() }

  // MARK: Management unlock

  /// Unlocks server management for ten minutes; the password is sent once and never stored.
  func unlockManagement(password: String) async throws -> Date {
    guard IOSServerPassword.isPlausible(password) else { throw IOSCoreError.invalidRequest }
    struct Payload: Encodable { let password: String }
    struct Response: Decodable { let expiresAt: String }
    let response: Response = try await admin(
      "/api/v1/management/unlock", method: "POST", json: Payload(password: password))
    guard let date = IOSServerDate.parse(response.expiresAt) else {
      throw IOSCoreError.invalidResponse
    }
    return date
  }
  func lockManagement() async throws {
    try await adminSend("/api/v1/management/lock", method: "POST")
  }
  /// The signed-in profile as the server sees it now, with its role and access.
  func currentAdminUser() async throws -> IOSAdminUser { try await admin("/api/v1/auth/me") }

  // MARK: Server

  func serverStatus() async throws -> IOSServerStatus { try await admin("/api/v1/server/status") }
  func serverHealth() async throws -> IOSServerHealth { try await admin("/api/v1/server/health") }
  func serverPerformance() async throws -> IOSServerPerformance {
    try await admin("/api/v1/server/health/performance")
  }
  func resetServerPerformance() async throws {
    try await adminSend("/api/v1/server/health/performance", method: "DELETE")
  }
  func serverCapabilities() async throws -> IOSServerCapabilities {
    try await admin("/api/v1/server/capabilities")
  }
  func serverSettings() async throws -> IOSServerConfiguration {
    try await admin("/api/v1/server/settings")
  }
  func saveServerSettings(_ stored: [String: IOSJSONValue]) async throws -> IOSServerConfiguration {
    try await admin("/api/v1/server/settings", method: "PUT", json: stored)
  }
  func restartServer() async throws -> IOSHostOperation {
    try await admin("/api/v1/server/operations/restart", method: "POST")
  }
  func serverJobs() async throws -> IOSServerJobs { try await admin("/api/v1/server/jobs") }
  func retryMetadataJob(id: UUID) async throws {
    try await adminSend("/api/v1/metadata/jobs/\(Self.id(id))/retry", method: "POST")
  }
  func serverDiagnostics() async throws -> [IOSDiagnosticEvent] {
    try await admin("/api/v1/server/diagnostics")
  }
  func serverDiagnosticsReport() async throws -> Data {
    try await adminData("/api/v1/server/diagnostics/export")
  }
  func serverTranscoding() async throws -> IOSTranscodingStatus {
    try await admin("/api/v1/server/transcoding")
  }

  // MARK: Backups

  func serverBackups() async throws -> [IOSServerBackup] { try await admin("/api/v1/server/backups") }
  func createBackup() async throws {
    try await adminSend("/api/v1/server/backups/database", method: "POST", longRunning: true)
  }
  func verifyBackup(name: String) async throws -> Bool {
    guard Self.isBackupName(name) else { throw IOSCoreError.invalidRequest }
    struct Verification: Decodable { let isValid: Bool }
    let result: Verification = try await admin(
      "/api/v1/server/backups/\(name)/verify", method: "POST", longRunning: true)
    return result.isValid
  }
  /// A backup's file name as the server lists it: no folders, nothing that changes the address.
  static func isBackupName(_ name: String) -> Bool {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    return (1...200).contains(name.count) && !name.contains("..")
      && name.unicodeScalars.allSatisfy(allowed.contains)
  }
  /// Has the server encrypt a backup with `passphrase` and saves it as `destination`.
  func exportEncryptedBackup(passphrase: String, to destination: URL) async throws {
    guard (12...1024).contains(passphrase.count) else { throw IOSCoreError.invalidRequest }
    struct Payload: Encodable { let passphrase: String }
    struct Transfer: Decodable { let id: UUID }
    let transfer: Transfer = try await admin(
      "/api/v1/server/backups/export", method: "POST", json: Payload(passphrase: passphrase),
      longRunning: true)
    let path = "/api/v1/server/backups/transfers/\(Self.id(transfer.id))"
    do {
      try await IOSLongRunningTransport().download(
        adminFileRequest(path), fingerprint: fingerprint, to: destination)
    } catch {
      try? await adminSend(path, method: "DELETE")
      throw error
    }
    try? await adminSend(path, method: "DELETE")
  }
  /// Sends an encrypted backup to the server and has it checked. Applying it is a second step.
  func prepareRestore(from file: URL, passphrase: String, acceptDifferentIdentity: Bool)
    async throws -> IOSPreparedRestore
  {
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, Int64(size) <= 4 * 1024 * 1024 * 1024, !passphrase.isEmpty else {
      throw IOSCoreError.invalidRequest
    }
    let upload = UUID()
    let path = "/api/v1/server/backups/uploads/\(Self.id(upload))"
    defer {
      Task { try? await adminSend("/api/v1/server/backups/transfers/\(Self.id(upload))", method: "DELETE") }
    }
    var request = try adminFileRequest(path, method: "PUT")
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    let response = try await IOSLongRunningTransport().upload(
      request, fingerprint: fingerprint, from: file)
    guard (200..<300).contains(response.statusCode) else {
      throw IOSCoreError.server(
        status: response.statusCode, code: nil, message: "The backup could not be sent.",
        retryAfter: nil)
    }
    struct Restore: Encodable {
      let uploadId: UUID
      let passphrase: String
      let revokeAllSessions: Bool
      let acceptDifferentServerIdentity: Bool
    }
    return try await admin(
      "/api/v1/server/backups/restore/prepare", method: "POST",
      json: Restore(
        uploadId: upload, passphrase: passphrase, revokeAllSessions: true,
        acceptDifferentServerIdentity: acceptDifferentIdentity), longRunning: true)
  }
  func applyRestore(id: UUID) async throws {
    try await adminSend("/api/v1/server/backups/restore/\(Self.id(id))/apply", method: "POST")
  }

  // MARK: Power and updates

  func serverPower() async throws -> IOSServerPower { try await admin("/api/v1/server/power") }
  func saveServerPower(_ payload: IOSPowerRules.Payload) async throws -> IOSServerPower {
    try await admin("/api/v1/server/power", method: "PUT", json: payload)
  }
  func serverUpdates() async throws -> IOSServerUpdateStatus {
    try await admin("/api/v1/server/updates")
  }
  func checkServerUpdates() async throws -> IOSServerUpdateStatus {
    try await admin("/api/v1/server/updates/check", method: "POST")
  }
  func installServerUpdate() async throws -> IOSServerUpdateStatus {
    try await admin("/api/v1/server/updates/install", method: "POST")
  }

  // MARK: Scrub previews, intros and credits, speech

  func serverScrubPreviews() async throws -> IOSScrubPreviewSettings {
    try await admin("/api/v1/server/scrub-previews")
  }
  func saveServerScrubPreviews(_ settings: IOSUpdateScrubPreviews) async throws
    -> IOSScrubPreviewSettings
  {
    try await admin("/api/v1/server/scrub-previews", method: "PUT", json: settings)
  }
  func deleteServerScrubPreviews() async throws -> IOSScrubPreviewSettings {
    try await admin("/api/v1/server/scrub-previews", method: "DELETE")
  }
  func serverSegments() async throws -> IOSSegmentSettings {
    try await admin("/api/v1/server/media-segments")
  }
  func saveServerSegments(enabled: Bool, usePictures: Bool?) async throws -> IOSSegmentSettings {
    struct Payload: Encodable {
      let enabled: Bool
      let usePictures: Bool?
    }
    return try await admin(
      "/api/v1/server/media-segments", method: "PUT",
      json: Payload(enabled: enabled, usePictures: usePictures))
  }
  func segmentSeries() async throws -> [IOSSegmentSeries] {
    try await admin("/api/v1/server/media-segments/series")
  }
  /// Examines one series again, every movie (`movies`), or everything when both are nil.
  func reanalyzeSegments(seriesId: UUID? = nil, movies: Bool = false) async throws
    -> IOSSegmentSettings
  {
    struct Payload: Encodable {
      let seriesId: String?
      let movies: Bool?
    }
    return try await admin(
      "/api/v1/server/media-segments/reanalyze", method: "POST",
      json: Payload(seriesId: seriesId.map(Self.id), movies: movies ? true : nil))
  }
  func serverSpeech() async throws -> IOSServerSpeech { try await admin("/api/v1/server/speech") }
  func downloadSpeechModel(_ name: String) async throws -> IOSServerSpeech {
    struct Payload: Encodable { let name: String }
    return try await admin("/api/v1/server/speech/model", method: "POST", json: Payload(name: name))
  }
  func removeSpeechModel() async throws -> IOSServerSpeech {
    try await admin("/api/v1/server/speech/model", method: "DELETE")
  }

  // MARK: Profiles

  func serverUsers() async throws -> [IOSUserAccessSummary] { try await admin("/api/v1/server/users") }
  func profileEditor(id: UUID) async throws -> IOSProfileEditor {
    try await admin("/api/v1/users/\(Self.id(id))/profile")
  }
  func createProfile(_ request: IOSProfileCreateRequest) async throws -> IOSAdminUser {
    try await admin("/api/v1/users", method: "POST", json: request)
  }
  func updateProfile(id: UUID, _ request: IOSProfileUpdateRequest) async throws -> IOSProfileEditor
  {
    try await admin("/api/v1/users/\(Self.id(id))/profile", method: "PUT", json: request)
  }
  func deleteProfile(id: UUID) async throws {
    try await adminSend("/api/v1/users/\(Self.id(id))", method: "DELETE")
  }
  func renameProfile(id: UUID, name: String) async throws -> IOSAdminUser {
    struct Payload: Encodable { let name: String }
    return try await admin(
      "/api/v1/users/\(Self.id(id))/name", method: "PUT", json: Payload(name: name))
  }
  func setProfilePicture(id: UUID, builtin: String?) async throws -> IOSAdminUser {
    struct Payload: Encodable { let builtin: String? }
    return try await admin(
      "/api/v1/users/\(Self.id(id))/picture", method: "PUT", json: Payload(builtin: builtin))
  }
  func resetProfilePIN(id: UUID, pin: String) async throws {
    guard IOSProfilePIN.isValid(pin) else { throw IOSCoreError.invalidRequest }
    struct Payload: Encodable { let pin: String }
    try await adminSend("/api/v1/users/\(Self.id(id))/pin", method: "PUT", json: Payload(pin: pin))
  }
  func ageLimit(user: UUID) async throws -> IOSProfileAgeLimit {
    try await admin("/api/v1/users/\(Self.id(user))/age-limit")
  }
  func setAgeLimit(user: UUID, _ value: IOSProfileAgeLimit) async throws -> IOSProfileAgeLimit {
    try await admin("/api/v1/users/\(Self.id(user))/age-limit", method: "PUT", json: value)
  }
  func screenTime(user: UUID) async throws -> IOSProfileScreenTime {
    try await admin("/api/v1/users/\(Self.id(user))/screen-time")
  }
  func setScreenTime(user: UUID, _ value: IOSProfileScreenTimeUpdate) async throws
    -> IOSProfileScreenTime
  {
    try await admin("/api/v1/users/\(Self.id(user))/screen-time", method: "PUT", json: value)
  }
  func grantScreenTime(user: UUID, _ grant: IOSScreenTimeGrant) async throws -> IOSProfileScreenTime
  {
    try await admin("/api/v1/users/\(Self.id(user))/screen-time/today", method: "POST", json: grant)
  }
  func titleAccess(user: UUID) async throws -> IOSTitleAccess {
    try await admin("/api/v1/users/\(Self.id(user))/titles")
  }
  func setTitleAccess(user: UUID, _ access: IOSTitleAccess) async throws -> IOSTitleAccess {
    try await admin("/api/v1/users/\(Self.id(user))/titles", method: "PUT", json: access)
  }

  // MARK: Devices

  func createPairingCode() async throws -> IOSPairingCode {
    try await admin("/api/v1/auth/pairings", method: "POST")
  }
  func lookupDevicePairing(code: String) async throws -> IOSDeviceAuthorizationPreview {
    let digits = code.filter(\.isNumber)
    guard digits.count == 8 else { throw IOSCoreError.invalidRequest }
    struct Payload: Encodable { let code: String }
    let preview: IOSDeviceAuthorizationPreview = try await admin(
      "/api/v1/server/device-pairings/lookup", method: "POST", json: Payload(code: digits))
    guard connection == nil || preview.serverId == connection?.serverID else {
      throw IOSCoreError.identityMismatch
    }
    return preview
  }
  func decideDevicePairing(id: UUID, approve: Bool) async throws -> IOSDeviceAuthorizationPreview {
    let preview: IOSDeviceAuthorizationPreview = try await admin(
      "/api/v1/server/device-pairings/\(Self.id(id))/\(approve ? "approve" : "deny")",
      method: "POST")
    guard preview.id == id else { throw IOSCoreError.invalidResponse }
    return preview
  }
  func ownDevices() async throws -> [IOSDeviceSession] { try await admin("/api/v1/auth/sessions") }
  func revokeOwnDevice(id: UUID) async throws {
    try await adminSend("/api/v1/auth/sessions/\(Self.id(id))", method: "DELETE")
  }
  func userDevices(user: UUID) async throws -> [IOSDeviceSession] {
    try await admin("/api/v1/server/sessions/\(Self.id(user))")
  }
  func revokeDevice(id: UUID) async throws {
    try await adminSend("/api/v1/server/sessions/\(Self.id(id))", method: "DELETE")
  }
  func revokeAllDevices(user: UUID) async throws {
    try await adminSend("/api/v1/users/\(Self.id(user))/sessions", method: "DELETE")
  }

  // MARK: Libraries

  func libraries() async throws -> [IOSLibrarySummary] { try await admin("/api/v1/libraries") }
  func serverFolders(path: String?) async throws -> IOSServerFolderListing {
    try await admin(
      "/api/v1/libraries/folders", query: path.map { [URLQueryItem(name: "path", value: $0)] } ?? [])
  }
  func createLibrary(_ request: IOSCreateLibraryRequest) async throws -> IOSLibrarySummary {
    try await admin("/api/v1/libraries", method: "POST", json: request)
  }
  func removeLibrary(id: UUID) async throws {
    try await adminSend("/api/v1/libraries/\(Self.id(id))", method: "DELETE")
  }
  func setLibraryMonitoring(id: UUID, enabled: Bool) async throws -> IOSLibrarySummary {
    try await admin(
      "/api/v1/libraries/\(Self.id(id))/monitoring", method: "PUT", json: ["enabled": enabled])
  }
  func scanLibrary(id: UUID) async throws -> IOSLibraryScan {
    try await admin("/api/v1/libraries/\(Self.id(id))/scans", method: "POST")
  }
  func scanAllLibraries() async throws -> [IOSLibraryScan] {
    try await admin("/api/v1/libraries/scans", method: "POST")
  }
  func activeScans() async throws -> [IOSLibraryScan] { try await admin("/api/v1/libraries/scans") }
  func libraryScans(id: UUID, limit: Int = 10) async throws -> [IOSLibraryScan] {
    try await admin(
      "/api/v1/libraries/\(Self.id(id))/scans",
      query: [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))])
  }
  func cancelScan(id: UUID) async throws {
    try await adminSend("/api/v1/scans/\(Self.id(id))", method: "DELETE")
  }
  func exclusions(library: UUID) async throws -> [IOSExcludedMedia] {
    try await admin("/api/v1/libraries/\(Self.id(library))/exclusions")
  }
  func restoreExclusion(library: UUID, id: UUID) async throws {
    try await adminSend(
      "/api/v1/libraries/\(Self.id(library))/exclusions/\(Self.id(id))", method: "DELETE")
  }
  func discoveries(library: UUID) async throws -> [IOSLibraryDiscovery] {
    try await admin("/api/v1/libraries/\(Self.id(library))/discoveries")
  }
  func setClassification(library: UUID, discovery: UUID, decision: String) async throws
    -> IOSLibraryScan
  {
    struct Update: Encodable {
      let discoveryId: UUID
      let decision: String
    }
    struct Payload: Encodable { let decisions: [Update] }
    return try await admin(
      "/api/v1/libraries/\(Self.id(library))/classification-decisions", method: "PUT",
      json: Payload(decisions: [Update(discoveryId: discovery, decision: decision)]))
  }
  func resetClassification(library: UUID, discovery: UUID) async throws -> IOSLibraryScan {
    try await admin(
      "/api/v1/libraries/\(Self.id(library))/classification-decisions/\(Self.id(discovery))",
      method: "DELETE")
  }
  func importReviews(library: UUID) async throws -> [IOSLibraryImportReview] {
    try await admin("/api/v1/libraries/\(Self.id(library))/import-reviews")
  }
  /// Ignores a file the scan could not place, or assigns it to a movie.
  func decideImportReview(library: UUID, review: UUID, movieId: UUID?) async throws
    -> IOSLibraryScan
  {
    struct Payload: Encodable {
      let action: String
      let movieId: UUID?
    }
    return try await admin(
      "/api/v1/libraries/\(Self.id(library))/import-reviews/\(Self.id(review))", method: "PUT",
      json: Payload(action: movieId == nil ? "ignore" : "assignToMovie", movieId: movieId))
  }
  func analyzeImport(library: UUID) async throws -> IOSImportPreviewSummary {
    try await admin(
      "/api/v1/libraries/\(Self.id(library))/import-preview", method: "POST", longRunning: true)
  }
  func importPreviewItems(library: UUID, preview: UUID, offset: Int, limit: Int = 500) async throws
    -> IOSImportPreviewPage
  {
    try await admin(
      "/api/v1/libraries/\(Self.id(library))/import-preview/\(Self.id(preview))/items",
      query: [
        URLQueryItem(name: "offset", value: String(max(offset, 0))),
        URLQueryItem(name: "limit", value: String(min(max(limit, 1), 500))),
      ])
  }
  func updateImportPreview(
    library: UUID, preview: UUID, revision: String, assignments: [IOSImportAssignment]
  ) async throws -> IOSImportPreviewSummary {
    struct Payload: Encodable {
      let revision: String
      let assignments: [IOSImportAssignment]
    }
    return try await admin(
      "/api/v1/libraries/\(Self.id(library))/import-preview/\(Self.id(preview))/assignments",
      method: "PUT", json: Payload(revision: revision, assignments: assignments))
  }
  func confirmImportPreview(library: UUID, preview: UUID, revision: String) async throws
    -> IOSLibraryScan
  {
    struct Payload: Encodable { let revision: String }
    return try await admin(
      "/api/v1/libraries/\(Self.id(library))/import-preview/\(Self.id(preview))/confirm",
      method: "POST", json: Payload(revision: revision))
  }

  // MARK: Library health and reset

  func healthDuplicates(offset: Int = 0, limit: Int = 50) async throws -> [IOSDuplicateGroup] {
    try await admin("/api/v1/library/health/duplicates", query: Self.page(offset, limit))
  }
  func healthOffline(days: Int = 30, offset: Int = 0, limit: Int = 50) async throws
    -> [IOSHealthOfflineTitle]
  {
    try await admin(
      "/api/v1/library/health/offline",
      query: [URLQueryItem(name: "days", value: String(days))] + Self.page(offset, limit))
  }
  func healthUnmatched(offset: Int = 0, limit: Int = 50) async throws -> [IOSUnmatchedTitle] {
    try await admin("/api/v1/library/health/unmatched", query: Self.page(offset, limit))
  }
  /// Keeps `target` and moves watch history, favorites and collections from `source` to it.
  func mergeDuplicates(source: UUID, target: UUID) async throws {
    struct Payload: Encodable {
      let sourceMediaId: UUID
      let targetMediaId: UUID
    }
    try await adminSend(
      "/api/v1/library/health/merge", method: "POST",
      json: Payload(sourceMediaId: source, targetMediaId: target))
  }
  /// Removes a catalog entry whose file is gone. The media itself is never touched.
  func removeHealthEntry(mediaId: UUID) async throws {
    try await adminSend("/api/v1/library/health/entries/\(Self.id(mediaId))", method: "DELETE")
  }
  func previewReset(libraries: [UUID]) async throws -> IOSResetLibraryPreview {
    try await admin("/api/v1/libraries/reset/preview", method: "POST", json: libraries)
  }
  func resetLibrary(_ preview: IOSResetLibraryPreview) async throws -> IOSLibraryMutation {
    struct Payload: Encodable {
      let libraryIds: [UUID]
      let revision: String
    }
    return try await admin(
      "/api/v1/libraries/reset", method: "POST",
      json: Payload(libraryIds: preview.libraryIds, revision: preview.revision), longRunning: true)
  }
  func libraryMutation(id: UUID) async throws -> IOSLibraryMutation {
    try await admin("/api/v1/library-operations/\(Self.id(id))")
  }
  private static func page(_ offset: Int, _ limit: Int) -> [URLQueryItem] {
    [
      URLQueryItem(name: "offset", value: String(max(offset, 0))),
      URLQueryItem(name: "limit", value: String(min(max(limit, 1), 200))),
    ]
  }

  // MARK: Metadata

  func metadataProvider() async throws -> IOSMetadataProvider {
    try await admin("/api/v1/metadata/provider")
  }
  func saveMetadataProvider(enabled: Bool, token: String?, language: String) async throws
    -> IOSMetadataProvider
  {
    struct Payload: Encodable {
      let enabled: Bool
      let language: String
      let token: String?
    }
    return try await admin(
      "/api/v1/metadata/provider", method: "PUT",
      json: Payload(enabled: enabled, language: language, token: token))
  }
  func removeMetadataToken() async throws -> IOSMetadataProvider {
    try await admin("/api/v1/metadata/provider/token", method: "DELETE")
  }
  func metadataJobs(activeOnly: Bool = false, limit: Int = 25) async throws -> [IOSMetadataJob] {
    try await admin(
      "/api/v1/metadata/jobs",
      query: [
        URLQueryItem(name: "activeOnly", value: activeOnly ? "true" : "false"),
        URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))),
      ])
  }
  /// Finds missing information (`fullRefresh` false) or refreshes every title.
  func startMetadataJob(libraryId: UUID? = nil, fullRefresh: Bool = false) async throws
    -> IOSMetadataJob
  {
    struct Payload: Encodable {
      let libraryId: UUID?
      let mode: String
    }
    return try await admin(
      "/api/v1/metadata/jobs", method: "POST",
      json: Payload(libraryId: libraryId, mode: fullRefresh ? "fullRefresh" : "incremental"))
  }
  func cancelMetadataJob(id: UUID) async throws {
    try await adminSend("/api/v1/metadata/jobs/\(Self.id(id))", method: "DELETE")
  }
  func metadataReviews() async throws -> [IOSMetadataReview] {
    try await admin("/api/v1/metadata/reviews")
  }
  func selectMetadataMatch(mediaId: UUID, candidate: IOSMetadataCandidate) async throws {
    struct Payload: Encodable {
      let providerMediaId: String
      let mediaType: String
    }
    try await adminSend(
      "/api/v1/media/\(Self.id(mediaId))/metadata/match", method: "PUT",
      json: Payload(providerMediaId: candidate.providerMediaId, mediaType: candidate.mediaType))
  }
  func clearMetadataMatch(mediaId: UUID) async throws {
    try await adminSend("/api/v1/media/\(Self.id(mediaId))/metadata/match", method: "DELETE")
  }
  func pruneArtwork() async throws {
    try await adminSend("/api/v1/metadata/artwork/prune", method: "POST")
  }
  func rebuildSearch() async throws {
    try await adminSend("/api/v1/catalog/search/rebuild", method: "POST")
  }
  func subtitleProvider() async throws -> IOSSubtitleProvider {
    try await admin("/api/v1/metadata/subtitles")
  }
  func saveSubtitleProvider(_ request: IOSUpdateSubtitleProvider) async throws
    -> IOSSubtitleProvider
  {
    try await admin("/api/v1/metadata/subtitles", method: "PUT", json: request)
  }
  func removeSubtitleKey() async throws -> IOSSubtitleProvider {
    try await admin("/api/v1/metadata/subtitles/key", method: "DELETE")
  }
  func removeSubtitleAccount() async throws -> IOSSubtitleProvider {
    try await admin("/api/v1/metadata/subtitles/account", method: "DELETE")
  }
}
