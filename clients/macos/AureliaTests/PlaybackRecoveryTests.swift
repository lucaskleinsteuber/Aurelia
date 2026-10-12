import Foundation
import Testing

@testable import Aurelia

@MainActor
struct PlaybackRecoveryTests {
  @Test
  func prematureEndKeepsPositionAndDoesNotFinishOrAdvance() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.controller.seek(to: 405_000)
    fixture.engine.isPlaying = false
    fixture.engine.onEnded?()
    try await fixture.clock.waitForSleeps(1)
    #expect(fixture.controller.currentTimeMilliseconds == 405_000)
    #expect(fixture.controller.presentation.mediaId == fixture.client.mediaID)
    #expect(!fixture.client.updates.contains { $0.isCompleted })
    #expect(fixture.controller.recoveryMessage != nil)
    fixture.clock.wake()
    try await fixture.waitForPlaying()
    #expect(fixture.engine.currentTimeMilliseconds == 405_000)
    #expect(fixture.client.calls == 2)
    await fixture.close()
  }

  @Test
  func requestedNearEndSeekCannotCompleteAnActualEarlyDecoderEnd() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.controller.seek(to: 405_000)
    fixture.engine.deferSeekStateChange = true
    let requestedPosition = fixture.engine.durationMilliseconds - 100
    fixture.controller.seek(to: requestedPosition)
    #expect(fixture.engine.pendingSeekTarget == requestedPosition)
    #expect(fixture.engine.currentTimeMilliseconds == 405_000)
    #expect(fixture.controller.currentTimeMilliseconds == requestedPosition)

    // The decoder ends before acknowledging the requested position. Its real
    // clock is still far from EOF; the optimistic UI target is not progress.
    fixture.engine.isPlaying = false
    fixture.engine.onEnded?()
    for _ in 0..<100 { await Task.yield() }
    #expect(fixture.controller.presentation.mediaId == fixture.client.mediaID)
    #expect(fixture.client.requestedIDs == [fixture.client.mediaID])
    #expect(!fixture.client.updates.contains { $0.isCompleted })
    #expect(!fixture.controller.diagnostics.events.contains { $0.kind == .ended })
    #expect(fixture.controller.recoveryCause == .prematureEnd)
    #expect(fixture.controller.recoveryMessage != nil)
    await fixture.close()
  }

  @Test
  func reportedNearEndSourceFailureQuarantinesLateDecoderEnd() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.controller.seek(to: fixture.engine.durationMilliseconds - 1_000)
    fixture.relay.failure?(.unavailable)
    // A queued decoder EOF can arrive after the relay has already reported
    // the failed source. Near-end position must not override that failure.
    fixture.engine.onEnded?()
    for _ in 0..<100 { await Task.yield() }
    #expect(fixture.controller.presentation.mediaId == fixture.client.mediaID)
    #expect(fixture.client.requestedIDs == [fixture.client.mediaID])
    #expect(!fixture.client.updates.contains { $0.isCompleted })
    #expect(!fixture.controller.diagnostics.events.contains { $0.kind == .ended })
    #expect(fixture.controller.recoveryCause == .mediaSourceUnavailable)
    #expect(fixture.controller.recoveryMessage != nil)
    await fixture.close()
  }

  @Test
  func recoveryOverridesStaleServerProgressEvenWhenAutomaticResumeIsOff() async throws {
    var preferences = PlaybackPreferences.defaultValue
    preferences.automaticResume = false
    let fixture = RecoveryFixture(preferences: preferences)
    await fixture.controller.start()
    fixture.controller.seek(to: 405_000)
    fixture.relay.failure?(.interrupted)
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.waitForPlaying()
    #expect(fixture.controller.currentTimeMilliseconds == 405_000)
    #expect(fixture.controller.presentation.mediaId == fixture.client.mediaID)
    await fixture.close()
  }

  @Test
  func explicitRetryPreservesUnsavedLocalPosition() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.controller.seek(to: 405_000)
    await fixture.controller.retry()
    #expect(fixture.engine.currentTimeMilliseconds == 405_000)
    #expect(fixture.controller.isPlaying)
    await fixture.close()
  }

  @Test
  func closingDuringExplicitRetryCleanupCannotResurrectPlayback() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.client.holdNextRevocation = true
    let retry = Task { await fixture.controller.retry() }
    try await fixture.waitUntil { fixture.client.pendingRevocation != nil }
    await fixture.controller.shutdown(saveProgress: false)
    fixture.client.releaseRevocation()
    await retry.value
    #expect(fixture.client.calls == 1)
    #expect(!fixture.engine.isPlaying)
    #expect(fixture.controller.recoveryMessage == nil)
  }

  @Test
  func missingDriveRetriesWithBackoffAndRecovers() async throws {
    let fixture = RecoveryFixture(outcomes: [
      .failure(Self.offline), .failure(Self.offline), .success(()),
    ])
    await fixture.controller.start()
    fixture.controller.seek(to: 405_000)
    fixture.relay.failure?(.unavailable)
    for count in 1...3 {
      try await fixture.clock.waitForSleeps(count)
      fixture.clock.wake()
    }
    try await fixture.waitForPlaying()
    #expect(fixture.clock.delays == [1, 2, 4])
    #expect(fixture.controller.currentTimeMilliseconds == 405_000)
    #expect(fixture.controller.errorMessage == nil)
    await fixture.close()
  }

  @Test
  func endOfEpisodeWaitsForNextWithoutLosingQueueOrReplayingPrevious() async throws {
    let fixture = RecoveryFixture(outcomes: [.failure(Self.offline), .success(())])
    await fixture.controller.start()
    fixture.engine.currentTimeMilliseconds = fixture.engine.durationMilliseconds
    fixture.engine.onEnded?()
    try await fixture.clock.waitForSleeps(1)
    #expect(fixture.controller.presentation.mediaId == fixture.nextID)
    #expect(fixture.controller.presentation.queue.first?.mediaId == fixture.nextID)
    fixture.clock.wake()
    try await fixture.waitForPlaying()
    #expect(fixture.controller.presentation.mediaId == fixture.nextID)
    #expect(fixture.controller.presentation.queue.isEmpty)
    #expect(
      fixture.client.requestedIDs == [fixture.client.mediaID, fixture.nextID, fixture.nextID])
    #expect(fixture.engine.currentTimeMilliseconds == 0)
    await fixture.close()
  }

  @Test
  func retriesAreBoundedAndFailureNeverMarksFinished() async throws {
    let fixture = RecoveryFixture(outcomes: Array(repeating: .failure(Self.offline), count: 6))
    await fixture.controller.start()
    fixture.controller.seek(to: 405_000)
    fixture.relay.failure?(.unavailable)
    for count in 1...6 {
      try await fixture.clock.waitForSleeps(count)
      fixture.clock.wake()
    }
    try await fixture.waitForError()
    #expect(fixture.client.calls == 7)
    #expect(fixture.clock.delays == PlaybackRecoveryPolicy.delays)
    #expect(fixture.controller.recoveryMessage == nil)
    #expect(fixture.controller.currentTimeMilliseconds == 405_000)
    #expect(!fixture.client.updates.contains { $0.isCompleted })
    await fixture.close()
  }

  @Test
  func repeatedPrematureEndsWithoutMovementCannotLoopForever() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.controller.seek(to: 405_000)
    for count in 1...6 {
      fixture.engine.onEnded?()
      try await fixture.clock.waitForSleeps(count)
      fixture.clock.wake()
      try await fixture.waitForPlaying()
    }
    fixture.engine.onEnded?()
    try await fixture.waitForError()
    #expect(fixture.client.calls == 7)
    await fixture.close()
  }

  @Test(arguments: [PlaybackStreamFailure.authorizationDenied, .untrustedServer, .invalidResponse])
  func securityOrInvalidResponseDoesNotAutoRetry(failure: PlaybackStreamFailure) async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.relay.failure?(failure)
    for _ in 0..<20 { await Task.yield() }
    #expect(fixture.client.calls == 1)
    #expect(fixture.clock.delays.isEmpty)
    #expect(fixture.engine.didStop)
    #expect(fixture.relay.didStop)
    #expect(fixture.controller.errorMessage != nil)
    await fixture.close()
  }

  @Test
  func cancellationAndOldRelayFailureCannotRestartClosedPlayback() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    let oldCallback = fixture.relay.failure
    oldCallback?(.interrupted)
    try await fixture.clock.waitForSleeps(1)
    await fixture.controller.shutdown(saveProgress: false)
    fixture.clock.wake()
    oldCallback?(.interrupted)
    for _ in 0..<30 { await Task.yield() }
    #expect(fixture.client.calls == 1)
    #expect(fixture.controller.recoveryMessage == nil)
  }

  @Test
  func canceledRecoverySleepDoesNotReopenPlayback() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.relay.failure?(.interrupted)
    try await fixture.clock.waitForSleeps(1)
    fixture.controller.cancelRecovery()
    fixture.clock.wake()
    for _ in 0..<30 { await Task.yield() }
    #expect(fixture.client.calls == 1)
    #expect(!fixture.controller.isPlaying)
    #expect(fixture.controller.recoveryMessage == nil)
    await fixture.close()
  }

  @Test
  func canceledInFlightRecoveryRevokesItsLateTicketWithoutRestarting() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.controller.seek(to: 405_000)
    fixture.client.holdNextRequest = true
    fixture.relay.failure?(.interrupted)
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.waitUntil { fixture.client.pendingRequest != nil }
    fixture.controller.cancelRecovery()
    fixture.client.releaseRequest()
    try await fixture.waitUntil { fixture.client.revokedIDs.count == 2 }
    #expect(fixture.client.calls == 2)
    #expect(!fixture.engine.isPlaying)
    #expect(fixture.controller.currentTimeMilliseconds == 405_000)
    #expect(fixture.controller.recoveryMessage == nil)
    await fixture.close()
  }

  @Test
  func oldRelayFailureCannotInterruptSuccessfullyRecoveredSource() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    let oldCallback = fixture.relay.failure
    oldCallback?(.interrupted)
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.waitForPlaying()
    oldCallback?(.authorizationDenied)
    #expect(fixture.controller.isPlaying)
    #expect(fixture.controller.errorMessage == nil)
    #expect(fixture.clock.delays == [1])
    await fixture.close()
  }

  @Test
  func authorizationFailureDuringRecoveryStopsWithoutFurtherRequests() async throws {
    let denied = APIClientError.httpFailure(
      status: 403, retryAfter: nil, code: "access_denied", message: "No access")
    let fixture = RecoveryFixture(outcomes: [.failure(denied)])
    await fixture.controller.start()
    fixture.relay.failure?(.interrupted)
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.waitForError()
    fixture.controller.togglePlayback()
    #expect(!fixture.engine.isPlaying)
    #expect(fixture.client.calls == 2)
    #expect(fixture.clock.delays == [1])
    await fixture.close()
  }

  @Test
  func latePreviousSourceFailuresDoNotInterfereWithEpisodeAdvance() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    let oldCallback = fixture.relay.failure
    fixture.engine.currentTimeMilliseconds = fixture.engine.durationMilliseconds
    fixture.engine.onEnded?()
    oldCallback?(.interrupted)
    fixture.engine.onError?("Retired input")
    try await fixture.waitUntil {
      fixture.controller.presentation.mediaId == fixture.nextID && fixture.controller.isPlaying
    }
    #expect(fixture.clock.delays.isEmpty)
    #expect(fixture.client.calls == 2)
    await fixture.close()
  }

  @Test
  func completedMoviePlayReloadsFromStartAndReenablesProgressEvents() async throws {
    let fixture = RecoveryFixture(includeQueue: false)
    await fixture.controller.start()
    fixture.engine.currentTimeMilliseconds = fixture.engine.durationMilliseconds
    fixture.engine.isPlaying = false
    fixture.engine.onEnded?()
    fixture.controller.togglePlayback()
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.waitForPlaying()
    #expect(fixture.client.requestedIDs == [fixture.client.mediaID, fixture.client.mediaID])
    #expect(fixture.engine.currentTimeMilliseconds == 0)
    fixture.engine.currentTimeMilliseconds = 30_000
    fixture.engine.onUpdate?()
    #expect(fixture.controller.currentTimeMilliseconds == 30_000)
    fixture.engine.currentTimeMilliseconds = fixture.engine.durationMilliseconds
    fixture.engine.onEnded?()
    // Intermediate unsent progress is intentionally coalesced. Replaying a
    // completed movie may replace its first pending completion with the new
    // unfinished position, but both ends must be observed and the latest
    // durable server snapshot must still be completed at the true duration.
    try await fixture.waitUntil {
      fixture.client.updates.last?.isCompleted == true
        && fixture.client.updates.last?.positionMilliseconds == fixture.engine.durationMilliseconds
    }
    #expect(fixture.controller.diagnostics.events.filter { $0.kind == .ended }.count == 2)
    #expect(!fixture.controller.isPlaying)
    await fixture.close()
  }

  @Test
  func completedMovieSeekReloadsPausedAtSelectedPositionThenCanPlay() async throws {
    let fixture = RecoveryFixture(includeQueue: false)
    await fixture.controller.start()
    fixture.engine.currentTimeMilliseconds = fixture.engine.durationMilliseconds
    fixture.engine.isPlaying = false
    fixture.engine.onEnded?()
    fixture.controller.seek(to: 405_000)
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.waitUntil {
      fixture.client.calls == 2 && fixture.controller.recoveryMessage == nil
    }
    #expect(!fixture.controller.isPlaying)
    #expect(fixture.engine.currentTimeMilliseconds == 405_000)
    fixture.controller.togglePlayback()
    #expect(fixture.controller.isPlaying)
    fixture.engine.currentTimeMilliseconds = 406_000
    fixture.engine.onUpdate?()
    #expect(fixture.controller.currentTimeMilliseconds == 406_000)
    await fixture.close()
  }

  @Test
  func pendingCompletedReplayTogglePausesWithoutRestartingAuthorization() async throws {
    let fixture = RecoveryFixture(includeQueue: false)
    await fixture.controller.start()
    fixture.engine.currentTimeMilliseconds = fixture.engine.durationMilliseconds
    fixture.engine.isPlaying = false
    fixture.engine.onEnded?()
    fixture.client.holdNextRequest = true
    #expect(fixture.controller.play())
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.waitUntil { fixture.client.pendingRequest != nil }
    #expect(fixture.controller.play())
    #expect(fixture.controller.play())
    #expect(fixture.controller.togglePlayback())
    fixture.client.releaseRequest()
    try await fixture.waitUntil {
      fixture.controller.recoveryMessage == nil && !fixture.controller.isPreparing
    }
    #expect(fixture.client.calls == 2)
    #expect(fixture.clock.delays == [1])
    #expect(fixture.engine.playCalls == 1)
    #expect(!fixture.engine.isPlaying && !fixture.controller.isPlaying)
    #expect(fixture.controller.play())
    #expect(fixture.controller.isPlaying && fixture.engine.playCalls == 2)
    await fixture.close()
  }

  @Test
  func duplicatePlayCannotResetAPendingCompletedReplayIncidentBudget() async throws {
    let fixture = RecoveryFixture(includeQueue: false)
    await fixture.controller.start()
    fixture.engine.currentTimeMilliseconds = fixture.engine.durationMilliseconds
    fixture.engine.isPlaying = false
    fixture.engine.onEnded?()
    fixture.client.holdNextRequest = true
    #expect(fixture.controller.play())
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.waitUntil { fixture.client.pendingRequest != nil }
    fixture.clock.now.addTimeInterval(110)
    #expect(fixture.controller.play())
    #expect(fixture.controller.play())
    fixture.client.releaseRequest()
    try await fixture.waitForPlaying()
    fixture.clock.now.addTimeInterval(11)
    fixture.controller.checkForStall()
    #expect(fixture.controller.errorMessage != nil)
    #expect(!fixture.controller.play() && !fixture.controller.togglePlayback())
    #expect(fixture.client.calls == 2)
    #expect(fixture.controller.diagnostics.events.contains { $0.kind == .recoveryExhausted })
    // An intentional new retry is still allowed after a terminal incident.
    await fixture.controller.retry()
    #expect(fixture.client.calls == 3)
    #expect(fixture.controller.isPlaying && fixture.controller.errorMessage == nil)
    await fixture.close()
  }

  @Test
  func completedEpisodeCommandsPreservePausedIntentWithoutCompetingWithAutoAdvance() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.client.holdNextRequest = true
    fixture.engine.currentTimeMilliseconds = fixture.engine.durationMilliseconds
    fixture.engine.onEnded?()
    #expect(fixture.controller.togglePlayback())
    fixture.controller.seek(to: 405_000)
    fixture.controller.selectChapter(fixture.engine.chapters[1])
    try await fixture.waitUntil { fixture.client.pendingRequest != nil }
    #expect(fixture.clock.delays.isEmpty)
    fixture.client.releaseRequest()
    try await fixture.waitUntil {
      fixture.controller.presentation.mediaId == fixture.nextID
        && fixture.controller.recoveryMessage == nil && !fixture.controller.isPreparing
    }
    #expect(fixture.client.requestedIDs == [fixture.client.mediaID, fixture.nextID])
    #expect(fixture.engine.currentTimeMilliseconds == 0)
    #expect(!fixture.engine.isPlaying && !fixture.controller.isPlaying)
    #expect(fixture.engine.playCalls == 1)
    #expect(fixture.controller.play())
    #expect(fixture.controller.isPlaying && fixture.engine.playCalls == 2)
    await fixture.close()
  }

  @Test
  func endOfEpisodeSleepTimerAllowsOnlyExplicitReplayOfCurrentTitle() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.controller.setSleepTimer(.endOfEpisode)
    fixture.engine.currentTimeMilliseconds = fixture.engine.durationMilliseconds
    fixture.engine.isPlaying = false
    fixture.engine.onEnded?()
    #expect(fixture.client.calls == 1)
    fixture.controller.togglePlayback()
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.waitForPlaying()
    #expect(fixture.client.requestedIDs == [fixture.client.mediaID, fixture.client.mediaID])
    #expect(fixture.controller.presentation.queue.first?.mediaId == fixture.nextID)
    await fixture.close()
  }

  @Test
  func sleepTimerDuringPendingStartupPreventsAutoplay() async throws {
    let fixture = RecoveryFixture()
    fixture.client.holdNextRequest = true
    let start = Task { await fixture.controller.start() }
    try await fixture.waitUntil { fixture.client.pendingRequest != nil }
    fixture.controller.setSleepTimer(.minutes(0))
    fixture.client.releaseRequest()
    await start.value
    #expect(!fixture.engine.isPlaying)
    #expect(!fixture.controller.isPlaying)
    await fixture.close()
  }

  @Test
  func chapterSelectionResetsStallBaselineAndStartupStallsAreBounded() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.clock.now = fixture.clock.now.addingTimeInterval(20)
    fixture.controller.selectChapter(fixture.engine.chapters[1])
    fixture.controller.checkForStall()
    #expect(fixture.controller.recoveryMessage == nil)
    fixture.engine.durationMilliseconds = 0
    fixture.engine.isPlaying = false
    fixture.engine.onUpdate?()
    fixture.clock.now = fixture.clock.now.addingTimeInterval(31)
    fixture.controller.checkForStall()
    try await fixture.clock.waitForSleeps(1)
    #expect(fixture.controller.recoveryMessage != nil)
    await fixture.close()
  }

  @Test
  func watchdogRecoversStalledPlaybackButNotIntentionalPause() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.controller.seek(to: 405_000)
    fixture.engine.currentTimeMilliseconds += 1_000
    fixture.engine.onUpdate?()
    fixture.controller.togglePlayback()
    fixture.clock.now = fixture.clock.now.addingTimeInterval(20)
    fixture.controller.checkForStall()
    #expect(fixture.controller.recoveryMessage == nil)
    fixture.controller.togglePlayback()
    fixture.clock.now = fixture.clock.now.addingTimeInterval(20)
    fixture.controller.checkForStall()
    try await fixture.clock.waitForSleeps(1)
    #expect(fixture.controller.recoveryMessage != nil)
    await fixture.close()
  }

  @Test
  func recoveryKeepsIntentionalPauseAndSleepTimerCancelsRecovery() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.controller.seek(to: 405_000)
    fixture.controller.togglePlayback()
    fixture.relay.failure?(.interrupted)
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.waitUntil {
      fixture.client.calls == 2 && fixture.controller.recoveryMessage == nil
    }
    #expect(!fixture.engine.isPlaying)
    #expect(fixture.engine.currentTimeMilliseconds == 405_000)
    fixture.controller.togglePlayback()
    fixture.relay.failure?(.interrupted)
    try await fixture.clock.waitForSleeps(2)
    fixture.controller.setSleepTimer(.minutes(0))
    fixture.clock.wake()
    for _ in 0..<30 { await Task.yield() }
    #expect(fixture.client.calls == 2)
    #expect(!fixture.controller.isPlaying)
    await fixture.close()
  }

  @Test
  func endAndRecoveryPoliciesDoNotConfuseUnavailableWithDenied() {
    #expect(!PlaybackRecoveryPolicy.hasReachedEnd(position: 405_000, duration: 3_486_000))
    #expect(!PlaybackRecoveryPolicy.hasReachedEnd(position: 0, duration: 0))
    #expect(PlaybackRecoveryPolicy.hasReachedEnd(position: 2_800, duration: 3_000))
    #expect(PlaybackRecoveryPolicy.hasReachedEnd(position: 3_485_900, duration: 3_486_000))
    #expect(PlaybackRecoveryPolicy.isRecoverable(Self.offline))
    #expect(!PlaybackRecoveryPolicy.isRecoverable(APIClientError.serverIdentityMismatch))
    #expect(
      !PlaybackRecoveryPolicy.isRecoverable(
        APIClientError.httpFailure(
          status: 403, retryAfter: nil, code: "media_unavailable", message: nil)))
    #expect(
      !PlaybackRecoveryPolicy.isRecoverable(
        APIClientError.httpFailure(
          status: 409, retryAfter: nil, code: "media_file_unavailable", message: nil)))
  }

  @Test
  func naturalEndPolicyAcceptsOnlyTheBoundedReportedClockGap() {
    // Valid synthetic 64-second streams reported native EOF with about 2.15s
    // left in VLC's public clock. This is a bounded classification tolerance,
    // not a guarantee about presentation timestamps or every codec.
    #expect(PlaybackRecoveryPolicy.hasReachedEnd(position: 61_850, duration: 64_000))
    #expect(PlaybackRecoveryPolicy.hasReachedEnd(position: 62_000, duration: 64_000))
    #expect(!PlaybackRecoveryPolicy.hasReachedEnd(position: 60_000, duration: 64_000))
    #expect(!PlaybackRecoveryPolicy.hasReachedEnd(position: 54_000, duration: 64_000))
    #expect(!PlaybackRecoveryPolicy.hasReachedEnd(position: 0, duration: 0))
    #expect(!PlaybackRecoveryPolicy.hasReachedEnd(position: 0, duration: 3_000))
    #expect(!PlaybackRecoveryPolicy.hasReachedEnd(position: 2_000, duration: 3_000))
    #expect(PlaybackRecoveryPolicy.hasReachedEnd(position: 2_800, duration: 3_000))
    #expect(!PlaybackRecoveryPolicy.hasReachedEnd(position: 0, duration: 500))
    #expect(!PlaybackRecoveryPolicy.hasReachedEnd(position: 0, duration: -1))
    #expect(!PlaybackRecoveryPolicy.hasReachedEnd(position: 405_000, duration: 3_486_000))
    #expect(PlaybackRecoveryPolicy.hasReachedEnd(position: 3_486_000 - 2_799, duration: 3_486_000))
    #expect(!PlaybackRecoveryPolicy.hasReachedEnd(position: 3_486_000 - 3_100, duration: 3_486_000))
  }

  @Test
  func boundedNaturalEndCompletesFromTheActualDecoderClockWithoutARequestedSeek() async throws {
    let fixture = RecoveryFixture(includeQueue: false)
    fixture.engine.durationMilliseconds = 64_000
    await fixture.controller.start()
    // No optimistic UI seek is issued. Supply the actual decoder observation
    // followed by its native end callback, as in the verified streaming probe.
    fixture.engine.currentTimeMilliseconds = 61_850
    fixture.engine.onUpdate?()
    fixture.engine.isPlaying = false
    fixture.engine.onEnded?()
    for _ in 0..<100 { await Task.yield() }
    #expect(fixture.controller.currentTimeMilliseconds == 64_000)
    #expect(fixture.controller.durationMilliseconds == 64_000)
    #expect(fixture.controller.presentation.mediaId == fixture.client.mediaID)
    #expect(fixture.client.requestedIDs == [fixture.client.mediaID])
    #expect(fixture.client.updates.contains { $0.isCompleted })
    #expect(fixture.controller.diagnostics.events.filter { $0.kind == .ended }.count == 1)
    #expect(!fixture.controller.diagnostics.events.contains { $0.kind == .recoveryStarted })
    #expect(fixture.controller.recoveryMessage == nil)
    #expect(!fixture.controller.isPlaying)
    await fixture.close()
  }

  @Test
  func hangingInitialTicketIsBoundedAndItsLateResultIsRevoked() async throws {
    let fixture = RecoveryFixture(timing: PlaybackTimingPolicy(ticketTimeout: 0.02))
    fixture.client.holdNextRequest = true
    let started = ContinuousClock.now
    await fixture.controller.start()
    #expect(started.duration(to: .now) < .seconds(1))
    #expect(fixture.engine.loadedURL == nil)
    #expect(
      fixture.controller.diagnostics.events.contains {
        $0.kind == .operationTimedOut && $0.phase == .ticketAuthorization
      })
    fixture.client.releaseRequest()
    try await fixture.waitUntil { fixture.client.revokedIDs.count == 1 }
    #expect(fixture.engine.loadedURL == nil)
    #expect(fixture.client.calls == 1)
    await fixture.close()
  }

  @Test
  func hangingRelayIsBoundedAndStoppedBeforeRecovery() async throws {
    let fixture = RecoveryFixture(timing: PlaybackTimingPolicy(relayTimeout: 0.02))
    fixture.relay.holdNextStart = true
    await fixture.controller.start()
    #expect(fixture.relay.didStop)
    #expect(fixture.engine.loadedURL == nil)
    #expect(fixture.client.revokedIDs.count == 1)
    #expect(
      fixture.controller.diagnostics.events.contains {
        $0.kind == .operationTimedOut && $0.phase == .relayStartup
      })
    await fixture.close()
    fixture.relay.releaseStart()
    for _ in 0..<30 { await Task.yield() }
    #expect(fixture.engine.loadedURL == nil)
  }

  @Test
  func shutdownReachesPreparingRelayWithoutWaitingForItsCompletion() async throws {
    let fixture = RecoveryFixture()
    fixture.relay.holdNextStart = true
    let start = Task { await fixture.controller.start() }
    try await fixture.waitUntil { fixture.relay.pendingStart != nil }
    await fixture.controller.shutdown(saveProgress: false)
    await start.value
    #expect(fixture.relay.didStop)
    #expect(fixture.engine.loadedURL == nil)
    fixture.relay.releaseStart()
    for _ in 0..<30 { await Task.yield() }
    #expect(!fixture.engine.isPlaying)
    #expect(fixture.client.revokedIDs.count == 1)
  }

  @Test
  func incidentBudgetIncludesAHangingTicketAndRequiresExplicitRetry() async throws {
    let fixture = RecoveryFixture(
      timing: PlaybackTimingPolicy(ticketTimeout: 5, incidentTimeout: 0.02))
    fixture.client.holdNextRequest = true
    let started = ContinuousClock.now
    let start = Task { await fixture.controller.start() }
    try await fixture.waitUntil { fixture.client.pendingRequest != nil }
    // The controller's incident clock expires while the non-cooperative call waits.
    fixture.clock.now.addTimeInterval(1)
    await start.value
    try await fixture.waitForError()
    #expect(started.duration(to: .now) < .seconds(1))
    #expect(fixture.client.calls == 1)
    #expect(!fixture.controller.play())
    #expect(!fixture.controller.togglePlayback())
    fixture.client.releaseRequest()
    try await fixture.waitUntil { fixture.client.revokedIDs.count == 1 }
    #expect(!fixture.engine.isPlaying)
    await fixture.close()
  }

  @Test
  func firstMovementDeadlineAppliesEvenIfDecoderSaysItIsPlaying() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    #expect(fixture.controller.isPlaying)
    fixture.clock.now.addTimeInterval(31)
    fixture.controller.checkForStall()
    try await fixture.clock.waitForSleeps(1)
    #expect(
      fixture.controller.diagnostics.events.contains {
        $0.kind == .operationTimedOut && $0.phase == .firstMovement
      })
    await fixture.close()
  }

  @Test
  func shortRecoveriesCannotResetTheSixAttemptLimit() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    for count in 1...6 {
      fixture.relay.failure?(.interrupted)
      try await fixture.clock.waitForSleeps(count)
      fixture.clock.wake()
      try await fixture.waitForPlaying()
      #expect(fixture.clock.delays.last == PlaybackRecoveryPolicy.delays[count - 1])
      fixture.clock.now.addTimeInterval(0.5)
      fixture.engine.currentTimeMilliseconds += 1_000
      fixture.engine.onUpdate?()
    }
    fixture.relay.failure?(.interrupted)
    try await fixture.waitForError()
    #expect(fixture.client.calls == 7)
    #expect(fixture.controller.diagnostics.events.filter { $0.kind == .recovered }.count == 6)
    await fixture.close()
  }

  @Test
  func recoveryIsConfirmedByMovementAndBudgetResetsOnlyAfterStablePlayback() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.relay.failure?(.interrupted)
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.waitForPlaying()
    #expect(!fixture.controller.diagnostics.events.contains { $0.kind == .recovered })
    fixture.controller.seek(to: 60_000)
    #expect(!fixture.controller.diagnostics.events.contains { $0.kind == .recovered })
    for _ in 0..<11 {
      fixture.clock.now.addTimeInterval(1)
      fixture.engine.currentTimeMilliseconds += 1_000
      fixture.engine.onUpdate?()
    }
    #expect(fixture.controller.diagnostics.events.filter { $0.kind == .recovered }.count == 1)
    fixture.relay.failure?(.interrupted)
    try await fixture.clock.waitForSleeps(2)
    #expect(fixture.clock.delays == [1, 1])
    await fixture.close()
  }

  @Test
  func briefBufferingCannotCombineSeparateStablePlaybackIntervals() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.relay.failure?(.interrupted)
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.waitForPlaying()
    for _ in 0..<9 {
      fixture.clock.now.addTimeInterval(1)
      fixture.engine.currentTimeMilliseconds += 1_000
      fixture.engine.onUpdate?()
    }
    fixture.engine.isPlaying = false
    fixture.engine.onUpdate?()
    fixture.clock.now.addTimeInterval(0.5)
    fixture.engine.isPlaying = true
    fixture.engine.onUpdate?()
    for _ in 0..<3 {
      fixture.clock.now.addTimeInterval(1)
      fixture.engine.currentTimeMilliseconds += 1_000
      fixture.engine.onUpdate?()
    }
    fixture.relay.failure?(.interrupted)
    try await fixture.clock.waitForSleeps(2)
    #expect(fixture.clock.delays == [1, 2])
    await fixture.close()
  }

  @Test
  func backwardSeekAcknowledgementKeepsActualProgressAliveButAConstantClockStillStalls()
    async throws
  {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.controller.seek(to: 45_000)
    fixture.engine.currentTimeMilliseconds = 46_000
    fixture.engine.onUpdate?()
    fixture.engine.deferSeekStateChange = true
    fixture.controller.seek(to: 5_000)
    #expect(fixture.engine.pendingSeekTarget == 5_000)
    // The native seek is asynchronous. Its preceding input can deliver one
    // more old-clock update before acknowledging the requested lower position.
    fixture.engine.onUpdate?()
    fixture.engine.completeDeferredSeek()
    #expect(fixture.controller.currentTimeMilliseconds == 5_000)

    for _ in 0..<20 {
      fixture.clock.now.addTimeInterval(1)
      fixture.engine.currentTimeMilliseconds += 1_000
      fixture.engine.onUpdate?()
      fixture.controller.checkForStall()
      #expect(fixture.controller.recoveryMessage == nil)
      #expect(fixture.controller.isPlaying)
    }
    #expect(fixture.client.calls == 1)
    #expect(
      !fixture.controller.diagnostics.events.contains { $0.kind == .recoveryStarted })

    // Do not weaken the watchdog to fix the seek race: an actually constant
    // decoder clock must still start recovery after its existing 15-second limit.
    fixture.clock.now.addTimeInterval(16)
    fixture.controller.checkForStall()
    try await fixture.clock.waitForSleeps(1)
    #expect(fixture.controller.recoveryCause == .stalled)
    await fixture.close()
  }

  @Test
  func backwardClockAcknowledgementDoesNotResetRecoveryBudgetOrClaimRecovery() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.relay.failure?(.interrupted)
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.waitForPlaying()
    for _ in 0..<9 {
      fixture.clock.now.addTimeInterval(1)
      fixture.engine.currentTimeMilliseconds += 1_000
      fixture.engine.onUpdate?()
    }
    #expect(fixture.controller.diagnostics.events.filter { $0.kind == .recovered }.count == 1)
    fixture.engine.deferSeekStateChange = true
    fixture.controller.seek(to: 5_000)
    fixture.engine.onUpdate?()
    fixture.engine.completeDeferredSeek()
    #expect(fixture.controller.diagnostics.events.filter { $0.kind == .recovered }.count == 1)
    for _ in 0..<2 {
      fixture.clock.now.addTimeInterval(1)
      fixture.engine.currentTimeMilliseconds += 1_000
      fixture.engine.onUpdate?()
    }
    fixture.relay.failure?(.interrupted)
    try await fixture.clock.waitForSleeps(2)
    #expect(fixture.clock.delays == [1, 2])
    await fixture.close()
  }

  @Test
  func staleZeroBeforeRecoveryResumeAcknowledgementCannotClaimActualMovement() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.controller.seek(to: 44_000)
    fixture.engine.currentTimeMilliseconds = 45_000
    fixture.engine.onUpdate?()
    fixture.engine.deferSeekStateChange = true
    fixture.relay.failure?(.interrupted)
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.waitForPlaying()
    #expect(fixture.engine.pendingSeekTarget == 45_000)
    #expect(!fixture.controller.diagnostics.events.contains { $0.kind == .recovered })
    fixture.engine.onUpdate?()
    #expect(fixture.engine.currentTimeMilliseconds == 0)
    fixture.engine.completeDeferredSeek()
    #expect(fixture.controller.currentTimeMilliseconds == 45_000)
    #expect(!fixture.controller.diagnostics.events.contains { $0.kind == .recovered })
    fixture.clock.now.addTimeInterval(1)
    fixture.engine.currentTimeMilliseconds += 1_000
    fixture.engine.onUpdate?()
    #expect(fixture.controller.diagnostics.events.filter { $0.kind == .recovered }.count == 1)
    await fixture.close()
  }

  @Test
  func pauseDuringPendingStartupOrRecoveryNeverStartsPreparedAudio() async throws {
    let fixture = RecoveryFixture()
    fixture.client.holdNextRequest = true
    let start = Task { await fixture.controller.start() }
    try await fixture.waitUntil { fixture.client.pendingRequest != nil }
    #expect(fixture.controller.pause())
    #expect(fixture.controller.pause())
    fixture.client.releaseRequest()
    await start.value
    #expect(fixture.engine.playCalls == 0)
    #expect(!fixture.controller.isPlaying)
    #expect(fixture.controller.play())
    #expect(fixture.controller.play())
    #expect(fixture.engine.playCalls == 1)
    fixture.relay.failure?(.interrupted)
    try await fixture.clock.waitForSleeps(1)
    #expect(fixture.controller.pause())
    fixture.clock.wake()
    try await fixture.waitUntil {
      fixture.client.calls == 2 && fixture.controller.recoveryMessage == nil
    }
    #expect(fixture.engine.playCalls == 1)
    #expect(!fixture.controller.isPlaying)
    #expect(fixture.controller.play())
    #expect(fixture.engine.playCalls == 2)
    await fixture.close()
  }

  @Test
  func pauseDuringQueueCleanupIsRetainedForTheNextEpisode() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.client.holdNextRevocation = true
    fixture.engine.currentTimeMilliseconds = fixture.engine.durationMilliseconds
    fixture.engine.isPlaying = false
    fixture.engine.onEnded?()
    #expect(fixture.controller.pause())
    try await fixture.waitUntil { fixture.client.pendingRevocation != nil }
    fixture.client.releaseRevocation()
    try await fixture.waitUntil {
      fixture.controller.presentation.mediaId == fixture.nextID && fixture.client.calls == 2
        && fixture.controller.recoveryMessage == nil
    }
    // Wait for the new relay preparation, not merely the request to be dispatched.
    try await fixture.waitUntil {
      fixture.controller.diagnostics.events.filter { $0.kind == .prepared }.count == 2
    }
    #expect(!fixture.controller.isPlaying)
    #expect(fixture.engine.playCalls == 1)
    #expect(fixture.controller.play())
    #expect(fixture.engine.playCalls == 2)
    await fixture.close()
  }

  @Test
  func repeatedPlayAndPauseCommandsAreIdempotent() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    #expect(fixture.controller.play())
    #expect(fixture.engine.playCalls == 1)
    #expect(fixture.controller.pause())
    #expect(fixture.controller.pause())
    #expect(fixture.engine.pauseCalls == 1)
    #expect(!fixture.engine.isPlaying)
    #expect(fixture.controller.play())
    #expect(fixture.controller.play())
    #expect(fixture.engine.playCalls == 2)
    await fixture.close()
    #expect(!fixture.controller.play() && !fixture.controller.pause())
  }

  @Test
  func detailedPermanentFileFailureStopsAndNeverLooksLikeLostConnection() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    fixture.relay.failure?(
      .detailed(
        PlaybackFailureContext(
          error: APIClientError.httpFailure(
            status: 409, retryAfter: nil, code: "media_file_unavailable", message: "private path"),
          phase: .streamTransport)))
    #expect(fixture.controller.recoveryCause == .mediaFileUnavailable)
    #expect(!fixture.controller.play())
    #expect(!fixture.controller.togglePlayback())
    #expect(fixture.clock.delays.isEmpty)
    #expect(fixture.client.calls == 1)
    let exported = String(decoding: try fixture.controller.diagnostics.export(), as: UTF8.self)
    #expect(!exported.contains("private path"))
    #expect(exported.contains("media_file_unavailable"))
    await fixture.close()
  }

  @Test
  func opaqueMissingStreamTicketCanBeReauthorizedOnlyOnce() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    let failure = PlaybackStreamFailure.detailed(
      PlaybackFailureContext(
        error: APIClientError.httpFailure(status: 404, retryAfter: nil, code: nil, message: nil),
        phase: .streamTransport))
    fixture.relay.failure?(failure)
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.waitForPlaying()
    fixture.relay.failure?(failure)
    #expect(fixture.controller.errorMessage != nil)
    #expect(fixture.client.calls == 2)
    #expect(fixture.clock.delays == [1])
    await fixture.close()
  }

  @Test
  func rateLimitHonorsSafeRetryAfterAndRejectsUnlistedDiagnosticStrings() async throws {
    let fixture = RecoveryFixture()
    await fixture.controller.start()
    let context = PlaybackFailureContext(
      cause: .rateLimited, phase: .streamTransport, httpStatus: 429,
      problemCode: "private path", bytesTransferred: -1, retryAfter: 7,
      localReason: "private token")
    fixture.relay.failure?(.detailed(context))
    try await fixture.clock.waitForSleeps(1)
    #expect(fixture.clock.delays == [7])
    #expect(context.problemCode == nil && context.localReason == nil)
    #expect(context.bytesTransferred == 0)
    let exported = String(decoding: try fixture.controller.diagnostics.export(), as: UTF8.self)
    #expect(!exported.contains("private path") && !exported.contains("private token"))
    await fixture.close()
  }

  @Test
  func serverStreamLimitIsClassifiedAndExportedInTheVersionTwoSchema() throws {
    let context = PlaybackFailureContext(
      error: APIClientError.httpFailure(
        status: 429, retryAfter: 7, code: "stream_limit", message: "Private server details"),
      phase: .ticketAuthorization)
    #expect(context.cause == .rateLimited && context.isRecoverable)
    #expect(context.problemCode == "stream_limit" && context.retryAfter == 7)
    let diagnostics = PlaybackDiagnostics()
    diagnostics.record(
      .failureObserved, cause: context.cause, position: 0, duration: 0,
      phase: context.phase, httpStatus: context.httpStatus, problemCode: context.problemCode,
      retryAfter: context.retryAfter)
    let data = try diagnostics.export()
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["formatVersion"] as? Int == 2)
    let events = try #require(json["events"] as? [[String: Any]])
    #expect(events.first?["problemCode"] as? String == "stream_limit")
    #expect(!String(decoding: data, as: UTF8.self).contains("Private server details"))
  }

  private static var offline: APIClientError {
    .httpFailure(status: 503, retryAfter: nil, code: "media_unavailable", message: "Drive offline")
  }
}

@MainActor
private final class RecoveryFixture {
  let client: RecoveryClient
  let engine = FakePlaybackEngine()
  let relay = RecoveryRelay()
  let clock = RecoveryClock()
  let nextID = UUID()
  let controller: PlaybackController

  init(
    outcomes: [Result<Void, Error>] = [], preferences: PlaybackPreferences = .defaultValue,
    includeQueue: Bool = true, timing: PlaybackTimingPolicy = PlaybackTimingPolicy()
  ) {
    client = RecoveryClient(outcomes: outcomes)
    engine.durationMilliseconds = 3_486_000
    controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: client.mediaID, title: "Synthetic Episode 1", subtitle: nil,
        queue: includeQueue
          ? [PlaybackQueueItem(mediaId: nextID, title: "Synthetic Episode 2", subtitle: nil)] : []),
      engine: engine, preferences: preferences, relayFactory: { [relay] _, _ in relay },
      recoveryClock: { [clock] in clock.now }, recoverySleep: clock.sleep, timing: timing)
  }

  func waitForPlaying() async throws {
    try await waitUntil { controller.isPlaying && controller.recoveryMessage == nil }
  }
  func waitForError() async throws {
    try await waitUntil { controller.errorMessage != nil && !controller.isPreparing }
  }
  func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
    for _ in 0..<2_000 {
      if predicate() { return }
      await Task.yield()
    }
    throw URLError(.timedOut)
  }
  func close() async {
    await controller.shutdown(saveProgress: false)
    clock.wake()
  }
}

@MainActor
private final class RecoveryClock {
  var now = Date()
  var delays: [TimeInterval] = []
  var pending: CheckedContinuation<Void, Error>?
  func sleep(_ delay: TimeInterval) async throws {
    delays.append(delay)
    try await withCheckedThrowingContinuation { pending = $0 }
  }
  func wake() {
    let continuation = pending
    pending = nil
    continuation?.resume()
  }
  func waitForSleeps(_ count: Int) async throws {
    for _ in 0..<2_000 {
      if delays.count >= count, pending != nil { return }
      await Task.yield()
    }
    throw URLError(.timedOut)
  }
}

@MainActor
private final class RecoveryRelay: PlaybackRelayProtocol {
  var failure: (@MainActor @Sendable (PlaybackStreamFailure) -> Void)?
  var didStop = false
  var holdNextStart = false
  var pendingStart: CheckedContinuation<Void, Never>?
  func start() async throws -> URL {
    if holdNextStart {
      holdNextStart = false
      await withCheckedContinuation { pendingStart = $0 }
    }
    return URL(string: "http://127.0.0.1:54321/stream/synthetic")!
  }
  func releaseStart() {
    let continuation = pendingStart
    pendingStart = nil
    continuation?.resume()
  }
  func setFailureHandler(_ handler: @escaping @MainActor @Sendable (PlaybackStreamFailure) -> Void)
  {
    failure = handler
  }
  func stop() { didStop = true }
  func updateSourceURL(_ url: URL) {}
}

@MainActor
private final class RecoveryClient: PlaybackClientProtocol {
  let mediaID = UUID()
  let profile = StoredServerProfile(
    serverId: UUID(), name: "Synthetic", baseURL: URL(string: "https://fixture.invalid")!,
    publicKeyFingerprint: String(repeating: "A", count: 64), token: "test-only",
    sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z")
  var outcomes: [Result<Void, Error>]
  var calls = 0
  var requestedIDs: [UUID] = []
  var updates: [PlaybackProgressResponse] = []
  var revokedIDs: [UUID] = []
  var holdNextRequest = false
  var pendingRequest: CheckedContinuation<Void, Never>?
  var holdNextRevocation = false
  var pendingRevocation: CheckedContinuation<Void, Never>?
  init(outcomes: [Result<Void, Error>]) { self.outcomes = outcomes }
  func createPlayback(mediaId: UUID) async throws -> PlaybackSourceResponse {
    calls += 1
    requestedIDs.append(mediaId)
    if holdNextRequest {
      holdNextRequest = false
      await withCheckedContinuation { pendingRequest = $0 }
    }
    if calls > 1, !outcomes.isEmpty { try outcomes.removeFirst().get() }
    return PlaybackSourceResponse(
      id: UUID(), mediaId: mediaId, streamPath: "/api/v1/streams/synthetic",
      contentType: "video/mp4", contentLength: 100, expiresAt: "2099-01-01T00:00:00Z",
      progress: PlaybackProgressResponse(
        mediaId: mediaId, positionMilliseconds: 0, durationMilliseconds: 3_486_000,
        isCompleted: false, lastPlayedAt: nil, updatedAt: nil))
  }
  func updatePlaybackProgress(
    mediaId: UUID, positionMilliseconds: Int64, durationMilliseconds: Int64, isFinished: Bool
  ) async throws -> PlaybackProgressResponse {
    let progress = PlaybackProgressResponse(
      mediaId: mediaId, positionMilliseconds: positionMilliseconds,
      durationMilliseconds: durationMilliseconds, isCompleted: isFinished,
      lastPlayedAt: nil, updatedAt: nil)
    updates.append(progress)
    return progress
  }
  func releaseRequest() {
    let request = pendingRequest
    pendingRequest = nil
    request?.resume()
  }
  func releaseRevocation() {
    let request = pendingRevocation
    pendingRevocation = nil
    request?.resume()
  }
  func revokePlayback(id: UUID) async throws {
    revokedIDs.append(id)
    if holdNextRevocation {
      holdNextRevocation = false
      await withCheckedContinuation { pendingRevocation = $0 }
    }
  }
  func streamURL(path: String) throws -> URL {
    URL(string: path, relativeTo: profile.baseURL)!.absoluteURL
  }
}
