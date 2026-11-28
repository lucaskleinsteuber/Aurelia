import Foundation

/// A device that plays titles and takes Play On commands (remote-playback-v1), as the server lists
/// it: its name, what it plays and where.
struct IOSRemotePlayer: Codable, Identifiable, Equatable, Sendable {
  var id: String { deviceId }
  let deviceId: String
  let deviceName: String
  let clientType: String
  let isPlaying: Bool
  let mediaId: UUID?
  let title: String?
  let positionSeconds: Double?
  let durationSeconds: Double?
  let isPaused: Bool

  /// "Living Room · Apple TV".
  var kindTitle: String {
    switch clientType.lowercased() {
    case "tvos", "appletv", "apple-tv": "Apple TV"
    case "ios": "iPhone or iPad"
    case "macos", "mac": "Mac"
    case "linux": "Linux"
    case "web", "browser": "Browser"
    default: "Player"
    }
  }

  var symbol: String {
    switch clientType.lowercased() {
    case "tvos", "appletv", "apple-tv": "appletv"
    case "ios": "ipad.and.iphone"
    case "macos", "mac": "laptopcomputer"
    case "web", "browser": "globe"
    default: "play.tv"
    }
  }

  /// What the device does now, for the list.
  var statusText: String {
    guard isPlaying, let title, !title.isEmpty else { return "Ready" }
    return isPaused ? "Paused: \(title)" : "Playing \(title)"
  }
}

struct IOSRemotePlaybackCommandRequest: Encodable, Equatable, Sendable {
  let action: String
  let mediaId: UUID?
  let positionSeconds: Double?
  let skipSeconds: Double?
}

struct IOSRemotePlaybackCommandResponse: Decodable, Sendable {
  let commandId: UUID
  let status: String
}

/// What a command sent to this device asks of it.
enum IOSRemoteAction: Equatable, Sendable {
  case play(UUID)
  case pause
  case resume
  case stop
  case seek(milliseconds: Int64)
  case skip(milliseconds: Int64)

  init?(_ command: IOSRemotePlaybackCommand) {
    switch command.action.lowercased() {
    case "play":
      guard let media = command.mediaId else { return nil }
      self = .play(media)
    case "pause": self = .pause
    case "resume": self = .resume
    case "stop": self = .stop
    case "seek":
      guard let seconds = command.positionSeconds, seconds.isFinite, seconds >= 0 else {
        return nil
      }
      self = .seek(milliseconds: Int64(seconds * 1_000))
    case "skip":
      guard let seconds = command.skipSeconds, seconds.isFinite, abs(seconds) <= 3_600 else {
        return nil
      }
      self = .skip(milliseconds: Int64(seconds * 1_000))
    default: return nil
    }
  }

  var request: IOSRemotePlaybackCommandRequest {
    switch self {
    case .play(let media):
      IOSRemotePlaybackCommandRequest(
        action: "play", mediaId: media, positionSeconds: nil, skipSeconds: nil)
    case .pause:
      IOSRemotePlaybackCommandRequest(
        action: "pause", mediaId: nil, positionSeconds: nil, skipSeconds: nil)
    case .resume:
      IOSRemotePlaybackCommandRequest(
        action: "resume", mediaId: nil, positionSeconds: nil, skipSeconds: nil)
    case .stop:
      IOSRemotePlaybackCommandRequest(
        action: "stop", mediaId: nil, positionSeconds: nil, skipSeconds: nil)
    case .seek(let milliseconds):
      IOSRemotePlaybackCommandRequest(
        action: "seek", mediaId: nil, positionSeconds: Double(milliseconds) / 1_000,
        skipSeconds: nil)
    case .skip(let milliseconds):
      IOSRemotePlaybackCommandRequest(
        action: "skip", mediaId: nil, positionSeconds: nil,
        skipSeconds: Double(milliseconds) / 1_000)
    }
  }
}

enum IOSRemotePlaybackText {
  /// "12:04 / 45:30" for the remote's position line.
  static func position(_ seconds: Double?, of duration: Double?) -> String? {
    guard let duration, duration > 0 else { return nil }
    return "\(clock(seconds ?? 0)) / \(clock(duration))"
  }

  static func clock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.isFinite ? seconds : 0))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let rest = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, rest)
      : String(format: "%d:%02d", minutes, rest)
  }

  static let empty =
    "No other Tarven player is open. Open Tarven on an Apple TV, Mac or another device signed in to this server, then look again."
}
