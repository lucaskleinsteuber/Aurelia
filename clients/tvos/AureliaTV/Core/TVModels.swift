import Foundation

enum TVCoreError: LocalizedError, Equatable, Sendable {
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
    case .unsupportedServer: "Update Aurelia Server to 1.5.5 or later to connect this Apple TV."
    case .profileRequired: "Choose a profile to continue."
    case .server(_, _, let message, _): message ?? "The server request could not be completed."
    }
  }
}

enum TVServerDate {
  static func parse(_ value: String) -> Date? {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = parser.date(from: value) { return date }
    parser.formatOptions = [.withInternetDateTime]
    return parser.date(from: value)
  }
}

/// A saved server that answers not at all, as when its computer sleeps, unlike one that answers with
/// an error. An Apple TV cannot wake a server; Aurelia on a Mac can.
enum TVServerReachability {
  static func isUnreachable(_ error: Error) -> Bool {
    guard let error = error as? URLError else { return false }
    return [
      .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
      .notConnectedToInternet, .secureConnectionFailed,
    ].contains(error.code)
  }
}

struct TVStoredConnection: Codable, Equatable, Sendable {
  let serverID: UUID
  let name: String
  let baseURL: URL
  let fingerprint: String
  let deviceToken: String
  let deviceSessionID: UUID
  var pendingAcknowledgement: TVPendingPairingAcknowledgement? = nil

  func validate() throws {
    guard TVServerAddress.isValid(baseURL), TVServerIdentity.isValidFingerprint(fingerprint),
      (32...256).contains(deviceToken.utf8.count), !deviceToken.contains(where: \.isWhitespace)
    else { throw TVCoreError.invalidResponse }
  }

  func relocating(to address: URL) -> Self {
    Self(
      serverID: serverID, name: name, baseURL: address, fingerprint: fingerprint,
      deviceToken: deviceToken, deviceSessionID: deviceSessionID,
      pendingAcknowledgement: pendingAcknowledgement)
  }
}

struct TVPendingPairingAcknowledgement: Codable, Equatable, Sendable {
  let id: UUID
  let secret: String
  let expiresAt: String
}

struct TVServerInfo: Codable, Equatable, Sendable {
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

struct TVInspectedServer: Equatable, Sendable {
  let baseURL: URL
  let info: TVServerInfo
  let fingerprint: String

  func connection(authentication: TVAuthentication) throws -> TVStoredConnection {
    let connection = TVStoredConnection(
      serverID: info.serverId, name: info.name,
      baseURL: baseURL, fingerprint: fingerprint, deviceToken: authentication.token,
      deviceSessionID: authentication.sessionId)
    try connection.validate()
    return connection
  }

  func validate(against connection: TVStoredConnection) throws {
    guard info.serverId == connection.serverID,
      fingerprint.caseInsensitiveCompare(connection.fingerprint) == .orderedSame
    else { throw TVCoreError.identityMismatch }
  }
}

struct TVCapabilities: Codable, Equatable, Sendable {
  let formatVersion: Int
  let minimumClientVersion: String
  let capabilities: [String]?

  func validate() throws {
    // Marketing versions belong to different products. TV 0.1 implements the
    // versioned protocol; it must not be compared with Mac minimumClientVersion.
    guard (1...2).contains(formatVersion),
      Set(capabilities ?? []).isSuperset(of: ["device-authorization-v1", "library-state-v1"])
    else { throw TVCoreError.unsupportedServer }
  }
  var supportsArtworkVariants: Bool { capabilities?.contains("artwork-variants-v1") == true }
  var supportsWatchlistAndPeople: Bool { capabilities?.contains("watchlist-people-v1") == true }
  var supportsScrubPreviews: Bool { capabilities?.contains("scrub-previews-v1") == true }
}

struct TVUser: Codable, Equatable, Sendable {
  let id: UUID
  let username: String
  let role: String
}

struct TVAuthentication: Codable, Equatable, Sendable {
  let user: TVUser
  let sessionId: UUID
  let token: String
  let expiresAt: String
}

struct TVProfileSession: Codable, Equatable, Sendable {
  let user: TVUser
  let sessionId: UUID
  let token: String
  let expiresAt: String

  func validate(profileID: UUID, now: Date = Date()) throws {
    guard user.id == profileID, (32...256).contains(token.utf8.count),
      !token.contains(where: \.isWhitespace),
      let expiry = TVServerDate.parse(expiresAt), expiry > now
    else { throw TVCoreError.invalidResponse }
  }
}

struct TVWatchingProfile: Codable, Identifiable, Equatable, Sendable {
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

struct TVProfilePicker: Codable, Equatable, Sendable {
  let formatVersion: Int
  let minimumClientVersion: String
  let managementSetupRequired: Bool
  let profiles: [TVWatchingProfile]

  func validate() throws {
    guard (1...2).contains(formatVersion), Set(profiles.map(\.id)).count == profiles.count else {
      throw TVCoreError.unsupportedServer
    }
  }
}

enum TVProfilePIN {
  /// One answer for every rejected unlock, so the message never hints at the PIN's length.
  static let incorrect = "The PIN is incorrect."

  static func isValid(_ value: String) -> Bool {
    (4...8).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) }
  }
}

/// The avatar color of a profile, matching the Mac app's for the same profile.
enum TVProfileColor {
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

enum TVPairingState: String, Codable, Sendable {
  case pending, approved, denied, cancelled, expired, unknown
  init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = Self(rawValue: value) ?? .unknown
  }
}

struct TVPairingStart: Codable, Equatable, Sendable {
  let id: UUID
  let code: String
  let secret: String
  let expiresAt: String
  let pollIntervalSeconds: Int

  func validate(now: Date = Date()) throws {
    guard code.utf8.count == 8, code.utf8.allSatisfy({ (48...57).contains($0) }),
      (32...256).contains(secret.utf8.count), !secret.contains(where: \.isWhitespace),
      (5...300).contains(pollIntervalSeconds),
      let expiry = TVServerDate.parse(expiresAt), expiry > now
    else { throw TVCoreError.invalidResponse }
  }
}

struct TVPairingStatus: Codable, Equatable, Sendable {
  let state: TVPairingState
  let expiresAt: String
  let pollIntervalSeconds: Int
  let authentication: TVAuthentication?
  let acknowledged: Bool
}

enum TVMediaKind: String, Codable, Sendable {
  case movie, series, episode, extra, trailer, unknown
  init(from decoder: Decoder) throws {
    self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
  }
}

enum TVMediaAvailability: String, Codable, Sendable {
  case available, missing, error, unknown
  init(from decoder: Decoder) throws {
    self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
  }
}

enum TVLibraryAvailability: String, Codable, Sendable {
  case unknown, available, unavailable, error
  init(from decoder: Decoder) throws {
    self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
  }
}

struct TVArtwork: Codable, Equatable, Sendable {
  let id: UUID
  let kind: String
  let path: String
  let contentType: String
  let contentLength: Int64
  let revision: Int64?
}

struct TVPlaybackProgress: Codable, Equatable, Sendable {
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
    else { throw TVCoreError.invalidResponse }
  }
}

struct TVCatalogItem: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let kind: TVMediaKind
  let title: String
  let originalTitle: String?
  let year: Int?
  let overview: String?
  let genres: [String]
  let poster: TVArtwork?
  let backdrop: TVArtwork?
  let availability: TVMediaAvailability
  let isFavorite: Bool
  let progress: TVPlaybackProgress?
  let addedAt: String
  let parentTitle: String?
  let seasonNumber: Int?
  let episodeNumber: Int?
  let parentId: UUID?
  let watchState: String?
  let libraryAvailability: TVLibraryAvailability?
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

struct TVPage<Item: Codable & Sendable>: Codable, Sendable {
  let items: [Item]
  let offset: Int
  let limit: Int
  let total: Int
  let revision: String?
}

struct TVSetWatchlistRequest: Encodable, Sendable {
  let isWatchlisted: Bool
}

struct TVWatchlistItemState: Codable, Equatable, Sendable {
  let mediaId: UUID
  let isWatchlisted: Bool
}

struct TVWatchlistResponse: Codable, Equatable, Sendable {
  let items: [TVCatalogItem]
  let mediaIds: [UUID]
}

struct TVPersonDetailResponse: Codable, Equatable, Sendable {
  let name: String
  let subtitle: String?
  let profile: TVArtwork?
  let items: [TVCatalogItem]
}

enum TVCatalogPageValidator {
  static func validate(
    _ page: TVPage<TVCatalogItem>, kind: TVMediaKind,
    offset: Int, revision: String?, total: Int? = nil, existingIDs: Set<UUID> = []
  ) throws {
    guard page.offset == offset, page.limit > 0, page.total >= 0,
      page.items.count <= page.limit, offset <= page.total,
      page.items.count <= page.total - offset,
      !page.items.isEmpty || offset == page.total,
      page.items.allSatisfy({ $0.kind == kind }),
      Set(page.items.map(\.id)).count == page.items.count,
      existingIDs.isDisjoint(with: page.items.map(\.id))
    else { throw TVCoreError.invalidResponse }
    if let revision, page.revision != revision {
      throw TVCoreError.server(
        status: 409,
        code: "catalog_changed", message: "The library changed. Reload this view.", retryAfter: nil)
    }
    if let total, page.total != total { throw TVCoreError.invalidResponse }
  }
}

struct TVMediaMetadata: Codable, Equatable, Sendable {
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
  let poster: TVArtwork?
  let backdrop: TVArtwork?
  let still: TVArtwork?
  // Optional so older servers without these fields still decode.
  var credits: [TVCredit]? = nil
  var studios: [String]? = nil
  var countries: [String]? = nil
  var fskAge: Int? = nil
}

struct TVCredit: Codable, Equatable, Sendable {
  let name: String
  let department: String
  let job: String?
  let character: String?
  let order: Int
  let profile: TVArtwork?
  var id: UUID? = nil
  var personKey: String? = nil
}

struct TVEpisode: Codable, Equatable, Sendable {
  let item: TVCatalogItem
  let seasonNumber: Int
  let episodeNumber: Int
}
struct TVSupplement: Codable, Equatable, Sendable {
  let item: TVCatalogItem
  let category: String
  let seasonNumber: Int?
}
struct TVSeason: Codable, Equatable, Sendable {
  let number: Int
  let episodes: [TVEpisode]
  let supplements: [TVSupplement]
}
struct TVCatalogDetail: Codable, Equatable, Sendable {
  let item: TVCatalogItem
  let metadata: TVMediaMetadata
  let seasons: [TVSeason]
  let supplements: [TVSupplement]
}

enum TVPlaybackAction: String, Codable, Sendable { case play, resume, playAgain }
struct TVPlaybackPlan: Codable, Equatable, Sendable {
  let target: TVCatalogItem?
  let seriesId: UUID?
  let queue: [TVCatalogItem]
  let action: TVPlaybackAction
  let continueWatchingEligible: Bool

  func validate(requestedID: UUID) throws {
    guard target?.kind != .series,
      target == nil || target?.id == requestedID || seriesId == requestedID,
      queue.allSatisfy({ $0.kind == .episode }),
      Set(queue.map(\.id)).count == queue.count,
      !queue.contains(where: { $0.id == target?.id })
    else { throw TVCoreError.invalidResponse }
  }
}

struct TVPlaybackTicket: Codable, Equatable, Sendable {
  let id: UUID
  let mediaId: UUID
  let streamPath: String
  let contentType: String
  let contentLength: Int64
  let expiresAt: String
  let progress: TVPlaybackProgress
}
