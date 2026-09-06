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
  func serverInformationDecodesBuildFourIdentity() throws {
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
  func serverProfileRoundTripsThroughKeychain() throws {
    let service = "com.lucas.aureliahome.tests.\(UUID().uuidString)"
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
