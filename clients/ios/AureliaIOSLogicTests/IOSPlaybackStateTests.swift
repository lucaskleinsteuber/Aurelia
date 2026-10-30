import Foundation
import Testing

struct IOSPlaybackStateTests {
  @Test func stickyBufferingWithMovingClockIsPlaybackAndRecordsActualProgress() {
    var machine = IOSPlaybackStateMachine()
    machine.reset(at: 100)
    machine.update(raw(.buffering, position: 0), at: 100)
    for step in 1...80 {
      let sample = machine.update(
        raw(.buffering, position: Int64(step * 250)), at: 100 + Double(step) / 4)
      #expect(sample.phase == .playing)
      #expect(!sample.isLoading)
      #expect(sample.hasObservedPlayback)
    }
    #expect(machine.state.progressPosition == 20_000)
  }

  @Test func noClockMotionEventuallyShowsAStallAndResumesWhenMotionReturns() {
    var machine = IOSPlaybackStateMachine()
    machine.reset(at: 0)
    machine.update(raw(.playing, position: 0), at: 0)
    machine.update(raw(.playing, position: 250), at: 0.25)
    #expect(machine.update(raw(.buffering, position: 250), at: 1).phase == .playing)
    #expect(machine.update(raw(.buffering, position: 250), at: 2).phase == .stalled)
    #expect(machine.state.isLoading)
    #expect(machine.state.progressPosition == 250)
    #expect(machine.update(raw(.buffering, position: 500), at: 2.25).phase == .playing)
    #expect(!machine.state.isLoading)
  }

  @Test func initialResumeRequiresRealMotionAndDoesNotCreditTheJump() {
    var machine = IOSPlaybackStateMachine()
    machine.reset(at: 0)
    machine.seek(to: 90_000, at: 0)
    machine.update(raw(.buffering, position: 0), at: 0.25)
    #expect(machine.state.position == 0)
    #expect(machine.state.progressPosition == nil)
    machine.update(raw(.buffering, position: 90_000), at: 0.5)
    #expect(machine.state.position == 90_000)
    #expect(!machine.state.hasObservedPlayback)
    #expect(machine.state.progressPosition == nil)
    machine.update(raw(.buffering, position: 90_250), at: 0.75)
    #expect(machine.state.progressPosition == 90_250)
    #expect(machine.state.hasObservedPlayback)
  }

  @Test func aSeekAloneKeepsTheLastViewedClockAndCannotCompleteATitle() {
    var machine = IOSPlaybackStateMachine()
    machine.reset(at: 0)
    machine.update(raw(.playing, position: 10_000), at: 0)
    machine.update(raw(.playing, position: 10_250), at: 0.25)
    machine.seek(to: 99_500, at: 0.5)
    machine.update(raw(.buffering, position: 99_500), at: 0.75)
    #expect(machine.state.progressPosition == 10_250)
    #expect(!machine.state.hasObservedPlayback)
    machine.update(raw(.ended, position: 100_000), at: 0.75)
    #expect(
      !IOSPlayerPolicy.isNaturalCompletion(
        position: machine.state.position, duration: machine.state.duration,
        observedPlayback: machine.state.hasObservedPlayback, transportFailed: false))
  }

  @Test func backwardSeekRequiresNewMotionBeforeReplacingPriorViewedPosition() {
    var machine = IOSPlaybackStateMachine()
    machine.reset(at: 0)
    machine.update(raw(.playing, position: 40_000), at: 0)
    machine.update(raw(.playing, position: 40_250), at: 0.25)
    machine.seek(to: 10_000, at: 0.5)
    machine.update(raw(.buffering, position: 10_000), at: 0.75)
    #expect(machine.state.progressPosition == 40_250)
    machine.update(raw(.buffering, position: 10_250), at: 1)
    #expect(machine.state.progressPosition == 10_250)
  }

  @Test func anUnannouncedLargeJumpIsNotObservedPlayback() {
    var machine = IOSPlaybackStateMachine()
    machine.reset(at: 0)
    machine.update(raw(.playing, position: 0), at: 0)
    machine.update(raw(.playing, position: 80_000), at: 0.25)
    #expect(!machine.state.hasObservedPlayback)
    #expect(machine.state.progressPosition == nil)
    machine.update(raw(.playing, position: 80_250), at: 0.5)
    #expect(machine.state.progressPosition == 80_250)
  }

  @Test func delayedDurationAndUnavailableClockDoNotEraseValidSamples() {
    var machine = IOSPlaybackStateMachine()
    machine.reset(at: 0)
    machine.update(raw(.buffering, position: 0, duration: nil), at: 0)
    machine.update(raw(.buffering, position: 250, duration: nil), at: 0.25)
    #expect(machine.state.isPlaying)
    #expect(machine.state.duration == 0)
    machine.update(raw(.buffering, position: nil, duration: 100_000), at: 0.5)
    machine.update(raw(.buffering, position: -1, duration: -1), at: 0.75)
    #expect(machine.state.position == 250)
    #expect(machine.state.progressPosition == 250)
    #expect(machine.state.duration == 100_000)
  }

  @Test func pauseWinsOverStaleBufferingAndClockMotion() {
    var machine = IOSPlaybackStateMachine()
    machine.reset(at: 0)
    machine.update(raw(.playing, position: 0), at: 0)
    machine.update(raw(.playing, position: 250), at: 0.25)
    machine.setWantsPlayback(false)
    let paused = machine.update(raw(.buffering, position: 500), at: 0.5)
    #expect(paused.phase == .paused)
    #expect(!paused.isLoading)
    #expect(paused.progressPosition == 250)
    machine.setWantsPlayback(true)
    #expect(machine.update(raw(.buffering, position: 750), at: 0.75).phase == .playing)
  }

  @Test func stoppedSessionAndOlderSamplesCannotChangeTheLastCapture() {
    var machine = IOSPlaybackStateMachine()
    machine.reset(at: 10)
    machine.update(raw(.playing, position: 0), at: 10)
    machine.update(raw(.playing, position: 250), at: 10.25)
    machine.update(raw(.playing, position: 90_000), at: 9)
    #expect(machine.state.position == 250)
    machine.stop()
    machine.update(raw(.playing, position: 500), at: 11)
    #expect(machine.state.phase == .idle)
    #expect(machine.state.progressPosition == 250)
    machine.reset(at: 12)
    #expect(machine.state.progressPosition == nil)
    #expect(machine.state.phase == .preparing)
  }

  @Test func terminalResetClockAndLateNotificationsDoNotErasePlaybackPosition() {
    var machine = IOSPlaybackStateMachine()
    machine.reset(at: 0)
    machine.update(raw(.playing, position: 99_000), at: 0)
    machine.update(raw(.playing, position: 99_250), at: 0.25)
    let ended = machine.update(raw(.ended, position: 0), at: 0.5)
    #expect(ended.position == 99_250)
    #expect(ended.progressPosition == 99_250)
    #expect(ended.phase == .ended)
    machine.update(raw(.buffering, position: 99_500), at: 0.75)
    #expect(machine.state == ended)
  }

  @Test func differentRatesAcceptPlausibleClockMovement() {
    for rate in IOSPlaybackPreferences.supportedRates {
      var machine = IOSPlaybackStateMachine()
      machine.reset(at: 0)
      machine.update(raw(.buffering, position: 0), at: 0, playbackRate: rate)
      machine.update(
        raw(.buffering, position: Int64(1_000 * rate)), at: 1, playbackRate: rate)
      #expect(machine.state.isPlaying)
      #expect(machine.state.hasObservedPlayback)
    }
  }

  @Test func watchdogBoundsStartupAndSubsequentStallsUsingControlledTime() {
    var watchdog = IOSPlaybackWatchdog()
    watchdog.reset(at: 100)
    let beforeStartupLimit = watchdog.shouldRecover(
      progressPosition: nil, wantsPlayback: true, interacting: false, at: 129)
    #expect(!beforeStartupLimit)
    let atStartupLimit = watchdog.shouldRecover(
      progressPosition: nil, wantsPlayback: true, interacting: false, at: 130)
    #expect(atStartupLimit)
    let moving = watchdog.shouldRecover(
      progressPosition: 500, wantsPlayback: true, interacting: false, at: 131)
    #expect(!moving)
    let beforeStallLimit = watchdog.shouldRecover(
      progressPosition: 500, wantsPlayback: true, interacting: false, at: 142)
    #expect(!beforeStallLimit)
    let atStallLimit = watchdog.shouldRecover(
      progressPosition: 500, wantsPlayback: true, interacting: false, at: 143)
    #expect(atStallLimit)
  }

  @Test func watchdogDoesNotRecoverDuringPauseMenusOrTimelineInteraction() {
    var watchdog = IOSPlaybackWatchdog()
    watchdog.reset(at: 0)
    let paused = watchdog.shouldRecover(
      progressPosition: nil, wantsPlayback: false, interacting: false, at: 1_000)
    #expect(!paused)
    let menuOpen = watchdog.shouldRecover(
      progressPosition: nil, wantsPlayback: true, interacting: true, at: 2_000)
    #expect(!menuOpen)
    let beforeLimit = watchdog.shouldRecover(
      progressPosition: nil, wantsPlayback: true, interacting: false, at: 2_029)
    #expect(!beforeLimit)
    let atLimit = watchdog.shouldRecover(
      progressPosition: nil, wantsPlayback: true, interacting: false, at: 2_030)
    #expect(atLimit)
  }

  @Test func watchdogSeekAndSessionResetStartFreshBoundedWindows() {
    var watchdog = IOSPlaybackWatchdog()
    watchdog.reset(at: 0)
    let playing = watchdog.shouldRecover(
      progressPosition: 250, wantsPlayback: true, interacting: false, at: 1)
    #expect(!playing)
    watchdog.noteSeek(at: 11)
    let afterSeek = watchdog.shouldRecover(
      progressPosition: 250, wantsPlayback: true, interacting: false, at: 22)
    #expect(!afterSeek)
    let stuckAfterSeek = watchdog.shouldRecover(
      progressPosition: 250, wantsPlayback: true, interacting: false, at: 23)
    #expect(stuckAfterSeek)
    watchdog.reset(at: 30)
    let freshSession = watchdog.shouldRecover(
      progressPosition: nil, wantsPlayback: true, interacting: false, at: 59)
    #expect(!freshSession)
  }

  private func raw(
    _ state: IOSDecoderState, position: Int64?, duration: Int64? = 100_000
  ) -> IOSDecoderSnapshot {
    IOSDecoderSnapshot(
      state: state, position: position, duration: duration, isPlaying: state != .paused,
      isSeekable: true)
  }
}

struct IOSPlaybackPreferencesTests {
  @Test func incompleteAndUnknownPreferenceFieldsRemainCompatible() throws {
    let values = try JSONDecoder().decode(
      IOSPlaybackPreferences.self, from: Data("{\"automaticResume\":false,\"futureField\":42}".utf8)
    )
    #expect(!values.automaticResume)
    #expect(values.automaticallyPlayNextEpisode)
    #expect(values.defaultPlaybackRate == 1)
    #expect(values.controlsDelay == 4)
    #expect(values.seekInterval == 10)
    #expect(values.preferredSubtitleTrack == nil)
  }

  @Test func invalidPreferencesAreNormalized() {
    var values = IOSPlaybackPreferences()
    values.defaultPlaybackRate = .infinity
    values.controlsDelay = .nan
    values.seekInterval = 100
    let normalized = values.normalized
    #expect(normalized.defaultPlaybackRate == 1)
    #expect(normalized.controlsDelay == 4)
    #expect(normalized.seekInterval == 60)
  }

  @Test func trackMatchingPrefersFullTitleThenStableLanguageInsteadOfTrackIndex() {
    let original = IOSPlaybackTrack(id: 1, title: "English Stereo [eng]")
    let tracks = [
      IOSPlaybackTrack(id: 1, title: "Deutsch [deu]"),
      IOSPlaybackTrack(id: 7, title: "English Stereo [eng]"),
      IOSPlaybackTrack(id: 9, title: "English Surround [eng]"),
    ]
    #expect(IOSPlaybackTrack.matching(original.preference, in: tracks)?.id == 7)
    #expect(IOSPlaybackTrack.matching(original.preference, in: Array(tracks.suffix(1)))?.id == 9)
    #expect(IOSPlaybackTrack.matching(nil, in: tracks) == nil)
    #expect(original.preference.language == "eng")
  }

  @Test @MainActor func isolatedPreferenceStorageSeparatesServersAndProfiles() throws {
    let suite = "Aurelia-TV-Preference-Tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = IOSPlaybackPreferencesStore(defaults: defaults)
    let server = UUID()
    let profile = UUID()
    var value = IOSPlaybackPreferences()
    value.automaticResume = false
    value.defaultPlaybackRate = 1.5
    value.preferredSubtitleTrack = IOSPlaybackTrack(id: 4, title: "English [eng]").preference
    #expect(store.save(value, serverID: server, profileID: profile))
    let restarted = IOSPlaybackPreferencesStore(defaults: defaults)
    #expect(restarted.preferences(serverID: server, profileID: profile) == value)
    #expect(restarted.preferences(serverID: UUID(), profileID: profile) == .defaultValue)
    #expect(restarted.preferences(serverID: server, profileID: UUID()) == .defaultValue)
    let bytes = try JSONEncoder().encode(value)
    let text = try #require(String(data: bytes, encoding: .utf8))
    #expect(!text.contains("token"))
    #expect(!text.contains("https"))
    #expect(!text.contains("streamPath"))
  }
}
