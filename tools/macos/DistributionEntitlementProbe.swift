import Foundation
import Security

// A diagnostic for an isolated synthetic group, never the installed app's group
// or credentials. It cannot validate a complete downloaded application.
let group = "B5N7JVK37J.com.aurelia.distribution-probe"
let service = "Aurelia.DistributionProbe.\(UUID().uuidString)"
let query: [String: Any] = [
  kSecClass as String: kSecClassGenericPassword,
  kSecAttrService as String: service,
  kSecAttrAccount as String: "synthetic",
  kSecAttrAccessGroup as String: group,
  kSecUseDataProtectionKeychain as String: true,
]
var item = query
item[kSecValueData as String] = Data("synthetic, not an application token".utf8)
let added = SecItemAdd(item as CFDictionary, nil)
if added == errSecSuccess { SecItemDelete(query as CFDictionary) }
let available = FileManager.default.containerURL(
  forSecurityApplicationGroupIdentifier: group) != nil
print("syntheticKeychainWriteStatus=\(added)")
print("syntheticAppGroupAvailable=\(available)")
