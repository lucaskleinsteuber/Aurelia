import Foundation
import Security

/// The GitHub token that lets the app read the private repository's releases. It stays in the
/// Keychain on this Mac only and is sent to GitHub's API and nowhere else.
struct AppUpdateTokenStore: Sendable {
  static let productionService = "com.lucas.aurelia.media.github-updates.v1"
  let service: String

  init(service: String = productionService) {
    self.service = service
  }

  func load() -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty
    else { return nil }
    return token
  }

  func save(_ token: String) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: Data(token.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let update = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else {
      throw KeychainServerStore.StoreError.unexpectedStatus(update)
    }
    var insert = baseQuery
    for (key, value) in attributes { insert[key] = value }
    let status = SecItemAdd(insert as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw KeychainServerStore.StoreError.unexpectedStatus(status)
    }
  }

  func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainServerStore.StoreError.unexpectedStatus(status)
    }
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "github-token",
      kSecAttrSynchronizable as String: false,
    ]
  }
}
