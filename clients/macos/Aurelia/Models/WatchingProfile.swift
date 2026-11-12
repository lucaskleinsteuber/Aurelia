import Foundation

struct WatchingProfile: Decodable, Identifiable, Equatable, Sendable {
  let id: UUID
  /// The shown name (the server sends the display name here, else the sign-in name).
  let name: String
  let role: UserRole
  let needsPinSetup: Bool
  let pinProtectionEnabled: Bool
  let pictureKey: String?
  let pictureRevision: Int64
  let ageLimit: Int?
  /// Screen time closes this whole profile until then ("Good night · back at 07:00").
  var closedUntil: String? = nil

  init(
    id: UUID, name: String, role: UserRole, needsPinSetup: Bool,
    pinProtectionEnabled: Bool = true, pictureKey: String? = nil, pictureRevision: Int64 = 0,
    ageLimit: Int? = nil, closedUntil: String? = nil
  ) {
    self.id = id
    self.name = name
    self.role = role
    self.needsPinSetup = needsPinSetup
    self.pinProtectionEnabled = pinProtectionEnabled
    self.pictureKey = pictureKey
    self.pictureRevision = pictureRevision
    self.ageLimit = ageLimit
    self.closedUntil = closedUntil
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, role, needsPinSetup, pinProtectionEnabled, pictureKey, pictureRevision, ageLimit
    case closedUntil
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    role = try values.decode(UserRole.self, forKey: .role)
    needsPinSetup = try values.decode(Bool.self, forKey: .needsPinSetup)
    pinProtectionEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .pinProtectionEnabled) ?? true
    pictureKey = try values.decodeIfPresent(String.self, forKey: .pictureKey)
    pictureRevision = try values.decodeIfPresent(Int64.self, forKey: .pictureRevision) ?? 0
    ageLimit = try values.decodeIfPresent(Int.self, forKey: .ageLimit)
    closedUntil = try values.decodeIfPresent(String.self, forKey: .closedUntil)
  }
}

struct ProfilePickerResponse: Decodable, Sendable {
  let formatVersion: Int
  let minimumClientVersion: String
  let managementSetupRequired: Bool
  let profiles: [WatchingProfile]
}

struct ProfileSessionResponse: Decodable, Sendable {
  let user: UserSummary
  let sessionId: UUID
  let token: String
  let expiresAt: String
}

enum ProfileAccessMode: String, Codable, Sendable {
  case legacyLibraries, entireLibrary, selectedTitles
}

struct ProfileTitleAccess: Codable, Sendable {
  let mode: ProfileAccessMode
  let titleIds: [UUID]
  let revision: Int64
}

struct ProfileEditorResponse: Codable, Sendable {
  let user: UserSummary
  let isEnabled: Bool
  let access: ProfileTitleAccess
  let revision: Int64
}

struct ProfileCreateRequest: Codable, Sendable {
  let username: String
  let role: UserRole
  let isEnabled: Bool
  let pinProtectionEnabled: Bool
  let pin: String?
  let accessMode: ProfileAccessMode?
  let titleIds: [UUID]?
  var displayName: String? = nil
  var pictureKey: String? = nil
  var ageLimit: Int? = nil
}

struct ProfileNameRequest: Codable, Sendable {
  let name: String
}

struct ProfilePictureRequest: Codable, Sendable {
  /// A built-in picture (`symbol:palette`), or nil for the initial.
  let builtin: String?
}

/// A children's profile: the highest FSK age it may watch (nil: none) and its exceptions.
struct ProfileAgeLimit: Codable, Equatable, Sendable {
  var ageLimit: Int?
  var allowedTitleIds: [UUID]
  var hiddenTitleIds: [UUID]
  var revision: Int64
}

struct ProfileUpdateRequest: Codable, Sendable {
  let revision: Int64
  let role: UserRole
  let isEnabled: Bool
  let pinProtectionEnabled: Bool
  let pin: String?
  let accessMode: ProfileAccessMode?
  let titleIds: [UUID]?
}

enum ProfilePIN {
  static let requirement = "Numbers only (0–9), 4 to 8 digits."
  /// One answer for every rejected unlock, so the message never hints at the PIN's length.
  static let incorrect = "The PIN is incorrect."

  static func isValid(_ pin: String) -> Bool {
    (4...8).contains(pin.count) && pin.utf8.allSatisfy { (48...57).contains($0) }
  }

  /// Live feedback while a PIN is typed. Letters and other characters are reported
  /// immediately; length and confirmation only once a confirmation is entered.
  static func problem(_ pin: String, confirmation: String = "") -> String? {
    if !pin.utf8.allSatisfy({ (48...57).contains($0) }) {
      return "A PIN can only contain numbers (0–9). Letters are not allowed."
    }
    if pin.count > 8 { return "A PIN can have at most 8 digits." }
    guard !confirmation.isEmpty else { return nil }
    if pin.count < 4 { return "A PIN needs at least 4 digits." }
    return confirmation == pin ? nil : "The PINs don't match."
  }

  static func canSave(
    role: UserRole, protectionEnabled: Bool, newPIN: String, hasExistingPIN: Bool
  ) -> Bool {
    guard !role.canManageLibraries || protectionEnabled else { return false }
    guard protectionEnabled else { return newPIN.isEmpty }
    return newPIN.isEmpty ? hasExistingPIN : isValid(newPIN)
  }
}
