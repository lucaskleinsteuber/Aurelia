import Foundation

// Moving a whole server to another computer and Storage Location Moved (docs/SERVER_MOVE.md), as
// the browser and the Mac do it. The owner starts a move on the old server; the new server, set up
// here, takes it in with the setup code.

// MARK: Storage Location Moved

struct IOSMoveSuggestion: Codable, Equatable, Identifiable, Sendable {
  let path: String
  let matched: Int
  var id: String { path }
}

struct IOSMoveLocationSuggestions: Codable, Equatable, Sendable {
  let sampled: Int
  let suggestions: [IOSMoveSuggestion]
}

struct IOSMoveLocationMatch: Codable, Equatable, Sendable {
  let sampled: Int
  let matched: Int
}

struct IOSRelocateResult: Codable, Equatable, Sendable {
  let sampled: Int
  let matched: Int
  let titles: Int
}

/// Whether a previewed folder may become the storage location, as in the browser: files found
/// is enough; none found needs a second Use Anyway, which the server takes as `force`.
struct IOSRelocateDecision: Equatable, Sendable {
  let canConfirm: Bool
  let force: Bool
  let needsSecondConfirmation: Bool
  let text: String

  init(preview: IOSMoveLocationMatch?, confirmedEmpty: Bool = false) {
    guard let preview else {
      self.init(false, false, false, "Choose a folder and preview it first.")
      return
    }
    if preview.matched > 0 {
      self.init(true, false, false, Self.matchText(preview.matched, of: preview.sampled))
    } else {
      self.init(
        confirmedEmpty, confirmedEmpty, true,
        preview.sampled > 0
          ? "\(Self.matchText(0, of: preview.sampled)). This may be the wrong folder."
          : Self.matchText(0, of: 0))
    }
  }

  private init(_ canConfirm: Bool, _ force: Bool, _ second: Bool, _ text: String) {
    self.canConfirm = canConfirm
    self.force = force
    needsSecondConfirmation = second
    self.text = text
  }

  static func matchText(_ matched: Int, of sampled: Int) -> String {
    if sampled <= 0 { return "This location had no files to compare." }
    if matched <= 0 { return "None of \(sampled) sample file\(sampled == 1 ? "" : "s") found" }
    if matched >= sampled { return "All \(sampled) sample file\(sampled == 1 ? "" : "s") found" }
    return "\(matched) of \(sampled) sample files found"
  }
}

// MARK: The old server

struct IOSServerMoveStatus: Codable, Equatable, Sendable {
  /// "idle", "waiting" (a code or moving file is out) or "moved".
  let state: String
  let method: String?
  let expiresAt: String?
  let movedTo: IOSServerMoveTarget?
}

struct IOSServerMoveStarted: Codable, Equatable, Sendable {
  let state: String
  let method: String
  let code: String?
  let expiresAt: String?
  let transferId: UUID?
}

// MARK: The new server

struct IOSSetupMoveProgress: Codable, Equatable, Sendable {
  let received: Int64
  let expected: Int64?
}

struct IOSSetupMoveSource: Codable, Equatable, Sendable {
  let serverId: UUID
  let name: String
}

struct IOSSetupMoveLocation: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let name: String
  let oldPath: String
  let sampled: Int
  let suggestions: [IOSMoveSuggestion]
}

struct IOSSetupMoveStatus: Codable, Equatable, Sendable {
  /// "idle", "receiving", "received" or "failed".
  let state: String
  let progress: IOSSetupMoveProgress?
  let error: String?
  let source: IOSSetupMoveSource?
  let locations: [IOSSetupMoveLocation]
}

struct IOSMovePathMapping: Codable, Equatable, Sendable {
  let id: UUID
  let path: String?
}

enum IOSServerMoveText {
  /// A friendly sentence for the move problems the server reports, as in the browser.
  static func problem(_ code: String?) -> String? {
    switch code {
    case "move_not_waiting":
      "The old server isn’t waiting for a move. On the old server, choose Move to a New Server… and use the code it shows."
    case "move_code_invalid", "invalid_move_code":
      "That move code is not right or has expired. Check the code the old server shows."
    case "move_address_invalid": "Enter the old server’s address, such as 192.168.1.20."
    case "move_source_unreachable", "move_source_failed":
      "The old server couldn’t be reached at that address. Check that it is on and shows its move code."
    case "move_in_progress": "A move is already under way on this server."
    case "setup_code_invalid":
      "That setup code is not right. On the server computer, run: sudo tarven setup --browser"
    case "backup_invalid", "invalid_passphrase", "backup_passphrase_invalid":
      "The passphrase doesn’t open this moving file."
    case "move_file_invalid":
      "This file is not a moving file. On the old server, choose Move to a New Server… › With a Moving File."
    case "move_not_received": "The old server’s data hasn’t arrived yet. Start the move again."
    case "folder_invalid": "Choose an existing folder on this computer, with its whole path."
    case "locations_overlap":
      "Two storage locations can’t use the same folder. Choose another folder, or Later."
    case "relocate_no_matches":
      "None of this storage location's sample files are in that folder. Use Anyway points it there all the same."
    default: nil
    }
  }

  static func message(_ error: Error) -> String {
    if let failure = error as? IOSCoreError, let text = problem(failure.problemCode) { return text }
    return (error as? LocalizedError)?.errorDescription ?? "Something went wrong. Try again."
  }

  /// What stops setting up a new server, as in the browser, plus the owner's viewing PIN.
  static func setupProblem(
    code: String, ownerName: String, password: String, repeat again: String, pin: String
  ) -> String? {
    if setupCode(code) == nil {
      return "Enter the 10-character setup code from the server computer."
    }
    if ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Choose a name for the owner."
    }
    if password.count < 12 { return "The Server Password needs at least 12 characters." }
    if password != again { return "The passwords don’t match." }
    if !(4...8).contains(pin.count) || !pin.allSatisfy(\.isNumber) {
      return "Choose a viewing PIN with 4 to 8 digits."
    }
    return nil
  }

  /// "ABCDE-FGHJK": the setup code as typed, in any case, with or without the dash.
  static func setupCode(_ typed: String) -> String? {
    let letters = typed.uppercased().filter { $0.isLetter || $0.isNumber }
    guard letters.count == 10 else { return nil }
    return "\(letters.prefix(5))-\(letters.suffix(5))"
  }
}

extension IOSAPIClient {
  private func move<Value: Decodable>(
    _ path: String, method: String = "GET", query: [URLQueryItem] = [], json body: Data? = nil,
    longRunning: Bool = false
  ) async throws -> Value {
    try Self.decodeAdmin(
      Value.self,
      data: await adminData(
        path, method: method, query: query, body: body, longRunning: longRunning))
  }

  private static func library(_ id: UUID) -> String {
    "/api/v1/libraries/\(id.uuidString.lowercased())/relocate"
  }

  func relocateSuggestions(library: UUID) async throws -> IOSMoveLocationSuggestions {
    try await move("\(Self.library(library))/suggestions", longRunning: true)
  }

  func relocatePreview(library: UUID, path: String) async throws -> IOSMoveLocationMatch {
    struct Payload: Encodable { let path: String }
    return try await move(
      "\(Self.library(library))/preview", method: "POST",
      json: JSONEncoder().encode(Payload(path: path)), longRunning: true)
  }

  func relocate(library: UUID, path: String, force: Bool) async throws -> IOSRelocateResult {
    struct Payload: Encodable {
      let path: String
      let force: Bool
    }
    return try await move(
      Self.library(library), method: "POST",
      json: JSONEncoder().encode(Payload(path: path, force: force)), longRunning: true)
  }

  // MARK: Old server

  func serverMoveStatus() async throws -> IOSServerMoveStatus {
    try await move("/api/v1/server/move")
  }

  /// Starts a move: "network" shows a move code, "file" makes an encrypted moving file.
  func startServerMove(method: String, passphrase: String? = nil) async throws
    -> IOSServerMoveStarted
  {
    struct Payload: Encodable {
      let method: String
      let passphrase: String?
    }
    return try await move(
      "/api/v1/server/move", method: "POST",
      json: JSONEncoder().encode(Payload(method: method, passphrase: passphrase)),
      longRunning: true)
  }

  /// Saves the moving file the server made to `destination` and removes it from the server.
  func downloadMovingFile(transfer: UUID, to destination: URL) async throws {
    let path = "/api/v1/server/backups/transfers/\(transfer.uuidString.lowercased())"
    defer { Task { [self] in _ = try? await adminData(path, method: "DELETE") } }
    try await IOSLongRunningTransport().download(
      adminFileRequest(path), fingerprint: fingerprint, to: destination)
  }

  func markServerMoved() async throws {
    _ = try await adminData("/api/v1/server/move/mark-moved", method: "POST")
  }

  func cancelServerMove() async throws {
    _ = try await adminData("/api/v1/server/move", method: "DELETE")
  }

  // MARK: New server

  func setupMoveStatus(setupCode: String) async throws -> IOSSetupMoveStatus {
    try Self.decodeAdmin(
      IOSSetupMoveStatus.self, data: await setupMoveData(setupCode: setupCode))
  }

  func setupMoveNetwork(address: String, code: String, setupCode: String) async throws
    -> IOSSetupMoveStatus
  {
    struct Payload: Encodable {
      let address: String
      let code: String
    }
    return try Self.decodeAdmin(
      IOSSetupMoveStatus.self,
      data: await setupMoveData(
        "/network", method: "POST",
        body: JSONEncoder().encode(Payload(address: address, code: code)), setupCode: setupCode))
  }

  /// Sends a moving file to the new server, then opens it with its passphrase.
  func setupMoveFile(_ file: URL, passphrase: String, setupCode: String) async throws
    -> IOSSetupMoveStatus
  {
    struct Upload: Decodable { let uploadId: UUID }
    struct Payload: Encodable { let passphrase: String }
    var request = try setupMoveRequest("/file", method: "PUT", setupCode: setupCode)
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    let response = try await IOSLongRunningTransport().upload(
      request, fingerprint: fingerprint, from: file)
    guard (200..<300).contains(response.statusCode) else {
      struct Problem: Decodable {
        let code: String?
        let message: String?
      }
      let problem = try? JSONDecoder().decode(Problem.self, from: response.body)
      throw IOSCoreError.server(
        status: response.statusCode, code: problem?.code, message: problem?.message,
        retryAfter: nil)
    }
    let upload = try Self.decodeAdmin(Upload.self, data: response.body)
    return try Self.decodeAdmin(
      IOSSetupMoveStatus.self,
      data: await setupMoveData(
        "/file/\(upload.uploadId.uuidString.lowercased())/open", method: "POST",
        body: JSONEncoder().encode(Payload(passphrase: passphrase)), setupCode: setupCode))
  }

  func setupMovePreview(location: UUID, path: String, setupCode: String) async throws
    -> IOSMoveLocationMatch
  {
    struct Payload: Encodable {
      let id: UUID
      let path: String
    }
    return try Self.decodeAdmin(
      IOSMoveLocationMatch.self,
      data: await setupMoveData(
        "/locations/preview", method: "POST",
        body: JSONEncoder().encode(Payload(id: location, path: path)), setupCode: setupCode))
  }

  /// Finishes the move; the new server restarts with the old one's data and devices follow it.
  func finishSetupMove(_ mappings: [IOSMovePathMapping], setupCode: String) async throws {
    struct Payload: Encodable { let mappings: [IOSMovePathMapping] }
    _ = try await setupMoveData(
      "/finish", method: "POST", body: JSONEncoder().encode(Payload(mappings: mappings)),
      setupCode: setupCode)
  }

  func discardSetupMove(setupCode: String) async throws {
    _ = try await setupMoveData(method: "DELETE", setupCode: setupCode)
  }
}
