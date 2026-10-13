import Foundation
import Security

protocol ServerProfileStore: Sendable {
  func load() throws -> StoredServerProfile?
  func save(_ profile: StoredServerProfile) throws
  func delete() throws
}

struct KeychainServerStore: ServerProfileStore {
  enum StoreError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
      switch self {
      case .unexpectedStatus(let status):
        "The server connection could not be stored securely (Keychain error \(status))."
      }
    }
  }

  static let productionService = "com.lucas.aurelia.media.connection.v1"
  static let legacyService = "com.lucas.aureliahome.connection.v2"

  let service: String
  let migrationService: String?

  init(service: String = productionService, migrationService: String? = nil) {
    self.service = service
    self.migrationService =
      migrationService ?? (service == Self.productionService ? Self.legacyService : nil)
  }

  func load() throws -> StoredServerProfile? {
    if let profile = try load(service: service) {
      return profile
    }
    guard let migrationService,
      let legacyProfile = try load(service: migrationService)
    else { return nil }
    try save(legacyProfile)
    // Retire the migrated credential only after its replacement is safely stored.
    // Otherwise an explicit disconnect could resurrect the old connection.
    try delete(service: migrationService)
    return legacyProfile
  }

  private func load(service: String) throws -> StoredServerProfile? {
    var query = baseQuery(service: service)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = result as? Data else {
      throw StoreError.unexpectedStatus(status)
    }
    return try JSONDecoder().decode(StoredServerProfile.self, from: data)
  }

  func save(_ profile: StoredServerProfile) throws {
    guard !profile.isViewingSession else { throw StoreError.unexpectedStatus(errSecParam) }
    let data = try JSONEncoder().encode(profile)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(
      baseQuery(service: service) as CFDictionary,
      attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw StoreError.unexpectedStatus(updateStatus)
    }

    var insert = baseQuery(service: service)
    for (key, value) in attributes {
      insert[key] = value
    }
    let addStatus = SecItemAdd(insert as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw StoreError.unexpectedStatus(addStatus)
    }
  }

  func delete() throws {
    // Delete the fallback first: if this fails, keep the current profile so the
    // caller can accurately report that disconnect did not finish.
    if let migrationService { try delete(service: migrationService) }
    try delete(service: service)
  }

  private func delete(service: String) throws {
    let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw StoreError.unexpectedStatus(status)
    }
  }

  private func baseQuery(service: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "active-server",
      kSecAttrSynchronizable as String: false,
    ]
  }
}

final class InMemoryServerProfileStore: ServerProfileStore, @unchecked Sendable {
  private let lock = NSLock()
  private var profile: StoredServerProfile?

  init(profile: StoredServerProfile? = nil) {
    self.profile = profile
  }

  func load() throws -> StoredServerProfile? {
    lock.withLock { profile }
  }

  func save(_ profile: StoredServerProfile) throws {
    lock.withLock { self.profile = profile }
  }

  func delete() throws {
    lock.withLock { profile = nil }
  }
}
