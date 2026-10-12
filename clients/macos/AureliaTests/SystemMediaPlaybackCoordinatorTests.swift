import Combine
import Foundation
@preconcurrency import MediaPlayer
import Testing

@testable import Aurelia

@MainActor
struct SystemMediaPlaybackCoordinatorTests {
  @Test
  func nativeNowPlayingDictionaryDescribesVideoWithoutClaimingTheSystemSession() {
    let info = SystemMediaNowPlayingInfo(
      title: "Episode", subtitle: "Synthetic Series", elapsedSeconds: 12.5,
      durationSeconds: 90, playbackRate: 0, defaultPlaybackRate: 1.5, state: .paused)
    let values = info.nowPlayingValues
    #expect(values[MPMediaItemPropertyTitle] as? String == "Episode")
    #expect(values[MPMediaItemPropertyAlbumTitle] as? String == "Synthetic Series")
    #expect(values[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 12.5)
    #expect(values[MPMediaItemPropertyPlaybackDuration] as? Double == 90)
    #expect(values[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
    #expect(values[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1.5)
    #expect(
      values[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.video.rawValue
    )
  }

  @Test
  func registrationIsIdempotentAndReplacementRemovesOnlyOwnedTargets() {
    let transport = FakeSystemMediaTransport()
    let coordinator = SystemMediaPlaybackCoordinator(transport: transport)
    let first = FakeSystemMediaController(title: "First")
    let second = FakeSystemMediaController(title: "Second")
    let unrelated = transport.addHandler(for: .play) { .success }

    coordinator.register(first)
    let firstTokens = Set(transport.handlers.keys).subtracting([unrelated])
    coordinator.register(first)
    #expect(transport.handlers.count == 5)
    #expect(transport.removedTokens.isEmpty)
    let retiredHandler = transport.handler(for: .toggle)

    coordinator.register(second)
    #expect(Set(transport.removedTokens) == firstTokens)
    #expect(transport.handlers.count == 5)
    #expect(transport.handlers[unrelated] != nil)
    #expect(transport.info?.title == "Second")
    #expect(retiredHandler?() == .unavailable)
    #expect(first.commands.isEmpty && second.commands.isEmpty)

    coordinator.unregister(first)
    #expect(transport.handlers.count == 5)
    #expect(transport.info?.title == "Second")
    coordinator.unregister(second)
    #expect(transport.handlers.count == 1)
    #expect(transport.handlers[unrelated] != nil)
    #expect(transport.info == nil)
    #expect(SystemMediaCommand.allCases.allSatisfy { transport.enabled[$0] == false })
  }

  @Test
  func nativePlayPauseToggleAndStopRetainTheCurrentPosition() {
    let transport = FakeSystemMediaTransport()
    let coordinator = SystemMediaPlaybackCoordinator(transport: transport)
    let controller = FakeSystemMediaController(title: "Movie")
    controller.currentTimeMilliseconds = 37_000
    coordinator.register(controller)
    defer { coordinator.unregister(controller) }

    #expect(transport.send(.play) == .success)
    #expect(controller.isPlaying)
    #expect(transport.send(.play) == .success)
    #expect(controller.isPlaying)
    #expect(transport.send(.pause) == .success)
    #expect(!controller.isPlaying)
    #expect(transport.send(.pause) == .success)
    #expect(!controller.isPlaying)
    #expect(transport.send(.toggle) == .success)
    #expect(controller.isPlaying)
    #expect(transport.send(.stop) == .success)
    #expect(!controller.isPlaying)
    #expect(controller.currentTimeMilliseconds == 37_000)
    #expect(controller.commands == [.play, .play, .pause, .pause, .toggle, .pause])
    #expect(transport.info?.elapsedSeconds == 37)
    #expect(transport.info?.playbackRate == 0)
    #expect(transport.info?.state == .paused)
  }

  @Test
  func publishedChangesUpdateMetadataAndActualPlaybackState() async {
    let transport = FakeSystemMediaTransport()
    let coordinator = SystemMediaPlaybackCoordinator(transport: transport)
    let controller = FakeSystemMediaController(title: "Episode 1")
    coordinator.register(controller)
    defer { coordinator.unregister(controller) }
    #expect(transport.info?.state == .paused)

    controller.objectWillChange.send()
    controller.presentation = PlaybackPresentation(
      mediaId: UUID(), title: "Episode 2", subtitle: "Synthetic Series · S01 E02")
    controller.currentTimeMilliseconds = 12_500
    controller.durationMilliseconds = 90_000
    controller.playbackRate = 1.5
    controller.isPlaying = true
    for _ in 0..<8 { await Task.yield() }
    #expect(transport.info?.title == "Episode 2")
    #expect(transport.info?.subtitle == "Synthetic Series · S01 E02")
    #expect(transport.info?.elapsedSeconds == 12.5)
    #expect(transport.info?.durationSeconds == 90)
    #expect(transport.info?.playbackRate == 1.5)
    #expect(transport.info?.defaultPlaybackRate == 1.5)
    #expect(transport.info?.state == .playing)

    controller.objectWillChange.send()
    controller.isPlaying = false
    for _ in 0..<8 { await Task.yield() }
    #expect(transport.info?.playbackRate == 0)
    #expect(transport.info?.defaultPlaybackRate == 1.5)
    #expect(transport.info?.state == .paused)
  }

  @Test
  func unavailableControllerRejectsCommandsWithoutChangingPosition() {
    let transport = FakeSystemMediaTransport()
    let coordinator = SystemMediaPlaybackCoordinator(transport: transport)
    let controller = FakeSystemMediaController(title: "Preparing or failed")
    controller.canPlay = false
    controller.canPause = false
    controller.currentTimeMilliseconds = 45_000
    coordinator.register(controller)
    defer { coordinator.unregister(controller) }
    for command in SystemMediaCommand.allCases {
      #expect(transport.enabled[command] == false)
      #expect(transport.send(command) == .unavailable)
    }
    #expect(controller.commands.isEmpty)
    #expect(controller.currentTimeMilliseconds == 45_000)
    #expect(transport.info?.state == .stopped)
  }

  @Test
  func backgroundCommandRunsOnMainActorAndRetiredCallbackCannotControlReplacement() async throws {
    let transport = FakeSystemMediaTransport()
    let coordinator = SystemMediaPlaybackCoordinator(transport: transport)
    let first = FakeSystemMediaController(title: "First")
    let second = FakeSystemMediaController(title: "Second")
    coordinator.register(first)
    let backgroundHandler = try #require(transport.handler(for: .play))
    let accepted = await Task.detached { backgroundHandler() }.value
    #expect(accepted == .success)
    for _ in 0..<8 { await Task.yield() }
    #expect(first.commands == [.play])
    #expect(first.isPlaying)

    coordinator.register(second)
    defer { coordinator.unregister(second) }
    let retiredResult = await Task.detached { backgroundHandler() }.value
    #expect(retiredResult == .unavailable)
    for _ in 0..<8 { await Task.yield() }
    #expect(second.commands.isEmpty)
  }

  @Test
  func registrationDoesNotRetainControllerAndLateCommandIsUnavailable() async throws {
    let transport = FakeSystemMediaTransport()
    let coordinator = SystemMediaPlaybackCoordinator(transport: transport)
    var controller: FakeSystemMediaController? = FakeSystemMediaController(title: "Temporary")
    weak let weakController = controller
    coordinator.register(try #require(controller))
    let handler = try #require(transport.handler(for: .toggle))
    controller = nil
    #expect(weakController == nil)
    #expect(handler() == .unavailable)
    let backgroundResult = await Task.detached { handler() }.value
    #expect(backgroundResult == .unavailable)
  }
}

@MainActor
private final class FakeSystemMediaTransport: SystemMediaPlaybackTransport {
  struct Handler {
    let command: SystemMediaCommand
    let invoke: @Sendable () -> SystemMediaCommandResult
  }

  var handlers: [UUID: Handler] = [:]
  var removedTokens: [UUID] = []
  var enabled: [SystemMediaCommand: Bool] = [:]
  var info: SystemMediaNowPlayingInfo?

  func addHandler(
    for command: SystemMediaCommand,
    handler: @escaping @Sendable () -> SystemMediaCommandResult
  ) -> UUID {
    let token = UUID()
    handlers[token] = Handler(command: command, invoke: handler)
    return token
  }

  func removeHandler(_ token: UUID) {
    removedTokens.append(token)
    handlers.removeValue(forKey: token)
  }

  func setEnabled(_ enabled: Bool, for command: SystemMediaCommand) {
    self.enabled[command] = enabled
  }

  func publish(_ info: SystemMediaNowPlayingInfo?) { self.info = info }

  func handler(for command: SystemMediaCommand) -> (@Sendable () -> SystemMediaCommandResult)? {
    handlers.values.first { $0.command == command }?.invoke
  }

  func send(_ command: SystemMediaCommand) -> SystemMediaCommandResult {
    handler(for: command)?() ?? .unavailable
  }
}

@MainActor
private final class FakeSystemMediaController: SystemMediaPlaybackControlling {
  let objectWillChange = ObservableObjectPublisher()
  var presentation: PlaybackPresentation
  var isPlaying = false
  var currentTimeMilliseconds: Int64 = 0
  var durationMilliseconds: Int64 = 120_000
  var playbackRate: Double = 1
  var canPlay = true
  var canPause = true
  var commands: [SystemMediaCommand] = []

  init(title: String) {
    presentation = PlaybackPresentation(mediaId: UUID(), title: title, subtitle: nil)
  }

  func play() -> Bool {
    guard canPlay else { return false }
    commands.append(.play)
    isPlaying = true
    return true
  }

  func pause() -> Bool {
    guard canPause else { return false }
    commands.append(.pause)
    isPlaying = false
    return true
  }

  func togglePlayback() -> Bool {
    guard isPlaying ? canPause : canPlay else { return false }
    commands.append(.toggle)
    isPlaying.toggle()
    return true
  }
}
