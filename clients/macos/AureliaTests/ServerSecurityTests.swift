import CryptoKit
import XCTest

@testable import Aurelia

/// Touch ID signatures and the security log's models ("security-v1", docs/SECURITY_MODEL.md).
final class ServerSecurityTests: XCTestCase {
  func testPasskeyMessageBindsPurposeAndChallenge() {
    let message = PasskeyMessage.data(purpose: "unlock", challenge: "abc")
    XCTAssertEqual(String(decoding: message, as: UTF8.self), "aurelia-passkey-v1|unlock|abc")
    let id = UUID(uuidString: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")!
    XCTAssertEqual(PasskeyMessage.remotePurpose(id), "remote:0a1b2c3d4e5f60718293a4b5c6d7e8f9")
  }

  func testSoftwareSignerProducesVerifiableDERSignatureOffTheMainActor() async throws {
    let signer = SoftwarePasskeySigner()
    XCTAssertEqual(signer.publicKey.count, 65)
    let message = PasskeyMessage.data(purpose: "register", challenge: "nonce")
    // Signing runs from a background task, as the real Touch ID key's does.
    let signature = try await Task.detached { try await signer.sign(message) }.value
    let key = try P256.Signing.PublicKey(x963Representation: signer.publicKey)
    XCTAssertTrue(key.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: signature), for: message))
    let other = PasskeyMessage.data(purpose: "unlock", challenge: "nonce")
    XCTAssertFalse(key.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: signature), for: other))
  }

  func testAlertsAndEventsDecodeWithUnknownKinds() throws {
    let json = Data(
      """
      {"version":7,"newDevices":[{"id":"6F1D2A40-0000-4000-8000-000000000001","userId":"6F1D2A40-0000-4000-8000-000000000002",
      "userName":"Owner","deviceName":"Synthetic Phone","platform":"iOS","clientVersion":"2.11.0","ipAddress":"192.0.2.40",
      "createdAt":"2026-11-13T10:00:00Z","lastSeenAt":"2026-11-13T10:01:00Z","isNew":true,"canBlock":true,"isCurrent":false}],
      "unlockRequests":[{"id":"6F1D2A40-0000-4000-8000-000000000003","profileName":"Owner","deviceName":"Browser",
      "ipAddress":null,"code":"1234","expiresAt":"2026-11-13T10:05:00Z"}]}
      """.utf8)
    let alerts = try JSONDecoder().decode(ServerSecurityAlerts.self, from: json)
    XCTAssertEqual(alerts.version, 7)
    XCTAssertEqual(alerts.newDevices.first?.deviceName, "Synthetic Phone")
    XCTAssertEqual(alerts.unlockRequests.first?.code, "1234")
    XCTAssertEqual(SecurityText.kind("library_removed"), "Storage location removed")
    XCTAssertEqual(SecurityText.kind("something_new"), "Something New")
    XCTAssertEqual(SecurityText.deviceLine(platform: "iOS", ipAddress: "192.0.2.40"), "iOS · 192.0.2.40")
    XCTAssertEqual(SecurityText.deviceLine(platform: nil, ipAddress: nil), "")
  }

  func testInstallationIdIsStableAndClientHeaderNamesTheMac() {
    let suite = "ServerSecurityTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = AureliaInstallation.identifier(defaults: defaults)
    XCTAssertNotNil(UUID(uuidString: first))
    XCTAssertEqual(first, AureliaInstallation.identifier(defaults: defaults))
    XCTAssertTrue(AureliaInstallation.clientHeader.hasPrefix("macos/"))
  }
}
