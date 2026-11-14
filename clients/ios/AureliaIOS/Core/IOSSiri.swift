import Foundation
import Security

/// Siri and Shortcuts on iPhone and iPad. Aurelia keeps the profile's sign-in only in memory, so
/// Siri uses its own key (an integration key the owner creates in Settings › Smart Home) stored
/// in this device's Keychain. Waking the server needs no key at all.
struct IOSSiriKeyStore {
  private static let service = "com.lucas.aurelia.ios.siri"

  func load(server: UUID) -> String? {
    var query = Self.query(server)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
      let key = String(data: data, encoding: .utf8), IOSSiriKeyStore.isKey(key)
    else { return nil }
    return key
  }

  func save(_ key: String, server: UUID) throws {
    guard Self.isKey(key) else { throw IOSCoreError.invalidResponse }
    SecItemDelete(Self.query(server) as CFDictionary)
    var query = Self.query(server)
    query[kSecValueData as String] = Data(key.utf8)
    // Siri may ask while the iPhone is locked, after it was unlocked once since starting.
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else { throw IOSCoreError.invalidResponse }
  }

  func delete(server: UUID) {
    SecItemDelete(Self.query(server) as CFDictionary)
  }

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

struct IOSIntegrationPlayer: Decodable, Equatable, Sendable {
  let deviceId: String
  let deviceName: String
  let clientType: String
  let isPlaying: Bool
  let title: String?
  let isPaused: Bool
}

struct IOSIntegrationStatus: Decodable, Sendable {
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

struct IOSIntegrationTitle: Decodable, Equatable, Sendable {
  let id: UUID
  let kind: String
  let title: String
  let year: Int?
  let parentTitle: String?
  let seasonNumber: Int?
  let episodeNumber: Int?
}

/// The calls Siri makes with its key; each needs the key's scope ("automation-v1", server 2.17.0
/// for finding titles).
struct IOSIntegrationClient: Sendable {
  let connection: IOSStoredConnection
  let key: String
  var transport: any IOSHTTPTransport = IOSURLSessionTransport()

  func status() async throws -> IOSIntegrationStatus { try await get("/api/v1/integration/status") }
  func players() async throws -> [IOSIntegrationPlayer] { try await get("/api/v1/integration/players") }
  func search(_ text: String) async throws -> [IOSIntegrationTitle] {
    try await get("/api/v1/integration/search", query: [URLQueryItem(name: "query", value: text)])
  }
  func episode(of series: UUID, season: Int, episode: Int) async throws -> IOSIntegrationTitle {
    try await get(
      "/api/v1/integration/titles/\(series.uuidString.lowercased())/episode",
      query: [URLQueryItem(name: "season", value: String(season)), URLQueryItem(name: "episode", value: String(episode))])
  }
  func next(in title: UUID) async throws -> IOSIntegrationTitle {
    try await get("/api/v1/integration/titles/\(title.uuidString.lowercased())/next")
  }
  func play(_ media: UUID, on deviceID: String) async throws {
    struct Body: Encodable {
      let action: String
      let mediaId: UUID
    }
    _ = try await send(
      "/api/v1/integration/players/\(deviceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deviceID)/commands",
      method: "POST", body: JSONEncoder().encode(Body(action: "play", mediaId: media)))
  }
  func powerNow(_ action: String) async throws -> String {
    struct Body: Encodable { let action: String }
    struct Answer: Decodable { let message: String }
    let data = try await send("/api/v1/integration/power", method: "POST", body: JSONEncoder().encode(Body(action: action)))
    return try JSONDecoder().decode(Answer.self, from: data).message
  }

  /// Whether the server answers at all (used after waking it).
  func answers() async -> Bool {
    (try? await send("/api/v1/health", method: "GET", authorized: false)) != nil
  }

  private func get<Value: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Value {
    try JSONDecoder().decode(Value.self, from: await send(path, method: "GET", query: query))
  }

  private func send(
    _ path: String, method: String, query: [URLQueryItem] = [], body: Data? = nil, authorized: Bool = true
  ) async throws -> Data {
    guard var components = URLComponents(url: connection.baseURL, resolvingAgainstBaseURL: false) else {
      throw IOSCoreError.invalidAddress
    }
    components.path = path
    components.queryItems = query.isEmpty ? nil : query
    guard let url = components.url else { throw IOSCoreError.invalidAddress }
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.httpMethod = method
    request.httpBody = body
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    if authorized { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    let response = try await transport.execute(request, trust: .pinned(connection.fingerprint))
    guard (200..<300).contains(response.statusCode) else {
      struct Problem: Decodable {
        let code: String?
        let message: String?
      }
      let problem = try? JSONDecoder().decode(Problem.self, from: response.body)
      throw IOSCoreError.server(
        status: response.statusCode, code: problem?.code ?? "request_failed",
        message: problem?.message ?? "The server refused this.", retryAfter: nil)
    }
    return response.body
  }
}

/// "Breaking Bad season 3 episode 4", "Breaking Bad S3E4", "Breaking Bad 3x04" or German
/// "Staffel 3 Folge 4": the title and, when said, the season and episode.
enum IOSTitleRequest {
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
  static func best(_ titles: [IOSIntegrationTitle], for request: Parsed) -> IOSIntegrationTitle? {
    let wanted = request.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    let exact = titles.filter {
      $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == wanted
    }
    let pool = exact.isEmpty ? titles : exact
    if request.season != nil { return pool.first { $0.kind == "series" } ?? pool.first }
    return pool.first
  }

  /// The device to play on: the one named, else an Apple TV, else the only other player.
  static func player(_ players: [IOSIntegrationPlayer], named name: String?) -> IOSIntegrationPlayer? {
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
