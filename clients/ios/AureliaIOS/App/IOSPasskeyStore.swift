import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// A P-256 key in this device's Secure Enclave, usable only after Face ID, Touch ID or the device
/// passcode. Only an encrypted reference to it is stored; the private key never leaves the chip.
///
/// Queue contract: `sign` runs the blocking CryptoKit call (which shows the system's Face ID
/// sheet) on a detached task, never on the main actor, and only Sendable values cross it.
struct IOSSecureEnclaveSigner: IOSPasskeySigner {
  let keyReference: Data
  let publicKey: Data

  static var isAvailable: Bool { SecureEnclave.isAvailable }

  /// "Face ID" or "Touch ID", for the words on screen.
  static var biometryName: String {
    let context = LAContext()
    _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    return context.biometryType == .touchID ? "Touch ID" : "Face ID"
  }

  static func create() throws -> IOSSecureEnclaveSigner {
    var error: Unmanaged<CFError>?
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &error)
    else { throw IOSPasskeyError.unavailable }
    let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
    return IOSSecureEnclaveSigner(
      keyReference: key.dataRepresentation, publicKey: key.publicKey.x963Representation)
  }

  func sign(_ message: Data) async throws -> Data {
    let reference = keyReference
    return try await Task.detached(priority: .userInitiated) { () throws -> Data in
      let context = LAContext()
      context.localizedReason = "Confirm the change on your Aurelia server"
      let key = try SecureEnclave.P256.Signing.PrivateKey(
        dataRepresentation: reference, authenticationContext: context)
      return try key.signature(for: message).derRepresentation
    }.value
  }
}

enum IOSPasskeyError: LocalizedError {
  case unavailable
  var errorDescription: String? {
    "This \(IOSPasskeyStore.deviceWord) can't keep a Face ID or Touch ID key."
  }
}

/// The key reference for one profile on one server, kept in the Keychain of this device only.
struct IOSStoredPasskey: Codable, Equatable, Sendable {
  let passkeyId: UUID
  let keyReference: Data
  let publicKey: Data

  var signer: IOSSecureEnclaveSigner {
    IOSSecureEnclaveSigner(keyReference: keyReference, publicKey: publicKey)
  }
}

enum IOSPasskeyStore {
  private static let service = "com.lucas.aurelia.ios.passkey"
  static let deviceWord = "device"

  static func load(server: UUID, profile: UUID) -> IOSStoredPasskey? {
    var query = baseQuery(server: server, profile: profile)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data
    else { return nil }
    return try? JSONDecoder().decode(IOSStoredPasskey.self, from: data)
  }

  static func save(_ passkey: IOSStoredPasskey, server: UUID, profile: UUID) throws {
    let data = try JSONEncoder().encode(passkey)
    remove(server: server, profile: profile)
    var query = baseQuery(server: server, profile: profile)
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw NSError(
        domain: NSOSStatusErrorDomain, code: Int(status),
        userInfo: [NSLocalizedDescriptionKey: "The key could not be saved on this device."])
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
