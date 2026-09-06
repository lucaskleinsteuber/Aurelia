import Foundation
import XCTest

@testable import AureliaHome

final class AureliaHomeIntegrationTests: XCTestCase {
  func testLiveServerInspectionPairingCatalogAndLogout() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let address = environment["AURELIA_HOME_TEST_SERVER_URL"],
      let pairingCode = environment["AURELIA_HOME_TEST_PAIRING_CODE"],
      let expectedFingerprint = environment["AURELIA_HOME_TEST_SERVER_FINGERPRINT"]
    else {
      throw XCTSkip("Live server variables were not supplied.")
    }

    let baseURL = try APIClient.normalizedServerURL(address)
    let inspected = try await APIClient.inspect(baseURL: baseURL)
    XCTAssertEqual(inspected.publicKeyFingerprint, expectedFingerprint)

    let wrongIdentity = StoredServerProfile(
      serverId: inspected.info.serverId,
      name: inspected.info.name,
      baseURL: inspected.baseURL,
      publicKeyFingerprint: String(repeating: "0", count: 64),
      token: "not-used",
      sessionId: UUID(),
      expiresAt: "2099-01-01T00:00:00Z")
    do {
      _ = try await APIClient(profile: wrongIdentity).serverInfo()
      XCTFail("A mismatched pinned identity must be rejected.")
    } catch {
      // Expected: URLSession cancels the TLS challenge before any API data is accepted.
    }

    let profile = try await APIClient.pair(
      inspected: inspected,
      code: pairingCode,
      deviceName: "Build 4 Integration Test")
    let client = APIClient(profile: profile)
    async let movies = client.movies()
    async let series = client.series()
    _ = try await (movies, series)
    try await client.logout()
  }
}
