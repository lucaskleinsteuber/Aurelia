import Foundation

enum OperatingModePolicy {
  static let selectionVersion = 1

  static func resolve(
    storedMode: OperatingMode?,
    storedSelectionVersion: Int,
    profile: StoredServerProfile?
  ) -> OperatingMode {
    if storedSelectionVersion >= selectionVersion, let storedMode {
      return storedMode
    }
    if let profile, !isLocal(profile.baseURL) {
      return .client
    }
    return .host
  }

  static func isLocal(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "127.0.0.1" || host == "localhost" || host == "::1"
  }
}
