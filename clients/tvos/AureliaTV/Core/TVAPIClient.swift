import Foundation

struct TVAPIClient: Sendable {
  let connection: TVStoredConnection?
  let session: TVProfileSession?
  let baseURL: URL
  let fingerprint: String
  private let transport: any TVHTTPTransport

  var viewingToken: String? { session?.token }

  init(
    connection: TVStoredConnection, session: TVProfileSession? = nil,
    transport: any TVHTTPTransport = TVURLSessionTransport()
  ) {
    self.connection = connection
    self.session = session
    baseURL = connection.baseURL
    fingerprint = connection.fingerprint
    self.transport = transport
  }

  init(inspected: TVInspectedServer, transport: any TVHTTPTransport = TVURLSessionTransport()) {
    connection = nil
    session = nil
    baseURL = inspected.baseURL
    fingerprint = inspected.fingerprint
    self.transport = transport
  }

  static func inspect(baseURL: URL, transport: any TVHTTPTransport = TVURLSessionTransport())
    async throws -> TVInspectedServer
  {
    guard TVServerAddress.isValid(baseURL) else { throw TVCoreError.invalidAddress }
    var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/server/info"))
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let response = try await transport.execute(request, trust: .inspect)
    try Task.checkCancellation()
    try requireSuccess(response)
    let info = try decode(TVServerInfo.self, data: response.body)
    guard let captured = response.fingerprint, TVServerIdentity.isValidFingerprint(captured),
      captured.caseInsensitiveCompare(info.publicKeyFingerprint ?? "") == .orderedSame,
      info.lanAccessEnabled
    else { throw TVCoreError.identityMismatch }
    return TVInspectedServer(baseURL: baseURL, info: info, fingerprint: captured)
  }

  func serverInfo() async throws -> TVServerInfo {
    let info: TVServerInfo = try await get("/api/v1/server/info", authentication: .none)
    guard info.publicKeyFingerprint?.caseInsensitiveCompare(fingerprint) == .orderedSame,
      connection == nil || info.serverId == connection?.serverID
    else { throw TVCoreError.identityMismatch }
    return info
  }

  func capabilities() async throws -> TVCapabilities {
    let value: TVCapabilities = try await get("/api/v1/capabilities", authentication: .none)
    try value.validate()
    return value
  }

  func startPairing(deviceName: String) async throws -> TVPairingStart {
    let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 128 else { throw TVCoreError.invalidResponse }
    struct Payload: Encodable { let deviceName: String }
    let value: TVPairingStart = try await post(
      "/api/v1/auth/device-pairings",
      payload: Payload(deviceName: name), authentication: .none)
    try value.validate()
    return value
  }

  func pairingStatus(id: UUID, secret: String) async throws -> TVPairingStatus {
    try await pairingOperation(id: id, secret: secret, operation: "status")
  }
  func acknowledgePairing(id: UUID, secret: String) async throws -> TVPairingStatus {
    let value = try await pairingOperation(id: id, secret: secret, operation: "ack")
    guard value.state == .approved, value.acknowledged else { throw TVCoreError.invalidResponse }
    return value
  }
  func cancelPairing(id: UUID, secret: String) async throws -> TVPairingStatus {
    try await pairingOperation(id: id, secret: secret, operation: "cancel")
  }

  private func pairingOperation(id: UUID, secret: String, operation: String) async throws
    -> TVPairingStatus
  {
    guard (32...256).contains(secret.utf8.count), !secret.contains(where: \.isWhitespace) else {
      throw TVCoreError.invalidResponse
    }
    struct Payload: Encodable { let secret: String }
    let value: TVPairingStatus = try await post(
      "/api/v1/auth/device-pairings/\(id.uuidString)/\(operation)",
      payload: Payload(secret: secret), authentication: .none)
    guard (5...300).contains(value.pollIntervalSeconds), TVServerDate.parse(value.expiresAt) != nil,
      value.authentication == nil || value.state == .approved && !value.acknowledged
    else {
      throw TVCoreError.invalidResponse
    }
    if let authentication = value.authentication {
      guard (32...256).contains(authentication.token.utf8.count),
        !authentication.token.contains(where: \.isWhitespace),
        let expiry = TVServerDate.parse(authentication.expiresAt), expiry > Date()
      else { throw TVCoreError.invalidResponse }
    }
    return value
  }

  func profiles() async throws -> TVProfilePicker {
    let value: TVProfilePicker = try await get("/api/v1/profiles", authentication: .device)
    try value.validate()
    return value
  }

  func unlockProfile(id: UUID, pin: String?) async throws -> TVProfileSession {
    if let pin, !pin.isEmpty, !TVProfilePIN.isValid(pin) {
      throw TVCoreError.server(
        status: 400, code: "invalid_profile_pin",
        message: "Enter a PIN with four to eight digits.", retryAfter: nil)
    }
    struct Payload: Encodable { let pin: String? }
    let value: TVProfileSession = try await post(
      "/api/v1/profiles/\(id.uuidString)/unlock",
      payload: Payload(pin: pin?.isEmpty == true ? nil : pin), authentication: .device)
    try value.validate(profileID: id)
    return value
  }

  func endProfile() async throws { _ = try await send("/api/v1/profile/end", method: "POST") }
  func disconnectDevice() async throws {
    _ = try await send("/api/v1/device", method: "DELETE", authentication: .device)
  }

  func catalogPage(kind: TVMediaKind, offset: Int, limit: Int = 60, revision: String? = nil)
    async throws -> TVPage<TVCatalogItem>
  {
    guard [.movie, .series].contains(kind), offset >= 0, (1...200).contains(limit) else {
      throw TVCoreError.invalidResponse
    }
    var query = [
      URLQueryItem(name: "kind", value: kind.rawValue),
      URLQueryItem(name: "sort", value: "title"),
      URLQueryItem(name: "direction", value: "ascending"),
      URLQueryItem(name: "offset", value: String(offset)),
      URLQueryItem(name: "limit", value: String(limit)),
    ]
    if let revision { query.append(URLQueryItem(name: "revision", value: revision)) }
    let data = try await send("/api/v1/catalog/items", query: query)
    let page = try Self.decode(TVPage<TVCatalogItem>.self, data: data)
    try TVCatalogPageValidator.validate(page, kind: kind, offset: offset, revision: revision)
    return page
  }

  func browsePage(
    query: TVBrowseQuery, search: String = "", offset: Int = 0,
    limit: Int = 60, revision: String? = nil
  ) async throws -> TVPage<TVCatalogItem> {
    guard offset >= 0, (1...200).contains(limit) else { throw TVCoreError.invalidResponse }
    var values = try query.queryItems(search: search)
    values.append(URLQueryItem(name: "offset", value: String(offset)))
    values.append(URLQueryItem(name: "limit", value: String(limit)))
    if let revision { values.append(URLQueryItem(name: "revision", value: revision)) }
    let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let data = try await send(
      term.isEmpty ? "/api/v1/catalog/items" : "/api/v1/catalog/search", query: values)
    let page = try Self.decode(TVPage<TVCatalogItem>.self, data: data)
    guard page.offset == offset, page.limit == limit, page.total >= offset,
      page.items.count <= min(limit, page.total - offset),
      !page.items.isEmpty || page.total == offset,
      Set(page.items.map(\.id)).count == page.items.count,
      page.items.allSatisfy({
        query.kind == nil
          ? (term.isEmpty ? [.movie, .series] : [.movie, .series, .episode]).contains($0.kind)
          : $0.kind == query.kind
      }),
      revision == nil || revision == page.revision
    else { throw TVCoreError.invalidResponse }
    return page
  }

  func home() async throws -> TVHome { try await get("/api/v1/home") }
  func collections(offset: Int = 0, limit: Int = 60) async throws -> [TVCollection] {
    guard offset >= 0, (1...200).contains(limit) else { throw TVCoreError.invalidResponse }
    let data = try await send(
      "/api/v1/catalog/collections",
      query: [
        URLQueryItem(name: "offset", value: String(offset)),
        URLQueryItem(name: "limit", value: String(limit)),
      ])
    let values = try Self.decode([TVCollection].self, data: data)
    guard values.count <= limit, Set(values.map(\.id)).count == values.count else {
      throw TVCoreError.invalidResponse
    }
    return values
  }
  func summary(id: UUID) async throws -> TVCatalogItem {
    let item: TVCatalogItem = try await get("/api/v1/catalog/items/\(id.uuidString)/summary")
    guard item.id == id else { throw TVCoreError.invalidResponse }
    return item
  }
  func setFavorite(mediaID: UUID, isFavorite: Bool) async throws -> Bool {
    struct Payload: Encodable { let isFavorite: Bool }
    let data = try await send(
      "/api/v1/media/\(mediaID.uuidString)/favorite", method: "PUT",
      body: JSONEncoder().encode(Payload(isFavorite: isFavorite)))
    return try Self.decode(Bool.self, data: data)
  }
  func watchState(mediaID: UUID, scope: TVWatchScope = .title, season: Int? = nil) async throws
    -> TVWatchState
  {
    var query = [URLQueryItem(name: "scope", value: scope.rawValue)]
    if let season { query.append(URLQueryItem(name: "seasonNumber", value: String(season))) }
    let data = try await send("/api/v1/media/\(mediaID.uuidString)/watch-state", query: query)
    let state = try Self.decode(TVWatchState.self, data: data)
    try state.validate(mediaID: mediaID, scope: scope, season: season)
    return state
  }
  func setWatchState(mediaID: UUID, request: TVSetWatchState) async throws -> TVWatchState {
    let data = try await send(
      "/api/v1/media/\(mediaID.uuidString)/watch-state", method: "PUT",
      body: JSONEncoder().encode(request))
    let state = try Self.decode(TVWatchState.self, data: data)
    try state.validate(mediaID: mediaID, scope: request.scope, season: request.seasonNumber)
    return state
  }
  func setContinueWatchingHidden(mediaID: UUID, request: TVSetContinueWatching) async throws
    -> TVWatchState
  {
    let data = try await send(
      "/api/v1/media/\(mediaID.uuidString)/continue-watching", method: "PUT",
      body: JSONEncoder().encode(request))
    let state = try Self.decode(TVWatchState.self, data: data)
    guard state.mediaId == mediaID, state.continueWatchingHidden == request.isHidden,
      !state.stateToken.isEmpty
    else { throw TVCoreError.invalidResponse }
    return state
  }
  func syncChanges(after cursor: Int64, generation: String?) async throws -> TVSyncChanges {
    var values = [
      URLQueryItem(name: "after", value: String(cursor)),
      URLQueryItem(name: "waitSeconds", value: "15"),
    ]
    if let generation { values.append(URLQueryItem(name: "generation", value: generation)) }
    let data = try await send("/api/v1/sync/changes", query: values)
    let response = try Self.decode(TVSyncChanges.self, data: data)
    guard response.cursor >= 0 else { throw TVCoreError.invalidResponse }
    return response
  }

  func detail(id: UUID) async throws -> TVCatalogDetail {
    let value: TVCatalogDetail = try await get("/api/v1/catalog/items/\(id.uuidString)")
    guard value.item.id == id, value.metadata.mediaId == id,
      Set(value.seasons.map(\.number)).count == value.seasons.count,
      value.seasons.allSatisfy({ season in
        season.episodes.allSatisfy { $0.item.kind == .episode && $0.seasonNumber == season.number }
      })
    else { throw TVCoreError.invalidResponse }
    return value
  }

  func playbackPlan(mediaID: UUID) async throws -> TVPlaybackPlan {
    let value: TVPlaybackPlan = try await get("/api/v1/media/\(mediaID.uuidString)/playback-plan")
    try value.validate(requestedID: mediaID)
    return value
  }

  func createTicket(mediaID: UUID) async throws -> TVPlaybackTicket {
    let data = try await send("/api/v1/media/\(mediaID.uuidString)/playback", method: "POST")
    let ticket = try Self.decode(TVPlaybackTicket.self, data: data)
    try ticket.progress.validate(mediaID: mediaID)
    guard ticket.mediaId == mediaID, ticket.contentLength > 0,
      let expiry = TVServerDate.parse(ticket.expiresAt), expiry > Date()
    else {
      throw TVCoreError.invalidResponse
    }
    _ = try validatedStreamURL(path: ticket.streamPath)
    return ticket
  }
  func revokeTicket(id: UUID) async throws {
    _ = try await send("/api/v1/playback/\(id.uuidString)", method: "DELETE")
  }
  /// A player's sleep timer ended: a server in sleep mode may sleep if nothing else plays.
  func sleepTimerEnded() async throws {
    _ = try await send("/api/v1/playback/sleep-timer-ended", method: "POST")
  }
  func progress(mediaID: UUID) async throws -> TVPlaybackProgress {
    let value: TVPlaybackProgress = try await get("/api/v1/media/\(mediaID.uuidString)/progress")
    try value.validate(mediaID: mediaID)
    return value
  }
  func saveProgress(
    mediaID: UUID, position: Int64, duration: Int64, finished: Bool,
    expectedRevision: Int64, mutationID: UUID
  ) async throws -> TVPlaybackProgress {
    guard position >= 0, duration > 0, position <= duration, expectedRevision >= 0,
      mutationID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    else {
      throw TVCoreError.invalidResponse
    }
    struct Payload: Encodable {
      let positionMilliseconds: Int64
      let durationMilliseconds: Int64
      let isFinished: Bool
      let clientMutationId: UUID
      let enforceRevision = true
      let expectedRevision: Int64
    }
    let body = try JSONEncoder().encode(
      Payload(
        positionMilliseconds: position,
        durationMilliseconds: duration, isFinished: finished, clientMutationId: mutationID,
        expectedRevision: expectedRevision))
    let data = try await send(
      "/api/v1/media/\(mediaID.uuidString)/progress", method: "PUT", body: body)
    let value = try Self.decode(TVPlaybackProgress.self, data: data)
    try value.validate(mediaID: mediaID)
    guard value.revision > expectedRevision, value.lastMutationId == mutationID else {
      throw TVCoreError.invalidResponse
    }
    return value
  }

  func validatedStreamURL(path: String) throws -> URL {
    guard path.hasPrefix("/api/v1/streams/"),
      let components = URLComponents(string: path), components.scheme == nil,
      components.host == nil, components.query == nil, components.fragment == nil,
      components.percentEncodedPath == components.path
    else { throw TVCoreError.invalidResponse }
    let token = String(path.dropFirst("/api/v1/streams/".count))
    guard (32...256).contains(token.utf8.count),
      token.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
          || $0 == 95
      })
    else { throw TVCoreError.invalidResponse }
    return try request(path, authentication: .profile).url!
  }

  func artworkRequest(artwork: TVArtwork, width: Int) throws -> URLRequest {
    guard [320, 640, 1280, 1920].contains(width),
      artwork.path == "/api/v1/artwork/\(artwork.id.uuidString.lowercased())"
        || artwork.path == "/api/v1/artwork/\(artwork.id.uuidString.uppercased())"
    else { throw TVCoreError.invalidResponse }
    return try request(
      artwork.path,
      query: artwork.revision == nil
        ? []
        : [
          URLQueryItem(name: "width", value: String(width))
        ], authentication: .profile)
  }
  func artworkData(artwork: TVArtwork, width: Int) async throws -> Data {
    let request = try artworkRequest(artwork: artwork, width: width)
    let response = try await execute(request)
    guard response.body.count <= 24 * 1024 * 1024,
      response.header("Content-Type")?.lowercased().hasPrefix("image/") == true
    else {
      throw TVCoreError.invalidResponse
    }
    return response.body
  }

  private enum Authentication { case none, device, profile }

  private func get<Value: Decodable>(_ path: String, authentication: Authentication = .profile)
    async throws -> Value
  {
    try Self.decode(Value.self, data: await send(path, authentication: authentication))
  }
  private func post<Value: Decodable>(
    _ path: String, payload: some Encodable,
    authentication: Authentication
  ) async throws -> Value {
    let body = try JSONEncoder().encode(payload)
    return try Self.decode(
      Value.self,
      data: await send(path, method: "POST", body: body, authentication: authentication))
  }
  private func send(
    _ path: String, method: String = "GET", query: [URLQueryItem] = [],
    body: Data? = nil, authentication: Authentication = .profile
  ) async throws -> Data {
    var request = try request(path, query: query, authentication: authentication)
    request.httpMethod = method
    request.httpBody = body
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    return try await execute(request).body
  }

  private func request(_ path: String, query: [URLQueryItem] = [], authentication: Authentication)
    throws -> URLRequest
  {
    guard TVServerAddress.isValid(baseURL), TVServerIdentity.isValidFingerprint(fingerprint),
      path.hasPrefix("/api/v1/"), !path.contains("?"), !path.contains("#"),
      !path.contains("%"), !path.contains(".."),
      var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    else { throw TVCoreError.invalidAddress }
    components.path = path
    components.queryItems = query.isEmpty ? nil : query
    guard let url = components.url else { throw TVCoreError.invalidAddress }
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let token: String?
    switch authentication {
    case .none: token = nil
    case .device:
      guard let connection else { throw TVCoreError.profileRequired }
      try connection.validate()
      token = connection.deviceToken
    case .profile:
      guard let session else { throw TVCoreError.profileRequired }
      if let expiry = TVServerDate.parse(session.expiresAt), expiry <= Date() {
        throw TVCoreError.server(
          status: 401, code: "profile_session_expired",
          message: "Choose a profile to continue.", retryAfter: nil)
      }
      try session.validate(profileID: session.user.id)
      token = session.token
    }
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    return request
  }
  private func execute(_ request: URLRequest) async throws -> TVHTTPResponse {
    try Task.checkCancellation()
    let response = try await transport.execute(request, trust: .pinned(fingerprint))
    try Task.checkCancellation()
    if let actual = response.fingerprint,
      actual.caseInsensitiveCompare(fingerprint) != .orderedSame
    {
      throw TVCoreError.identityMismatch
    }
    try Self.requireSuccess(response)
    return response
  }
  private static func requireSuccess(_ response: TVHTTPResponse) throws {
    guard (200..<300).contains(response.statusCode) else {
      struct Problem: Decodable {
        let code: String?
        let message: String?
      }
      let problem =
        response.body.count <= 16_384
        ? try? JSONDecoder().decode(Problem.self, from: response.body) : nil
      throw TVCoreError.server(
        status: response.statusCode, code: problem?.code,
        message: problem?.message, retryAfter: retryDelay(response.header("Retry-After")))
    }
  }
  static func retryDelay(_ value: String?, now: Date = Date()) -> TimeInterval? {
    guard let value else { return nil }
    if let seconds = TimeInterval(value), seconds.isFinite { return min(max(seconds, 0), 300) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value).map { min(max($0.timeIntervalSince(now), 0), 300) }
  }
  private static func decode<Value: Decodable>(_ type: Value.Type, data: Data) throws -> Value {
    do { return try JSONDecoder().decode(type, from: data) } catch {
      throw TVCoreError.invalidResponse
    }
  }
}
