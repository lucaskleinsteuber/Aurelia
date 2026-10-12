import Combine
import Foundation
@preconcurrency import MediaPlayer

enum SystemMediaCommand: CaseIterable, Hashable, Sendable {
  case play, pause, toggle, stop
}

enum SystemMediaCommandResult: Equatable, Sendable {
  case success, unavailable
}

struct SystemMediaNowPlayingInfo: Equatable, Sendable {
  enum State: Equatable, Sendable {
    case playing, paused, stopped
  }

  let title: String
  let subtitle: String?
  let elapsedSeconds: Double
  let durationSeconds: Double
  let playbackRate: Double
  let defaultPlaybackRate: Double
  let state: State

  var nowPlayingValues: [String: Any] {
    var values: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedSeconds,
      MPMediaItemPropertyPlaybackDuration: durationSeconds,
      MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: defaultPlaybackRate,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
    ]
    if let subtitle { values[MPMediaItemPropertyAlbumTitle] = subtitle }
    return values
  }
}

@MainActor
protocol SystemMediaPlaybackControlling: AnyObject {
  var objectWillChange: ObservableObjectPublisher { get }
  var presentation: PlaybackPresentation { get }
  var isPlaying: Bool { get }
  var currentTimeMilliseconds: Int64 { get }
  var durationMilliseconds: Int64 { get }
  var playbackRate: Double { get }
  var canPlay: Bool { get }
  var canPause: Bool { get }
  @discardableResult func play() -> Bool
  @discardableResult func pause() -> Bool
  @discardableResult func togglePlayback() -> Bool
}

extension PlaybackController: SystemMediaPlaybackControlling {}

@MainActor
protocol SystemMediaPlaybackTransport: AnyObject {
  func addHandler(
    for command: SystemMediaCommand,
    handler: @escaping @Sendable () -> SystemMediaCommandResult
  ) -> UUID
  func removeHandler(_ token: UUID)
  func setEnabled(_ enabled: Bool, for command: SystemMediaCommand)
  func publish(_ info: SystemMediaNowPlayingInfo?)
}

/// Owns native media commands only while a player is registered. The injected
/// transport keeps unit tests from claiming this Mac's Now Playing session.
@MainActor
final class SystemMediaPlaybackCoordinator {
  static let shared = SystemMediaPlaybackCoordinator(
    transport: NativeSystemMediaPlaybackTransport())

  private let transport: any SystemMediaPlaybackTransport
  private let commandGate = SystemMediaCommandGate()
  private weak var controller: (any SystemMediaPlaybackControlling)?
  private var generation = UUID()
  private var tokens: [UUID] = []
  private var observation: AnyCancellable?

  init(transport: any SystemMediaPlaybackTransport) {
    self.transport = transport
  }

  deinit {
    commandGate.clear()
  }

  func register(_ controller: any SystemMediaPlaybackControlling) {
    if self.controller === controller {
      update(controller)
      return
    }
    removeRegistration()
    self.controller = controller
    generation = UUID()
    let registration = generation
    let gate = commandGate
    tokens = SystemMediaCommand.allCases.map { command in
      transport.addHandler(for: command) { [weak self] in
        if Thread.isMainThread {
          return MainActor.assumeIsolated {
            self?.perform(command, generation: registration) ?? .unavailable
          }
        }
        guard gate.allows(command, generation: registration) else { return .unavailable }
        // Native callbacks may arrive off the main thread. Success here means
        // an eligible command was queued; ownership and controller guards are
        // checked again before it can mutate playback on the main actor.
        Task { @MainActor [weak self] in
          _ = self?.perform(command, generation: registration)
        }
        return .success
      }
    }
    observation = controller.objectWillChange.sink { [weak self, weak controller] in
      // Published properties notify before changing. Read the resulting state
      // after the controller finishes its main-actor mutation.
      Task { @MainActor [weak self, weak controller] in
        guard let controller else { return }
        self?.update(controller)
      }
    }
    update(controller)
  }

  func unregister(_ controller: any SystemMediaPlaybackControlling) {
    guard self.controller === controller else { return }
    removeRegistration()
    transport.publish(nil)
  }

  func update(_ controller: any SystemMediaPlaybackControlling) {
    guard self.controller === controller else { return }
    let enabled: [SystemMediaCommand: Bool] = [
      .play: controller.canPlay,
      .pause: controller.canPause,
      .toggle: controller.isPlaying ? controller.canPause : controller.canPlay,
      .stop: controller.canPause,
    ]
    commandGate.update(owner: controller, generation: generation, enabled: enabled)
    for command in SystemMediaCommand.allCases {
      transport.setEnabled(enabled[command] == true, for: command)
    }
    let rate =
      controller.playbackRate.isFinite && controller.playbackRate > 0
      ? controller.playbackRate : 1
    transport.publish(
      SystemMediaNowPlayingInfo(
        title: controller.presentation.title,
        subtitle: controller.presentation.subtitle,
        elapsedSeconds: Double(max(0, controller.currentTimeMilliseconds)) / 1_000,
        durationSeconds: Double(max(0, controller.durationMilliseconds)) / 1_000,
        playbackRate: controller.isPlaying ? rate : 0,
        defaultPlaybackRate: rate,
        state: controller.isPlaying
          ? .playing : (controller.canPlay || controller.canPause ? .paused : .stopped)))
  }

  private func perform(_ command: SystemMediaCommand, generation: UUID) -> SystemMediaCommandResult
  {
    guard self.generation == generation, let controller else { return .unavailable }
    let accepted: Bool
    switch command {
    case .play: accepted = controller.play()
    case .pause, .stop: accepted = controller.pause()
    case .toggle: accepted = controller.togglePlayback()
    }
    update(controller)
    return accepted ? .success : .unavailable
  }

  private func removeRegistration() {
    commandGate.clear()
    observation?.cancel()
    observation = nil
    for token in tokens { transport.removeHandler(token) }
    tokens.removeAll()
    for command in SystemMediaCommand.allCases { transport.setEnabled(false, for: command) }
    controller = nil
    generation = UUID()
  }
}

/// Only this eligibility snapshot is read from native callback queues. Playback
/// state and controller actions remain confined to the main actor.
private final class SystemMediaCommandGate: @unchecked Sendable {
  private let lock = NSLock()
  private weak var owner: AnyObject?
  private var generation: UUID?
  private var enabled: [SystemMediaCommand: Bool] = [:]

  func update(owner: AnyObject, generation: UUID, enabled: [SystemMediaCommand: Bool]) {
    lock.withLock {
      self.owner = owner
      self.generation = generation
      self.enabled = enabled
    }
  }

  func allows(_ command: SystemMediaCommand, generation: UUID) -> Bool {
    lock.withLock { owner != nil && self.generation == generation && enabled[command] == true }
  }

  func clear() {
    lock.withLock {
      owner = nil
      generation = nil
      enabled.removeAll()
    }
  }
}

@MainActor
private final class NativeSystemMediaPlaybackTransport: SystemMediaPlaybackTransport {
  private let commands = MPRemoteCommandCenter.shared()
  private let nowPlaying = MPNowPlayingInfoCenter.default()
  private var targets: [UUID: (MPRemoteCommand, Any)] = [:]

  func addHandler(
    for command: SystemMediaCommand,
    handler: @escaping @Sendable () -> SystemMediaCommandResult
  ) -> UUID {
    let remote = remoteCommand(command)
    let target = remote.addTarget { _ in
      switch handler() {
      case .success: .success
      case .unavailable: .noActionableNowPlayingItem
      }
    }
    let token = UUID()
    targets[token] = (remote, target)
    return token
  }

  func removeHandler(_ token: UUID) {
    guard let (command, target) = targets.removeValue(forKey: token) else { return }
    command.removeTarget(target)
  }

  func setEnabled(_ enabled: Bool, for command: SystemMediaCommand) {
    remoteCommand(command).isEnabled = enabled
  }

  func publish(_ info: SystemMediaNowPlayingInfo?) {
    guard let info else {
      nowPlaying.nowPlayingInfo = nil
      nowPlaying.playbackState = .stopped
      return
    }
    nowPlaying.nowPlayingInfo = info.nowPlayingValues
    switch info.state {
    case .playing: nowPlaying.playbackState = .playing
    case .paused: nowPlaying.playbackState = .paused
    case .stopped: nowPlaying.playbackState = .stopped
    }
  }

  private func remoteCommand(_ command: SystemMediaCommand) -> MPRemoteCommand {
    switch command {
    case .play: commands.playCommand
    case .pause: commands.pauseCommand
    case .toggle: commands.togglePlayPauseCommand
    case .stop: commands.stopCommand
    }
  }
}
