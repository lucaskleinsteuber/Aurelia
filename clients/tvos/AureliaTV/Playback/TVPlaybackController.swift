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
  /// "Skip Intro" is offered while the episode's intro plays (times from the server).
  @Published private(set) var showsSkipIntro = false
  /// The server's suggestions after a movie or a series' last episode, best first.
  @Published private(set) var suggestions: [TVMediaSuggestion] = []
  /// The suggestion card from the credits on, without a countdown.
  @Published private(set) var showsSuggestion = false
  /// The end screen with the suggestion and two more, once the file ended.
  @Published private(set) var showsSuggestionEndScreen = false
  /// Set when the suggestion should start: Watch Now, or Play Suggestions Automatically at the end.
  @Published private(set) var suggestionToStart: TVCatalogItem?
  /// A children's profile's screen time, from the ticket and then every minute (docs/SCREEN_TIME.md).
  @Published private(set) var screenTime: TVScreenTimeStatus?
  /// Screen time is over: the good-night screen shows instead of the next title or an error.
  @Published private(set) var showsGoodNight = false
  private var lastScreenTimeCheck = Date()
  private var screenTimeTask: Task<Void, Never>?
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
  /// Whether the server streams in several qualities, so the streaming quality setting applies.
  private let adaptiveStreaming: Bool
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
  private let supportsSuggestions: Bool
  private var suggestionsRequested = false
  private var suggestionDismissed = false
  /// Where the card appeared in the credits; its countdown runs from there.
  private var creditsAnchor: Int64?
  private var introSkipped = false
  private var movedIntoIntro = false
  /// Back over Skip Intro: the intro plays and the button stays away for this episode.
  private var introDeclined = false
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
    adaptiveStreaming: Bool = false,
    supportsSuggestions: Bool = false,
    onClose: @escaping @MainActor () -> Void,
    onSessionFailure: @escaping @MainActor (Error) -> Void = { _ in },
    startOver: Bool = false
  ) {
    self.adaptiveStreaming = adaptiveStreaming
    self.supportsSuggestions = supportsSuggestions
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

  /// Cinema mode's pre-show before this title, or nil when it gets none: only a film (no series
  /// queue) on a live player, with cinema mode on and nobody watching along. The server says
  /// whether the title is a film by listing trailers for it.
  func cinemaPreShow(capabilities: [String], watchingTogether: Bool) async -> TVCinemaPreShow? {
    guard runtime.managesAudioSession, !started, !closed,
      TVCinemaPlan.wanted(
        preferences: preferences, isEpisode: seriesID != nil || !queue.isEmpty,
        capabilities: capabilities, watchingTogether: watchingTogether)
    else { return nil }
    return await TVCinemaPreShow.prepare(
      api: api, film: mediaID, title: title, preferences: preferences, startOver: startOver,
      fingerprint: connection.fingerprint, token: session.token)
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
    noteMove(to: target)
    engine.seek(to: target)
    userActionObserver?(.seek(target))
    if revealControls { userInteracted() }
  }

  /// Moving into the intro by hand means it should play; it is not skipped automatically then.
  private func noteMove(to target: Int64) {
    if let intro = currentSegments?.intro, target >= intro.start, target < intro.end {
      movedIntoIntro = true
    }
  }

  /// The intro and credits times of the title that is playing.
  private var currentSegments: TVMediaSegments? {
    guard let ticket, ticket.mediaId == currentMediaID else { return nil }
    return ticket.segments
  }

  private var creditsStart: Int64? {
    preferences.upNextAtCredits ? currentSegments?.creditsStartMilliseconds : nil
  }

  /// Jumps to the end of the intro; Watch Together follows like any other seek.
  func skipIntro() {
    guard showsSkipIntro, let intro = currentSegments?.intro, canSeek, !closed else { return }
    introSkipped = true
    showsSkipIntro = false
    watchdog.noteSeek(at: ProcessInfo.processInfo.systemUptime)
    engine.seek(to: intro.end)
    userActionObserver?(.seek(intro.end))
  }

  private func updateSkipIntro() {
    guard preferences.introSkipping != .off, let intro = currentSegments?.intro, !isStarting,
      !finished, duration <= 0 || intro.end <= duration
    else {
      assignIfChanged(&showsSkipIntro, false)
      return
    }
    let shown = TVPlayerPolicy.showsSkipIntro(
      position: position, introStart: intro.start, introEnd: intro.end)
    if isPlaying,
      TVPlayerPolicy.skipsIntroAutomatically(
        setting: preferences.introSkipping, alreadySkipped: introSkipped,
        movedIntoIntro: movedIntoIntro, buttonShown: shown)
    {
      introSkipped = true
      assignIfChanged(&showsSkipIntro, false)
      watchdog.noteSeek(at: ProcessInfo.processInfo.systemUptime)
      engine.seek(to: intro.end)
      userActionObserver?(.seek(intro.end))
      return
    }
    assignIfChanged(&showsSkipIntro, shown && upNext == nil && !introDeclined)
  }

  func seek(to milliseconds: Int64) {
    guard canSeek, !closed else { return }
    watchdog.noteSeek(at: ProcessInfo.processInfo.systemUptime)
    let target = TVPlayerPolicy.seekPosition(current: 0, offset: milliseconds, duration: duration)
    noteMove(to: target)
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
    var value = preferences.applying(
      seriesID.flatMap {
        preferencesStore.seriesChoice(
          seriesID: $0, serverID: connection.serverID, profileID: session.user.id)
      })
    value.streamingQuality = value.streamingQuality.effective(serverSupports: adaptiveStreaming)
    return value
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

  /// Starts the next episode now from the Up Next card. From the credits on (or while the card
  /// shows) this episode counts as watched; earlier its position is kept.
  func playNextNow() {
    guard !closed, !finished, let next = queue.first else { return }
    let markFinished = TVPlayerPolicy.nextFinishesCurrent(
      position: position, duration: duration, upNextShown: upNext != nil,
      creditsStart: creditsStart)
    finished = true
    upNext = nil
    showsSkipIntro = false
    advanceTask = Task { [weak self] in await self?.advance(to: next, markFinished: markFinished) }
  }

  /// Hides the Up Next card. Cancel in the last seconds stops the player at the end; Watch
  /// Credits (the card that appeared with the credits) plays them, then the next episode follows.
  func dismissUpNext() {
    upNextDismissed = true
    if upNext?.duringCredits != true { autoplayCancelled = true }
    creditsAnchor = nil
    upNext = nil
  }

  /// Watch Credits on the suggestion card: the credits play, then the end screen follows.
  func dismissSuggestion() {
    suggestionDismissed = true
    showsSuggestion = false
  }

  /// Watch Now: this title counts as watched from its credits on; the app plays the suggestion
  /// the way Home plays anything.
  func playSuggestion(_ item: TVCatalogItem) {
    finishForSuggestion()
    suggestionToStart = item
  }

  /// Done, or leaving for a suggestion: from the credits on the title counts as watched.
  func finishForSuggestion() {
    if TVPlayerPolicy.nextFinishesCurrent(
      position: position, duration: duration,
      upNextShown: showsSuggestion || showsSuggestionEndScreen,
      creditsStart: currentSegments?.creditsStartMilliseconds)
    {
      finished = true
    }
  }

  func doneWithSuggestions() {
    finishForSuggestion()
    close()
  }

  private func updateSuggestion() {
    let hasNext = queue.first?.isPlayable == true
    if supportsSuggestions, !suggestionsRequested,
      TVPlayerPolicy.wantsSuggestions(position: position, duration: duration, hasNext: hasNext)
    {
      suggestionsRequested = true
      let api = api
      let media = mediaID
      Task { [weak self] in
        guard let list = try? await api.suggestions(mediaID: media, limit: 3) else { return }
        guard let self, self.mediaID == media, !self.closed else { return }
        self.suggestions = list.filter { $0.item.id != media }
      }
    }
    let shown =
      !finished && upNext == nil
      && TVPlayerPolicy.showsSuggestion(
        position: position, duration: duration, hasNext: hasNext,
        hasSuggestion: !suggestions.isEmpty, dismissed: suggestionDismissed,
        creditsStart: currentSegments?.creditsStartMilliseconds)
    assignIfChanged(&showsSuggestion, shown)
  }

  func back() {
    if scrubPosition != nil {
      cancelScrub()
    } else if showsSuggestionEndScreen {
      doneWithSuggestions()
    } else if showsSuggestion, !controlsVisible {
      dismissSuggestion()
    } else if upNext != nil, !controlsVisible {
      dismissUpNext()
    } else if showsSkipIntro, !controlsVisible {
      // Back over Skip Intro lets the intro play.
      introDeclined = true
      showsSkipIntro = false
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

  // MARK: Screen time

  /// The quiet "last episode" note while the last title of the day plays.
  var lastTitleNote: String? {
    screenTime?.noMoreTitles == true && !showsGoodNight
      ? TVScreenTimeText.lastTitleNote(screenTime) : nil
  }

  private func refreshScreenTime() async {
    lastScreenTimeCheck = Date()
    // The last known state stays when the server does not answer.
    guard let status = try? await api.ownScreenTime(), !closed else { return }
    screenTime = status
  }

  /// The friendly end of the day; nothing else starts, and the view shows the moon.
  private func showGoodNight() {
    guard !closed, !showsGoodNight else { return }
    engine.pause()
    upNext = nil
    showsSuggestion = false
    showsSuggestionEndScreen = false
    suggestionToStart = nil
    controlsVisible = false
    showsGoodNight = true
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
      screenTime = created.screenTime
      lastScreenTimeCheck = Date()
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
      let playing = effectivePreferences
      engine.applyPreferences(playing)
      engine.playbackRate = desiredRate
      engine.load(
        url: playing.streamingQuality.playbackURL(for: localURL), resumeAt: resumeAt ?? resumePosition,
        paused: !wantsPlayback)
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
      if let core = error as? TVCoreError, TVScreenTimeText.refusesTitle(core.problemCode) {
        // Screen time refused the title: the good-night screen, not an error.
        Task { [weak self] in
          await self?.refreshScreenTime()
          self?.showGoodNight()
        }
      } else if let core = error as? TVCoreError, core.endsSession {
        sessionFailed(core)
      } else if let core = error as? TVCoreError, let refusal = TVPlayerPolicy.refusal(core) {
        fail(refusal, canRetry: false)
      } else if let core = error as? TVCoreError,
        let missing = TVPlayerPolicy.unavailability(core)
      {
        // An offline drive answers 503, which would otherwise reconnect again and again.
        fail(missing, canRetry: true)
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
    updateSuggestion()
    updateSkipIntro()
    if wasPlaying != isPlaying || wasLoading != isLoading { userInteracted() }
    if !isPlaying { controlsVisible = true }
  }

  private func updateUpNext() {
    let next = queue.first
    let credits = creditsStart
    if isPlaying, screenTime != nil, screenTimeTask == nil,
      Date().timeIntervalSince(lastScreenTimeCheck) >= TVScreenTimeText.refreshInterval
    {
      screenTimeTask = Task { [weak self] in
        await self?.refreshScreenTime()
        self?.screenTimeTask = nil
      }
    }
    let shown = TVPlayerPolicy.showsUpNext(
      position: position, duration: duration,
      hasNext: next?.isPlayable == true && screenTime?.noMoreTitles != true,
      autoplay: preferences.automaticallyPlayNextEpisode, stopsAtEnd: sleepTimer == .endOfEpisode,
      dismissed: upNextDismissed || finished, creditsStart: credits)
    let duringCredits =
      shown
      && TVPlayerPolicy.showsForCredits(position: position, duration: duration, creditsStart: credits)
    // The countdown starts where the card appeared: at the credits, or later when the viewer
    // moved into them.
    if duringCredits {
      if creditsAnchor == nil { creditsAnchor = position }
    } else {
      creditsAnchor = nil
    }
    let card = next.flatMap { next in
      shown
        ? TVUpNext(
          title: next.episodeLabel.map { "\($0) · \(next.title)" } ?? next.title,
          seconds: TVPlayerPolicy.upNextSeconds(
            position: position, duration: duration, creditsAnchor: creditsAnchor),
          duringCredits: duringCredits)
        : nil
    }
    assignIfChanged(&upNext, card)
    // The countdown ran out in the credits before the file ended: the next episode starts, and
    // this one counts as watched.
    if let card, card.duringCredits, card.seconds == 0, isPlaying, position < duration {
      playNextNow()
    }
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
      showsSuggestion = false
      // Screen time may have ended while this title played: ask before anything else starts.
      guard screenTime == nil else {
        advanceTask = Task { [weak self] in
          guard let self else { return }
          await self.refreshScreenTime()
          guard !self.closed else { return }
          if self.screenTime?.noMoreTitles == true { self.showGoodNight() } else { self.continueAfterEnd() }
        }
        return
      }
      continueAfterEnd()
    } else {
      recover(message: "The stream was interrupted. Reconnecting…")
    }
  }

  private func continueAfterEnd() {
    if sleepTimer != .endOfEpisode, preferences.automaticallyPlayNextEpisode,
      !autoplayCancelled, let next = queue.first
    {
      advanceTask = Task { [weak self] in await self?.advance(to: next) }
    } else if sleepTimer != .endOfEpisode, queue.isEmpty, let first = suggestions.first {
      // After a movie or a series' last episode: only the viewer's own setting starts the
      // suggestion; otherwise the end screen offers it with two more.
      if preferences.playSuggestionsAutomatically, !autoplayCancelled {
        suggestionToStart = first.item
      } else {
        controlsVisible = false
        showsSuggestionEndScreen = true
      }
    } else {
      if sleepTimer == .endOfEpisode {
        let api = api
        Task { try? await api.sleepTimerEnded() }
      }
      close()
    }
  }

  private func handleRelayFailure(_ failure: TVStreamFailure) {
    transportFailed = true
    switch TVPlayerPolicy.response(to: failure) {
    case .endSession(let error):
      sessionFailed(error)
    case .fail(let message, let canRetry):
      fail(message, canRetry: canRetry)
    case .reconnect:
      recover(message: "The stream was interrupted. Reconnecting…")
    }
  }

  private func recover(message: String) {
    guard !closed, !showsGoodNight else { return }
    // "Stop now" ends the stream at bedtime; that is the good-night screen, not a problem.
    if screenTime != nil, screenTimeTask == nil {
      screenTimeTask = Task { [weak self] in
        guard let self else { return }
        await self.refreshScreenTime()
        self.screenTimeTask = nil
        if self.screenTime?.state == .closed { self.showGoodNight() }
      }
    }
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
        if let apiError = error as? TVCoreError, apiError.endsSession {
          sessionFailed(apiError)
        } else if let apiError = error as? TVCoreError,
          let refusal = TVPlayerPolicy.refusal(apiError)
        {
          fail(refusal, canRetry: false)
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
    suggestions = []
    suggestionsRequested = false
    suggestionDismissed = false
    showsSuggestion = false
    showsSuggestionEndScreen = false
    creditsAnchor = nil
    introSkipped = false
    movedIntoIntro = false
    introDeclined = false
    showsSkipIntro = false
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
  /// The card appeared with the credits: its second button keeps watching them.
  var duringCredits = false
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
