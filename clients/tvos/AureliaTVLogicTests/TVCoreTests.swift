import Foundation
import Testing

@Suite("TV client contracts and transport")
struct TVCoreTests {
  @Test func pinnedSessionsAreReusedPerIdentityAndBounded() {
    let pool = TVPinnedSessionPool()
    let first = pool.lease(host: "tv.local", fingerprint: "aa")
    #expect(pool.lease(host: "tv.local", fingerprint: "AA").session === first.session)
    #expect(pool.lease(host: "tv.local", fingerprint: "bb").session !== first.session)
    for index in 0..<8 { _ = pool.lease(host: "host\(index).local", fingerprint: "cc") }
    #expect(pool.count == TVPinnedSessionPool.capacity)
    pool.discard(host: "host7.local", fingerprint: "cc")
    #expect(pool.count == TVPinnedSessionPool.capacity - 1)
    #expect(pool.lease(host: "tv.local", fingerprint: "aa").session !== first.session)
  }

  @Test func onlyASilentServerCountsAsAsleep() {
    #expect(TVServerReachability.isUnreachable(URLError(.cannotConnectToHost)))
    #expect(TVServerReachability.isUnreachable(URLError(.timedOut)))
    // A server that answers with an error, or another failure, is not asleep.
    #expect(
      !TVServerReachability.isUnreachable(
        TVCoreError.server(status: 503, code: nil, message: nil, retryAfter: nil)))
    #expect(!TVServerReachability.isUnreachable(TVCoreError.identityMismatch))
    #expect(!TVServerReachability.isUnreachable(URLError(.cancelled)))
  }

  private static let fingerprint = String(repeating: "A", count: 64)
  private static let serverID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
  private static let profileID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
  private static let mediaID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
  private static let mutationID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
  private static let baseURL = URL(string: "https://synthetic-server.local:43111")!
  private static var connection: TVStoredConnection {
    TVStoredConnection(
      serverID: serverID, name: "Synthetic server", baseURL: baseURL,
      fingerprint: fingerprint, deviceToken: String(repeating: "D", count: 43),
      deviceSessionID: UUID())
  }
  private static var session: TVProfileSession {
    TVProfileSession(
      user: TVUser(id: profileID, username: "Viewer", role: "user"),
      sessionId: UUID(), token: String(repeating: "P", count: 43), expiresAt: "2099-01-01T00:00:00Z"
    )
  }

  @Test func addressDefaultsToHTTPSAndAcceptsIPv6() throws {
    #expect(
      try TVServerAddress.normalize("media-mac.local").absoluteString
        == "https://media-mac.local:43111")
    #expect(try TVServerAddress.normalize(" https://media-mac.local:54321/ ").port == 54321)
    #expect(try TVServerAddress.normalize("https://[fe80::1%25en0]:54321").port == 54321)
    #expect(
      TVServerAddress.trustHost("[fe80::1%25en0]") == TVServerAddress.trustHost("fe80::1%en0"))
  }

  @Test(arguments: [
    "http://example.local", "https://user:password@example.local", "https://example.local/path",
    "https://example.local?token=value", "https://example.local#fragment",
    "https://example.local:0",
  ])
  func invalidAddressesAreRejected(_ value: String) {
    #expect(throws: TVCoreError.invalidAddress) { try TVServerAddress.normalize(value) }
  }

  @Test func fingerprintUsesSubjectPublicKeyInfoRatherThanRawKey() throws {
    #expect(
      try TVServerIdentity.fingerprint(rawP256Key: Data([4] + Array(0...63)))
        == "0131DDA9654FEF86D57812B9960F260523C27A40C3A18FA8ECC7303510E78C22")
    #expect(throws: TVCoreError.identityMismatch) {
      try TVServerIdentity.fingerprint(rawP256Key: Data(repeating: 0, count: 65))
    }
  }

  @Test func capabilitiesUseProtocolNotIndependentTVMarketingVersion() throws {
    let capabilities = try decode(
      TVCapabilities.self,
      """
      {"formatVersion":2,"minimumClientVersion":"1.5.1",
       "capabilities":["device-authorization-v1","library-state-v1","artwork-variants-v1"],"future":true}
      """)
    try capabilities.validate()
    #expect(capabilities.supportsArtworkVariants)
    let older = TVCapabilities(formatVersion: 2, minimumClientVersion: "1.0", capabilities: [])
    #expect(throws: TVCoreError.unsupportedServer) { try older.validate() }
    let future = TVCapabilities(
      formatVersion: 99, minimumClientVersion: "1.5.1", capabilities: capabilities.capabilities)
    #expect(throws: TVCoreError.unsupportedServer) { try future.validate() }
  }

  @Test func inspectDoesNotSendCredentialsAndChecksCapturedIdentity() async throws {
    let transport = TVCoreFakeTransport(responses: [response(infoJSON)])
    let inspected = try await TVAPIClient.inspect(baseURL: Self.baseURL, transport: transport)
    #expect(inspected.info.serverId == Self.serverID)
    let request = try #require(await transport.requests.first)
    #expect(request.request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.trust == .inspect)
    let wrong = TVCoreFakeTransport(responses: [
      response(infoJSON, fingerprint: String(repeating: "B", count: 64))
    ])
    await #expect(throws: TVCoreError.identityMismatch) {
      try await TVAPIClient.inspect(baseURL: Self.baseURL, transport: wrong)
    }
  }

  @Test func relocationRequiresBothStableIDAndSavedPublicKey() throws {
    let info = try decode(TVServerInfo.self, infoJSON)
    let inspected = TVInspectedServer(
      baseURL: URL(string: "https://192.0.2.20:43111")!,
      info: info, fingerprint: Self.fingerprint.lowercased())
    try inspected.validate(against: Self.connection)
    var other = Self.connection
    other = TVStoredConnection(
      serverID: UUID(), name: other.name, baseURL: other.baseURL,
      fingerprint: other.fingerprint, deviceToken: other.deviceToken,
      deviceSessionID: other.deviceSessionID)
    #expect(throws: TVCoreError.identityMismatch) { try inspected.validate(against: other) }
    let wrongKey = TVInspectedServer(
      baseURL: inspected.baseURL, info: info,
      fingerprint: String(repeating: "B", count: 64))
    #expect(throws: TVCoreError.identityMismatch) {
      try wrongKey.validate(against: Self.connection)
    }
  }

  @Test func profileAndCatalogUseDifferentCredentials() async throws {
    let transport = TVCoreFakeTransport(responses: [response(pickerJSON), response(emptyPageJSON)])
    let client = TVAPIClient(
      connection: Self.connection, session: Self.session, transport: transport)
    _ = try await client.profiles()
    _ = try await client.catalogPage(kind: .movie, offset: 0)
    let requests = await transport.requests
    #expect(
      requests[0].request.value(forHTTPHeaderField: "Authorization")
        == "Bearer \(Self.connection.deviceToken)")
    #expect(
      requests[1].request.value(forHTTPHeaderField: "Authorization")
        == "Bearer \(Self.session.token)")
    #expect(requests.allSatisfy { $0.trust == .pinned(Self.fingerprint) })
    let deviceOnly = TVAPIClient(connection: Self.connection, transport: transport)
    await #expect(throws: TVCoreError.profileRequired) {
      try await deviceOnly.catalogPage(kind: .movie, offset: 0)
    }
  }

  @Test func noPINProfilesAndMissingOptionalFieldsRemainCompatible() throws {
    let picker = try decode(TVProfilePicker.self, pickerJSON)
    try picker.validate()
    #expect(picker.profiles.first?.pinProtectionEnabled == true)
    #expect(TVProfilePIN.isValid("1234"))
    #expect(TVProfilePIN.isValid("12345678"))
    #expect(!TVProfilePIN.isValid("123"))
    #expect(!TVProfilePIN.isValid("１２３４"))
    #expect(!TVProfilePIN.isValid("12 34"))
  }

  @Test func unlockValidatesResponseBelongsToSelectedProfile() async throws {
    let profile = Self.session
    let transport = TVCoreFakeTransport(responses: [try encodedResponse(profile)])
    let client = TVAPIClient(connection: Self.connection, transport: transport)
    await #expect(throws: TVCoreError.invalidResponse) {
      try await client.unlockProfile(id: UUID(), pin: "1234")
    }
    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(requests[0].request.httpMethod == "POST")
  }

  @Test func malformedPINDoesNotReachServer() async throws {
    let transport = TVCoreFakeTransport(responses: [])
    let client = TVAPIClient(connection: Self.connection, transport: transport)
    do {
      _ = try await client.unlockProfile(id: Self.profileID, pin: "abcd")
      Issue.record("Invalid PIN must fail locally")
    } catch let error as TVCoreError { #expect(error.code == "invalid_profile_pin") }
    #expect(await transport.requests.isEmpty)
  }

  @Test func expiredProfileIsReportedWithoutSendingItsToken() async throws {
    let transport = TVCoreFakeTransport(responses: [])
    let current = Self.session
    let expired = TVProfileSession(
      user: current.user, sessionId: current.sessionId,
      token: current.token, expiresAt: "2000-01-01T00:00:00Z")
    let client = TVAPIClient(connection: Self.connection, session: expired, transport: transport)
    do {
      _ = try await client.catalogPage(kind: .movie, offset: 0)
      Issue.record("Expired profiles must return to selection")
    } catch let error as TVCoreError {
      #expect(error.isAuthenticationFailure)
      #expect(error.code == "profile_session_expired")
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test func pairingSecretsStayInBodiesAndStatusIsFutureSafe() async throws {
    let transport = TVCoreFakeTransport(responses: [
      response(
        """
        {"state":"futureState","expiresAt":"2099-01-01T00:00:00Z","pollIntervalSeconds":5,"acknowledged":false}
        """)
    ])
    let info = try decode(TVServerInfo.self, infoJSON)
    let client = TVAPIClient(
      inspected: TVInspectedServer(
        baseURL: Self.baseURL, info: info,
        fingerprint: Self.fingerprint), transport: transport)
    let secret = String(repeating: "S", count: 43)
    let status = try await client.pairingStatus(id: UUID(), secret: secret)
    #expect(status.state == .unknown)
    let request = try #require(await transport.requests.first?.request)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.query == nil)
    #expect(request.url?.absoluteString.contains(secret) == false)
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let payload =
      try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: String]
    #expect(payload?["secret"] == secret)
  }

  @Test func receiptRoundTripPreservesCredentialBeforeAcknowledgement() throws {
    var connection = Self.connection
    connection.pendingAcknowledgement = TVPendingPairingAcknowledgement(
      id: UUID(),
      secret: String(repeating: "S", count: 43), expiresAt: "2099-01-01T00:00:00Z")
    let encoded = try JSONEncoder().encode(connection)
    let reloaded = try JSONDecoder().decode(TVStoredConnection.self, from: encoded)
    #expect(reloaded == connection)
    #expect(
      reloaded.relocating(to: Self.baseURL).pendingAcknowledgement
        == connection.pendingAcknowledgement)
    let oldJSON =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.connection))
      as? [String: Any]
    #expect(oldJSON?["pendingAcknowledgement"] == nil)
  }

  @Test func throttlingKeepsServerCodeAndRetryDelay() async throws {
    let transport = TVCoreFakeTransport(responses: [
      TVHTTPResponse(
        statusCode: 429,
        headers: ["retry-after": "5"],
        body: Data(
          "{\"code\":\"device_pairing_slow_down\",\"message\":\"Wait before checking again.\"}".utf8
        ),
        fingerprint: Self.fingerprint)
    ])
    let client = TVAPIClient(connection: Self.connection, transport: transport)
    do {
      _ = try await client.pairingStatus(id: UUID(), secret: String(repeating: "S", count: 43))
      Issue.record("Rate limit must be reported")
    } catch let error as TVCoreError {
      #expect(error.statusCode == 429)
      #expect(error.code == "device_pairing_slow_down")
      #expect(error.retryDelay == 5)
    }
  }

  @Test func cancellationRejectsEvenAnUncooperativeLateResponse() async throws {
    let transport = TVCoreFakeTransport(responses: [response(pickerJSON)], delay: .milliseconds(30))
    let task = Task {
      try await TVAPIClient(connection: Self.connection, transport: transport).profiles()
    }
    await transport.waitForFirstRequest()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func paginationRejectsDuplicateIDsAndMixedRevisions() throws {
    let item = try decode(TVCatalogItem.self, itemJSON)
    let page = TVPage(items: [item], offset: 60, limit: 60, total: 61, revision: "second")
    #expect(throws: TVCoreError.invalidResponse) {
      try TVCatalogPageValidator.validate(
        page, kind: .movie, offset: 60, revision: nil,
        existingIDs: [item.id])
    }
    do {
      try TVCatalogPageValidator.validate(page, kind: .movie, offset: 60, revision: "first")
      Issue.record("Mixed catalog revisions must not be appended")
    } catch let error as TVCoreError { #expect(error.isConflict) }
  }

  @Test func pageRequestsEscapeRevisionAndRetainExplicitSort() async throws {
    let transport = TVCoreFakeTransport(responses: [
      response(
        """
        {"items":[],"offset":0,"limit":60,"total":0,"revision":"a&kind=series"}
        """)
    ])
    let client = TVAPIClient(
      connection: Self.connection, session: Self.session, transport: transport)
    _ = try await client.catalogPage(kind: .movie, offset: 0, revision: "a&kind=series")
    let request = try #require(await transport.requests.first?.request)
    let url = try #require(request.url)
    let query = try #require(
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.filter { $0.name == "kind" }.map(\.value) == ["movie"])
    #expect(query.first { $0.name == "revision" }?.value == "a&kind=series")
    #expect(query.first { $0.name == "sort" }?.value == "title")
  }

  @Test func anEndedSleepTimerIsReportedToTheServer() async throws {
    let transport = TVCoreFakeTransport(responses: [
      TVHTTPResponse(statusCode: 204, headers: [:], body: Data(), fingerprint: Self.fingerprint)
    ])
    let client = TVAPIClient(
      connection: Self.connection, session: Self.session, transport: transport)
    try await client.sleepTimerEnded()
    let captured = try #require(await transport.requests.first)
    #expect(captured.request.httpMethod == "POST")
    #expect(captured.request.url?.path == "/api/v1/playback/sleep-timer-ended")
    #expect(captured.trust == .pinned(Self.fingerprint))
  }

  @Test func unavailableDriveDisablesTheConcreteTarget() throws {
    let item = try decode(
      TVCatalogItem.self,
      itemJSON.replacingOccurrences(
        of: "\"libraryAvailability\":\"available\"",
        with: "\"libraryAvailability\":\"unavailable\""))
    #expect(!item.isPlayable)
    #expect(item.availabilityMessage == "Media drive disconnected")
  }

  @Test func explicitEpisodeCannotBeReplacedByAnotherTarget() throws {
    let item = try decode(TVCatalogItem.self, itemJSON)
    let plan = TVPlaybackPlan(
      target: item, seriesId: UUID(), queue: [], action: .play,
      continueWatchingEligible: false)
    #expect(throws: TVCoreError.invalidResponse) { try plan.validate(requestedID: UUID()) }
  }

  @Test func ticketAndArtworkPathsCannotEscapePinnedServer() throws {
    let client = TVAPIClient(connection: Self.connection, session: Self.session)
    let valid = "/api/v1/streams/" + String(repeating: "T", count: 43)
    #expect(try client.validatedStreamURL(path: valid).host == Self.baseURL.host)
    for path in [
      "https://attacker.invalid/api/v1/streams/token", valid + "?token=bad", valid + "/../other",
      valid + "%2Fother",
    ] {
      #expect(throws: TVCoreError.invalidResponse) { try client.validatedStreamURL(path: path) }
    }
    let artwork = TVArtwork(
      id: Self.mediaID, kind: "poster", path: "https://attacker.invalid/image",
      contentType: "image/jpeg", contentLength: 100, revision: 1)
    #expect(throws: TVCoreError.invalidResponse) {
      try client.artworkRequest(artwork: artwork, width: 320)
    }
  }

  @Test func artworkUsesFixedWidthAndKeepsRevisionOutOfURL() throws {
    let client = TVAPIClient(connection: Self.connection, session: Self.session)
    let artwork = TVArtwork(
      id: Self.mediaID, kind: "poster",
      path: "/api/v1/artwork/\(Self.mediaID.uuidString.lowercased())",
      contentType: "image/jpeg", contentLength: 100, revision: 7)
    let request = try client.artworkRequest(artwork: artwork, width: 640)
    #expect(request.url?.query == "width=640")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.session.token)")
    #expect(throws: TVCoreError.invalidResponse) {
      try client.artworkRequest(artwork: artwork, width: 999)
    }
  }

  @Test func guardedProgressUsesStableMutationAndVerifiesReceipt() async throws {
    let progress = TVPlaybackProgress(
      mediaId: Self.mediaID, positionMilliseconds: 20_000,
      durationMilliseconds: 60_000, isCompleted: false, lastPlayedAt: nil, updatedAt: nil,
      revision: 8, lastMutationId: Self.mutationID)
    let transport = TVCoreFakeTransport(responses: [try encodedResponse(progress)])
    let client = TVAPIClient(
      connection: Self.connection, session: Self.session, transport: transport)
    let saved = try await client.saveProgress(
      mediaID: Self.mediaID, position: 20_000, duration: 60_000,
      finished: false, expectedRevision: 7, mutationID: Self.mutationID)
    #expect(saved.revision == 8)
    let request = try #require(await transport.requests.first?.request)
    let body = try #require(request.httpBody)
    let payload = try #require(
      JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(payload["enforceRevision"] as? Bool == true)
    #expect(payload["expectedRevision"] as? Int == 7)
    #expect(payload["clientMutationId"] as? String == Self.mutationID.uuidString)
  }

  @Test func serviceResolutionUsesActualHostAndPortAndMergesInterfaces() throws {
    let service = TVBonjourService(
      name: "Display Name Is Not A Host", type: "_aurelia._tcp", domain: "local.",
      displayName: "Living Room", serverID: Self.serverID)
    let resolved = try #require(
      service.resolved(
        host: "actual-machine.local.", port: 54321,
        numericHosts: ["192.0.2.20", "fe80::1%en0"]))
    #expect(resolved.baseURL.host == "actual-machine.local.")
    #expect(resolved.baseURL.port == 54321)
    #expect(resolved.addresses.count == 3)
    let alternate = TVDiscoveredServer(
      id: resolved.id, name: resolved.name, serverID: Self.serverID,
      baseURL: URL(string: "https://192.0.2.21:54321")!)
    let merged = TVBonjourBrowser.merged([resolved, alternate])
    #expect(merged.count == 1)
    #expect(merged[0].addresses.count == 4)
  }

  private func decode<Value: Decodable>(_ type: Value.Type, _ value: String) throws -> Value {
    try JSONDecoder().decode(type, from: Data(value.utf8))
  }
  private func response(_ json: String, fingerprint: String = Self.fingerprint) -> TVHTTPResponse {
    TVHTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: Data(json.utf8), fingerprint: fingerprint)
  }
  private func encodedResponse(_ value: some Encodable) throws -> TVHTTPResponse {
    TVHTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try JSONEncoder().encode(value), fingerprint: Self.fingerprint)
  }
  private var infoJSON: String {
    """
    {"serverId":"\(Self.serverID)","name":"Synthetic server","version":"1.5.6","isSetup":true,
    "lanAccessEnabled":true,"lanHttpsPort":43111,"publicKeyFingerprint":"\(Self.fingerprint)",
    "capabilities":["device-authorization-v1","library-state-v1"]}
    """
  }
  private var pickerJSON: String {
    """
    {"formatVersion":2,"minimumClientVersion":"1.5.1","managementSetupRequired":false,
    "profiles":[{"id":"\(Self.profileID)","name":"Viewer","role":"user","needsPinSetup":false}]}
    """
  }
  private var emptyPageJSON: String {
    "{\"items\":[],\"offset\":0,\"limit\":60,\"total\":0,\"revision\":\"first\"}"
  }
  private var itemJSON: String {
    """
    {"id":"\(Self.mediaID)","kind":"movie","title":"Synthetic movie","genres":[],
    "availability":"available","isFavorite":false,"addedAt":"2026-10-16T00:00:00Z",
    "libraryAvailability":"available"}
    """
  }
}

private actor TVCoreFakeTransport: TVHTTPTransport {
  struct Captured: Sendable {
    let request: URLRequest
    let trust: TVTrustMode
  }
  private var responses: [TVHTTPResponse]
  private let delay: Duration
  private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var requests: [Captured] = []
  init(responses: [TVHTTPResponse], delay: Duration = .zero) {
    self.responses = responses
    self.delay = delay
  }
  func execute(_ request: URLRequest, trust: TVTrustMode) async throws -> TVHTTPResponse {
    requests.append(Captured(request: request, trust: trust))
    for waiter in firstRequestWaiters { waiter.resume() }
    firstRequestWaiters.removeAll()
    if delay != .zero { try? await Task.sleep(for: delay) }
    guard !responses.isEmpty else { throw TVCoreError.invalidResponse }
    return responses.removeFirst()
  }

  func waitForFirstRequest() async {
    if !requests.isEmpty { return }
    await withCheckedContinuation { firstRequestWaiters.append($0) }
  }
}
