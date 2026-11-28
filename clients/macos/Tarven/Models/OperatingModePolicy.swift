import Foundation

enum NativeHostStartupError: LocalizedError {
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .failed(let message): message
    }
  }
}

enum OperatingModePolicy {
  static let selectionVersion = 1

  static func resolve(
    storedMode: OperatingMode?,
    storedSelectionVersion: Int,
    profile: StoredServerProfile?
  ) -> OperatingMode? {
    // Connection ownership survives a stale or missing mode preference. An ordinary
    // loopback client remains a client until local hosting is explicitly restored.
    if let profile, profile.locallyManaged == true, isLocal(profile.baseURL) {
      return .host
    }
    if storedSelectionVersion >= selectionVersion, let storedMode {
      return storedMode
    }
    if let profile, !isLocal(profile.baseURL) {
      return .client
    }
    if profile == nil, storedMode == nil {
      return nil
    }
    return .host
  }

  static func isLocal(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
  }

  static func validateLocalHost(_ snapshot: NativeHostSnapshot, profile: StoredServerProfile) throws
  {
    guard isLocal(profile.baseURL), snapshot.state == .running,
      let info = snapshot.serverInfo, info.isSetup,
      info.serverId == profile.serverId,
      info.publicKeyFingerprint?.caseInsensitiveCompare(profile.publicKeyFingerprint)
        == .orderedSame
    else { throw APIClientError.serverIdentityMismatch }
  }

  static func isAwaitingReadiness(_ state: NativeHostState) -> Bool {
    state == .starting || state == .restarting
  }
}
