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
  func streamSubtitles(ticket: UUID) async throws -> [LiveSubtitleTrack]
  /// Tells the server a sleep timer ended, so a server in sleep mode can sleep if nothing plays.
  func sleepTimerEnded() async
}

extension PlaybackClientProtocol {
  func streamSubtitles(ticket: UUID) async throws -> [LiveSubtitleTrack] { [] }
}

extension PlaybackClientProtocol {
  var requiresProgressRevision: Bool { false }
  func sleepTimerEnded() async {}
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

  func sleepTimerEnded() async {
    // Servers before 1.8.2 do not know the signal; playback is not affected either way.
    try? await api.sleepTimerEnded()
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
  func subtitleURL(index: Int) -> URL?
  func setFailureHandler(_ handler: @escaping @MainActor @Sendable (PlaybackStreamFailure) -> Void)
  func stop()
}

extension PlaybackRelayProtocol {
  func subtitleURL(index: Int) -> URL? { nil }
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
  /// The start screen covers the player from Play until the picture moves, for the first title
  /// and each next episode; pausing, an error or closing ends it.
  @Published private(set) var showsStartScreen = true
  /// The next episode's card in a title's last seconds.
  @Published private(set) var upNext: PlaybackUpNext?
  @Published private(set) var isPlaying = false
  @Published private(set) var isSeekable = false
  @Published private(set) var currentTimeMilliseconds: Int64 = 0
  @Published private(set) var navigationRevision: UInt64 = 0
  @Published private(set) var durationMilliseconds: Int64 = 0
  @Published private(set) var audioTracks: [PlaybackTrack] = []
  @Published private(set) var subtitleTracks: [PlaybackTrack] = []
  @Published private(set) var selectedAudioTrackID: Int32?
  @Published private(set) var selectedSubtitleTrackID: Int32?
  @Published private(set) var playbackRate: Double
  @Published private(set) var chapters: [PlaybackChapter] = []
  @Published private(set) var currentChapterIndex: Int32?
  @Published private(set) var sleepTimer: PlaybackSleepTimer = .off
  /// The sleep timer ran out: the player closes, so nothing keeps the Mac or the server awake.
  @Published private(set) var sleepTimerFinished = false
  @Published var volume: Double = 1
  @Published var isMuted = false
  @Published var errorMessage: String?
  @Published private(set) var recoveryMessage: String?
  @Published private(set) var recoveryCause: PlaybackRecoveryCause?
  @Published private(set) var progressMessage: String?
  @Published private(set) var hasProgressConflict = false
  /// A separate local relay for decoding scrub previews live. Its reads are marked as previews,
  /// which the server counts apart from playback, and its failures never touch playback.
  @Published private(set) var previewSourceURL: URL?
  /// The local relay address the player reads.
  private var playbackURL: URL?
  let diagnostics = PlaybackDiagnostics()

  @Published private(set) var presentation: PlaybackPresentation

  private let client: any PlaybackClientProtocol
  private let engine: PlaybackEngine
  private let preferences: PlaybackPreferences
  private let relayFactory: (URL, String) throws -> any PlaybackRelayProtocol
  private let previewRelayFactory: ((URL, String) throws -> any PlaybackRelayProtocol)?
  private var relay: (any PlaybackRelayProtocol)? {
    didSet { if relay !== oldValue { stopPreviewRelay() } }
  }
  private var previewRelay: (any PlaybackRelayProtocol)?
  private var previewRelayTask: Task<Void, Never>?
  private var activePlayback: PlaybackSourceResponse?
  private var playbackIDs: Set<UUID> = []
  private var renewalTask: Task<Void, Never>?
  private let progressOutbox: PlaybackProgressOutbox
  private var progressObserver: UUID?
  private var lastProgressState: PlaybackProgressSaveState?
  private var started = false
  private var stopped = false
  private var authorizationFailed = false
  private var terminalFailure = false
  private var appliedResumePosition = false
  private var hasPreparedCurrentItem = false
  /// The engine was asked to open at the resume position, so it usually needs no seek.
  private var openedAtResume = false
  private var upNextDismissed = false
  /// Cancel on the Up Next card: this title stops at its end instead of continuing.
  private var autoplayCancelled = false
  private var resumePositionMilliseconds: Int64 = 0
  private var lastPeriodicSave = Date.distantPast
  private var queuedItems: [PlaybackQueueItem]
  private var previousItems: [PlaybackQueueItem]
  private var sleepTask: Task<Void, Never>?
  private var sleepTimerSleep: @MainActor (TimeInterval) async throws -> Void = { delay in
    try await Task.sleep(for: .seconds(delay))
  }
  private var nextItemTask: Task<Void, Never>?
  private var activityToken: NSObjectProtocol?
  private var recoveryTask: Task<Void, Never>?
  private var watchdogTask: Task<Void, Never>?
  private var lifecycleID = UUID()
  private var loadID = UUID()
  private var wantsPlayback = false
  private var pauseRequestPending = false
  private var recovering = false
  private var endHandled = false
  // Queue navigation also retires engine callbacks; it is not proof of a natural media end.
  private var naturalEndReached = false
  private var lastMovementAt = Date()
  private var observedPosition: Int64 = 0
  private var recoveryAttempt = 0
  private var recoveryID = UUID()
  private var recoveryClock: @MainActor () -> Date = {
    Date(timeIntervalSince1970: ProcessInfo.processInfo.systemUptime)
  }
  private var timing = PlaybackTimingPolicy()
  private var deadlineSleep: @MainActor (TimeInterval) async throws -> Void = { delay in
    try await Task.sleep(for: .seconds(delay))
  }
  private var pendingOperations: [UUID: @MainActor () -> Void] = [:]
  private var incidentStartedAt: Date?
  private var incidentPausedAt: Date?
  private var stableMovementStartedAt: Date?
  private var awaitingFirstMovement = false
  private var awaitingRecoveryMovement = false
  private var preparedAt = Date()
  private var opaqueTicketRetryUsed = false
  private var recoveryRetryAfter: TimeInterval?
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
    if let engine = engine as? VLCPlaybackEngine, Self.isLocalServer(profile.baseURL) {
      engine.networkCachingMilliseconds = 300
    }
    self.progressOutbox = .shared
    self.presentation = presentation
    self.engine = engine
    self.engine.profileScope = profile.user?.id ?? profile.serverId
    self.preferences = preferences.normalized
    self.playbackRate = preferences.normalized.defaultPlaybackRate
    self.volume = preferences.normalized.defaultVolume
    self.queuedItems = presentation.queue
    self.previousItems = presentation.previousItems
    self.relayFactory = { url, fingerprint in
      try LoopbackStreamRelay(
        sourceURL: url,
        publicKeyFingerprint: fingerprint,
        authorizationToken: profile.token)
    }
    self.previewRelayFactory = { url, fingerprint in
      try LoopbackStreamRelay(
        sourceURL: url,
        publicKeyFingerprint: fingerprint,
        authorizationToken: profile.token,
        streamPurpose: "preview")
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
    previewRelayFactory: ((URL, String) throws -> any PlaybackRelayProtocol)? = nil,
    renewalClock: @escaping @MainActor () -> Date = { Date() },
    renewalSleep: @escaping @MainActor (TimeInterval) async throws -> Void = { delay in
      try await Task.sleep(for: .seconds(delay))
    },
    recoveryClock: @escaping @MainActor () -> Date = {
      Date(timeIntervalSince1970: ProcessInfo.processInfo.systemUptime)
    },
    recoverySleep: @escaping @MainActor (TimeInterval) async throws -> Void = { delay in
      try await Task.sleep(for: .seconds(delay))
    },
    progressOutbox: PlaybackProgressOutbox? = nil,
    timing: PlaybackTimingPolicy = PlaybackTimingPolicy(),
    deadlineSleep: @escaping @MainActor (TimeInterval) async throws -> Void = { delay in
      try await Task.sleep(for: .seconds(delay))
    },
    sleepTimerSleep: @escaping @MainActor (TimeInterval) async throws -> Void = { delay in
      try await Task.sleep(for: .seconds(delay))
    }
  ) {
    self.client = client
    self.progressOutbox = progressOutbox ?? PlaybackProgressOutbox()
    self.presentation = presentation
    self.engine = engine
    self.preferences = preferences.normalized
    self.playbackRate = preferences.normalized.defaultPlaybackRate
    self.volume = preferences.normalized.defaultVolume
    self.queuedItems = presentation.queue
    self.previousItems = presentation.previousItems
    self.relayFactory = relayFactory
    self.previewRelayFactory = previewRelayFactory
    self.renewalClock = renewalClock
    self.renewalSleep = renewalSleep
    self.recoveryClock = recoveryClock
    self.recoverySleep = recoverySleep
    self.timing = timing
    self.deadlineSleep = deadlineSleep
    self.sleepTimerSleep = sleepTimerSleep
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
    enqueueProgressSave(isFinished: naturalEndReached)
    do {
      try await progressOutbox.resolveConflict(media: presentation.mediaId, profile: client.profile)
    } catch {
      progressMessage = "The progress conflict could not be resolved. Check the server connection."
    }
  }

  private func record(
    _ kind: PlaybackDiagnosticEvent.Kind, cause: PlaybackRecoveryCause? = nil, attempt: Int? = nil,
    phase: PlaybackDiagnosticPhase? = nil, error: Error? = nil,
    context: PlaybackFailureContext? = nil
  ) {
    let detail =
      context
      ?? error.map {
        PlaybackFailureContext(error: $0, phase: phase ?? .ticketAuthorization)
      }
    diagnostics.record(
      kind, cause: cause, attempt: attempt, position: currentTimeMilliseconds,
      duration: durationMilliseconds, phase: detail?.phase ?? phase,
      httpStatus: detail?.httpStatus, urlErrorCode: detail?.urlErrorCode,
      problemCode: detail?.problemCode, bytesTransferred: detail?.bytesTransferred,
      retryAfter: detail?.retryAfter, localReason: detail?.localReason)
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
    terminalFailure = false
    wantsPlayback = true
    incidentStartedAt = recoveryClock()
    incidentPausedAt = nil
    opaqueTicketRetryUsed = false
    record(.started)
    let operation = lifecycleID

    do {
      let source = try await requestPlaybackSource(mediaId: presentation.mediaId)
      guard !stopped, !Task.isCancelled, operation == lifecycleID else {
        await revokeTickets([source.id])
        return
      }
      try await begin(source)
    } catch {
      guard !stopped, !Task.isCancelled, operation == lifecycleID else { return }
      let context = PlaybackFailureContext(error: error, phase: .ticketAuthorization)
      record(.failureObserved, cause: context.cause, context: context)
      if PlaybackRecoveryPolicy.isRecoverable(error) {
        recoverPlayback(context: context)
      } else {
        terminalFailure = true
        wantsPlayback = false
        recoveryCause = context.cause
        isPreparing = false
        errorMessage = context.cause.message
      }
    }
  }

  private var preservedInputPosition: Int64? {
    hasPreparedCurrentItem
      ? (appliedResumePosition ? currentTimeMilliseconds : resumePositionMilliseconds) : nil
  }

  func retry() async {
    let position = preservedInputPosition
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
    incidentStartedAt = recoveryClock()
    incidentPausedAt = nil
    opaqueTicketRetryUsed = false
    stableMovementStartedAt = nil
    // An explicit retry keeps the in-memory position even if its last server
    // save failed, or automatic resume is disabled for new playback sessions.
    started = true
    wantsPlayback = true
    errorMessage = nil
    terminalFailure = false
    isPreparing = true
    do {
      let source = try await requestPlaybackSource(mediaId: presentation.mediaId)
      guard !stopped, !Task.isCancelled, operation == lifecycleID else {
        await revokeTickets([source.id])
        return
      }
      try await begin(source, resumeOverride: position)
    } catch {
      guard !stopped, !Task.isCancelled, operation == lifecycleID else { return }
      let context = PlaybackFailureContext(error: error, phase: .ticketAuthorization)
      record(.failureObserved, cause: context.cause, context: context)
      if PlaybackRecoveryPolicy.isRecoverable(error) {
        recoverPlayback(context: context)
      } else {
        terminalFailure = true
        wantsPlayback = false
        recoveryCause = context.cause
        isPreparing = false
        errorMessage = context.cause.message
      }
    }
  }

  var canPlay: Bool { started && !stopped && !authorizationFailed && !terminalFailure }
  var canPause: Bool { started && !stopped && !terminalFailure }
  var canSeek: Bool {
    started && !stopped && !authorizationFailed && !terminalFailure && !recovering
      && !isPreparing && nextItemTask == nil && activePlayback != nil
      && durationMilliseconds > 0 && engine.isSeekable
  }
  private var canNavigateEpisodes: Bool {
    started && !stopped && !authorizationFailed && !terminalFailure && !recovering
      && !isPreparing && !endHandled && nextItemTask == nil && activePlayback != nil
  }
  var canPlayNext: Bool { canNavigateEpisodes && !queuedItems.isEmpty }
  var canPlayPrevious: Bool { canNavigateEpisodes && !previousItems.isEmpty }
  var nextQueueItem: PlaybackQueueItem? { queuedItems.first }

  @discardableResult
  func playPreviousFromSystemMedia() -> Bool {
    guard canPlayPrevious, let previous = previousItems.last else { return false }
    navigateNow(to: previous, backwards: true)
    return true
  }

  @discardableResult
  func playNextFromSystemMedia() -> Bool {
    guard canPlayNext else { return false }
    playNextNow()
    return true
  }

  @discardableResult
  func play() -> Bool {
    guard canPlay else { return false }
    if endHandled, !recovering, nextItemTask == nil {
      replayCompletedPlayback(at: 0, autoplay: true)
      return true
    }
    guard !wantsPlayback else { return true }
    wantsPlayback = true
    beginPlaybackActivityIfNeeded()
    pauseRequestPending = false
    lastMovementAt = recoveryClock()
    preparedAt = recoveryClock()
    stableMovementStartedAt = nil
    // A prepared, deliberately paused input can play without new authorization.
    // Pending startup/recovery/queue work reads this intent when it completes.
    if activePlayback != nil, !recovering, nextItemTask == nil {
      if let incidentPausedAt, let incidentStartedAt {
        self.incidentStartedAt = incidentStartedAt.addingTimeInterval(
          recoveryClock().timeIntervalSince(incidentPausedAt))
      }
      incidentPausedAt = nil
      engine.play()
    }
    engineUpdated()
    return true
  }

  @discardableResult
  func pause() -> Bool {
    guard canPause else { return false }
    wantsPlayback = false
    stableMovementStartedAt = nil
    applyPausedIntentIfNeeded()
    showsStartScreen = false
    isPlaying = false
    if activePlayback != nil, !recovering { isPreparing = false }
    if activePlayback != nil, !recovering, nextItemTask == nil, incidentPausedAt == nil {
      incidentPausedAt = recoveryClock()
    }
    // A paused title must not keep the Mac awake, for example after a sleep timer.
    endPlaybackActivity()
    enqueueProgressSave(isFinished: naturalEndReached)
    return true
  }

  private func applyPausedIntentIfNeeded() {
    guard !wantsPlayback else { return }
    guard engine.isPlaying else {
      pauseRequestPending = false
      return
    }
    // VLC starts and pauses asynchronously. A pause during input opening must
    // be applied once playing is reported, but repeated updates must not send
    // another toggle-capable pause before the first pause is acknowledged.
    guard !pauseRequestPending else { return }
    pauseRequestPending = true
    engine.pause()
  }

  @discardableResult
  func togglePlayback() -> Bool {
    if endHandled, !recovering, nextItemTask == nil { return play() }
    return wantsPlayback ? pause() : play()
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
    guard !stopped, !authorizationFailed, !terminalFailure, !recovering else { return }
    navigationRevision &+= 1
    let upper = durationMilliseconds > 0 ? durationMilliseconds : Int64.max
    let target = min(max(milliseconds, 0), upper)
    if endHandled {
      replayCompletedPlayback(at: target, autoplay: false)
      return
    }
    currentTimeMilliseconds = target
    observedPosition = target
    stableMovementStartedAt = nil
    lastMovementAt = recoveryClock()
    engine.seek(to: target)
    enqueueProgressSave(isFinished: false)
  }

  @discardableResult
  func setDialogueBoost(_ mode: DialogueBoost) -> Bool {
    let result = engine.applyDialogueBoost(mode)
    guard result != .unavailable else {
      errorMessage = "Dialogue Boost is unavailable in this VLC installation."
      return false
    }
    PlaybackPreferencesStore.shared.preferences.dialogueBoost = mode
    if result == .reloadRequired { reopenForAudioChange() }
    return true
  }

  /// Opens the current title again at the same position, for example after Volume Leveling changed:
  /// the audio processing of a VLC player is fixed when it opens a title.
  func reopenForAudioChange() {
    guard !stopped, !authorizationFailed, !terminalFailure, !recovering, !endHandled,
      !isPreparing, activePlayback != nil, let url = playbackURL
    else { return }
    let position = currentTimeMilliseconds
    navigationRevision &+= 1
    resumePositionMilliseconds = position
    appliedResumePosition = position == 0
    observedPosition = position
    awaitingFirstMovement = true
    stableMovementStartedAt = nil
    lastMovementAt = recoveryClock()
    hasPreparedCurrentItem = true
    engine.trackScope = presentation.trackScope
    engine.load(url: url, startAt: position)
    openedAtResume = engine.opensAtStartPosition && position > 0
    engine.volume = volume
    engine.isMuted = isMuted
    engine.playbackRate = playbackRate
    if wantsPlayback { engine.play() }
  }

  /// A server on this Mac, reached over loopback.
  static func isLocalServer(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
  }

  /// Starts the preview relay beside the playing one without delaying playback; previews simply
  /// stay unavailable when it cannot start.
  private func startPreviewRelay(from sourceURL: URL) {
    stopPreviewRelay()
    guard let previewRelayFactory, let owner = relay,
      let preview = try? previewRelayFactory(sourceURL, client.profile.publicKeyFingerprint)
    else { return }
    previewRelay = preview
    previewRelayTask = Task { [weak self] in
      let url = try? await preview.start()
      guard let self, let url, !Task.isCancelled, self.previewRelay === preview,
        self.relay === owner
      else {
        preview.stop()
        return
      }
      self.previewSourceURL = url
    }
  }

  private func stopPreviewRelay() {
    previewRelayTask?.cancel()
    previewRelayTask = nil
    previewRelay?.stop()
    previewRelay = nil
    previewSourceURL = nil
  }

  func setVolume(_ value: Double) {
    volume = min(max(value, 0), 1)
    engine.volume = volume
    if volume > 0 { isMuted = false }
  }

  func setVideoFill(_ fills: Bool, size: CGSize) {
    engine.setVideoFill(fills, size: size)
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
    guard !stopped, !authorizationFailed, !terminalFailure, !recovering else { return }
    if endHandled {
      seek(to: chapter.timeOffsetMilliseconds)
      return
    }
    navigationRevision &+= 1
    currentTimeMilliseconds = chapter.timeOffsetMilliseconds
    observedPosition = currentTimeMilliseconds
    stableMovementStartedAt = nil
    lastMovementAt = recoveryClock()
    engine.selectChapter(index: chapter.index)
  }

  private func replayCompletedPlayback(at position: Int64, autoplay: Bool) {
    // A completed VLC input and its relay generation cannot be reused. Explicit
    // replay uses fresh authorization/load, but never competes with auto-next.
    guard endHandled, !recovering, nextItemTask == nil else { return }
    naturalEndReached = false
    currentTimeMilliseconds = position
    observedPosition = position
    lastMovementAt = recoveryClock()
    wantsPlayback = autoplay
    recoveryAttempt = 0
    incidentStartedAt = recoveryClock()
    incidentPausedAt = nil
    stableMovementStartedAt = nil
    opaqueTicketRetryUsed = false
    recoverPlayback(message: "Preparing playback…")
  }

  func setSleepTimer(_ timer: PlaybackSleepTimer) {
    sleepTask?.cancel()
    sleepTask = nil
    sleepTimer = timer
    guard case .minutes(let minutes) = timer else { return }
    if minutes <= 0 {
      pause()
      cancelRecoveryForSleep()
      engineUpdated()
      sleepTimer = .off
      enqueueProgressSave(isFinished: false)
      return
    }
    let sleep = sleepTimerSleep
    sleepTask = Task { [weak self] in
      do {
        try await sleep(TimeInterval(minutes * 60))
      } catch {
        return
      }
      guard !Task.isCancelled, let self else { return }
      self.pause()
      self.cancelRecoveryForSleep()
      self.engineUpdated()
      self.sleepTimer = .off
      self.enqueueProgressSave(isFinished: false)
      await self.client.sleepTimerEnded()
      self.sleepTimerFinished = true
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
    pauseRequestPending = false
    cancelPendingOperations()
    incidentStartedAt = nil
    incidentPausedAt = nil
    stableMovementStartedAt = nil
    awaitingFirstMovement = false
    awaitingRecoveryMovement = false
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

    showsStartScreen = false
    // Stop reads immediately; a slow progress save must not leave the player
    // or an old recovery task running after its window has closed.
    relay?.stop()
    relay = nil
    playbackURL = nil
    engine.stop()
    // Terminal callbacks are ignored once stopped. Publish the terminal state
    // explicitly, preserving the last position/duration for the progress save.
    isPlaying = false
    isPreparing = false
    activePlayback = nil
    let retiredIDs = playbackIDs
    playbackIDs.removeAll()

    if saveProgress {
      enqueueProgressSave(isFinished: naturalEndReached)
      await progressOutbox.flush()
    }
    await revokeTickets(retiredIDs)
    record(.stopped)
    if let progressObserver { progressOutbox.removeObserver(progressObserver) }
    progressObserver = nil
  }

  private func begin(
    _ source: PlaybackSourceResponse, resumeOverride: Int64? = nil
  ) async throws {
    guard !stopped, !Task.isCancelled else { throw CancellationError() }
    let relay: any PlaybackRelayProtocol
    let sourceURL: URL
    do {
      sourceURL = try client.streamURL(path: source.streamPath)
      relay = try relayFactory(sourceURL, client.profile.publicKeyFingerprint)
    } catch {
      await revokeTickets([source.id])
      throw PlaybackFailureContext(error: error, phase: .relayStartup)
    }
    let generation = UUID()
    loadID = generation
    relay.setFailureHandler { [weak self] failure in
      guard let self, self.loadID == generation else { return }
      self.streamFailed(failure)
    }
    // Own the preparing relay before suspending so shutdown/cancel reaches it.
    self.relay = relay
    let localURL: URL
    do {
      localURL = try await boundedOperation(
        seconds: min(timing.relayTimeout, remainingIncidentTime), phase: .relayStartup
      ) { try await relay.start() }
      guard !stopped, !Task.isCancelled, loadID == generation else {
        throw CancellationError()
      }
    } catch {
      relay.stop()
      if loadID == generation { self.relay = nil }
      await revokeTickets([source.id])
      throw PlaybackFailureContext(error: error, phase: .relayStartup)
    }
    self.relay = relay
    progressOutbox.noteBaseline(source.progress, profile: client.profile)
    progressOutbox.retryAfterPlaybackAuthorization(media: source.mediaId, profile: client.profile)
    activePlayback = source
    // Only a newly authorized source with a ready local relay can clear a
    // definitive authorization failure. A tentative retry alone cannot.
    authorizationFailed = false
    terminalFailure = false
    playbackIDs.insert(source.id)
    let calculated =
      resumeOverride
      ?? presentation.startIntent.position(
        progress: source.progress, automaticResume: preferences.automaticResume)
    let threshold = Int64(preferences.resumeThresholdSeconds) * 1_000
    resumePositionMilliseconds = calculated < threshold ? 0 : calculated
    appliedResumePosition = resumePositionMilliseconds == 0
    recovering = false
    recoveryMessage = nil
    errorMessage = nil
    endHandled = false
    naturalEndReached = false
    lastMovementAt = recoveryClock()
    preparedAt = lastMovementAt
    stableMovementStartedAt = nil
    awaitingFirstMovement = true
    awaitingRecoveryMovement = recoveryAttempt > 0
    observedPosition = resumePositionMilliseconds
    pauseRequestPending = false
    if queuedItems.first?.mediaId == presentation.mediaId {
      queuedItems.removeFirst()
      presentation = PlaybackPresentation(
        mediaId: presentation.mediaId, title: presentation.title,
        subtitle: presentation.subtitle, queue: queuedItems, previousItems: previousItems,
        startIntent: presentation.startIntent,
        trackScope: presentation.trackScope, artwork: presentation.artwork)
    }
    hasPreparedCurrentItem = true
    engine.trackScope = presentation.trackScope
    engine.load(url: localURL, startAt: resumePositionMilliseconds)
    openedAtResume = engine.opensAtStartPosition && resumePositionMilliseconds > 0
    playbackURL = localURL
    startPreviewRelay(from: sourceURL)
    Task { [weak self] in
      guard let self, let relay = self.relay else { return }
      if let tracks = try? await self.client.streamSubtitles(ticket: source.id) {
        for track in tracks where track.isSidecar && track.supported {
          if let subURL = relay.subtitleURL(index: track.index) {
            self.engine.addSubtitleSlave(url: subURL)
          }
        }
      }
    }
    engine.volume = volume
    engine.isMuted = isMuted
    engine.playbackRate = playbackRate
    if wantsPlayback { beginPlaybackActivityIfNeeded() }
    scheduleRenewal(for: source)
    if wantsPlayback {
      engine.play()
    } else {
      // Preparing a paused source must not briefly start its audio/video.
      isPlaying = false
      isPreparing = false
      incidentPausedAt = recoveryClock()
      engineUpdated()
    }
    scheduleWatchdog()
    record(.prepared, phase: .relayStartup)
  }

  private func engineUpdated() {
    guard !stopped, !authorizationFailed, !terminalFailure, !recovering, !endHandled else { return }
    applyPausedIntentIfNeeded()
    assignIfChanged(&isPlaying, wantsPlayback && engine.isPlaying)
    assignIfChanged(&isSeekable, engine.isSeekable)
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
    assignIfChanged(&isPreparing, wantsPlayback && durationMilliseconds <= 0 && !isPlaying)
    updateUpNext()

    // Buffering or an external decoder pause breaks continuous stable playback,
    // even if the next position notification arrives within the normal tick gap.
    if !wantsPlayback || !isPlaying { stableMovementStartedAt = nil }

    if !appliedResumePosition, durationMilliseconds > 0 {
      let target = min(resumePositionMilliseconds, durationMilliseconds)
      let reported = engine.currentTimeMilliseconds
      // An engine that opened at the resume position reports a clock near it; wait for that
      // first clock. Some containers ignore the start position, so a clock far from it still
      // seeks as before.
      if !(openedAtResume && reported == 0) {
        appliedResumePosition = true
        if !(openedAtResume && abs(reported - target) <= 5_000) { engine.seek(to: target) }
        currentTimeMilliseconds = target
      }
    }

    // A native seek is asynchronous: a final old-clock callback can arrive
    // after seek(to:) and briefly raise the observed position again. Re-anchor
    // when the decoder acknowledges the lower clock so actual advancing
    // playback is not mistaken for a stall. A pending initial/resume seek must
    // still prove forward movement beyond its requested position.
    if !awaitingFirstMovement, currentTimeMilliseconds < observedPosition - 250 {
      observedPosition = currentTimeMilliseconds
      stableMovementStartedAt = nil
      lastMovementAt = recoveryClock()
    }

    if currentTimeMilliseconds > observedPosition + 250 {
      let now = recoveryClock()
      if wantsPlayback, isPlaying {
        if awaitingFirstMovement {
          awaitingFirstMovement = false
          assignIfChanged(&showsStartScreen, false)
          if awaitingRecoveryMovement { record(.recovered, cause: recoveryCause, phase: .playback) }
          awaitingRecoveryMovement = false
        }
        if stableMovementStartedAt == nil || now.timeIntervalSince(lastMovementAt) > 2 {
          stableMovementStartedAt = now
        }
        if let stableMovementStartedAt,
          now.timeIntervalSince(stableMovementStartedAt) >= timing.stablePlayback
        {
          recoveryAttempt = 0
          incidentStartedAt = nil
          incidentPausedAt = nil
          recoveryCause = nil
          opaqueTicketRetryUsed = false
        }
      }
      observedPosition = currentTimeMilliseconds
      lastMovementAt = now
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
    guard !stopped, !authorizationFailed, !terminalFailure, !recovering, !endHandled else { return }
    // The UI may already display an unacknowledged seek target. Only the
    // engine's preserved actual clock can establish completion or a safe
    // retry position after a real input end.
    let position = max(0, engine.currentTimeMilliseconds)
    let duration = max(durationMilliseconds, engine.durationMilliseconds)
    guard PlaybackRecoveryPolicy.hasReachedEnd(position: position, duration: duration) else {
      currentTimeMilliseconds = position
      recoverPlayback(cause: .prematureEnd)
      return
    }
    endHandled = true
    naturalEndReached = true
    loadID = UUID()
    watchdogTask?.cancel()
    watchdogTask = nil
    isPlaying = false
    currentTimeMilliseconds = duration
    durationMilliseconds = duration
    showsStartScreen = false
    record(.ended)
    enqueueProgressSave(isFinished: true)
    upNext = nil
    if sleepTimer == .endOfEpisode {
      let client = client
      Task { await client.sleepTimerEnded() }
      sleepTimerFinished = true
    }
    guard sleepTimer != .endOfEpisode,
      preferences.automaticallyPlayNextEpisode,
      !autoplayCancelled,
      let next = queuedItems.first
    else {
      sleepTimer = .off
      endPlaybackActivity()
      return
    }
    nextItemTask = Task { [weak self] in await self?.advance(to: next) }
  }

  /// Manual navigation keeps the position being left; only a real input end marks it watched.
  func playNextNow() {
    guard canPlayNext, let next = queuedItems.first else { return }
    navigateNow(to: next, backwards: false)
  }

  /// An explicit Resume menu action keeps this player/window and the series queue alive.
  @discardableResult
  func resumeNextNow() -> Bool {
    guard canPlayNext, let next = queuedItems.first else { return false }
    navigateNow(to: next, backwards: false, intent: .resume)
    return true
  }

  private func navigateNow(
    to item: PlaybackQueueItem, backwards: Bool, intent: PlaybackStartIntent = .play
  ) {
    naturalEndReached = false
    endHandled = true
    loadID = UUID()
    watchdogTask?.cancel()
    watchdogTask = nil
    isPlaying = false
    upNext = nil
    record(.ended)
    enqueueProgressSave(isFinished: false)
    nextItemTask = Task { [weak self] in
      await self?.advance(to: item, backwards: backwards, intent: intent)
    }
  }

  /// Hides the Up Next card; the player then stops at the end instead of continuing.
  func dismissUpNext() {
    upNextDismissed = true
    autoplayCancelled = true
    upNext = nil
  }

  private func updateUpNext() {
    let next = queuedItems.first
    let leadMs = Int64(preferences.upNextCountdownSeconds) * 1_000
    let shown = UpNextPolicy.shows(
      position: currentTimeMilliseconds, duration: durationMilliseconds, hasNext: next != nil,
      autoplay: preferences.automaticallyPlayNextEpisode, stopsAtEnd: sleepTimer == .endOfEpisode,
      dismissed: upNextDismissed, lead: leadMs)
    let card = next.flatMap { next in
      shown
        ? PlaybackUpNext(
          title: next.title, subtitle: next.subtitle,
          seconds: UpNextPolicy.seconds(
            position: currentTimeMilliseconds, duration: durationMilliseconds))
        : nil
    }
    assignIfChanged(&upNext, card)
  }

  private func engineFailed(_ message: String) {
    guard !stopped, !authorizationFailed, !terminalFailure, !recovering, !endHandled else { return }
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

  private func advance(
    to item: PlaybackQueueItem, backwards: Bool = false, intent: PlaybackStartIntent = .play
  ) async {
    guard !stopped, !authorizationFailed, !Task.isCancelled else { return }
    let operation = lifecycleID
    loadID = UUID()
    defer {
      if lifecycleID == operation { nextItemTask = nil }
    }
    await progressOutbox.flush()
    guard !stopped, !authorizationFailed, !Task.isCancelled else { return }
    renewalTask?.cancel()
    renewalTask = nil
    endPlaybackActivity()
    relay?.stop()
    relay = nil
    playbackURL = nil
    engine.stop()
    await revokeTickets(playbackIDs)
    guard !stopped, !authorizationFailed, !Task.isCancelled else { return }
    playbackIDs.removeAll()
    activePlayback = nil
    let current = PlaybackQueueItem(
      mediaId: presentation.mediaId, title: presentation.title,
      subtitle: presentation.subtitle, artwork: presentation.artwork)
    if backwards {
      previousItems.removeLast()
      queuedItems.insert(current, at: 0)
    } else {
      previousItems.append(current)
    }
    presentation = PlaybackPresentation(
      mediaId: item.mediaId,
      title: item.title,
      subtitle: item.subtitle,
      queue: queuedItems, previousItems: previousItems, startIntent: intent,
      trackScope: presentation.trackScope, artwork: item.artwork)
    isPreparing = true
    showsStartScreen = true
    upNext = nil
    upNextDismissed = false
    autoplayCancelled = false
    incidentStartedAt = recoveryClock()
    incidentPausedAt = nil
    opaqueTicketRetryUsed = false
    stableMovementStartedAt = nil
    recoveryAttempt = 0
    hasPreparedCurrentItem = false
    currentTimeMilliseconds = 0
    durationMilliseconds = 0
    appliedResumePosition = false
    errorMessage = nil
    record(.nextEpisode)
    progressStateChanged()
    do {
      let source = try await requestPlaybackSource(mediaId: item.mediaId)
      guard !stopped, !authorizationFailed, !Task.isCancelled else {
        await revokeTickets([source.id])
        return
      }
      try await begin(source, resumeOverride: intent == .play ? 0 : nil)
    } catch {
      guard !stopped, !authorizationFailed, !Task.isCancelled else { return }
      let context = PlaybackFailureContext(error: error, phase: .ticketAuthorization)
      record(.failureObserved, cause: context.cause, context: context)
      if PlaybackRecoveryPolicy.isRecoverable(error) {
        recoverPlayback(context: context)
      } else {
        terminalFailure = true
        wantsPlayback = false
        recoveryCause = context.cause
        isPreparing = false
        errorMessage = "The episode could not start. \(context.cause.message)"
      }
    }
  }

  /// Whether this player keeps the Mac from sleeping now.
  var preventsSystemSleep: Bool { activityToken != nil }

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
    guard !stopped, !authorizationFailed, !terminalFailure, let old = activePlayback else { return }
    let generation = loadID
    var attempt = 0
    var notice: String?
    while !stopped && !authorizationFailed && !terminalFailure && !Task.isCancelled
      && loadID == generation && activePlayback?.id == old.id
    {
      do {
        let renewed = try await requestPlaybackSource(mediaId: presentation.mediaId, renewal: true)
        guard !stopped, !authorizationFailed, !terminalFailure, !Task.isCancelled,
          loadID == generation, activePlayback?.id == old.id
        else {
          await revokeTickets([renewed.id])
          return
        }
        let renewedURL: URL
        do {
          renewedURL = try client.streamURL(path: renewed.streamPath)
        } catch {
          await revokeTickets([renewed.id])
          throw error
        }
        relay?.updateSourceURL(renewedURL)
        previewRelay?.updateSourceURL(renewedURL)
        activePlayback = renewed
        playbackIDs.insert(renewed.id)
        await revokeTickets([old.id])
        playbackIDs.remove(old.id)
        guard !stopped, !authorizationFailed, !terminalFailure, !Task.isCancelled,
          loadID == generation, activePlayback?.id == renewed.id
        else { return }
        if let notice, errorMessage == notice { errorMessage = nil }
        scheduleRenewal(for: renewed)
        return
      } catch {
        guard !stopped, !authorizationFailed, !terminalFailure, !Task.isCancelled,
          loadID == generation, activePlayback?.id == old.id
        else { return }
        let context = PlaybackFailureContext(error: error, phase: .ticketRenewal)
        record(.failureObserved, cause: context.cause, context: context)
        let remaining =
          TicketRenewalPolicy.expiration(old.expiresAt)?.timeIntervalSince(renewalClock()) ?? 0
        if context.isRecoverable, remaining > 0, attempt < 12 {
          let proposed = (error as? APIClientError)?.retryDelay ?? min(30, pow(2, Double(attempt)))
          let delay = min(max(0.1, proposed), remaining)
          attempt += 1
          notice = "The connection was interrupted. Retrying playback authorization…"
          errorMessage = notice
          do { try await renewalSleep(delay) } catch { return }
          guard !stopped, !authorizationFailed, !terminalFailure, !Task.isCancelled,
            loadID == generation, activePlayback?.id == old.id
          else { return }
          guard let expiry = TicketRenewalPolicy.expiration(old.expiresAt), expiry > renewalClock()
          else {
            stopUnauthorizedPlayback(
              "The playback authorization expired while the server was unreachable.")
            return
          }
          continue
        }
        stopUnauthorizedPlayback(
          "The playback authorization could not be renewed. \(context.cause.message)",
          cause: context.cause)
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
    terminalFailure = true
    renewalTask?.cancel()
    renewalTask = nil
    cancelPendingOperations()
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
    playbackURL = nil
    engine.stop()
    isPlaying = false
    isPreparing = false
    endPlaybackActivity()
    errorMessage = message
  }

  private func streamFailed(_ failure: PlaybackStreamFailure) {
    guard !stopped, !authorizationFailed, !terminalFailure, !recovering, !endHandled else { return }
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
    case .detailed(let context):
      record(.failureObserved, cause: context.cause, context: context)
      if context.phase == .streamTransport, context.httpStatus == 404,
        context.problemCode == nil
      {
        guard !opaqueTicketRetryUsed else {
          stopUnauthorizedPlayback(context.cause.message, cause: context.cause)
          return
        }
        opaqueTicketRetryUsed = true
      }
      if context.isRecoverable {
        recoverPlayback(context: context)
      } else {
        stopUnauthorizedPlayback(context.cause.message, cause: context.cause)
      }
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
    guard !stopped, !authorizationFailed, !terminalFailure, !recovering, !endHandled, wantsPlayback,
      activePlayback != nil
    else { return }
    if remainingIncidentTime <= 0 {
      exhaustRecovery()
      return
    }
    if awaitingFirstMovement {
      guard recoveryClock().timeIntervalSince(preparedAt) >= timing.firstMovementTimeout else {
        return
      }
      record(.operationTimedOut, cause: .stalled, phase: .firstMovement)
    } else {
      guard recoveryClock().timeIntervalSince(lastMovementAt) >= 15 else { return }
    }
    recoverPlayback(cause: .stalled)
  }

  private func recoverPlayback(cause: PlaybackRecoveryCause) {
    recoveryCause = cause
    record(.recoveryStarted, cause: cause)
    recoverPlayback(message: cause.message)
  }

  private func recoverPlayback(context: PlaybackFailureContext) {
    recoveryCause = context.cause
    recoveryRetryAfter = context.retryAfter
    record(.recoveryStarted, cause: context.cause, context: context)
    recoverPlayback(message: context.cause.message)
  }

  private func recoverPlayback(message: String) {
    guard !stopped, !authorizationFailed, !terminalFailure, !recovering else { return }
    // Before authorization/relay setup there is no input clock to override the requested
    // Play/Resume intent. A chosen but unapplied resume position must survive an early failure.
    let position = preservedInputPosition
    if incidentStartedAt == nil { incidentStartedAt = recoveryClock() }
    incidentPausedAt = nil
    stableMovementStartedAt = nil
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
    playbackURL = nil
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
        guard self.remainingIncidentTime > 0 else { break }
        let delay = min(
          max(PlaybackRecoveryPolicy.delays[self.recoveryAttempt], self.recoveryRetryAfter ?? 0),
          self.remainingIncidentTime)
        self.recoveryRetryAfter = nil
        self.recoveryAttempt += 1
        self.record(.recoveryAttempt, cause: self.recoveryCause, attempt: self.recoveryAttempt)
        do { try await self.recoverySleep(delay) } catch { return }
        guard !Task.isCancelled, !self.stopped, self.lifecycleID == operation,
          self.recoveryID == recovery
        else { return }
        do {
          guard self.remainingIncidentTime > 0 else { break }
          let source = try await self.requestPlaybackSource(mediaId: self.presentation.mediaId)
          guard !Task.isCancelled, !self.stopped, self.lifecycleID == operation,
            self.recoveryID == recovery
          else {
            await self.revokeTickets([source.id])
            return
          }
          try await self.begin(source, resumeOverride: position)
          return
        } catch {
          guard !Task.isCancelled, !self.stopped, self.lifecycleID == operation,
            self.recoveryID == recovery
          else { return }
          let context = PlaybackFailureContext(error: error, phase: .ticketAuthorization)
          self.record(.failureObserved, cause: context.cause, context: context)
          self.recoveryCause = context.cause
          self.recoveryMessage = context.cause.message
          self.recoveryRetryAfter = context.retryAfter
          if !PlaybackRecoveryPolicy.isRecoverable(error) {
            if context.cause == .accessDenied || context.cause == .serverIdentityMismatch {
              self.stopUnauthorizedPlayback(
                context.cause.message, cause: context.cause)
              return
            }
            self.recovering = false
            self.terminalFailure = true
            self.wantsPlayback = false
            self.recoveryMessage = nil
            self.isPreparing = false
            self.errorMessage = context.cause.message
            self.endPlaybackActivity()
            return
          }
        }
      }
      self.exhaustRecovery()
    }
  }

  func cancelRecovery() {
    record(.recoveryCancelled, cause: recoveryCause)
    recoveryTask?.cancel()
    recoveryID = UUID()
    recoveryTask = nil
    recovering = false
    terminalFailure = true
    recoveryMessage = nil
    isPreparing = false
    wantsPlayback = false
    loadID = UUID()
    relay?.stop()
    relay = nil
    playbackURL = nil
    endPlaybackActivity()
    errorMessage = "Playback recovery stopped. Choose Try Again when the media is available."
  }

  private func cancelRecoveryForSleep() {
    if recovering { cancelRecovery() }
  }

  private var remainingIncidentTime: TimeInterval {
    guard let incidentStartedAt else { return timing.incidentTimeout }
    return max(
      0,
      timing.incidentTimeout
        - (incidentPausedAt ?? recoveryClock()).timeIntervalSince(incidentStartedAt))
  }

  private func exhaustRecovery() {
    terminalFailure = true
    recovering = false
    wantsPlayback = false
    awaitingFirstMovement = false
    awaitingRecoveryMovement = false
    recoveryID = UUID()
    loadID = UUID()
    recoveryTask?.cancel()
    recoveryTask = nil
    cancelPendingOperations()
    watchdogTask?.cancel()
    watchdogTask = nil
    renewalTask?.cancel()
    renewalTask = nil
    relay?.stop()
    relay = nil
    playbackURL = nil
    engine.stop()
    activePlayback = nil
    isPlaying = false
    recoveryMessage = nil
    isPreparing = false
    errorMessage =
      "Playback could not recover. Reconnect the media drive or check the server, then choose Try Again."
    endPlaybackActivity()
    record(.recoveryExhausted, cause: recoveryCause)
    let retired = playbackIDs
    playbackIDs.removeAll()
    let client = client
    Task { await Self.revokeTickets(retired, client: client) }
  }

  private func cancelPendingOperations() {
    let cancellations = Array(pendingOperations.values)
    pendingOperations.removeAll()
    for cancel in cancellations { cancel() }
  }

  private func requestPlaybackSource(mediaId: UUID, renewal: Bool = false) async throws
    -> PlaybackSourceResponse
  {
    let client = client
    return try await boundedOperation(
      seconds: renewal ? timing.ticketTimeout : min(timing.ticketTimeout, remainingIncidentTime),
      phase: renewal ? .ticketRenewal : .ticketAuthorization,
      onLateSuccess: { source in
        Task { await Self.revokeTickets([source.id], client: client) }
      },
      operation: { try await client.createPlayback(mediaId: mediaId) })
  }

  /// A task group waits for non-cooperative children on exit. This race instead
  /// resumes its caller at the deadline and quarantines/cleans any late result.
  private func boundedOperation<Value: Sendable>(
    seconds: TimeInterval, phase: PlaybackDiagnosticPhase,
    onLateSuccess: (@MainActor (Value) -> Void)? = nil,
    operation: @escaping @MainActor () async throws -> Value
  ) async throws -> Value {
    guard seconds > 0 else { throw PlaybackOperationError.timedOut(phase) }
    let completion = PlaybackOperationCompletion<Value>()
    let id = UUID()
    pendingOperations[id] = { completion.finish(.failure(CancellationError())) }
    defer { pendingOperations[id] = nil }
    let sleep = deadlineSleep
    do {
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          completion.continuation = continuation
          guard !Task.isCancelled else {
            completion.finish(.failure(CancellationError()))
            return
          }
          completion.operation = Task {
            do {
              let value = try await operation()
              if !completion.finish(.success(value)) { onLateSuccess?(value) }
            } catch {
              completion.finish(.failure(error))
            }
          }
          completion.timeout = Task {
            do { try await sleep(seconds) } catch { return }
            completion.finish(.failure(PlaybackOperationError.timedOut(phase)))
          }
        }
      } onCancel: {
        Task { @MainActor in completion.finish(.failure(CancellationError())) }
      }
    } catch {
      if error is PlaybackOperationError {
        record(.operationTimedOut, cause: .preparationTimedOut, phase: phase, error: error)
      }
      throw error
    }
  }

  private func revokeTickets(_ ids: Set<UUID>) async {
    await Self.revokeTickets(ids, client: client)
  }

  private static func revokeTickets(_ ids: Set<UUID>, client: any PlaybackClientProtocol) async {
    guard !ids.isEmpty else { return }
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

struct PlaybackTimingPolicy: Equatable {
  var ticketTimeout: TimeInterval = 15
  var relayTimeout: TimeInterval = 5
  var firstMovementTimeout: TimeInterval = 30
  var stablePlayback: TimeInterval = 10
  var incidentTimeout: TimeInterval = 120
}

@MainActor
private final class PlaybackOperationCompletion<Value: Sendable> {
  var continuation: CheckedContinuation<Value, Error>?
  var operation: Task<Void, Never>?
  var timeout: Task<Void, Never>?

  @discardableResult
  func finish(_ result: Result<Value, Error>) -> Bool {
    guard let continuation else { return false }
    self.continuation = nil
    operation?.cancel()
    timeout?.cancel()
    operation = nil
    timeout = nil
    continuation.resume(with: result)
    return true
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
    // A complete streamed input can naturally end with its public VLC clock
    // still about two seconds behind the duration after output draining. Accept
    // only a bounded final gap: at most 5% of a short clip (500 ms minimum),
    // capped at three seconds for longer media. Reported transport failures
    // are quarantined separately and cannot turn their late EOF into completion.
    duration > 0 && position >= max(1, duration - min(3_000, max(500, duration / 20)))
  }

  static func isRecoverable(_ error: Error) -> Bool {
    PlaybackFailureContext(error: error, phase: .ticketAuthorization).isRecoverable
  }
}

enum TicketRenewalPolicy {
  static func expiration(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  static func isTransient(_ error: Error) -> Bool {
    if error is PlaybackOperationError { return true }
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
