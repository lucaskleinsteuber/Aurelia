import Foundation
import Security

struct IOSCredentialStore {
  private static let service = "com.lucas.aurelia.ios.connection"
  private static let account = "paired-server"

  func load() throws -> IOSStoredConnection? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
    let value = try JSONDecoder().decode(IOSStoredConnection.self, from: data)
    try value.validate()
    return value
  }

  func save(_ connection: IOSStoredConnection) throws {
    try connection.validate()
    let data = try JSONEncoder().encode(connection)
    let update: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var query = baseQuery
      for (key, value) in update { query[key] = value }
      let inserted = SecItemAdd(query as CFDictionary, nil)
      guard inserted == errSecSuccess else { throw failure(inserted) }
    } else if status != errSecSuccess {
      throw failure(status)
    }
  }

  func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
      kSecAttrAccount as String: Self.account, kSecAttrSynchronizable as String: false,
    ]
  }
  private func failure(_ status: OSStatus) -> NSError {
    NSError(
      domain: NSOSStatusErrorDomain, code: Int(status),
      userInfo: [
        NSLocalizedDescriptionKey: "The paired server could not be saved securely. Try again."
      ])
  }
}
