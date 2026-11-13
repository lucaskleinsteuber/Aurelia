import Foundation

// Security ("security-v1"): the log, signed-in devices, the block list and Touch ID for server
// management. Copies of the server's SecurityContracts.cs; unknown kinds are shown, not refused.

struct ServerSecurityEvent: Decodable, Identifiable, Sendable {
  let id: UUID
  let at: String
  let kind: String
  let outcome: String
  let userId: UUID?
  let userName: String?
  let deviceSessionId: UUID?
  let deviceName: String?
  let platform: String?
  let ipAddress: String?
  let detail: String?
}

struct ServerSecurityEventPage: Decodable, Sendable {
  let events: [ServerSecurityEvent]
  let before: String?
}

struct ServerSecurityDevice: Decodable, Identifiable, Equatable, Sendable {
  let id: UUID
  let userId: UUID
  let userName: String
  let deviceName: String
  let platform: String?
  let clientVersion: String?
  let ipAddress: String?
  let createdAt: String
  let lastSeenAt: String
  let isNew: Bool
  let canBlock: Bool
  let isCurrent: Bool
}

struct ServerBlockedDevice: Decodable, Identifiable, Sendable {
  let id: UUID
  let deviceName: String
  let platform: String?
  let ipAddress: String?
  let blockedAt: String
}

struct ServerSecuritySettings: Codable, Equatable, Sendable {
  var securityLogDays: Int
  var requirePasskeysForAdministrators: Bool
  var passkeyCount: Int? = nil
}

struct ServerRemoteUnlockRequest: Decodable, Identifiable, Equatable, Sendable {
  let id: UUID
  let profileName: String
  let deviceName: String
  let ipAddress: String?
  let code: String
  let expiresAt: String
}

struct ServerSecurityAlerts: Decodable, Sendable {
  let version: Int64
  let newDevices: [ServerSecurityDevice]
  let unlockRequests: [ServerRemoteUnlockRequest]
}

struct ServerPasskey: Decodable, Identifiable, Sendable {
  let id: UUID
  let userId: UUID
  let userName: String
  let name: String
  let createdAt: String
  let lastUsedAt: String?
  let isThisDevice: Bool
}

struct ServerBlockResult: Decodable, Sendable {
  let listed: Bool
  let signedOut: Int
}

enum PasskeyMessage {
  /// The words the server checks: purpose and challenge, so a signature fits nothing else.
  static func data(purpose: String, challenge: String) -> Data {
    Data("aurelia-passkey-v1|\(purpose)|\(challenge)".utf8)
  }
  static func remotePurpose(_ id: UUID) -> String {
    "remote:" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }
}

/// Words for the security log, the same on every Aurelia app.
enum SecurityText {
  static func kind(_ kind: String) -> String {
    switch kind {
    case "signed_in": "Signed in"
    case "profile_opened": "Opened profile"
    case "management_unlocked": "Unlocked management"
    case "wrong_password": "Wrong Server Password"
    case "wrong_pin": "Wrong profile PIN"
    case "wrong_code": "Wrong device code"
    case "locked_out": "Paused after wrong attempts"
    case "blocked_device_refused": "Blocked device refused"
    case "passkey_failed": "Face ID or Touch ID not confirmed"
    case "password_refused": "Server Password refused (Face ID required)"
    case "library_added": "Storage location added"
    case "library_removed": "Storage location removed"
    case "library_reset": "Library reset"
    case "title_removed": "Title removed"
    case "profile_created": "Profile created"
    case "profile_changed": "Profile changed"
    case "profile_deleted": "Profile deleted"
    case "pin_reset": "PIN replaced"
    case "password_reset": "Password replaced"
    case "role_changed": "Role changed"
    case "screen_time_changed": "Screen time changed"
    case "devices_signed_out": "Devices signed out"
    case "device_signed_out": "Device signed out"
    case "device_code_created": "Device code created"
    case "device_approved": "Device allowed"
    case "device_blocked": "Device blocked"
    case "device_unblocked": "Device unblocked"
    case "settings_changed": "Server settings changed"
    case "network_changed": "Network changed"
    case "server_restarted": "Server restarted"
    case "power_changed": "Power settings changed"
    case "backup_restored": "Backup restored"
    case "backup_exported": "Encrypted backup saved"
    case "update_installed": "Server update installed"
    case "metadata_changed": "Metadata settings changed"
    case "passkey_added": "Face ID or Touch ID set up"
    case "passkey_removed": "Face ID or Touch ID removed"
    case "passkey_requirement_changed": "Face ID requirement changed"
    case "security_settings_changed": "Security settings changed"
    case "remote_unlock_approved": "Unlock confirmed for another device"
    case "remote_unlock_denied": "Unlock denied for another device"
    default: kind.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }

  static func deviceLine(platform: String?, ipAddress: String?) -> String {
    [platform, ipAddress].compactMap { $0 }.joined(separator: " · ")
  }
}
