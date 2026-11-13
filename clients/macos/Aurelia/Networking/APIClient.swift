import CryptoKit
@preconcurrency import Foundation

enum APIClientError: LocalizedError, Equatable {
  case invalidAddress
  case insecureAddress
  case invalidResponse
  case supersededSnapshot
  case serverIdentityMismatch
  case serverRejected(code: String, message: String)
  case httpFailure(status: Int, retryAfter: TimeInterval?, code: String?, message: String?)

  var httpStatus: Int? {
    if case .httpFailure(let status, _, _, _) = self { return status }
    return nil
  }

  var retryDelay: TimeInterval? {
    if case .httpFailure(_, let delay, _, _) = self { return delay }
    return nil
  }

  var isManagementLocked: Bool { problemCode == "management_locked" }
  var isAuthenticationFailure: Bool {
    !isManagementLocked && (httpStatus == 401 || httpStatus == 403)
  }
  var isRetryableTransient: Bool {
    guard let status = httpStatus else {
      return self == .invalidResponse || self == .supersededSnapshot
    }
    return status == 408 || status == 429 || status >= 500
  }

  var problemCode: String? {
    switch self {
    case .serverRejected(let code, _), .httpFailure(_, _, let code?, _): code
    default: nil
    }
  }

  var errorDescription: String? {
    switch self {
    case .invalidAddress:
      "Enter a valid server address."
    case .insecureAddress:
      "Aurelia requires an HTTPS server address."
    case .invalidResponse:
      "The server returned an invalid response."
    case .supersededSnapshot:
      "A newer library update replaced this request."
    case .serverIdentityMismatch:
      "The server identity does not match the paired server."
    case .serverRejected(_, let message):
      message
    case .httpFailure(let status, _, _, let message):
      message
        ?? (status == 401
          ? "The device session has expired or was revoked. Sign in again."
          : status == 403
            ? "The server did not allow this. Your profile may not have access."
            : "The server request failed (HTTP \(status)).")
    }
  }
}

struct APIClient: Sendable {
  let profile: StoredServerProfile
  /// Servers with "catalog-pages-500-v1" accept larger pages, so whole lists need fewer requests.
  var catalogPageSize = 100

  init(profile: StoredServerProfile) {
    self.profile = profile
  }

  static let largeCatalogPagesFeature = "catalog-pages-500-v1"

  func pagingCatalog(for capabilities: [String]?) -> APIClient {
    var client = self
    client.catalogPageSize =
      capabilities?.contains(Self.largeCatalogPagesFeature) == true ? 500 : 100
    return client
  }

  static func normalizedServerURL(_ input: String) throws -> URL {
    var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if !value.contains("://") {
      value = "https://\(value)"
    }
    guard var components = URLComponents(string: value),
      components.scheme?.lowercased() == "https",
      components.host != nil,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      components.path.isEmpty || components.path == "/"
    else {
      if URLComponents(string: value)?.scheme?.lowercased() == "http" {
        throw APIClientError.insecureAddress
      }
      throw APIClientError.invalidAddress
    }
    components.path = ""
    components.port = components.port ?? 43111
    guard let url = components.url else {
      throw APIClientError.invalidAddress
    }
    return url
  }

  static func inspect(baseURL: URL, timeout: TimeInterval = 15) async throws -> InspectedServer {
    let (data, _, delegate) = try await request(
      baseURL: baseURL,
      path: "/api/v1/server/info",
      method: "GET",
      token: nil,
      body: nil,
      trustMode: .inspect,
      timeout: timeout)
    let info = try decode(ServerInfoResponse.self, from: data)
    guard let fingerprint = delegate.capturedFingerprint,
      fingerprint.caseInsensitiveCompare(info.publicKeyFingerprint ?? "") == .orderedSame,
      info.lanAccessEnabled || baseURL.host == "127.0.0.1" || baseURL.host == "localhost"
        || baseURL.host == "::1"
    else {
      throw APIClientError.serverIdentityMismatch
    }
    return InspectedServer(
      baseURL: baseURL,
      info: info,
      publicKeyFingerprint: fingerprint)
  }

  static func pair(
    inspected: InspectedServer,
    code: String,
    deviceName: String
  ) async throws -> StoredServerProfile {
    let payload = try JSONEncoder().encode(
      RedeemPairingCodeRequest(code: code, deviceName: deviceName))
    let (data, _, _) = try await request(
      baseURL: inspected.baseURL,
      path: "/api/v1/auth/pair",
      method: "POST",
      token: nil,
      body: payload,
      trustMode: .pinned(inspected.publicKeyFingerprint))
    let authentication = try decode(AuthenticationResponse.self, from: data)
    return StoredServerProfile(
      serverId: inspected.info.serverId,
      name: inspected.info.name,
      baseURL: inspected.baseURL,
      publicKeyFingerprint: inspected.publicKeyFingerprint,
      token: authentication.token,
      sessionId: authentication.sessionId,
      expiresAt: authentication.expiresAt,
      user: authentication.user)
  }

  static func setupOwner(
    username: String,
    password: String,
    deviceName: String,
    bootstrapToken: String
  ) async throws -> AuthenticationResponse {
    let body = try JSONEncoder().encode(
      SetupOwnerRequest(username: username, password: password, deviceName: deviceName))
    let (data, _, _) = try await request(
      baseURL: URL(string: "http://127.0.0.1:43110")!,
      path: "/api/v1/setup/owner",
      method: "POST",
      token: nil,
      body: body,
      trustMode: .inspect,
      additionalHeaders: ["X-Aurelia-Bootstrap-Token": bootstrapToken])
    return try decode(AuthenticationResponse.self, from: data)
  }

  static func loginLocally(
    username: String,
    password: String,
    deviceName: String
  ) async throws -> AuthenticationResponse {
    let body = try JSONEncoder().encode(
      LoginRequest(username: username, password: password, deviceName: deviceName))
    let (data, _, _) = try await request(
      baseURL: URL(string: "http://127.0.0.1:43110")!,
      path: "/api/v1/auth/login",
      method: "POST",
      token: nil,
      body: body,
      trustMode: .inspect)
    return try decode(AuthenticationResponse.self, from: data)
  }

  static func profile(
    authentication: AuthenticationResponse,
    inspected: InspectedServer
  ) -> StoredServerProfile {
    StoredServerProfile(
      serverId: inspected.info.serverId,
      name: inspected.info.name,
      baseURL: inspected.baseURL,
      publicKeyFingerprint: inspected.publicKeyFingerprint,
      token: authentication.token,
      sessionId: authentication.sessionId,
      expiresAt: authentication.expiresAt,
      user: authentication.user)
  }

  func serverInfo() async throws -> ServerInfoResponse {
    try await get("/api/v1/server/info")
  }

  func watchingProfiles() async throws -> ProfilePickerResponse {
    try await get("/api/v1/profiles")
  }
  func initializeProfiles(password: String, pin: String) async throws {
    struct Payload: Encodable {
      let password: String
      let pin: String
    }
    _ = try await perform(
      path: "/api/v1/profiles/initialize", method: "POST",
      body: JSONEncoder().encode(Payload(password: password, pin: pin)))
  }
  func unlockProfile(id: UUID, pin: String) async throws -> ProfileSessionResponse {
    struct Payload: Encodable { let pin: String }
    return try Self.decode(
      ProfileSessionResponse.self,
      from: await perform(
        path: "/api/v1/profiles/\(id.uuidString)/unlock", method: "POST",
        body: JSONEncoder().encode(Payload(pin: pin))))
  }
  func endProfileSession(timeout: TimeInterval = 15) async throws {
    _ = try await perform(path: "/api/v1/profile/end", method: "POST", timeout: timeout)
  }
  func disconnectPairedDevice() async throws {
    _ = try await perform(path: "/api/v1/device", method: "DELETE")
  }
  func changeProfilePIN(current: String, new: String) async throws {
    struct Payload: Encodable {
      let currentPin: String
      let newPin: String
    }
    _ = try await perform(
      path: "/api/v1/profile/pin", method: "PUT",
      body: JSONEncoder().encode(Payload(currentPin: current, newPin: new)))
  }
  func resetProfilePIN(id: UUID, pin: String) async throws {
    struct Payload: Encodable { let pin: String }
    _ = try await perform(
      path: "/api/v1/users/\(id.uuidString)/pin", method: "PUT",
      body: JSONEncoder().encode(Payload(pin: pin)))
  }
  func setOwnPINProtection(current: String?, new: String?, enabled: Bool) async throws {
    struct Payload: Encodable {
      let currentPin: String?
      let pin: String?
      let pinProtectionEnabled: Bool
    }
    _ = try await perform(
      path: "/api/v1/profile/pin-protection", method: "PUT",
      body: JSONEncoder().encode(
        Payload(currentPin: current, pin: new, pinProtectionEnabled: enabled)))
  }
  func createProfile(request: ProfileCreateRequest) async throws -> UserSummary {
    try Self.decode(
      UserSummary.self,
      from: await perform(
        path: "/api/v1/users", method: "POST", body: JSONEncoder().encode(request)))
  }
  func profileEditor(id: UUID) async throws -> ProfileEditorResponse {
    try await get("/api/v1/users/\(id.uuidString)/profile")
  }
  func updateProfile(id: UUID, request: ProfileUpdateRequest) async throws -> ProfileEditorResponse
  {
    try Self.decode(
      ProfileEditorResponse.self,
      from: await perform(
        path: "/api/v1/users/\(id.uuidString)/profile", method: "PUT",
        body: JSONEncoder().encode(request)))
  }
  /// A profile's photo (JPEG), shown in the picker before any profile is unlocked.
  func profilePhoto(id: UUID, revision: Int64) async throws -> Data {
    try await perform(path: "/api/v1/profiles/\(id.uuidString)/picture?rev=\(revision)")
  }
  /// Renames the signed-in profile; an owner keeps signing in with the original name.
  func renameOwnProfile(_ name: String) async throws -> UserSummary {
    try Self.decode(
      UserSummary.self,
      from: await perform(
        path: "/api/v1/profile/name", method: "PUT",
        body: JSONEncoder().encode(ProfileNameRequest(name: name))))
  }
  func setOwnPicture(builtin: String?) async throws -> UserSummary {
    try Self.decode(
      UserSummary.self,
      from: await perform(
        path: "/api/v1/profile/picture", method: "PUT",
        body: JSONEncoder().encode(ProfilePictureRequest(builtin: builtin))))
  }
  func uploadOwnPhoto(_ image: Data) async throws -> UserSummary {
    try Self.decode(
      UserSummary.self,
      from: await perform(
        path: "/api/v1/profile/picture/photo", method: "PUT", body: image, timeout: 60))
  }
  func renameProfile(id: UUID, name: String) async throws -> UserSummary {
    try Self.decode(
      UserSummary.self,
      from: await perform(
        path: "/api/v1/users/\(id.uuidString)/name", method: "PUT",
        body: JSONEncoder().encode(ProfileNameRequest(name: name))))
  }
  func setProfilePicture(id: UUID, builtin: String?) async throws -> UserSummary {
    try Self.decode(
      UserSummary.self,
      from: await perform(
        path: "/api/v1/users/\(id.uuidString)/picture", method: "PUT",
        body: JSONEncoder().encode(ProfilePictureRequest(builtin: builtin))))
  }
  func uploadProfilePhoto(id: UUID, image: Data) async throws -> UserSummary {
    try Self.decode(
      UserSummary.self,
      from: await perform(
        path: "/api/v1/users/\(id.uuidString)/picture/photo", method: "PUT", body: image,
        timeout: 60))
  }
  func ageLimit(user: UUID) async throws -> ProfileAgeLimit {
    try await get("/api/v1/users/\(user.uuidString)/age-limit")
  }
  func setAgeLimit(user: UUID, _ value: ProfileAgeLimit) async throws -> ProfileAgeLimit {
    try Self.decode(
      ProfileAgeLimit.self,
      from: await perform(
        path: "/api/v1/users/\(user.uuidString)/age-limit", method: "PUT",
        body: JSONEncoder().encode(value)))
  }
  func screenTime(user: UUID) async throws -> ProfileScreenTime {
    try await get("/api/v1/users/\(user.uuidString)/screen-time")
  }
  func setScreenTime(user: UUID, _ value: ProfileScreenTimeUpdate) async throws -> ProfileScreenTime {
    try Self.decode(
      ProfileScreenTime.self,
      from: await perform(
        path: "/api/v1/users/\(user.uuidString)/screen-time", method: "PUT",
        body: JSONEncoder().encode(value)))
  }
  func grantScreenTime(user: UUID, _ grant: ScreenTimeGrant) async throws -> ProfileScreenTime {
    try Self.decode(
      ProfileScreenTime.self,
      from: await perform(
        path: "/api/v1/users/\(user.uuidString)/screen-time/today", method: "POST",
        body: JSONEncoder().encode(grant)))
  }
  func ownScreenTime() async throws -> OwnScreenTime {
    try await get("/api/v1/profile/screen-time")
  }
  func unlockManagement(password: String) async throws -> String {
    struct Payload: Encodable { let password: String }
    struct Response: Decodable { let expiresAt: String }
    return try Self.decode(
      Response.self,
      from: await perform(
        path: "/api/v1/management/unlock", method: "POST",
        body: JSONEncoder().encode(Payload(password: password)))
    ).expiresAt
  }
  func lockManagement() async throws {
    _ = try await perform(path: "/api/v1/management/lock", method: "POST")
  }
  func titleAccess(user: UUID) async throws -> ProfileTitleAccess {
    try await get("/api/v1/users/\(user.uuidString)/titles")
  }
  func setTitleAccess(user: UUID, access: ProfileTitleAccess) async throws -> ProfileTitleAccess {
    try Self.decode(
      ProfileTitleAccess.self,
      from: await perform(
        path: "/api/v1/users/\(user.uuidString)/titles", method: "PUT",
        body: JSONEncoder().encode(access)))
  }

  func sceneNotes(mediaId: UUID) async throws -> [SceneNote] {
    try await get("/api/v1/media/\(mediaId.uuidString)/notes")
  }

  func saveSceneNote(
    mediaId: UUID, id: UUID, start: Int64, end: Int64?, text: String, revision: Int64
  ) async throws -> SceneNote {
    struct Payload: Encodable {
      let startMilliseconds: Int64
      let endMilliseconds: Int64?
      let text: String
      let revision: Int64
    }
    return try Self.decode(
      SceneNote.self,
      from: await perform(
        path: "/api/v1/media/\(mediaId.uuidString)/notes/\(id.uuidString)",
        method: "PUT",
        body: JSONEncoder().encode(
          Payload(startMilliseconds: start, endMilliseconds: end, text: text, revision: revision))))
  }

  func removeSceneNote(mediaId: UUID, note: SceneNote) async throws {
    _ = try await perform(
      path:
        "/api/v1/media/\(mediaId.uuidString)/notes/\(note.id.uuidString)?revision=\(note.revision)",
      method: "DELETE")
  }

  func serverSettings() async throws -> ServerConfigurationResponse {
    try await get("/api/v1/server/settings")
  }

  func saveServerSettings(_ settings: ServerPolicySettings) async throws
    -> ServerConfigurationResponse
  {
    let data = try await perform(
      path: "/api/v1/server/settings", method: "PUT", body: JSONEncoder().encode(settings))
    return try Self.decode(ServerConfigurationResponse.self, from: data)
  }

  func serverStatus() async throws -> ServerStatusSummary { try await get("/api/v1/server/status") }
  func serverHealth() async throws -> ServerHealthResponse {
    try await get("/api/v1/server/health")
  }
  func serverPerformance() async throws -> ServerPerformanceResponse {
    try await get("/api/v1/server/health/performance")
  }
  func resetServerPerformance() async throws {
    _ = try await perform(path: "/api/v1/server/health/performance", method: "DELETE")
  }
  func serverUsers() async throws -> [UserAccessSummary] { try await get("/api/v1/server/users") }
  func deleteProfile(id: UUID) async throws {
    _ = try await perform(path: "/api/v1/users/\(id.uuidString.lowercased())", method: "DELETE")
  }
  func userSessions(_ id: UUID) async throws -> [DeviceSessionSummary] {
    try await get("/api/v1/server/sessions/\(id.uuidString)")
  }
  func revokeManagedSession(id: UUID) async throws {
    _ = try await perform(path: "/api/v1/server/sessions/\(id.uuidString)", method: "DELETE")
  }

  func createUser(username: String, pin: String, role: UserRole) async throws {
    struct Payload: Encodable {
      let username: String
      let password: String
      let role: UserRole
      let pin: String
    }
    _ = try await perform(
      path: "/api/v1/users", method: "POST",
      body: JSONEncoder().encode(Payload(username: username, password: "", role: role, pin: pin)))
  }
  func setProfileEnabled(id: UUID, enabled: Bool) async throws {
    struct Payload: Encodable { let isEnabled: Bool }
    _ = try await perform(
      path: "/api/v1/users/\(id.uuidString)/enabled", method: "PUT",
      body: JSONEncoder().encode(Payload(isEnabled: enabled)))
  }
  func updateUserAccess(id: UUID, enabled: Bool, libraries: [UUID]) async throws {
    struct Payload: Encodable {
      let isEnabled: Bool
      let libraryIds: [UUID]
    }
    _ = try await perform(
      path: "/api/v1/users/\(id.uuidString)/access", method: "PUT",
      body: JSONEncoder().encode(Payload(isEnabled: enabled, libraryIds: libraries)))
  }
  func changeUserRole(id: UUID, role: UserRole) async throws {
    struct Payload: Encodable { let role: UserRole }
    _ = try await perform(
      path: "/api/v1/users/\(id.uuidString)/role", method: "PUT",
      body: JSONEncoder().encode(Payload(role: role)))
  }
  func resetUserPassword(id: UUID, password: String) async throws {
    struct Payload: Encodable { let password: String }
    _ = try await perform(
      path: "/api/v1/users/\(id.uuidString)/password", method: "PUT",
      body: JSONEncoder().encode(Payload(password: password)))
  }
  func revokeUserSessions(id: UUID) async throws {
    _ = try await perform(path: "/api/v1/users/\(id.uuidString)/sessions", method: "DELETE")
  }

  func currentUser() async throws -> UserSummary {
    try await get("/api/v1/auth/me")
  }

  func libraries() async throws -> [LibrarySummary] {
    try await get("/api/v1/libraries")
  }

  func serverFolders(path: String?) async throws -> ServerFolderListing {
    let query = try path.map { "?" + (try Self.query(name: "path", value: $0)) } ?? ""
    return try await get("/api/v1/libraries/folders\(query)")
  }

  func createLibrary(
    name: String? = nil,
    path: String,
    kind: LibraryKind = .automatic,
    combineExisting: Bool = false,
    requireImportPreview: Bool = false
  ) async throws
    -> LibrarySummary
  {
    let body = try JSONEncoder().encode(
      CreateLibraryRequest(
        name: name,
        path: path,
        kind: kind,
        combineExisting: combineExisting,
        requireImportPreview: requireImportPreview))
    let data = try await perform(path: "/api/v1/libraries", method: "POST", body: body)
    return try Self.decode(LibrarySummary.self, from: data)
  }

  func libraryDiscoveries(id: UUID) async throws -> [LibraryDiscoverySummary] {
    try await get("/api/v1/libraries/\(id.uuidString.lowercased())/discoveries")
  }

  func analyzeImport(libraryId: UUID) async throws -> ImportPreviewSummary {
    let data = try await perform(
      path: "/api/v1/libraries/\(libraryId.uuidString.lowercased())/import-preview",
      method: "POST")
    return try Self.decode(ImportPreviewSummary.self, from: data)
  }

  func importPreviewItems(libraryId: UUID, previewId: UUID, offset: Int = 0, limit: Int = 200)
    async throws -> ImportPreviewPage
  {
    try await get(
      "/api/v1/libraries/\(libraryId.uuidString.lowercased())/import-preview/\(previewId.uuidString.lowercased())/items?offset=\(offset)&limit=\(limit)"
    )
  }

  func updateImportPreview(
    libraryId: UUID, previewId: UUID, revision: String, assignments: [ImportAssignmentUpdate]
  ) async throws -> ImportPreviewSummary {
    let body = try JSONEncoder().encode(
      ImportAssignmentsRequest(revision: revision, assignments: assignments))
    let data = try await perform(
      path:
        "/api/v1/libraries/\(libraryId.uuidString.lowercased())/import-preview/\(previewId.uuidString.lowercased())/assignments",
      method: "PUT", body: body)
    return try Self.decode(ImportPreviewSummary.self, from: data)
  }

  func confirmImportPreview(libraryId: UUID, previewId: UUID, revision: String)
    async throws -> LibraryScanSummary
  {
    let body = try JSONEncoder().encode(ConfirmImportPreviewRequest(revision: revision))
    let data = try await perform(
      path:
        "/api/v1/libraries/\(libraryId.uuidString.lowercased())/import-preview/\(previewId.uuidString.lowercased())/confirm",
      method: "POST", body: body)
    return try Self.decode(LibraryScanSummary.self, from: data)
  }

  func importAssignments(libraryId: UUID) async throws -> ImportAssignmentsSummary {
    try await get("/api/v1/libraries/\(libraryId.uuidString.lowercased())/import-assignments")
  }

  func libraryImportReviews(id: UUID) async throws -> [LibraryImportReviewSummary] {
    try await get("/api/v1/libraries/\(id.uuidString.lowercased())/import-reviews")
  }

  func updateLibraryImportReview(
    libraryId: UUID,
    reviewId: UUID,
    action: LibraryImportReviewAction,
    movieId: UUID? = nil
  ) async throws -> LibraryScanSummary {
    let body = try JSONEncoder().encode(
      UpdateLibraryImportReviewRequest(action: action, movieId: movieId))
    let data = try await perform(
      path:
        "/api/v1/libraries/\(libraryId.uuidString.lowercased())/import-reviews/\(reviewId.uuidString.lowercased())",
      method: "PUT",
      body: body)
    return try Self.decode(LibraryScanSummary.self, from: data)
  }

  func updateClassification(
    libraryId: UUID,
    discoveryId: UUID,
    decision: ClassificationDecision
  ) async throws -> LibraryScanSummary {
    let body = try JSONEncoder().encode(
      UpdateClassificationDecisionsRequest(
        decisions: [ClassificationDecisionUpdate(discoveryId: discoveryId, decision: decision)]))
    let data = try await perform(
      path: "/api/v1/libraries/\(libraryId.uuidString.lowercased())/classification-decisions",
      method: "PUT",
      body: body)
    return try Self.decode(LibraryScanSummary.self, from: data)
  }

  func resetClassification(libraryId: UUID, discoveryId: UUID) async throws
    -> LibraryScanSummary
  {
    let data = try await perform(
      path:
        "/api/v1/libraries/\(libraryId.uuidString.lowercased())/classification-decisions/\(discoveryId.uuidString.lowercased())",
      method: "DELETE")
    return try Self.decode(LibraryScanSummary.self, from: data)
  }

  func removeLibrary(id: UUID) async throws {
    _ = try await perform(path: "/api/v1/libraries/\(id.uuidString.lowercased())", method: "DELETE")
  }

  func updateLibraryMonitoring(id: UUID, enabled: Bool) async throws -> LibrarySummary {
    let body = try JSONEncoder().encode(["enabled": enabled])
    let data = try await perform(
      path: "/api/v1/libraries/\(id.uuidString.lowercased())/monitoring",
      method: "PUT",
      body: body)
    return try Self.decode(LibrarySummary.self, from: data)
  }

  func startLibraryScan(id: UUID) async throws -> LibraryScanSummary {
    let data = try await perform(
      path: "/api/v1/libraries/\(id.uuidString.lowercased())/scans",
      method: "POST")
    return try Self.decode(LibraryScanSummary.self, from: data)
  }

  func startAllLibraryScans() async throws -> [LibraryScanSummary] {
    let data = try await perform(path: "/api/v1/libraries/scans", method: "POST")
    return try Self.decode([LibraryScanSummary].self, from: data)
  }

  func scan(id: UUID) async throws -> LibraryScanSummary {
    try await get("/api/v1/scans/\(id.uuidString.lowercased())")
  }

  func cancelScan(id: UUID) async throws {
    _ = try await perform(path: "/api/v1/scans/\(id.uuidString.lowercased())", method: "DELETE")
  }

  func activeLibraryScans() async throws -> [LibraryScanSummary] {
    try await get("/api/v1/libraries/scans")
  }

  func libraryScans(id: UUID, limit: Int = 10) async throws -> [LibraryScanSummary] {
    try await get(
      "/api/v1/libraries/\(id.uuidString.lowercased())/scans?limit=\(limit)")
  }

  func createPairingCode() async throws -> PairingCodeResponse {
    let data = try await perform(path: "/api/v1/auth/pairings", method: "POST")
    return try Self.decode(PairingCodeResponse.self, from: data)
  }

  func sessions() async throws -> [DeviceSessionSummary] {
    try await get("/api/v1/auth/sessions")
  }

  func revokeSession(id: UUID) async throws {
    _ = try await perform(
      path: "/api/v1/auth/sessions/\(id.uuidString.lowercased())",
      method: "DELETE")
  }

  func metadataProviderStatus() async throws -> MetadataProviderStatus {
    try await get("/api/v1/metadata/provider")
  }

  func configureMetadata(token: String?, enabled: Bool) async throws -> MetadataProviderStatus {
    let body = try JSONEncoder().encode(
      UpdateMetadataProviderRequest(enabled: enabled, language: "en-US", token: token))
    let data = try await perform(path: "/api/v1/metadata/provider", method: "PUT", body: body)
    return try Self.decode(MetadataProviderStatus.self, from: data)
  }

  func removeMetadataToken() async throws -> MetadataProviderStatus {
    let data = try await perform(path: "/api/v1/metadata/provider/token", method: "DELETE")
    return try Self.decode(MetadataProviderStatus.self, from: data)
  }

  func watchParties(mediaId: UUID? = nil) async throws -> [WatchPartySummary] {
    try await get(
      "/api/v1/watch-together" + (mediaId.map { "?mediaId=\($0.uuidString.lowercased())" } ?? ""))
  }

  func createWatchParty(_ request: CreateWatchPartyRequest) async throws -> WatchPartyState {
    let data = try await perform(
      path: "/api/v1/watch-together", method: "POST", body: try JSONEncoder().encode(request))
    return try Self.decode(WatchPartyState.self, from: data)
  }

  func joinWatchParty(id: UUID, _ request: JoinWatchPartyRequest) async throws -> WatchPartyState {
    let data = try await perform(
      path: "/api/v1/watch-together/\(id.uuidString.lowercased())/join", method: "POST",
      body: try JSONEncoder().encode(request))
    return try Self.decode(WatchPartyState.self, from: data)
  }

  /// The party once its revision is newer than `after`, or after up to `waitMilliseconds`.
  func watchParty(id: UUID, after: Int64?, waitMilliseconds: Int) async throws -> WatchPartyState {
    var path = "/api/v1/watch-together/\(id.uuidString.lowercased())"
    if let after { path += "?after=\(after)&waitMs=\(waitMilliseconds)" }
    let data = try await perform(
      path: path, method: "GET", timeout: TimeInterval(waitMilliseconds) / 1000 + 10)
    return try Self.decode(WatchPartyState.self, from: data)
  }

  func sendWatchPartyCommand(id: UUID, _ request: WatchPartyCommandRequest) async throws
    -> WatchPartyState
  {
    let data = try await perform(
      path: "/api/v1/watch-together/\(id.uuidString.lowercased())/commands", method: "POST",
      body: try JSONEncoder().encode(request))
    return try Self.decode(WatchPartyState.self, from: data)
  }

  func leaveWatchParty(id: UUID) async throws {
    _ = try await perform(
      path: "/api/v1/watch-together/\(id.uuidString.lowercased())/members/me", method: "DELETE")
  }

  // MARK: Movie Night (see MovieNight.swift)

  private struct MovieNightJoinBody: Encodable {
    let deviceName: String
    let isVoting: Bool
  }

  private struct MovieNightRoleBody: Encodable { let isVoting: Bool }

  private static func movieNightPath(_ id: UUID, _ tail: String = "") -> String {
    "/api/v1/movie-night/\(id.uuidString.lowercased())\(tail)"
  }

  private func movieNightPost(_ path: String, _ body: some Encodable) async throws -> MovieNightState {
    let data = try await perform(path: path, method: "POST", body: try JSONEncoder().encode(body))
    return try Self.decode(MovieNightState.self, from: data)
  }

  func movieNights() async throws -> [MovieNightSummary] { try await get("/api/v1/movie-night") }

  func createMovieNight(deviceName: String, voting: Bool) async throws -> MovieNightState {
    try await movieNightPost("/api/v1/movie-night", MovieNightJoinBody(deviceName: deviceName, isVoting: voting))
  }

  func joinMovieNight(id: UUID, deviceName: String, voting: Bool) async throws -> MovieNightState {
    try await movieNightPost(
      Self.movieNightPath(id, "/join"), MovieNightJoinBody(deviceName: deviceName, isVoting: voting))
  }

  /// The night once its revision is newer than `after`, or after up to `waitMilliseconds`.
  func movieNight(id: UUID, after: Int64?, deckVersion: Int?, waitMilliseconds: Int) async throws
    -> MovieNightState
  {
    var path = Self.movieNightPath(id)
    if let after {
      path += "?after=\(after)&waitMs=\(waitMilliseconds)"
      if let deckVersion { path += "&deckVersion=\(deckVersion)" }
    }
    let data = try await perform(
      path: path, method: "GET", timeout: TimeInterval(waitMilliseconds) / 1000 + 10)
    return try Self.decode(MovieNightState.self, from: data)
  }

  func movieNightSettings(id: UUID, program: MovieNightProgram) async throws -> MovieNightState {
    try await movieNightPost(Self.movieNightPath(id, "/settings"), program)
  }

  func dealMovieNight(id: UUID) async throws -> MovieNightState {
    try await movieNightPost(Self.movieNightPath(id, "/deal"), [String: String]())
  }

  func voteMovieNight(id: UUID, mediaID: UUID, like: Bool) async throws -> MovieNightState {
    try await movieNightPost(Self.movieNightPath(id, "/votes"), MovieNightVote(mediaId: mediaID, like: like))
  }

  func keepSwiping(id: UUID) async throws -> MovieNightState {
    try await movieNightPost(Self.movieNightPath(id, "/keep-swiping"), [String: String]())
  }

  func movieNightRole(id: UUID, voting: Bool) async throws -> MovieNightState {
    try await movieNightPost(Self.movieNightPath(id, "/role"), MovieNightRoleBody(isVoting: voting))
  }

  func leaveMovieNight(id: UUID) async throws {
    _ = try await perform(path: Self.movieNightPath(id, "/members/me"), method: "DELETE")
  }

  func subtitleProviderStatus() async throws -> SubtitleProviderStatus {
    try await get("/api/v1/metadata/subtitles")
  }

  func configureSubtitles(_ request: UpdateSubtitleProviderRequest) async throws
    -> SubtitleProviderStatus
  {
    let data = try await perform(
      path: "/api/v1/metadata/subtitles", method: "PUT", body: try JSONEncoder().encode(request))
    return try Self.decode(SubtitleProviderStatus.self, from: data)
  }

  func removeSubtitleKey() async throws -> SubtitleProviderStatus {
    let data = try await perform(path: "/api/v1/metadata/subtitles/key", method: "DELETE")
    return try Self.decode(SubtitleProviderStatus.self, from: data)
  }

  func removeSubtitleAccount() async throws -> SubtitleProviderStatus {
    let data = try await perform(path: "/api/v1/metadata/subtitles/account", method: "DELETE")
    return try Self.decode(SubtitleProviderStatus.self, from: data)
  }

  func downloadedSubtitles(mediaId: UUID) async throws -> [DownloadedSubtitle] {
    try await get("/api/v1/media/\(mediaId.uuidString.lowercased())/subtitles")
  }

  func searchSubtitles(mediaId: UUID, language: String) async throws -> [SubtitleCandidate] {
    let code = language.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    return try await get(
      "/api/v1/media/\(mediaId.uuidString.lowercased())/subtitles/search?language=\(code)")
  }

  func downloadSubtitle(mediaId: UUID, _ request: DownloadSubtitleRequest) async throws
    -> DownloadedSubtitle
  {
    let data = try await perform(
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/subtitles", method: "POST",
      body: try JSONEncoder().encode(request), timeout: 45)
    return try Self.decode(DownloadedSubtitle.self, from: data)
  }

  func removeSubtitle(mediaId: UUID, id: UUID) async throws {
    _ = try await perform(
      path:
        "/api/v1/media/\(mediaId.uuidString.lowercased())/subtitles/\(id.uuidString.lowercased())",
      method: "DELETE")
  }

  func startMetadataJob(libraryId: UUID? = nil) async throws -> MetadataJobSummary {
    let body = try libraryId.map {
      try JSONEncoder().encode(["libraryId": $0.uuidString.lowercased()])
    }
    let data = try await perform(path: "/api/v1/metadata/jobs", method: "POST", body: body)
    return try Self.decode(MetadataJobSummary.self, from: data)
  }

  func metadataJob(id: UUID) async throws -> MetadataJobSummary {
    try await get("/api/v1/metadata/jobs/\(id.uuidString.lowercased())")
  }

  func metadataJobs(activeOnly: Bool = false, limit: Int = 25) async throws
    -> [MetadataJobSummary]
  {
    try await get("/api/v1/metadata/jobs?activeOnly=\(activeOnly)&limit=\(limit)")
  }

  func cancelMetadataJob(id: UUID) async throws {
    _ = try await perform(
      path: "/api/v1/metadata/jobs/\(id.uuidString.lowercased())", method: "DELETE")
  }

  func syncChanges(after cursor: Int64, waitSeconds: Int, generation: String? = nil) async throws
    -> SyncChangesResponse
  {
    let generationQuery =
      try generation.map { "&" + (try Self.query(name: "generation", value: $0)) } ?? ""
    let data = try await perform(
      path: "/api/v1/sync/changes?after=\(cursor)&waitSeconds=\(waitSeconds)\(generationQuery)",
      method: "GET",
      timeout: TimeInterval(max(waitSeconds + 5, 15)))
    return try Self.decode(SyncChangesResponse.self, from: data)
  }

  func pruneArtwork() async throws {
    _ = try await perform(path: "/api/v1/metadata/artwork/prune", method: "POST")
  }

  func movies() async throws -> [MovieSummary] {
    try await allPages(path: "/api/v1/catalog/movies")
  }

  func series() async throws -> [SeriesSummary] {
    try await allPages(path: "/api/v1/catalog/series")
  }

  func movie(id: UUID) async throws -> MovieDetailResponse {
    try await get("/api/v1/catalog/movies/\(id.uuidString.lowercased())")
  }

  func series(id: UUID) async throws -> SeriesDetailResponse {
    try await get("/api/v1/catalog/series/\(id.uuidString.lowercased())")
  }

  func catalogItems(kind: MediaKind? = nil) async throws -> [CatalogItemSummary] {
    let query = kind.map { "kind=\($0.rawValue)" }
    return try await allPages(path: "/api/v1/catalog/items", query: query)
  }

  static func catalogQuery(_ query: CatalogBrowseQuery, search: String) throws -> String? {
    var values: [(String, String)] = []
    let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
    if !search.isEmpty { values.append(("query", search)) }
    if let kind = query.kind { values.append(("kind", kind.rawValue)) }
    if query.favoritesOnly { values.append(("favorite", "true")) }
    if let genre = query.genre, !genre.isEmpty { values.append(("genre", genre)) }
    if let year = query.yearFrom { values.append(("yearFrom", String(year))) }
    if let year = query.yearTo { values.append(("yearTo", String(year))) }
    switch query.watchState {
    case .all: break
    case .unwatched: values.append(("watchState", "unplayed"))
    case .inProgress: values.append(("watchState", "inProgress"))
    case .watched: values.append(("watchState", "completed"))
    }
    if let sort = query.sort {
      values.append(("sort", sort.rawValue))
      values.append(("direction", query.descending ? "descending" : "ascending"))
    }
    let result = try values.map { try Self.query(name: $0.0, value: $0.1) }.joined(separator: "&")
    return result.isEmpty ? nil : result
  }

  func browseCatalog(query: CatalogBrowseQuery, search: String) async throws -> [CatalogItemSummary]
  {
    let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return try await allPages(
      path: search.isEmpty ? "/api/v1/catalog/items" : "/api/v1/catalog/search",
      query: Self.catalogQuery(query, search: search))
  }

  func playbackPlan(mediaId: UUID) async throws -> PlaybackPlanResponse {
    let result: PlaybackPlanResponse = try await get(
      "/api/v1/media/\(mediaId.uuidString.lowercased())/playback-plan")
    guard result.queue.allSatisfy({ $0.kind == .episode }),
      Set(result.queue.map(\.id)).count == result.queue.count,
      !result.queue.contains(where: { $0.id == result.target?.id }),
      result.target?.kind != .series
    else { throw APIClientError.invalidResponse }
    if let target = result.target, target.id != mediaId, result.seriesId != mediaId {
      throw APIClientError.invalidResponse
    }
    return result
  }

  func watchState(mediaId: UUID, scope: WatchStateScope = .title, seasonNumber: Int? = nil)
    async throws -> WatchStateResponse
  {
    let season = seasonNumber.map { "&seasonNumber=\($0)" } ?? ""
    let result: WatchStateResponse = try await get(
      "/api/v1/media/\(mediaId.uuidString.lowercased())/watch-state?scope=\(scope.rawValue)\(season)"
    )
    guard result.mediaId == mediaId, result.scope == scope, result.seasonNumber == seasonNumber,
      result.affectedCount >= 0, !result.stateToken.isEmpty
    else { throw APIClientError.invalidResponse }
    return result
  }

  func setWatchState(mediaId: UUID, request: SetWatchStateRequest) async throws
    -> WatchStateResponse
  {
    let data = try await perform(
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/watch-state", method: "PUT",
      body: JSONEncoder().encode(request))
    let result = try Self.decode(WatchStateResponse.self, from: data)
    guard result.mediaId == mediaId, result.scope == request.scope,
      result.seasonNumber == request.seasonNumber, result.affectedCount >= 0
    else { throw APIClientError.invalidResponse }
    return result
  }

  func setContinueWatchingHidden(mediaId: UUID, request: SetContinueWatchingRequest) async throws
    -> WatchStateResponse
  {
    let data = try await perform(
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/continue-watching", method: "PUT",
      body: JSONEncoder().encode(request))
    let result = try Self.decode(WatchStateResponse.self, from: data)
    // Servers from 1.7.1 answer for the series when an episode is sent.
    guard result.continueWatchingHidden == request.isHidden else {
      throw APIClientError.invalidResponse
    }
    return result
  }

  func catalogDetail(id: UUID) async throws -> CatalogDetailPresentation {
    try await get("/api/v1/catalog/items/\(id.uuidString.lowercased())")
  }

  func catalogSummary(id: UUID) async throws -> CatalogItemSummary {
    try await get("/api/v1/catalog/items/\(id.uuidString.lowercased())/summary")
  }

  func home() async throws -> HomeResponse {
    try await get("/api/v1/home")
  }

  func searchCatalog(_ query: String) async throws -> [CatalogItemSummary] {
    return try await allPages(
      path: "/api/v1/catalog/search",
      query: try Self.query(name: "query", value: query))
  }

  func searchMoviesForImportReview(
    _ query: String,
    libraryId: UUID
  ) async throws -> [CatalogItemSummary] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let encodedQuery = try Self.query(name: "query", value: trimmed)
    let page: PagedResponse<CatalogItemSummary> = try await get(
      "/api/v1/catalog/search?\(encodedQuery)&kind=movie&libraryId=\(libraryId.uuidString.lowercased())&offset=0&limit=25"
    )
    return page.items
  }

  func collections() async throws -> [CollectionSummary] {
    try await get("/api/v1/catalog/collections?offset=0&limit=200")
  }

  func collection(id: UUID) async throws -> CollectionDetail {
    try await get("/api/v1/collections/\(id.uuidString.lowercased())")
  }

  func collectionNext(id: UUID) async throws -> CollectionNextResponse {
    try await get("/api/v1/collections/\(id.uuidString.lowercased())/next")
  }

  func createCollection(
    name: String, mediaIds: [UUID]? = nil, isSmart: Bool = false, isShared: Bool = false,
    rulesJson: String? = nil, overview: String? = nil, sortMode: String? = nil,
    members: [CollectionMemberInput]? = nil
  ) async throws -> CollectionSummary {
    let body = try JSONEncoder().encode(
      SaveCollectionRequest(
        name: name, mediaIds: members == nil ? mediaIds : nil, isSmart: isSmart, isShared: isShared,
        rulesJson: rulesJson, overview: overview, sortMode: sortMode, members: members))
    let data = try await perform(path: "/api/v1/collections", method: "POST", body: body)
    return try Self.decode(CollectionSummary.self, from: data)
  }

  func updateCollection(
    id: UUID, name: String, mediaIds: [UUID]? = nil, isSmart: Bool = false, isShared: Bool = false,
    rulesJson: String? = nil, overview: String? = nil, sortMode: String? = nil,
    members: [CollectionMemberInput]? = nil
  ) async throws
    -> CollectionSummary
  {
    let body = try JSONEncoder().encode(
      SaveCollectionRequest(
        name: name, mediaIds: members == nil ? mediaIds : nil, isSmart: isSmart, isShared: isShared,
        rulesJson: rulesJson, overview: overview, sortMode: sortMode, members: members))
    let data = try await perform(
      path: "/api/v1/collections/\(id.uuidString.lowercased())", method: "PUT", body: body)
    return try Self.decode(CollectionSummary.self, from: data)
  }

  func updateCollectionOrder(
    id: UUID, members: [CollectionMemberInput], sortMode: String? = "custom"
  ) async throws -> CollectionDetail {
    let body = try JSONEncoder().encode(CollectionOrderRequest(members: members, sortMode: sortMode))
    let data = try await perform(
      path: "/api/v1/collections/\(id.uuidString.lowercased())/order", method: "PUT", body: body)
    return try Self.decode(CollectionDetail.self, from: data)
  }

  func deleteCollection(id: UUID) async throws {
    _ = try await perform(
      path: "/api/v1/collections/\(id.uuidString.lowercased())", method: "DELETE")
  }

  func addCollectionItem(collectionId: UUID, mediaId: UUID, seasonNumber: Int? = nil) async throws {
    let query = seasonNumber.map { "?seasonNumber=\($0)" } ?? ""
    _ = try await perform(
      path:
        "/api/v1/collections/\(collectionId.uuidString.lowercased())/items/\(mediaId.uuidString.lowercased())\(query)",
      method: "POST")
  }

  func removeCollectionItem(collectionId: UUID, mediaId: UUID, seasonNumber: Int? = nil) async throws {
    let query = seasonNumber.map { "?seasonNumber=\($0)" } ?? ""
    _ = try await perform(
      path:
        "/api/v1/collections/\(collectionId.uuidString.lowercased())/items/\(mediaId.uuidString.lowercased())\(query)",
      method: "DELETE")
  }

  func uploadCollectionEditorImage(id: UUID, png: Data) async throws -> EditorUploadSummary {
    try Self.decode(
      EditorUploadSummary.self,
      from: await perform(
        path: "/api/v1/collections/\(id.uuidString.lowercased())/editor/uploads", method: "POST",
        body: png, timeout: 120))
  }

  func collectionEditorImage(id: UUID, uploadId: UUID) async throws -> Data {
    try await perform(
      path:
        "/api/v1/collections/\(id.uuidString.lowercased())/editor/uploads/\(uploadId.uuidString.lowercased())"
    )
  }

  func discardCollectionEditorImage(id: UUID, uploadId: UUID) async throws {
    _ = try await perform(
      path:
        "/api/v1/collections/\(id.uuidString.lowercased())/editor/uploads/\(uploadId.uuidString.lowercased())",
      method: "DELETE")
  }

  func saveCollectionArtwork(id: UUID, kind: String, request: SaveCollectionArtworkRequest)
    async throws -> ArtworkSummary
  {
    let body = try JSONEncoder().encode(request)
    let data = try await perform(
      path: "/api/v1/collections/\(id.uuidString.lowercased())/artwork/\(kind)", method: "POST",
      body: body)
    return try Self.decode(ArtworkSummary.self, from: data)
  }

  func deleteCollectionArtwork(id: UUID, kind: String) async throws {
    _ = try await perform(
      path: "/api/v1/collections/\(id.uuidString.lowercased())/artwork/\(kind)", method: "DELETE")
  }

  func franchises() async throws -> [CollectionSummary] {
    try await get("/api/v1/catalog/franchises")
  }

  func createCollectionFromFranchise(franchiseId: String) async throws -> CollectionSummary {
    let data = try await perform(
      path: "/api/v1/collections/from-franchise/\(franchiseId)",
      method: "POST")
    return try Self.decode(CollectionSummary.self, from: data)
  }

  func streamSubtitles(ticket: UUID) async throws -> [LiveSubtitleTrack] {
    try await get("/api/v1/streams/\(ticket.uuidString.lowercased())/subtitles")
  }

  func history(offset: Int = 0, limit: Int = 50) async throws -> WatchHistoryPage {
    try await get("/api/v1/history?offset=\(offset)&limit=\(limit)")
  }

  func deleteHistoryItem(id: UUID) async throws {
    _ = try await perform(
      path: "/api/v1/history/\(id.uuidString.lowercased())",
      method: "DELETE")
  }

  func clearHistory() async throws {
    _ = try await perform(
      path: "/api/v1/history",
      method: "DELETE")
  }

  func statistics() async throws -> UserStatistics {
    try await get("/api/v1/statistics")
  }

  func yearInReview(year: Int) async throws -> YearInReview {
    try await get("/api/v1/statistics/year/\(year)")
  }

  func wrapped(year: Int, month: Int? = nil) async throws -> YearWrapped {
    if let month { return try await get("/api/v1/statistics/year/\(year)/month/\(month)/wrapped") }
    return try await get("/api/v1/statistics/year/\(year)/wrapped")
  }

  func healthDuplicates(offset: Int = 0, limit: Int = 50) async throws -> [DuplicateGroup] {
    try await get("/api/v1/library/health/duplicates?offset=\(offset)&limit=\(limit)")
  }

  func healthOffline(days: Int = 30, offset: Int = 0, limit: Int = 50) async throws
    -> [OfflineTitleSummary]
  {
    try await get("/api/v1/library/health/offline?days=\(days)&offset=\(offset)&limit=\(limit)")
  }

  func healthUnmatched(offset: Int = 0, limit: Int = 50) async throws -> [UnmatchedTitleSummary] {
    try await get("/api/v1/library/health/unmatched?offset=\(offset)&limit=\(limit)")
  }

  func healthMerge(sourceId: UUID, targetId: UUID) async throws {
    let body = try JSONEncoder().encode(
      MergeMediaRequest(sourceMediaId: sourceId, targetMediaId: targetId))
    _ = try await perform(
      path: "/api/v1/library/health/merge",
      method: "POST",
      body: body)
  }

  func healthRemoveEntry(mediaId: UUID) async throws {
    _ = try await perform(
      path: "/api/v1/library/health/entries/\(mediaId.uuidString.lowercased())",
      method: "DELETE")
  }

  func sendPlayerHeartbeat(_ request: PlayerHeartbeatRequest) async throws
    -> PlayerHeartbeatResponse
  {
    let body = try JSONEncoder().encode(request)
    let data = try await perform(
      path: "/api/v1/devices/player/heartbeat", method: "POST", body: body)
    return try Self.decode(PlayerHeartbeatResponse.self, from: data)
  }

  func activePlayers(currentDeviceId: String? = nil) async throws -> [RemotePlayerDevice] {
    var path = "/api/v1/devices/players"
    if let currentDeviceId, !currentDeviceId.isEmpty {
      path +=
        "?currentDeviceId=\(currentDeviceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? currentDeviceId)"
    }
    return try await get(path)
  }

  func playerStatus(deviceId: String) async throws -> RemotePlayerDevice {
    let encoded = deviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deviceId
    return try await get("/api/v1/devices/players/\(encoded)/status")
  }

  func sendPlayerCommand(
    deviceId: String, action: String, mediaId: UUID? = nil, positionSeconds: Double? = nil,
    skipSeconds: Double? = nil
  ) async throws -> RemotePlaybackCommandResponse {
    let body = try JSONEncoder().encode(
      RemotePlaybackCommandRequest(
        action: action, mediaId: mediaId, positionSeconds: positionSeconds, skipSeconds: skipSeconds
      ))
    let encoded = deviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deviceId
    let data = try await perform(
      path: "/api/v1/devices/players/\(encoded)/commands", method: "POST", body: body)
    return try Self.decode(RemotePlaybackCommandResponse.self, from: data)
  }

  func pollPlayerCommands(deviceId: String, waitMs: Int = 0) async throws -> [RemotePlaybackCommand]
  {
    let encoded =
      deviceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceId
    return try await get("/api/v1/devices/player/commands?deviceId=\(encoded)&waitMs=\(waitMs)")
  }

  func setFavorite(mediaId: UUID, isFavorite: Bool) async throws -> Bool {
    let body = try JSONEncoder().encode(SetFavoriteRequest(isFavorite: isFavorite))
    let data = try await perform(
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/favorite",
      method: "PUT",
      body: body)
    return try Self.decode(Bool.self, from: data)
  }

  func watchlist() async throws -> WatchlistResponse {
    try await get("/api/v1/watchlist")
  }

  func setWatchlist(mediaId: UUID, isWatchlisted: Bool) async throws -> WatchlistItemStateResponse {
    let body = try JSONEncoder().encode(SetWatchlistRequest(isWatchlisted: isWatchlisted))
    let data = try await perform(
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/watchlist",
      method: "PUT",
      body: body)
    return try Self.decode(WatchlistItemStateResponse.self, from: data)
  }

  func personDetail(name: String?, personKey: String?) async throws -> PersonDetailResponse {
    var items: [URLQueryItem] = []
    if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      items.append(URLQueryItem(name: "name", value: name))
    }
    if let personKey, !personKey.isEmpty, !personKey.hasPrefix("unidentified:") {
      items.append(URLQueryItem(name: "key", value: personKey))
    }
    var components = URLComponents()
    components.path = "/api/v1/catalog/person"
    components.queryItems = items.isEmpty ? nil : items
    return try await get(components.string ?? "/api/v1/catalog/person")
  }

  func mediaMetadata(id: UUID) async throws -> MediaMetadataSummary {
    try await get("/api/v1/media/\(id.uuidString.lowercased())/metadata")
  }

  func updateMediaMetadata(id: UUID, request: UpdateMediaMetadataRequest) async throws
    -> MediaMetadataSummary
  {
    let body = try JSONEncoder().encode(request)
    let data = try await perform(
      path: "/api/v1/media/\(id.uuidString.lowercased())/metadata", method: "PUT", body: body)
    return try Self.decode(MediaMetadataSummary.self, from: data)
  }

  func metadataCandidates(mediaId: UUID, query: String) async throws
    -> [MetadataCandidateSummary]
  {
    #if DEBUG
      if await CinemaUITestFixture.enabled {
        if query == "Slow match" { try? await Task.sleep(for: .seconds(1)) }
        if query == "Fail match" { throw APIClientError.invalidResponse }
        return [
          MetadataCandidateSummary(
            provider: "Synthetic", providerMediaId: query, mediaType: "tv",
            title: "Match: \(query)", originalTitle: nil, year: 2026,
            overview: "In-memory search fixture; no provider request.", posterPath: nil,
            confidence: 1)
        ]
      }
    #endif
    return try await get(
      "/api/v1/media/\(mediaId.uuidString.lowercased())/metadata/search?\(try Self.query(name: "query", value: query))"
    )
  }

  func mediaEditor(id: UUID) async throws -> MediaEditorDocument {
    try await get("/api/v1/media/\(id.uuidString)/editor")
  }
  func saveMediaEditor(id: UUID, request: SaveMediaEditorRequest) async throws
    -> MediaEditorDocument
  {
    try Self.decode(
      MediaEditorDocument.self,
      from: await perform(
        path: "/api/v1/media/\(id.uuidString)/editor", method: "PUT",
        body: JSONEncoder().encode(request), timeout: 120))
  }
  func uploadEditorImage(id: UUID, png: Data) async throws -> EditorUploadSummary {
    try Self.decode(
      EditorUploadSummary.self,
      from: await perform(
        path: "/api/v1/media/\(id.uuidString)/editor/uploads", method: "POST", body: png,
        timeout: 120))
  }
  func editorImage(id: UUID, selection: EditorArtwork) async throws -> Data {
    let path: String
    if let upload = selection.uploadId {
      path = "/api/v1/media/\(id.uuidString)/editor/uploads/\(upload.uuidString)"
    } else if let asset = selection.assetId {
      path = "/api/v1/media/\(id.uuidString)/editor/artwork/\(asset.uuidString)"
    } else {
      throw APIClientError.invalidResponse
    }
    return try await perform(path: path)
  }
  func discardEditorImage(id: UUID, upload: UUID) async throws {
    _ = try await perform(
      path: "/api/v1/media/\(id.uuidString)/editor/uploads/\(upload.uuidString)", method: "DELETE")
  }
  func editorFiles(id: UUID, path: String) async throws -> ServerFileListing {
    try await get(
      "/api/v1/media/\(id.uuidString)/editor/files?\(try Self.query(name: "path", value: path))")
  }
  func removeMedia(id: UUID) async throws -> LibraryMutationResult {
    try Self.decode(
      LibraryMutationResult.self,
      from: await perform(path: "/api/v1/media/\(id.uuidString)", method: "DELETE", timeout: 120))
  }
  func libraryMutation(id: UUID) async throws -> LibraryMutationResult {
    try await get("/api/v1/library-operations/\(id.uuidString)")
  }
  func previewReset(libraries: [UUID]) async throws -> ResetLibraryPreview {
    try Self.decode(
      ResetLibraryPreview.self,
      from: await perform(
        path: "/api/v1/libraries/reset/preview", method: "POST",
        body: JSONEncoder().encode(libraries)))
  }
  func resetLibrary(preview: ResetLibraryPreview) async throws -> LibraryMutationResult {
    try Self.decode(
      LibraryMutationResult.self,
      from: await perform(
        path: "/api/v1/libraries/reset", method: "POST",
        body: JSONEncoder().encode(
          ResetLibraryRequest(libraryIds: preview.libraryIds, revision: preview.revision)),
        timeout: 120))
  }
  func excludedItems(library: UUID) async throws -> [ExcludedMediaSummary] {
    try await get("/api/v1/libraries/\(library.uuidString)/exclusions")
  }
  func reinclude(library: UUID, excluded: UUID) async throws {
    _ = try await perform(
      path: "/api/v1/libraries/\(library.uuidString)/exclusions/\(excluded.uuidString)",
      method: "DELETE")
  }

  func selectMetadataMatch(
    mediaId: UUID,
    providerMediaId: String,
    mediaType: String
  ) async throws -> MediaMetadataSummary {
    let body = try JSONEncoder().encode(
      SelectMetadataMatchRequest(providerMediaId: providerMediaId, mediaType: mediaType))
    let data = try await perform(
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/metadata/match",
      method: "PUT",
      body: body)
    return try Self.decode(MediaMetadataSummary.self, from: data)
  }

  func clearMetadataMatch(mediaId: UUID) async throws -> MediaMetadataSummary {
    let data = try await perform(
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/metadata/match",
      method: "DELETE")
    return try Self.decode(MediaMetadataSummary.self, from: data)
  }

  func metadataReviews() async throws -> [MetadataReviewSummary] {
    try await get("/api/v1/metadata/reviews")
  }

  func artworkData(path: String) async throws -> Data {
    guard Self.isValidArtworkPath(path) else { throw APIClientError.invalidResponse }
    return try await perform(path: path, method: "GET")
  }

  static func isValidArtworkPath(_ path: String) -> Bool {
    guard path.hasPrefix("/api/v1/artwork/"),
      let components = URLComponents(string: path), components.scheme == nil,
      components.host == nil, components.fragment == nil,
      components.percentEncodedPath == components.path
    else {
      return false
    }
    let suffix = String(components.path.dropFirst("/api/v1/artwork/".count))
    let parts = suffix.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    if parts.count == 1, UUID(uuidString: parts[0]) != nil {
      guard let query = components.queryItems else { return true }
      return query.count == 1 && query[0].name == "width"
        && ["320", "640", "1280", "1920"].contains(query[0].value ?? "")
    }
    if parts.count >= 2, parts.count <= 3, parts[0] == "collection", UUID(uuidString: parts[1]) != nil {
      if parts.count == 3, !["poster", "backdrop"].contains(parts[2]) { return false }
      guard let query = components.queryItems else { return true }
      for item in query {
        switch item.name {
        case "kind":
          guard ["poster", "backdrop"].contains(item.value ?? "") else { return false }
        case "width":
          guard ["320", "640", "1280", "1920"].contains(item.value ?? "") else { return false }
        case "rev":
          guard let val = item.value, !val.isEmpty, val.allSatisfy(\.isNumber) else { return false }
        default:
          return false
        }
      }
      return true
    }
    return false
  }

  static func query(name: String, value: String) throws -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    guard let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed),
      let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed)
    else { throw APIClientError.invalidAddress }
    return "\(encodedName)=\(encodedValue)"
  }

  @discardableResult
  func sleepTimerEnded() async throws -> SleepTimerEndedResponse? {
    let data = try await perform(path: "/api/v1/playback/sleep-timer-ended", method: "POST")
    guard !data.isEmpty else { return nil }
    return try? Self.decode(SleepTimerEndedResponse.self, from: data)
  }

  func wishes(state: WishState? = nil, offset: Int = 0, limit: Int = 30) async throws
    -> WishListResponse
  {
    var params: [String] = []
    if let state {
      params.append(try Self.query(name: "state", value: state.rawValue))
    }
    if offset > 0 {
      params.append("offset=\(offset)")
    }
    params.append("limit=\(max(1, min(limit, 100)))")
    let suffix = params.isEmpty ? "" : "?\(params.joined(separator: "&"))"
    return try await get("/api/v1/wishes\(suffix)")
  }

  func wishSummary() async throws -> WishSummaryResponse {
    try await get("/api/v1/wishes/summary")
  }

  func wishSearch(query: String, kind: MediaKind? = nil) async throws -> WishSearchResponse {
    var params = [try Self.query(name: "query", value: query)]
    if let kind {
      params.append(try Self.query(name: "kind", value: kind.rawValue))
    }
    return try await get("/api/v1/wishes/search?\(params.joined(separator: "&"))")
  }

  func createWish(_ payload: CreateWishRequest) async throws -> CreateWishOutcome {
    let body = try JSONEncoder().encode(payload)
    let (data, http, _) = try await Self.request(
      baseURL: profile.baseURL,
      path: "/api/v1/wishes",
      method: "POST",
      token: profile.token,
      body: body,
      trustMode: .pinned(profile.publicKeyFingerprint),
      allowedStatuses: [409])
    if http.statusCode == 409 {
      if let conflict = try? Self.decode(WishAlreadyInLibraryProblem.self, from: data),
        conflict.code == "already_in_library"
      {
        return .alreadyInLibrary(conflict)
      }
      throw Self.responseError(
        status: http.statusCode,
        retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
        data: data)
    }
    return .created(try Self.decode(CreateWishResponse.self, from: data))
  }

  func deleteWish(id: UUID) async throws {
    _ = try await perform(path: "/api/v1/wishes/\(id.uuidString.lowercased())", method: "DELETE")
  }

  func setWishSupport(id: UUID, supported: Bool) async throws -> WishSummary {
    let body = try JSONEncoder().encode(SetWishSupportRequest(supported: supported))
    let data = try await perform(
      path: "/api/v1/wishes/\(id.uuidString.lowercased())/support",
      method: "PUT",
      body: body)
    return try Self.decode(WishSummary.self, from: data)
  }

  func updateWishState(
    id: UUID, state: WishState, resolutionNote: String? = nil, fulfilledMediaItemId: UUID? = nil
  ) async throws -> WishSummary {
    let body = try JSONEncoder().encode(
      UpdateWishStateRequest(
        state: state, resolutionNote: resolutionNote, fulfilledMediaItemId: fulfilledMediaItemId))
    let data = try await perform(
      path: "/api/v1/wishes/\(id.uuidString.lowercased())/state",
      method: "PUT",
      body: body)
    return try Self.decode(WishSummary.self, from: data)
  }

  func markWishesSeen() async throws -> WishSummaryResponse {
    let data = try await perform(path: "/api/v1/wishes/seen", method: "POST")
    return try Self.decode(WishSummaryResponse.self, from: data)
  }

  func wishPosterData(path: String, width: Int = 342) async throws -> Data {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.hasPrefix("/"), !trimmed.contains("://") else {
      throw APIClientError.invalidResponse
    }
    let query = [
      try Self.query(name: "path", value: trimmed),
      "width=\(max(92, min(width, 780)))",
    ].joined(separator: "&")
    return try await perform(path: "/api/v1/wishes/poster?\(query)", method: "GET")
  }

  func createPlayback(mediaId: UUID) async throws -> PlaybackSourceResponse {
    let data = try await perform(
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/playback",
      method: "POST")
    let source = try Self.decode(PlaybackSourceResponse.self, from: data)
    guard source.mediaId == mediaId, source.progress.mediaId == mediaId else {
      throw APIClientError.invalidResponse
    }
    return source
  }

  /// Trailers of other films the profile hasn't started, for the pre-show before film `mediaId`.
  /// The server refuses titles that aren't films.
  func cinemaTrailers(mediaId: UUID, count: Int) async throws -> [CinemaTrailer] {
    let response: CinemaTrailersResponse = try await get(
      "/api/v1/media/\(mediaId.uuidString.lowercased())/cinema-trailers?count=\(count)")
    return response.trailers
  }

  /// What to watch after a title (servers from 2.11.0); an episode's are its series'.
  func suggestions(mediaId: UUID, limit: Int = 10) async throws -> [MediaSuggestion] {
    let response: MediaSuggestionsResponse = try await get(
      "/api/v1/media/\(mediaId.uuidString.lowercased())/suggestions?limit=\(limit)")
    return response.suggestions
  }

  func playbackProgress(mediaId: UUID) async throws -> PlaybackProgressResponse {
    try await get("/api/v1/media/\(mediaId.uuidString.lowercased())/progress")
  }

  func updatePlaybackProgress(
    mediaId: UUID,
    positionMilliseconds: Int64,
    durationMilliseconds: Int64,
    isFinished: Bool,
    expectedRevision: Int64? = nil,
    clientMutationId: UUID? = nil
  ) async throws -> PlaybackProgressResponse {
    let body = try JSONEncoder().encode(
      UpdatePlaybackProgressRequest(
        positionMilliseconds: positionMilliseconds,
        durationMilliseconds: durationMilliseconds,
        isFinished: isFinished,
        expectedRevision: expectedRevision,
        enforceRevision: expectedRevision != nil ? true : nil,
        clientMutationId: clientMutationId))
    let data = try await perform(
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/progress",
      method: "PUT",
      body: body)
    return try Self.decode(PlaybackProgressResponse.self, from: data)
  }

  /// A title's sound tracks, through its playback ticket, for writing subtitles from speech.
  func speechAudioTracks(streamPath: String) async throws -> SpeechAudioTracksResponse {
    _ = try streamURL(path: streamPath)
    return try await get("\(streamPath)/speech-audio/tracks")
  }

  /// Reads one sound track as 16 kHz mono PCM, in chunks.
  func speechAudio(streamPath: String, track: Int) throws -> SpeechAudioReader {
    let base = try streamURL(path: streamPath)
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
      throw APIClientError.invalidResponse
    }
    components.path += "/speech-audio"
    components.queryItems = [URLQueryItem(name: "audio", value: String(track))]
    guard let url = components.url else { throw APIClientError.invalidResponse }
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("Bearer \(profile.token)", forHTTPHeaderField: "Authorization")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    return SpeechAudioReader(request: request, fingerprint: profile.publicKeyFingerprint)
  }

  /// Whether the server can listen to this title ("server-speech-v1") and its job, if any.
  func mediaSpeech(mediaId: UUID) async throws -> MediaSpeechInfo {
    try await get("/api/v1/media/\(mediaId.uuidString.lowercased())/speech")
  }

  /// Has the server write subtitles from speech, or sync a subtitle track to it, in the background.
  func startServerSpeech(mediaId: UUID, _ request: StartServerSpeechRequest) async throws -> MediaSpeechInfo {
    let data = try await perform(
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/speech", method: "POST",
      body: try JSONEncoder().encode(request))
    return try Self.decode(MediaSpeechInfo.self, from: data)
  }

  func cancelServerSpeech(mediaId: UUID) async throws {
    _ = try await perform(path: "/api/v1/media/\(mediaId.uuidString.lowercased())/speech", method: "DELETE")
  }

  /// The owner's Speech Recognition settings: whisper.cpp, the model and the jobs.
  func serverSpeech() async throws -> ServerSpeechSettings { try await get("/api/v1/server/speech") }

  func downloadSpeechModel(_ name: String) async throws -> ServerSpeechSettings {
    let data = try await perform(
      path: "/api/v1/server/speech/model", method: "POST",
      body: try JSONEncoder().encode(["name": name]))
    return try Self.decode(ServerSpeechSettings.self, from: data)
  }

  func removeSpeechModel() async throws -> ServerSpeechSettings {
    let data = try await perform(path: "/api/v1/server/speech/model", method: "DELETE")
    return try Self.decode(ServerSpeechSettings.self, from: data)
  }

  /// Keeps subtitles written from speech on the server, in place of earlier ones in that language.
  func saveSpeechSubtitles(mediaId: UUID, language: String, subRip: String) async throws
    -> DownloadedSubtitle
  {
    let code = language.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    let data = try await perform(
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/subtitles/speech?language=\(code)",
      method: "POST", body: Data(subRip.utf8), timeout: 60)
    return try Self.decode(DownloadedSubtitle.self, from: data)
  }

  /// One of the title's subtitle tracks as WebVTT text, through its playback ticket.
  func streamSubtitleText(streamPath: String, index: Int) async throws -> String {
    _ = try streamURL(path: streamPath)
    let data = try await perform(path: "\(streamPath)/subtitles/\(max(0, index))", timeout: 60)
    return String(decoding: data, as: UTF8.self)
  }

  /// Keeps a copy of subtitles moved to fit the speech, in place of an earlier synced copy.
  func saveSyncedSubtitles(mediaId: UUID, language: String, subRip: String) async throws
    -> DownloadedSubtitle
  {
    let code = language.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    let data = try await perform(
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/subtitles/synced?language=\(code)",
      method: "POST", body: Data(subRip.utf8), timeout: 60)
    return try Self.decode(DownloadedSubtitle.self, from: data)
  }

  func revokePlayback(id: UUID) async throws {
    _ = try await perform(
      path: "/api/v1/playback/\(id.uuidString.lowercased())",
      method: "DELETE")
  }

  func streamURL(path: String) throws -> URL {
    guard path.hasPrefix("/api/v1/streams/"),
      !path.contains("?"),
      !path.contains("#"),
      let components = URLComponents(string: path),
      components.scheme == nil,
      components.host == nil,
      let url = URL(string: path, relativeTo: profile.baseURL)?.absoluteURL,
      url.host?.caseInsensitiveCompare(profile.baseURL.host ?? "") == .orderedSame
    else {
      throw APIClientError.invalidResponse
    }
    return url
  }

  func logout() async throws {
    _ = try await perform(path: "/api/v1/auth/logout", method: "POST")
  }

  private func allPages<Item: Decodable & Sendable & Identifiable>(
    path: String,
    query: String? = nil
  ) async throws -> [Item] where Item.ID == UUID {
    try await Self.loadPages { offset, revision in
      let prefix = query.map { "\($0)&" } ?? ""
      let revisionQuery =
        try revision.map { "&" + (try Self.query(name: "revision", value: $0)) } ?? ""
      return try await get(
        "\(path)?\(prefix)offset=\(offset)&limit=\(catalogPageSize)\(revisionQuery)")
    }
  }

  static func loadPages<Item: Decodable & Sendable & Identifiable>(
    fetch: (Int, String?) async throws -> PagedResponse<Item>
  ) async throws -> [Item] where Item.ID == UUID {
    for attempt in 0...2 {
      var collected: [Item] = []
      var identities = Set<UUID>()
      var offset = 0
      var revision: String?
      var total: Int?
      do {
        while true {
          try Task.checkCancellation()
          let page = try await fetch(offset, revision)
          guard page.offset == offset, page.limit > 0, page.total >= 0,
            page.items.count <= page.limit
          else { throw APIClientError.invalidResponse }
          if offset == 0 {
            revision = page.revision
            total = page.total
          }
          guard page.revision == revision, page.total == total else {
            throw APIClientError.serverRejected(
              code: "catalog_changed", message: "The library changed while loading. Try again.")
          }
          for item in page.items where identities.insert(item.id).inserted {
            collected.append(item)
          }
          offset += page.items.count
          if offset >= page.total {
            guard collected.count == page.total else {
              throw APIClientError.serverRejected(
                code: "catalog_changed", message: "The library changed while loading. Try again.")
            }
            return collected
          }
          guard !page.items.isEmpty else { throw APIClientError.invalidResponse }
        }
      } catch let error as APIClientError
        where error.problemCode == "catalog_changed" && attempt < 2
      {
        continue
      }
    }
    throw APIClientError.serverRejected(
      code: "catalog_changed",
      message: "The library kept changing while loading. Try again after the current scan finishes."
    )
  }

  private func get<Value: Decodable>(_ path: String) async throws -> Value {
    let data = try await perform(path: path, method: "GET")
    return try Self.decode(Value.self, from: data)
  }

  private func perform(
    path: String,
    method: String = "GET",
    body: Data? = nil,
    timeout: TimeInterval = 15
  ) async throws -> Data {
    #if DEBUG
      if await ProfileEditorUITestFixture.enabled,
        let fixture = try await ProfileEditorUITestFixture.response(
          path: path, method: method, body: body)
      {
        return fixture
      }
      if await ShowcaseUITestFixture.enabled, method == "GET",
        path.hasPrefix("/api/v1/artwork/"),
        let data = await ShowcaseUITestFixture.artwork(path: path)
      {
        return data
      }
      if await CinemaUITestFixture.enabled, path.contains("/notes") {
        return try await CinemaUITestFixture.sceneNotes(path: path, method: method, body: body)
      }
      if await CinemaUITestFixture.enabled, method == "GET",
        path.hasPrefix("/api/v1/artwork/") || path.contains("/editor/artwork/")
      {
        return await CinemaUITestFixture.png
      }
      if await LibraryStateUITestFixture.enabled, method == "GET",
        path.hasPrefix("/api/v1/artwork/") || path.contains("/editor/artwork/")
      {
        return await CinemaUITestFixture.png
      }
      if ProcessInfo.processInfo.environment["AURELIA_UI_TEST_MODE"] == "library-admin",
        path == "/api/v1/metadata/reviews" || path.hasSuffix("/editor")
          || path.hasSuffix("/metadata")
      {
        return try await MetadataEditorUITestFixture.response(
          path: path, method: method, body: body)
      }
      if ProcessInfo.processInfo.environment["AURELIA_UI_TEST_MODE"] == "server-settings"
        || ProcessInfo.processInfo.environment["AURELIA_UI_TEST_MODE"] == "profile-management"
        || ProcessInfo.processInfo.environment["AURELIA_UI_TEST_MODE"] == "local-host-recovery"
        || profile.baseURL.host == "server-settings-preview.invalid"
      {
        if ProcessInfo.processInfo.environment["AURELIA_DEVICE_APPROVAL_UI_TESTS"] == "1",
          path.hasPrefix("/api/v1/server/device-pairings/")
        {
          if path.hasSuffix("/lookup") {
            guard let body,
              let values = try JSONSerialization.jsonObject(with: body) as? [String: String],
              values["code"] == "12345678"
            else {
              throw APIClientError.serverRejected(
                code: "invalid_device_pairing_code",
                message: "The device code is invalid or has expired.")
            }
          }
          let state =
            path.hasSuffix("/approve") ? "approved" : path.hasSuffix("/deny") ? "denied" : "pending"
          return Data(
            """
            {"id":"15500000-0000-0000-0000-000000000001","deviceName":"Living Room Apple TV",
            "serverId":"00000000-0000-0000-0000-000000000004","serverName":"Synthetic UI Server",
            "state":"\(state)","expiresAt":"2099-01-01T00:00:00Z"}
            """.utf8)
        }
        guard method == "GET" else { throw APIClientError.invalidResponse }
        return try Self.serverSettingsFixture(path: path)
      }
    #endif
    return try await AdministrationRequestExecutor.execute { proof in
      let headers = proof.map { ["X-Aurelia-Approval": $0] } ?? [:]
      let (data, _, _) = try await Self.request(
        baseURL: profile.baseURL, path: path, method: method, token: profile.token, body: body,
        trustMode: .pinned(profile.publicKeyFingerprint), additionalHeaders: headers,
        timeout: timeout)
      return data
    } approve: {
      struct Confirmation: Encodable {
        let action: String
        let payloadHash: String
      }
      struct Approval: Decodable { let token: String }
      let hash = SHA256.hash(data: body ?? Data()).map { String(format: "%02x", $0) }.joined()
      let confirmation = Confirmation(
        action: try AdministrationRequestExecutor.action(
          baseURL: profile.baseURL, path: path, method: method),
        payloadHash: hash)
      let (data, _, _) = try await Self.request(
        baseURL: profile.baseURL, path: "/api/v1/management/approval", method: "POST",
        token: profile.token, body: JSONEncoder().encode(confirmation),
        trustMode: .pinned(profile.publicKeyFingerprint))
      return try Self.decode(Approval.self, from: data).token
    }
  }

  func serverCapabilities() async throws -> ServerCapabilities {
    try Self.decode(
      ServerCapabilities.self, from: await perform(path: "/api/v1/server/capabilities"))
  }
  func lookupDeviceAuthorization(code: String) async throws -> DeviceAuthorizationPreview {
    struct Request: Encodable { let code: String }
    let response = try Self.decode(
      DeviceAuthorizationPreview.self,
      from: await perform(
        path: "/api/v1/server/device-pairings/lookup", method: "POST",
        body: JSONEncoder().encode(Request(code: code))))
    guard response.serverId == profile.serverId else { throw APIClientError.serverIdentityMismatch }
    return response
  }

  func decideDeviceAuthorization(id: UUID, approve: Bool) async throws -> DeviceAuthorizationPreview
  {
    let action = approve ? "approve" : "deny"
    let response = try Self.decode(
      DeviceAuthorizationPreview.self,
      from: await perform(
        path: "/api/v1/server/device-pairings/\(id.uuidString.lowercased())/\(action)",
        method: "POST"))
    guard response.id == id, response.serverId == profile.serverId else {
      throw APIClientError.invalidResponse
    }
    return response
  }
  func serverBackups() async throws -> [ServerBackupSummary] {
    try Self.decode([ServerBackupSummary].self, from: await perform(path: "/api/v1/server/backups"))
  }
  func serverPower() async throws -> ServerPowerSettings { try await get("/api/v1/server/power") }
  func serverTranscoding() async throws -> TranscodingStatus {
    try await get("/api/v1/server/transcoding")
  }

  func serverScrubPreviews() async throws -> ScrubPreviewSettings {
    try await get("/api/v1/server/scrub-previews")
  }
  func saveServerScrubPreviews(_ settings: UpdateScrubPreviewSettingsRequest) async throws
    -> ScrubPreviewSettings
  {
    let data = try await perform(
      path: "/api/v1/server/scrub-previews", method: "PUT",
      body: JSONEncoder().encode(settings))
    return try Self.decode(ScrubPreviewSettings.self, from: data)
  }
  func deleteServerScrubPreviews() async throws -> ScrubPreviewSettings {
    let data = try await perform(path: "/api/v1/server/scrub-previews", method: "DELETE")
    return try Self.decode(ScrubPreviewSettings.self, from: data)
  }
  /// Intro and credits times of one title with their origin ("media-segments-v2").
  func mediaSegments(mediaId: UUID) async throws -> MediaSegmentTimes {
    try await get("/api/v1/media/\(mediaId.uuidString.lowercased())/segments")
  }
  /// Corrects the times by hand; a changed part is never replaced by detection again.
  func saveMediaSegments(mediaId: UUID, _ request: SetMediaSegmentsRequest) async throws
    -> MediaSegmentTimes
  {
    let data = try await perform(
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/segments", method: "PUT",
      body: try JSONEncoder().encode(request))
    return try Self.decode(MediaSegmentTimes.self, from: data)
  }
  /// Removes the corrections; the server examines the title again.
  func resetMediaSegments(mediaId: UUID) async throws -> MediaSegmentTimes {
    let data = try await perform(
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/segments", method: "DELETE")
    return try Self.decode(MediaSegmentTimes.self, from: data)
  }
  /// Has the server examine an episode's season (or all seasons of a series) again.
  func reanalyzeMediaSegments(mediaId: UUID) async throws {
    _ = try await perform(
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/segments/reanalyze", method: "POST")
  }
  func serverMediaSegments() async throws -> MediaSegmentSettings {
    try await get("/api/v1/server/media-segments")
  }
  func saveServerMediaSegments(enabled: Bool, usePictures: Bool? = nil) async throws
    -> MediaSegmentSettings
  {
    var body = ["enabled": enabled]
    if let usePictures { body["usePictures"] = usePictures }
    let data = try await perform(
      path: "/api/v1/server/media-segments", method: "PUT", body: try JSONEncoder().encode(body))
    return try Self.decode(MediaSegmentSettings.self, from: data)
  }
  /// Each series with how many episodes have an intro and credits and how many are still to examine.
  func mediaSegmentSeries() async throws -> [MediaSegmentSeriesStatus] {
    try await get("/api/v1/server/media-segments/series")
  }
  func reanalyzeMediaSegments(seriesId: UUID) async throws -> MediaSegmentSettings {
    let data = try await perform(
      path: "/api/v1/server/media-segments/reanalyze", method: "POST",
      body: try JSONEncoder().encode(["seriesId": seriesId.uuidString.lowercased()]))
    return try Self.decode(MediaSegmentSettings.self, from: data)
  }
  func reanalyzeMovieSegments() async throws -> MediaSegmentSettings {
    let data = try await perform(
      path: "/api/v1/server/media-segments/reanalyze", method: "POST",
      body: Data(#"{"movies":true}"#.utf8))
    return try Self.decode(MediaSegmentSettings.self, from: data)
  }
  func reanalyzeAllMediaSegments() async throws -> MediaSegmentSettings {
    let data = try await perform(
      path: "/api/v1/server/media-segments/reanalyze", method: "POST",
      body: Data("{}".utf8))
    return try Self.decode(MediaSegmentSettings.self, from: data)
  }
  func scrubPreviewFrame(mediaId: UUID, seconds: Int) async throws -> Data {
    let (data, _, _) = try await Self.request(
      baseURL: profile.baseURL,
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/scrub-previews/\(max(0, seconds))",
      method: "GET",
      token: profile.token,
      body: nil,
      trustMode: .pinned(profile.publicKeyFingerprint),
      additionalHeaders: ["Accept": "image/jpeg"],
      timeout: 8)
    return data
  }
  func serverUpdates() async throws -> ServerUpdateStatus {
    try await get("/api/v1/server/updates")
  }
  func checkServerUpdates() async throws -> ServerUpdateStatus {
    try Self.decode(
      ServerUpdateStatus.self,
      from: await perform(path: "/api/v1/server/updates/check", method: "POST"))
  }
  func installServerUpdate() async throws -> ServerUpdateStatus {
    try Self.decode(
      ServerUpdateStatus.self,
      from: await perform(path: "/api/v1/server/updates/install", method: "POST"))
  }
  func saveServerPower(_ settings: ServerPowerSettings) async throws -> ServerPowerSettings {
    struct Request: Encodable {
      let mode: String
      let idleMinutes: Int
      let awakeFrom: String?
      let awakeUntil: String?
    }
    let data = try await perform(
      path: "/api/v1/server/power", method: "PUT",
      body: JSONEncoder().encode(
        Request(
          mode: settings.mode, idleMinutes: settings.idleMinutes,
          awakeFrom: settings.awakeFrom, awakeUntil: settings.awakeUntil)))
    return try Self.decode(ServerPowerSettings.self, from: data)
  }
  func serverDiagnostics() async throws -> [ServerDiagnosticEvent] {
    try Self.decode(
      [ServerDiagnosticEvent].self, from: await perform(path: "/api/v1/server/diagnostics"))
  }
  func serverDiagnosticsExport() async throws -> Data {
    try await perform(path: "/api/v1/server/diagnostics/export")
  }
  func createDatabaseBackup() async throws {
    _ = try await perform(path: "/api/v1/server/backups/database", method: "POST", timeout: 120)
  }
  func verifyDatabaseBackup(name: String) async throws {
    struct Verification: Decodable { let isValid: Bool }
    let result = try Self.decode(
      Verification.self,
      from: await perform(
        path: "/api/v1/server/backups/\(name)/verify", method: "POST", timeout: 120))
    guard result.isValid else { throw APIClientError.invalidResponse }
  }
  func serverJobs() async throws -> ServerJobHistory { try await get("/api/v1/server/jobs") }
  func retryMetadataJob(id: UUID) async throws {
    _ = try await perform(path: "/api/v1/metadata/jobs/\(id.uuidString)/retry", method: "POST")
  }
  func currentHostOperation() async throws -> HostOperationStatus? {
    let data = try await perform(path: "/api/v1/server/operations/current")
    if String(data: data, encoding: .utf8) == "null" { return nil }
    return try Self.decode(HostOperationStatus.self, from: data)
  }
  func restartServer() async throws -> HostOperationStatus {
    try Self.decode(
      HostOperationStatus.self,
      from: await perform(path: "/api/v1/server/operations/restart", method: "POST"))
  }
  func serverHosting() async throws -> ServerHostingStatus {
    try await get("/api/v1/server/hosting")
  }
  func authorizeHostingChange(_ settings: HostServiceSettings) async throws -> HostOperationStatus {
    struct Request: Encodable {
      let backgroundEnabled: Bool
      let startAtLogin: Bool
      let preventIdleSleep: Bool
    }
    return try Self.decode(
      HostOperationStatus.self,
      from: await perform(
        path: "/api/v1/server/operations/hosting", method: "POST",
        body: JSONEncoder().encode(
          Request(
            backgroundEnabled: settings.backgroundEnabled, startAtLogin: settings.startAtLogin,
            preventIdleSleep: settings.preventIdleSleep))))
  }
  func trialNetwork(_ settings: ServerPolicySettings, confirmDisconnect: Bool) async throws
    -> HostOperationStatus
  {
    struct Request: Encodable {
      let settings: ServerPolicySettings
      let confirmRemoteAccessDisabled: Bool
    }
    return try Self.decode(
      HostOperationStatus.self,
      from: await perform(
        path: "/api/v1/server/operations/network", method: "POST",
        body: JSONEncoder().encode(
          Request(settings: settings, confirmRemoteAccessDisabled: confirmDisconnect))))
  }
  func confirmNetwork(id: UUID) async throws {
    _ = try await perform(
      path: "/api/v1/server/operations/\(id.uuidString)/confirm", method: "POST")
  }
  func exportEncryptedServerBackup(passphrase: String, to destination: URL) async throws {
    let access = destination.startAccessingSecurityScopedResource()
    defer { if access { destination.stopAccessingSecurityScopedResource() } }
    struct Request: Encodable { let passphrase: String }
    struct Response: Decodable { let id: UUID }
    let result = try Self.decode(
      Response.self,
      from: await perform(
        path: "/api/v1/server/backups/export", method: "POST",
        body: JSONEncoder().encode(Request(passphrase: passphrase)), timeout: 300))
    defer {
      Task {
        _ = try? await self.perform(
          path: "/api/v1/server/backups/transfers/\(result.id.uuidString)", method: "DELETE")
      }
    }
    let url = profile.baseURL.appendingPathComponent(
      "api/v1/server/backups/transfers/\(result.id.uuidString)")
    var request = URLRequest(url: url)
    request.setValue("Bearer \(profile.token)", forHTTPHeaderField: "Authorization")
    let delegate = TLSTrustDelegate(
      mode: .pinned(profile.publicKeyFingerprint), allowedHost: profile.baseURL.host ?? "")
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (temporary, response) = try await session.download(for: request)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try Task.checkCancellation()
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw APIClientError.invalidResponse
    }
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: destination)
    }
  }
  func prepareServerRestore(
    from file: URL, passphrase: String, acceptDifferentIdentity: Bool = false
  ) async throws -> PreparedServerRestore {
    let access = file.startAccessingSecurityScopedResource()
    defer { if access { file.stopAccessingSecurityScopedResource() } }
    let id = UUID()
    defer {
      Task {
        _ = try? await self.perform(
          path: "/api/v1/server/backups/transfers/\(id.uuidString)", method: "DELETE")
      }
    }
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, Int64(size) <= 4 * 1024 * 1024 * 1024 else {
      throw APIClientError.invalidResponse
    }
    var request = URLRequest(
      url: profile.baseURL.appendingPathComponent("api/v1/server/backups/uploads/\(id.uuidString)"))
    request.httpMethod = "PUT"
    request.setValue("Bearer \(profile.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue("\(size)", forHTTPHeaderField: "Content-Length")
    let delegate = TLSTrustDelegate(
      mode: .pinned(profile.publicKeyFingerprint), allowedHost: profile.baseURL.host ?? "")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForResource = 600
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (_, response) = try await session.upload(for: request, fromFile: file)
    try Task.checkCancellation()
    guard (response as? HTTPURLResponse)?.statusCode == 204 else {
      throw APIClientError.invalidResponse
    }
    struct Restore: Encodable {
      let uploadId: UUID
      let passphrase: String
      let revokeAllSessions: Bool
      let acceptDifferentServerIdentity: Bool
    }
    return try Self.decode(
      PreparedServerRestore.self,
      from: await perform(
        path: "/api/v1/server/backups/restore/prepare", method: "POST",
        body: JSONEncoder().encode(
          Restore(
            uploadId: id, passphrase: passphrase, revokeAllSessions: true,
            acceptDifferentServerIdentity: acceptDifferentIdentity)), timeout: 300))
  }
  func applyServerRestore(id: UUID) async throws {
    _ = try await perform(
      path: "/api/v1/server/backups/restore/\(id.uuidString)/apply", method: "POST")
  }

  #if DEBUG
    private static func serverSettingsFixture(path: String) throws -> Data {
      let configuration = """
        {"stored":{"version":2,"serverName":"Synthetic UI Server","lanAccessEnabled":true,"lanHttpsPort":43111,
        "revision":1,"pairingEnabled":true,"deviceSessionDays":90,"globalStreamLimit":32,"userStreamLimit":4,
        "bonjourEnabled":true,"allowedNetworks":[],"monitoringEnabled":true,"reconciliationMinutes":360,
        "maintenanceStartHour":0,"maintenanceEndHour":24,"jobQueueLimit":1000,"automaticBackupsEnabled":true,
        "backupIntervalHours":24,"dailyBackupsRetained":7,"weeklyBackupsRetained":4,"eventRetentionDays":30,"maximumEvents":10000},
        "active":{"serverName":"Synthetic UI Server","lanAccessEnabled":true,"lanHttpsPort":43111},"restartRequired":false}
        """
      let response: String
      switch path {
      case "/api/v1/server/settings": response = configuration
      case "/api/v1/server/capabilities":
        response =
          "{\"nativeHostOperations\":false,\"encryptedBackups\":true,\"transcoding\":false}"
      case "/api/v1/server/status":
        response = """
          {"state":"running","version":"\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2")","uptimeSeconds":3600,"activeStreams":0,"databaseBytes":1048576,
          "users":1,"libraries":0,"freeDiskBytes":10737418240,"certificateExpiresAt":"2036-10-01T12:00:00Z","networkAddresses":["192.168.1.10"],
          "readiness":{"state":"degraded","components":[{"id":"database","state":"ready"},{"id":"media","state":"degraded","reason":"media_drive_disconnected"}],"checkedAt":"2026-10-15T12:00:00Z"},"recentRecoveryEvents":[]}
          """
      case "/api/v1/server/users", "/api/v1/server/backups", "/api/v1/server/diagnostics",
        "/api/v1/libraries", "/api/v1/auth/sessions", "/api/v1/libraries/scans":
        response = "[]"
      case "/api/v1/metadata/provider":
        response = """
          {"enabled":false,"hasToken":false,"language":"en-US","artworkBytes":0,
          "artworkLimitBytes":1073741824,"provider":"TMDB","attribution":"Synthetic test provider"}
          """
      case "/api/v1/server/jobs":
        if ProcessInfo.processInfo.environment["AURELIA_METADATA_WAIT_UI_TESTS"] == "1" {
          response = """
            {"scans":[],"metadata":[{"id":"70000000-0000-0000-0000-000000000001",
            "state":"queued","itemsTotal":10,"itemsProcessed":4,"itemsMatched":2,
            "itemsNeedingReview":1,"itemsFailed":0,"itemsSkipped":1,
            "createdAt":"2026-10-15T12:00:00Z","nextAttemptAt":"2026-10-15T14:32:00Z","waitReason":"tmdb"}]}
            """
        } else {
          response = "{\"scans\":[],\"metadata\":[]}"
        }
      case "/api/v1/server/operations/current": response = "null"
      case "/api/v1/server/health":
        response = """
          {"uptimeSeconds":3600,"freeDiskBytes":10737418240,"databaseBytes":1048576,
          "scrubPreviewTitleCount":0,"scrubPreviewBytes":0,"scrubPreviewPendingCount":0,
          "activeLiveConversions":0,"activeStreams":0,"offlineMediaCount":0,
          "lastScan":null,"backgroundJobs":{"activeScans":0,"activeMetadataJobs":0,"activeScrubPreviewJobs":0},
          "recentIssues":[],"backup":null}
          """
      case "/api/v1/server/scrub-previews":
        response = """
          {"available":true,"mode":"off","intervalSeconds":15,"storageCapMegabytes":500,
          "storedTitleCount":0,"storedBytes":0,"activeCount":0,"pendingCount":0,
          "completedCount":0,"totalScheduledCount":0,"pausedForPlayback":false}
          """
      case let p where p.hasPrefix("/api/v1/library/health/duplicates"):
        response = "[]"
      case let p where p.hasPrefix("/api/v1/library/health/offline"):
        response = "[]"
      case let p where p.hasPrefix("/api/v1/library/health/unmatched"):
        response = "[]"
      case "/api/v1/catalog/franchises":
        response = "[]"
      case let p where p.hasPrefix("/api/v1/history"):
        response = "{\"items\":[],\"totalCount\":0,\"offset\":0,\"limit\":50}"
      case "/api/v1/statistics":
        response = """
          {"totalHoursWatched":0,"hoursPast7Days":0,"hoursPast30Days":0,"weeklyHours":[],
          "monthlyHours":[],"topGenres":[],"currentStreakDays":0,"longestStreakDays":0,
          "completionRatePercent":0,"busiestDayOfWeek":"Sunday","busiestHourOfDay":20,"yearsAvailable":[]}
          """
      default: throw APIClientError.invalidResponse
      }
      return Data(response.utf8)
    }
  #endif

  private static func request(
    baseURL: URL,
    path: String,
    method: String,
    token: String?,
    body: Data?,
    trustMode: TLSTrustDelegate.Mode,
    additionalHeaders: [String: String] = [:],
    timeout: TimeInterval = 15,
    allowedStatuses: Set<Int> = []
  ) async throws -> (Data, HTTPURLResponse, TLSTrustDelegate) {
    guard let host = baseURL.host,
      let url = URL(string: path, relativeTo: baseURL)?.absoluteURL
    else {
      throw APIClientError.invalidAddress
    }
    let delegate: TLSTrustDelegate
    let session: URLSession
    let pooled: Bool
    switch trustMode {
    case .pinned(let fingerprint):
      // Pinned requests share open connections instead of a new TLS handshake each time.
      (session, delegate) = PinnedSessionPool.shared.lease(
        host: host, port: url.port, fingerprint: fingerprint)
      pooled = true
    case .inspect:
      // Inspection captures the presented key of exactly one fresh connection.
      delegate = TLSTrustDelegate(mode: trustMode, allowedHost: host)
      let configuration = URLSessionConfiguration.ephemeral
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.urlCache = nil
      configuration.httpCookieStorage = nil
      session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
      pooled = false
    }
    defer { if !pooled { session.invalidateAndCancel() } }

    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    request.httpMethod = method
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    for (name, value) in additionalHeaders {
      request.setValue(value, forHTTPHeaderField: name)
    }
    if let token {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body {
      request.httpBody = body
      request.setValue(
        path.hasSuffix("/editor/uploads")
          ? "image/png" : path.hasSuffix("/picture/photo") ? "image/jpeg"
          : path.contains("/subtitles/speech") || path.contains("/subtitles/synced")
            ? "text/plain; charset=utf-8" : "application/json",
        forHTTPHeaderField: "Content-Type")
    }

    let result: (Data, URLResponse)
    do { result = try await session.data(for: request) } catch {
      if delegate.didRejectTrust { throw APIClientError.serverIdentityMismatch }
      throw error
    }
    let (data, response) = result
    guard let http = response as? HTTPURLResponse else {
      throw APIClientError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) || allowedStatuses.contains(http.statusCode) else {
      throw Self.responseError(
        status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
        data: data)
    }
    return (data, http, delegate)
  }

  static func responseError(status: Int, retryAfter: String?, data: Data, now: Date = Date())
    -> APIClientError
  {
    let problem = try? JSONDecoder().decode(APIProblem.self, from: data)
    var delay = retryAfter.flatMap(TimeInterval.init)
    if delay == nil, let retryAfter {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
      delay = formatter.date(from: retryAfter)?.timeIntervalSince(now)
    }
    let bounded = delay.flatMap { $0.isFinite ? min(max($0, 0), 300) : nil }
    return .httpFailure(
      status: status, retryAfter: bounded, code: problem?.code, message: problem?.message)
  }

  private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value
  {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      APIResponseDiagnostics.decodingFailure(type, error: error)
      throw APIClientError.invalidResponse
    }
  }
}
