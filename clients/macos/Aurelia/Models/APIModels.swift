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
  var wakeOnLanAddresses: [String]? = nil
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

/// A folder on the server computer that can become a storage location.
struct ServerFolder: Codable, Hashable, Sendable {
  let name: String
  let path: String
}

/// The folders inside one folder on the server; without a path, the usual places for drives.
struct ServerFolderListing: Codable, Equatable, Sendable {
  let path: String?
  let parent: String?
  let folders: [ServerFolder]
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

  var expiryDate: Date? { ServerDate.parse(expiresAt) }
}

/// Server timestamps are ISO 8601, with or without fractional seconds.
enum ServerDate {
  static func parse(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
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
    guard revokedAt == nil, let expiry = ServerDate.parse(expiresAt) else { return false }
    return expiry > Date()
  }

  var lastSeenDate: Date? { ServerDate.parse(lastSeenAt) }
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

struct ArtworkSummary: Codable, Identifiable, Equatable, Hashable, Sendable {
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

  init(
    stubId id: UUID,
    kind: MediaKind,
    title: String = "",
    availability: MediaAvailability = .available,
    isFavorite: Bool = false
  ) {
    self.init(
      id: id,
      kind: kind,
      title: title,
      originalTitle: nil,
      year: nil,
      overview: nil,
      genres: [],
      poster: nil,
      backdrop: nil,
      availability: availability,
      isFavorite: isFavorite,
      progress: nil,
      addedAt: ""
    )
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
  var franchise: CollectionSummary? = nil

  enum CodingKeys: String, CodingKey {
    case item, metadata, seasons, supplements, franchise
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    item = try container.decode(CatalogItemSummary.self, forKey: .item)
    metadata = try container.decode(MediaMetadataSummary.self, forKey: .metadata)
    seasons = try container.decodeIfPresent([SeasonPresentation].self, forKey: .seasons) ?? []
    supplements =
      try container.decodeIfPresent([SupplementPresentation].self, forKey: .supplements) ?? []
    franchise = try container.decodeIfPresent(CollectionSummary.self, forKey: .franchise)
  }

  init(
    item: CatalogItemSummary, metadata: MediaMetadataSummary, seasons: [SeasonPresentation] = [],
    supplements: [SupplementPresentation] = [], franchise: CollectionSummary? = nil
  ) {
    self.item = item
    self.metadata = metadata
    self.seasons = seasons
    self.supplements = supplements
    self.franchise = franchise
  }
}

struct CollectionSummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let poster: ArtworkSummary?
  let items: [CatalogItemSummary]
  var isSmart: Bool = false
  var totalCount: Int = 0
  var isShared: Bool = true
  var userId: UUID? = nil
  var rulesJson: String? = nil

  enum CodingKeys: String, CodingKey {
    case id, name, poster, items, isSmart, totalCount, isShared, userId, rulesJson
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    poster = try container.decodeIfPresent(ArtworkSummary.self, forKey: .poster)
    items = try container.decodeIfPresent([CatalogItemSummary].self, forKey: .items) ?? []
    isSmart = try container.decodeIfPresent(Bool.self, forKey: .isSmart) ?? false
    let rawCount = try container.decodeIfPresent(Int.self, forKey: .totalCount) ?? items.count
    totalCount = rawCount > 0 ? rawCount : items.count
    isShared = try container.decodeIfPresent(Bool.self, forKey: .isShared) ?? true
    userId = try container.decodeIfPresent(UUID.self, forKey: .userId)
    rulesJson = try container.decodeIfPresent(String.self, forKey: .rulesJson)
  }

  init(
    id: UUID, name: String, poster: ArtworkSummary? = nil, items: [CatalogItemSummary] = [],
    isSmart: Bool = false, totalCount: Int = 0, isShared: Bool = true, userId: UUID? = nil,
    rulesJson: String? = nil
  ) {
    self.id = id
    self.name = name
    self.poster = poster
    self.items = items
    self.isSmart = isSmart
    self.totalCount = totalCount > 0 ? totalCount : items.count
    self.isShared = isShared
    self.userId = userId
    self.rulesJson = rulesJson
  }
}

/// A smart list's rules in the editor's terms ("movies", "watched", "any"). They travel in the
/// protocol's names (`kind: movie`, `watchedState`, `textContains`, `combination: or`); lists
/// that earlier versions saved in the editor's names are still read.
struct SmartCollectionRules: Codable, Equatable, Sendable {
  var kind: String? = nil
  var genres: [String]? = nil
  var yearMin: Int? = nil
  var yearMax: Int? = nil
  var ratingMin: Double? = nil
  var ratingMax: Double? = nil
  var watched: String? = nil
  var addedWithinDays: Int? = nil
  var favoritesOnly: Bool? = nil
  var search: String? = nil
  var match: String? = nil

  private enum CodingKeys: String, CodingKey {
    case kind, genres, yearMin, yearMax, ratingMin, ratingMax, watchedState, addedWithinDays
    case favoritesOnly, textContains, combination
    case watched, search, match
  }

  init(
    kind: String? = nil, genres: [String]? = nil, yearMin: Int? = nil, yearMax: Int? = nil,
    ratingMin: Double? = nil, ratingMax: Double? = nil, watched: String? = nil,
    addedWithinDays: Int? = nil, favoritesOnly: Bool? = nil, search: String? = nil,
    match: String? = nil
  ) {
    self.kind = kind
    self.genres = genres
    self.yearMin = yearMin
    self.yearMax = yearMax
    self.ratingMin = ratingMin
    self.ratingMax = ratingMax
    self.watched = watched
    self.addedWithinDays = addedWithinDays
    self.favoritesOnly = favoritesOnly
    self.search = search
    self.match = match
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decodeIfPresent(String.self, forKey: .kind) {
    case "movie", "movies": kind = "movies"
    case "series": kind = "series"
    default: kind = nil
    }
    genres = try values.decodeIfPresent([String].self, forKey: .genres)
    yearMin = try values.decodeIfPresent(Int.self, forKey: .yearMin)
    yearMax = try values.decodeIfPresent(Int.self, forKey: .yearMax)
    ratingMin = try values.decodeIfPresent(Double.self, forKey: .ratingMin)
    ratingMax = try values.decodeIfPresent(Double.self, forKey: .ratingMax)
    watched =
      try values.decodeIfPresent(String.self, forKey: .watchedState)
      ?? values.decodeIfPresent(String.self, forKey: .watched)
    addedWithinDays = try values.decodeIfPresent(Int.self, forKey: .addedWithinDays)
    favoritesOnly = try values.decodeIfPresent(Bool.self, forKey: .favoritesOnly)
    search =
      try values.decodeIfPresent(String.self, forKey: .textContains)
      ?? values.decodeIfPresent(String.self, forKey: .search)
    if let combination = try values.decodeIfPresent(String.self, forKey: .combination) {
      match = combination == "or" ? "any" : "all"
    } else {
      match = try values.decodeIfPresent(String.self, forKey: .match)
    }
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encodeIfPresent(kind.map { $0 == "movies" ? "movie" : $0 }, forKey: .kind)
    try values.encodeIfPresent(genres, forKey: .genres)
    try values.encodeIfPresent(yearMin, forKey: .yearMin)
    try values.encodeIfPresent(yearMax, forKey: .yearMax)
    try values.encodeIfPresent(ratingMin, forKey: .ratingMin)
    try values.encodeIfPresent(ratingMax, forKey: .ratingMax)
    try values.encodeIfPresent(watched, forKey: .watchedState)
    try values.encodeIfPresent(addedWithinDays, forKey: .addedWithinDays)
    try values.encodeIfPresent(favoritesOnly, forKey: .favoritesOnly)
    try values.encodeIfPresent(search, forKey: .textContains)
    try values.encode(match == "any" ? "or" : "and", forKey: .combination)
  }
}

struct LiveSubtitleTrack: Codable, Identifiable, Equatable, Sendable {
  var id: Int { index }
  let index: Int
  let codec: String
  let language: String
  let title: String
  let isDefault: Bool
  let isForced: Bool
  let supported: Bool
  let isSidecar: Bool
  let isSdh: Bool

  enum CodingKeys: String, CodingKey {
    case index, codec, language, title, isDefault, isForced, supported, isSidecar, isSdh
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    index = try container.decode(Int.self, forKey: .index)
    codec = try container.decodeIfPresent(String.self, forKey: .codec) ?? ""
    language = try container.decodeIfPresent(String.self, forKey: .language) ?? "und"
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    isForced = try container.decodeIfPresent(Bool.self, forKey: .isForced) ?? false
    supported = try container.decodeIfPresent(Bool.self, forKey: .supported) ?? true
    isSidecar = try container.decodeIfPresent(Bool.self, forKey: .isSidecar) ?? false
    isSdh = try container.decodeIfPresent(Bool.self, forKey: .isSdh) ?? false
  }

  init(
    index: Int, codec: String = "", language: String = "und", title: String = "",
    isDefault: Bool = false, isForced: Bool = false, supported: Bool = true,
    isSidecar: Bool = false, isSdh: Bool = false
  ) {
    self.index = index
    self.codec = codec
    self.language = language
    self.title = title
    self.isDefault = isDefault
    self.isForced = isForced
    self.supported = supported
    self.isSidecar = isSidecar
    self.isSdh = isSdh
  }
}

/// One entry of the profile's own viewing history, as the server reports it.
struct WatchHistoryItem: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let mediaId: UUID
  let title: String
  /// "Series · S1E2" for episodes, the year for movies.
  let eyebrow: String?
  let year: Int?
  let kind: String
  let poster: ArtworkSummary?
  let watchedAt: String
  let positionMilliseconds: Int64
  let durationMilliseconds: Int64
  let secondsWatched: Int64
  let isCompleted: Bool

  var watchedDate: Date? { ServerDate.parse(watchedAt) }
  var completionPercentage: Double {
    if isCompleted { return 100 }
    guard durationMilliseconds > 0 else { return 0 }
    return min(100, Double(positionMilliseconds) / Double(durationMilliseconds) * 100)
  }
}

struct WatchHistoryPage: Codable, Equatable, Sendable {
  let items: [WatchHistoryItem]
  let offset: Int
  let limit: Int
  let total: Int
}

struct PeriodHours: Codable, Equatable, Sendable {
  let period: String
  let hours: Double
}

struct NamedCount: Codable, Equatable, Sendable {
  let name: String
  let count: Int
  /// Watch time in hours; older servers send only the count.
  let hours: Double?
}

struct YearInReview: Codable, Equatable, Sendable {
  let year: Int
  let totalHoursWatched: Double?
  let titlesWatched: Int?
  let moviesWatched: Int?
  let episodesWatched: Int?
  let topGenre: String?
  let topTitle: String?
  let busiestDay: String?
  let busiestDayHours: Double?

  var totalHours: Double { totalHoursWatched ?? 0 }
  var totalTitles: Int { titlesWatched ?? 0 }
  var movieCount: Int { moviesWatched ?? 0 }
  var episodeCount: Int { episodesWatched ?? 0 }
}

struct UserStatistics: Codable, Equatable, Sendable {
  let totalHoursWatched: Double
  let hoursPast7Days: Double?
  let hoursPast30Days: Double?
  let hoursByWeek: [PeriodHours]?
  let hoursByMonth: [PeriodHours]?
  let topGenres: [NamedCount]?
  let topTitles: [NamedCount]?
  let currentStreakDays: Int?
  let longestStreakDays: Int?
  let busiestWeekday: String?
  let busiestTimeOfDay: String?
  let completionRate: Double?
  let yearsAvailable: [Int]?

  var weeklyHours: [PeriodHours] { hoursByWeek ?? [] }
  var monthlyHours: [PeriodHours] { hoursByMonth ?? [] }
  var completionRatePercent: Double { completionRate ?? 0 }
  var busiestDayOfWeek: String { busiestWeekday ?? "—" }
}

/// One file of a title that exists several times. Only the file name travels, never the path.
struct DuplicateItemSummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let kind: String
  let year: Int?
  let fileName: String
  let fileSize: Int64?
  let availability: String

  var isAvailable: Bool { availability == "available" }
}

struct DuplicateGroup: Codable, Identifiable, Equatable, Sendable {
  let key: String
  let title: String
  let kind: String
  let year: Int?
  let items: [DuplicateItemSummary]

  var id: String { key }
}

struct OfflineTitleSummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let kind: String
  let year: Int?
  let libraryName: String
  let fileName: String
  let lastSeenAt: String
  let daysOffline: Int

  var lastSeenDate: Date? { ServerDate.parse(lastSeenAt) }
}

struct UnmatchedTitleSummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let kind: String
  let year: Int?
  let fileName: String
  let issueReason: String
}

struct MergeMediaRequest: Encodable, Sendable {
  let sourceMediaId: UUID
  let targetMediaId: UUID
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
  var isSmart: Bool = false
  var isShared: Bool = false
  var rulesJson: String? = nil
}

struct SetFavoriteRequest: Encodable, Sendable {
  let isFavorite: Bool
}

struct SetWatchlistRequest: Encodable, Sendable {
  let isWatchlisted: Bool
}

struct WatchlistItemStateResponse: Codable, Equatable, Sendable {
  let mediaId: UUID
  let isWatchlisted: Bool
}

struct WatchlistResponse: Codable, Equatable, Sendable {
  let items: [CatalogItemSummary]
  let mediaIds: [UUID]
}

struct PersonDetailResponse: Codable, Equatable, Sendable {
  let name: String
  let subtitle: String?
  let profile: ArtworkSummary?
  let items: [CatalogItemSummary]
}

struct PersonSelection: Hashable, Sendable {
  let name: String
  let personKey: String?
  let profile: ArtworkSummary?
  let subtitle: String?
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

  var isFinished: Bool { state != .queued && state != .running }

  /// What a finished job did, in one line: "Done · 23 matched, 2 need review".
  var finishedSummary: String? {
    guard isFinished else { return nil }
    var parts: [String] = []
    if itemsMatched > 0 { parts.append("\(itemsMatched) matched") }
    if itemsNeedingReview > 0 {
      parts.append("\(itemsNeedingReview) need\(itemsNeedingReview == 1 ? "s" : "") review")
    }
    if let skipped = itemsSkipped, skipped > 0 { parts.append("\(skipped) skipped") }
    if itemsFailed > 0 { parts.append("\(itemsFailed) failed") }
    let detail = parts.isEmpty ? "\(itemsTotal) \(itemsTotal == 1 ? "title" : "titles") checked" : parts.joined(separator: ", ")
    switch state {
    case .completed: return "Done · " + detail
    case .cancelled: return "Stopped · " + detail
    default: return "Did not finish · " + (error ?? detail)
    }
  }

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
  let artwork: ArtworkSummary?

  init(mediaId: UUID, title: String, subtitle: String?, artwork: ArtworkSummary? = nil) {
    self.mediaId = mediaId
    self.title = title
    self.subtitle = subtitle
    self.artwork = artwork
  }

  var id: UUID { mediaId }
}

/// Progress is used only by an explicit Resume action. Episode navigation always plays from zero.
enum PlaybackStartIntent: Equatable, Sendable {
  case play, resume

  func position(progress: PlaybackProgressResponse, automaticResume: Bool) -> Int64 {
    self == .resume && automaticResume && !progress.isCompleted
      ? max(0, progress.positionMilliseconds) : 0
  }
}

struct PlaybackPresentation: Identifiable, Equatable, Sendable {
  let mediaId: UUID
  let title: String
  let subtitle: String?
  let queue: [PlaybackQueueItem]
  let previousItems: [PlaybackQueueItem]
  let startIntent: PlaybackStartIntent
  /// The series whose episodes share audio and subtitle choices; nil for a movie.
  let trackScope: UUID?
  let artwork: ArtworkSummary?

  init(
    mediaId: UUID,
    title: String,
    subtitle: String?,
    queue: [PlaybackQueueItem] = [],
    previousItems: [PlaybackQueueItem] = [],
    startIntent: PlaybackStartIntent = .play,
    trackScope: UUID? = nil,
    artwork: ArtworkSummary? = nil
  ) {
    self.mediaId = mediaId
    self.title = title
    self.subtitle = subtitle
    self.queue = queue
    self.previousItems = previousItems
    self.startIntent = startIntent
    self.trackScope = trackScope
    self.artwork = artwork
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

// MARK: Remote Playback Models

struct PlayerHeartbeatRequest: Codable, Sendable {
  let deviceId: String
  let deviceName: String
  let clientType: String
  let isPlaying: Bool
  let mediaId: UUID?
  let title: String?
  let positionSeconds: Double?
  let durationSeconds: Double?
  let isPaused: Bool
}

// Times arrive as ISO 8601 text, like every other server time; ServerDate reads them.
struct PlayerHeartbeatResponse: Codable, Sendable {
  let success: Bool
  let timestamp: String
}

struct RemotePlayerDevice: Codable, Identifiable, Equatable, Sendable {
  var id: String { deviceId }
  let deviceId: String
  let deviceName: String
  let clientType: String
  let isPlaying: Bool
  let mediaId: UUID?
  let title: String?
  let positionSeconds: Double?
  let durationSeconds: Double?
  let isPaused: Bool
  let lastSeen: String
}

struct RemotePlaybackCommandRequest: Codable, Sendable {
  let action: String
  let mediaId: UUID?
  let positionSeconds: Double?
  let skipSeconds: Double?
}

struct RemotePlaybackCommandResponse: Codable, Sendable {
  let commandId: UUID
  let status: String
}

struct RemotePlaybackCommand: Codable, Identifiable, Sendable {
  var id: UUID { commandId }
  let commandId: UUID
  let action: String
  let mediaId: UUID?
  let positionSeconds: Double?
  let skipSeconds: Double?
  let createdAt: String
}

// MARK: - Subtitle downloads

/// The server's OpenSubtitles setup. Keys and passwords never come back from the server.
struct SubtitleProviderStatus: Codable, Equatable, Sendable {
  let enabled: Bool
  let hasApiKey: Bool
  let hasAccount: Bool
  let accountName: String?
  let languages: [String]
  let automatic: Bool
  let provider: String
  let attribution: String
  let remainingDownloads: Int?
  let resetsAt: String?
  let lastAutomaticRunAt: String?
  let downloadedCount: Int
}

struct UpdateSubtitleProviderRequest: Encodable, Sendable {
  let enabled: Bool
  let languages: [String]
  let automatic: Bool
  var apiKey: String? = nil
  var accountName: String? = nil
  var accountPassword: String? = nil
}

struct SubtitleCandidate: Codable, Identifiable, Equatable, Sendable {
  let fileId: String
  let language: String
  let release: String?
  let hashMatch: Bool
  let hearingImpaired: Bool
  let foreignPartsOnly: Bool
  let machineTranslated: Bool
  let downloadCount: Int
  let fromTrusted: Bool
  var id: String { fileId }

  /// "Exact match · SDH · 1,204 downloads", the facts that help choose one.
  var details: String {
    var parts: [String] = []
    if hashMatch { parts.append("Matches this file") }
    if hearingImpaired { parts.append("SDH") }
    if foreignPartsOnly { parts.append("Foreign parts only") }
    if machineTranslated { parts.append("Machine translated") }
    if fromTrusted { parts.append("Trusted") }
    parts.append("\(downloadCount.formatted()) downloads")
    return parts.joined(separator: " · ")
  }
}

struct DownloadSubtitleRequest: Encodable, Sendable {
  let fileId: String
  let language: String
  let release: String?
  let hearingImpaired: Bool
  let foreignPartsOnly: Bool
}

struct DownloadedSubtitle: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let language: String
  let title: String
  let hearingImpaired: Bool
  let forced: Bool
  let provider: String
  let release: String?
  let downloadedAt: String
  let automatic: Bool
}

enum SubtitleLanguages {
  /// The languages offered in Settings, by their English names.
  static let choices = [
    "en", "de", "fr", "es", "it", "nl", "pt", "sv", "da", "no", "fi", "pl", "cs", "tr", "ru", "ja",
    "ko", "zh", "ar",
  ]

  static func name(_ code: String) -> String {
    Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
  }
}

// MARK: - Watch Together

struct WatchPartySummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let mediaId: UUID
  let title: String
  let hostName: String
  let memberCount: Int
  let isPlaying: Bool
}

struct WatchPartyMember: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let deviceName: String
  let isBuffering: Bool
  let isHost: Bool
  let isYou: Bool
}

/// The shared state of a Watch Together party; dates are ISO 8601 strings from the server.
struct WatchPartyState: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let mediaId: UUID
  let title: String
  let isPlaying: Bool
  let isWaiting: Bool
  let positionMilliseconds: Int64
  let updatedAt: String
  let serverTime: String
  let revision: Int64
  let members: [WatchPartyMember]
  let lastAction: String?
  let lastActionBy: String?

  var me: WatchPartyMember? { members.first { $0.isYou } }

  /// "Mia paused", the last thing someone else did, for a short notice in the player.
  var notice: String? {
    guard let lastAction, let lastActionBy else { return nil }
    switch lastAction {
    case "play": return "\(lastActionBy) pressed play"
    case "pause": return "\(lastActionBy) paused"
    case "seek": return "\(lastActionBy) jumped to another moment"
    case "joined": return "\(lastActionBy) joined"
    case "left": return "\(lastActionBy) left"
    case "change": return "\(lastActionBy) started \(title)"
    default: return nil
    }
  }
}

struct CreateWatchPartyRequest: Encodable, Sendable {
  let mediaId: UUID
  let positionMilliseconds: Int64
  let isPlaying: Bool
  let deviceName: String?
}

struct JoinWatchPartyRequest: Encodable, Sendable {
  let deviceName: String?
}

struct WatchPartyCommandRequest: Encodable, Sendable {
  let action: String
  var positionMilliseconds: Int64? = nil
  var mediaId: UUID? = nil
}
