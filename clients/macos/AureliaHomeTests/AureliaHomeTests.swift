import Foundation
import Testing

@testable import AureliaHome

struct AureliaHomeTests {
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
  }

  @Test
  func serverAddressDefaultsToSecureLanPort() throws {
    let url = try APIClient.normalizedServerURL("192.168.1.20")
    #expect(url.absoluteString == "https://192.168.1.20:43111")
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
      "GET /stream/\(secret) HTTP/1.1\r\nHost: 127.0.0.1:54321\r\nRange: bytes=10-20\r\nIf-Range: test-etag\r\n\r\n".utf8)
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
    #expect(BonjourBrowser.sanitizeHostLabel("Aurelia Home") == "Aurelia-Home")
    #expect(BonjourBrowser.sanitizeHostLabel("  Lucas's   Server  ") == "Lucas-s-Server")
    #expect(BonjourBrowser.sanitizeHostLabel("🎬") == "device")
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
      serverName: "Aurelia Home on Test Mac",
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
      .appendingPathComponent("AureliaHomeHostLaunch-\(UUID().uuidString)", isDirectory: true)
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
        "AURELIA_HOME_DATA_DIR": root.appendingPathComponent("Data").path,
        "AURELIA_HOME_LOG_DIR": root.appendingPathComponent("Logs").path,
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
    let expectedExecutable = URL(fileURLWithPath: "/Applications/Aurelia Home.app/Contents/MacOS/AureliaHome")
    #expect(
      HostLaunchSecurity.acceptsApplication(
        processIdentifier: 42,
        executableURL: expectedExecutable,
        isTerminated: false,
        expectedExecutableURL: expectedExecutable))
    #expect(
      !HostLaunchSecurity.acceptsApplication(
        processIdentifier: 42,
        executableURL: URL(fileURLWithPath: "/private/tmp/AureliaHome"),
        isTerminated: false,
        expectedExecutableURL: expectedExecutable))
    #expect(
      !HostLaunchSecurity.acceptsApplication(
        processIdentifier: 42,
        executableURL: expectedExecutable,
        isTerminated: true,
        expectedExecutableURL: expectedExecutable))

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AureliaHomeHostValidation-\(UUID().uuidString)", isDirectory: true)
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
    #expect(throws: HostLaunchSecurityError.invalidDescription) {
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
  }

  @Test
  func serverProfileRoundTripsThroughAppOwnedKeychain() throws {
    let service = "com.lucas.aureliahome.connection.tests.\(UUID().uuidString)"
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
}
