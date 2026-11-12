import Foundation
import Testing

@Suite("iOS client contracts and transport")
struct IOSCoreTests {
  @Test func remoteCommandsDecodeAsTheServerWritesThem() throws {
    let json = #"""
      [{"commandId":"5f0c2f1e-4c7b-4a39-9a3e-0d6c1c2b8a11","action":"play","mediaId":"0b6f6a8e-2d9c-4b43-8d55-3f1a4c5e6d70","positionSeconds":null,"skipSeconds":null,"createdAt":"2026-10-31T16:50:00.1234567+00:00"}]
      """#
    let commands = try JSONDecoder().decode([IOSRemotePlaybackCommand].self, from: Data(json.utf8))
    #expect(commands.first?.action == "play")
  }

  @Test func untitledTracksDecodeAndOnlyTextSidecarFilesAreAdded() throws {
    let json = #"""
      [{"index":2,"format":"subrip","language":null,"title":null,"isDefault":false,"isForced":false,"supported":true,"isSidecar":false,"isSdh":false},
       {"index":1000,"format":"subrip","language":null,"title":null,"isDefault":false,"isForced":false,"supported":true,"isSidecar":true,"isSdh":false},
       {"index":1001,"format":"vobsub","language":"en","title":"English","isDefault":false,"isForced":false,"supported":false,"isSidecar":true,"isSdh":false}]
      """#
    let tracks = try JSONDecoder().decode([IOSLiveSubtitleTrack].self, from: Data(json.utf8))
    #expect(tracks.count == 3)
    #expect(IOSLiveSubtitleTrack.sidecarFiles(tracks).map(\.index) == [1000])
  }

  @Test func pinnedSessionsAreReusedPerIdentityAndBounded() {
    let pool = IOSPinnedSessionPool()
    let first = pool.lease(host: "tv.local", fingerprint: "aa")
    #expect(pool.lease(host: "tv.local", fingerprint: "AA").session === first.session)
    #expect(pool.lease(host: "tv.local", fingerprint: "bb").session !== first.session)
    for index in 0..<8 { _ = pool.lease(host: "host\(index).local", fingerprint: "cc") }
    #expect(pool.count == IOSPinnedSessionPool.capacity)
    pool.discard(host: "host7.local", fingerprint: "cc")
    #expect(pool.count == IOSPinnedSessionPool.capacity - 1)
    #expect(pool.lease(host: "tv.local", fingerprint: "aa").session !== first.session)
  }

  @Test func picturesUseTheirOwnConnectionsBesideTheData() {
    #expect(IOSConnectionLane(path: "/api/v1/artwork/0f0e") == .artwork)
    #expect(IOSConnectionLane(path: "/api/v1/media/0f0e/playback-plan") == .api)
    let pool = IOSPinnedSessionPool()
    let data = pool.lease(host: "tv.local", fingerprint: "aa")
    let pictures = pool.lease(host: "tv.local", fingerprint: "aa", lane: .artwork)
    #expect(data.session !== pictures.session)
    #expect(pool.lease(host: "tv.local", fingerprint: "AA", lane: .artwork).session === pictures.session)
  }

  @Test func aGenericDeviceNameGetsAStableTag() {
    let tag = UUID(uuidString: "AB12CD34-0000-4000-8000-000000000001")!
    #expect(IOSDeviceName.display(systemName: "iPhone", model: "iPhone", tag: tag) == "iPhone AB12")
    #expect(IOSDeviceName.display(systemName: "Lucas’s iPad", model: "iPad", tag: tag) == "Lucas’s iPad")
    #expect(IOSDeviceName.display(systemName: "Apple TV", model: "Apple TV", tag: nil) == "Apple TV")
  }

  @Test func onlyASilentServerCountsAsAsleep() {
    #expect(IOSServerReachability.isUnreachable(URLError(.cannotConnectToHost)))
    #expect(IOSServerReachability.isUnreachable(URLError(.timedOut)))
    // A server that answers with an error, or another failure, is not asleep.
    #expect(
      !IOSServerReachability.isUnreachable(
        IOSCoreError.server(status: 503, code: nil, message: nil, retryAfter: nil)))
    #expect(!IOSServerReachability.isUnreachable(IOSCoreError.identityMismatch))
    #expect(!IOSServerReachability.isUnreachable(URLError(.cancelled)))
  }

  private static let fingerprint = String(repeating: "A", count: 64)
  private static let serverID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
  private static let profileID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
  private static let mediaID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
  private static let mutationID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
  private static let baseURL = URL(string: "https://synthetic-server.local:43111")!
  private static var connection: IOSStoredConnection {
    IOSStoredConnection(
      serverID: serverID, name: "Synthetic server", baseURL: baseURL,
      fingerprint: fingerprint, deviceToken: String(repeating: "D", count: 43),
      deviceSessionID: UUID())
  }
  private static var session: IOSProfileSession {
    IOSProfileSession(
      user: IOSUser(id: profileID, username: "Viewer", role: "user"),
      sessionId: UUID(), token: String(repeating: "P", count: 43), expiresAt: "2099-01-01T00:00:00Z"
    )
  }

  @Test func addressDefaultsToHTTPSAndAcceptsIPv6() throws {
    #expect(
      try IOSServerAddress.normalize("media-mac.local").absoluteString
        == "https://media-mac.local:43111")
    #expect(try IOSServerAddress.normalize(" https://media-mac.local:54321/ ").port == 54321)
    #expect(try IOSServerAddress.normalize("https://[fe80::1%25en0]:54321").port == 54321)
    #expect(
      IOSServerAddress.trustHost("[fe80::1%25en0]") == IOSServerAddress.trustHost("fe80::1%en0"))
  }

  @Test(arguments: [
    "http://example.local", "https://user:password@example.local", "https://example.local/path",
    "https://example.local?token=value", "https://example.local#fragment",
    "https://example.local:0",
  ])
  func invalidAddressesAreRejected(_ value: String) {
    #expect(throws: IOSCoreError.invalidAddress) { try IOSServerAddress.normalize(value) }
  }

  @Test func fingerprintUsesSubjectPublicKeyInfoRatherThanRawKey() throws {
    #expect(
      try IOSServerIdentity.fingerprint(rawP256Key: Data([4] + Array(0...63)))
        == "0131DDA9654FEF86D57812B9960F260523C27A40C3A18FA8ECC7303510E78C22")
    #expect(throws: IOSCoreError.identityMismatch) {
      try IOSServerIdentity.fingerprint(rawP256Key: Data(repeating: 0, count: 65))
    }
  }

  @Test func capabilitiesUseProtocolNotIndependentTVMarketingVersion() throws {
    let capabilities = try decode(
      IOSCapabilities.self,
      """
      {"formatVersion":2,"minimumClientVersion":"1.5.1",
       "capabilities":["device-authorization-v1","library-state-v1","artwork-variants-v1"],"future":true}
      """)
    try capabilities.validate()
    #expect(capabilities.supportsArtworkVariants)
    let older = IOSCapabilities(formatVersion: 2, minimumClientVersion: "1.0", capabilities: [])
    #expect(throws: IOSCoreError.unsupportedServer) { try older.validate() }
    let future = IOSCapabilities(
      formatVersion: 99, minimumClientVersion: "1.5.1", capabilities: capabilities.capabilities)
    #expect(throws: IOSCoreError.outdatedClient) { try future.validate() }
    let ancient = IOSCapabilities(
      formatVersion: 0, minimumClientVersion: "1.0", capabilities: capabilities.capabilities)
    #expect(throws: IOSCoreError.unsupportedServer) { try ancient.validate() }
  }

  @Test func inspectDoesNotSendCredentialsAndChecksCapturedIdentity() async throws {
    let transport = IOSCoreFakeTransport(responses: [response(infoJSON)])
    let inspected = try await IOSAPIClient.inspect(baseURL: Self.baseURL, transport: transport)
    #expect(inspected.info.serverId == Self.serverID)
    let request = try #require(await transport.requests.first)
    #expect(request.request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.trust == .inspect)
    let wrong = IOSCoreFakeTransport(responses: [
      response(infoJSON, fingerprint: String(repeating: "B", count: 64))
    ])
    await #expect(throws: IOSCoreError.identityMismatch) {
      try await IOSAPIClient.inspect(baseURL: Self.baseURL, transport: wrong)
    }
    // A server that is closed to the home network says so, not that its identity changed.
    let closed = IOSCoreFakeTransport(responses: [
      response(infoJSON.replacingOccurrences(
        of: "\"lanAccessEnabled\":true", with: "\"lanAccessEnabled\":false"))
    ])
    await #expect(throws: IOSCoreError.lanAccessDisabled) {
      try await IOSAPIClient.inspect(baseURL: Self.baseURL, transport: closed)
    }
  }

  @Test func relocationRequiresBothStableIDAndSavedPublicKey() throws {
    let info = try decode(IOSServerInfo.self, infoJSON)
    let inspected = IOSInspectedServer(
      baseURL: URL(string: "https://192.0.2.20:43111")!,
      info: info, fingerprint: Self.fingerprint.lowercased())
    try inspected.validate(against: Self.connection)
    var other = Self.connection
    other = IOSStoredConnection(
      serverID: UUID(), name: other.name, baseURL: other.baseURL,
      fingerprint: other.fingerprint, deviceToken: other.deviceToken,
      deviceSessionID: other.deviceSessionID)
    #expect(throws: IOSCoreError.identityMismatch) { try inspected.validate(against: other) }
    let wrongKey = IOSInspectedServer(
      baseURL: inspected.baseURL, info: info,
      fingerprint: String(repeating: "B", count: 64))
    #expect(throws: IOSCoreError.identityMismatch) {
      try wrongKey.validate(against: Self.connection)
    }
  }

  @Test func profileAndCatalogUseDifferentCredentials() async throws {
    let transport = IOSCoreFakeTransport(responses: [response(pickerJSON), response(emptyPageJSON)])
    let client = IOSAPIClient(
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
    let deviceOnly = IOSAPIClient(connection: Self.connection, transport: transport)
    await #expect(throws: IOSCoreError.profileRequired) {
      try await deviceOnly.catalogPage(kind: .movie, offset: 0)
    }
  }

  @Test func noPINProfilesAndMissingOptionalFieldsRemainCompatible() throws {
    let picker = try decode(IOSProfilePicker.self, pickerJSON)
    try picker.validate()
    #expect(picker.profiles.first?.pinProtectionEnabled == true)
    #expect(IOSProfilePIN.isValid("1234"))
    #expect(IOSProfilePIN.isValid("12345678"))
    #expect(!IOSProfilePIN.isValid("123"))
    #expect(!IOSProfilePIN.isValid("１２３４"))
    #expect(!IOSProfilePIN.isValid("12 34"))
  }

  @Test func profileColorsMatchTheMacAndInitialsAreUppercase() {
    #expect(IOSProfileColor.index(for: nil) == 0)
    let id = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    // Bytes 0x40 + 0x80 + 0x02 = 194, and 194 % 7 = 5, as on the Mac.
    #expect(IOSProfileColor.index(for: id) == 5)
    #expect(IOSProfileColor.initial(of: "  lucas") == "L")
    #expect(IOSProfileColor.initial(of: " ") == "?")
  }

  @Test func unlockValidatesResponseBelongsToSelectedProfile() async throws {
    let profile = Self.session
    let transport = IOSCoreFakeTransport(responses: [try encodedResponse(profile)])
    let client = IOSAPIClient(connection: Self.connection, transport: transport)
    await #expect(throws: IOSCoreError.invalidResponse) {
      try await client.unlockProfile(id: UUID(), pin: "1234")
    }
    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(requests[0].request.httpMethod == "POST")
  }

  @Test func malformedPINDoesNotReachServer() async throws {
    let transport = IOSCoreFakeTransport(responses: [])
    let client = IOSAPIClient(connection: Self.connection, transport: transport)
    do {
      _ = try await client.unlockProfile(id: Self.profileID, pin: "abcd")
      Issue.record("Invalid PIN must fail locally")
    } catch let error as IOSCoreError {
      #expect(error.code == "invalid_profile_pin")
      #expect(error.localizedDescription == IOSProfilePIN.incorrect)
    }
    do {
      _ = try await client.unlockProfile(id: Self.profileID, pin: "12")
      Issue.record("A short PIN must fail locally")
    } catch let error as IOSCoreError {
      #expect(error.localizedDescription == IOSProfilePIN.incorrect, "No hint about the length.")
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test func expiredProfileIsReportedWithoutSendingItsToken() async throws {
    let transport = IOSCoreFakeTransport(responses: [])
    let current = Self.session
    let expired = IOSProfileSession(
      user: current.user, sessionId: current.sessionId,
      token: current.token, expiresAt: "2000-01-01T00:00:00Z")
    let client = IOSAPIClient(connection: Self.connection, session: expired, transport: transport)
    do {
      _ = try await client.catalogPage(kind: .movie, offset: 0)
      Issue.record("Expired profiles must return to selection")
    } catch let error as IOSCoreError {
      #expect(error.isAuthenticationFailure)
      #expect(error.code == "profile_session_expired")
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test func pairingSecretsStayInBodiesAndStatusIsFutureSafe() async throws {
    let transport = IOSCoreFakeTransport(responses: [
      response(
        """
        {"state":"futureState","expiresAt":"2099-01-01T00:00:00Z","pollIntervalSeconds":5,"acknowledged":false}
        """)
    ])
    let info = try decode(IOSServerInfo.self, infoJSON)
    let client = IOSAPIClient(
      inspected: IOSInspectedServer(
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
    connection.pendingAcknowledgement = IOSPendingPairingAcknowledgement(
      id: UUID(),
      secret: String(repeating: "S", count: 43), expiresAt: "2099-01-01T00:00:00Z")
    let encoded = try JSONEncoder().encode(connection)
    let reloaded = try JSONDecoder().decode(IOSStoredConnection.self, from: encoded)
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
    let transport = IOSCoreFakeTransport(responses: [
      IOSHTTPResponse(
        statusCode: 429,
        headers: ["retry-after": "5"],
        body: Data(
          "{\"code\":\"device_pairing_slow_down\",\"message\":\"Wait before checking again.\"}".utf8
        ),
        fingerprint: Self.fingerprint)
    ])
    let client = IOSAPIClient(connection: Self.connection, transport: transport)
    do {
      _ = try await client.pairingStatus(id: UUID(), secret: String(repeating: "S", count: 43))
      Issue.record("Rate limit must be reported")
    } catch let error as IOSCoreError {
      #expect(error.statusCode == 429)
      #expect(error.code == "device_pairing_slow_down")
      #expect(error.retryDelay == 5)
    }
  }

  @Test func cancellationRejectsEvenAnUncooperativeLateResponse() async throws {
    let transport = IOSCoreFakeTransport(
      responses: [response(pickerJSON)], delay: .milliseconds(30))
    let task = Task {
      try await IOSAPIClient(connection: Self.connection, transport: transport).profiles()
    }
    await transport.waitForFirstRequest()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func paginationRejectsDuplicateIDsAndMixedRevisions() throws {
    let item = try decode(IOSCatalogItem.self, itemJSON)
    let page = IOSPage(items: [item], offset: 60, limit: 60, total: 61, revision: "second")
    #expect(throws: IOSCoreError.invalidResponse) {
      try IOSCatalogPageValidator.validate(
        page, kind: .movie, offset: 60, revision: nil,
        existingIDs: [item.id])
    }
    do {
      try IOSCatalogPageValidator.validate(page, kind: .movie, offset: 60, revision: "first")
      Issue.record("Mixed catalog revisions must not be appended")
    } catch let error as IOSCoreError { #expect(error.isConflict) }
  }

  @Test func pageRequestsEscapeRevisionAndRetainExplicitSort() async throws {
    let transport = IOSCoreFakeTransport(responses: [
      response(
        """
        {"items":[],"offset":0,"limit":60,"total":0,"revision":"a&kind=series"}
        """)
    ])
    let client = IOSAPIClient(
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
    let transport = IOSCoreFakeTransport(responses: [
      IOSHTTPResponse(statusCode: 204, headers: [:], body: Data(), fingerprint: Self.fingerprint)
    ])
    let client = IOSAPIClient(
      connection: Self.connection, session: Self.session, transport: transport)
    try await client.sleepTimerEnded()
    let captured = try #require(await transport.requests.first)
    #expect(captured.request.httpMethod == "POST")
    #expect(captured.request.url?.path == "/api/v1/playback/sleep-timer-ended")
    #expect(captured.trust == .pinned(Self.fingerprint))
  }

  @Test func unavailableDriveDisablesTheConcreteTarget() throws {
    let item = try decode(
      IOSCatalogItem.self,
      itemJSON.replacingOccurrences(
        of: "\"libraryAvailability\":\"available\"",
        with: "\"libraryAvailability\":\"unavailable\""))
    #expect(!item.isPlayable)
    #expect(item.availabilityMessage == "Media drive disconnected")
  }

  @Test func explicitEpisodeCannotBeReplacedByAnotherTarget() throws {
    let item = try decode(IOSCatalogItem.self, itemJSON)
    let plan = IOSPlaybackPlan(
      target: item, seriesId: UUID(), queue: [], action: .play,
      continueWatchingEligible: false)
    #expect(throws: IOSCoreError.invalidResponse) { try plan.validate(requestedID: UUID()) }
  }

  @Test func ticketAndArtworkPathsCannotEscapePinnedServer() throws {
    let client = IOSAPIClient(connection: Self.connection, session: Self.session)
    let valid = "/api/v1/streams/" + String(repeating: "T", count: 43)
    #expect(try client.validatedStreamURL(path: valid).host == Self.baseURL.host)
    for path in [
      "https://attacker.invalid/api/v1/streams/token", valid + "?token=bad", valid + "/../other",
      valid + "%2Fother",
    ] {
      #expect(throws: IOSCoreError.invalidResponse) { try client.validatedStreamURL(path: path) }
    }
    let artwork = IOSArtwork(
      id: Self.mediaID, kind: "poster", path: "https://attacker.invalid/image",
      contentType: "image/jpeg", contentLength: 100, revision: 1)
    #expect(throws: IOSCoreError.invalidResponse) {
      try client.artworkRequest(artwork: artwork, width: 320)
    }
  }

  @Test func artworkUsesFixedWidthAndKeepsRevisionOutOfURL() throws {
    let client = IOSAPIClient(connection: Self.connection, session: Self.session)
    let artwork = IOSArtwork(
      id: Self.mediaID, kind: "poster",
      path: "/api/v1/artwork/\(Self.mediaID.uuidString.lowercased())",
      contentType: "image/jpeg", contentLength: 100, revision: 7)
    let request = try client.artworkRequest(artwork: artwork, width: 640)
    #expect(request.url?.query == "width=640")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.session.token)")
    #expect(throws: IOSCoreError.invalidResponse) {
      try client.artworkRequest(artwork: artwork, width: 999)
    }
  }

  @Test func guardedProgressUsesStableMutationAndVerifiesReceipt() async throws {
    let progress = IOSPlaybackProgress(
      mediaId: Self.mediaID, positionMilliseconds: 20_000,
      durationMilliseconds: 60_000, isCompleted: false, lastPlayedAt: nil, updatedAt: nil,
      revision: 8, lastMutationId: Self.mutationID)
    let transport = IOSCoreFakeTransport(responses: [try encodedResponse(progress)])
    let client = IOSAPIClient(
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

  @Test func capabilitiesExposeWatchlistAndScrubPreviews() throws {
    let caps = try decode(
      IOSCapabilities.self,
      """
      {"formatVersion":2,"minimumClientVersion":"1.0",
       "capabilities":["device-authorization-v1","library-state-v1","watchlist-people-v1","scrub-previews-v1"]}
      """)
    #expect(caps.supportsWatchlistAndPeople)
    #expect(caps.supportsScrubPreviews)

    let plain = try decode(
      IOSCapabilities.self,
      """
      {"formatVersion":2,"minimumClientVersion":"1.0",
       "capabilities":["device-authorization-v1","library-state-v1"]}
      """)
    #expect(!plain.supportsWatchlistAndPeople)
    #expect(!plain.supportsScrubPreviews)
  }

  @Test func watchlistEndpointsRequestCorrectPathsAndDecodePayloads() async throws {
    let watchlistJSON = """
      {"items":[\(itemJSON)],"mediaIds":["\(Self.mediaID.uuidString)"]}
      """
    let updateJSON = """
      {"mediaId":"\(Self.mediaID.uuidString)","isWatchlisted":true}
      """
    let transport = IOSCoreFakeTransport(responses: [
      response(watchlistJSON),
      response(updateJSON),
    ])
    let client = IOSAPIClient(
      connection: Self.connection, session: Self.session, transport: transport)

    let list = try await client.watchlist()
    #expect(list.items.count == 1)
    #expect(list.mediaIds == [Self.mediaID])

    let updated = try await client.setWatchlist(mediaID: Self.mediaID, isWatchlisted: true)
    #expect(updated.mediaId == Self.mediaID)
    #expect(updated.isWatchlisted == true)

    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests[0].request.url?.path == "/api/v1/watchlist")
    #expect(requests[0].request.httpMethod == "GET")
    #expect(requests[1].request.url?.path == "/api/v1/media/\(Self.mediaID.uuidString)/watchlist")
    #expect(requests[1].request.httpMethod == "PUT")
  }

  @Test func personDetailEndpointRequestsEncodedNameAndDecodesResponse() async throws {
    let personJSON = """
      {"name":"Jane Doe","subtitle":"Actor","profile":null,"items":[\(itemJSON)]}
      """
    let transport = IOSCoreFakeTransport(responses: [response(personJSON)])
    let client = IOSAPIClient(
      connection: Self.connection, session: Self.session, transport: transport)

    let person = try await client.personDetail(name: "Jane Doe")
    #expect(person.name == "Jane Doe")
    #expect(person.subtitle == "Actor")
    #expect(person.items.count == 1)

    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(requests[0].request.url?.path == "/api/v1/catalog/person")
    #expect(requests[0].request.url?.query == "name=Jane%20Doe")
  }

  @Test func scrubPreviewFrameRequestsCorrectPath() async throws {
    let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
    let transport = IOSCoreFakeTransport(responses: [
      IOSHTTPResponse(
        statusCode: 200, headers: ["Content-Type": "image/jpeg"],
        body: jpegBytes, fingerprint: Self.fingerprint)
    ])
    let client = IOSAPIClient(
      connection: Self.connection, session: Self.session, transport: transport)

    let frame = try await client.scrubPreviewFrame(mediaID: Self.mediaID, seconds: 45)
    #expect(frame == jpegBytes)

    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(
      requests[0].request.url?.path
        == "/api/v1/media/\(Self.mediaID.uuidString.lowercased())/scrub-previews/45")
    #expect(requests[0].request.httpMethod == "GET")
  }

  @Test func serviceResolutionUsesActualHostAndPortAndMergesInterfaces() throws {
    let service = IOSBonjourService(
      name: "Display Name Is Not A Host", type: "_aurelia._tcp", domain: "local.",
      displayName: "Living Room", serverID: Self.serverID)
    let resolved = try #require(
      service.resolved(
        host: "actual-machine.local.", port: 54321,
        numericHosts: ["192.0.2.20", "fe80::1%en0"]))
    #expect(resolved.baseURL.host == "actual-machine.local.")
    #expect(resolved.baseURL.port == 54321)
    #expect(resolved.addresses.count == 3)
    let alternate = IOSDiscoveredServer(
      id: resolved.id, name: resolved.name, serverID: Self.serverID,
      baseURL: URL(string: "https://192.0.2.21:54321")!)
    let merged = IOSBonjourBrowser.merged([resolved, alternate])
    #expect(merged.count == 1)
    #expect(merged[0].addresses.count == 4)
  }

  private func decode<Value: Decodable>(_ type: Value.Type, _ value: String) throws -> Value {
    try JSONDecoder().decode(type, from: Data(value.utf8))
  }
  private func response(_ json: String, fingerprint: String = Self.fingerprint) -> IOSHTTPResponse {
    IOSHTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: Data(json.utf8), fingerprint: fingerprint)
  }
  private func encodedResponse(_ value: some Encodable) throws -> IOSHTTPResponse {
    IOSHTTPResponse(
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

private actor IOSCoreFakeTransport: IOSHTTPTransport {
  struct Captured: Sendable {
    let request: URLRequest
    let trust: IOSTrustMode
  }
  private var responses: [IOSHTTPResponse]
  private let delay: Duration
  private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var requests: [Captured] = []
  init(responses: [IOSHTTPResponse], delay: Duration = .zero) {
    self.responses = responses
    self.delay = delay
  }
  func execute(_ request: URLRequest, trust: IOSTrustMode) async throws -> IOSHTTPResponse {
    requests.append(Captured(request: request, trust: trust))
    for waiter in firstRequestWaiters { waiter.resume() }
    firstRequestWaiters.removeAll()
    if delay != .zero { try? await Task.sleep(for: delay) }
    guard !responses.isEmpty else { throw IOSCoreError.invalidResponse }
    return responses.removeFirst()
  }

  func waitForFirstRequest() async {
    if !requests.isEmpty { return }
    await withCheckedContinuation { firstRequestWaiters.append($0) }
  }
}
