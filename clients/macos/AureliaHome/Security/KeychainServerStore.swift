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

  static let productionService = "com.lucas.aureliahome.connection.v2"

  let service: String

  init(service: String = productionService) {
    self.service = service
  }

  func load() throws -> StoredServerProfile? {
    var query = baseQuery
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
    let data = try JSONEncoder().encode(profile)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(
      baseQuery as CFDictionary,
      attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw StoreError.unexpectedStatus(updateStatus)
    }

    var insert = baseQuery
    for (key, value) in attributes {
      insert[key] = value
    }
    let addStatus = SecItemAdd(insert as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw StoreError.unexpectedStatus(addStatus)
    }
  }

  func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw StoreError.unexpectedStatus(status)
    }
  }

  private var baseQuery: [String: Any] {
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
