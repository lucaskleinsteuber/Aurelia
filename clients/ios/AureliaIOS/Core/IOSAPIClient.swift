import Foundation

struct IOSAPIClient: Sendable {
  let connection: IOSStoredConnection?
  let session: IOSProfileSession?
  let baseURL: URL
  let fingerprint: String
  private let transport: any IOSHTTPTransport

  var viewingToken: String? { session?.token }

  init(
    connection: IOSStoredConnection, session: IOSProfileSession? = nil,
    transport: any IOSHTTPTransport = IOSURLSessionTransport()
  ) {
    self.connection = connection
    self.session = session
    baseURL = connection.baseURL
    fingerprint = connection.fingerprint
    self.transport = transport
  }

  init(inspected: IOSInspectedServer, transport: any IOSHTTPTransport = IOSURLSessionTransport()) {
    connection = nil
    session = nil
    baseURL = inspected.baseURL
    fingerprint = inspected.fingerprint
    self.transport = transport
  }

  static func inspect(baseURL: URL, transport: any IOSHTTPTransport = IOSURLSessionTransport())
    async throws -> IOSInspectedServer
  {
    guard IOSServerAddress.isValid(baseURL) else { throw IOSCoreError.invalidAddress }
    var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/server/info"))
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let response = try await transport.execute(request, trust: .inspect)
    try Task.checkCancellation()
    try requireSuccess(response)
    let info = try decode(IOSServerInfo.self, data: response.body)
    guard let captured = response.fingerprint, IOSServerIdentity.isValidFingerprint(captured),
      captured.caseInsensitiveCompare(info.publicKeyFingerprint ?? "") == .orderedSame
    else { throw IOSCoreError.identityMismatch }
    guard info.lanAccessEnabled else { throw IOSCoreError.lanAccessDisabled }
    return IOSInspectedServer(baseURL: baseURL, info: info, fingerprint: captured)
  }

  func serverInfo() async throws -> IOSServerInfo {
    let info: IOSServerInfo = try await get("/api/v1/server/info", authentication: .none)
    guard info.publicKeyFingerprint?.caseInsensitiveCompare(fingerprint) == .orderedSame,
      connection == nil || info.serverId == connection?.serverID
    else { throw IOSCoreError.identityMismatch }
    return info
  }

  func capabilities() async throws -> IOSCapabilities {
    let value: IOSCapabilities = try await get("/api/v1/capabilities", authentication: .none)
    try value.validate()
    return value
  }

  func startPairing(deviceName: String) async throws -> IOSPairingStart {
    // A long device name is shortened rather than refused; the server allows 128 characters.
    let name = String(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
    guard !name.isEmpty else { throw IOSCoreError.invalidRequest }
    struct Payload: Encodable { let deviceName: String }
    let value: IOSPairingStart = try await post(
      "/api/v1/auth/device-pairings",
      payload: Payload(deviceName: name), authentication: .none)
    try value.validate()
    return value
  }

  /// Redeems the 8-digit code that the main device (a Mac or Linux computer) created for this
  /// device. The server answers with this device's own credential.
  func redeemPairingCode(_ code: String, deviceName: String) async throws -> IOSAuthentication {
    let digits = code.filter(\.isNumber)
    let name = String(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
    guard digits.count == 8, !name.isEmpty else { throw IOSCoreError.invalidRequest }
    struct Payload: Encodable {
      let code: String
      let deviceName: String
    }
    let value: IOSAuthentication = try await post(
      "/api/v1/auth/pair", payload: Payload(code: digits, deviceName: name),
      authentication: .none)
    guard (32...256).contains(value.token.utf8.count),
      !value.token.contains(where: \.isWhitespace),
      let expiry = IOSServerDate.parse(value.expiresAt), expiry > Date()
    else { throw IOSCoreError.invalidResponse }
    return value
  }

  func pairingStatus(id: UUID, secret: String) async throws -> IOSPairingStatus {
    try await pairingOperation(id: id, secret: secret, operation: "status")
  }
  func acknowledgePairing(id: UUID, secret: String) async throws -> IOSPairingStatus {
    let value = try await pairingOperation(id: id, secret: secret, operation: "ack")
    guard value.state == .approved, value.acknowledged else { throw IOSCoreError.invalidResponse }
    return value
  }
  func cancelPairing(id: UUID, secret: String) async throws -> IOSPairingStatus {
    try await pairingOperation(id: id, secret: secret, operation: "cancel")
  }

  private func pairingOperation(id: UUID, secret: String, operation: String) async throws
    -> IOSPairingStatus
  {
    guard (32...256).contains(secret.utf8.count), !secret.contains(where: \.isWhitespace) else {
      throw IOSCoreError.invalidRequest
    }
    struct Payload: Encodable { let secret: String }
    let value: IOSPairingStatus = try await post(
      "/api/v1/auth/device-pairings/\(id.uuidString)/\(operation)",
      payload: Payload(secret: secret), authentication: .none)
    guard (5...300).contains(value.pollIntervalSeconds),
      IOSServerDate.parse(value.expiresAt) != nil,
      value.authentication == nil || value.state == .approved && !value.acknowledged
    else {
      throw IOSCoreError.invalidResponse
    }
    if let authentication = value.authentication {
      guard (32...256).contains(authentication.token.utf8.count),
        !authentication.token.contains(where: \.isWhitespace),
        let expiry = IOSServerDate.parse(authentication.expiresAt), expiry > Date()
      else { throw IOSCoreError.invalidResponse }
    }
    return value
  }

  func profiles() async throws -> IOSProfilePicker {
    let value: IOSProfilePicker = try await get("/api/v1/profiles", authentication: .device)
    try value.validate()
    return value
  }

  func unlockProfile(id: UUID, pin: String?) async throws -> IOSProfileSession {
    if let pin, !pin.isEmpty, !IOSProfilePIN.isValid(pin) {
      throw IOSCoreError.server(
        status: 401, code: "invalid_profile_pin", message: IOSProfilePIN.incorrect,
        retryAfter: nil)
    }
    struct Payload: Encodable { let pin: String? }
    let value: IOSProfileSession = try await post(
      "/api/v1/profiles/\(id.uuidString)/unlock",
      payload: Payload(pin: pin?.isEmpty == true ? nil : pin), authentication: .device)
    try value.validate(profileID: id)
    return value
  }

  /// A profile's photo (JPEG), read with the device credential so the picker can show it.
  func profilePhoto(id: UUID, revision: Int64) async throws -> Data {
    try await send(
      "/api/v1/profiles/\(id.uuidString)/picture",
      query: [URLQueryItem(name: "rev", value: String(revision))], authentication: .device)
  }
  /// Renames the signed-in profile. An owner keeps signing in with the original name.
  func renameProfile(_ name: String) async throws -> IOSUser {
    struct Payload: Encodable { let name: String }
    return try Self.decode(
      IOSUser.self,
      data: await send(
        "/api/v1/profile/name", method: "PUT", body: JSONEncoder().encode(Payload(name: name))))
  }
  /// A built-in picture (`symbol:palette`) for the signed-in profile, or nil for the initial.
  func setPicture(builtin: String?) async throws -> IOSUser {
    struct Payload: Encodable { let builtin: String? }
    return try Self.decode(
      IOSUser.self,
      data: await send(
        "/api/v1/profile/picture", method: "PUT",
        body: JSONEncoder().encode(Payload(builtin: builtin))))
  }
  /// An own photo for the signed-in profile; the server keeps a small square copy.
  func uploadPhoto(_ jpeg: Data) async throws -> IOSUser {
    guard !jpeg.isEmpty, jpeg.count <= IOSProfilePictures.maximumUploadBytes else {
      throw IOSCoreError.invalidResponse
    }
    var request = try request("/api/v1/profile/picture/photo", authentication: .profile)
    request.httpMethod = "PUT"
    request.httpBody = jpeg
    request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
    return try Self.decode(IOSUser.self, data: await execute(request).body)
  }
  func endProfile() async throws { _ = try await send("/api/v1/profile/end", method: "POST") }
  func disconnectDevice() async throws {
    _ = try await send("/api/v1/device", method: "DELETE", authentication: .device)
  }

  func catalogPage(kind: IOSMediaKind, offset: Int, limit: Int = 60, revision: String? = nil)
    async throws -> IOSPage<IOSCatalogItem>
  {
    guard [.movie, .series].contains(kind), offset >= 0, (1...200).contains(limit) else {
      throw IOSCoreError.invalidRequest
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
    let page = try Self.decode(IOSPage<IOSCatalogItem>.self, data: data)
    try IOSCatalogPageValidator.validate(page, kind: kind, offset: offset, revision: revision)
    return page
  }

  func browsePage(
    query: IOSBrowseQuery, search: String = "", offset: Int = 0,
    limit: Int = 60, revision: String? = nil
  ) async throws -> IOSPage<IOSCatalogItem> {
    guard offset >= 0, (1...200).contains(limit) else { throw IOSCoreError.invalidRequest }
    var values = try query.queryItems(search: search)
    values.append(URLQueryItem(name: "offset", value: String(offset)))
    values.append(URLQueryItem(name: "limit", value: String(limit)))
    if let revision { values.append(URLQueryItem(name: "revision", value: revision)) }
    let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let data = try await send(
      term.isEmpty ? "/api/v1/catalog/items" : "/api/v1/catalog/search", query: values)
    let page = try Self.decode(IOSPage<IOSCatalogItem>.self, data: data)
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
    else { throw IOSCoreError.invalidResponse }
    return page
  }

  func home() async throws -> IOSHome { try await get("/api/v1/home") }
  func history(offset: Int = 0, limit: Int = 50) async throws -> IOSWatchHistoryPage {
    try Self.decode(
      IOSWatchHistoryPage.self,
      data: await send(
        "/api/v1/history",
        query: [
          URLQueryItem(name: "offset", value: String(offset)),
          URLQueryItem(name: "limit", value: String(limit)),
        ]))
  }
  func deleteHistoryItem(id: UUID) async throws {
    _ = try await send("/api/v1/history/\(id.uuidString.lowercased())", method: "DELETE")
  }
  func clearHistory() async throws { _ = try await send("/api/v1/history", method: "DELETE") }
  func statistics() async throws -> IOSUserStatistics { try await get("/api/v1/statistics") }
  func yearInReview(year: Int) async throws -> IOSYearInReview {
    try await get("/api/v1/statistics/year/\(year)")
  }
  func wrapped(year: Int, month: Int? = nil) async throws -> IOSYearWrapped {
    if let month { return try await get("/api/v1/statistics/year/\(year)/month/\(month)/wrapped") }
    return try await get("/api/v1/statistics/year/\(year)/wrapped")
  }
  /// Sets a new PIN for the signed-in profile; the current one is needed when it has a PIN.
  func changeProfilePIN(current: String?, new: String) async throws {
    struct Payload: Encodable {
      let pinProtectionEnabled: Bool
      let currentPin: String?
      let pin: String?
    }
    _ = try await send(
      "/api/v1/profile/pin-protection", method: "PUT",
      body: JSONEncoder().encode(
        Payload(pinProtectionEnabled: true, currentPin: current, pin: new)))
  }
  /// Turns the PIN off; the server allows this only for profiles that are not Owner or Admin.
  func removeProfilePIN(current: String) async throws {
    struct Payload: Encodable {
      let pinProtectionEnabled: Bool
      let currentPin: String?
    }
    _ = try await send(
      "/api/v1/profile/pin-protection", method: "PUT",
      body: JSONEncoder().encode(Payload(pinProtectionEnabled: false, currentPin: current)))
  }
  func collections(offset: Int = 0, limit: Int = 60) async throws -> [IOSCollection] {
    guard offset >= 0, (1...200).contains(limit) else { throw IOSCoreError.invalidRequest }
    let data = try await send(
      "/api/v1/catalog/collections",
      query: [
        URLQueryItem(name: "offset", value: String(offset)),
        URLQueryItem(name: "limit", value: String(limit)),
      ])
    let values = try Self.decode([IOSCollection].self, data: data)
    guard values.count <= limit, Set(values.map(\.id)).count == values.count else {
      throw IOSCoreError.invalidResponse
    }
    return values
  }
  /// Shared collections and this profile's own ("collections-v2" / "collections-v3").
  func collectionDetail(id: UUID) async throws -> IOSCollectionDetail {
    try Self.decode(
      IOSCollectionDetail.self,
      data: await send("/api/v1/collections/\(id.uuidString.lowercased())"))
  }

  func collectionNext(id: UUID) async throws -> IOSCollectionNextResponse {
    try Self.decode(
      IOSCollectionNextResponse.self,
      data: await send("/api/v1/collections/\(id.uuidString.lowercased())/next"))
  }

  func franchises() async throws -> [IOSCollection] {
    try Self.decode([IOSCollection].self, data: await send("/api/v1/catalog/franchises"))
  }

  func saveFromFranchise(id: UUID) async throws -> IOSCollection {
    try Self.decode(
      IOSCollection.self,
      data: await send("/api/v1/collections/from-franchise/\(id.uuidString.lowercased())", method: "POST"))
  }

  func createCollection(_ payload: IOSSaveCollection) async throws -> IOSCollection {
    try Self.decode(
      IOSCollection.self,
      data: await send("/api/v1/collections", method: "POST", body: JSONEncoder().encode(payload)))
  }

  func updateCollection(id: UUID, _ payload: IOSSaveCollection) async throws -> IOSCollection {
    try Self.decode(
      IOSCollection.self,
      data: await send(
        "/api/v1/collections/\(id.uuidString.lowercased())", method: "PUT",
        body: JSONEncoder().encode(payload)))
  }

  func updateCollection(_ collection: IOSCollection, name: String, mediaIDs: [UUID]) async throws
    -> IOSCollection
  {
    try await updateCollection(
      id: collection.id,
      IOSSaveCollection(
        name: name, mediaIds: mediaIDs, isSmart: collection.isSmart,
        isShared: collection.isShared, rulesJson: collection.rulesJson,
        overview: collection.overview, sortMode: collection.sortMode))
  }

  func updateCollectionOrder(id: UUID, _ order: IOSCollectionOrderRequest) async throws
    -> IOSCollectionDetail
  {
    try Self.decode(
      IOSCollectionDetail.self,
      data: await send(
        "/api/v1/collections/\(id.uuidString.lowercased())/order", method: "PUT",
        body: JSONEncoder().encode(order)))
  }

  func deleteCollection(id: UUID) async throws {
    _ = try await send("/api/v1/collections/\(id.uuidString.lowercased())", method: "DELETE")
  }

  func setCollectionItem(
    collectionID: UUID, mediaID: UUID, seasonNumber: Int? = nil, included: Bool
  ) async throws {
    let query = seasonNumber.map { [URLQueryItem(name: "seasonNumber", value: String($0))] } ?? []
    _ = try await send(
      "/api/v1/collections/\(collectionID.uuidString.lowercased())/items/\(mediaID.uuidString.lowercased())",
      method: included ? "POST" : "DELETE", query: query)
  }

  func uploadCollectionEditorImage(
    collectionID: UUID, _ data: Data, contentType: String = "image/jpeg"
  ) async throws -> IOSUploadedEditorImage {
    guard !data.isEmpty, data.count <= IOSRectCrop.maximumArtworkUploadBytes else {
      throw IOSCoreError.invalidRequest
    }
    let response = try await send(
      "/api/v1/collections/\(collectionID.uuidString.lowercased())/editor/uploads",
      method: "POST", body: data, contentType: contentType)
    return try Self.decode(IOSUploadedEditorImage.self, data: response)
  }

  func discardCollectionEditorImage(collectionID: UUID, uploadID: UUID) async throws {
    _ = try await send(
      "/api/v1/collections/\(collectionID.uuidString.lowercased())/editor/uploads/\(uploadID.uuidString.lowercased())",
      method: "DELETE")
  }

  func saveCollectionArtwork(
    collectionID: UUID, kind: String, _ payload: IOSSaveCollectionArtwork
  ) async throws -> IOSArtwork {
    try Self.decode(
      IOSArtwork.self,
      data: await send(
        "/api/v1/collections/\(collectionID.uuidString.lowercased())/artwork/\(kind)",
        method: "POST", body: JSONEncoder().encode(payload)))
  }

  func deleteCollectionArtwork(collectionID: UUID, kind: String) async throws {
    _ = try await send(
      "/api/v1/collections/\(collectionID.uuidString.lowercased())/artwork/\(kind)",
      method: "DELETE")
  }

  func summary(id: UUID) async throws -> IOSCatalogItem {
    let item: IOSCatalogItem = try await get("/api/v1/catalog/items/\(id.uuidString)/summary")
    guard item.id == id else { throw IOSCoreError.invalidResponse }
    return item
  }
  func setFavorite(mediaID: UUID, isFavorite: Bool) async throws -> Bool {
    struct Payload: Encodable { let isFavorite: Bool }
    let data = try await send(
      "/api/v1/media/\(mediaID.uuidString)/favorite", method: "PUT",
      body: JSONEncoder().encode(Payload(isFavorite: isFavorite)))
    return try Self.decode(Bool.self, data: data)
  }
  /// This profile's scene notes for a title.
  func sceneNotes(mediaID: UUID) async throws -> [IOSSceneNote] {
    try Self.decode(
      [IOSSceneNote].self, data: await send("/api/v1/media/\(mediaID.uuidString)/notes"))
  }

  func saveSceneNote(mediaID: UUID, noteID: UUID, _ note: IOSSaveSceneNote) async throws
    -> IOSSceneNote
  {
    try Self.decode(
      IOSSceneNote.self,
      data: await send(
        "/api/v1/media/\(mediaID.uuidString)/notes/\(noteID.uuidString)", method: "PUT",
        body: JSONEncoder().encode(note)))
  }

  func deleteSceneNote(mediaID: UUID, noteID: UUID, revision: Int64) async throws {
    _ = try await send(
      "/api/v1/media/\(mediaID.uuidString)/notes/\(noteID.uuidString)", method: "DELETE",
      query: [URLQueryItem(name: "revision", value: String(revision))])
  }

  func watchlist() async throws -> IOSWatchlistResponse {
    let data = try await send("/api/v1/watchlist")
    return try Self.decode(IOSWatchlistResponse.self, data: data)
  }
  func setWatchlist(mediaID: UUID, isWatchlisted: Bool) async throws -> IOSWatchlistItemState {
    let data = try await send(
      "/api/v1/media/\(mediaID.uuidString)/watchlist", method: "PUT",
      body: JSONEncoder().encode(IOSSetWatchlistRequest(isWatchlisted: isWatchlisted)))
    return try Self.decode(IOSWatchlistItemState.self, data: data)
  }
  func personDetail(name: String, key: String? = nil) async throws -> IOSPersonDetailResponse {
    var query = [URLQueryItem(name: "name", value: name)]
    if let key, !key.isEmpty { query.append(URLQueryItem(name: "key", value: key)) }
    let data = try await send("/api/v1/catalog/person", query: query)
    return try Self.decode(IOSPersonDetailResponse.self, data: data)
  }
  func scrubPreviewFrame(mediaID: UUID, seconds: Int) async throws -> Data {
    try await send(
      "/api/v1/media/\(mediaID.uuidString.lowercased())/scrub-previews/\(max(0, seconds))",
      method: "GET")
  }
  func watchState(mediaID: UUID, scope: IOSWatchScope = .title, season: Int? = nil) async throws
    -> IOSWatchState
  {
    var query = [URLQueryItem(name: "scope", value: scope.rawValue)]
    if let season { query.append(URLQueryItem(name: "seasonNumber", value: String(season))) }
    let data = try await send("/api/v1/media/\(mediaID.uuidString)/watch-state", query: query)
    let state = try Self.decode(IOSWatchState.self, data: data)
    try state.validate(mediaID: mediaID, scope: scope, season: season)
    return state
  }
  func setWatchState(mediaID: UUID, request: IOSSetWatchState) async throws -> IOSWatchState {
    let data = try await send(
      "/api/v1/media/\(mediaID.uuidString)/watch-state", method: "PUT",
      body: JSONEncoder().encode(request))
    let state = try Self.decode(IOSWatchState.self, data: data)
    try state.validate(mediaID: mediaID, scope: request.scope, season: request.seasonNumber)
    return state
  }
  func setContinueWatchingHidden(mediaID: UUID, request: IOSSetContinueWatching) async throws
    -> IOSWatchState
  {
    let data = try await send(
      "/api/v1/media/\(mediaID.uuidString)/continue-watching", method: "PUT",
      body: JSONEncoder().encode(request))
    let state = try Self.decode(IOSWatchState.self, data: data)
    guard state.mediaId == mediaID, state.continueWatchingHidden == request.isHidden,
      !state.stateToken.isEmpty
    else { throw IOSCoreError.invalidResponse }
    return state
  }
  func syncChanges(after cursor: Int64, generation: String?) async throws -> IOSSyncChanges {
    var values = [
      URLQueryItem(name: "after", value: String(cursor)),
      URLQueryItem(name: "waitSeconds", value: "15"),
    ]
    if let generation { values.append(URLQueryItem(name: "generation", value: generation)) }
    let data = try await send("/api/v1/sync/changes", query: values)
    let response = try Self.decode(IOSSyncChanges.self, data: data)
    guard response.cursor >= 0 else { throw IOSCoreError.invalidResponse }
    return response
  }

  func detail(id: UUID) async throws -> IOSCatalogDetail {
    let value: IOSCatalogDetail = try await get("/api/v1/catalog/items/\(id.uuidString)")
    guard value.item.id == id, value.metadata.mediaId == id,
      Set(value.seasons.map(\.number)).count == value.seasons.count,
      value.seasons.allSatisfy({ season in
        season.episodes.allSatisfy { $0.item.kind == .episode && $0.seasonNumber == season.number }
      })
    else { throw IOSCoreError.invalidResponse }
    return value
  }

  func playbackPlan(mediaID: UUID) async throws -> IOSPlaybackPlan {
    let value: IOSPlaybackPlan = try await get("/api/v1/media/\(mediaID.uuidString)/playback-plan")
    try value.validate(requestedID: mediaID)
    return value
  }

  func createTicket(mediaID: UUID) async throws -> IOSPlaybackTicket {
    let data = try await send("/api/v1/media/\(mediaID.uuidString)/playback", method: "POST")
    let ticket = try Self.decode(IOSPlaybackTicket.self, data: data)
    try ticket.progress.validate(mediaID: mediaID)
    guard ticket.mediaId == mediaID, ticket.contentLength > 0,
      let expiry = IOSServerDate.parse(ticket.expiresAt), expiry > Date()
    else {
      throw IOSCoreError.invalidResponse
    }
    _ = try validatedStreamURL(path: ticket.streamPath)
    return ticket
  }
  /// Trailers of films nobody in this profile has watched yet, for cinema mode before `mediaID`.
  func cinemaTrailers(mediaID: UUID, count: Int) async throws -> [IOSCinemaTrailer] {
    let response: IOSCinemaTrailersResponse = try await get(
      "/api/v1/media/\(mediaID.uuidString.lowercased())/cinema-trailers?count=\(count)")
    return response.trailers
  }

  /// What to watch after a title (servers from 2.11.0); an episode's are its series'.
  func suggestions(mediaID: UUID, limit: Int = 3) async throws -> [IOSMediaSuggestion] {
    let response: IOSMediaSuggestionsResponse = try await get(
      "/api/v1/media/\(mediaID.uuidString.lowercased())/suggestions?limit=\(limit)")
    return response.suggestions
  }

  func revokeTicket(id: UUID) async throws {
    _ = try await send("/api/v1/playback/\(id.uuidString)", method: "DELETE")
  }
  func streamSubtitles(ticketID: UUID) async throws -> [IOSLiveSubtitleTrack] {
    let data = try await send("/api/v1/streams/\(ticketID.uuidString)/subtitles", method: "GET")
    return try Self.decode([IOSLiveSubtitleTrack].self, data: data)
  }
  /// A subtitle file next to the video, as WebVTT text, through the ticket's stream address.
  func streamSubtitleFile(streamPath: String, index: Int) async throws -> Data {
    _ = try validatedStreamURL(path: streamPath)
    return try await send("\(streamPath)/subtitles/\(max(0, index))", method: "GET")
  }
  /// A player's sleep timer ended: a server in sleep mode may sleep if nothing else plays.
  @discardableResult
  func sleepTimerEnded() async throws -> IOSSleepTimerEndedResponse? {
    let data = try await send("/api/v1/playback/sleep-timer-ended", method: "POST")
    guard !data.isEmpty else { return nil }
    return try? JSONDecoder().decode(IOSSleepTimerEndedResponse.self, from: data)
  }

  func wishes(state: IOSWishState? = nil, offset: Int = 0, limit: Int = IOSWishPresentation.pageSize)
    async throws -> IOSWishListResponse
  {
    var query = [
      URLQueryItem(name: "offset", value: String(max(0, offset))),
      URLQueryItem(name: "limit", value: String(max(1, min(100, limit)))),
    ]
    if let state {
      query.append(URLQueryItem(name: "state", value: state.rawValue))
    }
    return try Self.decode(
      IOSWishListResponse.self, data: await send("/api/v1/wishes", query: query))
  }

  func wishSummary() async throws -> IOSWishSummaryResponse {
    try await get("/api/v1/wishes/summary")
  }

  func wishSearch(query text: String, kind: IOSMediaKind? = nil) async throws -> IOSWishSearchResponse
  {
    var query = [URLQueryItem(name: "query", value: text)]
    if let kind {
      query.append(URLQueryItem(name: "kind", value: kind.rawValue))
    }
    return try Self.decode(
      IOSWishSearchResponse.self, data: await send("/api/v1/wishes/search", query: query))
  }

  func createWish(_ requestBody: IOSCreateWishRequest) async throws -> IOSCreateWishOutcome {
    var req = try request("/api/v1/wishes", authentication: .profile)
    req.httpMethod = "POST"
    req.httpBody = try JSONEncoder().encode(requestBody)
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    try Task.checkCancellation()
    let response = try await transport.execute(req, trust: .pinned(fingerprint))
    try Task.checkCancellation()
    if let actual = response.fingerprint,
      actual.caseInsensitiveCompare(fingerprint) != .orderedSame
    {
      throw IOSCoreError.identityMismatch
    }
    if response.statusCode == 409,
      let problem = try? JSONDecoder().decode(
        IOSWishAlreadyInLibraryProblem.self, from: response.body),
      problem.code == "already_in_library"
    {
      return .alreadyInLibrary(problem)
    }
    try Self.requireSuccess(response)
    return .created(try Self.decode(IOSCreateWishResponse.self, data: response.body))
  }

  func deleteWish(id: UUID) async throws {
    _ = try await send("/api/v1/wishes/\(id.uuidString.lowercased())", method: "DELETE")
  }

  func setWishSupport(id: UUID, supported: Bool) async throws -> IOSWishSummary {
    let body = try JSONEncoder().encode(IOSSetWishSupportRequest(supported: supported))
    let data = try await send(
      "/api/v1/wishes/\(id.uuidString.lowercased())/support", method: "POST", body: body)
    return try Self.decode(IOSWishSummary.self, data: data)
  }

  func updateWishState(id: UUID, requestBody: IOSUpdateWishStateRequest) async throws
    -> IOSWishSummary
  {
    let body = try JSONEncoder().encode(requestBody)
    let data = try await send(
      "/api/v1/wishes/\(id.uuidString.lowercased())/state", method: "POST", body: body)
    return try Self.decode(IOSWishSummary.self, data: data)
  }

  @discardableResult
  func markWishesSeen() async throws -> IOSWishSummaryResponse {
    let data = try await send("/api/v1/wishes/seen", method: "POST")
    return try Self.decode(IOSWishSummaryResponse.self, data: data)
  }

  func wishPosterData(path: String, width: Int = 342) async throws -> Data {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.hasPrefix("/") else {
      throw IOSCoreError.invalidRequest
    }
    let req = try request(
      "/api/v1/wishes/poster",
      query: [
        URLQueryItem(name: "path", value: trimmed),
        URLQueryItem(name: "width", value: String(width)),
      ],
      authentication: .profile)
    let response = try await execute(req)
    guard response.body.count <= 8 * 1024 * 1024,
      response.header("Content-Type")?.lowercased().hasPrefix("image/") == true
    else {
      throw IOSCoreError.invalidResponse
    }
    return response.body
  }

  /// The watching profile's screen time now; nil when it has none.
  func ownScreenTime() async throws -> IOSScreenTimeStatus? {
    let own: IOSOwnScreenTime = try await get("/api/v1/profile/screen-time")
    return own.status
  }

  func sendPlayerHeartbeat(
    deviceId: String, deviceName: String, clientType: String, isPlaying: Bool, mediaId: UUID? = nil,
    title: String? = nil, positionSeconds: Double? = nil, durationSeconds: Double? = nil,
    isPaused: Bool = false
  ) async throws {
    struct HeartbeatBody: Encodable {
      let deviceId: String
      let deviceName: String
      let clientType: String
      let isPlaying: Bool
      let mediaId: UUID?
      let title: String?
      let positionSeconds: Double?
      let durationSeconds: Double?
      let isPaused: Bool
    }
    let body = HeartbeatBody(
      deviceId: deviceId, deviceName: deviceName, clientType: clientType, isPlaying: isPlaying,
      mediaId: mediaId, title: title, positionSeconds: positionSeconds,
      durationSeconds: durationSeconds, isPaused: isPaused)
    _ = try await send(
      "/api/v1/devices/player/heartbeat", method: "POST", body: try JSONEncoder().encode(body))
  }

  func pollPlayerCommands(deviceId: String, waitMs: Int = 0) async throws
    -> [IOSRemotePlaybackCommand]
  {
    // The query goes in query items: a path with "?" is refused before any request is sent.
    try Self.decode(
      [IOSRemotePlaybackCommand].self,
      data: await send(
        "/api/v1/devices/player/commands",
        query: [
          URLQueryItem(name: "deviceId", value: deviceId),
          URLQueryItem(name: "waitMs", value: String(waitMs)),
        ]))
  }
  func progress(mediaID: UUID) async throws -> IOSPlaybackProgress {
    let value: IOSPlaybackProgress = try await get("/api/v1/media/\(mediaID.uuidString)/progress")
    try value.validate(mediaID: mediaID)
    return value
  }
  func saveProgress(
    mediaID: UUID, position: Int64, duration: Int64, finished: Bool,
    expectedRevision: Int64, mutationID: UUID
  ) async throws -> IOSPlaybackProgress {
    guard position >= 0, duration > 0, position <= duration, expectedRevision >= 0,
      mutationID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    else {
      throw IOSCoreError.invalidRequest
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
    let value = try Self.decode(IOSPlaybackProgress.self, data: data)
    try value.validate(mediaID: mediaID)
    guard value.revision > expectedRevision, value.lastMutationId == mutationID else {
      throw IOSCoreError.invalidResponse
    }
    return value
  }

  func validatedStreamURL(path: String) throws -> URL {
    guard path.hasPrefix("/api/v1/streams/"),
      let components = URLComponents(string: path), components.scheme == nil,
      components.host == nil, components.query == nil, components.fragment == nil,
      components.percentEncodedPath == components.path
    else { throw IOSCoreError.invalidResponse }
    let token = String(path.dropFirst("/api/v1/streams/".count))
    guard (32...256).contains(token.utf8.count),
      token.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
          || $0 == 95
      })
    else { throw IOSCoreError.invalidResponse }
    return try request(path, authentication: .profile).url!
  }

  static func isValidArtworkPath(_ path: String, id: UUID) -> (path: String, query: [URLQueryItem])? {
    guard path.hasPrefix("/api/v1/artwork/"),
      let components = URLComponents(string: path),
      components.scheme == nil, components.host == nil, components.fragment == nil,
      components.percentEncodedPath == components.path
    else { return nil }
    let trimmed = components.path
    if trimmed == "/api/v1/artwork/\(id.uuidString.lowercased())"
      || trimmed == "/api/v1/artwork/\(id.uuidString.uppercased())"
    {
      return (trimmed, components.queryItems ?? [])
    }
    let prefix = "/api/v1/artwork/collection/"
    if trimmed.hasPrefix(prefix) {
      let suffix = trimmed.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
      guard (1...2).contains(suffix.count), UUID(uuidString: String(suffix[0])) != nil else {
        return nil
      }
      if suffix.count == 2, suffix[1] != "poster", suffix[1] != "backdrop" { return nil }
      return (trimmed, components.queryItems ?? [])
    }
    return nil
  }

  func artworkRequest(artwork: IOSArtwork, width: Int) throws -> URLRequest {
    guard [320, 640, 1280, 1920].contains(width),
      let parsed = Self.isValidArtworkPath(artwork.path, id: artwork.id)
    else { throw IOSCoreError.invalidResponse }
    var query = parsed.query
    if artwork.revision != nil, !query.contains(where: { $0.name == "width" }) {
      query.append(URLQueryItem(name: "width", value: String(width)))
    }
    return try request(parsed.path, query: query, authentication: .profile)
  }
  func artworkData(artwork: IOSArtwork, width: Int) async throws -> Data {
    let request = try artworkRequest(artwork: artwork, width: width)
    let response = try await execute(request)
    guard response.body.count <= 24 * 1024 * 1024,
      response.header("Content-Type")?.lowercased().hasPrefix("image/") == true
    else {
      throw IOSCoreError.invalidResponse
    }
    return response.body
  }

  // Watch Together requests (see IOSWatchTogether.swift).
  func getWatchTogether<Value: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws
    -> Value
  {
    try Self.decode(Value.self, data: await send(path, query: query))
  }

  func postWatchTogether<Value: Decodable>(_ path: String, _ payload: some Encodable) async throws
    -> Value
  {
    try Self.decode(
      Value.self, data: await send(path, method: "POST", body: try JSONEncoder().encode(payload)))
  }

  func deleteWatchTogether(_ path: String) async throws {
    _ = try await send(path, method: "DELETE")
  }

  // Server administration (see IOSAdminAPI.swift). A protected change is refused with
  // `approval_required` before anything happens; the app then gets a one-time approval for exactly
  // this method, address and body and sends it once more. `longRunning` uses its own connection
  // with long timeouts, for backups and checks that take minutes.
  func adminData(
    _ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
    contentType: String = "application/json", longRunning: Bool = false
  ) async throws -> Data {
    let base = try request(path, query: query, authentication: .profile)
    guard let url = base.url else { throw IOSCoreError.invalidAddress }
    let transport: any IOSHTTPTransport =
      longRunning && self.transport is IOSURLSessionTransport
      ? IOSLongRunningTransport() : self.transport
    return try await IOSApprovalExecutor.execute { approval in
      var request = base
      request.httpMethod = method
      request.httpBody = body
      if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
      if let approval { request.setValue(approval, forHTTPHeaderField: "X-Aurelia-Approval") }
      return try await execute(request, using: transport).body
    } approve: {
      struct Confirmation: Encodable {
        let action: String
        let payloadHash: String
      }
      struct Approval: Decodable { let token: String }
      let confirmation = Confirmation(
        action: try IOSApprovalExecutor.action(method: method, url: url),
        payloadHash: IOSApprovalExecutor.payloadHash(body))
      let data = try await send(
        "/api/v1/management/approval", method: "POST", body: JSONEncoder().encode(confirmation))
      let token = try Self.decode(Approval.self, data: data).token
      guard (16...1024).contains(token.utf8.count), !token.contains(where: \.isWhitespace) else {
        throw IOSCoreError.invalidResponse
      }
      return token
    }
  }

  /// The profile's request for a file the server sends (a backup or a diagnostics report),
  /// for `IOSLongRunningTransport.download`.
  func adminFileRequest(_ path: String, method: String = "GET") throws -> URLRequest {
    var request = try request(path, authentication: .profile)
    request.httpMethod = method
    return request
  }

  static func decodeAdmin<Value: Decodable>(_ type: Value.Type, data: Data) throws -> Value {
    try decode(type, data: data)
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
    body: Data? = nil, contentType: String = "application/json",
    authentication: Authentication = .profile
  ) async throws -> Data {
    var request = try request(path, query: query, authentication: authentication)
    request.httpMethod = method
    request.httpBody = body
    if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    return try await execute(request).body
  }

  private func request(_ path: String, query: [URLQueryItem] = [], authentication: Authentication)
    throws -> URLRequest
  {
    guard IOSServerAddress.isValid(baseURL), IOSServerIdentity.isValidFingerprint(fingerprint),
      path.hasPrefix("/api/v1/"), !path.contains("?"), !path.contains("#"),
      !path.contains("%"), !path.contains(".."),
      var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    else { throw IOSCoreError.invalidAddress }
    components.path = path
    components.queryItems = query.isEmpty ? nil : query
    guard let url = components.url else { throw IOSCoreError.invalidAddress }
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(IOSInstallation.identifier(), forHTTPHeaderField: "X-Aurelia-Installation")
    request.setValue(IOSInstallation.clientHeader, forHTTPHeaderField: "X-Aurelia-Client")
    let token: String?
    switch authentication {
    case .none: token = nil
    case .device:
      guard let connection else { throw IOSCoreError.profileRequired }
      try connection.validate()
      token = connection.deviceToken
    case .profile:
      guard let session else { throw IOSCoreError.profileRequired }
      if let expiry = IOSServerDate.parse(session.expiresAt), expiry <= Date() {
        throw IOSCoreError.server(
          status: 401, code: "profile_session_expired",
          message: "Choose a profile to continue.", retryAfter: nil)
      }
      try session.validate(profileID: session.user.id)
      token = session.token
    }
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    return request
  }
  private func execute(_ request: URLRequest) async throws -> IOSHTTPResponse {
    try await execute(request, using: transport)
  }
  private func execute(_ request: URLRequest, using transport: any IOSHTTPTransport) async throws
    -> IOSHTTPResponse
  {
    try Task.checkCancellation()
    let response = try await transport.execute(request, trust: .pinned(fingerprint))
    try Task.checkCancellation()
    if let actual = response.fingerprint,
      actual.caseInsensitiveCompare(fingerprint) != .orderedSame
    {
      throw IOSCoreError.identityMismatch
    }
    try Self.requireSuccess(response)
    return response
  }
  private static func requireSuccess(_ response: IOSHTTPResponse) throws {
    guard (200..<300).contains(response.statusCode) else {
      struct Problem: Decodable {
        let code: String?
        let message: String?
      }
      let problem =
        response.body.count <= 16_384
        ? try? JSONDecoder().decode(Problem.self, from: response.body) : nil
      throw IOSCoreError.server(
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
      throw IOSCoreError.invalidResponse
    }
  }
}
