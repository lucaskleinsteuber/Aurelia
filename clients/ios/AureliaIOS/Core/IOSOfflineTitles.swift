import CommonCrypto
import Foundation
import Security

/// A title downloaded to this iPhone or iPad to watch without the server (owner's decision,
/// 07.11.2026): the original file, read once through a normal playback ticket and kept in this
/// app's own data folder until someone removes it. Progress watched offline goes back to the
/// server later. The same rules as the Mac's downloads.
struct IOSOfflineTitle: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let serverID: UUID
  let profileID: UUID
  let title: String
  /// "Series · S1 E3" for an episode, the year for a movie.
  let subtitle: String?
  let kind: String
  let fileName: String
  let contentType: String
  var bytes: Int64
  var downloadedAt: Date
  var positionMilliseconds: Int64
  var durationMilliseconds: Int64
  var isCompleted: Bool
  var progressSavedAt: Date?
  /// Watched offline and not yet on the server.
  var progressDirty: Bool
  var subtitles: [IOSOfflineSubtitle]
  /// The server's progress revision when this device last knew it.
  var serverRevision: Int64?
  var overview: String?
  var year: Int?
  var genres: [String]
  var parentID: UUID?
  var parentTitle: String?
  var seasonNumber: Int?
  var episodeNumber: Int?
  /// File names of the pictures in the title's folder.
  var posterFile: String?
  var backdropFile: String?
  var seriesPosterFile: String?

  var isEpisode: Bool { kind == "episode" }
  var episodeLabel: String? {
    guard isEpisode, let seasonNumber else { return nil }
    return "S\(seasonNumber) E\(episodeNumber ?? 0)"
  }
  var isInProgress: Bool { positionMilliseconds > 0 && !isCompleted }
  var watchedShare: Double {
    guard durationMilliseconds > 0 else { return 0 }
    return min(1, Double(positionMilliseconds) / Double(durationMilliseconds))
  }
  /// What the player shows as the title.
  var playerTitle: String {
    guard isEpisode, let parentTitle, let episodeLabel else { return title }
    return "\(parentTitle) · \(episodeLabel)"
  }

  /// The title as the library's model, for the player's Up Next queue.
  var catalogItem: IOSCatalogItem {
    IOSCatalogItem(
      id: id, kind: IOSMediaKind(rawValue: kind) ?? .movie, title: title, originalTitle: nil,
      year: year, overview: overview, genres: genres, poster: nil, backdrop: nil,
      availability: .available, isFavorite: false, progress: nil,
      addedAt: IOSServerDate.string(downloadedAt), parentTitle: parentTitle,
      seasonNumber: seasonNumber, episodeNumber: episodeNumber, parentId: parentID,
      watchState: nil, libraryAvailability: .available)
  }
}

struct IOSOfflineSubtitle: Codable, Equatable, Sendable {
  let index: Int
  let language: String?
  let title: String?
  let isForced: Bool
  let isSdh: Bool
  let fileName: String
}

/// A download still loading, or one that stopped and can be tried again.
struct IOSOfflinePending: Codable, Identifiable, Equatable, Sendable {
  /// One file loads at a time, so a season never takes all of a profile's streams.
  enum State: String, Codable, Sendable { case waiting, downloading, failed }
  /// Everything known before the file arrives; `bytes` is the size the server announced.
  var title: IOSOfflineTitle
  var ticketID: UUID
  var startedAt: Date
  var state: State
  /// The server's pinned key, which every connection of the transfer must present.
  var fingerprint: String
  var message: String?
  var receivedBytes: Int64 = 0
  /// Where a stopped transfer can continue, in the title's folder.
  var resumeFile: String?
  var id: UUID { title.id }

  var share: Double {
    guard title.bytes > 0 else { return 0 }
    return min(1, Double(receivedBytes) / Double(title.bytes))
  }
  /// A playback ticket lasts twelve hours; a transfer stopped later starts over with a new one.
  func canResume(now: Date = Date()) -> Bool {
    resumeFile != nil && now.timeIntervalSince(startedAt) < 11 * 3600
  }
}

/// The rules downloads follow, kept apart from files and transfers so they can be tested.
enum IOSOfflineRules {
  /// Room left on the device besides the file, so a download never fills it up.
  static let reserveBytes: Int64 = 1_000_000_000

  static func hasRoom(for bytes: Int64, available: Int64) -> Bool {
    bytes <= 0 || bytes + reserveBytes < available
  }

  /// Whether progress watched offline replaces the server's. Unchanged since this device last
  /// knew it (same revision), it always does, whatever the clocks say; when the server's
  /// progress changed meanwhile, the later of the two wins.
  static func offlineIsNewer(_ title: IOSOfflineTitle, server: IOSPlaybackProgress) -> Bool {
    if let known = title.serverRevision, server.revision == known { return true }
    guard let saved = title.progressSavedAt else { return false }
    return server.updatedAt.flatMap(IOSServerDate.parse).map { $0 < saved } ?? true
  }

  /// The server's progress taken over by a download nobody watched offline since.
  static func adopting(_ server: IOSPlaybackProgress, into title: IOSOfflineTitle)
    -> IOSOfflineTitle
  {
    var updated = title
    updated.positionMilliseconds = server.positionMilliseconds
    updated.durationMilliseconds = max(server.durationMilliseconds, title.durationMilliseconds)
    updated.isCompleted = server.isCompleted
    updated.serverRevision = server.revision
    return updated
  }

  static func fileExtension(_ contentType: String) -> String {
    switch contentType.lowercased() {
    case "video/mp4": "mp4"
    case "video/quicktime": "mov"
    case "video/x-m4v": "m4v"
    case "video/x-msvideo": "avi"
    case "video/webm": "webm"
    default: "mkv"
    }
  }

  /// "Series · S1 E3" for an episode, the year for a movie.
  static func subtitle(for item: IOSCatalogItem) -> String? {
    if item.kind == .episode {
      let parts = [
        item.parentTitle,
        item.seasonNumber.map { "S\($0) E\(item.episodeNumber ?? 0)" },
      ].compactMap { $0 }
      return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    return item.year.map(String.init)
  }

  static func canDownload(_ item: IOSCatalogItem) -> Bool {
    (item.kind == .movie || item.kind == .episode) && item.isPlayable
  }

  /// The downloaded episodes after this one in the same series, for Up Next offline.
  static func followingEpisodes(after title: IOSOfflineTitle, in titles: [IOSOfflineTitle])
    -> [IOSOfflineTitle]
  {
    guard title.isEpisode, let series = title.parentID else { return [] }
    let order = { (value: IOSOfflineTitle) in (value.seasonNumber ?? 0, value.episodeNumber ?? 0) }
    return titles.filter { $0.isEpisode && $0.parentID == series && order($0) > order(title) }
      .sorted { order($0) < order($1) }
  }
}

/// How the offline library arranges a profile's downloads.
struct IOSOfflineLayout: Equatable {
  struct Series: Identifiable, Equatable {
    let id: String
    let title: String
    let episodes: [IOSOfflineTitle]
  }

  let continueWatching: [IOSOfflineTitle]
  let movies: [IOSOfflineTitle]
  let series: [Series]

  init(_ titles: [IOSOfflineTitle]) {
    continueWatching = titles.filter(\.isInProgress).sorted {
      ($0.progressSavedAt ?? $0.downloadedAt) > ($1.progressSavedAt ?? $1.downloadedAt)
    }
    movies = titles.filter { !$0.isEpisode }
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    let grouped = Dictionary(grouping: titles.filter(\.isEpisode)) {
      $0.parentID?.uuidString ?? Self.seriesName($0)
    }
    series = grouped.map { key, episodes in
      Series(
        id: key, title: episodes.first.map(Self.seriesName) ?? "TV Show",
        episodes: episodes.sorted {
          ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0, $0.title)
            < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0, $1.title)
        })
    }
    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  var isEmpty: Bool { movies.isEmpty && series.isEmpty }

  static func seriesName(_ episode: IOSOfflineTitle) -> String {
    if let parent = episode.parentTitle, !parent.isEmpty { return parent }
    return "TV Show"
  }
}

/// What the offline mode needs to open a profile's downloads while the server is out of reach:
/// its name and picture, and whether it has a PIN. A PIN is kept only as a salted PBKDF2 check
/// value, never the PIN itself, and only on this device.
struct IOSOfflineProfileCard: Codable, Equatable, Identifiable, Sendable {
  let serverID: UUID
  let profileID: UUID
  var name: String
  var pictureKey: String?
  var pictureRevision: Int64
  var pinProtected: Bool
  var salt: Data?
  var check: Data?
  var rememberedAt: Date

  var id: UUID { profileID }

  static let rounds: UInt32 = 210_000

  /// Whether this PIN opens the profile offline. A profile without a PIN opens without one.
  func accepts(_ pin: String) -> Bool {
    guard pinProtected else { return true }
    guard let salt, let check, IOSProfilePIN.isValid(pin),
      let derived = Self.derive(pin, salt: salt), derived.count == check.count
    else { return false }
    // Constant-time comparison.
    return zip(derived, check).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }

  static func make(
    serverID: UUID, profile: IOSWatchingProfile, pin: String?, now: Date = Date()
  ) -> IOSOfflineProfileCard? {
    var salt: Data?
    var check: Data?
    if profile.pinProtectionEnabled {
      guard let pin, IOSProfilePIN.isValid(pin) else { return nil }
      var bytes = Data(count: 16)
      let status = bytes.withUnsafeMutableBytes {
        SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
      }
      guard status == errSecSuccess, let derived = derive(pin, salt: bytes) else { return nil }
      salt = bytes
      check = derived
    }
    return IOSOfflineProfileCard(
      serverID: serverID, profileID: profile.id, name: profile.name,
      pictureKey: profile.pictureKey, pictureRevision: profile.pictureRevision,
      pinProtected: profile.pinProtectionEnabled, salt: salt, check: check, rememberedAt: now)
  }

  static func derive(_ pin: String, salt: Data, rounds: UInt32 = rounds) -> Data? {
    let password = Array(pin.utf8)
    var derived = Data(count: 32)
    let status = derived.withUnsafeMutableBytes { output in
      salt.withUnsafeBytes { saltBytes in
        CCKeyDerivationPBKDF(
          CCPBKDFAlgorithm(kCCPBKDF2), password.map { Int8(bitPattern: $0) }, password.count,
          saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
          output.bindMemory(to: UInt8.self).baseAddress, 32)
      }
    }
    return status == kCCSuccess ? derived : nil
  }
}

/// The profile whose downloads the offline mode shows.
struct IOSOfflineSession: Equatable, Sendable {
  let serverID: UUID
  let profileID: UUID
  let name: String
  let pictureKey: String?
  let pictureRevision: Int64

  /// A stand-in sign-in for the player, which never leaves this device: the offline transport
  /// answers every request itself.
  var playerSession: IOSProfileSession {
    IOSProfileSession(
      user: IOSUser(
        id: profileID, username: name, role: "viewer", displayName: name,
        pictureKey: pictureKey, pictureRevision: pictureRevision),
      sessionId: profileID, token: "offline-" + profileID.uuidString.replacingOccurrences(
        of: "-", with: ""),
      expiresAt: "2099-01-01T00:00:00Z")
  }
}

/// Plays a download through the normal player with no server: the requests the player makes
/// are answered on this device from the download and its saved progress.
struct IOSOfflineTransport: IOSHTTPTransport {
  /// The download a request is about, by media ID.
  let title: @Sendable (UUID) async -> IOSOfflineTitle?
  /// Saves a position watched offline; answers the saved progress.
  let save:
    @Sendable (_ id: UUID, _ position: Int64, _ duration: Int64, _ finished: Bool) async ->
      IOSOfflineTitle?
  /// Each title's offline revision, for the player's progress journal.
  let revisions = IOSOfflineRevisions()

  static let ticketPrefix = "offline"

  static func streamToken(_ id: UUID) -> String {
    ticketPrefix + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }

  /// The download an offline stream address stands for.
  static func mediaID(streamURL: URL) -> UUID? {
    let token = streamURL.lastPathComponent
    guard token.hasPrefix(ticketPrefix) else { return nil }
    let hex = Array(token.dropFirst(ticketPrefix.count))
    guard hex.count == 32 else { return nil }
    let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(hex[$0]) }
    return UUID(uuidString: groups.joined(separator: "-"))
  }

  func execute(_ request: URLRequest, trust: IOSTrustMode) async throws -> IOSHTTPResponse {
    let parts = (request.url?.path ?? "").split(separator: "/").map(String.init)
    let method = request.httpMethod ?? "GET"
    // /api/v1/media/{id}/playback, /api/v1/media/{id}/progress
    if parts.count == 5, parts[2] == "media", let id = UUID(uuidString: parts[3]) {
      guard let title = await self.title(id) else { return Self.status(404) }
      switch (parts[4], method) {
      case ("playback", "POST"):
        let ticket = IOSPlaybackTicket(
          id: id, mediaId: id, streamPath: "/api/v1/streams/\(Self.streamToken(id))",
          contentType: title.contentType, contentLength: max(1, title.bytes),
          expiresAt: "2099-01-01T00:00:00Z", progress: progress(title, mutation: nil))
        return try Self.json(ticket)
      case ("progress", "GET"):
        return try Self.json(progress(title, mutation: nil))
      case ("progress", "PUT"):
        struct Payload: Decodable {
          let positionMilliseconds: Int64
          let durationMilliseconds: Int64
          let isFinished: Bool
          let clientMutationId: UUID
        }
        guard let body = request.httpBody,
          let payload = try? JSONDecoder().decode(Payload.self, from: body),
          let saved = await save(
            id, payload.positionMilliseconds, payload.durationMilliseconds, payload.isFinished)
        else { return Self.status(400) }
        revisions.advance(id)
        return try Self.json(progress(saved, mutation: payload.clientMutationId))
      default:
        return Self.status(404)
      }
    }
    // /api/v1/streams/{ticket}/subtitles: the ticket is the media ID offline.
    if parts.count == 5, parts[2] == "streams", parts[4] == "subtitles",
      let id = UUID(uuidString: parts[3])
    {
      guard let title = await self.title(id) else { return Self.status(404) }
      return try Self.json(
        title.subtitles.map {
          IOSLiveSubtitleTrack(
            index: $0.index, title: $0.title, language: $0.language, isDefault: false,
            isForced: $0.isForced, isSdh: $0.isSdh, isSidecar: true, supported: true)
        })
    }
    // Ending a ticket or a sleep timer needs nothing offline.
    if method == "DELETE" || method == "POST" { return Self.status(204) }
    return Self.status(404)
  }

  private func progress(_ title: IOSOfflineTitle, mutation: UUID?) -> IOSPlaybackProgress {
    IOSPlaybackProgress(
      mediaId: title.id, positionMilliseconds: title.positionMilliseconds,
      durationMilliseconds: max(title.durationMilliseconds, title.positionMilliseconds),
      isCompleted: title.isCompleted, lastPlayedAt: nil, updatedAt: nil,
      revision: revisions.current(title.id), lastMutationId: mutation)
  }

  private static func json(_ value: some Encodable) throws -> IOSHTTPResponse {
    IOSHTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try JSONEncoder().encode(value), fingerprint: nil)
  }

  private static func status(_ code: Int) -> IOSHTTPResponse {
    IOSHTTPResponse(statusCode: code, headers: [:], body: Data(), fingerprint: nil)
  }
}

/// Offline revisions count only within this device's offline player; the server never sees them.
final class IOSOfflineRevisions: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UUID: Int64] = [:]

  func current(_ id: UUID) -> Int64 { lock.withLock { values[id] ?? 1 } }
  func advance(_ id: UUID) { lock.withLock { values[id] = (values[id] ?? 1) + 1 } }
}
