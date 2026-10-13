import Foundation
import Testing

@testable import Aurelia

struct ProfileProtocolTests {
  @Test func serverRenameAndNewAccessRevisionDoNotRetireAnUnlockedSession() {
    let user = UserSummary(
      id: UUID(), username: "Synthetic", role: .admin, createdAt: "2026-01-01T00:00:00Z",
      accessMode: .entireLibrary)
    let original = StoredServerProfile(
      serverId: UUID(), name: "Previous server name",
      baseURL: URL(string: "https://fixture.invalid")!,
      publicKeyFingerprint: String(repeating: "A", count: 64), token: "synthetic-only-token",
      sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z", user: user, viewingSession: true)
    let updatedUser = UserSummary(
      id: user.id, username: user.username, role: .admin,
      createdAt: user.createdAt, accessMode: .selectedTitles, profileRevision: 4)
    let refreshed = StoredServerProfile(
      serverId: original.serverId, name: "Current server name", baseURL: original.baseURL,
      publicKeyFingerprint: original.publicKeyFingerprint, token: original.token,
      sessionId: original.sessionId,
      expiresAt: original.expiresAt, user: updatedUser, viewingSession: true)
    #expect(original != refreshed)
    #expect(ProfilePickerProtocol.isSameSession(refreshed, as: original))
    let replacement = StoredServerProfile(
      serverId: original.serverId, name: refreshed.name, baseURL: original.baseURL,
      publicKeyFingerprint: original.publicKeyFingerprint, token: "replacement-session",
      sessionId: UUID(),
      expiresAt: original.expiresAt, user: updatedUser, viewingSession: true)
    #expect(!ProfilePickerProtocol.isSameSession(replacement, as: original))
  }
  @Test(arguments: [1, 2])
  func supportedPickerFormatsDecodeWithoutAnInvalidResponse(version: Int) throws {
    let response = try JSONDecoder().decode(
      ProfilePickerResponse.self,
      from: Data(
        "{\"formatVersion\":\(version),\"minimumClientVersion\":\"1.5.1\",\"managementSetupRequired\":false,\"profiles\":[]}"
          .utf8))
    try ProfilePickerProtocol.validate(formatVersion: response.formatVersion)
  }

  @Test(arguments: [0, 3, -1])
  func unknownProfileProtocolHasAnUpdateMessageNotAnInvalidResponse(version: Int) {
    do {
      try ProfilePickerProtocol.validate(formatVersion: version)
      Issue.record("Unsupported profile protocols must not unlock data.")
    } catch let failure as APIClientError {
      #expect(failure.problemCode == "unsupported_profile_protocol")
      #expect(failure != .invalidResponse)
    } catch { Issue.record("Unexpected error type.") }
  }
}
