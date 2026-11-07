import AVFAudio
import Combine
import Foundation
import UIKit

@MainActor
final class TVPlaybackController: ObservableObject {
  enum TrackMenu: Equatable { case audio, subtitles, rate, sleep }

  let engine: any TVPlaybackEngine
  private let runtime: TVPlaybackRuntime
  @Published private(set) var isScrubbing = false
  @Published private(set) var title: String
  @Published private(set) var playbackRate: Double = 1
  @Published private(set) var sleepTimer: TVSleepTimer = .off
  @Published private(set) var audioSelectionPending = false
  @Published private(set) var subtitleSelectionPending = false
  @Published private(set) var isClosing = false
  @Published private(set) var canRetry = true
  @Published private(set) var isPlaying = false
  @Published private(set) var isLoading = true {
    didSet { if isLoading != oldValue { watchStateObserver?() } }
  }
  /// Watch Together listens here for play, pause and seek done on this Apple TV.
  var userActionObserver: (@MainActor (TVPlaybackUserAction) -> Void)?
  /// Watch Together listens here when the title opens, loads again or moves on.
  var watchStateObserver: (@MainActor () -> Void)?
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
  /// From Play until the picture moves, for each title: the player shows only a loading ring.
  @Published private(set) var isStarting = true
  /// While the timeline is scrubbed, the position the viewer is choosing; Select jumps there.
  @Published private(set) var scrubPosition: Int64?
  @Published private(set) var upNext: TVUpNext?
  /// A separate local relay for timeline previews; its reads are marked as previews, which
  /// the server counts apart from playback, and its failures never touch playback.
  @Published private(set) var previewSourceURL: URL?
  @Published private(set) var previewsParallel = false
  @Published private(set) var supportsServerScrubPreviews = false
  @Published private(set) var currentMediaID: UUID {
    didSet { if currentMediaID != oldValue { watchStateObserver?() } }
  }
  @Published var trackMenu: TrackMenu? {
    didSet { userInteracted() }
  }

  private let api: TVAPIClient
  private let connection: TVStoredConnection
  private let session: TVProfileSession
  private var mediaID: UUID
  /// The series whose episodes share audio and subtitle choices; nil for a movie.
  private let seriesID: UUID?
  private var queue: [TVCatalogItem]
  private var preferences: TVPlaybackPreferences
  private let preferencesStore: TVPlaybackPreferencesStore
  private var sleepTask: Task<Void, Never>?
  private var advanceTask: Task<Void, Never>?
  private var watchdogTask: Task<Void, Never>?
  private var audioSelectionTask: Task<Void, Never>?
  private var subtitleSelectionTask: Task<Void, Never>?
  private var audioSelectionID = UUID()
  private var subtitleSelectionID = UUID()
  private var watchdog = TVPlaybackWatchdog()
  private let scope: TVProgressScope
  private let onClose: @MainActor () -> Void
  private let onSessionFailure: @MainActor (Error) -> Void
  private let outbox: TVProgressOutbox
  private var relay: (any TVPlaybackRelay)?
  private var previewRelay: (any TVPlaybackRelay)?
  private var previewRelayTask: Task<Void, Never>?
  private var scrubRepeats = 0
  private var lastScrubAt: TimeInterval = 0
  private var upNextDismissed = false
  private var autoplayCancelled = false
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
  private var startOver: Bool
  private var quietSkipUntil: TimeInterval = 0
  private var backgroundSave: UIBackgroundTaskIdentifier = .invalid

  init(
    connection: TVStoredConnection, session: TVProfileSession, mediaID: UUID, title: String,
    outbox: TVProgressOutbox = .shared,
    api: TVAPIClient? = nil, runtime: TVPlaybackRuntime? = nil,
    queue: [TVCatalogItem] = [], seriesID: UUID? = nil,
    preferences: TVPlaybackPreferences? = nil,
    preferencesStore: TVPlaybackPreferencesStore? = nil,
    onClose: @escaping @MainActor () -> Void,
    onSessionFailure: @escaping @MainActor (Error) -> Void = { _ in },
    startOver: Bool = false
  ) {
    self.connection = connection
    self.session = session
    self.mediaID = mediaID
    self.currentMediaID = mediaID
    self.seriesID = seriesID
    self.queue = queue
    let store = preferencesStore ?? .shared
    self.preferencesStore = store
    self.preferences =
      (preferences
      ?? store.preferences(
        serverID: connection.serverID, profileID: session.user.id)).normalized
    self.title = title
    self.outbox = outbox
    self.onClose = onClose
    self.onSessionFailure = onSessionFailure
    self.startOver = startOver
    self.api = api ?? TVAPIClient(connection: connection, session: session)
    let selectedRuntime = runtime ?? .live()
    self.runtime = selectedRuntime
    engine = selectedRuntime.engine
    playbackRate = self.preferences.defaultPlaybackRate
    engine.applyPreferences(
      self.preferences.applying(
        seriesID.flatMap {
          store.seriesChoice(
            seriesID: $0, serverID: connection.serverID, profileID: session.user.id)
        }))
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
    Task { [weak self, api] in
      let features = (try? await api.capabilities())?.capabilities ?? []
      self?.previewsParallel = features.contains(TVScrubPreviewPlan.serverFeature)
      self?.supportsServerScrubPreviews = features.contains(
        TVScrubPreviewPlan.serverScrubPreviewsFeature)
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
    if scrubPosition != nil { commitScrub() }
    wantsPlayback.toggle()
    if !wantsPlayback { isStarting = false }
    if wantsPlayback { engine.play() } else { engine.pause() }
    userActionObserver?(wantsPlayback ? .play(position) : .pause(position))
    if !wantsPlayback { Task { await saveProgress(finished: false) } }
    userInteracted()
  }

  /// `revealControls: false` skips while the controls stay hidden, like the
  /// Apple TV player; the view shows only a brief position indicator.
  func seek(by offset: Int64, revealControls: Bool = true) {
    guard canSeek, !closed else { return }
    watchdog.noteSeek(at: ProcessInfo.processInfo.systemUptime)
    // Set before seeking: the engine reports the seek synchronously.
    if !revealControls { quietSkipUntil = ProcessInfo.processInfo.systemUptime + 2.5 }
    let target = TVPlayerPolicy.seekPosition(current: position, offset: offset, duration: duration)
    engine.seek(to: target)
    userActionObserver?(.seek(target))
    if revealControls { userInteracted() }
  }

  func seek(to milliseconds: Int64) {
    guard canSeek, !closed else { return }
    watchdog.noteSeek(at: ProcessInfo.processInfo.systemUptime)
    let target = TVPlayerPolicy.seekPosition(current: 0, offset: milliseconds, duration: duration)
    engine.seek(to: target)
    userActionObserver?(.seek(target))
    userInteracted()
  }

  func selectAudio(_ track: Int32) {
    guard !closed, let selected = audioTracks.first(where: { $0.id == track }) else { return }
    audioSelectionTask?.cancel()
    let request = UUID()
    audioSelectionID = request
    engine.selectAudioTrack(track)
    audioSelectionTask = confirmSelection(
      track: track, preference: selected.preference, audio: true, request: request)
    trackMenu = nil
    userInteracted()
  }

  func selectSubtitle(_ track: Int32) {
    guard !closed, track == -1 || subtitleTracks.contains(where: { $0.id == track }) else { return }
    subtitleSelectionTask?.cancel()
    let request = UUID()
    subtitleSelectionID = request
    let preference = subtitleTracks.first(where: { $0.id == track })?.preference
    engine.selectSubtitleTrack(track)
    subtitleSelectionTask = confirmSelection(
      track: track, preference: preference, audio: false, request: request)
    trackMenu = nil
    userInteracted()
  }

  private func confirmSelection(
    track: Int32, preference: TVPlaybackTrackPreference?, audio: Bool, request: UUID
  ) -> Task<Void, Never> {
    Task { [weak self] in
      let deadline = ContinuousClock.now.advanced(by: .milliseconds(2_500))
      while !Task.isCancelled {
        guard let self, !closed,
          request == (audio ? audioSelectionID : subtitleSelectionID)
        else { return }
        engine.sample()
        guard !closed else { return }
        let actual = audio ? engine.audioTrackID : engine.subtitleTrackID
        let pending = audio ? engine.audioSelectionPending : engine.subtitleSelectionPending
        if actual == track, !pending {
          if audio {
            preferences.preferredAudioTrack = preference
          } else {
            preferences.preferredSubtitleTrack = preference
          }
          persistPreferences()
          if let seriesID {
            preferencesStore.updateSeriesChoice(
              seriesID: seriesID, serverID: connection.serverID, profileID: session.user.id
            ) { choice in
              if audio {
                choice.audio = preference
              } else {
                choice.subtitle = preference
                choice.subtitleChosen = true
              }
            }
          }
          return
        }
        if ContinuousClock.now >= deadline {
          progressMessage =
            audio
            ? "The audio track could not be changed. Try another track."
            : "The subtitle track could not be changed. Try another track."
          return
        }
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
      }
    }
  }

  private func cancelTrackSelections() {
    audioSelectionTask?.cancel()
    subtitleSelectionTask?.cancel()
    audioSelectionTask = nil
    subtitleSelectionTask = nil
    audioSelectionID = UUID()
    subtitleSelectionID = UUID()
  }

  var seekInterval: Int64 { Int64(preferences.seekInterval) * 1_000 }
  var hasNextEpisode: Bool { !queue.isEmpty }

  func setPlaybackRate(_ rate: Double) {
    guard TVPlaybackPreferences.supportedRates.contains(rate), !closed else { return }
    engine.playbackRate = rate
    playbackRate = engine.playbackRate
    trackMenu = nil
    userInteracted()
  }

  func setSleepTimer(_ timer: TVSleepTimer) {
    sleepTask?.cancel()
    sleepTimer = timer
    trackMenu = nil
    if case .minutes(let minutes) = timer {
      sleepTask = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(Double(minutes) * 60)) } catch { return }
        guard let self, !closed else { return }
        wantsPlayback = false
        engine.pause()
        sleepTimer = .off
        await saveProgress(finished: false)
        userInteracted()
        // Servers before 1.8.2 do not know the signal; nothing else depends on it.
        try? await api.sleepTimerEnded()
      }
    }
    userInteracted()
  }

  var nightMode: Bool { preferences.nightMode }
  var dialogueBoost: DialogueBoost { preferences.dialogueBoost }
  var volumeLeveling: VolumeLeveling { preferences.volumeLeveling }

  func setNightMode(_ enabled: Bool) { setVolumeLeveling(enabled ? .standard : .off) }

  func setDialogueBoost(_ mode: DialogueBoost) {
    guard !closed, preferences.dialogueBoost != mode else { return }
    let result = engine.applyDialogueBoost(mode)
    guard result != .unavailable else {
      progressMessage = "Dialogue Boost is unavailable in this VLC installation."
      return
    }
    preferences.dialogueBoost = mode
    persistPreferences()
    trackMenu = nil
    if result == .reloadRequired, started, errorMessage == nil {
      recoveryBudget = TVPlaybackRecoveryBudget()
      recover(message: "Applying Dialogue Boost…")
    }
  }

  func setVolumeLeveling(_ mode: VolumeLeveling) {
    guard !closed, preferences.volumeLeveling != mode else { return }
    preferences.volumeLeveling = mode
    persistPreferences()
    trackMenu = nil
    guard started, errorMessage == nil else { return }
    recoveryBudget = TVPlaybackRecoveryBudget()
    recover(message: "Applying Volume Leveling…")
  }

  /// The profile's preferences with this series' own track choices.
  private var effectivePreferences: TVPlaybackPreferences {
    preferences.applying(
      seriesID.flatMap {
        preferencesStore.seriesChoice(
          seriesID: $0, serverID: connection.serverID, profileID: session.user.id)
      })
  }

  private func persistPreferences() {
    if !preferencesStore.save(
      preferences, serverID: connection.serverID, profileID: session.user.id)
    {
      progressMessage = "Playback preferences could not be saved on this Apple TV."
    }
  }

  func userInteracted() {
    guard !closed else { return }
    controlsVisible = true
    controlsTask?.cancel()
    guard mayHideControls else { return }
    let delay = preferences.controlsDelay
    controlsTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard let self, mayHideControls, !closed else { return }
      controlsVisible = false
    }
  }

  func setScrubbing(_ active: Bool) {
    isScrubbing = active
    userInteracted()
  }

  /// Moves the scrub position; quick repeated presses move further. Playback continues until
  /// Select jumps there.
  func scrub(forward: Bool) {
    guard canSeek, !closed else { return }
    let now = ProcessInfo.processInfo.systemUptime
    scrubRepeats = now - lastScrubAt < 0.45 ? scrubRepeats + 1 : 0
    lastScrubAt = now
    let step = TVPlayerPolicy.scrubStep(base: seekInterval, repeats: scrubRepeats)
    scrubPosition = TVPlayerPolicy.seekPosition(
      current: scrubPosition ?? position, offset: forward ? step : -step, duration: duration)
    userInteracted()
  }

  /// Jumps to the scrub position; false when nothing was being scrubbed.
  @discardableResult
  func commitScrub() -> Bool {
    guard let target = scrubPosition else { return false }
    scrubPosition = nil
    seek(to: target)
    return true
  }

  func cancelScrub() {
    guard scrubPosition != nil else { return }
    scrubPosition = nil
    userInteracted()
  }

  func fetchScrubPreviewFrame(mediaID: UUID, seconds: Int) async -> Data? {
    guard supportsServerScrubPreviews else { return nil }
    return try? await api.scrubPreviewFrame(mediaID: mediaID, seconds: seconds)
  }

  /// Starts the next episode now from the Up Next card.
  func playNextNow() {
    guard !closed, !finished, let next = queue.first else { return }
    finished = true
    upNext = nil
    advanceTask = Task { [weak self] in await self?.advance(to: next) }
  }

  /// Hides the Up Next card; the player then stops at the end instead of continuing.
  func dismissUpNext() {
    upNextDismissed = true
    autoplayCancelled = true
    upNext = nil
  }

  func back() {
    if scrubPosition != nil {
      cancelScrub()
    } else if upNext != nil, !controlsVisible {
      dismissUpNext()
    } else if trackMenu != nil {
      trackMenu = nil
      userInteracted()
    } else {
      close()
    }
  }

  func retry() {
    guard !closed, canRetry else { return }
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
    // its private local journal write, never for a network flush.
    let snapshot = currentSnapshot(finished: finished)
    // Sampling may synchronously observe EOF and close this player.
    guard !closed else { return }
    isClosing = true
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
    canRetry = true
    errorMessage = nil
    progressMessage = nil
    controlsVisible = true
    var unclaimedTicketID: UUID?
    var unclaimedRelay: (any TVPlaybackRelay)?
    defer {
      unclaimedRelay?.stop()
      if let id = unclaimedTicketID { Task { [api] in try? await api.revokeTicket(id: id) } }
    }
    do {
      _ = await outbox.flush(scope: scope, mediaID: mediaID, timeout: .seconds(2))
      guard !closed, operation == generation, !Task.isCancelled else { return }
      let created = try await api.createTicket(mediaID: mediaID)
      unclaimedTicketID = created.id
      guard !closed, operation == generation, !Task.isCancelled else { return }
      let url = try api.validatedStreamURL(path: created.streamPath)
      let secureRelay = try runtime.makeRelay(url, connection.fingerprint, session.token)
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
      startPreviewRelay(sourceURL: url)
      if let previous = ticket?.id { Task { [api] in try? await api.revokeTicket(id: previous) } }
      ticket = created
      unclaimedRelay = nil
      unclaimedTicketID = nil
      baselineRevision = created.progress.revision
      await outbox.noteBaseline(
        scope: scope, progress: created.progress, sessionID: session.sessionId)
      guard !closed, operation == generation, !Task.isCancelled else { return }
      if runtime.managesAudioSession {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try AVAudioSession.sharedInstance().setActive(true)
      }
      transportFailed = false
      finished = false
      let resolvedPosition = await outbox.resumePosition(scope: scope, server: created.progress)
      let conflict = await outbox.state(scope: scope, mediaID: mediaID) == .conflict
      guard !closed, operation == generation, !Task.isCancelled else { return }
      // Start Over applies once; later reconnects resume at the current position.
      let resumePosition = preferences.automaticResume && !startOver ? resolvedPosition : 0
      startOver = false
      if conflict {
        progressMessage = "Progress changed on another device. Its newer position has been kept."
      }
      let desiredRate = playbackRate
      engine.applyPreferences(effectivePreferences)
      engine.playbackRate = desiredRate
      engine.load(url: localURL, resumeAt: resumeAt ?? resumePosition, paused: !wantsPlayback)
      if let error = engine.audioProcessingError {
        fail(error)
        return
      }
      Task { [weak self, api] in
        guard let tracks = try? await api.streamSubtitles(ticketID: created.id) else { return }
        await MainActor.run {
          guard let self, !self.closed, self.generation == operation,
            self.relayGeneration == relayOperation
          else { return }
          for track in TVLiveSubtitleTrack.sidecarFiles(tracks) {
            if let subURL = secureRelay.subtitleURL(index: track.index) {
              self.engine.addSubtitleSlave(url: subURL)
            }
          }
        }
      }
      startWatchdog(operation: operation)
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
    let wasLoading = isLoading
    assignIfChanged(&isPlaying, engine.isPlaying)
    assignIfChanged(&isLoading, engine.isLoading)
    assignIfChanged(&position, engine.position)
    assignIfChanged(
      &duration,
      engine.duration > 0 ? engine.duration : (ticket?.progress.durationMilliseconds ?? 0))
    assignIfChanged(&canSeek, engine.isSeekable && duration > 0)
    assignIfChanged(&audioTracks, engine.audioTracks)
    assignIfChanged(&subtitleTracks, engine.subtitleTracks)
    assignIfChanged(&selectedAudio, engine.audioTrackID)
    assignIfChanged(&selectedSubtitle, engine.subtitleTrackID)
    assignIfChanged(&audioSelectionPending, engine.audioSelectionPending)
    assignIfChanged(&subtitleSelectionPending, engine.subtitleSelectionPending)
    assignIfChanged(&playbackRate, engine.playbackRate)
    if !wantsPlayback, isPlaying {
      engine.pause()
      return
    }
    // A skip with hidden controls briefly reports buffering; that alone must not
    // bring the controls back while the viewer keeps skipping.
    let quietSkip = wantsPlayback && ProcessInfo.processInfo.systemUptime < quietSkipUntil
    if quietSkip { return }
    if isStarting, engine.hasObservedPlayback {
      isStarting = false
      userInteracted()
    }
    updateUpNext()
    if wasPlaying != isPlaying || wasLoading != isLoading { userInteracted() }
    if !isPlaying { controlsVisible = true }
  }

  private func updateUpNext() {
    let next = queue.first
    let shown = TVPlayerPolicy.showsUpNext(
      position: position, duration: duration, hasNext: next?.isPlayable == true,
      autoplay: preferences.automaticallyPlayNextEpisode, stopsAtEnd: sleepTimer == .endOfEpisode,
      dismissed: upNextDismissed || finished)
    let card = next.flatMap { next in
      shown
        ? TVUpNext(
          title: next.episodeLabel.map { "\($0) · \(next.title)" } ?? next.title,
          seconds: TVPlayerPolicy.upNextSeconds(position: position, duration: duration))
        : nil
    }
    assignIfChanged(&upNext, card)
  }

  /// Starts the preview relay beside the playing one without delaying playback; previews
  /// simply stay unavailable when it cannot start.
  private func startPreviewRelay(sourceURL: URL) {
    stopPreviewRelay()
    guard
      let preview = try? runtime.makePreviewRelay?(
        sourceURL, connection.fingerprint, session.token)
    else { return }
    previewRelay = preview
    previewRelayTask = Task { [weak self] in
      let url = try? await preview.start()
      guard let self, let url, !Task.isCancelled, previewRelay === preview else {
        preview.stop()
        return
      }
      previewSourceURL = url
    }
  }

  private func stopPreviewRelay() {
    previewRelayTask?.cancel()
    previewRelayTask = nil
    previewRelay?.stop()
    previewRelay = nil
    previewSourceURL = nil
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
      upNext = nil
      if sleepTimer != .endOfEpisode, preferences.automaticallyPlayNextEpisode,
        !autoplayCancelled, let next = queue.first
      {
        advanceTask = Task { [weak self] in await self?.advance(to: next) }
      } else {
        if sleepTimer == .endOfEpisode {
          let api = api
          Task { try? await api.sleepTimerEnded() }
        }
        close()
      }
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
    guard !closed else { return }
    openingTask?.cancel()
    renewalTask?.cancel()
    watchdogTask?.cancel()
    cancelTrackSelections()
    relayGeneration = UUID()
    engine.stop()
    relay?.stop()
    relay = nil
    stopPreviewRelay()
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

  private func startWatchdog(operation: UUID) {
    watchdogTask?.cancel()
    watchdog.reset(at: ProcessInfo.processInfo.systemUptime)
    watchdogTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard let self, !closed, !finished, operation == generation, errorMessage == nil else {
          return
        }
        engine.sample()
        guard !closed, !finished, operation == generation else { return }
        if watchdog.shouldRecover(
          progressPosition: engine.progressPosition, wantsPlayback: wantsPlayback,
          interacting: trackMenu != nil || isScrubbing,
          at: ProcessInfo.processInfo.systemUptime)
        {
          recover(message: "The stream stopped responding. Reconnecting…")
          return
        }
      }
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
        previewRelay?.updateSourceURL(url)
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
    guard engine.isActive || finished else { return nil }
    engine.sample()
    guard let actualPosition = engine.progressPosition else { return nil }
    let knownDuration = max(engine.duration, duration)
    guard knownDuration > 0, actualPosition > 0 else { return nil }
    return TVProgressSnapshot(
      position: min(actualPosition, knownDuration), duration: knownDuration,
      finished: finished || self.finished)
  }

  private func assignIfChanged<Value: Equatable>(_ value: inout Value, _ updated: Value) {
    if value != updated { value = updated }
  }

  /// Watch Together moved to another title: it opens in this player; this title is not marked watched.
  func switchTitle(to item: TVCatalogItem) {
    Task { [weak self] in await self?.advance(to: item, markFinished: false) }
  }

  private func advance(to next: TVCatalogItem, markFinished: Bool = true) async {
    guard !closed else { return }
    await saveProgress(finished: markFinished)
    guard !closed, !Task.isCancelled else { return }
    _ = await outbox.flush(scope: scope, mediaID: mediaID, timeout: .seconds(2))
    guard !closed, !Task.isCancelled else { return }
    guard next.isPlayable else {
      fail(next.availabilityMessage ?? "The next episode is unavailable.", canRetry: false)
      return
    }
    renewalTask?.cancel()
    watchdogTask?.cancel()
    cancelTrackSelections()
    relayGeneration = UUID()
    engine.stop()
    relay?.stop()
    relay = nil
    stopPreviewRelay()
    if let id = ticket?.id { Task { [api] in try? await api.revokeTicket(id: id) } }
    ticket = nil
    if queue.first?.id == next.id { queue.removeFirst() }
    mediaID = next.id
    currentMediaID = next.id
    isStarting = true
    scrubPosition = nil
    upNext = nil
    upNextDismissed = false
    autoplayCancelled = false
    title = next.parentTitle.map { "\($0) · \(next.episodeLabel ?? next.title)" } ?? next.title
    baselineRevision = nil
    position = 0
    duration = 0
    finished = false
    isScrubbing = false
    recoveryBudget = TVPlaybackRecoveryBudget()
    generation = UUID()
    await open(resumeAt: nil, operation: generation)
  }

  private func saveProgress(finished: Bool) async {
    guard !closed, let snapshot = currentSnapshot(finished: finished), !closed else { return }
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

  private func fail(_ message: String, canRetry: Bool = true) {
    let snapshot = currentSnapshot(finished: false)
    guard !closed else { return }
    self.canRetry = canRetry
    if let snapshot {
      Task { [outbox, scope, mediaID, baselineRevision, session] in
        _ = await outbox.enqueue(
          scope: scope, mediaID: mediaID, snapshot: snapshot,
          baselineRevision: baselineRevision, sessionID: session.sessionId)
      }
    }
    openingTask?.cancel()
    renewalTask?.cancel()
    watchdogTask?.cancel()
    cancelTrackSelections()
    relayGeneration = UUID()
    engine.stop()
    relay?.stop()
    relay = nil
    stopPreviewRelay()
    if let id = ticket?.id { Task { [api] in try? await api.revokeTicket(id: id) } }
    ticket = nil
    if runtime.managesAudioSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    isLoading = false
    isPlaying = false
    isStarting = false
    scrubPosition = nil
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
      // Timeline focus alone does not pin the controls: every skip restarts the
      // auto-hide delay, and an idle timeline hides like the transport buttons.
      interacting: scrubPosition != nil, loading: isLoading, hasError: errorMessage != nil)
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
    sleepTask?.cancel()
    advanceTask?.cancel()
    watchdogTask?.cancel()
    cancelTrackSelections()
    progressTask?.cancel()
    controlsTask?.cancel()
    relayGeneration = UUID()
    engine.stop()
    relay?.stop()
    relay = nil
    stopPreviewRelay()
    engine.onUpdate = nil
    engine.onTerminal = nil
    if runtime.managesAudioSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }
}

struct TVUpNext: Equatable {
  let title: String
  let seconds: Int
}

/// Watch Together drives the Apple TV player through these, without showing the controls.
extension TVPlaybackController: TVWatchTogetherPlayer {
  var watchMediaID: UUID { currentMediaID }
  var watchPosition: Int64 { position }
  var watchIsPlaying: Bool { isPlaying }
  var watchIsReady: Bool { !isLoading && canSeek && errorMessage == nil && !closed }

  func watchPlay() {
    guard !closed, errorMessage == nil, !wantsPlayback else { return }
    wantsPlayback = true
    engine.play()
  }

  func watchPause() {
    guard !closed, wantsPlayback else { return }
    wantsPlayback = false
    isStarting = false
    engine.pause()
  }

  func watchSeek(to milliseconds: Int64) {
    guard canSeek, !closed else { return }
    watchdog.noteSeek(at: ProcessInfo.processInfo.systemUptime)
    engine.seek(to: TVPlayerPolicy.seekPosition(current: 0, offset: milliseconds, duration: duration))
  }
}
