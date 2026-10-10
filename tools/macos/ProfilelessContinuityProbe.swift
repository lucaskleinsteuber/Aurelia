import Foundation
import LocalAuthentication
import Security

// Only a fresh random service supplied by the harness is accepted. This probe
// never queries an application's existing account, service, or credentials.
guard CommandLine.arguments.count >= 3,
  let identifier = UUID(uuidString: CommandLine.arguments[2])
else { exit(2) }
let action = CommandLine.arguments[1]
let service = "Aurelia.ProfilelessContinuityProbe.\(identifier.uuidString)"
let initial = Data("synthetic baseline credential".utf8)
let updated = Data("synthetic updated credential".utf8)
let authenticationContext = LAContext()
authenticationContext.interactionNotAllowed = true
let query: [String: Any] = [
  kSecClass as String: kSecClassGenericPassword,
  kSecAttrService as String: service,
  kSecAttrAccount as String: "synthetic",
  kSecAttrSynchronizable as String: false,
  kSecUseAuthenticationContext as String: authenticationContext,
]

func read(_ expected: Data) -> Bool {
  var request = query
  request[kSecReturnData as String] = true
  request[kSecMatchLimit as String] = kSecMatchLimitOne
  var result: CFTypeRef?
  let status = SecItemCopyMatching(request as CFDictionary, &result)
  print("syntheticCredentialReadStatus=\(status)")
  return status == errSecSuccess && (result as? Data) == expected
}

func remove() -> Bool {
  let status = SecItemDelete(query as CFDictionary)
  print("syntheticCredentialCleanupStatus=\(status)")
  return status == errSecSuccess || status == errSecItemNotFound
}

switch action {
case "write":
  var insert = query
  insert[kSecValueData as String] = initial
  insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
  let status = SecItemAdd(insert as CFDictionary, nil)
  print("syntheticBaselineWriteStatus=\(status)")
  exit(status == errSecSuccess ? 0 : 1)
case "read-update-delete":
  let readable = read(initial)
  print("syntheticCredentialSurvivedSignatureChange=\(readable)")
  guard readable else { exit(1) }
  let status = SecItemUpdate(
    query as CFDictionary, [kSecValueData as String: updated] as CFDictionary)
  print("syntheticCredentialUpdateStatus=\(status)")
  let updatedCorrectly = status == errSecSuccess && read(updated)
  let removed = remove()
  guard updatedCorrectly && removed else { exit(1) }
  guard
    let group = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "B5N7JVK37J.com.aurelia.distribution-probe")
  else { exit(1) }
  // The synthetic group is unrelated to Aurelia's production host group.
  let directory = group.appendingPathComponent(
    "Library/Caches/SigningProbe/\(identifier.uuidString)")
  do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try initial.write(to: directory.appendingPathComponent("synthetic-handoff"), options: .atomic)
    print("syntheticSharedGroupWrite=true")
    exit(0)
  } catch {
    print("syntheticProfilelessHelperStatus=failed")
    exit(1)
  }
case "group-read":
  guard
    let group = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "B5N7JVK37J.com.aurelia.distribution-probe")
  else { exit(1) }
  let path = group.appendingPathComponent(
    "Library/Caches/SigningProbe/\(identifier.uuidString)/synthetic-handoff")
  let matches = (try? Data(contentsOf: path)) == initial
  print("syntheticSharedGroupHandoff=\(matches)")
  do {
    try FileManager.default.removeItem(at: path.deletingLastPathComponent())
    print("syntheticSharedGroupCleanup=true")
  } catch {
    print("syntheticSharedGroupCleanup=false")
    exit(1)
  }
  exit(matches ? 0 : 1)
case "group-delete":
  guard
    let group = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "B5N7JVK37J.com.aurelia.distribution-probe")
  else { exit(1) }
  let directory = group.appendingPathComponent(
    "Library/Caches/SigningProbe/\(identifier.uuidString)")
  do {
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
    exit(0)
  } catch { exit(1) }
case "delete":
  exit(remove() ? 0 : 1)
default:
  exit(2)
}
