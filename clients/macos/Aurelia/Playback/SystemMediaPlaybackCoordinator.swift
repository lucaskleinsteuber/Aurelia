@preconcurrency import AppKit
import Combine
import Foundation
@preconcurrency import MediaPlayer

enum SystemMediaCommand: CaseIterable, Hashable, Sendable {
  case play, pause, toggle, stop, skipBackward, skipForward, previousEpisode, nextEpisode

  nonisolated static func episodeShortcut(
    characters: String?, modified: Bool, isRepeat: Bool = false
  ) -> Self? {
    guard !modified, !isRepeat else { return nil }
    switch characters?.lowercased() {
    case "p": return .previousEpisode
    case "n": return .nextEpisode
    default: return nil
    }
  }
}

/// In-window commands must leave the field editor and sheets their standard shortcuts.
@MainActor
enum EpisodeKeyboardPolicy {
  static func permits(isKeyWindow: Bool, hasSheet: Bool, isTextEditing: Bool, isBlocked: Bool)
    -> Bool
  {
    isKeyWindow && !hasSheet && !isTextEditing && !isBlocked
  }

  static var allowsMenu: Bool {
    guard NSApplication.shared.isActive, let window = NSApplication.shared.keyWindow else {
      return false
    }
    return permits(
      isKeyWindow: window.isKeyWindow, hasSheet: window.attachedSheet != nil,
      isTextEditing: window.firstResponder is NSTextView || window.firstResponder is NSTextField,
      isBlocked: false)
  }
}

enum SystemMediaCommandResult: Equatable, Sendable {
  case success, unavailable
}

/// Framework handlers may run on MediaPlayer's private queues, even when registered on main.
enum SystemMediaCallbacks {
  nonisolated static func remoteCommandHandler(
    _ handler: @escaping @Sendable () -> SystemMediaCommandResult
  ) -> @Sendable (MPRemoteCommandEvent?) -> MPRemoteCommandHandlerStatus {
    { @Sendable _ in
      switch handler() {
      case .success: .success
      case .unavailable: .noActionableNowPlayingItem
      }
    }
  }
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
  var canSeek: Bool { get }
  var canPlayNext: Bool { get }
  var canPlayPrevious: Bool { get }
  func seek(to milliseconds: Int64)
  @discardableResult func playNextFromSystemMedia() -> Bool
  @discardableResult func playPreviousFromSystemMedia() -> Bool
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
  func publish(_ info: SystemMediaNowPlayingInfo?, artwork: NSImage?)
}

/// Owns native media commands only while a player is registered. The injected
/// transport keeps unit tests from claiming this Mac's Now Playing session.
@MainActor
final class SystemMediaPlaybackCoordinator {
  typealias ArtworkProvider = @MainActor (ArtworkSummary) async throws -> NSImage

  static let shared = SystemMediaPlaybackCoordinator(
    transport: NativeSystemMediaPlaybackTransport())

  private let transport: any SystemMediaPlaybackTransport
  private let commandGate = SystemMediaCommandGate()
  private weak var controller: (any SystemMediaPlaybackControlling)?
  private var generation = UUID()
  private var tokens: [UUID] = []
  private var observation: AnyCancellable?
  private var artworkProvider: ArtworkProvider?
  private var artworkTask: Task<Void, Never>?
  private var artworkIdentity: ArtworkIdentity?
  private var artworkImage: NSImage?

  private struct ArtworkIdentity: Equatable {
    let mediaID: UUID
    let artwork: ArtworkSummary?
  }

  init(transport: any SystemMediaPlaybackTransport) {
    self.transport = transport
  }

  deinit {
    commandGate.clear()
    artworkTask?.cancel()
  }

  func register(
    _ controller: any SystemMediaPlaybackControlling, loadArtwork: ArtworkProvider? = nil
  ) {
    if self.controller === controller {
      update(controller)
      return
    }
    removeRegistration()
    self.controller = controller
    artworkProvider = loadArtwork
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
    transport.publish(nil, artwork: nil)
  }

  func update(_ controller: any SystemMediaPlaybackControlling) {
    guard self.controller === controller else { return }
    let active = controller.canPlay || controller.canPause || controller.isPlaying
    let enabled: [SystemMediaCommand: Bool] = [
      .play: controller.canPlay,
      .pause: controller.canPause,
      .toggle: controller.isPlaying ? controller.canPause : controller.canPlay,
      .stop: controller.canPause,
      .skipBackward: active && controller.canSeek,
      .skipForward: active && controller.canSeek,
      .nextEpisode: active && controller.canPlayNext,
      .previousEpisode: active && controller.canPlayPrevious,
    ]
    commandGate.update(owner: controller, generation: generation, enabled: enabled)
    for command in SystemMediaCommand.allCases {
      transport.setEnabled(enabled[command] == true, for: command)
    }
    guard active else {
      clearArtwork()
      transport.publish(nil, artwork: nil)
      return
    }
    updateArtwork(for: controller)
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
          ? .playing : .paused), artwork: artworkImage)
  }

  private func perform(_ command: SystemMediaCommand, generation: UUID) -> SystemMediaCommandResult
  {
    guard self.generation == generation else { return .unavailable }
    guard let controller else {
      removeRegistration()
      transport.publish(nil, artwork: nil)
      return .unavailable
    }
    let accepted: Bool
    switch command {
    case .play: accepted = controller.play()
    case .pause, .stop: accepted = controller.pause()
    case .toggle: accepted = controller.togglePlayback()
    case .skipBackward, .skipForward:
      guard controller.canSeek, controller.canPlay || controller.canPause || controller.isPlaying,
        let target = Self.skipTarget(
          position: controller.currentTimeMilliseconds, duration: controller.durationMilliseconds,
          forward: command == .skipForward)
      else { return .unavailable }
      controller.seek(to: target)
      accepted = true
    case .previousEpisode:
      guard controller.canPlayPrevious,
        controller.canPlay || controller.canPause || controller.isPlaying
      else { return .unavailable }
      accepted = controller.playPreviousFromSystemMedia()
    case .nextEpisode:
      guard controller.canPlayNext,
        controller.canPlay || controller.canPause || controller.isPlaying
      else { return .unavailable }
      accepted = controller.playNextFromSystemMedia()
    }
    update(controller)
    return accepted ? .success : .unavailable
  }

  static func skipTarget(position: Int64, duration: Int64, forward: Bool) -> Int64? {
    guard duration > 0 else { return nil }
    let position = min(max(position, 0), duration)
    if forward { return position + min(10_000, duration - position) }
    return max(0, position - 10_000)
  }

  private func updateArtwork(for controller: any SystemMediaPlaybackControlling) {
    let identity = ArtworkIdentity(
      mediaID: controller.presentation.mediaId, artwork: controller.presentation.artwork)
    guard identity != artworkIdentity else { return }
    clearArtwork()
    artworkIdentity = identity
    guard let artwork = identity.artwork, let artworkProvider else { return }
    let registration = generation
    artworkTask = Task { [weak self, weak controller] in
      do {
        let image = try await artworkProvider(artwork)
        try Task.checkCancellation()
        guard let self, let controller, self.controller === controller,
          self.generation == registration, self.artworkIdentity == identity,
          controller.presentation.mediaId == identity.mediaID,
          controller.presentation.artwork == identity.artwork
        else { return }
        self.artworkImage = image
        self.artworkTask = nil
        self.update(controller)
      } catch {
        // Artwork is optional. Keep playback metadata; retry only for a new title/revision.
      }
    }
  }

  private func clearArtwork() {
    artworkTask?.cancel()
    artworkTask = nil
    artworkIdentity = nil
    artworkImage = nil
  }

  private func removeRegistration() {
    commandGate.clear()
    observation?.cancel()
    observation = nil
    clearArtwork()
    artworkProvider = nil
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
  private var sourceArtwork: NSImage?
  private var mediaArtwork: MPMediaItemArtwork?

  init() {
    commands.skipBackwardCommand.preferredIntervals = [10]
    commands.skipForwardCommand.preferredIntervals = [10]
  }

  func addHandler(
    for command: SystemMediaCommand,
    handler: @escaping @Sendable () -> SystemMediaCommandResult
  ) -> UUID {
    let remote = remoteCommand(command)
    let target = remote.addTarget(handler: SystemMediaCallbacks.remoteCommandHandler(handler))
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

  func publish(_ info: SystemMediaNowPlayingInfo?, artwork: NSImage?) {
    guard let info else {
      sourceArtwork = nil
      mediaArtwork = nil
      nowPlaying.nowPlayingInfo = nil
      nowPlaying.playbackState = .stopped
      return
    }
    if sourceArtwork !== artwork {
      sourceArtwork = artwork
      mediaArtwork = artwork.flatMap(SystemMediaArtwork.mediaItem)
    }
    var values = info.nowPlayingValues
    if let mediaArtwork { values[MPMediaItemPropertyArtwork] = mediaArtwork }
    nowPlaying.nowPlayingInfo = values
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
    case .skipBackward: commands.skipBackwardCommand
    case .skipForward: commands.skipForwardCommand
    case .previousEpisode: commands.previousTrackCommand
    case .nextEpisode: commands.nextTrackCommand
    }
  }
}

/// The loader already decodes a bounded variant. Native artwork keeps immutable pixels and
/// only changes its display size, preserving aspect ratio without allocating enlarged bitmaps.
enum SystemMediaArtwork {
  private struct Bitmap: @unchecked Sendable {
    let image: CGImage
  }

  nonisolated static func fittedSize(source: NSSize, requested: NSSize) -> NSSize? {
    guard source.width.isFinite, source.height.isFinite, requested.width.isFinite,
      requested.height.isFinite, source.width > 0, source.height > 0,
      requested.width > 0, requested.height > 0
    else { return nil }
    let scale = min(1, requested.width / source.width, requested.height / source.height)
    return NSSize(width: source.width * scale, height: source.height * scale)
  }

  @MainActor static func mediaItem(_ image: NSImage) -> MPMediaItemArtwork? {
    guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return nil
    }
    let bitmap = Bitmap(image: pixels)
    let source = NSSize(width: pixels.width, height: pixels.height)
    return mediaItem(bitmap: bitmap, source: source)
  }

  // Construct the request handler outside MainActor so MediaPlayer can call it on accessQueue.
  // Only immutable pixels and value geometry cross this boundary; no UI/model state is captured.
  private nonisolated static func mediaItem(bitmap: Bitmap, source: NSSize) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: source) { @Sendable requested in
      NSImage(
        cgImage: bitmap.image,
        size: fittedSize(source: source, requested: requested) ?? source)
    }
  }
}
