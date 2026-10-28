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

  @Test func episodeMenuPolicyRejectsFieldsSheetsAndInactiveWindows() {
    #expect(
      EpisodeKeyboardPolicy.permits(
        isKeyWindow: true, hasSheet: false, isTextEditing: false, isBlocked: false))
    #expect(
      !EpisodeKeyboardPolicy.permits(
        isKeyWindow: false, hasSheet: false, isTextEditing: false, isBlocked: false))
    #expect(
      !EpisodeKeyboardPolicy.permits(
        isKeyWindow: true, hasSheet: true, isTextEditing: false, isBlocked: false))
    #expect(
      !EpisodeKeyboardPolicy.permits(
        isKeyWindow: true, hasSheet: false, isTextEditing: true, isBlocked: false))
    #expect(
      !EpisodeKeyboardPolicy.permits(
        isKeyWindow: true, hasSheet: false, isTextEditing: false, isBlocked: true))
  }

  @Test func videoSurfaceEpisodeShortcutsLeaveModifiedKeysAlone() {
    #expect(SystemMediaCommand.episodeShortcut(characters: "n", modified: false) == .nextEpisode)
    #expect(
      SystemMediaCommand.episodeShortcut(characters: "P", modified: false) == .previousEpisode)
    #expect(SystemMediaCommand.episodeShortcut(characters: "n", modified: true) == nil)
    #expect(
      SystemMediaCommand.episodeShortcut(characters: "n", modified: false, isRepeat: true) == nil)
    #expect(SystemMediaCommand.episodeShortcut(characters: "p", modified: true) == nil)
    #expect(SystemMediaCommand.episodeShortcut(characters: nil, modified: false) == nil)
    #expect(SystemMediaCommand.episodeShortcut(characters: "m", modified: false) == nil)
  }

  @Test func previousAndNextCommandsFollowTheFirstMiddleAndLastEpisodeBoundaries() {
    let transport = FakeSystemMediaTransport()
    let coordinator = SystemMediaPlaybackCoordinator(transport: transport)
    let controller = FakeSystemMediaController(title: "Synthetic episode")
    coordinator.register(controller)
    defer { coordinator.unregister(controller) }
    for (previous, next) in [(false, true), (true, true), (true, false)] {
      controller.canPlayPrevious = previous
      controller.canPlayNext = next
      coordinator.update(controller)
      #expect(transport.enabled[.previousEpisode] == previous)
      #expect(transport.enabled[.nextEpisode] == next)
      #expect(transport.send(.previousEpisode) == (previous ? .success : .unavailable))
      #expect(transport.send(.nextEpisode) == (next ? .success : .unavailable))
    }
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

  @Test(arguments: [false, true])
  func pendingArtworkDoesNotRetainRetiredCoordinatorOrPublishAfterDeallocation(
    unregisterBeforeRelease: Bool
  ) async throws {
    let transport = FakeSystemMediaTransport()
    let provider = ControlledSystemMediaArtwork()
    var coordinator: SystemMediaPlaybackCoordinator? = SystemMediaPlaybackCoordinator(
      transport: transport)
    var controller: FakeSystemMediaController? = FakeSystemMediaController(
      title: "Temporary invented title")
    weak let weakCoordinator = coordinator
    weak let weakController = controller
    controller?.presentation = PlaybackPresentation(
      mediaId: UUID(), title: "Temporary invented title", subtitle: nil, artwork: inventedArtwork())
    coordinator?.register(try #require(controller), loadArtwork: provider.load)
    try await provider.waitForRequests(1)
    let handler = try #require(transport.handler(for: .play))
    let callback = SystemMediaCallbacks.remoteCommandHandler(handler)
    if unregisterBeforeRelease {
      coordinator?.unregister(try #require(controller))
      #expect(transport.info == nil && transport.artwork == nil)
      #expect(transport.handlers.isEmpty)
    }
    let publicationCount = transport.publicationCount
    coordinator = nil
    controller = nil
    #expect(weakCoordinator == nil)
    #expect(weakController == nil)

    let pixels = try #require(makeSystemMediaTestPixels())
    provider.complete(0, image: NSImage(cgImage: pixels, size: NSSize(width: 16, height: 24)))
    for _ in 0..<100 {
      if provider.cancelled[0] != nil { break }
      await Task.yield()
    }
    let retired = await invokeSystemMediaCommandOffMain(callback)
    #expect(retired.invokedOffMain)
    #expect(retired.result == Int(MPRemoteCommandHandlerStatus.noActionableNowPlayingItem.rawValue))
    #expect(provider.cancelled[0] == true)
    #expect(transport.publicationCount == publicationCount)
    #expect(transport.artwork == nil)
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

  @Test(arguments: [
    (12.0, 12.0, 8.0, 12.0),
    (64.0, 96.0, 16.0, 24.0),
  ])
  func productionArtworkRequestRunsOffMainWithFittedSizeAndImmutablePixels(
    dimensions: (Double, Double, Double, Double)
  ) async throws {
    let pixels = try #require(makeSystemMediaTestPixels())
    let source = NSImage(cgImage: pixels, size: NSSize(width: 16, height: 24))
    let artwork = try #require(SystemMediaArtwork.mediaItem(source))
    let captured = BackgroundSystemMediaArtwork(artwork)
    let observation = await requestSystemMediaArtworkOffMain(
      captured, width: dimensions.0, height: dimensions.1)

    #expect(observation.invokedOffMain)
    #expect(observation.returnedOffMain)
    #expect(observation.width == dimensions.2)
    #expect(observation.height == dimensions.3)
    // The display size changes, while the bounded source bitmap remains intact.
    #expect(observation.pixelWidth == 16)
    #expect(observation.pixelHeight == 24)
    #expect(observation.samples == [255, 0, 0, 255, 0, 0, 255, 255])
  }

  @Test func nativeRemoteCommandAdapterRunsItsHandlerOffMainAndMapsBothResults() async {
    for result in [SystemMediaCommandResult.success, .unavailable] {
      let probe = BackgroundSystemMediaCommandProbe()
      let callback = SystemMediaCallbacks.remoteCommandHandler { @Sendable in
        probe.record(offMain: !Thread.isMainThread)
        return result
      }
      let observation = await invokeSystemMediaCommandOffMain(callback)
      let expected: MPRemoteCommandHandlerStatus =
        result == .success ? .success : .noActionableNowPlayingItem
      #expect(observation.invokedOffMain)
      #expect(observation.result == Int(expected.rawValue))
      #expect(probe.offMainCalls == [true])
    }
  }

  @Test func nativeRemoteCommandAdapterHopsToMainAndRejectsARetiredRegistration() async throws {
    let transport = FakeSystemMediaTransport()
    let coordinator = SystemMediaPlaybackCoordinator(transport: transport)
    let first = FakeSystemMediaController(title: "First invented title")
    let second = FakeSystemMediaController(title: "Second invented title")
    coordinator.register(first)
    let handler = try #require(transport.handler(for: .play))
    let callback = SystemMediaCallbacks.remoteCommandHandler(handler)
    let accepted = await invokeSystemMediaCommandOffMain(callback)
    #expect(accepted.invokedOffMain)
    #expect(accepted.result == Int(MPRemoteCommandHandlerStatus.success.rawValue))
    for _ in 0..<100 {
      if !first.commands.isEmpty { break }
      await Task.yield()
    }
    #expect(first.commands == [.play])
    #expect(first.playThreadsWereMain == [true])

    coordinator.register(second)
    defer { coordinator.unregister(second) }
    let retired = await invokeSystemMediaCommandOffMain(callback)
    #expect(retired.invokedOffMain)
    #expect(retired.result == Int(MPRemoteCommandHandlerStatus.noActionableNowPlayingItem.rawValue))
    for _ in 0..<8 { await Task.yield() }
    #expect(second.commands.isEmpty)
    #expect(second.playThreadsWereMain.isEmpty)
  }

  @Test func nativeArtworkWithoutPixelsDoesNotCreateMediaItem() {
    #expect(SystemMediaArtwork.mediaItem(NSImage()) == nil)
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
  var publicationCount = 0

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
    publicationCount += 1
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
  var canPlayPrevious = false
  var seeks: [Int64] = []
  var commands: [SystemMediaCommand] = []
  var playThreadsWereMain: [Bool] = []

  init(title: String) {
    presentation = PlaybackPresentation(mediaId: UUID(), title: title, subtitle: nil)
  }

  func seek(to milliseconds: Int64) {
    guard canSeek else { return }
    seeks.append(milliseconds)
    currentTimeMilliseconds = milliseconds
  }

  func playPreviousFromSystemMedia() -> Bool {
    guard canPlayPrevious else { return false }
    commands.append(.previousEpisode)
    canPlayPrevious = false
    return true
  }

  func playNextFromSystemMedia() -> Bool {
    guard canPlayNext else { return false }
    commands.append(.nextEpisode)
    canPlayNext = false
    return true
  }

  func play() -> Bool {
    guard canPlay else { return false }
    playThreadsWereMain.append(Thread.isMainThread)
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

// These observations cross the queue boundary; NSImage never does. The artwork wrapper is
// immutable after the production factory captures its immutable, generated CGImage pixels.
private struct BackgroundSystemMediaArtworkObservation: Sendable {
  let invokedOffMain: Bool
  let returnedOffMain: Bool
  let width: Double
  let height: Double
  let pixelWidth: Int
  let pixelHeight: Int
  let samples: [UInt8]
}

private final class BackgroundSystemMediaArtwork: @unchecked Sendable {
  let value: MPMediaItemArtwork

  init(_ value: MPMediaItemArtwork) {
    self.value = value
  }
}

private func makeSystemMediaTestPixels() -> CGImage? {
  let width = 16
  let height = 24
  let bytes: [UInt8] = (0..<height).flatMap { _ in
    (0..<width).flatMap { x -> [UInt8] in
      x < width / 2 ? [255, 0, 0, 255] : [0, 0, 255, 255]
    }
  }
  guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
  return CGImage(
    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
      CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

private func requestSystemMediaArtworkOffMain(
  _ artwork: BackgroundSystemMediaArtwork, width: Double, height: Double
) async -> BackgroundSystemMediaArtworkObservation {
  await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async { @Sendable in
      let invokedOffMain = !Thread.isMainThread
      guard let image = artwork.value.image(at: NSSize(width: width, height: height)),
        let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
      else {
        continuation.resume(
          returning: BackgroundSystemMediaArtworkObservation(
            invokedOffMain: invokedOffMain, returnedOffMain: !Thread.isMainThread,
            width: 0, height: 0, pixelWidth: 0, pixelHeight: 0, samples: []))
        return
      }
      // Inspect only the newly returned CGImage-backed image on this same background queue.
      // Rendering its immutable pixels does not use a window, player or Now Playing session.
      var bytes = [UInt8](repeating: 0, count: pixels.width * pixels.height * 4)
      let samples = bytes.withUnsafeMutableBytes { buffer -> [UInt8] in
        guard
          let context = CGContext(
            data: buffer.baseAddress, width: pixels.width, height: pixels.height,
            bitsPerComponent: 8, bytesPerRow: pixels.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
              | CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        context.interpolationQuality = .none
        context.draw(
          pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        let rgba = buffer.bindMemory(to: UInt8.self)
        let left = ((pixels.height / 2) * pixels.width + pixels.width / 4) * 4
        let right = ((pixels.height / 2) * pixels.width + 3 * pixels.width / 4) * 4
        return Array(rgba[left..<(left + 4)]) + Array(rgba[right..<(right + 4)])
      }
      continuation.resume(
        returning: BackgroundSystemMediaArtworkObservation(
          invokedOffMain: invokedOffMain, returnedOffMain: !Thread.isMainThread,
          width: Double(image.size.width), height: Double(image.size.height),
          pixelWidth: pixels.width, pixelHeight: pixels.height, samples: samples))
    }
  }
}

private struct BackgroundSystemMediaCommandObservation: Sendable {
  let invokedOffMain: Bool
  let result: Int
}

private final class BackgroundSystemMediaCommandProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [Bool] = []

  var offMainCalls: [Bool] { lock.withLock { calls } }

  func record(offMain: Bool) {
    lock.withLock { calls.append(offMain) }
  }
}

private func invokeSystemMediaCommandOffMain(
  _ callback: @escaping @Sendable (MPRemoteCommandEvent?) -> MPRemoteCommandHandlerStatus
) async -> BackgroundSystemMediaCommandObservation {
  await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async { @Sendable in
      let offMain = !Thread.isMainThread
      let result = callback(nil)
      continuation.resume(
        returning: BackgroundSystemMediaCommandObservation(
          invokedOffMain: offMain, result: Int(result.rawValue)))
    }
  }
}
