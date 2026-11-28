import Foundation

/// Moving a server to another computer (docs/SERVER_MOVE.md). The old server hands out a move
/// code or a moving file; the new one takes over its identity, data and sign-ins.
struct ServerMoveStatusResponse: Codable, Equatable, Sendable {
  /// "none", "waiting", "transferring" or "moved".
  let state: String
  var method: String? = nil
  var expiresAt: String? = nil
  var movedTo: ServerMoveTarget? = nil
  var movedAt: String? = nil

  var isMoved: Bool { state == "moved" }
  var isWaiting: Bool { state == "waiting" || state == "transferring" }
}

struct ServerMoveStartResponse: Codable, Equatable, Sendable {
  let state: String
  let method: String
  var code: String? = nil
  var expiresAt: String? = nil
  var transferId: UUID? = nil
}

struct StorageRelocationSuggestion: Codable, Equatable, Sendable, Identifiable {
  let path: String
  let matched: Int
  var id: String { path }
}

struct StorageRelocationSuggestions: Codable, Equatable, Sendable {
  let sampled: Int
  let suggestions: [StorageRelocationSuggestion]
}

struct StorageRelocationPreview: Codable, Equatable, Sendable {
  let sampled: Int
  let matched: Int
}

/// The words the move and relocation sheets show; kept apart from the views so they are tested.
enum ServerMoveText {
  /// "412 of 415 sample files found", or a plain sentence when the location had no files.
  static func match(_ matched: Int, of sampled: Int) -> String {
    guard sampled > 0 else { return "No sample files to compare" }
    if matched == 0 { return "None of the \(sampled) sample files found" }
    if matched == sampled { return "All \(sampled) sample files found" }
    return "\(matched) of \(sampled) sample files found"
  }

  /// "14:32 left" until the move code runs out, or nil once it did.
  static func remaining(until expiry: Date, now: Date = Date()) -> String? {
    let seconds = Int(expiry.timeIntervalSince(now).rounded(.down))
    guard seconds > 0 else { return nil }
    return String(format: "%d:%02d left", seconds / 60, seconds % 60)
  }

  /// The code as the old server shows it, grouped for reading aloud: "ABCD-EFGH-JKMN".
  static func grouped(_ code: String) -> String {
    let plain = code.uppercased().filter { $0.isLetter || $0.isNumber }
    var groups: [String] = []
    var index = plain.startIndex
    while index < plain.endIndex {
      let end = plain.index(index, offsetBy: 4, limitedBy: plain.endIndex) ?? plain.endIndex
      groups.append(String(plain[index..<end]))
      index = end
    }
    return groups.joined(separator: "-")
  }

  static func movedSummary(_ status: ServerMoveStatusResponse) -> String {
    guard let target = status.movedTo else { return "This server moved to another computer." }
    let address = target.addresses.first.map { " at \($0.host ?? $0.absoluteString)" } ?? ""
    return "This server moved to “\(target.name)”\(address). Devices follow it there by themselves."
  }
}
