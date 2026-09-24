import AppKit
import Foundation

@MainActor
protocol PlaybackClientProtocol: AnyObject {
  var profile: StoredServerProfile { get }
  func createPlayback(mediaId: UUID) async throws -> PlaybackSourceResponse
  func updatePlaybackProgress(
    mediaId: UUID,
    positionMilliseconds: Int64,
    durationMilliseconds: Int64,
    isFinished: Bool
  ) async throws -> PlaybackProgressResponse
  func revokePlayback(id: UUID) async throws
  func streamURL(path: String) throws -> URL
}

@MainActor
final class APIPlaybackClient: PlaybackClientProtocol {
  let api: APIClient
  var profile: StoredServerProfile { api.profile }

  init(profile: StoredServerProfile) {
    api = APIClient(profile: profile)
  }

  func createPlayback(mediaId: UUID) async throws -> PlaybackSourceResponse {
    try await api.createPlayback(mediaId: mediaId)
  }

  func updatePlaybackProgress(
    mediaId: UUID,
    positionMilliseconds: Int64,
    durationMilliseconds: Int64,
    isFinished: Bool
  ) async throws -> PlaybackProgressResponse {
    try await api.updatePlaybackProgress(
      mediaId: mediaId,
      positionMilliseconds: positionMilliseconds,
      durationMilliseconds: durationMilliseconds,
      isFinished: isFinished)
  }

  func revokePlayback(id: UUID) async throws {
    try await api.revokePlayback(id: id)
  }

  func streamURL(path: String) throws -> URL {
    try api.streamURL(path: path)
  }
}

@MainActor
protocol PlaybackRelayProtocol: AnyObject {
  func start() async throws -> URL
  func updateSourceURL(_ url: URL)
  func stop()
}

extension LoopbackStreamRelay: PlaybackRelayProtocol {}

enum PlaybackSleepTimer: Equatable, Sendable {
  case off
  case endOfEpisode
  case minutes(Int)

  var title: String {
    switch self {
    case .off: "Off"
    case .endOfEpisode: "End of episode"
    case .minutes(let value): "\(value) minutes"
    }
  }
}

@MainActor
final class PlaybackController: ObservableObject {
  @Published private(set) var isPreparing = true
  @Published private(set) var isPlaying = false
  @Published private(set) var currentTimeMilliseconds: Int64 = 0
  @Published private(set) var durationMilliseconds: Int64 = 0
  @Published private(set) var audioTracks: [PlaybackTrack] = []
  @Published private(set) var subtitleTracks: [PlaybackTrack] = []
  @Published private(set) var selectedAudioTrackID: Int32?
  @Published private(set) var selectedSubtitleTrackID: Int32?
  @Published private(set) var playbackRate: Double
  @Published private(set) var chapters: [PlaybackChapter] = []
  @Published private(set) var currentChapterIndex: Int32?
  @Published private(set) var sleepTimer: PlaybackSleepTimer = .off
  @Published var volume: Double = 1
  @Published var isMuted = false
  @Published var errorMessage: String?

  @Published private(set) var presentation: PlaybackPresentation

  private let client: any PlaybackClientProtocol
  private let engine: PlaybackEngine
  private let preferences: PlaybackPreferences
  private let relayFactory: (URL, String) throws -> any PlaybackRelayProtocol
  private var relay: (any PlaybackRelayProtocol)?
  private var activePlayback: PlaybackSourceResponse?
  private var playbackIDs: Set<UUID> = []
  private var renewalTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?
  private var started = false
  private var stopped = false
  private var appliedResumePosition = false
  private var resumePositionMilliseconds: Int64 = 0
  private var lastPeriodicSave = Date.distantPast
  private var queuedItems: [PlaybackQueueItem]
  private var sleepTask: Task<Void, Never>?
  private var nextItemTask: Task<Void, Never>?
  private var activityToken: NSObjectProtocol?

  init(
    profile: StoredServerProfile,
    presentation: PlaybackPresentation,
    engine: PlaybackEngine = VLCPlaybackEngine(),
    preferences: PlaybackPreferences = PlaybackPreferencesStore.shared.preferences
  ) {
    self.client = APIPlaybackClient(profile: profile)
    self.presentation = presentation
    self.engine = engine
    self.preferences = preferences.normalized
    self.playbackRate = preferences.normalized.defaultPlaybackRate
    self.volume = preferences.normalized.defaultVolume
    self.queuedItems = presentation.queue
    self.relayFactory = { url, fingerprint in
      try LoopbackStreamRelay(
        sourceURL: url,
        publicKeyFingerprint: fingerprint,
        authorizationToken: profile.token)
    }
    connectEngineCallbacks()
  }

  init(
    client: any PlaybackClientProtocol,
    presentation: PlaybackPresentation,
    engine: PlaybackEngine,
    preferences: PlaybackPreferences = .defaultValue,
    relayFactory: @escaping (URL, String) throws -> any PlaybackRelayProtocol
  ) {
    self.client = client
    self.presentation = presentation
    self.engine = engine
    self.preferences = preferences.normalized
    self.playbackRate = preferences.normalized.defaultPlaybackRate
    self.volume = preferences.normalized.defaultVolume
    self.queuedItems = presentation.queue
    self.relayFactory = relayFactory
    connectEngineCallbacks()
  }

  private func connectEngineCallbacks() {
    engine.onUpdate = { [weak self] in self?.engineUpdated() }
    engine.onEnded = { [weak self] in self?.engineEnded() }
    engine.onError = { [weak self] message in self?.engineFailed(message) }
  }

  func attachVideoView(_ view: NSView) {
    engine.attach(to: view)
  }

  func start() async {
    guard !started else { return }
    started = true
    stopped = false
    isPreparing = true
    errorMessage = nil

    do {
      let source = try await client.createPlayback(mediaId: presentation.mediaId)
      guard !stopped, !Task.isCancelled else {
        try? await client.revokePlayback(id: source.id)
        return
      }
      try await begin(source)
    } catch {
      guard !stopped, !Task.isCancelled else { return }
      isPreparing = false
      errorMessage = error.localizedDescription
    }
  }

  func retry() async {
    await shutdown(saveProgress: false)
    started = false
    stopped = false
    await start()
  }

  func togglePlayback() {
    if engine.isPlaying {
      engine.pause()
      enqueueProgressSave(isFinished: false)
    } else {
      engine.play()
    }
    engineUpdated()
  }

  func skip(seconds: Int64) {
    seek(to: currentTimeMilliseconds + seconds * 1_000)
  }

  func setPlaybackRate(_ value: Double) {
    guard PlaybackPreferences.supportedRates.contains(value) else { return }
    playbackRate = value
    engine.playbackRate = value
  }

  func seek(to milliseconds: Int64) {
    let upper = durationMilliseconds > 0 ? durationMilliseconds : Int64.max
    let target = min(max(milliseconds, 0), upper)
    engine.seek(to: target)
    currentTimeMilliseconds = target
    enqueueProgressSave(isFinished: false)
  }

  func setVolume(_ value: Double) {
    volume = min(max(value, 0), 1)
    engine.volume = volume
    if volume > 0 { isMuted = false }
  }

  func toggleMute() {
    isMuted.toggle()
    engine.isMuted = isMuted
  }

  func selectAudioTrack(_ id: Int32) {
    engine.selectAudioTrack(id: id)
    engineUpdated()
  }

  func selectSubtitleTrack(_ id: Int32?) {
    engine.selectSubtitleTrack(id: id)
    engineUpdated()
  }

  func selectChapter(_ chapter: PlaybackChapter) {
    engine.selectChapter(index: chapter.index)
    currentTimeMilliseconds = chapter.timeOffsetMilliseconds
  }

  func setSleepTimer(_ timer: PlaybackSleepTimer) {
    sleepTask?.cancel()
    sleepTask = nil
    sleepTimer = timer
    guard case .minutes(let minutes) = timer else { return }
    if minutes <= 0 {
      if engine.isPlaying { engine.pause() }
      engineUpdated()
      sleepTimer = .off
      enqueueProgressSave(isFinished: false)
      return
    }
    sleepTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(minutes * 60))
      } catch {
        return
      }
      guard !Task.isCancelled, let self else { return }
      if self.engine.isPlaying { self.engine.pause() }
      self.engineUpdated()
      self.sleepTimer = .off
      self.enqueueProgressSave(isFinished: false)
    }
  }

  func shutdown(saveProgress: Bool = true) async {
    guard !stopped else { return }
    stopped = true
    renewalTask?.cancel()
    renewalTask = nil
    sleepTask?.cancel()
    sleepTask = nil
    nextItemTask?.cancel()
    nextItemTask = nil
    endPlaybackActivity()

    if saveProgress {
      enqueueProgressSave(isFinished: false)
      await saveTask?.value
    }

    engine.stop()
    relay?.stop()
    relay = nil
    for id in playbackIDs {
      try? await client.revokePlayback(id: id)
    }
    playbackIDs.removeAll()
    activePlayback = nil
  }

  private func begin(_ source: PlaybackSourceResponse) async throws {
    guard !stopped, !Task.isCancelled else { throw CancellationError() }
    let sourceURL = try client.streamURL(path: source.streamPath)
    let relay = try relayFactory(sourceURL, client.profile.publicKeyFingerprint)
    let localURL = try await relay.start()
    guard !stopped, !Task.isCancelled else {
      relay.stop()
      throw CancellationError()
    }
    self.relay = relay
    activePlayback = source
    playbackIDs.insert(source.id)
    resumePositionMilliseconds =
      source.progress.isCompleted
      ? 0
      : source.progress.positionMilliseconds
    if !preferences.automaticResume { resumePositionMilliseconds = 0 }
    appliedResumePosition = resumePositionMilliseconds == 0
    engine.load(url: localURL)
    engine.volume = volume
    engine.isMuted = isMuted
    engine.playbackRate = playbackRate
    beginPlaybackActivityIfNeeded()
    scheduleRenewal(for: source)
    engine.play()
  }

  private func engineUpdated() {
    assignIfChanged(&isPlaying, engine.isPlaying)
    assignIfChanged(&currentTimeMilliseconds, engine.currentTimeMilliseconds)
    assignIfChanged(&durationMilliseconds, engine.durationMilliseconds)
    assignIfChanged(&volume, engine.volume)
    assignIfChanged(&isMuted, engine.isMuted)
    assignIfChanged(&audioTracks, engine.audioTracks)
    assignIfChanged(&subtitleTracks, engine.subtitleTracks)
    assignIfChanged(&selectedAudioTrackID, engine.selectedAudioTrackID)
    assignIfChanged(&selectedSubtitleTrackID, engine.selectedSubtitleTrackID)
    assignIfChanged(&playbackRate, engine.playbackRate)
    assignIfChanged(&chapters, engine.chapters)
    assignIfChanged(&currentChapterIndex, engine.currentChapterIndex)
    assignIfChanged(&isPreparing, durationMilliseconds <= 0 && !isPlaying)

    if !appliedResumePosition, durationMilliseconds > 0 {
      appliedResumePosition = true
      engine.seek(to: min(resumePositionMilliseconds, durationMilliseconds))
      currentTimeMilliseconds = min(resumePositionMilliseconds, durationMilliseconds)
    }

    if isPlaying, Date().timeIntervalSince(lastPeriodicSave) >= 15 {
      lastPeriodicSave = Date()
      enqueueProgressSave(isFinished: false)
    }
  }

  private func assignIfChanged<Value: Equatable>(_ value: inout Value, _ newValue: Value) {
    guard value != newValue else { return }
    value = newValue
  }

  private func engineEnded() {
    guard !stopped else { return }
    isPlaying = false
    currentTimeMilliseconds = durationMilliseconds
    enqueueProgressSave(isFinished: true)
    guard sleepTimer != .endOfEpisode,
      preferences.automaticallyPlayNextEpisode,
      let next = queuedItems.first
    else {
      sleepTimer = .off
      endPlaybackActivity()
      return
    }
    queuedItems.removeFirst()
    nextItemTask = Task { [weak self] in await self?.advance(to: next) }
  }

  private func engineFailed(_ message: String) {
    isPreparing = false
    isPlaying = false
    endPlaybackActivity()
    errorMessage = message
  }

  private func enqueueProgressSave(isFinished: Bool) {
    let position = currentTimeMilliseconds
    let duration = durationMilliseconds
    guard duration > 0, position >= 0, position <= duration else { return }
    let previous = saveTask
    let client = client
    let mediaID = presentation.mediaId
    saveTask = Task {
      await previous?.value
      _ = try? await client.updatePlaybackProgress(
        mediaId: mediaID,
        positionMilliseconds: position,
        durationMilliseconds: duration,
        isFinished: isFinished)
    }
  }

  private func scheduleRenewal(for source: PlaybackSourceResponse) {
    renewalTask?.cancel()
    let delay = TicketRenewalPolicy.delayUntilRenewal(expiresAt: source.expiresAt)
    renewalTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      await self?.renewTicket()
    }
  }

  private func advance(to item: PlaybackQueueItem) async {
    defer { nextItemTask = nil }
    await saveTask?.value
    guard !stopped, !Task.isCancelled else { return }
    renewalTask?.cancel()
    renewalTask = nil
    endPlaybackActivity()
    engine.stop()
    relay?.stop()
    relay = nil
    for id in playbackIDs {
      try? await client.revokePlayback(id: id)
      guard !stopped, !Task.isCancelled else { return }
    }
    playbackIDs.removeAll()
    activePlayback = nil
    presentation = PlaybackPresentation(
      mediaId: item.mediaId,
      title: item.title,
      subtitle: item.subtitle,
      queue: queuedItems)
    isPreparing = true
    currentTimeMilliseconds = 0
    durationMilliseconds = 0
    appliedResumePosition = false
    errorMessage = nil
    do {
      let source = try await client.createPlayback(mediaId: item.mediaId)
      guard !stopped, !Task.isCancelled else {
        try? await client.revokePlayback(id: source.id)
        return
      }
      try await begin(source)
    } catch {
      guard !stopped, !Task.isCancelled else { return }
      isPreparing = false
      errorMessage = "The next episode could not start. \(error.localizedDescription)"
    }
  }

  private func beginPlaybackActivityIfNeeded() {
    guard preferences.preventSleepDuringPlayback, activityToken == nil else { return }
    activityToken =
      ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleSystemSleepDisabled],
        reason: "Aurelia is playing video") as NSObjectProtocol
  }

  private func endPlaybackActivity() {
    guard let activityToken else { return }
    ProcessInfo.processInfo.endActivity(activityToken)
    self.activityToken = nil
  }

  private func renewTicket() async {
    guard !stopped, let old = activePlayback else { return }
    do {
      let renewed = try await client.createPlayback(mediaId: presentation.mediaId)
      let renewedURL = try client.streamURL(path: renewed.streamPath)
      relay?.updateSourceURL(renewedURL)
      activePlayback = renewed
      playbackIDs.insert(renewed.id)
      try? await client.revokePlayback(id: old.id)
      playbackIDs.remove(old.id)
      scheduleRenewal(for: renewed)
    } catch {
      errorMessage =
        "The playback authorization could not be renewed. \(error.localizedDescription)"
    }
  }
}

enum TicketRenewalPolicy {
  static func delayUntilRenewal(
    expiresAt: String,
    now: Date = Date()
  ) -> TimeInterval {
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let expiration =
      fractionalFormatter.date(from: expiresAt)
      ?? ISO8601DateFormatter().date(from: expiresAt)
      ?? now.addingTimeInterval(60)
    return max(1, expiration.timeIntervalSince(now) - 5 * 60)
  }
}

@MainActor
final class PlaybackShutdownCoordinator {
  static let shared = PlaybackShutdownCoordinator()

  private weak var controller: PlaybackController?
  var hasActivePlayback: Bool { controller != nil }

  func register(_ controller: PlaybackController) {
    self.controller = controller
  }

  func unregister(_ controller: PlaybackController) {
    if self.controller === controller { self.controller = nil }
  }

  func shutdown() async {
    await controller?.shutdown()
    controller = nil
  }
}
