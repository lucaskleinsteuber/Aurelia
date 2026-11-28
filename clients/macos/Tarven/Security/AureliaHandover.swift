import Foundation
import Security

/// Tarven was called Aurelia until Mac 2.30.0. Tarven is a new app with its own identifier, so on
/// its first start it takes over, once, what Aurelia kept:
/// - the server connection and offline profiles from Aurelia's Keychain group (copied; Aurelia's
///   items stay until Aurelia is removed),
/// - the settings Aurelia 2.30.0 left in its App Group ("Tarven Handover/preferences.plist"),
///   with their keys renamed the way the code was.
/// The Mac's own server folder is taken over by the server helper (ServerDataMigrator). Nothing
/// here touches Aurelia Classic (com.lucas.aurelia, Application Support/Aurelia).
enum AureliaHandover {
  static let importedKey = "TarvenImportedAureliaSettings"
  static let bundleIdentifier = "com.lucas.aurelia.media"
  static let groupSuffix = ".com.lucas.aurelia.media.host"

  /// Aurelia's Keychain services and Tarven's for the same item.
  static let keychainServices: [(legacy: String, current: String)] = [
    (bundleIdentifier + ".connection.v1", KeychainServerStore.productionService),
    (bundleIdentifier + ".offline-profiles.v1", KeychainOfflineProfileStore.productionService),
  ]

  /// The signing team, the prefix of this app's App Group.
  static var team: String { String(AppEdition.appGroup.prefix(10)) }

  @MainActor
  static func runOnce(defaults: UserDefaults = .standard) {
    guard !AppEdition.isTest, !defaults.bool(forKey: importedKey) else { return }
    copyKeychainItems(accessGroup: team + "." + bundleIdentifier)
    if let group = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: team + groupSuffix)
    {
      importPreferences(from: preferencesFile(groupContainer: group), into: defaults)
    }
    defaults.set(true, forKey: importedKey)
  }

  static func preferencesFile(groupContainer: URL) -> URL {
    groupContainer.appendingPathComponent(
      "Library/Application Support/Tarven Handover/preferences.plist")
  }

  /// Adds Aurelia's settings that Tarven does not have yet, under their new names. Caches of the
  /// old update feed are left out; returns how many settings were taken over.
  @discardableResult
  static func importPreferences(from file: URL, into defaults: UserDefaults) -> Int {
    guard let data = try? Data(contentsOf: file),
      let settings = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return 0 }
    var count = 0
    for (key, value) in settings {
      let renamed = renamedKey(key)
      guard !renamed.hasPrefix("TarvenUpdateCatalog"), !renamed.hasPrefix("TarvenLastUpdateCheck"),
        !renamed.hasPrefix("TarvenUpdateLatestETag"), defaults.object(forKey: renamed) == nil
      else { continue }
      defaults.set(value, forKey: renamed)
      count += 1
    }
    return count
  }

  /// "AureliaBetaUpdates" → "TarvenBetaUpdates", "aurelia.library-browse.v1.x" → "tarven.…".
  static func renamedKey(_ key: String) -> String {
    key.replacingOccurrences(of: bundleIdentifier, with: "org.tarven.mac")
      .replacingOccurrences(of: "AURELIA", with: "TARVEN")
      .replacingOccurrences(of: "Aurelia", with: "Tarven")
      .replacingOccurrences(of: "aurelia", with: "tarven")
  }

  /// Copies Aurelia's items into Tarven's services where Tarven has none yet.
  static func copyKeychainItems(accessGroup: String) {
    for (legacy, current) in keychainServices {
      let search: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: legacy,
        kSecAttrAccessGroup as String: accessGroup,
        kSecUseDataProtectionKeychain as String: true,
        kSecReturnAttributes as String: true,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
      ]
      var result: CFTypeRef?
      guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
        let items = result as? [[String: Any]]
      else { continue }
      for item in items {
        guard let account = item[kSecAttrAccount as String] as? String,
          let data = item[kSecValueData as String] as? Data
        else { continue }
        let existing = TarvenKeychain.item([
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: current,
          kSecAttrAccount as String: account,
        ])
        guard SecItemCopyMatching(existing as CFDictionary, nil) == errSecItemNotFound else {
          continue
        }
        var insert = existing
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        insert[kSecAttrSynchronizable as String] = false
        SecItemAdd(insert as CFDictionary, nil)
      }
    }
  }
}
