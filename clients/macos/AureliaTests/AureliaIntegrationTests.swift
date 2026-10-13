import Foundation
import XCTest

@testable import Aurelia

final class AureliaIntegrationTests: XCTestCase {
  func testLiveServerInspectionPairingCatalogAndLogout() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let address = environment["AURELIA_TEST_SERVER_URL"],
      let pairingCode = environment["AURELIA_TEST_PAIRING_CODE"],
      let expectedFingerprint = environment["AURELIA_TEST_SERVER_FINGERPRINT"],
      let pin = environment["AURELIA_TEST_PROFILE_PIN"], ProfilePIN.isValid(pin)
    else {
      throw XCTSkip("Isolated live-server variables and a valid profile PIN were not supplied.")
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

    let device = try await APIClient.pair(
      inspected: inspected,
      code: pairingCode,
      deviceName: "Synthetic Integration Test")
    let paired = APIClient(profile: device)
    var viewing: StoredServerProfile?
    do {
      do {
        _ = try await paired.movies()
        XCTFail("A paired device must not read the catalog before PIN unlock.")
      } catch let error as APIClientError {
        XCTAssertEqual(error.httpStatus, 403)
      }
      let profileID =
        environment["AURELIA_TEST_PROFILE_ID"].flatMap(UUID.init(uuidString:))
        ?? device.user?.id
      let selectedID = try XCTUnwrap(profileID, "The isolated profile identity is required.")
      let unlocked = try await paired.unlockProfile(id: selectedID, pin: pin)
      XCTAssertEqual(unlocked.user.id, selectedID)
      let profile = StoredServerProfile(
        serverId: device.serverId, name: device.name, baseURL: device.baseURL,
        publicKeyFingerprint: device.publicKeyFingerprint, token: unlocked.token,
        sessionId: unlocked.sessionId, expiresAt: unlocked.expiresAt, user: unlocked.user,
        viewingSession: true)
      viewing = profile
      let client = APIClient(profile: profile)
      try await verifyCatalogAndPlayback(client: client, profile: profile)
      try await client.logout()
      do {
        _ = try await client.currentUser()
        XCTFail("Ending a viewing session must retire its token.")
      } catch let error as APIClientError {
        XCTAssertEqual(error.httpStatus, 401)
      }
      _ = try await paired.watchingProfiles()
      try await paired.disconnectPairedDevice()
    } catch {
      if let viewing { try? await APIClient(profile: viewing).endProfileSession() }
      try? await paired.disconnectPairedDevice()
      throw error
    }
  }

  private func verifyCatalogAndPlayback(client: APIClient, profile: StoredServerProfile)
    async throws
  {
    async let moviesRequest = client.movies()
    async let seriesRequest = client.series()
    let (movies, _) = try await (moviesRequest, seriesRequest)
    if let movie = movies.first(where: { $0.availability == .available }) {
      let playback = try await client.createPlayback(mediaId: movie.id)
      XCTAssertEqual(playback.mediaId, movie.id)
      let relay = try LoopbackStreamRelay(
        sourceURL: client.streamURL(path: playback.streamPath),
        publicKeyFingerprint: profile.publicKeyFingerprint,
        authorizationToken: profile.token)
      let localURL = try await relay.start()
      var rangeRequest = URLRequest(url: localURL)
      rangeRequest.setValue("bytes=0-7", forHTTPHeaderField: "Range")
      let (bytes, response) = try await URLSession.shared.data(for: rangeRequest)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
      XCTAssertEqual(bytes.count, 8)
      relay.stop()

      let stored = try await client.updatePlaybackProgress(
        mediaId: movie.id,
        positionMilliseconds: 20_000,
        durationMilliseconds: 120_000,
        isFinished: false)
      XCTAssertEqual(stored.positionMilliseconds, 20_000)
      let loadedProgress = try await client.playbackProgress(mediaId: movie.id)
      XCTAssertEqual(loadedProgress, stored)
      try await client.revokePlayback(id: playback.id)
    }
  }
}
