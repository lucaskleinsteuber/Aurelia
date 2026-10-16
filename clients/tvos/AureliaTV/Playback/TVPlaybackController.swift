import AVFAudio
import Combine
import Foundation
import UIKit

@MainActor
final class TVPlaybackController: ObservableObject {
  enum TrackMenu: Equatable { case audio, subtitles }

  let engine = TVVideoEngine()
  let title: String
  @Published private(set) var isPlaying = false
  @Published private(set) var isLoading = true
  @Published private(set) var position: Int64 = 0
  @Published private(set) var duration: Int64 = 0
  @Published private(set) var canSeek = false
  @Published private(set) var audioTracks: [TVPlaybackTrack] = []
  @Published private(set) var subtitleTracks: [TVPlaybackTrack] = []
  @Published private(set) var selectedAudio: Int32 = -1
  @Published private(set) var selectedSubtitle: Int32 = -1
  @Published private(set) var errorMessage: String?
  @Published private(set) var progressMessage: String?
  @Published private(set) var controlsVisible = true
  @Published var trackMenu: TrackMenu? {
    didSet { userInteracted() }
  }

  private let api: TVAPIClient
  private let connection: TVStoredConnection
  private let session: TVProfileSession
  private let mediaID: UUID
  private let scope: TVProgressScope
  private let onClose: @MainActor () -> Void
  private let onSessionFailure: @MainActor (Error) -> Void
  private let outbox: TVProgressOutbox
  private var relay: TVStreamRelay?
  private var ticket: TVPlaybackTicket?
  private var baselineRevision: Int64?
  private var openingTask: Task<Void, Never>?
  private var renewalTask: Task<Void, Never>?
  private var progressTask: Task<Void, Never>?
  private var controlsTask: Task<Void, Never>?
  private var generation = UUID()
  private var relayGeneration = UUID()
  private var closed = false
  private var started = false
  private var transportFailed = false
  private var finished = false
  private var recoveryBudget = TVPlaybackRecoveryBudget()
  private var wantsPlayback = true
  private var backgroundSave: UIBackgroundTaskIdentifier = .invalid

  init(
    connection: TVStoredConnection, session: TVProfileSession, mediaID: UUID, title: String,
    outbox: TVProgressOutbox = .shared,
    onClose: @escaping @MainActor () -> Void,
    onSessionFailure: @escaping @MainActor (Error) -> Void = { _ in }
  ) {
    self.connection = connection
    self.session = session
    self.mediaID = mediaID
    self.title = title
    self.outbox = outbox
    self.onClose = onClose
    self.onSessionFailure = onSessionFailure
    api = TVAPIClient(connection: connection, session: session)
    scope = TVProgressScope(connection: connection, session: session)
    engine.onUpdate = { [weak self] in self?.updateFromEngine() }
    engine.onTerminal = { [weak self] terminal in self?.engineTerminated(terminal) }
  }

  func start() {
    guard !started, !closed else { return }
    started = true
    let operation = generation
    openingTask = Task { [weak self] in
      guard let self else { return }
      guard !Task.isCancelled, operation == generation, !closed else { return }
      await open(resumeAt: nil, operation: operation)
    }
    progressTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(TVPlayerPolicy.progressInterval)) } catch { return }
        guard let self, !closed else { return }
        await saveProgress(finished: false)
      }
    }
  }

  func togglePlayPause() {
    guard !closed, errorMessage == nil else { return }
    wantsPlayback.toggle()
    if wantsPlayback { engine.play() } else { engine.pause() }
    if !wantsPlayback { Task { await saveProgress(finished: false) } }
    userInteracted()
  }

  func seek(by offset: Int64) {
    guard canSeek, !closed else { return }
    engine.seek(
      to: TVPlayerPolicy.seekPosition(current: position, offset: offset, duration: duration))
    userInteracted()
  }

  func seek(to milliseconds: Int64) {
    guard canSeek, !closed else { return }
    engine.seek(
      to: TVPlayerPolicy.seekPosition(current: 0, offset: milliseconds, duration: duration))
    userInteracted()
  }

  func selectAudio(_ track: Int32) {
    engine.selectAudioTrack(track)
    trackMenu = nil
    userInteracted()
  }

  func selectSubtitle(_ track: Int32) {
    engine.selectSubtitleTrack(track)
    trackMenu = nil
    userInteracted()
  }

  func userInteracted() {
    guard !closed else { return }
    controlsVisible = true
    controlsTask?.cancel()
    guard mayHideControls else { return }
    controlsTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(TVPlayerPolicy.controlsDelay)) } catch { return }
      guard let self, mayHideControls, !closed else { return }
      controlsVisible = false
    }
  }

  func back() {
    if trackMenu != nil {
      trackMenu = nil
      userInteracted()
    } else {
      close()
    }
  }

  func retry() {
    guard !closed else { return }
    recoveryBudget = TVPlaybackRecoveryBudget()
    wantsPlayback = true
    recover(message: "Reconnecting…")
  }

  func background() {
    guard !closed else { return }
    backgroundSave = UIApplication.shared.beginBackgroundTask(withName: "Save Aurelia progress") {
      [weak self] in
      self?.endBackgroundSave()
    }
    close()
  }

  func close() {
    guard !closed else { return }
    // Capture while the engine still owns the input. Queueing only waits for
    // its private atomic file write, never for a network flush.
    let snapshot = currentSnapshot(finished: finished)
    closed = true
    generation = UUID()
    stopResources()
    let ticketID = ticket?.id
    ticket = nil
    let api = api
    let scope = scope
    let mediaID = mediaID
    let revision = baselineRevision
    let outbox = outbox
    let sessionID = session.sessionId
    Task { [onClose] in
      if let snapshot {
        _ = await outbox.enqueue(
          scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: revision,
          sessionID: sessionID)
      }
      if let ticketID { Task { try? await api.revokeTicket(id: ticketID) } }
      self.endBackgroundSave()
      onClose()
    }
  }

  private func open(resumeAt: Int64?, operation: UUID) async {
    isLoading = true
    errorMessage = nil
    progressMessage = nil
    controlsVisible = true
    var unclaimedTicketID: UUID?
    var unclaimedRelay: TVStreamRelay?
    defer {
      unclaimedRelay?.stop()
      if let id = unclaimedTicketID { Task { [api] in try? await api.revokeTicket(id: id) } }
    }
    do {
      let created = try await api.createTicket(mediaID: mediaID)
      unclaimedTicketID = created.id
      guard !closed, operation == generation, !Task.isCancelled else { return }
      let url = try api.validatedStreamURL(path: created.streamPath)
      let secureRelay = try TVStreamRelay(
        sourceURL: url,
        publicKeyFingerprint: connection.fingerprint, authorizationToken: session.token)
      unclaimedRelay = secureRelay
      let localURL = try await secureRelay.start()
      guard !closed, operation == generation, !Task.isCancelled else { return }
      let relayOperation = UUID()
      relayGeneration = relayOperation
      secureRelay.setFailureHandler { [weak self] failure in
        guard let self, !closed, operation == generation, relayOperation == relayGeneration else {
          return
        }
        handleRelayFailure(failure)
      }
      relay?.stop()
      relay = secureRelay
      if let previous = ticket?.id { Task { [api] in try? await api.revokeTicket(id: previous) } }
      ticket = created
      unclaimedRelay = nil
      unclaimedTicketID = nil
      baselineRevision = created.progress.revision
      await outbox.noteBaseline(
        scope: scope, progress: created.progress, sessionID: session.sessionId)
      guard !closed, operation == generation, !Task.isCancelled else { return }
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
      try AVAudioSession.sharedInstance().setActive(true)
      transportFailed = false
      finished = false
      engine.load(
        url: localURL, resumeAt: resumeAt ?? TVPlayerPolicy.resumePosition(created.progress))
      scheduleRenewal(created, operation: operation)
      userInteracted()
    } catch {
      guard !closed, operation == generation, !Task.isCancelled else { return }
      if let core = error as? TVCoreError, core.isAuthenticationFailure || core == .identityMismatch
      {
        sessionFailed(core)
      } else if (error as? TVCoreError)?.isTransient == true || error is URLError {
        recover(message: "Reconnecting…")
      } else {
        fail("This title could not be opened. Try again or return to the library.")
      }
    }
  }

  private func updateFromEngine() {
    guard !closed else { return }
    let wasPlaying = isPlaying
    isPlaying = engine.isPlaying
    isLoading = engine.isLoading
    position = engine.position
    duration = engine.duration > 0 ? engine.duration : (ticket?.progress.durationMilliseconds ?? 0)
    canSeek = engine.isSeekable && duration > 0
    audioTracks = engine.audioTracks
    subtitleTracks = engine.subtitleTracks
    selectedAudio = engine.audioTrackID
    selectedSubtitle = engine.subtitleTrackID
    if !wantsPlayback, isPlaying {
      engine.pause()
      return
    }
    if wasPlaying != isPlaying { userInteracted() }
    if !isPlaying { controlsVisible = true }
  }

  private func engineTerminated(_ terminal: TVVideoEngine.Terminal) {
    guard !closed, !finished else { return }
    updateFromEngine()
    if terminal == .ended,
      TVPlayerPolicy.isNaturalCompletion(
        position: position, duration: duration,
        observedPlayback: engine.hasObservedPlayback, transportFailed: transportFailed)
    {
      finished = true
      close()
    } else {
      recover(message: "The stream was interrupted. Reconnecting…")
    }
  }

  private func handleRelayFailure(_ failure: TVStreamFailure) {
    transportFailed = true
    switch failure {
    case .untrustedServer:
      sessionFailed(TVCoreError.identityMismatch)
    case .server(let status, let code) where status == 401 || status == 403:
      sessionFailed(TVCoreError.server(status: status, code: code, message: nil, retryAfter: nil))
    case .authorizationDenied:
      sessionFailed(TVCoreError.profileRequired)
    case .unavailable:
      fail("Media file unavailable.")
    case .invalidResponse:
      fail("The server returned an invalid media stream.")
    default:
      recover(message: "The stream was interrupted. Reconnecting…")
    }
  }

  private func recover(message: String) {
    guard !closed else { return }
    guard let delay = recoveryBudget.takeAttempt() else {
      fail("Playback could not reconnect. Try again or return to the library.")
      return
    }
    let resume = max(position, engine.position)
    let snapshot = currentSnapshot(finished: false)
    openingTask?.cancel()
    renewalTask?.cancel()
    relayGeneration = UUID()
    engine.stop()
    relay?.stop()
    relay = nil
    isPlaying = false
    isLoading = true
    errorMessage = nil
    progressMessage = message
    controlsVisible = true
    let operation = generation
    openingTask = Task { [weak self] in
      guard let self else { return }
      if let snapshot {
        _ = await outbox.enqueue(
          scope: scope, mediaID: mediaID, snapshot: snapshot,
          baselineRevision: baselineRevision, sessionID: session.sessionId)
      }
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard !closed, operation == generation else { return }
      await open(resumeAt: resume, operation: operation)
    }
  }

  private func scheduleRenewal(_ current: TVPlaybackTicket, operation: UUID) {
    renewalTask?.cancel()
    guard let expiry = TVPlayerPolicy.expiry(current.expiresAt) else { return }
    renewalTask = Task { [weak self] in
      do {
        try await Task.sleep(
          for: .seconds(TVPlayerPolicy.renewalDelay(expiresAt: expiry, now: Date())))
      } catch { return }
      guard let self, !closed, operation == generation else { return }
      do {
        let renewed = try await api.createTicket(mediaID: mediaID)
        guard !closed, operation == generation, !Task.isCancelled else {
          Task { [api] in try? await api.revokeTicket(id: renewed.id) }
          return
        }
        let url = try api.validatedStreamURL(path: renewed.streamPath)
        relay?.updateSourceURL(url)
        ticket = renewed
        Task { [api] in try? await api.revokeTicket(id: current.id) }
        scheduleRenewal(renewed, operation: operation)
      } catch {
        guard !closed, operation == generation, !Task.isCancelled else { return }
        if let apiError = error as? TVCoreError,
          apiError.isAuthenticationFailure || apiError == .identityMismatch
        {
          sessionFailed(apiError)
        } else {
          recover(message: "Refreshing playback access…")
        }
      }
    }
  }

  private func currentSnapshot(finished: Bool) -> TVProgressSnapshot? {
    guard engine.isActive else { return nil }
    let observed = engine.hasObservedPlayback
    let actualPosition = max(0, engine.position)
    let knownDuration = max(engine.duration, duration)
    guard observed, knownDuration > 0, actualPosition > 0 else { return nil }
    return TVProgressSnapshot(
      position: min(actualPosition, knownDuration), duration: knownDuration, finished: finished)
  }

  private func saveProgress(finished: Bool) async {
    guard !closed, let snapshot = currentSnapshot(finished: finished) else { return }
    let saved = await outbox.enqueue(
      scope: scope, mediaID: mediaID, snapshot: snapshot,
      baselineRevision: baselineRevision, sessionID: session.sessionId)
    guard !closed else { return }
    if !saved {
      progressMessage = "Playback progress could not be saved on this Apple TV."
    } else {
      let state = await outbox.state(scope: scope, mediaID: mediaID)
      guard !closed else { return }
      switch state {
      case .conflict:
        progressMessage = "Progress changed on another device. Its newer position has been kept."
      case .unavailable:
        progressMessage = "Playback progress could not be saved on the server."
      case .accessDenied:
        progressMessage = "Unlock your profile again to save playback progress."
      default:
        if errorMessage == nil { progressMessage = nil }
      }
    }
  }

  private func fail(_ message: String) {
    let snapshot = currentSnapshot(finished: false)
    if let snapshot {
      Task { [outbox, scope, mediaID, baselineRevision, session] in
        _ = await outbox.enqueue(
          scope: scope, mediaID: mediaID, snapshot: snapshot,
          baselineRevision: baselineRevision, sessionID: session.sessionId)
      }
    }
    openingTask?.cancel()
    renewalTask?.cancel()
    relayGeneration = UUID()
    engine.stop()
    relay?.stop()
    relay = nil
    if let id = ticket?.id { Task { [api] in try? await api.revokeTicket(id: id) } }
    ticket = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    isLoading = false
    isPlaying = false
    errorMessage = message
    progressMessage = nil
    controlsVisible = true
  }

  private func sessionFailed(_ error: Error) {
    guard !closed else { return }
    close()
    onSessionFailure(error)
  }

  private var mayHideControls: Bool {
    TVPlayerPolicy.mayHideControls(
      playing: isPlaying, menuOpen: trackMenu != nil,
      interacting: false, loading: isLoading, hasError: errorMessage != nil)
  }

  private func endBackgroundSave() {
    guard backgroundSave != .invalid else { return }
    let task = backgroundSave
    backgroundSave = .invalid
    UIApplication.shared.endBackgroundTask(task)
  }

  private func stopResources() {
    openingTask?.cancel()
    renewalTask?.cancel()
    progressTask?.cancel()
    controlsTask?.cancel()
    relayGeneration = UUID()
    engine.stop()
    relay?.stop()
    relay = nil
    engine.onUpdate = nil
    engine.onTerminal = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}
