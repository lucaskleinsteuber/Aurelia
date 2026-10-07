import Foundation
import Security

// Uses only an isolated synthetic group and an ephemeral credential. The
// Keychain query intentionally matches Aurelia's existing ordinary Mac query,
// without claiming a restricted access group or forcing the DP Keychain.
let group = "B5N7JVK37J.com.aurelia.distribution-probe"
let service = "Aurelia.ProfilelessSigningProbe.\(UUID().uuidString)"
let expected = Data("synthetic probe, not an application token".utf8)
let query: [String: Any] = [
  kSecClass as String: kSecClassGenericPassword,
  kSecAttrService as String: service,
  kSecAttrAccount as String: "synthetic",
  kSecAttrSynchronizable as String: false,
]
var insert = query
insert[kSecValueData as String] = expected
insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
let added = SecItemAdd(insert as CFDictionary, nil)
var copied: CFTypeRef?
var readQuery = query
readQuery[kSecReturnData as String] = true
readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
let read = added == errSecSuccess
  ? SecItemCopyMatching(readQuery as CFDictionary, &copied) : added
let matches = copied as? Data == expected
let deleted = added == errSecSuccess ? SecItemDelete(query as CFDictionary) : added
let groupAvailable = FileManager.default.containerURL(
  forSecurityApplicationGroupIdentifier: group) != nil
print("syntheticKeychainWriteStatus=\(added)")
print("syntheticKeychainReadStatus=\(read)")
print("syntheticKeychainRoundTrip=\(matches)")
print("syntheticKeychainCleanupStatus=\(deleted)")
print("syntheticAppGroupAvailable=\(groupAvailable)")
exit(added == errSecSuccess && read == errSecSuccess && matches
  && deleted == errSecSuccess && groupAvailable ? 0 : 1)
