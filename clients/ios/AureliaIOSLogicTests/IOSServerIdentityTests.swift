import Foundation
import Testing

@Suite("iOS Server Identity and Address Tests")
struct IOSServerIdentityTests {
  @Test func normalizeAddressDefaultsToHTTPSAnd43111() throws {
    let url = try IOSServerAddress.normalize("server.local")
    #expect(url.absoluteString == "https://server.local:43111")
  }

  @Test func normalizePreservesCustomPort() throws {
    let url = try IOSServerAddress.normalize("https://server.local:8443/")
    #expect(url.port == 8443)
    #expect(url.scheme == "https")
  }

  @Test func rejectInsecureOrInvalidAddresses() {
    #expect(throws: IOSError.self) {
      try IOSServerAddress.normalize("http://server.local")
    }
    #expect(throws: IOSError.self) {
      try IOSServerAddress.normalize("https://user:pass@server.local")
    }
    #expect(throws: IOSError.self) {
      try IOSServerAddress.normalize("https://server.local/path")
    }
  }

  @Test func validFingerprintCheck() {
    let validHex = String(repeating: "a1b2C3D4", count: 8)
    #expect(IOSServerIdentity.isValidFingerprint(validHex))
    #expect(!IOSServerIdentity.isValidFingerprint("tooShort"))
    #expect(!IOSServerIdentity.isValidFingerprint(String(repeating: "G", count: 64)))
  }

  @Test func storedConnectionValidation() throws {
    let validFP = String(repeating: "A", count: 64)
    let conn = IOSStoredConnection(
      serverId: UUID(),
      serverName: "Test Server",
      baseURL: URL(string: "https://192.168.1.100:43111")!,
      fingerprint: validFP
    )
    #expect(throws: Never.self) {
      try conn.validate()
    }

    let invalidConn = IOSStoredConnection(
      serverId: UUID(),
      serverName: "Invalid",
      baseURL: URL(string: "http://insecure.local")!,
      fingerprint: "short"
    )
    #expect(throws: IOSError.self) {
      try invalidConn.validate()
    }
  }
}
