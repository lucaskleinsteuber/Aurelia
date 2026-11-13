import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Signs with a P-256 key: the Secure Enclave's on this Mac, a software key in tests.
protocol PasskeySigner: Sendable {
  /// The public key as X9.63 (65 bytes).
  var publicKey: Data { get }
  /// A DER signature over the message, after Touch ID where the key needs it.
  func sign(_ message: Data) async throws -> Data
}

/// A software key for tests; never used for a real server.
struct SoftwarePasskeySigner: PasskeySigner {
  let key: P256.Signing.PrivateKey
  init(key: P256.Signing.PrivateKey = .init()) { self.key = key }
  var publicKey: Data { key.publicKey.x963Representation }
  func sign(_ message: Data) async throws -> Data { try key.signature(for: message).derRepresentation }
}

/// A P-256 key in this Mac's Secure Enclave, usable only after Touch ID or the login password.
/// Only an encrypted reference to it is stored; the private key never leaves the chip.
///
/// Queue contract: `sign` runs the blocking CryptoKit call (which shows the Touch ID sheet) on a
/// detached task, never on the main actor; only Sendable values cross it.
struct SecureEnclavePasskeySigner: PasskeySigner {
  let keyReference: Data
  let publicKey: Data

  static var isAvailable: Bool { SecureEnclave.isAvailable }

  static func create() throws -> SecureEnclavePasskeySigner {
    var error: Unmanaged<CFError>?
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &error)
    else { throw APIClientError.serverRejected(code: "passkey_unavailable", message: "This Mac can't keep a Touch ID key.") }
    let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
    return SecureEnclavePasskeySigner(keyReference: key.dataRepresentation, publicKey: key.publicKey.x963Representation)
  }

  func sign(_ message: Data) async throws -> Data {
    let reference = keyReference
    return try await Task.detached(priority: .userInitiated) { () throws -> Data in
      let context = LAContext()
      context.localizedReason = "confirm the change on your Aurelia server"
      let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: reference, authenticationContext: context)
      return try key.signature(for: message).derRepresentation
    }.value
  }
}

/// The key reference for one profile on one server, in this Mac's Keychain only.
struct StoredPasskey: Codable, Equatable, Sendable {
  let passkeyId: UUID
  let keyReference: Data
  let publicKey: Data

  var signer: SecureEnclavePasskeySigner {
    SecureEnclavePasskeySigner(keyReference: keyReference, publicKey: publicKey)
  }
}

enum PasskeyStore {
  private static var service: String {
    AppEdition.isTest ? "com.lucas.aurelia.media.test.passkey" : "com.lucas.aurelia.media.passkey"
  }

  static func load(server: UUID, profile: UUID) -> StoredPasskey? {
    var query = baseQuery(server: server, profile: profile)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data
    else { return nil }
    return try? JSONDecoder().decode(StoredPasskey.self, from: data)
  }

  static func save(_ passkey: StoredPasskey, server: UUID, profile: UUID) throws {
    let data = try JSONEncoder().encode(passkey)
    remove(server: server, profile: profile)
    var query = baseQuery(server: server, profile: profile)
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw APIClientError.serverRejected(code: "passkey_save_failed", message: "The key could not be saved on this Mac.")
    }
  }

  static func remove(server: UUID, profile: UUID) {
    SecItemDelete(baseQuery(server: server, profile: profile) as CFDictionary)
  }

  private static func baseQuery(server: UUID, profile: UUID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: "\(server.uuidString).\(profile.uuidString)",
      kSecAttrSynchronizable as String: false,
    ]
  }
}
