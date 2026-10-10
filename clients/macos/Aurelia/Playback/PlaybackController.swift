import AppKit
import Foundation

@MainActor
protocol PlaybackClientProtocol: AnyObject {
  var profile: StoredServerProfile { get }
  var requiresProgressRevision: Bool { get }
  func createPlayback(mediaId: UUID) async throws -> PlaybackSourceResponse
  func playbackProgress(mediaId: UUID) async throws -> PlaybackProgressResponse
  func updatePlaybackProgress(
    mediaId: UUID,
    positionMilliseconds: Int64,
    durationMilliseconds: Int64,
    isFinished: Bool
  ) async throws -> PlaybackProgressResponse
  func updatePlaybackProgress(
    mediaId: UUID, positionMilliseconds: Int64, durationMilliseconds: Int64, isFinished: Bool,
    expectedRevision: Int64, clientMutationId: UUID
  ) async throws -> PlaybackProgressResponse
  func revokePlayback(id: UUID) async throws
  func streamURL(path: String) throws -> URL
}

extension PlaybackClientProtocol {
  var requiresProgressRevision: Bool { false }
  func playbackProgress(mediaId: UUID) async throws -> PlaybackProgressResponse {
    throw APIClientError.invalidResponse
  }
  func updatePlaybackProgress(
    mediaId: UUID, positionMilliseconds: Int64, durationMilliseconds: Int64, isFinished: Bool,
    expectedRevision: Int64, clientMutationId: UUID
  ) async throws -> PlaybackProgressResponse {
    try await updatePlaybackProgress(
      mediaId: mediaId, positionMilliseconds: positionMilliseconds,
      durationMilliseconds: durationMilliseconds, isFinished: isFinished)
  }
}

@MainActor
final class APIPlaybackClient: PlaybackClientProtocol {
  let api: APIClient
  var profile: StoredServerProfile { api.profile }
  var requiresProgressRevision: Bool { true }

  init(profile: StoredServerProfile) {
    api = APIClient(profile: profile)
  }

  func createPlayback(mediaId: UUID) async throws -> PlaybackSourceResponse {
    try await api.createPlayback(mediaId: mediaId)
  }

  func playbackProgress(mediaId: UUID) async throws -> PlaybackProgressResponse {
    try await api.playbackProgress(mediaId: mediaId)
  }

  func updatePlaybackProgress(
    mediaId: UUID, positionMilliseconds: Int64, durationMilliseconds: Int64, isFinished: Bool,
    expectedRevision: Int64, clientMutationId: UUID
  ) async throws -> PlaybackProgressResponse {
    try await api.updatePlaybackProgress(
      mediaId: mediaId, positionMilliseconds: positionMilliseconds,
      durationMilliseconds: durationMilliseconds, isFinished: isFinished,
      expectedRevision: expectedRevision, clientMutationId: clientMutationId)
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
  func setFailureHandler(_ handler: @escaping @MainActor @Sendable (PlaybackStreamFailure) -> Void)
  func stop()
}

extension PlaybackRelayProtocol {
  func setFailureHandler(_ handler: @escaping @MainActor @Sendable (PlaybackStreamFailure) -> Void)
  {}
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
  @Published private(set) var recoveryMessage: String?
  @Published private(set) var recoveryCause: PlaybackRecoveryCause?
  @Published private(set) var progressMessage: String?
  @Published private(set) var hasProgressConflict = false
  let diagnostics = PlaybackDiagnostics()

  @Published private(set) var presentation: PlaybackPresentation

  private let client: any PlaybackClientProtocol
  private let engine: PlaybackEngine
  private let preferences: PlaybackPreferences
  private let relayFactory: (URL, String) throws -> any PlaybackRelayProtocol
  private var relay: (any PlaybackRelayProtocol)?
  private var activePlayback: PlaybackSourceResponse?
  private var playbackIDs: Set<UUID> = []
  private var renewalTask: Task<Void, Never>?
  private let progressOutbox: PlaybackProgressOutbox
  private var progressObserver: UUID?
  private var lastProgressState: PlaybackProgressSaveState?
  private var started = false
  private var stopped = false
  private var authorizationFailed = false
  private var appliedResumePosition = false
  private var resumePositionMilliseconds: Int64 = 0
  private var lastPeriodicSave = Date.distantPast
  private var queuedItems: [PlaybackQueueItem]
  private var sleepTask: Task<Void, Never>?
  private var nextItemTask: Task<Void, Never>?
  private var activityToken: NSObjectProtocol?
  private var recoveryTask: Task<Void, Never>?
  private var watchdogTask: Task<Void, Never>?
  private var lifecycleID = UUID()
  private var loadID = UUID()
  private var wantsPlayback = false
  private var recovering = false
  private var endHandled = false
  private var pauseAfterResume = false
  private var lastMovementAt = Date()
  private var observedPosition: Int64 = 0
  private var recoveryAttempt = 0
  private var recoveryID = UUID()
  private var recoveryClock: @MainActor () -> Date = { Date() }
  private var recoverySleep: @MainActor (TimeInterval) async throws -> Void = { delay in
    try await Task.sleep(for: .seconds(delay))
  }
  private var renewalClock: @MainActor () -> Date = { Date() }
  private var renewalSleep: @MainActor (TimeInterval) async throws -> Void = { delay in
    try await Task.sleep(for: .seconds(delay))
  }

  init(
    profile: StoredServerProfile,
    presentation: PlaybackPresentation,
    engine: PlaybackEngine = VLCPlaybackEngine(),
    preferences: PlaybackPreferences = PlaybackPreferencesStore.shared.preferences
  ) {
    self.client = APIPlaybackClient(profile: profile)
    self.progressOutbox = .shared
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
    connectProgressOutbox()
  }

  init(
    client: any PlaybackClientProtocol,
    presentation: PlaybackPresentation,
    engine: PlaybackEngine,
    preferences: PlaybackPreferences = .defaultValue,
    relayFactory: @escaping (URL, String) throws -> any PlaybackRelayProtocol,
    renewalClock: @escaping @MainActor () -> Date = { Date() },
    renewalSleep: @escaping @MainActor (TimeInterval) async throws -> Void = { delay in
      try await Task.sleep(for: .seconds(delay))
    },
    recoveryClock: @escaping @MainActor () -> Date = { Date() },
    recoverySleep: @escaping @MainActor (TimeInterval) async throws -> Void = { delay in
      try await Task.sleep(for: .seconds(delay))
    },
    progressOutbox: PlaybackProgressOutbox? = nil
  ) {
    self.client = client
    self.progressOutbox = progressOutbox ?? PlaybackProgressOutbox()
    self.presentation = presentation
    self.engine = engine
    self.preferences = preferences.normalized
    self.playbackRate = preferences.normalized.defaultPlaybackRate
    self.volume = preferences.normalized.defaultVolume
    self.queuedItems = presentation.queue
    self.relayFactory = relayFactory
    self.renewalClock = renewalClock
    self.renewalSleep = renewalSleep
    self.recoveryClock = recoveryClock
    self.recoverySleep = recoverySleep
    connectEngineCallbacks()
    connectProgressOutbox()
  }

  private func connectProgressOutbox() {
    progressOutbox.activate(client: client)
    progressObserver = progressOutbox.observe { [weak self] in self?.progressStateChanged() }
    progressStateChanged()
  }

  private func progressStateChanged() {
    let state = progressOutbox.state(media: presentation.mediaId, profile: client.profile)
    hasProgressConflict = state == .conflict
    if progressOutbox.capacityReached {
      progressMessage =
        "Too many unsynchronized titles. Reconnect the server before saving more progress."
    } else if progressOutbox.storageFailed {
      progressMessage = "Progress could not be saved on this Mac. Check available disk space."
      if lastProgressState != state { record(.progressStorageFailure) }
    } else {
      switch state {
      case .conflict:
        progressMessage =
          "Another device changed this playback position. Your local progress is retained."
      case .accessDenied:
        progressMessage = "Progress saving stopped. Sign in again or check library access."
      case .unsupportedServer:
        progressMessage = "Update the server to safely synchronize retained playback progress."
      case .retrying:
        progressMessage = "Progress is saved on this Mac and will sync when the server reconnects."
      case .pending, nil: progressMessage = nil
      }
      if lastProgressState != state {
        if state == .conflict {
          record(.progressConflict)
        } else if state == .accessDenied {
          record(.progressAccessDenied)
        } else if state == .retrying {
          record(.progressPending)
        }
      }
    }
    lastProgressState = state
  }

  func useCurrentProgress() async {
    guard hasProgressConflict else { return }
    enqueueProgressSave(isFinished: endHandled)
    do {
      try await progressOutbox.resolveConflict(media: presentation.mediaId, profile: client.profile)
    } catch {
      progressMessage = "The progress conflict could not be resolved. Check the server connection."
    }
  }

  private func record(
    _ kind: PlaybackDiagnosticEvent.Kind, cause: PlaybackRecoveryCause? = nil, attempt: Int? = nil
  ) {
    diagnostics.record(
      kind, cause: cause, attempt: attempt, position: currentTimeMilliseconds,
      duration: durationMilliseconds)
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
    wantsPlayback = true
    record(.started)
    let operation = lifecycleID

    do {
      let source = try await client.createPlayback(mediaId: presentation.mediaId)
      guard !stopped, !Task.isCancelled, operation == lifecycleID else {
        try? await client.revokePlayback(id: source.id)
        return
      }
      try await begin(source, autoplay: wantsPlayback)
    } catch {
      guard !stopped, !Task.isCancelled, operation == lifecycleID else { return }
      if PlaybackRecoveryPolicy.isRecoverable(error) {
        recoverPlayback(cause: PlaybackRecoveryCause.classify(error))
      } else {
        isPreparing = false
        errorMessage = error.localizedDescription
      }
    }
  }

  func retry() async {
    let position = currentTimeMilliseconds
    let operation = UUID()
    lifecycleID = operation
    await stopCurrentPlayback(saveProgress: false)
    // Closing the window (or a newer retry) while old tickets are being
    // revoked must not resurrect this player after asynchronous cleanup.
    guard lifecycleID == operation, !Task.isCancelled else { return }
    if progressObserver == nil { connectProgressOutbox() }
    started = false
    stopped = false
    recoveryAttempt = 0
    // An explicit retry keeps the in-memory position even if its last server
    // save failed, or automatic resume is disabled for new playback sessions.
    started = true
    wantsPlayback = true
    errorMessage = nil
    isPreparing = true
    do {
      let source = try await client.createPlayback(mediaId: presentation.mediaId)
      guard !stopped, !Task.isCancelled, operation == lifecycleID else {
        try? await client.revokePlayback(id: source.id)
        return
      }
      try await begin(source, resumeOverride: position)
    } catch {
      guard !stopped, !Task.isCancelled, operation == lifecycleID else { return }
      if PlaybackRecoveryPolicy.isRecoverable(error) {
        recoverPlayback(cause: PlaybackRecoveryCause.classify(error))
      } else {
        isPreparing = false
        errorMessage = error.localizedDescription
      }
    }
  }

  func togglePlayback() {
    guard !stopped, !authorizationFailed, !recovering else { return }
    if endHandled {
      replayCompletedPlayback(at: 0, autoplay: true)
      return
    }
    if engine.isPlaying {
      wantsPlayback = false
      engine.pause()
      enqueueProgressSave(isFinished: false)
    } else {
      wantsPlayback = true
      lastMovementAt = recoveryClock()
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
    guard !stopped, !authorizationFailed, !recovering else { return }
    let upper = durationMilliseconds > 0 ? durationMilliseconds : Int64.max
    let target = min(max(milliseconds, 0), upper)
    if endHandled {
      replayCompletedPlayback(at: target, autoplay: false)
      return
    }
    engine.seek(to: target)
    currentTimeMilliseconds = target
    observedPosition = target
    lastMovementAt = recoveryClock()
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
    guard !stopped, !authorizationFailed, !recovering else { return }
    if endHandled {
      seek(to: chapter.timeOffsetMilliseconds)
      return
    }
    engine.selectChapter(index: chapter.index)
    currentTimeMilliseconds = chapter.timeOffsetMilliseconds
    observedPosition = currentTimeMilliseconds
    lastMovementAt = recoveryClock()
  }

  private func replayCompletedPlayback(at position: Int64, autoplay: Bool) {
    // A completed VLC input and its relay generation cannot be reused. Explicit
    // replay uses fresh authorization/load, but never competes with auto-next.
    guard endHandled, nextItemTask == nil else { return }
    currentTimeMilliseconds = position
    observedPosition = position
    lastMovementAt = recoveryClock()
    wantsPlayback = autoplay
    recoveryAttempt = 0
    recoverPlayback(message: "Preparing playback…")
  }

  func setSleepTimer(_ timer: PlaybackSleepTimer) {
    sleepTask?.cancel()
    sleepTask = nil
    sleepTimer = timer
    guard case .minutes(let minutes) = timer else { return }
    if minutes <= 0 {
      wantsPlayback = false
      cancelRecoveryForSleep()
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
      self.wantsPlayback = false
      self.cancelRecoveryForSleep()
      if self.engine.isPlaying { self.engine.pause() }
      self.engineUpdated()
      self.sleepTimer = .off
      self.enqueueProgressSave(isFinished: false)
    }
  }

  func shutdown(saveProgress: Bool = true) async {
    lifecycleID = UUID()
    await stopCurrentPlayback(saveProgress: saveProgress)
  }

  private func stopCurrentPlayback(saveProgress: Bool) async {
    guard !stopped else { return }
    stopped = true
    loadID = UUID()
    wantsPlayback = false
    recoveryTask?.cancel()
    recoveryID = UUID()
    recoveryTask = nil
    watchdogTask?.cancel()
    watchdogTask = nil
    recovering = false
    recoveryMessage = nil
    renewalTask?.cancel()
    renewalTask = nil
    sleepTask?.cancel()
    sleepTask = nil
    nextItemTask?.cancel()
    nextItemTask = nil
    endPlaybackActivity()

    // Stop reads immediately; a slow progress save must not leave the player
    // or an old recovery task running after its window has closed.
    relay?.stop()
    relay = nil
    engine.stop()
    activePlayback = nil
    let retiredIDs = playbackIDs
    playbackIDs.removeAll()

    if saveProgress {
      enqueueProgressSave(isFinished: endHandled)
      await progressOutbox.flush()
    }
    await revokeTickets(retiredIDs)
    record(.stopped)
    if let progressObserver { progressOutbox.removeObserver(progressObserver) }
    progressObserver = nil
  }

  private func begin(
    _ source: PlaybackSourceResponse, resumeOverride: Int64? = nil, autoplay: Bool = true
  ) async throws {
    guard !stopped, !Task.isCancelled else { throw CancellationError() }
    let relay: any PlaybackRelayProtocol
    do {
      let sourceURL = try client.streamURL(path: source.streamPath)
      relay = try relayFactory(sourceURL, client.profile.publicKeyFingerprint)
    } catch {
      try? await client.revokePlayback(id: source.id)
      throw error
    }
    let generation = UUID()
    loadID = generation
    relay.setFailureHandler { [weak self] failure in
      guard let self, self.loadID == generation else { return }
      self.streamFailed(failure)
    }
    let localURL: URL
    do {
      localURL = try await relay.start()
      guard !stopped, !Task.isCancelled, loadID == generation else {
        throw CancellationError()
      }
    } catch {
      relay.stop()
      try? await client.revokePlayback(id: source.id)
      throw error
    }
    self.relay = relay
    progressOutbox.noteBaseline(source.progress, profile: client.profile)
    activePlayback = source
    // Only a newly authorized source with a ready local relay can clear a
    // definitive authorization failure. A tentative retry alone cannot.
    authorizationFailed = false
    playbackIDs.insert(source.id)
    resumePositionMilliseconds =
      resumeOverride
      ?? (preferences.automaticResume && !source.progress.isCompleted
        ? source.progress.positionMilliseconds : 0)
    appliedResumePosition = resumePositionMilliseconds == 0
    pauseAfterResume = !autoplay
    wantsPlayback = autoplay
    recovering = false
    recoveryMessage = nil
    recoveryCause = nil
    errorMessage = nil
    endHandled = false
    lastMovementAt = recoveryClock()
    observedPosition = resumePositionMilliseconds
    if queuedItems.first?.mediaId == presentation.mediaId {
      queuedItems.removeFirst()
      presentation = PlaybackPresentation(
        mediaId: presentation.mediaId, title: presentation.title,
        subtitle: presentation.subtitle, queue: queuedItems)
    }
    engine.load(url: localURL)
    engine.volume = volume
    engine.isMuted = isMuted
    engine.playbackRate = playbackRate
    beginPlaybackActivityIfNeeded()
    scheduleRenewal(for: source)
    engine.play()
    scheduleWatchdog()
    record(.prepared)
  }

  private func engineUpdated() {
    guard !stopped, !authorizationFailed, !recovering, !endHandled else { return }
    assignIfChanged(&isPlaying, engine.isPlaying)
    if appliedResumePosition {
      assignIfChanged(&currentTimeMilliseconds, engine.currentTimeMilliseconds)
    }
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

    if pauseAfterResume, appliedResumePosition, durationMilliseconds > 0 {
      pauseAfterResume = false
      engine.pause()
      isPlaying = false
    }
    if currentTimeMilliseconds > observedPosition + 250 {
      observedPosition = currentTimeMilliseconds
      lastMovementAt = recoveryClock()
      recoveryAttempt = 0
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
    guard !stopped, !authorizationFailed, !recovering, !endHandled else { return }
    let position = max(currentTimeMilliseconds, engine.currentTimeMilliseconds)
    let duration = max(durationMilliseconds, engine.durationMilliseconds)
    guard PlaybackRecoveryPolicy.hasReachedEnd(position: position, duration: duration) else {
      recoverPlayback(cause: .prematureEnd)
      return
    }
    endHandled = true
    loadID = UUID()
    watchdogTask?.cancel()
    watchdogTask = nil
    isPlaying = false
    currentTimeMilliseconds = duration
    durationMilliseconds = duration
    record(.ended)
    enqueueProgressSave(isFinished: true)
    guard sleepTimer != .endOfEpisode,
      preferences.automaticallyPlayNextEpisode,
      let next = queuedItems.first
    else {
      sleepTimer = .off
      endPlaybackActivity()
      return
    }
    nextItemTask = Task { [weak self] in await self?.advance(to: next) }
  }

  private func engineFailed(_ message: String) {
    guard !stopped, !authorizationFailed, !recovering, !endHandled else { return }
    // The decoder's arbitrary error text must never enter diagnostic exports.
    recoverPlayback(cause: .decoderError)
  }

  private func enqueueProgressSave(isFinished: Bool) {
    let position = currentTimeMilliseconds
    let duration = durationMilliseconds
    guard duration > 0, position >= 0, position <= duration else { return }
    progressOutbox.enqueue(
      media: presentation.mediaId, profile: client.profile, position: position, duration: duration,
      finished: isFinished)
  }

  private func scheduleRenewal(for source: PlaybackSourceResponse) {
    renewalTask?.cancel()
    let delay = TicketRenewalPolicy.delayUntilRenewal(
      expiresAt: source.expiresAt, now: renewalClock())
    renewalTask = Task { [weak self] in
      guard let self else { return }
      do { try await self.renewalSleep(delay) } catch { return }
      guard !Task.isCancelled, !self.stopped else { return }
      await self.renewTicket()
    }
  }

  private func advance(to item: PlaybackQueueItem) async {
    loadID = UUID()
    defer { nextItemTask = nil }
    await progressOutbox.flush()
    guard !stopped, !authorizationFailed, !Task.isCancelled else { return }
    renewalTask?.cancel()
    renewalTask = nil
    endPlaybackActivity()
    relay?.stop()
    relay = nil
    engine.stop()
    await revokeTickets(playbackIDs)
    guard !stopped, !authorizationFailed, !Task.isCancelled else { return }
    playbackIDs.removeAll()
    activePlayback = nil
    presentation = PlaybackPresentation(
      mediaId: item.mediaId,
      title: item.title,
      subtitle: item.subtitle,
      queue: queuedItems)
    isPreparing = true
    wantsPlayback = true
    currentTimeMilliseconds = 0
    durationMilliseconds = 0
    appliedResumePosition = false
    errorMessage = nil
    record(.nextEpisode)
    progressStateChanged()
    do {
      let source = try await client.createPlayback(mediaId: item.mediaId)
      guard !stopped, !authorizationFailed, !Task.isCancelled else {
        try? await client.revokePlayback(id: source.id)
        return
      }
      try await begin(source, autoplay: wantsPlayback)
    } catch {
      guard !stopped, !authorizationFailed, !Task.isCancelled else { return }
      if PlaybackRecoveryPolicy.isRecoverable(error) {
        recoverPlayback(cause: PlaybackRecoveryCause.classify(error))
      } else {
        isPreparing = false
        errorMessage = "The next episode could not start. \(error.localizedDescription)"
      }
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
    var attempt = 0
    var notice: String?
    while !stopped && !Task.isCancelled && activePlayback?.id == old.id {
      do {
        let renewed = try await client.createPlayback(mediaId: presentation.mediaId)
        guard !stopped, !Task.isCancelled, activePlayback?.id == old.id else {
          try? await client.revokePlayback(id: renewed.id)
          return
        }
        let renewedURL = try client.streamURL(path: renewed.streamPath)
        relay?.updateSourceURL(renewedURL)
        activePlayback = renewed
        playbackIDs.insert(renewed.id)
        try? await client.revokePlayback(id: old.id)
        playbackIDs.remove(old.id)
        guard !stopped, !Task.isCancelled else { return }
        if let notice, errorMessage == notice { errorMessage = nil }
        scheduleRenewal(for: renewed)
        return
      } catch {
        guard !stopped, !Task.isCancelled, activePlayback?.id == old.id else { return }
        let remaining =
          TicketRenewalPolicy.expiration(old.expiresAt)?.timeIntervalSince(renewalClock()) ?? 0
        if TicketRenewalPolicy.isTransient(error), remaining > 0, attempt < 12 {
          let proposed = (error as? APIClientError)?.retryDelay ?? min(30, pow(2, Double(attempt)))
          let delay = min(max(0.1, proposed), remaining)
          attempt += 1
          notice = "The connection was interrupted. Retrying playback authorization…"
          errorMessage = notice
          do { try await renewalSleep(delay) } catch { return }
          guard let expiry = TicketRenewalPolicy.expiration(old.expiresAt), expiry > renewalClock()
          else {
            stopUnauthorizedPlayback(
              "The playback authorization expired while the server was unreachable.")
            return
          }
          continue
        }
        stopUnauthorizedPlayback(
          "The playback authorization could not be renewed. \(error.localizedDescription)")
        return
      }
    }
  }

  private func stopUnauthorizedPlayback(
    _ message: String, cause: PlaybackRecoveryCause = .accessDenied
  ) {
    record(.authorizationStopped, cause: cause)
    recoveryCause = cause
    authorizationFailed = true
    loadID = UUID()
    recoveryTask?.cancel()
    recoveryTask = nil
    watchdogTask?.cancel()
    watchdogTask = nil
    recovering = false
    recoveryMessage = nil
    wantsPlayback = false
    sleepTask?.cancel()
    sleepTask = nil
    nextItemTask?.cancel()
    nextItemTask = nil
    relay?.stop()
    relay = nil
    engine.stop()
    isPlaying = false
    isPreparing = false
    endPlaybackActivity()
    errorMessage = message
  }

  private func streamFailed(_ failure: PlaybackStreamFailure) {
    guard !stopped, !recovering, !endHandled else { return }
    switch failure {
    case .interrupted:
      recoverPlayback(cause: .connectionInterrupted)
    case .unavailable:
      // HTTP 404/410/503 alone cannot prove that a physical drive disconnected.
      recoverPlayback(cause: .mediaSourceUnavailable)
    case .authorizationDenied:
      stopUnauthorizedPlayback("Playback access was denied. Sign in again or check library access.")
    case .untrustedServer:
      stopUnauthorizedPlayback(
        "The server identity could not be verified. Playback has stopped.",
        cause: .serverIdentityMismatch)
    case .invalidResponse:
      stopUnauthorizedPlayback(
        "The server returned an invalid media stream.", cause: .invalidStream)
    }
  }

  private func scheduleWatchdog() {
    watchdogTask?.cancel()
    let operation = lifecycleID
    watchdogTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard let self, !self.stopped, self.lifecycleID == operation else { return }
        self.checkForStall()
      }
    }
  }

  // Also covers VLC stalls that produce neither an error nor an end callback.
  func checkForStall() {
    guard !stopped, !authorizationFailed, !recovering, !endHandled, wantsPlayback,
      recoveryClock().timeIntervalSince(lastMovementAt) >= (isPreparing ? 30 : 15)
    else { return }
    recoverPlayback(cause: .stalled)
  }

  private func recoverPlayback(cause: PlaybackRecoveryCause) {
    recoveryCause = cause
    record(.recoveryStarted, cause: cause)
    recoverPlayback(message: cause.message)
  }

  private func recoverPlayback(message: String) {
    guard !stopped, !authorizationFailed, !recovering else { return }
    let position = currentTimeMilliseconds
    let autoplay = wantsPlayback
    let operation = lifecycleID
    let recovery = UUID()
    recoveryID = recovery
    recovering = true
    loadID = UUID()
    isPlaying = false
    isPreparing = true
    recoveryMessage = message
    errorMessage = nil
    renewalTask?.cancel()
    renewalTask = nil
    watchdogTask?.cancel()
    watchdogTask = nil
    enqueueProgressSave(isFinished: false)
    relay?.stop()
    relay = nil
    engine.stop()
    activePlayback = nil
    let retiredIDs = playbackIDs
    playbackIDs.removeAll()
    recoveryTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.lifecycleID == operation, self.recoveryID == recovery {
          self.recoveryTask = nil
        }
      }
      await self.revokeTickets(retiredIDs)
      guard !Task.isCancelled, !self.stopped, self.lifecycleID == operation,
        self.recoveryID == recovery
      else { return }
      while self.recoveryAttempt < PlaybackRecoveryPolicy.delays.count {
        let delay = PlaybackRecoveryPolicy.delays[self.recoveryAttempt]
        self.recoveryAttempt += 1
        self.record(.recoveryAttempt, cause: self.recoveryCause, attempt: self.recoveryAttempt)
        do { try await self.recoverySleep(delay) } catch { return }
        guard !Task.isCancelled, !self.stopped, self.lifecycleID == operation,
          self.recoveryID == recovery
        else { return }
        do {
          let source = try await self.client.createPlayback(mediaId: self.presentation.mediaId)
          guard !Task.isCancelled, !self.stopped, self.lifecycleID == operation,
            self.recoveryID == recovery
          else {
            try? await self.client.revokePlayback(id: source.id)
            return
          }
          try await self.begin(source, resumeOverride: position, autoplay: autoplay)
          self.record(.recovered)
          return
        } catch {
          guard !Task.isCancelled, !self.stopped, self.lifecycleID == operation,
            self.recoveryID == recovery
          else { return }
          if !PlaybackRecoveryPolicy.isRecoverable(error) {
            if (error as? APIClientError)?.isAuthenticationFailure == true
              || error as? APIClientError == .serverIdentityMismatch
              || (error as? URLError)?.code == .serverCertificateUntrusted
            {
              self.stopUnauthorizedPlayback(
                error.localizedDescription, cause: PlaybackRecoveryCause.classify(error))
              return
            }
            self.recovering = false
            self.recoveryMessage = nil
            self.isPreparing = false
            self.errorMessage = error.localizedDescription
            self.endPlaybackActivity()
            return
          }
        }
      }
      self.recovering = false
      self.recoveryMessage = nil
      self.isPreparing = false
      self.errorMessage =
        "Playback could not recover. Reconnect the media drive or check the server, then choose Try Again."
      self.endPlaybackActivity()
      self.record(.recoveryExhausted, cause: self.recoveryCause)
    }
  }

  func cancelRecovery() {
    record(.recoveryCancelled, cause: recoveryCause)
    recoveryTask?.cancel()
    recoveryID = UUID()
    recoveryTask = nil
    recovering = false
    recoveryMessage = nil
    isPreparing = false
    wantsPlayback = false
    endPlaybackActivity()
    errorMessage = "Playback recovery stopped. Choose Try Again when the media is available."
  }

  private func cancelRecoveryForSleep() {
    if recovering { cancelRecovery() }
  }

  private func revokeTickets(_ ids: Set<UUID>) async {
    guard !ids.isEmpty else { return }
    let client = client
    await withCheckedContinuation { continuation in
      let completion = PlaybackCleanupCompletion(continuation)
      completion.operation = Task {
        for id in ids {
          guard !Task.isCancelled else { break }
          try? await client.revokePlayback(id: id)
        }
        completion.finish()
      }
      completion.timeout = Task {
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        completion.finish()
      }
    }
  }
}

@MainActor
private final class PlaybackCleanupCompletion {
  private var continuation: CheckedContinuation<Void, Never>?
  var operation: Task<Void, Never>?
  var timeout: Task<Void, Never>?
  init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
  func finish() {
    guard let continuation else { return }
    self.continuation = nil
    operation?.cancel()
    timeout?.cancel()
    operation = nil
    timeout = nil
    continuation.resume()
  }
}

enum PlaybackRecoveryPolicy {
  static let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30]

  static func hasReachedEnd(position: Int64, duration: Int64) -> Bool {
    // VLC time notifications are coarser than frame timestamps. Allow a small
    // final-tick gap even for short clips, but never accept an early EOF.
    duration > 0 && position >= max(1, duration - min(2_000, max(500, duration / 100)))
  }

  static func isRecoverable(_ error: Error) -> Bool {
    if let api = error as? APIClientError {
      if api.isAuthenticationFailure { return false }
      return api.problemCode == "media_unavailable" || api.isRetryableTransient
    }
    return TicketRenewalPolicy.isTransient(error)
  }
}

enum TicketRenewalPolicy {
  static func expiration(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  static func isTransient(_ error: Error) -> Bool {
    if let api = error as? APIClientError { return api.isRetryableTransient }
    guard let network = error as? URLError else { return false }
    return [
      .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
      .networkConnectionLost, .notConnectedToInternet, .cannotLoadFromNetwork,
    ].contains(network.code)
  }
  static func delayUntilRenewal(
    expiresAt: String,
    now: Date = Date()
  ) -> TimeInterval {
    let expiration =
      expiration(expiresAt)
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
    await PlaybackProgressOutbox.shared.flush()
  }
}
