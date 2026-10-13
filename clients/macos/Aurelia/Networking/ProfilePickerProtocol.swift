import Foundation

enum ProfilePickerProtocol {
  /// Display names and revisions can change during the first catalog snapshot.
  /// They must not make a successfully unlocked session look superseded.
  static func isSameSession(_ current: StoredServerProfile?, as expected: StoredServerProfile)
    -> Bool
  {
    guard let current else { return false }
    return current.serverId == expected.serverId && current.sessionId == expected.sessionId
      && current.token == expected.token && current.user?.id == expected.user?.id
      && current.baseURL == expected.baseURL
      && current.publicKeyFingerprint == expected.publicKeyFingerprint
      && current.isViewingSession == expected.isViewingSession
  }
  static func validate(formatVersion: Int) throws {
    guard formatVersion == 1 || formatVersion == 2 else {
      throw APIClientError.serverRejected(
        code: "unsupported_profile_protocol",
        message:
          "This server uses an unsupported profile format. Update Aurelia to connect. Your device connection has been retained."
      )
    }
  }
}
