import Foundation

/// The new server's side of a move while it has no owner yet (docs/SERVER_MOVE.md, "On the new
/// server while it has no owner"). This Mac's own server answers on 127.0.0.1 and accepts the
/// bootstrap token its host passed it at start, the same authority that creates the owner.
struct SetupMoveStatus: Codable, Equatable, Sendable {
  struct Progress: Codable, Equatable, Sendable {
    let received: Int64
    var expected: Int64? = nil

    var fraction: Double? {
      guard let expected, expected > 0 else { return nil }
      return min(1, Double(received) / Double(expected))
    }
  }

  struct Source: Codable, Equatable, Sendable {
    let serverId: UUID
    let name: String
  }

  struct Location: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let oldPath: String
    let sampled: Int
    let suggestions: [StorageRelocationSuggestion]
  }

  /// "idle", "fetching", "received", "applying", "done" or "failed".
  let state: String
  var progress: Progress? = nil
  var error: String? = nil
  var source: Source? = nil
  var locations: [Location]? = nil

  var isWorking: Bool { state == "fetching" || state == "applying" }
}

/// What the Finish button sends: for each storage location its folder on this Mac, or nil to keep
/// the old path (the location stays offline until Storage Location Moved).
struct SetupMoveMapping: Codable, Equatable, Sendable {
  let id: UUID
  let path: String?
}

enum SetupMovePlan {
  /// The folder each location starts with: its best suggestion when any sample file matched it.
  static func initialChoices(for locations: [SetupMoveStatus.Location]) -> [UUID: String] {
    var choices: [UUID: String] = [:]
    for location in locations {
      if let best = location.suggestions.max(by: { $0.matched < $1.matched }), best.matched > 0 {
        choices[location.id] = best.path
      }
    }
    return choices
  }

  /// Every location in the order the server listed them; an empty or missing choice is Later.
  static func mappings(for locations: [SetupMoveStatus.Location], choices: [UUID: String])
    -> [SetupMoveMapping]
  {
    locations.map { location in
      let path = choices[location.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
      return SetupMoveMapping(id: location.id, path: path?.isEmpty == false ? path : nil)
    }
  }

  /// The old server's address as typed: "minipc.local" becomes "https://minipc.local:43111".
  static func normalizedAddress(_ typed: String) -> String {
    var value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return value }
    if !value.lowercased().hasPrefix("https://") && !value.lowercased().hasPrefix("http://") {
      value = "https://" + value
    }
    if let components = URLComponents(string: value), components.port == nil,
      var adjusted = Optional(components)
    {
      adjusted.port = 43_111
      value = adjusted.string ?? value
    }
    return value
  }

  static func failureText(_ code: String?, message: String?) -> String {
    switch code {
    case "move_code_invalid": "That move code isn't right. Check it on the old server."
    case "move_not_waiting":
      "The old server isn't waiting for a move. Start Move to a New Server there first."
    case "move_source_unreachable":
      "The old server didn't answer. Check its address and that both computers are on the same network."
    case "move_address_invalid": "That address doesn't look right."
    case "backup_invalid": "The passphrase is wrong, or the file is damaged."
    case "move_file_invalid":
      "This is a backup, not a moving file. Make a moving file on the old server."
    case "folder_invalid": "One of the folders doesn't exist on this Mac."
    case "locations_overlap": "Two storage locations point at the same folder."
    case "bootstrap_required", "server_already_setup":
      "This Mac's server is already set up, so it can't take over another one."
    default: message ?? "The move didn't work. Try again."
    }
  }
}

struct LocalSetupMoveClient: Sendable {
  private struct Problem: Decodable {
    let code: String?
    let message: String?
  }

  struct Failure: LocalizedError, Equatable {
    let code: String?
    let message: String?
    var errorDescription: String? { SetupMovePlan.failureText(code, message: message) }
  }

  let bootstrapToken: String
  private static let base = URL(string: "http://127.0.0.1:43110")!

  func status() async throws -> SetupMoveStatus {
    try await send("GET", "/api/v1/setup/move")
  }

  func startNetwork(address: String, code: String) async throws -> SetupMoveStatus {
    struct Request: Encodable {
      let address: String
      let code: String
    }
    return try await send(
      "POST", "/api/v1/setup/move/network", body: Request(address: address, code: code),
      timeout: 60)
  }

  /// Uploads the moving file from disk without reading it into memory, then opens it.
  func openFile(_ file: URL, passphrase: String) async throws -> SetupMoveStatus {
    struct Uploaded: Decodable { let uploadId: UUID }
    struct Request: Encodable { let passphrase: String }
    let access = file.startAccessingSecurityScopedResource()
    defer { if access { file.stopAccessingSecurityScopedResource() } }
    var request = makeRequest("PUT", "/api/v1/setup/move/file", timeout: 600)
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
    let uploaded: Uploaded = try Self.decode(data, response)
    return try await send(
      "POST", "/api/v1/setup/move/file/\(uploaded.uploadId.uuidString)/open",
      body: Request(passphrase: passphrase), timeout: 300)
  }

  func preview(locationId: UUID, path: String) async throws -> StorageRelocationPreview {
    struct Request: Encodable {
      let id: UUID
      let path: String
    }
    return try await send(
      "POST", "/api/v1/setup/move/locations/preview",
      body: Request(id: locationId, path: path), timeout: 60)
  }

  func finish(_ mappings: [SetupMoveMapping]) async throws -> SetupMoveStatus {
    struct Request: Encodable { let mappings: [SetupMoveMapping] }
    return try await send(
      "POST", "/api/v1/setup/move/finish", body: Request(mappings: mappings), timeout: 120)
  }

  func discard() async throws {
    let _: SetupMoveStatus = try await send("DELETE", "/api/v1/setup/move")
  }

  private func send<Value: Decodable>(
    _ method: String, _ path: String, body: (any Encodable)? = nil, timeout: TimeInterval = 15
  ) async throws -> Value {
    var request = makeRequest(method, path, timeout: timeout)
    if let body {
      request.httpBody = try JSONEncoder().encode(body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    return try Self.decode(data, response)
  }

  private func makeRequest(_ method: String, _ path: String, timeout: TimeInterval) -> URLRequest {
    var request = URLRequest(url: Self.base.appendingPathComponent(path), timeoutInterval: timeout)
    request.httpMethod = method
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(bootstrapToken, forHTTPHeaderField: "X-Aurelia-Bootstrap-Token")
    return request
  }

  private static func decode<Value: Decodable>(_ data: Data, _ response: URLResponse) throws
    -> Value
  {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let problem = try? JSONDecoder().decode(Problem.self, from: data)
      throw Failure(code: problem?.code, message: problem?.message)
    }
    return try JSONDecoder().decode(Value.self, from: data)
  }
}
