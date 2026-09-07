import Foundation
import Testing

@testable import AureliaHome

struct AureliaHomeTests {
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
