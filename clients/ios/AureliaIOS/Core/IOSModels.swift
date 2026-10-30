import Foundation

enum IOSCoreError: LocalizedError, Equatable, Sendable {
  case invalidAddress
  case identityMismatch
  case invalidResponse
  case unsupportedServer
  case profileRequired
  case server(status: Int, code: String?, message: String?, retryAfter: TimeInterval?)

  var statusCode: Int? {
    if case .server(let status, _, _, _) = self { return status }
    return nil
  }
  var code: String? {
    if case .server(_, let code, _, _) = self { return code }
    return nil
  }
  var retryAfter: TimeInterval? {
    if case .server(_, _, _, let delay) = self { return delay }
    return nil
  }
  var isTransient: Bool {
    guard let statusCode else { return false }
    return statusCode == 408 || statusCode == 429 || statusCode >= 500
  }
  var httpStatus: Int? { statusCode }
  var problemCode: String? { code }
  var retryDelay: TimeInterval? { retryAfter }
  var isConflict: Bool { statusCode == 409 }
  var isAuthenticationFailure: Bool { statusCode == 401 || statusCode == 403 }
  var errorDescription: String? {
    switch self {
    case .invalidAddress: "Enter a valid HTTPS server address."
    case .identityMismatch:
      "The server identity has changed. Confirm the server on your Mac before reconnecting."
    case .invalidResponse: "The server returned an invalid response."
    case .unsupportedServer: "Update Aurelia Server to 1.5.5 or later to connect this device."
    case .profileRequired: "Choose a profile to continue."
    case .server(_, _, let message, _): message ?? "The server request could not be completed."
    }
  }
}

enum IOSServerDate {
  static func parse(_ value: String) -> Date? {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = parser.date(from: value) { return date }
    parser.formatOptions = [.withInternetDateTime]
    return parser.date(from: value)
  }
}

/// A saved server that answers not at all, as when its computer sleeps, unlike one that answers with
/// an error. This device cannot wake a server; Aurelia on a Mac can.
enum IOSServerReachability {
  static func isUnreachable(_ error: Error) -> Bool {
    guard let error = error as? URLError else { return false }
    return [
      .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
      .notConnectedToInternet, .secureConnectionFailed,
    ].contains(error.code)
  }
}

struct IOSStoredConnection: Codable, Equatable, Sendable {
  let serverID: UUID
  let name: String
  let baseURL: URL
  let fingerprint: String
  let deviceToken: String
  let deviceSessionID: UUID
  var pendingAcknowledgement: IOSPendingPairingAcknowledgement? = nil

  func validate() throws {
    guard IOSServerAddress.isValid(baseURL), IOSServerIdentity.isValidFingerprint(fingerprint),
      (32...256).contains(deviceToken.utf8.count), !deviceToken.contains(where: \.isWhitespace)
    else { throw IOSCoreError.invalidResponse }
  }

  func relocating(to address: URL) -> Self {
    Self(
      serverID: serverID, name: name, baseURL: address, fingerprint: fingerprint,
      deviceToken: deviceToken, deviceSessionID: deviceSessionID,
      pendingAcknowledgement: pendingAcknowledgement)
  }
}

struct IOSPendingPairingAcknowledgement: Codable, Equatable, Sendable {
  let id: UUID
  let secret: String
  let expiresAt: String
}

struct IOSServerInfo: Codable, Equatable, Sendable {
  let serverId: UUID
  let name: String
  let version: String
  let isSetup: Bool
  let lanAccessEnabled: Bool
  let lanHttpsPort: Int?
  let publicKeyFingerprint: String?
  let displayFingerprint: String?
  let capabilities: [String]?
  /// Hardware addresses of the server's network cards, reported for Wake-on-LAN.
  var wakeOnLanAddresses: [String]? = nil
}

struct IOSInspectedServer: Equatable, Sendable {
  let baseURL: URL
  let info: IOSServerInfo
  let fingerprint: String

  func connection(authentication: IOSAuthentication) throws -> IOSStoredConnection {
    let connection = IOSStoredConnection(
      serverID: info.serverId, name: info.name,
      baseURL: baseURL, fingerprint: fingerprint, deviceToken: authentication.token,
      deviceSessionID: authentication.sessionId)
    try connection.validate()
    return connection
  }

  func validate(against connection: IOSStoredConnection) throws {
    guard info.serverId == connection.serverID,
      fingerprint.caseInsensitiveCompare(connection.fingerprint) == .orderedSame
    else { throw IOSCoreError.identityMismatch }
  }
}

struct IOSCapabilities: Codable, Equatable, Sendable {
  let formatVersion: Int
  let minimumClientVersion: String
  let capabilities: [String]?

  func validate() throws {
    // Marketing versions belong to different products. TV 0.1 implements the
    // versioned protocol; it must not be compared with Mac minimumClientVersion.
    guard (1...2).contains(formatVersion),
      Set(capabilities ?? []).isSuperset(of: ["device-authorization-v1", "library-state-v1"])
    else { throw IOSCoreError.unsupportedServer }
  }
  var supportsArtworkVariants: Bool { capabilities?.contains("artwork-variants-v1") == true }
  var supportsWatchlistAndPeople: Bool { capabilities?.contains("watchlist-people-v1") == true }
  var supportsScrubPreviews: Bool { capabilities?.contains("scrub-previews-v1") == true }
}

struct IOSUser: Codable, Equatable, Sendable {
  let id: UUID
  let username: String
  let role: String
}

struct IOSAuthentication: Codable, Equatable, Sendable {
  let user: IOSUser
  let sessionId: UUID
  let token: String
  let expiresAt: String
}

struct IOSProfileSession: Codable, Equatable, Sendable {
  let user: IOSUser
  let sessionId: UUID
  let token: String
  let expiresAt: String

  func validate(profileID: UUID, now: Date = Date()) throws {
    guard user.id == profileID, (32...256).contains(token.utf8.count),
      !token.contains(where: \.isWhitespace),
      let expiry = IOSServerDate.parse(expiresAt), expiry > now
    else { throw IOSCoreError.invalidResponse }
  }
}

struct IOSWatchingProfile: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let role: String
  let needsPinSetup: Bool
  let pinProtectionEnabled: Bool

  init(
    id: UUID, name: String, role: String, needsPinSetup: Bool,
    pinProtectionEnabled: Bool = true
  ) {
    self.id = id
    self.name = name
    self.role = role
    self.needsPinSetup = needsPinSetup
    self.pinProtectionEnabled = pinProtectionEnabled
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, role, needsPinSetup, pinProtectionEnabled
  }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    role = try values.decode(String.self, forKey: .role)
    needsPinSetup = try values.decode(Bool.self, forKey: .needsPinSetup)
    pinProtectionEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .pinProtectionEnabled) ?? true
  }
}

struct IOSProfilePicker: Codable, Equatable, Sendable {
  let formatVersion: Int
  let minimumClientVersion: String
  let managementSetupRequired: Bool
  let profiles: [IOSWatchingProfile]

  func validate() throws {
    guard (1...2).contains(formatVersion), Set(profiles.map(\.id)).count == profiles.count else {
      throw IOSCoreError.unsupportedServer
    }
  }
}

enum IOSProfilePIN {
  /// One answer for every rejected unlock, so the message never hints at the PIN's length.
  static let incorrect = "The PIN is incorrect."

  static func isValid(_ value: String) -> Bool {
    (4...8).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) }
  }
}

/// The avatar color of a profile, matching the Mac app's for the same profile.
enum IOSProfileColor {
  static let count = 7

  static func index(for id: UUID?) -> Int {
    guard let id else { return 0 }
    let sum = withUnsafeBytes(of: id.uuid) { $0.reduce(0) { $0 + Int($1) } }
    return sum % count
  }

  static func initial(of name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() }
      ?? "?"
  }
}

enum IOSPairingState: String, Codable, Sendable {
  case pending, approved, denied, cancelled, expired, unknown
  init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = Self(rawValue: value) ?? .unknown
  }
}

struct IOSPairingStart: Codable, Equatable, Sendable {
  let id: UUID
  let code: String
  let secret: String
  let expiresAt: String
  let pollIntervalSeconds: Int

  func validate(now: Date = Date()) throws {
    guard code.utf8.count == 8, code.utf8.allSatisfy({ (48...57).contains($0) }),
      (32...256).contains(secret.utf8.count), !secret.contains(where: \.isWhitespace),
      (5...300).contains(pollIntervalSeconds),
      let expiry = IOSServerDate.parse(expiresAt), expiry > now
    else { throw IOSCoreError.invalidResponse }
  }
}

struct IOSPairingStatus: Codable, Equatable, Sendable {
  let state: IOSPairingState
  let expiresAt: String
  let pollIntervalSeconds: Int
  let authentication: IOSAuthentication?
  let acknowledged: Bool
}

enum IOSMediaKind: String, Codable, Sendable {
  case movie, series, episode, extra, trailer, unknown
  init(from decoder: Decoder) throws {
    self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
  }
}

enum IOSMediaAvailability: String, Codable, Sendable {
  case available, missing, error, unknown
  init(from decoder: Decoder) throws {
    self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
  }
}

enum IOSLibraryAvailability: String, Codable, Sendable {
  case unknown, available, unavailable, error
  init(from decoder: Decoder) throws {
    self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
  }
}

struct IOSArtwork: Codable, Equatable, Sendable {
  let id: UUID
  let kind: String
  let path: String
  let contentType: String
  let contentLength: Int64
  let revision: Int64?
}

struct IOSPlaybackProgress: Codable, Equatable, Sendable {
  let mediaId: UUID
  let positionMilliseconds: Int64
  let durationMilliseconds: Int64
  let isCompleted: Bool
  let lastPlayedAt: String?
  let updatedAt: String?
  let revision: Int64
  let lastMutationId: UUID?

  func validate(mediaID: UUID) throws {
    guard mediaId == mediaID, positionMilliseconds >= 0, durationMilliseconds >= 0,
      positionMilliseconds <= durationMilliseconds, revision >= 0
    else { throw IOSCoreError.invalidResponse }
  }
}

struct IOSCatalogItem: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let kind: IOSMediaKind
  let title: String
  let originalTitle: String?
  let year: Int?
  let overview: String?
  let genres: [String]
  let poster: IOSArtwork?
  let backdrop: IOSArtwork?
  let availability: IOSMediaAvailability
  let isFavorite: Bool
  let progress: IOSPlaybackProgress?
  let addedAt: String
  let parentTitle: String?
  let seasonNumber: Int?
  let episodeNumber: Int?
  let parentId: UUID?
  let watchState: String?
  let libraryAvailability: IOSLibraryAvailability?
  var continueWatchingHidden: Bool? = nil

  var isPlayable: Bool {
    [.movie, .episode, .extra, .trailer].contains(kind) && availability == .available
      && libraryAvailability != .unavailable && libraryAvailability != .error
  }
  var availabilityMessage: String? {
    if libraryAvailability == .unavailable { return "Media drive disconnected" }
    if libraryAvailability == .error || availability == .error {
      return "Media could not be accessed"
    }
    if availability == .missing { return "Media file unavailable" }
    if availability == .unknown { return "Media availability unknown" }
    return nil
  }
  var episodeLabel: String? {
    guard kind == .episode, let seasonNumber, let episodeNumber else { return nil }
    return String(format: "S%02d E%02d", seasonNumber, episodeNumber)
  }
}

struct IOSPage<Item: Codable & Sendable>: Codable, Sendable {
  let items: [Item]
  let offset: Int
  let limit: Int
  let total: Int
  let revision: String?
}

struct IOSSetWatchlistRequest: Encodable, Sendable {
  let isWatchlisted: Bool
}

struct IOSWatchlistItemState: Codable, Equatable, Sendable {
  let mediaId: UUID
  let isWatchlisted: Bool
}

struct IOSWatchlistResponse: Codable, Equatable, Sendable {
  let items: [IOSCatalogItem]
  let mediaIds: [UUID]
}

struct IOSPersonDetailResponse: Codable, Equatable, Sendable {
  let name: String
  let subtitle: String?
  let profile: IOSArtwork?
  let items: [IOSCatalogItem]
}

enum IOSCatalogPageValidator {
  static func validate(
    _ page: IOSPage<IOSCatalogItem>, kind: IOSMediaKind,
    offset: Int, revision: String?, total: Int? = nil, existingIDs: Set<UUID> = []
  ) throws {
    guard page.offset == offset, page.limit > 0, page.total >= 0,
      page.items.count <= page.limit, offset <= page.total,
      page.items.count <= page.total - offset,
      !page.items.isEmpty || offset == page.total,
      page.items.allSatisfy({ $0.kind == kind }),
      Set(page.items.map(\.id)).count == page.items.count,
      existingIDs.isDisjoint(with: page.items.map(\.id))
    else { throw IOSCoreError.invalidResponse }
    if let revision, page.revision != revision {
      throw IOSCoreError.server(
        status: 409,
        code: "catalog_changed", message: "The library changed. Reload this view.", retryAfter: nil)
    }
    if let total, page.total != total { throw IOSCoreError.invalidResponse }
  }
}

struct IOSMediaMetadata: Codable, Equatable, Sendable {
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
  let poster: IOSArtwork?
  let backdrop: IOSArtwork?
  let still: IOSArtwork?
  // Optional so older servers without these fields still decode.
  var credits: [IOSCredit]? = nil
  var studios: [String]? = nil
  var countries: [String]? = nil
  var fskAge: Int? = nil
}

struct IOSCredit: Codable, Equatable, Sendable {
  let name: String
  let department: String
  let job: String?
  let character: String?
  let order: Int
  let profile: IOSArtwork?
  var id: UUID? = nil
  var personKey: String? = nil
}

struct IOSEpisode: Codable, Equatable, Sendable {
  let item: IOSCatalogItem
  let seasonNumber: Int
  let episodeNumber: Int
}
struct IOSSupplement: Codable, Equatable, Sendable {
  let item: IOSCatalogItem
  let category: String
  let seasonNumber: Int?
}
struct IOSSeason: Codable, Equatable, Sendable {
  let number: Int
  let episodes: [IOSEpisode]
  let supplements: [IOSSupplement]
}
struct IOSCatalogDetail: Codable, Equatable, Sendable {
  let item: IOSCatalogItem
  let metadata: IOSMediaMetadata
  let seasons: [IOSSeason]
  let supplements: [IOSSupplement]
  let franchise: IOSCollection?

  init(
    item: IOSCatalogItem,
    metadata: IOSMediaMetadata,
    seasons: [IOSSeason],
    supplements: [IOSSupplement],
    franchise: IOSCollection? = nil
  ) {
    self.item = item
    self.metadata = metadata
    self.seasons = seasons
    self.supplements = supplements
    self.franchise = franchise
  }

  enum CodingKeys: String, CodingKey {
    case item, metadata, seasons, supplements, franchise
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    item = try container.decode(IOSCatalogItem.self, forKey: .item)
    metadata = try container.decode(IOSMediaMetadata.self, forKey: .metadata)
    seasons = try container.decodeIfPresent([IOSSeason].self, forKey: .seasons) ?? []
    supplements = try container.decodeIfPresent([IOSSupplement].self, forKey: .supplements) ?? []
    franchise = try container.decodeIfPresent(IOSCollection.self, forKey: .franchise)
  }
}

struct IOSLiveSubtitleTrack: Codable, Equatable, Sendable {
  let index: Int
  let title: String
  let language: String?
  let isDefault: Bool
  let isForced: Bool
  let isSdh: Bool
  let isSidecar: Bool
}

enum IOSPlaybackAction: String, Codable, Sendable { case play, resume, playAgain }
struct IOSPlaybackPlan: Codable, Equatable, Sendable {
  let target: IOSCatalogItem?
  let seriesId: UUID?
  let queue: [IOSCatalogItem]
  let action: IOSPlaybackAction
  let continueWatchingEligible: Bool

  func validate(requestedID: UUID) throws {
    guard target?.kind != .series,
      target == nil || target?.id == requestedID || seriesId == requestedID,
      queue.allSatisfy({ $0.kind == .episode }),
      Set(queue.map(\.id)).count == queue.count,
      !queue.contains(where: { $0.id == target?.id })
    else { throw IOSCoreError.invalidResponse }
  }
}

struct IOSPlaybackTicket: Codable, Equatable, Sendable {
  let id: UUID
  let mediaId: UUID
  let streamPath: String
  let contentType: String
  let contentLength: Int64
  let expiresAt: String
  let progress: IOSPlaybackProgress
}

// MARK: Remote Playback Commands

public struct IOSRemotePlaybackCommand: Decodable, Sendable {
  public let commandId: UUID
  public let action: String
  public let mediaId: UUID?
  public let positionSeconds: Double?
  public let skipSeconds: Double?
  public let createdAt: Date
}
