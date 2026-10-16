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
  var capabilities: [String]? = nil
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
  let accessMode: ProfileAccessMode?
  let pinProtectionEnabled: Bool
  let needsPinSetup: Bool
  let profileRevision: Int64

  init(
    id: UUID, username: String, role: UserRole, createdAt: String,
    accessMode: ProfileAccessMode? = nil, pinProtectionEnabled: Bool = true,
    needsPinSetup: Bool = false, profileRevision: Int64 = 0
  ) {
    self.id = id
    self.username = username
    self.role = role
    self.createdAt = createdAt
    self.accessMode = accessMode
    self.pinProtectionEnabled = pinProtectionEnabled
    self.needsPinSetup = needsPinSetup
    self.profileRevision = profileRevision
  }

  private enum CodingKeys: String, CodingKey {
    case id, username, role, createdAt, accessMode, pinProtectionEnabled, needsPinSetup,
      profileRevision
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    username = try values.decode(String.self, forKey: .username)
    role = try values.decode(UserRole.self, forKey: .role)
    createdAt = try values.decode(String.self, forKey: .createdAt)
    accessMode = try values.decodeIfPresent(ProfileAccessMode.self, forKey: .accessMode)
    pinProtectionEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .pinProtectionEnabled) ?? true
    needsPinSetup = try values.decodeIfPresent(Bool.self, forKey: .needsPinSetup) ?? false
    profileRevision = try values.decodeIfPresent(Int64.self, forKey: .profileRevision) ?? 0
  }
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
  case waitingForStorage
  case completed
  case failed
  case interrupted
  case cancelled
}

enum LibraryHealthStatus: String, Codable, Sendable {
  case unknown, healthy, waitingForStorage, permissionDenied, error
}

enum LibraryScanTrigger: String, Codable, Sendable {
  case manual, fileChange, startup, scheduled, storageReconnected, classificationChanged
}

struct CreateLibraryRequest: Encodable, Sendable {
  let name: String?
  let path: String
  let kind: LibraryKind
  let combineExisting: Bool
  var requireImportPreview = false
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

enum LibraryImportReviewState: String, Codable, Sendable {
  case pending
  case assigned
  case ignored
}

struct LibraryImportReviewSummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let libraryId: UUID
  let relativePath: String
  let detectedTitle: String
  let reason: String
  let state: LibraryImportReviewState
}

enum LibraryImportReviewAction: String, Encodable, Sendable {
  case assignToMovie
  case ignore
}

struct UpdateLibraryImportReviewRequest: Encodable, Sendable {
  let action: LibraryImportReviewAction
  let movieId: UUID?
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
  var monitoringEnabled: Bool? = nil
  var lastObservedAt: String? = nil
  var health: LibraryHealthStatus? = nil
  var importPreviewRequired: Bool? = nil

  var isMonitoringEnabled: Bool { monitoringEnabled ?? false }
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
  var trigger: LibraryScanTrigger? = nil
  var attempt: Int? = nil
  var targetRelativePath: String? = nil
  var phase: String? = nil
  var recognizedFiles: Int? = nil
  var pendingFiles: Int? = nil
  var ignoredFiles: Int? = nil
  var failedFiles: Int? = nil
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

  var isActive: Bool {
    guard revokedAt == nil else { return false }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fractional = formatter.date(from: expiresAt)
    formatter.formatOptions = [.withInternetDateTime]
    guard let expiry = fractional ?? formatter.date(from: expiresAt) else { return false }
    return expiry > Date()
  }
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
  var revision: String? = nil
}

enum MediaAvailability: String, Codable, Sendable {
  case available
  case missing
  case error
}

enum MediaKind: String, Codable, Sendable {
  case movie
  case series
  case episode
  case extra
  case trailer
}

enum ArtworkKind: String, Codable, Sendable {
  case poster
  case backdrop
  case still
  case profile
}

enum MetadataReviewState: String, Codable, Sendable {
  case needsReview
  case matched
  case ignored
}

struct ArtworkSummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let kind: ArtworkKind
  let path: String
  let contentType: String
  let contentLength: Int64
  var revision: Int64? = nil
}

struct CreditSummary: Codable, Identifiable, Equatable, Sendable {
  let name: String
  let department: String
  let job: String?
  let character: String?
  let order: Int
  let profile: ArtworkSummary?
  var personKey: String? = nil
  var creditId: UUID? = nil

  enum CodingKeys: String, CodingKey {
    case name, department, job, character, order, profile, personKey
    case creditId = "id"
  }

  var id: String { creditId?.uuidString ?? "\(order):\(department):\(name):\(character ?? "")" }
}

struct MediaMetadataSummary: Codable, Identifiable, Equatable, Sendable {
  let mediaId: UUID
  let title: String
  let originalTitle: String?
  let overview: String?
  let releaseDate: String?
  let year: Int?
  let runtimeMinutes: Int?
  let rating: Double?
  let contentRating: String?
  let genres: [String]
  let studios: [String]
  let countries: [String]
  let credits: [CreditSummary]
  let poster: ArtworkSummary?
  let backdrop: ArtworkSummary?
  let still: ArtworkSummary?
  let provider: String?
  let providerMediaId: String?
  let reviewState: MetadataReviewState
  var fskAge: Int? = nil

  var id: UUID { mediaId }
}

struct CatalogItemSummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let kind: MediaKind
  let title: String
  let originalTitle: String?
  let year: Int?
  let overview: String?
  let genres: [String]
  let poster: ArtworkSummary?
  let backdrop: ArtworkSummary?
  let availability: MediaAvailability
  let isFavorite: Bool
  let progress: PlaybackProgressResponse?
  let addedAt: String
  let parentTitle: String?
  let seasonNumber: Int?
  let episodeNumber: Int?
  var watchState: CatalogWatchState? = nil
  var libraryAvailability: LibraryAvailability? = nil
  var parentId: UUID? = nil
  var continueWatchingHidden = false

  init(
    id: UUID, kind: MediaKind, title: String, originalTitle: String?, year: Int?,
    overview: String?, genres: [String], poster: ArtworkSummary?, backdrop: ArtworkSummary?,
    availability: MediaAvailability, isFavorite: Bool, progress: PlaybackProgressResponse?,
    addedAt: String, parentTitle: String? = nil, seasonNumber: Int? = nil,
    episodeNumber: Int? = nil, watchState: CatalogWatchState? = nil,
    libraryAvailability: LibraryAvailability? = nil, parentId: UUID? = nil,
    continueWatchingHidden: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.originalTitle = originalTitle
    self.year = year
    self.overview = overview
    self.genres = genres
    self.poster = poster
    self.backdrop = backdrop
    self.availability = availability
    self.isFavorite = isFavorite
    self.progress = progress
    self.addedAt = addedAt
    self.parentTitle = parentTitle
    self.seasonNumber = seasonNumber
    self.episodeNumber = episodeNumber
    self.watchState = watchState
    self.libraryAvailability = libraryAvailability
    self.parentId = parentId
    self.continueWatchingHidden = continueWatchingHidden
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, title, originalTitle, year, overview, genres, poster, backdrop, availability
    case isFavorite, progress, addedAt, parentTitle, seasonNumber, episodeNumber
    case watchState, libraryAvailability, parentId, continueWatchingHidden
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    kind = try values.decode(MediaKind.self, forKey: .kind)
    title = try values.decode(String.self, forKey: .title)
    originalTitle = try values.decodeIfPresent(String.self, forKey: .originalTitle)
    year = try values.decodeIfPresent(Int.self, forKey: .year)
    overview = try values.decodeIfPresent(String.self, forKey: .overview)
    genres = try values.decode([String].self, forKey: .genres)
    poster = try values.decodeIfPresent(ArtworkSummary.self, forKey: .poster)
    backdrop = try values.decodeIfPresent(ArtworkSummary.self, forKey: .backdrop)
    availability = try values.decode(MediaAvailability.self, forKey: .availability)
    isFavorite = try values.decode(Bool.self, forKey: .isFavorite)
    progress = try values.decodeIfPresent(PlaybackProgressResponse.self, forKey: .progress)
    addedAt = try values.decode(String.self, forKey: .addedAt)
    parentTitle = try values.decodeIfPresent(String.self, forKey: .parentTitle)
    seasonNumber = try values.decodeIfPresent(Int.self, forKey: .seasonNumber)
    episodeNumber = try values.decodeIfPresent(Int.self, forKey: .episodeNumber)
    watchState = try values.decodeIfPresent(CatalogWatchState.self, forKey: .watchState)
    libraryAvailability = try values.decodeIfPresent(
      LibraryAvailability.self, forKey: .libraryAvailability)
    parentId = try values.decodeIfPresent(UUID.self, forKey: .parentId)
    continueWatchingHidden =
      try values.decodeIfPresent(Bool.self, forKey: .continueWatchingHidden) ?? false
  }

  var isPlayable: Bool {
    availability == .available && kind != .series
      && libraryAvailability != .unavailable && libraryAvailability != .error
  }
  var progressFraction: Double? {
    guard let progress, progress.durationMilliseconds > 0, !progress.isCompleted else { return nil }
    return min(
      max(Double(progress.positionMilliseconds) / Double(progress.durationMilliseconds), 0), 1)
  }
}

struct EpisodePresentation: Codable, Identifiable, Equatable, Sendable {
  let item: CatalogItemSummary
  let seasonNumber: Int
  let episodeNumber: Int

  var id: UUID { item.id }
}

struct SupplementPresentation: Codable, Identifiable, Equatable, Sendable {
  let item: CatalogItemSummary
  let category: String
  let seasonNumber: Int?

  var id: UUID { item.id }
}

struct SeasonPresentation: Codable, Identifiable, Equatable, Sendable {
  let number: Int
  let episodes: [EpisodePresentation]
  let supplements: [SupplementPresentation]

  var id: Int { number }
}

struct CatalogDetailPresentation: Codable, Equatable, Sendable {
  let item: CatalogItemSummary
  let metadata: MediaMetadataSummary
  let seasons: [SeasonPresentation]
  let supplements: [SupplementPresentation]
}

struct CollectionSummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let poster: ArtworkSummary?
  let items: [CatalogItemSummary]
}

struct HomeResponse: Codable, Equatable, Sendable {
  let recommendation: CatalogItemSummary?
  let continueWatching: [CatalogItemSummary]
  let recentlyAdded: [CatalogItemSummary]
  let favorites: [CatalogItemSummary]
  let collections: [CollectionSummary]
  let recommendationChangesAt: String
}

struct MetadataCandidateSummary: Codable, Identifiable, Equatable, Sendable {
  let provider: String
  let providerMediaId: String
  let mediaType: String
  let title: String
  let originalTitle: String?
  let year: Int?
  let overview: String?
  let posterPath: String?
  let confidence: Double

  var id: String { "\(provider):\(mediaType):\(providerMediaId)" }
}

struct MetadataReviewSummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let mediaId: UUID
  let title: String
  let reason: String
  let state: MetadataReviewState
  let candidates: [MetadataCandidateSummary]
  let updatedAt: String
}

struct SaveCollectionRequest: Encodable, Sendable {
  let name: String
  let mediaIds: [UUID]
}

struct SetFavoriteRequest: Encodable, Sendable {
  let isFavorite: Bool
}

struct SelectMetadataMatchRequest: Encodable, Sendable {
  let providerMediaId: String
  let mediaType: String
}

struct UpdateMediaMetadataRequest: Encodable, Sendable {
  let title: String?
  let originalTitle: String?
  let overview: String?
  let releaseDate: String?
  let runtimeMinutes: Int?
  let rating: Double?
  let contentRating: String?
  let genres: [String]?
  let studios: [String]?
  let countries: [String]?
  let clearFields: [String]?
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
  var revision: Int64? = nil
  var lastMutationId: UUID? = nil
}

struct UpdatePlaybackProgressRequest: Encodable, Equatable, Sendable {
  let positionMilliseconds: Int64
  let durationMilliseconds: Int64
  let isFinished: Bool
  var expectedRevision: Int64? = nil
  var enforceRevision: Bool? = nil
  var clientMutationId: UUID? = nil
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

struct MetadataProviderStatus: Codable, Equatable, Sendable {
  let enabled: Bool
  let hasToken: Bool
  let language: String
  let artworkBytes: Int64
  let artworkLimitBytes: Int64
  let provider: String
  let attribution: String
}

struct UpdateMetadataProviderRequest: Encodable, Sendable {
  let enabled: Bool
  let language: String
  let token: String?
}

enum MetadataJobState: String, Codable, Sendable {
  case queued, running, completed, failed, interrupted, cancelled
}

enum MetadataJobMode: String, Codable, Sendable {
  case incremental, fullRefresh, singleItem, retryFailed
}

struct MetadataJobSummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let libraryId: UUID?
  let mediaId: UUID?
  let state: MetadataJobState
  let itemsTotal: Int
  let itemsProcessed: Int
  let itemsMatched: Int
  let itemsNeedingReview: Int
  let itemsFailed: Int
  let error: String?
  let createdAt: String
  let startedAt: String?
  let completedAt: String?
  var mode: MetadataJobMode? = nil
  var attempt: Int? = nil
  var nextAttemptAt: String? = nil
  var waitReason: String? = nil
  var itemsSkipped: Int? = nil

  func waitingStatus(locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
    guard state == .queued || state == .running,
      waitReason != nil || nextAttemptAt != nil
    else { return nil }
    let reason =
      switch waitReason {
      case "tmdb": "Waiting for TMDB"
      case "storage": "Waiting for writable storage"
      default: "Waiting"
      }
    guard let nextAttemptAt else { return reason }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard
      let date = iso.date(from: nextAttemptAt)
        ?? ISO8601DateFormatter().date(from: nextAttemptAt)
    else { return reason }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return "\(reason) · Retry at \(formatter.string(from: date))"
  }
}

enum SyncChangeArea: String, Codable, Sendable {
  case catalog, libraries, metadata, collections, userState
}

struct SyncChangesResponse: Codable, Equatable, Sendable {
  let cursor: Int64
  let resetRequired: Bool
  let changedAreas: [SyncChangeArea]
  let changedMediaIds: [UUID]
  var generation: String? = nil
}

struct PlaybackQueueItem: Identifiable, Equatable, Sendable {
  let mediaId: UUID
  let title: String
  let subtitle: String?

  var id: UUID { mediaId }
}

struct PlaybackPresentation: Identifiable, Equatable, Sendable {
  let mediaId: UUID
  let title: String
  let subtitle: String?
  let queue: [PlaybackQueueItem]

  init(
    mediaId: UUID,
    title: String,
    subtitle: String?,
    queue: [PlaybackQueueItem] = []
  ) {
    self.mediaId = mediaId
    self.title = title
    self.subtitle = subtitle
    self.queue = queue
  }

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
  /// Set only after the bundled host and the pinned connection identify the same server.
  let locallyManaged: Bool?
  /// Present only in memory; Keychain rejects viewing credentials.
  let viewingSession: Bool?
  var isViewingSession: Bool { viewingSession == true }

  init(
    serverId: UUID,
    name: String,
    baseURL: URL,
    publicKeyFingerprint: String,
    token: String,
    sessionId: UUID,
    expiresAt: String,
    user: UserSummary? = nil,
    locallyManaged: Bool? = nil,
    viewingSession: Bool? = nil
  ) {
    self.serverId = serverId
    self.name = name
    self.baseURL = baseURL
    self.publicKeyFingerprint = publicKeyFingerprint
    self.token = token
    self.sessionId = sessionId
    self.expiresAt = expiresAt
    self.user = user
    self.locallyManaged = locallyManaged
    self.viewingSession = viewingSession
  }

  func retainingLocalHosting() -> StoredServerProfile {
    StoredServerProfile(
      serverId: serverId, name: name, baseURL: baseURL,
      publicKeyFingerprint: publicKeyFingerprint, token: token,
      sessionId: sessionId, expiresAt: expiresAt, user: user, locallyManaged: true,
      viewingSession: viewingSession)
  }

  func changingAddress(_ address: URL, name: String? = nil) -> StoredServerProfile {
    StoredServerProfile(
      serverId: serverId, name: name ?? self.name, baseURL: address,
      publicKeyFingerprint: publicKeyFingerprint, token: token, sessionId: sessionId,
      expiresAt: expiresAt, user: user, locallyManaged: locallyManaged,
      viewingSession: viewingSession)
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
