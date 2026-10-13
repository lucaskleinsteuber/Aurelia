import Foundation

struct WatchingProfile: Decodable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let role: UserRole
  let needsPinSetup: Bool
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

enum ProfilePIN {
  static func isValid(_ pin: String) -> Bool {
    (4...8).contains(pin.count) && pin.utf8.allSatisfy { (48...57).contains($0) }
  }
}
