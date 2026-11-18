import Foundation
@preconcurrency import MediaPlayer

/// The lock screen's and Control Center's buttons for the playing title.
enum IOSNowPlayingCommand: CaseIterable, Hashable, Sendable {
  case play, pause, toggle, skipBackward, skipForward, changePosition, previousEpisode, nextEpisode
}

/// What the lock screen shows about the playing title.
struct IOSNowPlayingInfo: Equatable, Sendable {
  let title: String
  /// "Series · S1 E3" for an episode.
  let subtitle: String?
  let elapsedSeconds: Double
  let durationSeconds: Double
  let isPlaying: Bool
  let rate: Double

  var values: [String: Any] {
    var values: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsedSeconds),
      MPMediaItemPropertyPlaybackDuration: max(0, durationSeconds),
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0.0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
    ]
    if let subtitle { values[MPMediaItemPropertyArtist] = subtitle }
    return values
  }
}

/// Which buttons are offered, from the player's state alone.
struct IOSNowPlayingState: Equatable, Sendable {
  var isReady: Bool
  var isPlaying: Bool
  var canSeek: Bool
  var hasNext: Bool
  var hasPrevious: Bool

  var enabled: [IOSNowPlayingCommand: Bool] {
    [
      .play: isReady && !isPlaying,
      .pause: isReady && isPlaying,
      .toggle: isReady,
      .skipBackward: isReady && canSeek,
      .skipForward: isReady && canSeek,
      .changePosition: isReady && canSeek,
      .previousEpisode: isReady && hasPrevious,
      .nextEpisode: isReady && hasNext,
    ]
  }
}

/// The eligibility snapshot that MediaPlayer's own queues may read. Playback itself stays on the
/// main actor (docs/SYSTEM_CALLBACKS.md).
final class IOSNowPlayingGate: @unchecked Sendable {
  private let lock = NSLock()
  private var generation: UUID?
  private var enabled: [IOSNowPlayingCommand: Bool] = [:]

  func update(generation: UUID, enabled: [IOSNowPlayingCommand: Bool]) {
    lock.withLock {
      self.generation = generation
      self.enabled = enabled
    }
  }

  func allows(_ command: IOSNowPlayingCommand, generation: UUID) -> Bool {
    lock.withLock { self.generation == generation && enabled[command] == true }
  }

  func clear() {
    lock.withLock {
      generation = nil
      enabled.removeAll()
    }
  }
}

enum IOSNowPlayingCallbacks {
  /// A remote command handler that MediaPlayer may call on any queue: it checks the snapshot,
  /// then schedules the action on the main actor, which checks again before acting.
  nonisolated static func handler(
    for command: IOSNowPlayingCommand, gate: IOSNowPlayingGate, generation: UUID,
    perform: @escaping @MainActor @Sendable (IOSNowPlayingCommand, Double?) -> Void
  ) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
    { @Sendable event in
      respond(
        to: command, position: (event as? MPChangePlaybackPositionCommandEvent)?.positionTime,
        gate: gate, generation: generation, perform: perform)
    }
  }

  /// The handler's answer on MediaPlayer's queue (events can't be made outside MediaPlayer, so
  /// tests call this directly from a background queue).
  nonisolated static func respond(
    to command: IOSNowPlayingCommand, position: Double?, gate: IOSNowPlayingGate,
    generation: UUID,
    perform: @escaping @MainActor @Sendable (IOSNowPlayingCommand, Double?) -> Void
  ) -> MPRemoteCommandHandlerStatus {
    guard gate.allows(command, generation: generation) else { return .noActionableNowPlayingItem }
    Task { @MainActor in perform(command, position) }
    return .success
  }

  /// Where a skip goes, within the title.
  static func skipTarget(position: Int64, duration: Int64, by offset: Int64) -> Int64? {
    guard duration > 0 else { return nil }
    return min(max(0, position + offset), duration)
  }
}
