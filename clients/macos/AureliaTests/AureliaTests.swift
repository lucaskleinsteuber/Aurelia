import Foundation
import Testing

@testable import Aurelia

struct AureliaTests {
  @Test
  func hostingDefaultsDoNotOptIntoBackgroundOrLoginServices() throws {
    let settings = HostServiceSettings()
    #expect(!settings.backgroundEnabled)
    #expect(!settings.startAtLogin)
    #expect(!settings.preventIdleSleep)
    #expect(settings.controlSecret.isEmpty)
    let request = HostServiceRequest(
      id: UUID(), backgroundEnabled: false, startAtLogin: false, preventIdleSleep: true)
    let data = try JSONEncoder().encode(request)
    #expect(try JSONDecoder().decode(HostServiceRequest.self, from: data) == request)
    #expect(String(data: data, encoding: .utf8)?.contains("controlSecret") == false)
  }

  @Test
  func seriesInformationUsesYearOneCountryAndActualEpisodes() {
    let detail = informationFixture(kind: .series)
    let fields = MediaInformationPresentation.fields(for: detail)

    #expect(
      fields.map(\.title) == [
        "Seasons", "Episodes", "Studio", "Released", "Country of Origin", "Genres", "FSK",
      ])
    #expect(fields.map(\.value) == ["1", "1", "Test Studio", "2019", "US", "Drama", "FSK 12"])
    #expect(!fields.map(\.title).contains("Content Rating"))
    #expect(!fields.map(\.title).contains("Original Title"))
  }

  @Test
  func movieInformationOnlyIncludesMovieFields() {
    let fields = MediaInformationPresentation.fields(for: informationFixture(kind: .movie))

    #expect(
      fields.map(\.title) == [
        "Runtime", "Release Year", "Genres", "Studio", "Country of Origin", "FSK",
      ])
    #expect(fields.map(\.value) == ["103 min", "2019", "Drama", "Test Studio", "US", "FSK 12"])
  }

  private func informationFixture(kind: MediaKind) -> CatalogDetailPresentation {
    let id = UUID()
    let item = CatalogItemSummary(
      id: id, kind: kind, title: "Test Title", originalTitle: "Other Title", year: 2018,
      overview: nil, genres: ["Drama"], poster: nil, backdrop: nil,
      availability: .available, isFavorite: false, progress: nil,
      addedAt: "2026-09-26T00:00:00Z")
    let episode = CatalogItemSummary(
      id: UUID(), kind: .episode, title: "Episode 1", originalTitle: nil, year: 2019,
      overview: nil, genres: [], poster: nil, backdrop: nil,
      availability: .available, isFavorite: false, progress: nil,
      addedAt: "2026-09-26T00:00:00Z")
    let extra = CatalogItemSummary(
      id: UUID(), kind: .extra, title: "Featurette", originalTitle: nil, year: nil,
      overview: nil, genres: [], poster: nil, backdrop: nil,
      availability: .available, isFavorite: false, progress: nil,
      addedAt: "2026-09-26T00:00:00Z")
    let metadata = MediaMetadataSummary(
      mediaId: id, title: item.title, originalTitle: item.originalTitle, overview: nil,
      releaseDate: "2019-05-06", year: 2019, runtimeMinutes: 103,
      rating: nil, contentRating: "TV-MA", genres: ["Drama"], studios: ["Test Studio"],
      countries: ["US", "GB"], credits: [], poster: nil, backdrop: nil, still: nil,
      provider: nil, providerMediaId: nil, reviewState: .matched, fskAge: 12)
    return CatalogDetailPresentation(
      item: item, metadata: metadata,
      seasons: [
        SeasonPresentation(
          number: 1,
          episodes: [EpisodePresentation(item: episode, seasonNumber: 1, episodeNumber: 1)],
          supplements: [SupplementPresentation(item: extra, category: "Extras", seasonNumber: 1)])
      ],
      supplements: [SupplementPresentation(item: extra, category: "Extras", seasonNumber: nil)])
  }

  @Test
  func classicCanvasUsesTheMeasuredReferenceColor() {
    #expect(AureliaDesign.canvasRGB.red == 32)
    #expect(AureliaDesign.canvasRGB.green == 35)
    #expect(AureliaDesign.canvasRGB.blue == 38)
  }

  @Test
  func metadataProviderAndJobResponsesDecodeWithoutSecrets() throws {
    let provider = try JSONDecoder().decode(
      MetadataProviderStatus.self,
      from: Data(
        """
        {"enabled":true,"hasToken":true,"language":"en-US","artworkBytes":42,
        "artworkLimitBytes":1073741824,"provider":"TMDB","attribution":"Required attribution"}
        """.utf8))
    #expect(provider.enabled)
    #expect(provider.hasToken)
    #expect(provider.language == "en-US")
    #expect(provider.artworkBytes == 42)

    let job = try JSONDecoder().decode(
      MetadataJobSummary.self,
      from: Data(
        """
        {"id":"00000000-0000-0000-0000-000000000009","libraryId":null,"mediaId":null,
        "state":"running","itemsTotal":10,"itemsProcessed":4,"itemsMatched":3,
        "itemsNeedingReview":1,"itemsFailed":0,"error":null,
        "createdAt":"2026-09-09T12:00:00Z","startedAt":"2026-09-09T12:00:01Z","completedAt":null}
        """.utf8))
    #expect(job.state == .running)
    #expect(job.itemsProcessed == 4)
    #expect(job.itemsNeedingReview == 1)
    #expect(job.nextAttemptAt == nil)
    #expect(job.waitReason == nil)
    #expect(job.itemsSkipped == nil)
    #expect(job.waitingStatus() == nil)
  }

  @Test
  func metadataWaitingStatusDecodesAdditiveFieldsAndUsesLocalTime() throws {
    var job = try JSONDecoder().decode(
      MetadataJobSummary.self,
      from: Data(
        """
        {"id":"00000000-0000-0000-0000-000000000009","state":"queued",
        "itemsTotal":10,"itemsProcessed":4,"itemsMatched":2,"itemsNeedingReview":1,
        "itemsSkipped":1,"itemsFailed":0,"createdAt":"2026-10-15T12:00:00Z",
        "nextAttemptAt":"2026-10-15T14:32:00.000Z","waitReason":"tmdb"}
        """.utf8))
    #expect(job.itemsSkipped == 1)
    #expect(
      job.waitingStatus(locale: Locale(identifier: "en_GB"), timeZone: .gmt)
        == "Waiting for TMDB · Retry at 14:32")
    job.nextAttemptAt = "invalid"
    #expect(job.waitingStatus() == "Waiting for TMDB")
    job.waitReason = "storage"
    #expect(job.waitingStatus() == "Waiting for writable storage")
  }

  @Test
  func serverAddressDefaultsToSecureLanPort() throws {
    let url = try APIClient.normalizedServerURL("192.168.1.20")
    #expect(url.absoluteString == "https://192.168.1.20:43111")
  }

  @Test(
    arguments: [
      (nil, 0, nil, nil),
      (OperatingMode.client, 0, nil, OperatingMode.host),
      (OperatingMode.host, 0, "https://media-mac.local:43111", OperatingMode.client),
      (OperatingMode.client, 0, "https://127.0.0.1:43111", OperatingMode.host),
      (OperatingMode.client, 0, "https://localhost:43111", OperatingMode.host),
      (OperatingMode.client, 0, "https://[::1]:43111", OperatingMode.host),
      (OperatingMode.host, 0, "https://192.168.1.20:43111", OperatingMode.client),
      (OperatingMode.host, 1, "https://192.168.1.20:43111", OperatingMode.host),
      (OperatingMode.client, 1, "https://127.0.0.1:43111", OperatingMode.client),
    ] as [(OperatingMode?, Int, String?, OperatingMode?)]
  )
  func operatingModeMigrationIsExplicitAndDistinguishesLoopbackFromRemote(
    storedMode: OperatingMode?,
    selectionVersion: Int,
    address: String?,
    expected: OperatingMode?
  ) throws {
    let profile = try address.map { address in
      StoredServerProfile(
        serverId: UUID(),
        name: "Test",
        baseURL: try #require(URL(string: address)),
        publicKeyFingerprint: String(repeating: "A", count: 64),
        token: "test-token",
        sessionId: UUID(),
        expiresAt: "2099-01-01T00:00:00Z")
    }
    #expect(
      OperatingModePolicy.resolve(
        storedMode: storedMode,
        storedSelectionVersion: selectionVersion,
        profile: profile) == expected)
  }

  @Test
  func insecureAndPathBasedAddressesAreRejected() {
    #expect(throws: APIClientError.insecureAddress) {
      try APIClient.normalizedServerURL("http://192.168.1.20:43110")
    }
    #expect(throws: APIClientError.invalidAddress) {
      try APIClient.normalizedServerURL("https://example.local/media")
    }
  }

  @Test
  func verifiedLocalOwnershipSurvivesAStaleClientPreferenceAndProfileRoundTrip() throws {
    let original = StoredServerProfile(
      serverId: UUID(), name: "Existing server", baseURL: URL(string: "https://127.0.0.1:43111")!,
      publicKeyFingerprint: String(repeating: "A", count: 64), token: "synthetic-session",
      sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z")
    let legacy = try JSONDecoder().decode(
      StoredServerProfile.self, from: JSONEncoder().encode(original))
    #expect(legacy.locallyManaged == nil)
    #expect(
      OperatingModePolicy.resolve(storedMode: .client, storedSelectionVersion: 1, profile: legacy)
        == .client)
    let owned = original.retainingLocalHosting()
    let reloaded = try JSONDecoder().decode(
      StoredServerProfile.self, from: JSONEncoder().encode(owned))
    #expect(reloaded == owned)
    #expect(reloaded.serverId == original.serverId)
    #expect(reloaded.token == original.token)
    #expect(reloaded.sessionId == original.sessionId)
    #expect(reloaded.expiresAt == original.expiresAt)
    #expect(reloaded.publicKeyFingerprint == original.publicKeyFingerprint)
    #expect(
      OperatingModePolicy.resolve(storedMode: .client, storedSelectionVersion: 1, profile: reloaded)
        == .host)
    #expect(
      OperatingModePolicy.resolve(storedMode: nil, storedSelectionVersion: 0, profile: reloaded)
        == .host)
  }

  @Test(arguments: [
    "https://server.local:43111", "https://192.168.1.20:43111",
    "https://127.0.0.1.evil.invalid:43111",
  ])
  func localOwnershipNeverStartsHostingForRemoteConnections(address: String) {
    let profile = StoredServerProfile(
      serverId: UUID(), name: "Remote", baseURL: URL(string: address)!,
      publicKeyFingerprint: "test", token: "synthetic", sessionId: UUID(),
      expiresAt: "2099-01-01", locallyManaged: true)
    #expect(
      OperatingModePolicy.resolve(storedMode: .client, storedSelectionVersion: 1, profile: profile)
        == .client)
  }

  @Test
  func localRecoveryRequiresTheExistingServerIdentityAndFingerprint() {
    let id = UUID()
    let profile = StoredServerProfile(
      serverId: id, name: "Existing", baseURL: URL(string: "https://127.0.0.1:43111")!,
      publicKeyFingerprint: "AABB", token: "synthetic", sessionId: UUID(), expiresAt: "2099")
    func snapshot(
      id: UUID, fingerprint: String, state: NativeHostState = .running, setup: Bool = true
    ) -> NativeHostSnapshot {
      NativeHostSnapshot(
        state: state, message: nil, bootstrapToken: nil,
        serverInfo: ServerInfoResponse(
          serverId: id, name: "Existing", version: "test", isSetup: setup,
          lanAccessEnabled: true, lanHttpsPort: 43111, publicKeyFingerprint: fingerprint,
          displayFingerprint: nil))
    }
    #expect(throws: Never.self) {
      try OperatingModePolicy.validateLocalHost(
        snapshot(id: id, fingerprint: "aabb"), profile: profile)
    }
    #expect(throws: APIClientError.serverIdentityMismatch) {
      try OperatingModePolicy.validateLocalHost(
        snapshot(id: UUID(), fingerprint: "AABB"), profile: profile)
    }
    #expect(throws: APIClientError.serverIdentityMismatch) {
      try OperatingModePolicy.validateLocalHost(
        snapshot(id: id, fingerprint: "CCDD"), profile: profile)
    }
    #expect(throws: APIClientError.serverIdentityMismatch) {
      try OperatingModePolicy.validateLocalHost(
        snapshot(id: id, fingerprint: "AABB", state: .starting), profile: profile)
    }
    #expect(throws: APIClientError.serverIdentityMismatch) {
      try OperatingModePolicy.validateLocalHost(
        snapshot(id: id, fingerprint: "AABB", setup: false), profile: profile)
    }
  }

  @Test(arguments: [
    NativeHostState.starting, .restarting, .running, .setupRequired, .failed, .stopped, .stopping,
  ])
  func helperReadinessIsNotAssumedFromRendezvous(state: NativeHostState) {
    #expect(
      OperatingModePolicy.isAwaitingReadiness(state) == (state == .starting || state == .restarting)
    )
  }

  @Test(arguments: [false, true])
  func preflightIsolationAcceptsDirectoryPathsWithEitherURLSlash(isDirectory: Bool) {
    #expect(
      NativePreflightIsolation.accepts(
        bundleURL: URL(fileURLWithPath: "/private/tmp/Aurelia/synthetic-test/Aurelia.app"),
        dataDirectory: URL(
          fileURLWithPath: "/private/tmp/Aurelia/synthetic-test/Data", isDirectory: isDirectory)))
  }

  @Test
  func preflightIsolationAcceptsTheMacOSTemporaryDirectoryAlias() {
    #expect(
      NativePreflightIsolation.accepts(
        bundleURL: URL(fileURLWithPath: "/tmp/Aurelia/synthetic-test/Aurelia.app"),
        dataDirectory: URL(fileURLWithPath: "/private/tmp/Aurelia/synthetic-test/Data")))
  }

  @Test(arguments: [
    ("/Applications/Aurelia.app", "/private/tmp/Aurelia/synthetic-test/Data"),
    ("/private/tmp/Aurelia/synthetic-test/Other.app", "/private/tmp/Aurelia/synthetic-test/Data"),
    ("/private/tmp/Aurelia/synthetic-test/Aurelia.app", "/private/tmp/Aurelia/other-test/Data"),
    ("/private/tmp/Aurelia/synthetic-test/Aurelia.app", "/private/tmp/Aurelia/synthetic-test"),
  ])
  func preflightIsolationRejectsUnrelatedApplicationsAndData(bundle: String, data: String) {
    #expect(
      !NativePreflightIsolation.accepts(
        bundleURL: URL(fileURLWithPath: bundle), dataDirectory: URL(fileURLWithPath: data)))
  }

  @Test
  func serverInformationDecodesBuildSixIdentity() throws {
    let json = Data(
      """
      {
        "serverId":"00000000-0000-0000-0000-000000000004",
        "name":"Living Room",
        "version":"0.1.0",
        "isSetup":true,
        "lanAccessEnabled":true,
        "lanHttpsPort":43111,
        "publicKeyFingerprint":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "displayFingerprint":"AAAA-AAAA-AAAA-AAAA-AAAA-AAAA"
      }
      """.utf8)
    let info = try JSONDecoder().decode(ServerInfoResponse.self, from: json)
    #expect(info.name == "Living Room")
    #expect(info.lanAccessEnabled)
    #expect(info.lanHttpsPort == 43111)
  }

  @Test
  func playbackResponseDecodesProgressAndKeepsStreamPathRelative() throws {
    let mediaID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let playbackID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    let json = Data(
      """
      {
        "id":"\(playbackID)",
        "mediaId":"\(mediaID)",
        "streamPath":"/api/v1/streams/opaque-ticket",
        "contentType":"video/x-matroska",
        "contentLength":4096,
        "expiresAt":"2099-01-01T12:00:00Z",
        "progress":{
          "mediaId":"\(mediaID)",
          "positionMilliseconds":42000,
          "durationMilliseconds":120000,
          "isCompleted":false,
          "lastPlayedAt":"2099-01-01T00:00:00Z",
          "updatedAt":"2099-01-01T00:00:00Z"
        }
      }
      """.utf8)
    let response = try JSONDecoder().decode(PlaybackSourceResponse.self, from: json)
    #expect(response.progress.positionMilliseconds == 42_000)

    let profile = StoredServerProfile(
      serverId: UUID(),
      name: "Test",
      baseURL: URL(string: "https://server.local:43111")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      token: "test-token",
      sessionId: UUID(),
      expiresAt: "2099-01-01T00:00:00Z")
    let client = APIClient(profile: profile)
    #expect(
      try client.streamURL(path: response.streamPath).absoluteString
        == "https://server.local:43111/api/v1/streams/opaque-ticket")
    #expect(throws: APIClientError.invalidResponse) {
      try client.streamURL(path: "https://attacker.invalid/api/v1/streams/stolen")
    }
  }

  @Test
  func relayParserAcceptsOnlyTheSecretLoopbackPlaybackShape() throws {
    let secret = "test-secret"
    let request = Data(
      "GET /stream/\(secret) HTTP/1.1\r\nHost: 127.0.0.1:54321\r\nRange: bytes=10-20\r\nIf-Range: test-etag\r\n\r\n"
        .utf8)
    #expect(
      try LoopbackStreamRelay.parseRequest(request, secret: secret)
        == RelayRequest(method: "GET", range: "bytes=10-20", ifRange: "test-etag"))

    for invalid in [
      "GET /stream/wrong HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
      "POST /stream/\(secret) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
      "GET /stream/\(secret) HTTP/1.1\r\nHost: example.com\r\n\r\n",
      "GET /stream/\(secret) HTTP/1.1\r\nHost: 127.0.0.1:invalid\r\n\r\n",
      "GET /stream/\(secret) HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-1,4-5\r\n\r\n",
      "GET /stream/\(secret) HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=999999999999999999999999-\r\n\r\n",
      "GET /stream/\(secret) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 1\r\n\r\n",
    ] {
      #expect(throws: StreamRelayError.invalidRequest) {
        try LoopbackStreamRelay.parseRequest(Data(invalid.utf8), secret: secret)
      }
    }
  }

  @Test
  func ticketRenewalHappensFiveMinutesBeforeExpiration() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let expires = ISO8601DateFormatter().string(from: now.addingTimeInterval(12 * 60 * 60))
    #expect(TicketRenewalPolicy.delayUntilRenewal(expiresAt: expires, now: now) == 42_900)
    let fractionalDelay = TicketRenewalPolicy.delayUntilRenewal(
      expiresAt: "1970-01-13T01:46:40.872864+00:00",
      now: now)
    #expect(abs(fractionalDelay - 42_900.872864) < 0.001)
    #expect(TicketRenewalPolicy.delayUntilRenewal(expiresAt: "invalid", now: now) == 1)
  }

  @Test
  func trackPreferencesUseDescriptionAndLanguageInsteadOfVLCIndex() {
    let english = PlaybackTrack(id: 4, title: "Commentary - [English]")
    let sameDescriptionNewIndex = PlaybackTrack(id: 12, title: "Commentary - [English]")
    #expect(english.preference == sameDescriptionNewIndex.preference)
    #expect(english.preference.language == "english")
    #expect(english.preference.title == "commentary - [english]")
  }

  @Test
  func fingerprintDisplayUsesOnlyTheComparisonPrefix() {
    let full = "00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF"
    #expect(FingerprintFormatter.display(full) == "0011-2233-4455-6677-8899-AABB")
  }

  @Test
  func p256FingerprintMatchesIndependentSubjectPublicKeyInfoVector() {
    let rawKey = Data([0x04] + Array(0...63))
    #expect(
      ServerPublicKeyFingerprint.calculateP256(rawPublicKey: rawKey)
        == "0131DDA9654FEF86D57812B9960F260523C27A40C3A18FA8ECC7303510E78C22")
  }

  @Test
  func bonjourHostnameMatchesServerSanitizingRules() {
    #expect(BonjourBrowser.sanitizeHostLabel("Aurelia") == "Aurelia")
    #expect(BonjourBrowser.sanitizeHostLabel("  Example's   Server  ") == "Example-s-Server")
    #expect(BonjourBrowser.sanitizeHostLabel("🎬") == "device")
  }

  @Test
  func storageDraftKeepsAnIndependentNameAndLibraryType() {
    var draft = StorageLocationDraft(path: "/Volumes/Media/TV")
    #expect(draft.suggestedName == "TV")
    #expect(draft.resolvedName == nil)
    #expect(draft.kind == .automatic)

    draft.libraryName = "  Living Room Shows  "
    draft.kind = .tvShows
    #expect(draft.resolvedName == "Living Room Shows")
    #expect(draft.kind == .tvShows)
  }

  @Test
  func scanSummaryDecodesPersistentCountsAndIssues() throws {
    let scan = try JSONDecoder().decode(
      LibraryScanSummary.self,
      from: Data(
        """
        {"id":"00000000-0000-0000-0000-000000000001",
        "libraryId":"00000000-0000-0000-0000-000000000002","state":"completed",
        "createdAt":"2026-09-13T12:00:00Z","startedAt":"2026-09-13T12:00:01Z",
        "completedAt":"2026-09-13T12:00:02Z","filesDiscovered":7,"filesProcessed":7,
        "addedFiles":4,"updatedFiles":1,"missingFiles":1,"skippedFiles":1,"error":null,
        "issues":[{"code":"unreadable","message":"One folder could not be read.","path":null}]}
        """.utf8))
    #expect(scan.state == .completed)
    #expect(scan.addedFiles == 4)
    #expect(scan.missingFiles == 1)
    #expect(scan.issues.first?.code == "unreadable")
    #expect(scan.trigger == nil)
    #expect(scan.attempt == nil)
  }

  @Test
  func reliableLibraryStateDecodesAdditivelyForBuild13() throws {
    let library = try JSONDecoder().decode(
      LibrarySummary.self,
      from: Data(
        """
        {"id":"00000000-0000-0000-0000-000000000010","name":"Archive",
        "path":"/Volumes/Archive","kind":"movies","availability":"unavailable",
        "createdAt":"2026-09-15T12:00:00Z","lastScanStartedAt":null,
        "lastScanCompletedAt":null,"lastError":null,"monitoringEnabled":true,
        "lastObservedAt":"2026-09-15T12:01:00Z","health":"waitingForStorage"}
        """.utf8))
    #expect(library.isMonitoringEnabled)
    #expect(library.health == .waitingForStorage)

    let scan = try JSONDecoder().decode(
      LibraryScanSummary.self,
      from: Data(
        """
        {"id":"00000000-0000-0000-0000-000000000011",
        "libraryId":"00000000-0000-0000-0000-000000000010",
        "state":"waitingForStorage","createdAt":"2026-09-15T12:00:00Z",
        "startedAt":null,"completedAt":null,"filesDiscovered":0,"filesProcessed":0,
        "addedFiles":0,"updatedFiles":0,"missingFiles":0,"skippedFiles":0,
        "error":null,"issues":[],"trigger":"scheduled","attempt":2,
        "targetRelativePath":null}
        """.utf8))
    #expect(scan.state == .waitingForStorage)
    #expect(scan.trigger == .scheduled)
    #expect(scan.attempt == 2)

    let changes = try JSONDecoder().decode(
      SyncChangesResponse.self,
      from: Data(
        """
        {"cursor":42,"resetRequired":false,"changedAreas":["catalog","userState"],
        "changedMediaIds":["00000000-0000-0000-0000-000000000012"]}
        """.utf8))
    #expect(changes.cursor == 42)
    #expect(changes.changedAreas == [.catalog, .userState])
    #expect(changes.changedMediaIds.count == 1)
  }

  @Test
  func syncControllerStopsInBackgroundAndResumesFromItsServerCursor() async throws {
    let profile = StoredServerProfile(
      serverId: UUID(),
      name: "Sync Test",
      baseURL: URL(string: "https://sync-test.local:43111")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      token: "ephemeral-test-token",
      sessionId: UUID(),
      expiresAt: "2099-01-01T00:00:00Z")
    let fetcher = SyncFetcherProbe()
    let updates = SyncUpdateProbe()
    let controller = LibrarySyncController { profile, cursor, _, _ in
      try await fetcher.fetch(profile: profile, cursor: cursor)
    }

    await controller.start(profile: profile) { changes in
      await updates.receive(changes)
    }
    try await Task.sleep(for: .milliseconds(100))
    let initialUpdates = await updates.count
    #expect(initialUpdates == 1)

    await controller.setForeground(false, profile: profile) { changes in
      await updates.receive(changes)
    }
    let callsBeforeBackgroundWait = await fetcher.cursors
    try await Task.sleep(for: .milliseconds(50))
    let callsAfterBackgroundWait = await fetcher.cursors
    #expect(callsAfterBackgroundWait == callsBeforeBackgroundWait)

    await controller.setForeground(true, profile: profile) { changes in
      await updates.receive(changes)
    }
    try await Task.sleep(for: .milliseconds(100))
    let resumedCursors = await fetcher.cursors
    #expect(resumedCursors.contains(41))
    await controller.stop()
  }

  @Test
  func build11ServerDataMigrationIsValidatedAtomicAndNonDestructive() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AureliaMigrationTests-\(UUID().uuidString)", isDirectory: true)
    let legacy = root.appendingPathComponent("Aurelia Home Server", isDirectory: true)
    let destination = root.appendingPathComponent("Aurelia Server", isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let legacyDatabase = legacy.appendingPathComponent("aurelia-home.db")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [
      legacyDatabase.path,
      "CREATE TABLE ServerIdentity(Id INTEGER PRIMARY KEY, Value TEXT); INSERT INTO ServerIdentity VALUES(1, 'kept');",
    ]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    try Data("settings".utf8).write(to: legacy.appendingPathComponent("server-settings.json"))

    try ServerDataMigrator.migrateIfNeeded(from: legacy, to: destination)

    #expect(FileManager.default.fileExists(atPath: legacyDatabase.path))
    #expect(
      FileManager.default.fileExists(atPath: destination.appendingPathComponent("aurelia.db").path))
    #expect(
      try String(
        contentsOf: destination.appendingPathComponent("server-settings.json"), encoding: .utf8)
        == "settings")
    try ServerDataMigrator.migrateIfNeeded(from: legacy, to: destination)
  }

  @Test
  func build11ServerDataMigrationRejectsASymlinkDatabase() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "AureliaMigrationSymlinkTests-\(UUID().uuidString)", isDirectory: true)
    let legacy = root.appendingPathComponent("Aurelia Home Server", isDirectory: true)
    let destination = root.appendingPathComponent("Aurelia Server", isDirectory: true)
    let externalDatabase = root.appendingPathComponent("external.db")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try Data().write(to: externalDatabase)
    try FileManager.default.createSymbolicLink(
      at: legacy.appendingPathComponent("aurelia-home.db"),
      withDestinationURL: externalDatabase)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: ServerDataMigrationError.invalidSource) {
      try ServerDataMigrator.migrateIfNeeded(from: legacy, to: destination)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test
  func serverProfileRoundTripsThroughInMemoryStore() throws {
    let store = InMemoryServerProfileStore()
    let profile = StoredServerProfile(
      serverId: UUID(),
      name: "Test Server",
      baseURL: URL(string: "https://test.local:43111")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      token: "temporary-unit-test-token",
      sessionId: UUID(),
      expiresAt: "2099-01-01T00:00:00Z")

    #expect(try store.load() == nil)
    try store.save(profile)
    #expect(try store.load() == profile)
    try store.delete()
    #expect(try store.load() == nil)
  }

  @Test
  func buildSixProfileDecodesWithoutRoleAndCanBeUpgraded() throws {
    let json = Data(
      """
      {
        "serverId":"00000000-0000-0000-0000-000000000004",
        "name":"Existing Server",
        "baseURL":"https://server.local:43111",
        "publicKeyFingerprint":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "token":"legacy-token",
        "sessionId":"00000000-0000-0000-0000-000000000005",
        "expiresAt":"2099-01-01T00:00:00Z"
      }
      """.utf8)
    let profile = try JSONDecoder().decode(StoredServerProfile.self, from: json)
    #expect(profile.user == nil)

    let ownerJSON = Data(
      """
      {
        "id":"00000000-0000-0000-0000-000000000006",
        "username":"lucas",
        "role":"owner",
        "createdAt":"2099-01-01T00:00:00Z"
      }
      """.utf8)
    let owner = try JSONDecoder().decode(UserSummary.self, from: ownerJSON)
    #expect(owner.role.canManageLibraries)
  }

  @Test
  func nativeHostSettingsUseVersionedPortableJSON() throws {
    let settings = NativeHostSettings(
      version: 1,
      serverName: "Aurelia on Test Mac",
      lanAccessEnabled: true,
      lanHttpsPort: 44_111)
    let encoded = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(NativeHostSettings.self, from: encoded) == settings)
  }

  @Test
  func automaticStorageContractsEncodeKindAndReviewDecision() throws {
    let libraryID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    let discoveryID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
    let request = CreateLibraryRequest(
      name: nil,
      path: "/Volumes/Media",
      kind: .automatic,
      combineExisting: false)
    let requestObject = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    #expect(requestObject["kind"] as? String == "automatic")
    #expect(requestObject["name"] == nil)

    let discovery = try JSONDecoder().decode(
      LibraryDiscoverySummary.self,
      from: Data(
        """
        {
          "id":"\(discoveryID)",
          "libraryId":"\(libraryID)",
          "relativePath":"Home Videos",
          "detectedTitle":"Home Videos",
          "suggestedKind":null,
          "reason":"multiple_unmatched_videos",
          "decision":"ignore"
        }
        """.utf8))
    #expect(discovery.decision == .ignore)
    #expect(discovery.relativePath == "Home Videos")
  }

  @Test
  func nativeHostLaunchHandoffIsPIDBoundAndKeepsItsSecretInAFIFO() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("AureliaHostLaunch-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    let processID: Int32 = 12_345
    let secret = String(repeating: "S", count: 43)
    let rendezvous = root.appendingPathComponent("rendezvous.json")
    let handoff = try HostLaunchHandoff(
      secret: secret,
      directory: root,
      rendezvous: rendezvous,
      serverName: "Test Server",
      lanPort: 43_111,
      environment: [
        "AURELIA_DATA_DIR": root.appendingPathComponent("Data").path,
        "AURELIA_LOG_DIR": root.appendingPathComponent("Logs").path,
      ],
      processID: processID)

    let configurationData = try Data(contentsOf: handoff.configurationURL)
    #expect(!String(decoding: configurationData, as: UTF8.self).contains(secret))
    let description = try JSONDecoder().decode(HostLaunchDescription.self, from: configurationData)
    #expect(description.parentProcessID == processID)
    #expect(
      try HostLaunchSecurity.validate(
        description,
        expectedParentProcessID: processID,
        bootstrapDirectory: root)
        == ValidatedHostLaunchPaths(
          rendezvousURL: rendezvous.standardizedFileURL,
          pipeURL: handoff.secretPipeURL.standardizedFileURL))
    #expect(throws: HostLaunchSecurityError.invalidDescription) {
      try HostLaunchSecurity.validate(
        description,
        expectedParentProcessID: processID + 1,
        bootstrapDirectory: root)
    }

    let mode = try #require(
      fileManager.attributesOfItem(atPath: handoff.configurationURL.path)[.posixPermissions]
        as? NSNumber)
    #expect(mode.intValue & 0o777 == 0o600)
    var metadata = stat()
    #expect(lstat(handoff.secretPipeURL.path, &metadata) == 0)
    #expect(metadata.st_mode & S_IFMT == S_IFIFO)
    #expect(try HostLaunchSecurity.readSecretPipe(at: handoff.secretPipeURL.path) == secret)
    #expect(!fileManager.fileExists(atPath: handoff.secretPipeURL.path))

    handoff.remove()
    #expect(!fileManager.fileExists(atPath: handoff.configurationURL.path))
  }

  @Test
  func nativeHostLaunchValidationRejectsWrongApplicationsPathsAndNonFIFOs() throws {
    let expectedExecutable = URL(
      fileURLWithPath: "/Applications/Aurelia.app/Contents/MacOS/Aurelia")
    #expect(
      HostLaunchSecurity.acceptsApplication(
        processIdentifier: 42,
        executableURL: expectedExecutable,
        isTerminated: false,
        expectedExecutableURL: expectedExecutable))
    #expect(
      !HostLaunchSecurity.acceptsApplication(
        processIdentifier: 42,
        executableURL: URL(fileURLWithPath: "/private/tmp/Aurelia"),
        isTerminated: false,
        expectedExecutableURL: expectedExecutable))
    #expect(
      !HostLaunchSecurity.acceptsApplication(
        processIdentifier: 42,
        executableURL: expectedExecutable,
        isTerminated: true,
        expectedExecutableURL: expectedExecutable))

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AureliaHostValidation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let invalid = HostLaunchDescription(
      version: 1,
      parentProcessID: 42,
      rendezvousPath: root.appendingPathComponent("rendezvous.json").path,
      secretPipePath: root.deletingLastPathComponent().appendingPathComponent("stolen.pipe").path,
      dataDirectory: nil,
      logDirectory: nil,
      serverName: "Test",
      lanPort: 43_111)
    #expect(throws: HostLaunchSecurityError.invalidPathLocation) {
      try HostLaunchSecurity.validate(
        invalid,
        expectedParentProcessID: 42,
        bootstrapDirectory: root)
    }

    let fakePipe = root.appendingPathComponent("not-a-fifo.pipe")
    try Data("not secret transport".utf8).write(to: fakePipe)
    #expect(throws: HostLaunchSecurityError.invalidSecretPipe) {
      try HostLaunchSecurity.readSecretPipe(at: fakePipe.path)
    }

    let publicPipe = root.appendingPathComponent("public.pipe")
    #expect(mkfifo(publicPipe.path, S_IRUSR | S_IWUSR) == 0)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: publicPipe.path)
    #expect(throws: HostLaunchSecurityError.invalidSecretPipe) {
      try HostLaunchSecurity.readSecretPipe(at: publicPipe.path)
    }
    unlink(publicPipe.path)
  }

  @Test
  func nativeHostLaunchFilesRequirePrivateOwnershipTypesAndGroupLocation() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("AureliaHostFiles-\(UUID().uuidString)", isDirectory: true)
    let outside = fileManager.temporaryDirectory
      .appendingPathComponent("AureliaOutside-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    defer {
      try? fileManager.removeItem(at: root)
      try? fileManager.removeItem(at: outside)
    }

    try HostLaunchSecurity.validateBootstrapDirectory(at: root)
    #expect(throws: HostLaunchSecurityError.invalidPathLocation) {
      try HostLaunchSecurity.validateBootstrapDirectory(at: root, owner: getuid() + 1)
    }

    let configuration = root.appendingPathComponent("launch-42.json")
    try Data("{}".utf8).write(to: configuration)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)
    try HostLaunchSecurity.validateConfigurationFile(
      at: configuration.path,
      bootstrapDirectory: root)
    #expect(throws: HostLaunchSecurityError.invalidDescription) {
      try HostLaunchSecurity.validateConfigurationFile(
        at: configuration.path,
        bootstrapDirectory: root,
        owner: getuid() + 1)
    }

    try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configuration.path)
    #expect(throws: HostLaunchSecurityError.invalidDescription) {
      try HostLaunchSecurity.validateConfigurationFile(
        at: configuration.path,
        bootstrapDirectory: root)
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)

    let outsideConfiguration = outside.appendingPathComponent("launch-42.json")
    try Data("{}".utf8).write(to: outsideConfiguration)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: outsideConfiguration.path)
    #expect(throws: HostLaunchSecurityError.invalidDescription) {
      try HostLaunchSecurity.validateConfigurationFile(
        at: outsideConfiguration.path,
        bootstrapDirectory: root)
    }

    let symlink = root.appendingPathComponent("launch-symlink.json")
    try fileManager.createSymbolicLink(at: symlink, withDestinationURL: configuration)
    #expect(throws: HostLaunchSecurityError.invalidDescription) {
      try HostLaunchSecurity.validateConfigurationFile(
        at: symlink.path,
        bootstrapDirectory: root)
    }
  }

  @Test
  func serverProfileRoundTripsThroughAppOwnedKeychain() throws {
    let service = "com.lucas.aurelia.media.connection.tests.\(UUID().uuidString)"
    let store = KeychainServerStore(service: service)
    let profile = StoredServerProfile(
      serverId: UUID(),
      name: "Test Server",
      baseURL: URL(string: "https://test.local:43111")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      token: "temporary-unit-test-token",
      sessionId: UUID(),
      expiresAt: "2099-01-01T00:00:00Z")
    defer { try? store.delete() }

    try store.save(profile)
    #expect(try store.load() == profile)
    try store.delete()
    #expect(try store.load() == nil)
  }

  @Test
  func buildTenPresentationDetailDecodesEpisodesSupplementsCreditsAndProgress() throws {
    let mediaID = "10000000-0000-0000-0000-000000000001"
    let episodeID = "10000000-0000-0000-0000-000000000002"
    let extraID = "10000000-0000-0000-0000-000000000003"
    let json = Data(
      """
      {
        "item":{
          "id":"\(mediaID)","kind":"series","title":"Example Show","originalTitle":null,
          "year":2026,"overview":"A precise test.","genres":["Drama","Crime"],
          "poster":null,"backdrop":null,"availability":"available","isFavorite":true,
          "progress":null,"addedAt":"2026-09-12T08:00:00Z"
        },
        "metadata":{
          "mediaId":"\(mediaID)","title":"Example Show","originalTitle":null,
          "overview":"A precise test.","releaseDate":"2026-09-12","year":2026,
          "runtimeMinutes":null,"rating":8.4,"contentRating":"TV-MA",
          "genres":["Drama","Crime"],"studios":["Aurelia"],"countries":["DE"],
          "credits":[{"name":"Actor","department":"Acting","job":null,"character":"Lead","order":0,"profile":null}],
          "poster":null,"backdrop":null,"still":null,"provider":"tmdb",
          "providerMediaId":"42","reviewState":"matched"
        },
        "seasons":[{
          "number":1,
          "episodes":[{
            "item":{"id":"\(episodeID)","kind":"episode","title":"Pilot","originalTitle":null,
              "year":2026,"overview":"Episode overview","genres":[],"poster":null,"backdrop":null,
              "availability":"available","isFavorite":false,
              "progress":{"mediaId":"\(episodeID)","positionMilliseconds":30000,
                "durationMilliseconds":60000,"isCompleted":false,"lastPlayedAt":null,"updatedAt":null},
              "addedAt":"2026-09-12T08:00:00Z"},
            "seasonNumber":1,"episodeNumber":1
          }],
          "supplements":[]
        }],
        "supplements":[{
          "item":{"id":"\(extraID)","kind":"extra","title":"Behind the Scenes","originalTitle":null,
            "year":2026,"overview":null,"genres":[],"poster":null,"backdrop":null,
            "availability":"missing","isFavorite":false,"progress":null,
            "addedAt":"2026-09-12T08:00:00Z"},
          "category":"Extras","seasonNumber":null
        }]
      }
      """.utf8)
    let detail = try JSONDecoder().decode(CatalogDetailPresentation.self, from: json)
    #expect(detail.seasons.first?.episodes.first?.item.progressFraction == 0.5)
    #expect(detail.supplements.first?.item.availability == .missing)
    #expect(detail.metadata.credits.first?.character == "Lead")
  }

  @Test
  func homeGenreRowsAreStableLimitedAndNeverEmpty() {
    let first = presentationItem(
      id: "10000000-0000-0000-0000-000000000011",
      title: "First",
      genres: ["Drama", "Crime", "Drama"])
    let second = presentationItem(
      id: "10000000-0000-0000-0000-000000000012",
      title: "Second",
      genres: ["Fantasy", "Comedy", " "])
    let rows = HomePresentationLogic.genreRows(from: [first, second])
    #expect(rows.map(\.title) == ["Comedy", "Crime", "Drama"])
    #expect(rows.allSatisfy { !$0.items.isEmpty })
    #expect(rows.last?.items.count == 1)
    #expect(HomePresentationLogic.genreRows(from: [], limit: 3).isEmpty)
  }

  @Test
  func homeRefreshPolicyUsesTheExactServerBoundary() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let boundary = ISO8601DateFormatter().string(from: now.addingTimeInterval(1_800))
    #expect(HomeRefreshPolicy.delay(until: boundary, now: now) == 1_800)
    #expect(HomeRefreshPolicy.delay(until: "invalid", now: now) == nil)
  }

  @Test
  func queryEncodingCannotInjectAdditionalParameters() throws {
    #expect(
      try APIClient.query(name: "query", value: "crime & drama? +")
        == "query=crime%20%26%20drama%3F%20%2B")
  }

  @Test @MainActor
  func artworkLoaderCoalescesRequestsCachesInMemoryAndScopesServers() async throws {
    let counter = ArtworkFetchCounter()
    let loader = ArtworkLoader(memoryLimit: 1_024, itemLimit: 4) { _, _ in
      await counter.increment()
      try await Task.sleep(for: .milliseconds(40))
      return Data([1, 2, 3])
    }
    let artwork = ArtworkSummary(
      id: UUID(uuidString: "10000000-0000-0000-0000-000000000099")!,
      kind: .poster,
      path: "/api/v1/artwork/10000000-0000-0000-0000-000000000099",
      contentType: "image/jpeg",
      contentLength: 3)
    let firstProfile = artworkProfile(serverID: "20000000-0000-0000-0000-000000000001")
    let secondProfile = artworkProfile(serverID: "20000000-0000-0000-0000-000000000002")

    async let first = loader.data(for: artwork, profile: firstProfile)
    async let second = loader.data(for: artwork, profile: firstProfile)
    let values = try await (first, second)
    #expect(values.0 == Data([1, 2, 3]))
    #expect(values.1 == Data([1, 2, 3]))
    #expect(await counter.value == 1)

    _ = try await loader.data(for: artwork, profile: firstProfile)
    #expect(await counter.value == 1)
    _ = try await loader.data(for: artwork, profile: secondProfile)
    #expect(await counter.value == 2)
  }

  @Test @MainActor
  func artworkLoaderRejectsForeignAndDecoratedPathsBeforeFetching() async {
    let counter = ArtworkFetchCounter()
    let loader = ArtworkLoader { _, _ in
      await counter.increment()
      return Data()
    }
    let profile = artworkProfile(serverID: "20000000-0000-0000-0000-000000000001")
    for path in [
      "https://attacker.invalid/api/v1/artwork/10000000-0000-0000-0000-000000000099",
      "/api/v1/artwork/10000000-0000-0000-0000-000000000099?token=leak",
      "/api/v1/artwork/not-a-uuid",
    ] {
      let artwork = ArtworkSummary(
        id: UUID(), kind: .poster, path: path, contentType: "image/jpeg", contentLength: 1)
      await #expect(throws: APIClientError.invalidResponse) {
        try await loader.data(for: artwork, profile: profile)
      }
    }
    #expect(await counter.value == 0)
  }

  private func presentationItem(id: String, title: String, genres: [String])
    -> CatalogItemSummary
  {
    CatalogItemSummary(
      id: UUID(uuidString: id)!, kind: .movie, title: title, originalTitle: nil,
      year: 2026, overview: nil, genres: genres, poster: nil, backdrop: nil,
      availability: .available, isFavorite: false, progress: nil,
      addedAt: "2026-09-12T08:00:00Z")
  }

  private func artworkProfile(serverID: String) -> StoredServerProfile {
    StoredServerProfile(
      serverId: UUID(uuidString: serverID)!, name: "Test",
      baseURL: URL(string: "https://server.local:43111")!,
      publicKeyFingerprint: String(repeating: "A", count: 64), token: "test-token",
      sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z")
  }
}

private actor SyncFetcherProbe {
  private(set) var cursors: [Int64] = []

  func fetch(profile: StoredServerProfile, cursor: Int64) async throws -> SyncChangesResponse {
    _ = profile
    cursors.append(cursor)
    if cursors.count == 1 {
      return SyncChangesResponse(
        cursor: 41,
        resetRequired: false,
        changedAreas: [.catalog],
        changedMediaIds: [])
    }
    try await Task.sleep(for: .seconds(60))
    return SyncChangesResponse(
      cursor: cursor,
      resetRequired: false,
      changedAreas: [],
      changedMediaIds: [])
  }
}

private actor SyncUpdateProbe {
  private(set) var count = 0

  func receive(_ changes: SyncChangesResponse) {
    _ = changes
    count += 1
  }
}

private actor ArtworkFetchCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}
