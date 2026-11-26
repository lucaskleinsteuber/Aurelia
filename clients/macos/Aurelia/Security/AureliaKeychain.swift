import Foundation
import Security

/// Where Aurelia keeps its Keychain items on the Mac: the data protection keychain, the one iOS
/// uses. Only there does "this device only" hold, so a sign-in does not move to another Mac with
/// Migration Assistant or a copied login keychain (audit C-L10). Items an earlier version kept in
/// the login keychain move over the first time they are read, and are removed there only once
/// their copy is stored.
///
/// A build signed without a keychain access group cannot write to the data protection keychain
/// (errSecMissingEntitlement), although a lookup there may still answer "not found"; it keeps
/// using the login keychain as before. A service whose items could not be moved also stays in
/// the login keychain, so a sign-in is never hidden in a keychain that lacks it.
enum AureliaKeychain {
  /// Whether this signature may use the data protection keychain, found out once by storing and
  /// removing a throwaway item there.
  static let usesDataProtection: Bool = {
    let probe: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: AppEdition.bundleIdentifier + ".keychain-probe",
      kSecAttrAccount as String: UUID().uuidString,
      kSecUseDataProtectionKeychain as String: true,
    ]
    var add = probe
    add[kSecValueData as String] = Data([1])
    add[kSecAttrSynchronizable as String] = false
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { return false }
    SecItemDelete(probe as CFDictionary)
    return true
  }()

  private static let lock = NSLock()
  nonisolated(unsafe) private static var migrated: Set<String> = []
  nonisolated(unsafe) private static var keptInLoginKeychain: Set<String> = []

  /// A query or item for the keychain Aurelia uses now.
  static func item(_ base: [String: Any]) -> [String: Any] {
    guard usesDataProtection else { return base }
    if let service = base[kSecAttrService as String] as? String,
      lock.withLock({ keptInLoginKeychain.contains(service) })
    {
      return base
    }
    var query = base
    query[kSecUseDataProtectionKeychain as String] = true
    return query
  }

  /// A query for the login keychain alone. Without the flag set to false, macOS searches both
  /// keychains, and deleting the old item would remove its new copy too.
  static func loginKeychain(_ base: [String: Any]) -> [String: Any] {
    var query = base
    query[kSecUseDataProtectionKeychain as String] = false
    return query
  }

  /// When migrating from the login keychain finds an existing data protection item, keep
  /// whichever entry was modified more recently so a fresh pairing made under a profileless build
  /// is never discarded in favor of an older token.
  static func shouldOverwriteExisting(legacyModified: Date?, existingModified: Date?) -> Bool {
    guard let legacyModified else { return false }
    guard let existingModified else { return true }
    return legacyModified > existingModified
  }

  /// Moves this service's items from the login keychain, once per launch.
  static func migrate(
    service: String, accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
  ) {
    guard usesDataProtection else { return }
    let first = lock.withLock { migrated.insert(service).inserted }
    guard first else { return }
    let list = loginKeychain([
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ])
    var result: CFTypeRef?
    guard SecItemCopyMatching(list as CFDictionary, &result) == errSecSuccess,
      let items = result as? [[String: Any]]
    else { return }
    // The login keychain refuses data together with "all matches", so each item is read alone.
    for attributes in items {
      guard let account = attributes[kSecAttrAccount as String] as? String else { continue }
      let legacyModified = attributes[kSecAttrModificationDate as String] as? Date
      let legacy: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
      ]
      var read = loginKeychain(legacy)
      read[kSecReturnData as String] = true
      read[kSecMatchLimit as String] = kSecMatchLimitOne
      var data: CFTypeRef?
      guard SecItemCopyMatching(read as CFDictionary, &data) == errSecSuccess,
        let value = data as? Data
      else { continue }
      var copy = item(legacy)
      copy[kSecAttrSynchronizable as String] = false
      copy[kSecValueData as String] = value
      copy[kSecAttrAccessible as String] = accessible
      let added = SecItemAdd(copy as CFDictionary, nil)
      if added == errSecSuccess {
        SecItemDelete(loginKeychain(legacy) as CFDictionary)
      } else if added == errSecDuplicateItem {
        var existingQuery = item(legacy)
        existingQuery[kSecAttrSynchronizable as String] = false
        existingQuery[kSecReturnAttributes as String] = true
        existingQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var existingResult: CFTypeRef?
        let existingStatus = SecItemCopyMatching(existingQuery as CFDictionary, &existingResult)
        let existingModified =
          (existingResult as? [String: Any])?[kSecAttrModificationDate as String] as? Date
        if existingStatus == errSecSuccess,
          shouldOverwriteExisting(
            legacyModified: legacyModified, existingModified: existingModified)
        {
          var target = item(legacy)
          target[kSecAttrSynchronizable as String] = false
          let updateAttributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: accessible,
          ]
          let updated = SecItemUpdate(target as CFDictionary, updateAttributes as CFDictionary)
          guard updated == errSecSuccess else {
            _ = lock.withLock { keptInLoginKeychain.insert(service) }
            return
          }
        }
        SecItemDelete(loginKeychain(legacy) as CFDictionary)
      } else {
        // Not moved: this service keeps using the login keychain for this launch.
        _ = lock.withLock { keptInLoginKeychain.insert(service) }
        return
      }
    }
  }

  /// Removes matching items from both keychains, so an item not yet moved cannot come back.
  @discardableResult
  static func delete(_ base: [String: Any]) -> OSStatus {
    let current = SecItemDelete(item(base) as CFDictionary)
    guard usesDataProtection else { return current }
    let legacy = SecItemDelete(loginKeychain(base) as CFDictionary)
    if current != errSecSuccess && current != errSecItemNotFound { return current }
    if legacy != errSecSuccess && legacy != errSecItemNotFound { return legacy }
    return current == errSecSuccess || legacy == errSecSuccess ? errSecSuccess : errSecItemNotFound
  }
}
