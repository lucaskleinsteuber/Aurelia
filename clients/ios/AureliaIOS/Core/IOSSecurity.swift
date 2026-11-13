import CryptoKit
import Foundation

// Security on iPhone and iPad ("security-v1"): the log, signed-in devices, the block list and
// Face ID / Touch ID for server management. The private key lives in the Secure Enclave
// (IOSSecureEnclaveSigner in App); this file holds what tests can check with a software key.

struct IOSSecurityEvent: Codable, Identifiable, Equatable, Sendable {
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

struct IOSSecurityEventPage: Codable, Equatable, Sendable {
  let events: [IOSSecurityEvent]
  let before: String?
}

struct IOSSecurityDevice: Codable, Identifiable, Equatable, Sendable {
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

struct IOSBlockedDevice: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let deviceName: String
  let platform: String?
  let ipAddress: String?
  let blockedAt: String
}

struct IOSSecuritySettings: Codable, Equatable, Sendable {
  var securityLogDays: Int
  var requirePasskeysForAdministrators: Bool
  var passkeyCount: Int? = nil
}

struct IOSRemoteUnlockRequest: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let profileName: String
  let deviceName: String
  let ipAddress: String?
  let code: String
  let expiresAt: String
}

struct IOSSecurityAlerts: Codable, Equatable, Sendable {
  let version: Int64
  let newDevices: [IOSSecurityDevice]
  let unlockRequests: [IOSRemoteUnlockRequest]
}

struct IOSPasskey: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let userId: UUID
  let userName: String
  let name: String
  let createdAt: String
  let lastUsedAt: String?
  let isThisDevice: Bool
}

struct IOSBlockResult: Codable, Equatable, Sendable {
  let listed: Bool
  let signedOut: Int
}

/// Signs with a P-256 key: the Secure Enclave's on a device, a software key in tests.
protocol IOSPasskeySigner: Sendable {
  /// The public key as X9.63 (65 bytes).
  var publicKey: Data { get }
  /// A DER signature over the message, after Face ID or Touch ID where the key needs it.
  func sign(_ message: Data) async throws -> Data
}

/// A software key for tests and previews; never used for a real server.
struct IOSSoftwarePasskeySigner: IOSPasskeySigner {
  let key: P256.Signing.PrivateKey
  init(key: P256.Signing.PrivateKey = .init()) { self.key = key }
  var publicKey: Data { key.publicKey.x963Representation }
  func sign(_ message: Data) async throws -> Data { try key.signature(for: message).derRepresentation }
}

enum IOSPasskeyMessage {
  /// The words the server checks: purpose and challenge, so a signature fits nothing else.
  static func data(purpose: String, challenge: String) -> Data {
    Data("aurelia-passkey-v1|\(purpose)|\(challenge)".utf8)
  }
  static func remotePurpose(_ id: UUID) -> String {
    "remote:" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }
}

/// This app's own random identifier, sent as `X-Aurelia-Installation` so the owner can tell its
/// devices apart and block one. It identifies an installation, not a person.
enum IOSInstallation {
  static let defaultsKey = "AureliaIOSInstallationId"

  static func identifier(defaults: UserDefaults = .standard) -> String {
    if let saved = defaults.string(forKey: defaultsKey), UUID(uuidString: saved) != nil { return saved }
    let created = UUID().uuidString
    defaults.set(created, forKey: defaultsKey)
    return created
  }

  /// "ios/2.11.0".
  static var clientHeader: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    return "ios/" + version.filter { $0.isNumber || $0 == "." }
  }
}

/// Words for the security log, the same on every Aurelia app.
enum IOSSecurityText {
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

  static func symbol(_ outcome: String) -> String {
    switch outcome {
    case "failed": "exclamationmark.triangle.fill"
    case "succeeded": "person.badge.key"
    default: "slider.horizontal.3"
    }
  }

  /// "Safari on iPhone · 192.168.1.40", the line under a device's name.
  static func deviceLine(platform: String?, ipAddress: String?) -> String {
    [platform, ipAddress].compactMap { $0 }.joined(separator: " · ")
  }
}
