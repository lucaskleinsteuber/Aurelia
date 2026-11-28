import Combine
import Foundation
@preconcurrency import MediaPlayer
import UIKit

/// The lock screen and Control Center while a title plays: its name, poster, position and the
/// buttons for play, pause, skipping, seeking and the next episode. Registered by the player while
/// it is open, removed when it closes, so the system never shows a title that ended.
@MainActor
final class IOSNowPlayingCoordinator {
  static let shared = IOSNowPlayingCoordinator()

  private let commands = MPRemoteCommandCenter.shared()
  private let center = MPNowPlayingInfoCenter.default()
  private let gate = IOSNowPlayingGate()
  private weak var controller: IOSPlaybackController?
  private var generation = UUID()
  private var targets: [(MPRemoteCommand, Any)] = []
  private var observation: AnyCancellable?
  private var artworkKey: String?
  private var artwork: MPMediaItemArtwork?
  private var artworkTask: Task<Void, Never>?
  private var lastInfo: IOSNowPlayingInfo?

  func register(_ controller: IOSPlaybackController) {
    guard self.controller !== controller else { return update() }
    unregisterAll()
    self.controller = controller
    generation = UUID()
    let interval = NSNumber(value: Double(controller.seekInterval) / 1_000)
    commands.skipBackwardCommand.preferredIntervals = [interval]
    commands.skipForwardCommand.preferredIntervals = [interval]
    for command in IOSNowPlayingCommand.allCases {
      let remote = remoteCommand(command)
      let handler = IOSNowPlayingCallbacks.handler(
        for: command, gate: gate, generation: generation
      ) { [weak self] command, position in self?.perform(command, position: position) }
      targets.append((remote, remote.addTarget(handler: handler)))
    }
    observation = controller.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.update() }
    update()
  }

  func unregister(_ controller: IOSPlaybackController) {
    guard self.controller === controller else { return }
    unregisterAll()
  }

  private func unregisterAll() {
    gate.clear()
    observation = nil
    artworkTask?.cancel()
    artworkTask = nil
    artworkKey = nil
    artwork = nil
    lastInfo = nil
    for (command, target) in targets { command.removeTarget(target) }
    targets.removeAll()
    for command in IOSNowPlayingCommand.allCases { remoteCommand(command).isEnabled = false }
    controller = nil
    generation = UUID()
    center.nowPlayingInfo = nil
    center.playbackState = .stopped
  }

  private func update() {
    guard let controller else { return }
    let state = IOSNowPlayingState(
      isReady: !controller.isLoading && controller.errorMessage == nil && !controller.isClosing,
      isPlaying: controller.isPlaying, canSeek: controller.canSeek,
      hasNext: controller.hasNextEpisode, hasPrevious: false)
    let enabled = state.enabled
    gate.update(generation: generation, enabled: enabled)
    for command in IOSNowPlayingCommand.allCases {
      remoteCommand(command).isEnabled = enabled[command] == true
    }
    loadArtwork(for: controller)
    let info = IOSNowPlayingInfo(
      title: controller.title, subtitle: nil,
      elapsedSeconds: Double(controller.position) / 1_000,
      durationSeconds: Double(controller.duration) / 1_000,
      isPlaying: controller.isPlaying, rate: controller.playbackRate)
    // The system extrapolates the position from the rate; republish only on a real change.
    guard info != lastInfo || center.nowPlayingInfo == nil else { return }
    let jumped =
      lastInfo.map {
        abs($0.elapsedSeconds - info.elapsedSeconds) > 2 || $0.isPlaying != info.isPlaying
          || $0.title != info.title || $0.durationSeconds != info.durationSeconds
      } ?? true
    guard jumped else { return }
    lastInfo = info
    var values = info.values
    if let artwork { values[MPMediaItemPropertyArtwork] = artwork }
    center.nowPlayingInfo = values
    center.playbackState = info.isPlaying ? .playing : .paused
  }

  private func perform(_ command: IOSNowPlayingCommand, position: Double?) {
    guard let controller, gate.allows(command, generation: generation) else { return }
    switch command {
    case .play: if !controller.isPlaying { controller.togglePlayPause() }
    case .pause: if controller.isPlaying { controller.togglePlayPause() }
    case .toggle: controller.togglePlayPause()
    case .skipBackward: controller.seek(by: -controller.seekInterval, revealControls: false)
    case .skipForward: controller.seek(by: controller.seekInterval, revealControls: false)
    case .changePosition:
      if let position { controller.seek(to: Int64(position * 1_000)) }
    case .previousEpisode: break
    case .nextEpisode: controller.playNextNow()
    }
    lastInfo = nil
    update()
  }

  private func loadArtwork(for controller: IOSPlaybackController) {
    let poster = controller.nowPlayingArtwork
    let key = poster?.cacheIdentity
    guard key != artworkKey else { return }
    artworkKey = key
    artwork = nil
    artworkTask?.cancel()
    guard let poster else { return }
    let api = controller.api
    artworkTask = Task { [weak self] in
      guard let data = try? await api.artworkData(artwork: poster, width: 600),
        let image = UIImage(data: data)?.cgImage
      else { return }
      guard let self, self.artworkKey == key else { return }
      self.artwork = Self.mediaArtwork(image)
      self.lastInfo = nil
      self.update()
    }
  }

  /// Built outside the main actor: MediaPlayer asks for the picture on its own queue, and only
  /// immutable pixels cross over.
  private nonisolated static func mediaArtwork(_ image: CGImage) -> MPMediaItemArtwork {
    let pixels = IOSImmutablePixels(image: image)
    let size = CGSize(width: image.width, height: image.height)
    return MPMediaItemArtwork(boundsSize: size) { @Sendable _ in UIImage(cgImage: pixels.image) }
  }

  private func remoteCommand(_ command: IOSNowPlayingCommand) -> MPRemoteCommand {
    switch command {
    case .play: commands.playCommand
    case .pause: commands.pauseCommand
    case .toggle: commands.togglePlayPauseCommand
    case .skipBackward: commands.skipBackwardCommand
    case .skipForward: commands.skipForwardCommand
    case .changePosition: commands.changePlaybackPositionCommand
    case .previousEpisode: commands.previousTrackCommand
    case .nextEpisode: commands.nextTrackCommand
    }
  }
}

/// A CGImage never changes once made, so handing it to MediaPlayer's queue is safe.
private struct IOSImmutablePixels: @unchecked Sendable {
  let image: CGImage
}
