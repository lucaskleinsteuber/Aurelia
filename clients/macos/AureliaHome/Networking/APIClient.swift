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
      "Aurelia Home requires an HTTPS server address."
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

  private func allPages<Item: Decodable & Sendable>(path: String) async throws -> [Item] {
    var collected: [Item] = []
    while true {
      let page: PagedResponse<Item> = try await get(
        "\(path)?offset=\(collected.count)&limit=100")
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

  private func perform(path: String, method: String, body: Data? = nil) async throws -> Data {
    let (data, _, _) = try await Self.request(
      baseURL: profile.baseURL,
      path: path,
      method: method,
      token: profile.token,
      body: body,
      trustMode: .pinned(profile.publicKeyFingerprint))
    return data
  }

  private static func request(
    baseURL: URL,
    path: String,
    method: String,
    token: String?,
    body: Data?,
    trustMode: TLSTrustDelegate.Mode,
    additionalHeaders: [String: String] = [:]
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
    configuration.timeoutIntervalForRequest = 15
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
