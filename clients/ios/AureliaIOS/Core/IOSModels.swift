import Foundation

// MARK: - Server Info & Discovery

public struct IOSServerInfo: Codable, Sendable, Equatable {
  public let serverId: UUID
  public let name: String
  public let version: String
  public let isSetup: Bool
  public let lanAccessEnabled: Bool
  public let lanHttpsPort: Int?
  public let publicKeyFingerprint: String
  public let displayFingerprint: String
  public let capabilities: [String]
  public let wakeOnLanAddresses: [String]?

  public init(
    serverId: UUID,
    name: String,
    version: String,
    isSetup: Bool,
    lanAccessEnabled: Bool,
    lanHttpsPort: Int? = nil,
    publicKeyFingerprint: String,
    displayFingerprint: String,
    capabilities: [String] = [],
    wakeOnLanAddresses: [String]? = nil
  ) {
    self.serverId = serverId
    self.name = name
    self.version = version
    self.isSetup = isSetup
    self.lanAccessEnabled = lanAccessEnabled
    self.lanHttpsPort = lanHttpsPort
    self.publicKeyFingerprint = publicKeyFingerprint
    self.displayFingerprint = displayFingerprint
    self.capabilities = capabilities
    self.wakeOnLanAddresses = wakeOnLanAddresses
  }
}

// MARK: - Pairing & Auth

public struct IOSPairingStartResponse: Codable, Sendable, Equatable {
  public let pairingId: String
  public let code: String
  public let expiresAt: Date
  public let pollIntervalSeconds: Int

  public init(pairingId: String, code: String, expiresAt: Date, pollIntervalSeconds: Int) {
    self.pairingId = pairingId
    self.code = code
    self.expiresAt = expiresAt
    self.pollIntervalSeconds = pollIntervalSeconds
  }
}

public struct IOSPairingPollResponse: Codable, Sendable, Equatable {
  public let status: String  // "pending", "approved", "rejected", "expired"
  public let token: String?
  public let profile: IOSUserProfile?

  public init(status: String, token: String? = nil, profile: IOSUserProfile? = nil) {
    self.status = status
    self.token = token
    self.profile = profile
  }
}

public struct IOSUserProfile: Codable, Sendable, Equatable, Identifiable, Hashable {
  public let id: String
  public let name: String
  public let hasPin: Bool
  public let isAdmin: Bool
  public let avatarUrl: String?

  public init(
    id: String, name: String, hasPin: Bool, isAdmin: Bool = false, avatarUrl: String? = nil
  ) {
    self.id = id
    self.name = name
    self.hasPin = hasPin
    self.isAdmin = isAdmin
    self.avatarUrl = avatarUrl
  }
}

public struct IOSSwitchProfileResponse: Codable, Sendable, Equatable {
  public let token: String
  public let profile: IOSUserProfile

  public init(token: String, profile: IOSUserProfile) {
    self.token = token
    self.profile = profile
  }
}

// MARK: - Catalog & Media

public enum IOSMediaType: String, Codable, Sendable, Hashable {
  case movie
  case show
  case season
  case episode
}

public struct IOSCatalogItemSummary: Codable, Sendable, Equatable, Identifiable, Hashable {
  public let id: String
  public let type: IOSMediaType
  public let title: String
  public let originalTitle: String?
  public let releaseYear: Int?
  public let durationSeconds: Double?
  public let posterUrl: String?
  public let backdropUrl: String?
  public let overview: String?
  public let genres: [String]?
  public let watched: Bool
  public let positionSeconds: Double?
  public let rating: Double?
  public let seriesTitle: String?
  public let seasonNumber: Int?
  public let episodeNumber: Int?
  public let franchiseId: String?
  public let franchiseName: String?

  public init(
    id: String,
    type: IOSMediaType,
    title: String,
    originalTitle: String? = nil,
    releaseYear: Int? = nil,
    durationSeconds: Double? = nil,
    posterUrl: String? = nil,
    backdropUrl: String? = nil,
    overview: String? = nil,
    genres: [String]? = nil,
    watched: Bool = false,
    positionSeconds: Double? = nil,
    rating: Double? = nil,
    seriesTitle: String? = nil,
    seasonNumber: Int? = nil,
    episodeNumber: Int? = nil,
    franchiseId: String? = nil,
    franchiseName: String? = nil
  ) {
    self.id = id
    self.type = type
    self.title = title
    self.originalTitle = originalTitle
    self.releaseYear = releaseYear
    self.durationSeconds = durationSeconds
    self.posterUrl = posterUrl
    self.backdropUrl = backdropUrl
    self.overview = overview
    self.genres = genres
    self.watched = watched
    self.positionSeconds = positionSeconds
    self.rating = rating
    self.seriesTitle = seriesTitle
    self.seasonNumber = seasonNumber
    self.episodeNumber = episodeNumber
    self.franchiseId = franchiseId
    self.franchiseName = franchiseName
  }
}

public struct IOSCatalogIndexResponse: Codable, Sendable, Equatable {
  public let continueWatching: [IOSCatalogItemSummary]
  public let upNext: [IOSCatalogItemSummary]
  public let recentlyAdded: [IOSCatalogItemSummary]
  public let movies: [IOSCatalogItemSummary]
  public let shows: [IOSCatalogItemSummary]

  public init(
    continueWatching: [IOSCatalogItemSummary] = [],
    upNext: [IOSCatalogItemSummary] = [],
    recentlyAdded: [IOSCatalogItemSummary] = [],
    movies: [IOSCatalogItemSummary] = [],
    shows: [IOSCatalogItemSummary] = []
  ) {
    self.continueWatching = continueWatching
    self.upNext = upNext
    self.recentlyAdded = recentlyAdded
    self.movies = movies
    self.shows = shows
  }
}

public struct IOSCatalogDetailResponse: Codable, Sendable, Equatable {
  public let item: IOSCatalogItemSummary
  public let seasons: [IOSSeasonSummary]?
  public let franchise: IOSFranchiseSummary?
  public let collections: [IOSCollectionSummary]?

  public init(
    item: IOSCatalogItemSummary,
    seasons: [IOSSeasonSummary]? = nil,
    franchise: IOSFranchiseSummary? = nil,
    collections: [IOSCollectionSummary]? = nil
  ) {
    self.item = item
    self.seasons = seasons
    self.franchise = franchise
    self.collections = collections
  }
}

public struct IOSSeasonSummary: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let seasonNumber: Int
  public let title: String
  public let episodes: [IOSCatalogItemSummary]

  public init(id: String, seasonNumber: Int, title: String, episodes: [IOSCatalogItemSummary]) {
    self.id = id
    self.seasonNumber = seasonNumber
    self.title = title
    self.episodes = episodes
  }
}

// MARK: - Collections & Franchises

public struct IOSCollectionSummary: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let isSmart: Bool
  public let isShared: Bool
  public let itemCount: Int
  public let posterUrl: String?

  public init(
    id: String,
    name: String,
    isSmart: Bool = false,
    isShared: Bool = false,
    itemCount: Int = 0,
    posterUrl: String? = nil
  ) {
    self.id = id
    self.name = name
    self.isSmart = isSmart
    self.isShared = isShared
    self.itemCount = itemCount
    self.posterUrl = posterUrl
  }
}

public struct IOSCollectionDetailResponse: Codable, Sendable, Equatable {
  public let collection: IOSCollectionSummary
  public let items: [IOSCatalogItemSummary]

  public init(collection: IOSCollectionSummary, items: [IOSCatalogItemSummary]) {
    self.collection = collection
    self.items = items
  }
}

public struct IOSFranchiseSummary: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let movieCount: Int
  public let posterUrl: String?

  public init(id: String, name: String, movieCount: Int, posterUrl: String? = nil) {
    self.id = id
    self.name = name
    self.movieCount = movieCount
    self.posterUrl = posterUrl
  }
}

public struct IOSFranchiseDetailResponse: Codable, Sendable, Equatable {
  public let franchise: IOSFranchiseSummary
  public let movies: [IOSCatalogItemSummary]

  public init(franchise: IOSFranchiseSummary, movies: [IOSCatalogItemSummary]) {
    self.franchise = franchise
    self.movies = movies
  }
}

// MARK: - Playback & Streams

public struct IOSStreamPlanResponse: Codable, Sendable, Equatable {
  public let ticket: String
  public let streamUrl: String
  public let audioTracks: [IOSAudioTrack]
  public let subtitleTracks: [IOSSubtitleTrack]
  public let scrubPreviewIndexUrl: String?
  public let resumePositionSeconds: Double?

  public init(
    ticket: String,
    streamUrl: String,
    audioTracks: [IOSAudioTrack] = [],
    subtitleTracks: [IOSSubtitleTrack] = [],
    scrubPreviewIndexUrl: String? = nil,
    resumePositionSeconds: Double? = nil
  ) {
    self.ticket = ticket
    self.streamUrl = streamUrl
    self.audioTracks = audioTracks
    self.subtitleTracks = subtitleTracks
    self.scrubPreviewIndexUrl = scrubPreviewIndexUrl
    self.resumePositionSeconds = resumePositionSeconds
  }
}

public struct IOSAudioTrack: Codable, Sendable, Equatable, Identifiable {
  public let id: Int
  public let language: String?
  public let title: String?
  public let isDefault: Bool

  public init(id: Int, language: String?, title: String?, isDefault: Bool = false) {
    self.id = id
    self.language = language
    self.title = title
    self.isDefault = isDefault
  }
}

public struct IOSSubtitleTrack: Codable, Sendable, Equatable, Identifiable {
  public let id: Int
  public let language: String?
  public let title: String?
  public let isForced: Bool
  public let isSdh: Bool
  public let isSidecar: Bool
  public let isDefault: Bool

  public init(
    id: Int,
    language: String?,
    title: String?,
    isForced: Bool = false,
    isSdh: Bool = false,
    isSidecar: Bool = false,
    isDefault: Bool = false
  ) {
    self.id = id
    self.language = language
    self.title = title
    self.isForced = isForced
    self.isSdh = isSdh
    self.isSidecar = isSidecar
    self.isDefault = isDefault
  }
}

public struct IOSProgressUpdateRequest: Codable, Sendable, Equatable {
  public let positionSeconds: Double
  public let durationSeconds: Double
  public let watched: Bool

  public init(positionSeconds: Double, durationSeconds: Double, watched: Bool) {
    self.positionSeconds = positionSeconds
    self.durationSeconds = durationSeconds
    self.watched = watched
  }
}

// MARK: - History & Statistics

public struct IOSWatchEvent: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let itemId: String
  public let title: String
  public let itemType: IOSMediaType
  public let watchedAt: Date
  public let durationSeconds: Double
  public let posterUrl: String?

  public init(
    id: String,
    itemId: String,
    title: String,
    itemType: IOSMediaType,
    watchedAt: Date,
    durationSeconds: Double,
    posterUrl: String? = nil
  ) {
    self.id = id
    self.itemId = itemId
    self.title = title
    self.itemType = itemType
    self.watchedAt = watchedAt
    self.durationSeconds = durationSeconds
    self.posterUrl = posterUrl
  }
}

public struct IOSWatchHistoryResponse: Codable, Sendable, Equatable {
  public let events: [IOSWatchEvent]
  public let totalCount: Int
  public let page: Int
  public let pageSize: Int

  public init(events: [IOSWatchEvent], totalCount: Int, page: Int, pageSize: Int) {
    self.events = events
    self.totalCount = totalCount
    self.page = page
    self.pageSize = pageSize
  }
}

public struct IOSPersonalStatisticsResponse: Codable, Sendable, Equatable {
  public let totalHours: Double
  public let monthHours: Double
  public let weekHours: Double
  public let topGenres: [String]
  public let currentStreakDays: Int
  public let longestStreakDays: Int
  public let busiestWeekday: String?
  public let busiestHour: Int?
  public let completionRate: Double

  public init(
    totalHours: Double,
    monthHours: Double,
    weekHours: Double,
    topGenres: [String] = [],
    currentStreakDays: Int = 0,
    longestStreakDays: Int = 0,
    busiestWeekday: String? = nil,
    busiestHour: Int? = nil,
    completionRate: Double = 0
  ) {
    self.totalHours = totalHours
    self.monthHours = monthHours
    self.weekHours = weekHours
    self.topGenres = topGenres
    self.currentStreakDays = currentStreakDays
    self.longestStreakDays = longestStreakDays
    self.busiestWeekday = busiestWeekday
    self.busiestHour = busiestHour
    self.completionRate = completionRate
  }
}

// MARK: - Remote Playback

public struct IOSRemotePlayerDevice: Codable, Sendable, Equatable, Identifiable {
  public let deviceId: String
  public let deviceName: String
  public let platform: String
  public let isPlaying: Bool
  public let currentTitle: String?

  public var id: String { deviceId }

  public init(
    deviceId: String,
    deviceName: String,
    platform: String,
    isPlaying: Bool = false,
    currentTitle: String? = nil
  ) {
    self.deviceId = deviceId
    self.deviceName = deviceName
    self.platform = platform
    self.isPlaying = isPlaying
    self.currentTitle = currentTitle
  }
}

public struct IOSRemotePlaybackCommand: Codable, Sendable, Equatable {
  public let action: String  // "play", "pause", "resume", "seek", "stop"
  public let titleId: String?
  public let title: String?
  public let positionSeconds: Double?

  public init(
    action: String, titleId: String? = nil, title: String? = nil, positionSeconds: Double? = nil
  ) {
    self.action = action
    self.titleId = titleId
    self.title = title
    self.positionSeconds = positionSeconds
  }
}
