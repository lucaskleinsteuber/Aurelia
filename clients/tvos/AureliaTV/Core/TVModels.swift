import Foundation

enum TVCoreError: LocalizedError, Equatable, Sendable {
  case invalidAddress
  case identityMismatch
  case invalidResponse
  /// This app refused to send a request it built itself; the server was not asked.
  case invalidRequest
  case unsupportedServer
  /// The server speaks a newer protocol than this app: the app needs the update, not the server.
  case outdatedClient
  /// The server accepts connections only from its own computer.
  case lanAccessDisabled
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
  /// Only these end the profile or device session. Any other 403 refuses a single request, such as
  /// a title this profile may not watch, and is shown where it happened.
  var endsSession: Bool {
    self == .identityMismatch || statusCode == 401
      || ["profile_session_expired", "profile_session_revoked", "device_session_revoked"].contains(
        code ?? "")
  }
  /// The server's own explanation, when it sent one.
  var serverMessage: String? {
    if case .server(_, _, let message, _) = self { return message }
    return nil
  }
  var errorDescription: String? {
    switch self {
    case .invalidAddress: "Enter a valid HTTPS server address."
    case .identityMismatch:
      "The server identity has changed. Confirm the server on your Mac before reconnecting."
    case .invalidResponse: "The server returned an invalid response."
    case .invalidRequest: "Aurelia could not send this request. Check what you entered and try again."
    case .unsupportedServer: "Update Aurelia Server to 1.5.5 or later to connect this Apple TV."
    case .lanAccessDisabled:
      "This server accepts connections only from its own computer. Allow devices on your home network in Aurelia on your Mac."
    case .outdatedClient: "This server is newer than Aurelia on this Apple TV. Update the app to connect."
    case .profileRequired: "Choose a profile to continue."
    case .server(_, _, let message, _): message ?? "The server request could not be completed."
    }
  }
}

/// Since iOS and tvOS 16 the system name of a device is only its kind, such as "iPhone", unless
/// the app has a special entitlement. A short tag that stays the same for this app tells several
/// such devices apart when the Mac approves one or Watch Together lists them.
enum TVDeviceName {
  static func display(systemName: String, model: String, tag: UUID?) -> String {
    let name = systemName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard name.isEmpty || name == model, let tag else { return name.isEmpty ? model : name }
    return "\(model) \(tag.uuidString.prefix(4))"
  }
}

enum TVServerDate {
  /// Every request checks the profile's expiry, so the parsers are made once. A configured
  /// ISO8601DateFormatter is safe to use from several threads.
  private final class Parsers: @unchecked Sendable {
    static let shared = Parsers()
    let fractional = ISO8601DateFormatter()
    let whole = ISO8601DateFormatter()
    private init() {
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      whole.formatOptions = [.withInternetDateTime]
    }
  }

  static func parse(_ value: String) -> Date? {
    Parsers.shared.fractional.date(from: value) ?? Parsers.shared.whole.date(from: value)
  }
}

/// A saved server that answers not at all, as when its computer sleeps, unlike one that answers with
/// an error. The app then tries Wake-on-LAN. A failed TLS handshake counts too: a server that is
/// still waking up can accept the connection and drop it; a wrong key is reported as identityMismatch.
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
  /// From server 2.10.0: "macApp" or "linuxApp" when the Aurelia app hosts it on a desktop or
  /// laptop, which its owner starts; "linuxServer" or "server" otherwise.
  var hosting: String? = nil
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
    try TVProtocolVersion.check(formatVersion)
    guard Set(capabilities ?? []).isSuperset(of: ["device-authorization-v1", "library-state-v1"])
    else { throw TVCoreError.unsupportedServer }
  }
  var supportsArtworkVariants: Bool { capabilities?.contains("artwork-variants-v1") == true }
  /// Names and pictures for profiles.
  var supportsProfilePersonalization: Bool {
    capabilities?.contains("profile-personalization-v1") == true
  }
  var supportsWatchlistAndPeople: Bool { capabilities?.contains("watchlist-people-v1") == true }
  var supportsScrubPreviews: Bool { capabilities?.contains("scrub-previews-v1") == true }
  /// Movie Night: the household swipes one deck until everyone likes a title.
  var supportsMovieNight: Bool { capabilities?.contains("movie-night-v1") == true }
  /// What to watch next after a movie or a series' last episode, and Home's "Because You Watched".
  var supportsSuggestions: Bool { capabilities?.contains("suggestions-v1") == true }
  var supportsWrapped: Bool { capabilities?.contains("year-wrapped-v1") == true }
  var supportsMonthlyWrapped: Bool { capabilities?.contains("monthly-wrapped-v1") == true }
  /// Cinema mode's trailers before a film.
  var supportsCinema: Bool { capabilities?.contains(TVCinemaPlan.feature) == true }
  /// HLS in several qualities, converted live by the server.
  var supportsAdaptiveStreaming: Bool { capabilities?.contains("adaptive-streaming-v1") == true }
}

struct TVUser: Codable, Equatable, Sendable {
  let id: UUID
  let username: String
  let role: String
  /// The name everyone sees; nil shows the sign-in name.
  var displayName: String? = nil
  /// A built-in picture (`symbol:palette`), `photo`, or nil for the initial.
  var pictureKey: String? = nil
  var pictureRevision: Int64? = nil
  /// A children's profile's highest FSK age, nil for none.
  var ageLimit: Int? = nil

  var shownName: String {
    if let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty {
      return displayName
    }
    return username
  }
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
  var pictureKey: String? = nil
  var pictureRevision: Int64 = 0
  var ageLimit: Int? = nil

  init(
    id: UUID, name: String, role: String, needsPinSetup: Bool,
    pinProtectionEnabled: Bool = true, pictureKey: String? = nil, pictureRevision: Int64 = 0,
    ageLimit: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.role = role
    self.needsPinSetup = needsPinSetup
    self.pinProtectionEnabled = pinProtectionEnabled
    self.pictureKey = pictureKey
    self.pictureRevision = pictureRevision
    self.ageLimit = ageLimit
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, role, needsPinSetup, pinProtectionEnabled, pictureKey, pictureRevision, ageLimit
  }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    role = try values.decode(String.self, forKey: .role)
    needsPinSetup = try values.decode(Bool.self, forKey: .needsPinSetup)
    pinProtectionEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .pinProtectionEnabled) ?? true
    pictureKey = try values.decodeIfPresent(String.self, forKey: .pictureKey)
    pictureRevision = try values.decodeIfPresent(Int64.self, forKey: .pictureRevision) ?? 0
    ageLimit = try values.decodeIfPresent(Int.self, forKey: .ageLimit)
  }
}

/// The server protocol versions this app understands. A newer server asks for an app update,
/// an older one for a server update.
enum TVProtocolVersion {
  static let supported = 1...2

  static func check(_ formatVersion: Int) throws {
    if formatVersion > supported.upperBound { throw TVCoreError.outdatedClient }
    if formatVersion < supported.lowerBound { throw TVCoreError.unsupportedServer }
  }
}

struct TVProfilePicker: Codable, Equatable, Sendable {
  let formatVersion: Int
  let minimumClientVersion: String
  let managementSetupRequired: Bool
  let profiles: [TVWatchingProfile]

  func validate() throws {
    try TVProtocolVersion.check(formatVersion)
    guard Set(profiles.map(\.id)).count == profiles.count else {
      throw TVCoreError.invalidResponse
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
  let franchise: TVCollection?

  init(
    item: TVCatalogItem,
    metadata: TVMediaMetadata,
    seasons: [TVSeason],
    supplements: [TVSupplement],
    franchise: TVCollection? = nil
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
    item = try container.decode(TVCatalogItem.self, forKey: .item)
    metadata = try container.decode(TVMediaMetadata.self, forKey: .metadata)
    seasons = try container.decodeIfPresent([TVSeason].self, forKey: .seasons) ?? []
    supplements = try container.decodeIfPresent([TVSupplement].self, forKey: .supplements) ?? []
    franchise = try container.decodeIfPresent(TVCollection.self, forKey: .franchise)
  }
}

/// A subtitle track the server lists for a stream. Untitled tracks arrive without a title.
struct TVLiveSubtitleTrack: Codable, Equatable, Sendable {
  let index: Int
  let title: String?
  let language: String?
  let isDefault: Bool
  let isForced: Bool
  let isSdh: Bool
  let isSidecar: Bool
  /// False for bitmap files (VobSub), which the server cannot turn into text.
  let supported: Bool?

  /// The subtitle files next to the video that the player adds itself. Embedded tracks are
  /// already in the stream, and loading them again would make the server extract each one.
  static func sidecarFiles(_ tracks: [TVLiveSubtitleTrack]) -> [TVLiveSubtitleTrack] {
    tracks.filter { $0.isSidecar && $0.supported != false }
  }
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
  /// Intro and credits times found by the server ("media-segments-v2"); older servers send none.
  var segments: TVMediaSegments? = nil
}

/// Where the intro and the credits of the playing title are, in milliseconds from its start.
struct TVMediaSegments: Codable, Equatable, Sendable {
  var introStartMilliseconds: Int64?
  var introEndMilliseconds: Int64?
  var creditsStartMilliseconds: Int64?

  /// The intro when both ends are known and in order.
  var intro: (start: Int64, end: Int64)? {
    guard let start = introStartMilliseconds, let end = introEndMilliseconds, start >= 0, end > start
    else { return nil }
    return (start, end)
  }
}

// MARK: Remote Playback Commands

public struct TVRemotePlaybackCommand: Decodable, Sendable {
  public let commandId: UUID
  public let action: String
  public let mediaId: UUID?
  public let positionSeconds: Double?
  public let skipSeconds: Double?
  /// ISO 8601 text, as the server writes every time.
  public let createdAt: String
}
