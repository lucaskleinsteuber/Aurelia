import Foundation

struct ServerInfoResponse: Codable, Equatable, Sendable {
  let serverId: UUID
  let name: String
  let version: String
  let isSetup: Bool
  let lanAccessEnabled: Bool
  let lanHttpsPort: Int?
  let publicKeyFingerprint: String?
  let displayFingerprint: String?
}

struct RedeemPairingCodeRequest: Encodable, Sendable {
  let code: String
  let deviceName: String
}

struct AuthenticationResponse: Decodable, Sendable {
  let user: UserSummary
  let sessionId: UUID
  let token: String
  let expiresAt: String
}

struct UserSummary: Decodable, Sendable {
  let id: UUID
  let username: String
  let role: String
  let createdAt: String
}

struct APIProblem: Decodable, Error, Sendable {
  let code: String
  let message: String
}

struct PagedResponse<Item: Decodable & Sendable>: Decodable, Sendable {
  let items: [Item]
  let offset: Int
  let limit: Int
  let total: Int
}

enum MediaAvailability: String, Codable, Sendable {
  case available
  case missing
}

enum MediaKind: String, Codable, Sendable {
  case movie
  case series
  case episode
  case extra
  case trailer
}

struct MovieSummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let year: Int?
  let availability: MediaAvailability
}

struct MovieDetailResponse: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let year: Int?
  let availability: MediaAvailability
  let supplements: [SupplementSummary]
}

struct SeriesSummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let availability: MediaAvailability
  let seasonCount: Int
  let episodeCount: Int
}

struct SeriesDetailResponse: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let availability: MediaAvailability
  let seasons: [SeasonSummary]
  let supplements: [SupplementSummary]
}

struct SeasonSummary: Codable, Identifiable, Equatable, Sendable {
  let number: Int
  let episodes: [EpisodeSummary]
  let supplements: [SupplementSummary]

  var id: Int { number }
}

struct EpisodeSummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let seasonNumber: Int
  let episodeNumber: Int
  let availability: MediaAvailability
}

struct SupplementSummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let kind: MediaKind
  let category: String
  let seasonNumber: Int?
  let availability: MediaAvailability
}

struct StoredServerProfile: Codable, Equatable, Sendable {
  let serverId: UUID
  let name: String
  let baseURL: URL
  let publicKeyFingerprint: String
  let token: String
  let sessionId: UUID
  let expiresAt: String
}

struct InspectedServer: Equatable, Sendable {
  let baseURL: URL
  let info: ServerInfoResponse
  let publicKeyFingerprint: String

  var displayFingerprint: String {
    FingerprintFormatter.display(publicKeyFingerprint)
  }
}
