import CryptoKit
@preconcurrency import Foundation

enum APIClientError: LocalizedError, Equatable {
  case invalidAddress
  case insecureAddress
  case invalidResponse
  case serverIdentityMismatch
  case serverRejected(code: String, message: String)

  var errorDescription: String? {
    switch self {
    case .invalidAddress:
      "Enter a valid server address."
    case .insecureAddress:
      "Aurelia requires an HTTPS server address."
    case .invalidResponse:
      "The server returned an invalid response."
    case .serverIdentityMismatch:
      "The server identity does not match the paired server."
    case .serverRejected(_, let message):
      message
    }
  }
}

struct APIClient: Sendable {
  let profile: StoredServerProfile

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

  static func inspect(baseURL: URL) async throws -> InspectedServer {
    let (data, _, delegate) = try await request(
      baseURL: baseURL,
      path: "/api/v1/server/info",
      method: "GET",
      token: nil,
      body: nil,
      trustMode: .inspect)
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
  func serverUsers() async throws -> [UserAccessSummary] { try await get("/api/v1/server/users") }
  func userSessions(_ id: UUID) async throws -> [DeviceSessionSummary] {
    try await get("/api/v1/server/sessions/\(id.uuidString)")
  }
  func revokeManagedSession(id: UUID) async throws {
    _ = try await perform(path: "/api/v1/server/sessions/\(id.uuidString)", method: "DELETE")
  }

  func createUser(username: String, password: String, role: UserRole) async throws {
    struct Payload: Encodable {
      let username: String
      let password: String
      let role: UserRole
    }
    _ = try await perform(
      path: "/api/v1/users", method: "POST",
      body: JSONEncoder().encode(Payload(username: username, password: password, role: role)))
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

  func syncChanges(after cursor: Int64, waitSeconds: Int) async throws
    -> SyncChangesResponse
  {
    let data = try await perform(
      path: "/api/v1/sync/changes?after=\(cursor)&waitSeconds=\(waitSeconds)",
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

  func catalogDetail(id: UUID) async throws -> CatalogDetailPresentation {
    try await get("/api/v1/catalog/items/\(id.uuidString.lowercased())")
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

  func createCollection(name: String, mediaIds: [UUID]) async throws -> CollectionSummary {
    let body = try JSONEncoder().encode(SaveCollectionRequest(name: name, mediaIds: mediaIds))
    let data = try await perform(path: "/api/v1/collections", method: "POST", body: body)
    return try Self.decode(CollectionSummary.self, from: data)
  }

  func updateCollection(id: UUID, name: String, mediaIds: [UUID]) async throws
    -> CollectionSummary
  {
    let body = try JSONEncoder().encode(SaveCollectionRequest(name: name, mediaIds: mediaIds))
    let data = try await perform(
      path: "/api/v1/collections/\(id.uuidString.lowercased())", method: "PUT", body: body)
    return try Self.decode(CollectionSummary.self, from: data)
  }

  func deleteCollection(id: UUID) async throws {
    _ = try await perform(
      path: "/api/v1/collections/\(id.uuidString.lowercased())", method: "DELETE")
  }

  func setFavorite(mediaId: UUID, isFavorite: Bool) async throws -> Bool {
    let body = try JSONEncoder().encode(SetFavoriteRequest(isFavorite: isFavorite))
    let data = try await perform(
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/favorite",
      method: "PUT",
      body: body)
    return try Self.decode(Bool.self, from: data)
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
    guard path.hasPrefix("/api/v1/artwork/"), !path.contains("?"), !path.contains("#") else {
      return false
    }
    let identifier = String(path.dropFirst("/api/v1/artwork/".count))
    return UUID(uuidString: identifier) != nil
  }

  static func query(name: String, value: String) throws -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    guard let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed),
      let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed)
    else { throw APIClientError.invalidAddress }
    return "\(encodedName)=\(encodedValue)"
  }

  func createPlayback(mediaId: UUID) async throws -> PlaybackSourceResponse {
    let data = try await perform(
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/playback",
      method: "POST")
    return try Self.decode(PlaybackSourceResponse.self, from: data)
  }

  func playbackProgress(mediaId: UUID) async throws -> PlaybackProgressResponse {
    try await get("/api/v1/media/\(mediaId.uuidString.lowercased())/progress")
  }

  func updatePlaybackProgress(
    mediaId: UUID,
    positionMilliseconds: Int64,
    durationMilliseconds: Int64,
    isFinished: Bool
  ) async throws -> PlaybackProgressResponse {
    let body = try JSONEncoder().encode(
      UpdatePlaybackProgressRequest(
        positionMilliseconds: positionMilliseconds,
        durationMilliseconds: durationMilliseconds,
        isFinished: isFinished))
    let data = try await perform(
      path: "/api/v1/media/\(mediaId.uuidString.lowercased())/progress",
      method: "PUT",
      body: body)
    return try Self.decode(PlaybackProgressResponse.self, from: data)
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

  private func allPages<Item: Decodable & Sendable>(
    path: String,
    query: String? = nil
  ) async throws -> [Item] {
    var collected: [Item] = []
    while true {
      let prefix = query.map { "\($0)&" } ?? ""
      let page: PagedResponse<Item> = try await get(
        "\(path)?\(prefix)offset=\(collected.count)&limit=100")
      collected.append(contentsOf: page.items)
      if collected.count >= page.total || page.items.isEmpty {
        return collected
      }
    }
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
      if ProcessInfo.processInfo.environment["AURELIA_UI_TEST_MODE"] == "library-admin",
        path == "/api/v1/metadata/reviews" || path.hasSuffix("/editor")
          || path.hasSuffix("/metadata")
      {
        return try await MetadataEditorUITestFixture.response(
          path: path, method: method, body: body)
      }
      if ProcessInfo.processInfo.environment["AURELIA_UI_TEST_MODE"] == "server-settings"
        || profile.baseURL.host == "server-settings-preview.invalid"
      {
        guard method == "GET" else { throw APIClientError.invalidResponse }
        return try Self.serverSettingsFixture(path: path)
      }
    #endif
    var headers: [String: String] = [:]
    if Self.requiresAdministrationApproval(path: path, method: method) {
      let libraryReset = path == "/api/v1/libraries/reset"
      guard
        profile.user?.role == .owner
          || (libraryReset && profile.user?.role.canManageLibraries == true)
      else {
        throw APIClientError.serverRejected(
          code: "owner_required", message: "Only an owner may change global server settings.")
      }
      let password = try await AdministrationPasswordPrompt.confirm(serverName: profile.name)
      struct Confirmation: Encodable {
        let action: String
        let payloadHash: String
        let password: String
      }
      struct Approval: Decodable { let token: String }
      let hash = SHA256.hash(data: body ?? Data()).map { String(format: "%02x", $0) }.joined()
      let confirmation = Confirmation(
        action: "\(method) \(path)", payloadHash: hash, password: password)
      let (approvalData, _, _) = try await Self.request(
        baseURL: profile.baseURL,
        path: libraryReset ? "/api/v1/libraries/reset/approval" : "/api/v1/server/approval",
        method: "POST", token: profile.token, body: JSONEncoder().encode(confirmation),
        trustMode: .pinned(profile.publicKeyFingerprint))
      headers["X-Aurelia-Approval"] = try Self.decode(Approval.self, from: approvalData).token
    }
    let (data, _, _) = try await Self.request(
      baseURL: profile.baseURL,
      path: path,
      method: method,
      token: profile.token,
      body: body,
      trustMode: .pinned(profile.publicKeyFingerprint),
      additionalHeaders: headers,
      timeout: timeout)
    return data
  }

  static func requiresAdministrationApproval(path: String, method: String) -> Bool {
    guard method != "GET", method != "HEAD" else { return false }
    let path = path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let normalized = "/" + path
    if normalized.hasPrefix("/api/v1/server/operations/"), normalized.hasSuffix("/confirm") {
      return false
    }
    if method == "PUT", normalized.hasPrefix("/api/v1/server/backups/uploads/") { return false }
    if method == "DELETE", normalized.hasPrefix("/api/v1/server/backups/transfers/") {
      return false
    }
    if normalized.contains("/exclusions/") { return false }
    if normalized == "/api/v1/libraries/reset" { return true }
    return normalized == "/api/v1/server/settings"
      || normalized.hasPrefix("/api/v1/server/operations")
      || normalized.hasPrefix("/api/v1/server/sessions")
      || normalized.hasPrefix("/api/v1/server/backups") || normalized.hasPrefix("/api/v1/users")
      || normalized.hasPrefix("/api/v1/metadata/provider")
      || (normalized.hasPrefix("/api/v1/libraries")
        && (method == "DELETE" || normalized == "/api/v1/libraries"))
  }

  func serverCapabilities() async throws -> ServerCapabilities {
    try Self.decode(
      ServerCapabilities.self, from: await perform(path: "/api/v1/server/capabilities"))
  }
  func serverBackups() async throws -> [ServerBackupSummary] {
    try Self.decode([ServerBackupSummary].self, from: await perform(path: "/api/v1/server/backups"))
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
          "users":1,"libraries":0,"freeDiskBytes":10737418240,"certificateExpiresAt":"2036-10-01T12:00:00Z","networkAddresses":["192.168.1.10"]}
          """
      case "/api/v1/server/users", "/api/v1/server/backups", "/api/v1/server/diagnostics",
        "/api/v1/libraries", "/api/v1/auth/sessions", "/api/v1/libraries/scans":
        response = "[]"
      case "/api/v1/metadata/provider":
        response = """
          {"enabled":false,"hasToken":false,"language":"en-US","artworkBytes":0,
          "artworkLimitBytes":1073741824,"provider":"TMDB","attribution":"Synthetic test provider"}
          """
      case "/api/v1/server/jobs": response = "{\"scans\":[],\"metadata\":[]}"
      case "/api/v1/server/operations/current": response = "null"
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
    timeout: TimeInterval = 15
  ) async throws -> (Data, HTTPURLResponse, TLSTrustDelegate) {
    guard let host = baseURL.host,
      let url = URL(string: path, relativeTo: baseURL)?.absoluteURL
    else {
      throw APIClientError.invalidAddress
    }
    let delegate = TLSTrustDelegate(mode: trustMode, allowedHost: host)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.timeoutIntervalForRequest = timeout
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }

    var request = URLRequest(url: url)
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
        path.hasSuffix("/editor/uploads") ? "image/png" : "application/json",
        forHTTPHeaderField: "Content-Type")
    }

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw APIClientError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      if let problem = try? JSONDecoder().decode(APIProblem.self, from: data) {
        throw APIClientError.serverRejected(code: problem.code, message: problem.message)
      }
      throw APIClientError.invalidResponse
    }
    return (data, http, delegate)
  }

  private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value
  {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw APIClientError.invalidResponse
    }
  }
}
