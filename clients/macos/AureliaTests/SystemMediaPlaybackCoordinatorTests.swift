import AppKit
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
    #expect(transport.handlers.count == SystemMediaCommand.allCases.count + 1)
    #expect(transport.removedTokens.isEmpty)
    let retiredHandler = transport.handler(for: .toggle)

    coordinator.register(second)
    #expect(Set(transport.removedTokens) == firstTokens)
    #expect(transport.handlers.count == SystemMediaCommand.allCases.count + 1)
    #expect(transport.handlers[unrelated] != nil)
    #expect(transport.info?.title == "Second")
    #expect(retiredHandler?() == .unavailable)
    #expect(first.commands.isEmpty && second.commands.isEmpty)

    coordinator.unregister(first)
    #expect(transport.handlers.count == SystemMediaCommand.allCases.count + 1)
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
    #expect(transport.info == nil)
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
  @Test func tenSecondCommandsClampToBoundsAndRejectNonseekableInputs() {
    let transport = FakeSystemMediaTransport()
    let coordinator = SystemMediaPlaybackCoordinator(transport: transport)
    let controller = FakeSystemMediaController(title: "Synthetic Movie")
    controller.currentTimeMilliseconds = 5_000
    controller.durationMilliseconds = 22_000
    coordinator.register(controller)
    defer { coordinator.unregister(controller) }
    #expect(transport.send(.skipBackward) == .success)
    #expect(controller.currentTimeMilliseconds == 0)
    #expect(transport.send(.skipForward) == .success)
    #expect(controller.currentTimeMilliseconds == 10_000)
    controller.currentTimeMilliseconds = 20_000
    #expect(transport.send(.skipForward) == .success)
    #expect(controller.currentTimeMilliseconds == 22_000)
    controller.canSeek = false
    // Eligibility is checked at execution even before a published-state update.
    #expect(transport.send(.skipBackward) == .unavailable)
    coordinator.update(controller)
    #expect(transport.enabled[.skipForward] == false)
    #expect(transport.enabled[.skipBackward] == false)
    #expect(controller.seeks == [0, 10_000, 22_000])
    controller.canSeek = true
    controller.durationMilliseconds = 0
    #expect(transport.send(.skipForward) == .unavailable)
    #expect(controller.seeks.count == 3)
  }

  @Test func skipMappingAvoidsIntegerOverflowAndInvalidDuration() {
    #expect(
      SystemMediaPlaybackCoordinator.skipTarget(position: -1, duration: 100_000, forward: false)
        == 0)
    #expect(
      SystemMediaPlaybackCoordinator.skipTarget(
        position: Int64.max, duration: Int64.max, forward: true) == Int64.max)
    #expect(
      SystemMediaPlaybackCoordinator.skipTarget(
        position: Int64.max - 5, duration: Int64.max, forward: true) == Int64.max)
    #expect(
      SystemMediaPlaybackCoordinator.skipTarget(
        position: Int64.min, duration: 100_000, forward: true) == 10_000)
    #expect(
      SystemMediaPlaybackCoordinator.skipTarget(position: 100_000, duration: 20_000, forward: false)
        == 10_000)
    #expect(
      SystemMediaPlaybackCoordinator.skipTarget(position: 0, duration: 0, forward: true) == nil)
    #expect(
      SystemMediaPlaybackCoordinator.skipTarget(position: 0, duration: -1, forward: false) == nil)
  }

  @Test func nextEpisodeIsAvailableOnlyWithAnEligibleQueueAndRetiredCommandsCannotSeek() throws {
    let transport = FakeSystemMediaTransport()
    let coordinator = SystemMediaPlaybackCoordinator(transport: transport)
    let first = FakeSystemMediaController(title: "Episode 1")
    coordinator.register(first)
    #expect(transport.enabled[.nextEpisode] == false)
    #expect(transport.send(.nextEpisode) == .unavailable)
    first.canPlayNext = true
    coordinator.update(first)
    #expect(transport.enabled[.nextEpisode] == true)
    #expect(transport.send(.nextEpisode) == .success)
    #expect(transport.send(.nextEpisode) == .unavailable)
    #expect(first.commands == [.nextEpisode])
    let retiredSkip = try #require(transport.handler(for: .skipForward))
    let retiredNext = try #require(transport.handler(for: .nextEpisode))
    let second = FakeSystemMediaController(title: "Another Title")
    second.canPlayNext = true
    coordinator.register(second)
    defer { coordinator.unregister(second) }
    #expect(retiredSkip() == .unavailable)
    #expect(retiredNext() == .unavailable)
    #expect(first.seeks.isEmpty && second.seeks.isEmpty && second.commands.isEmpty)
  }

  @Test func artworkFollowsCatalogAndPlannedQueueItemsWithoutAdditionalCatalogReads() throws {
    let first = catalogItem(title: "Episode 1", artwork: inventedArtwork())
    let next = catalogItem(title: "Episode 2", artwork: inventedArtwork())
    let direct = try #require(CatalogPlaybackLogic.presentation(for: first))
    #expect(direct.artwork == first.poster)
    let plan = PlaybackPlanResponse(
      target: first, seriesId: UUID(), queue: [next], action: .play,
      continueWatchingEligible: true)
    let planned = try #require(plan.presentation)
    #expect(planned.artwork == first.poster)
    #expect(planned.queue.first?.artwork == next.poster)
    #expect(planned.subtitle == "Synthetic Series · Season 1 · Episode 1")
  }

  @Test func staleArtworkCompletionCannotReplaceNewTitleOrRepeatForEveryPositionUpdate()
    async throws
  {
    let transport = FakeSystemMediaTransport()
    let coordinator = SystemMediaPlaybackCoordinator(transport: transport)
    let provider = ControlledSystemMediaArtwork()
    let controller = FakeSystemMediaController(title: "Episode 1")
    let firstArtwork = inventedArtwork()
    controller.presentation = PlaybackPresentation(
      mediaId: UUID(), title: "Episode 1", subtitle: nil, artwork: firstArtwork)
    coordinator.register(controller, loadArtwork: provider.load)
    defer { coordinator.unregister(controller) }
    try await provider.waitForRequests(1)
    let secondArtwork = inventedArtwork()
    controller.presentation = PlaybackPresentation(
      mediaId: UUID(), title: "Episode 2", subtitle: nil, artwork: secondArtwork)
    coordinator.update(controller)
    try await provider.waitForRequests(2)
    let stale = NSImage(size: NSSize(width: 16, height: 24))
    provider.complete(0, image: stale)
    for _ in 0..<8 { await Task.yield() }
    #expect(transport.artwork == nil)
    #expect(transport.info?.title == "Episode 2")
    let current = NSImage(size: NSSize(width: 32, height: 48))
    provider.complete(1, image: current)
    for _ in 0..<8 { await Task.yield() }
    #expect(transport.artwork === current)
    #expect(provider.cancelled[0] == true)
    for position in 0..<10 {
      controller.currentTimeMilliseconds = Int64(position * 1_000)
      coordinator.update(controller)
    }
    #expect(provider.requests == [firstArtwork, secondArtwork])
  }

  @Test func stoppedOrUnregisteredPlaybackClearsArtworkAndIgnoresLateCompletion() async throws {
    let transport = FakeSystemMediaTransport()
    let coordinator = SystemMediaPlaybackCoordinator(transport: transport)
    let provider = ControlledSystemMediaArtwork()
    let controller = FakeSystemMediaController(title: "Synthetic Movie")
    controller.presentation = PlaybackPresentation(
      mediaId: UUID(), title: "Synthetic Movie", subtitle: nil, artwork: inventedArtwork())
    coordinator.register(controller, loadArtwork: provider.load)
    try await provider.waitForRequests(1)
    controller.canPlay = false
    controller.canPause = false
    coordinator.update(controller)
    #expect(transport.info == nil && transport.artwork == nil)
    provider.complete(0, image: NSImage(size: NSSize(width: 16, height: 24)))
    for _ in 0..<8 { await Task.yield() }
    #expect(transport.info == nil && transport.artwork == nil)
    controller.canPlay = true
    controller.canPause = true
    coordinator.update(controller)
    try await provider.waitForRequests(2)
    coordinator.unregister(controller)
    provider.complete(1, image: NSImage(size: NSSize(width: 16, height: 24)))
    for _ in 0..<8 { await Task.yield() }
    #expect(transport.info == nil && transport.artwork == nil)
    #expect(transport.handlers.isEmpty)
  }

  @Test func failedArtworkKeepsMetadataAndDoesNotRetryEachUpdate() async {
    let transport = FakeSystemMediaTransport()
    let coordinator = SystemMediaPlaybackCoordinator(transport: transport)
    let controller = FakeSystemMediaController(title: "Synthetic Movie")
    controller.presentation = PlaybackPresentation(
      mediaId: UUID(), title: "Synthetic Movie", subtitle: nil, artwork: inventedArtwork())
    var requests = 0
    coordinator.register(controller) { _ in
      requests += 1
      throw CocoaError(.fileReadCorruptFile)
    }
    defer { coordinator.unregister(controller) }
    for _ in 0..<8 { await Task.yield() }
    for _ in 0..<10 { coordinator.update(controller) }
    #expect(requests == 1)
    #expect(transport.info?.title == "Synthetic Movie")
    #expect(transport.artwork == nil)
  }

  @Test func nativeArtworkSizesPreserveAspectRatioAndRejectInvalidRequests() {
    let source = NSSize(width: 640, height: 960)
    #expect(
      SystemMediaArtwork.fittedSize(source: source, requested: NSSize(width: 96, height: 96))
        == NSSize(width: 64, height: 96))
    #expect(
      SystemMediaArtwork.fittedSize(source: source, requested: NSSize(width: 1280, height: 1920))
        == source)
    for size in [
      NSSize.zero, NSSize(width: -1, height: 1), NSSize(width: CGFloat.infinity, height: 1),
      NSSize(width: 1, height: CGFloat.nan),
    ] {
      #expect(SystemMediaArtwork.fittedSize(source: source, requested: size) == nil)
      #expect(SystemMediaArtwork.fittedSize(source: size, requested: source) == nil)
    }
  }

  private func inventedArtwork() -> ArtworkSummary {
    let id = UUID()
    return ArtworkSummary(
      id: id, kind: .poster, path: "/api/v1/artwork/\(id)", contentType: "image/png",
      contentLength: 64, revision: 1)
  }

  private func catalogItem(title: String, artwork: ArtworkSummary) -> CatalogItemSummary {
    CatalogItemSummary(
      id: UUID(), kind: .episode, title: title, originalTitle: nil, year: nil,
      overview: nil, genres: [], poster: artwork, backdrop: nil, availability: .available,
      isFavorite: false, progress: nil, addedAt: "2026-10-27T00:00:00Z",
      parentTitle: "Synthetic Series", seasonNumber: 1, episodeNumber: 1)
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
  var artwork: NSImage?

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

  func publish(_ info: SystemMediaNowPlayingInfo?, artwork: NSImage?) {
    self.info = info
    self.artwork = artwork
  }

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
  var canSeek = true
  var canPlayNext = false
  var seeks: [Int64] = []
  var commands: [SystemMediaCommand] = []

  init(title: String) {
    presentation = PlaybackPresentation(mediaId: UUID(), title: title, subtitle: nil)
  }

  func seek(to milliseconds: Int64) {
    guard canSeek else { return }
    seeks.append(milliseconds)
    currentTimeMilliseconds = milliseconds
  }

  func playNextFromSystemMedia() -> Bool {
    guard canPlayNext else { return false }
    commands.append(.nextEpisode)
    canPlayNext = false
    return true
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

@MainActor
private final class ControlledSystemMediaArtwork {
  var requests: [ArtworkSummary] = []
  var cancelled: [Int: Bool] = [:]
  private var pending: [Int: CheckedContinuation<NSImage, Error>] = [:]

  func load(_ artwork: ArtworkSummary) async throws -> NSImage {
    let index = requests.count
    requests.append(artwork)
    let image = try await withCheckedThrowingContinuation { continuation in
      pending[index] = continuation
    }
    cancelled[index] = Task.isCancelled
    return image
  }

  func complete(_ index: Int, image: NSImage) {
    pending.removeValue(forKey: index)?.resume(returning: image)
  }

  func waitForRequests(_ count: Int) async throws {
    for _ in 0..<1_000 {
      if requests.count >= count { return }
      await Task.yield()
    }
    Issue.record("The invented artwork provider did not receive its request.")
    throw CancellationError()
  }
}
