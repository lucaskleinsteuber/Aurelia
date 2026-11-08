import CommonCrypto
import Foundation
import Security

/// What the offline mode needs to open a profile's downloads while the server is out of reach:
/// its name and picture, and whether it has a PIN. A PIN is kept only as a salted PBKDF2 check
/// value, never the PIN itself, and only on this Mac.
struct OfflineProfileCard: Codable, Equatable, Identifiable, Sendable {
  let serverId: UUID
  let userId: UUID
  var name: String
  var pictureKey: String?
  var pictureRevision: Int64
  var pinProtected: Bool
  var salt: Data?
  var check: Data?
  var rememberedAt: Date

  var id: UUID { userId }

  /// Whether this PIN opens the profile offline. A profile without a PIN opens without one.
  func accepts(_ pin: String) -> Bool {
    guard pinProtected else { return true }
    guard let salt, let check, ProfilePIN.isValid(pin),
      let derived = Self.derive(pin, salt: salt)
    else { return false }
    // Constant-time comparison.
    guard derived.count == check.count else { return false }
    return zip(derived, check).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }

  static func make(
    serverId: UUID, profile: WatchingProfile, pin: String, now: Date = Date()
  ) -> OfflineProfileCard? {
    var salt: Data?
    var check: Data?
    if profile.pinProtectionEnabled {
      var bytes = Data(count: 16)
      let status = bytes.withUnsafeMutableBytes {
        SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
      }
      guard status == errSecSuccess, let derived = derive(pin, salt: bytes) else { return nil }
      salt = bytes
      check = derived
    }
    return OfflineProfileCard(
      serverId: serverId, userId: profile.id, name: profile.name, pictureKey: profile.pictureKey,
      pictureRevision: profile.pictureRevision, pinProtected: profile.pinProtectionEnabled,
      salt: salt, check: check, rememberedAt: now)
  }

  static let rounds: UInt32 = 210_000

  static func derive(_ pin: String, salt: Data) -> Data? {
    let password = Array(pin.utf8)
    var derived = Data(count: 32)
    let status = derived.withUnsafeMutableBytes { output in
      salt.withUnsafeBytes { saltBytes in
        CCKeyDerivationPBKDF(
          CCPBKDFAlgorithm(kCCPBKDF2), password.map { Int8(bitPattern: $0) }, password.count,
          saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
          output.bindMemory(to: UInt8.self).baseAddress, 32)
      }
    }
    return status == Int32(kCCSuccess) ? derived : nil
  }
}

/// The offline cards of the profiles opened on this Mac, in the Keychain (this device only).
/// A card is written each time a profile opens while the server answers, so a changed name,
/// picture or PIN reaches it then, and removed when this Mac disconnects from the server.
protocol OfflineProfileStoring: Sendable {
  func cards(serverId: UUID) -> [OfflineProfileCard]
  func remember(_ card: OfflineProfileCard)
  func forget(serverId: UUID)
}

struct KeychainOfflineProfileStore: OfflineProfileStoring {
  static let productionService =
    AppEdition.isTest
    ? "com.lucas.aurelia.media.test.offline-profiles.v1"
    : "com.lucas.aurelia.media.offline-profiles.v1"

  let service: String

  init(service: String = productionService) {
    self.service = service
  }

  func cards(serverId: UUID) -> [OfflineProfileCard] {
    // The Mac's file keychain refuses data together with "all matches" (errSecParam), so the
    // offline mode never saw a card: list the accounts first, then read each card on its own.
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecAttrSynchronizable as String: false,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let items = result as? [[String: Any]]
    else { return [] }
    let accounts = items.compactMap { $0[kSecAttrAccount as String] as? String }
      .filter { $0.hasPrefix(serverId.uuidString + ".") }
    return accounts.compactMap { account -> Data? in
      var one = baseQuery(account: account)
      one[kSecReturnData as String] = true
      one[kSecMatchLimit as String] = kSecMatchLimitOne
      var data: CFTypeRef?
      guard SecItemCopyMatching(one as CFDictionary, &data) == errSecSuccess else { return nil }
      return data as? Data
    }
    .compactMap { try? JSONDecoder().decode(OfflineProfileCard.self, from: $0) }
      .filter { $0.serverId == serverId }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func remember(_ card: OfflineProfileCard) {
    guard let data = try? JSONEncoder().encode(card) else { return }
    let account = Self.account(card)
    let base = baseQuery(account: account)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var item = base
      item.merge(attributes) { _, new in new }
      SecItemAdd(item as CFDictionary, nil)
    }
  }

  func forget(serverId: UUID) {
    for card in cards(serverId: serverId) {
      SecItemDelete(baseQuery(account: Self.account(card)) as CFDictionary)
    }
  }

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
  }

  private static func account(_ card: OfflineProfileCard) -> String {
    "\(card.serverId.uuidString).\(card.userId.uuidString)"
  }
}

/// Keeps cards in memory; for tests and UI test fixtures.
final class MemoryOfflineProfileStore: OfflineProfileStoring, @unchecked Sendable {
  private var stored: [String: OfflineProfileCard] = [:]
  private let lock = NSLock()

  func cards(serverId: UUID) -> [OfflineProfileCard] {
    lock.withLock { stored.values.filter { $0.serverId == serverId } }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  func remember(_ card: OfflineProfileCard) {
    lock.withLock { stored["\(card.serverId).\(card.userId)"] = card }
  }
  func forget(serverId: UUID) {
    lock.withLock { stored = stored.filter { $0.value.serverId != serverId } }
  }
}
