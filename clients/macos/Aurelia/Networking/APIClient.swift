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
      info.lanAccessEnabled
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
    combineExisting: Bool = false
  ) async throws
    -> LibrarySummary
  {
    let body = try JSONEncoder().encode(
      CreateLibraryRequest(
        name: name,
        path: path,
        kind: kind,
        combineExisting: combineExisting))
    let data = try await perform(path: "/api/v1/libraries", method: "POST", body: body)
    return try Self.decode(LibrarySummary.self, from: data)
  }

  func libraryDiscoveries(id: UUID) async throws -> [LibraryDiscoverySummary] {
    try await get("/api/v1/libraries/\(id.uuidString.lowercased())/discoveries")
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

  func startMetadataJob() async throws -> MetadataJobSummary {
    let data = try await perform(path: "/api/v1/metadata/jobs", method: "POST")
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
      "/api/v1/catalog/search?\(encodedQuery)&kind=movie&libraryId=\(libraryId.uuidString.lowercased())&offset=0&limit=25")
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
    method: String,
    body: Data? = nil,
    timeout: TimeInterval = 15
  ) async throws -> Data {
    let (data, _, _) = try await Self.request(
      baseURL: profile.baseURL,
      path: path,
      method: method,
      token: profile.token,
      body: body,
      trustMode: .pinned(profile.publicKeyFingerprint),
      timeout: timeout)
    return data
  }

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
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
