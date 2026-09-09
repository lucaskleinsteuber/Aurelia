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

struct SetupOwnerRequest: Encodable, Sendable {
  let username: String
  let password: String
  let deviceName: String
}

struct LoginRequest: Encodable, Sendable {
  let username: String
  let password: String
  let deviceName: String
}

struct AuthenticationResponse: Decodable, Sendable {
  let user: UserSummary
  let sessionId: UUID
  let token: String
  let expiresAt: String
}

enum UserRole: String, Codable, Sendable {
  case owner
  case admin
  case user

  var canManageLibraries: Bool { self == .owner || self == .admin }
}

struct UserSummary: Codable, Equatable, Sendable {
  let id: UUID
  let username: String
  let role: UserRole
  let createdAt: String
}

enum LibraryKind: String, Codable, CaseIterable, Sendable {
  case movies
  case tvShows
  case automatic

  var title: String {
    switch self {
    case .movies: "Movies"
    case .tvShows: "TV Shows"
    case .automatic: "Automatic"
    }
  }
}

enum LibraryAvailability: String, Codable, Sendable {
  case unknown
  case available
  case unavailable
  case error
}

enum LibraryScanState: String, Codable, Sendable {
  case queued
  case running
  case completed
  case failed
  case interrupted
}

struct CreateLibraryRequest: Encodable, Sendable {
  let name: String?
  let path: String
  let kind: LibraryKind
  let combineExisting: Bool
}

enum ClassificationDecision: String, Codable, Sendable {
  case movie
  case tvShows
  case ignore
}

struct LibraryDiscoverySummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let libraryId: UUID
  let relativePath: String
  let detectedTitle: String
  let suggestedKind: LibraryKind?
  let reason: String
  let decision: ClassificationDecision?
}

struct ClassificationDecisionUpdate: Encodable, Sendable {
  let discoveryId: UUID
  let decision: ClassificationDecision
}

struct UpdateClassificationDecisionsRequest: Encodable, Sendable {
  let decisions: [ClassificationDecisionUpdate]
}

struct LibrarySummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let path: String
  let kind: LibraryKind
  let availability: LibraryAvailability
  let createdAt: String
  let lastScanStartedAt: String?
  let lastScanCompletedAt: String?
  let lastError: String?
}

struct LibraryScanIssueSummary: Codable, Equatable, Sendable {
  let code: String
  let message: String
  let path: String?
}

struct LibraryScanSummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let libraryId: UUID
  let state: LibraryScanState
  let createdAt: String
  let startedAt: String?
  let completedAt: String?
  let filesDiscovered: Int
  let filesProcessed: Int
  let addedFiles: Int
  let updatedFiles: Int
  let missingFiles: Int
  let skippedFiles: Int
  let error: String?
  let issues: [LibraryScanIssueSummary]
}

struct PairingCodeResponse: Codable, Equatable, Sendable {
  let code: String
  let expiresAt: String
}

struct DeviceSessionSummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let userId: UUID
  let deviceName: String
  let createdAt: String
  let lastSeenAt: String
  let expiresAt: String
  let revokedAt: String?
  let isCurrent: Bool
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

struct PlaybackProgressResponse: Codable, Equatable, Sendable {
  let mediaId: UUID
  let positionMilliseconds: Int64
  let durationMilliseconds: Int64
  let isCompleted: Bool
  let lastPlayedAt: String?
  let updatedAt: String?
}

struct UpdatePlaybackProgressRequest: Encodable, Equatable, Sendable {
  let positionMilliseconds: Int64
  let durationMilliseconds: Int64
  let isFinished: Bool
}

struct PlaybackSourceResponse: Codable, Equatable, Sendable {
  let id: UUID
  let mediaId: UUID
  let streamPath: String
  let contentType: String
  let contentLength: Int64
  let expiresAt: String
  let progress: PlaybackProgressResponse
}

struct PlaybackPresentation: Identifiable, Equatable, Sendable {
  let mediaId: UUID
  let title: String
  let subtitle: String?

  var id: UUID { mediaId }
}

struct StoredServerProfile: Codable, Equatable, Sendable {
  let serverId: UUID
  let name: String
  let baseURL: URL
  let publicKeyFingerprint: String
  let token: String
  let sessionId: UUID
  let expiresAt: String
  let user: UserSummary?

  init(
    serverId: UUID,
    name: String,
    baseURL: URL,
    publicKeyFingerprint: String,
    token: String,
    sessionId: UUID,
    expiresAt: String,
    user: UserSummary? = nil
  ) {
    self.serverId = serverId
    self.name = name
    self.baseURL = baseURL
    self.publicKeyFingerprint = publicKeyFingerprint
    self.token = token
    self.sessionId = sessionId
    self.expiresAt = expiresAt
    self.user = user
  }
}

struct InspectedServer: Equatable, Sendable {
  let baseURL: URL
  let info: ServerInfoResponse
  let publicKeyFingerprint: String

  var displayFingerprint: String {
    FingerprintFormatter.display(publicKeyFingerprint)
  }
}
