import Foundation
import Security

// Siri and Shortcuts on the Mac: Aurelia's profile sign-in lives only while the app runs, so Siri
// uses its own integration key, created in Settings › Smart Home and kept in this Mac's Keychain.
// Copied from the iPhone app, not shared.

struct SiriKeyStore {
  static let service =
    AppEdition.isTest ? "com.lucas.aurelia.media.test.siri" : "com.lucas.aurelia.media.siri"

  func load(server: UUID) -> String? {
    var query = Self.query(server)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
      let key = String(data: data, encoding: .utf8), Self.isKey(key)
    else { return nil }
    return key
  }

  func save(_ key: String, server: UUID) throws {
    guard Self.isKey(key) else { throw APIClientError.invalidResponse }
    SecItemDelete(Self.query(server) as CFDictionary)
    var query = Self.query(server)
    query[kSecValueData as String] = Data(key.utf8)
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw APIClientError.invalidResponse }
  }

  func delete(server: UUID) { SecItemDelete(Self.query(server) as CFDictionary) }

  static func isKey(_ text: String) -> Bool {
    text.hasPrefix("aur_it_") && (40...128).contains(text.utf8.count) && !text.contains(where: \.isWhitespace)
  }

  private static func query(_ server: UUID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: server.uuidString.lowercased(),
    ]
  }
}

/// The calls Siri makes with its key.
struct IntegrationClient: Sendable {
  let profile: StoredServerProfile
  let key: String

  func status() async throws -> IntegrationStatus { try await get("/api/v1/integration/status") }
  func players() async throws -> [IntegrationPlayer] { try await get("/api/v1/integration/players") }
  func search(_ text: String) async throws -> [IntegrationTitle] {
    let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))) ?? ""
    return try await get("/api/v1/integration/search?query=\(query)")
  }
  func episode(of series: UUID, season: Int, episode: Int) async throws -> IntegrationTitle {
    try await get("/api/v1/integration/titles/\(series.uuidString.lowercased())/episode?season=\(season)&episode=\(episode)")
  }
  func next(in title: UUID) async throws -> IntegrationTitle {
    try await get("/api/v1/integration/titles/\(title.uuidString.lowercased())/next")
  }
  func play(_ media: UUID, on deviceID: String) async throws {
    struct Body: Encodable {
      let action: String
      let mediaId: UUID
    }
    let device = deviceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? deviceID
    _ = try await APIClient.integrationRequest(
      profile: profile, key: key, path: "/api/v1/integration/players/\(device)/commands", method: "POST",
      body: JSONEncoder().encode(Body(action: "play", mediaId: media)))
  }
  func powerNow(_ action: String) async throws -> String {
    struct Body: Encodable { let action: String }
    struct Answer: Decodable { let message: String }
    let data = try await APIClient.integrationRequest(
      profile: profile, key: key, path: "/api/v1/integration/power", method: "POST",
      body: JSONEncoder().encode(Body(action: action)))
    return try JSONDecoder().decode(Answer.self, from: data).message
  }
  func answers() async -> Bool {
    (try? await APIClient.integrationRequest(profile: profile, key: nil, path: "/api/v1/health", method: "GET", body: nil)) != nil
  }

  private func get<Value: Decodable>(_ path: String) async throws -> Value {
    try JSONDecoder().decode(
      Value.self, from: await APIClient.integrationRequest(profile: profile, key: key, path: path, method: "GET", body: nil))
  }
}

struct IntegrationPlayer: Decodable, Equatable, Sendable {
  let deviceId: String
  let deviceName: String
  let clientType: String
  let isPlaying: Bool
  let title: String?
  let isPaused: Bool
}

struct IntegrationStatus: Decodable, Sendable {
  struct Entry: Decodable, Sendable {
    struct Device: Decodable, Sendable { let name: String }
    struct Media: Decodable, Sendable {
      let title: String
      let seriesTitle: String?
      let season: Int?
      let episode: Int?
    }
    let state: String
    let device: Device
    let media: Media
  }
  let playing: [Entry]
  let powerActions: [String]
}

struct IntegrationTitle: Decodable, Equatable, Sendable {
  let id: UUID
  let kind: String
  let title: String
  let year: Int?
  let parentTitle: String?
  let seasonNumber: Int?
  let episodeNumber: Int?
}

/// "Breaking Bad season 3 episode 4", "Breaking Bad S3E4", "Breaking Bad 3x04" or German
/// "Staffel 3 Folge 4": the title and, when said, the season and episode.
enum SiriTitleRequest {
  struct Parsed: Equatable, Sendable {
    var title: String
    var season: Int?
    var episode: Int?
  }

  static func parse(_ text: String) -> Parsed {
    let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let patterns = [
      #"(?i)\s*\bs(?:eason)?\s*(\d{1,2})\s*[,.]?\s*e(?:pisode)?\s*(\d{1,3})\b"#,
      #"(?i)\s*\b(\d{1,2})x(\d{1,3})\b"#,
      #"(?i)\s*\b(?:staffel)\s*(\d{1,2})\s*[,.]?\s*(?:folge|episode)\s*(\d{1,3})\b"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(in: spoken, range: NSRange(spoken.startIndex..., in: spoken)),
        let whole = Range(match.range, in: spoken), let first = Range(match.range(at: 1), in: spoken),
        let second = Range(match.range(at: 2), in: spoken)
      else { continue }
      var title = spoken
      title.removeSubrange(whole)
      return Parsed(title: clean(title), season: Int(spoken[first]), episode: Int(spoken[second]))
    }
    return Parsed(title: clean(spoken))
  }

  /// The best of several found titles: an exact name first, then a show when an episode was asked.
  static func best(_ titles: [IntegrationTitle], for request: Parsed) -> IntegrationTitle? {
    let wanted = request.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    let exact = titles.filter {
      $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == wanted
    }
    let pool = exact.isEmpty ? titles : exact
    if request.season != nil { return pool.first { $0.kind == "series" } ?? pool.first }
    return pool.first
  }

  /// The device to play on: the one named, else an Apple TV, else the only other player.
  static func player(_ players: [IntegrationPlayer], named name: String?) -> IntegrationPlayer? {
    if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
      return players.first { $0.deviceName.localizedCaseInsensitiveContains(name) }
    }
    return players.first { $0.clientType == "tvos" } ?? (players.count == 1 ? players[0] : nil)
  }

  private static func clean(_ text: String) -> String {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    for filler in ["play ", "spiele ", "watch "] where value.lowercased().hasPrefix(filler) {
      value = String(value.dropFirst(filler.count))
    }
    return value.trimmingCharacters(in: .whitespaces)
  }
}
