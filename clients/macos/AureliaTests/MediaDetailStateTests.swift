import Foundation
import Testing

@testable import Aurelia

@MainActor
struct MediaDetailStateTests {
  @Test func aggregateConfirmationKeepsItsOriginalTokenAndSubmitsOnce() async throws {
    let controller = MediaWatchActionController()
    let original = state(count: 12, token: "original")
    var writes: [(String, Bool, UUID)] = []
    await controller.prepare(
      isWatched: false, aggregate: true, fetch: { original },
      apply: { response, watched, id in writes.append((response.stateToken, watched, id)) })
    let pending = try #require(controller.pendingAction)
    #expect(pending.title == "Mark 12 episodes as unwatched?")
    #expect(pending.message.contains("resets playback positions"))
    #expect(writes.isEmpty && !controller.isWorking)
    let confirmation = try #require(controller.confirm())
    #expect(controller.confirm() == nil)
    // Dismissing a native confirmation must not cancel its already accepted action.
    controller.cancelConfirmation()
    await confirmation.value
    #expect(writes.count == 1)
    #expect(writes[0].0 == "original" && !writes[0].1)
    #expect(writes[0].2 == pending.clientMutationId)
    #expect(controller.pendingAction == nil && !controller.isWorking)
  }

  @Test func directActionBlocksDuplicateCommandsWhileReadingState() async throws {
    let controller = MediaWatchActionController()
    var reply: CheckedContinuation<WatchStateResponse, Never>?
    var writeCount = 0
    let first = Task {
      await controller.prepare(
        isWatched: true, aggregate: false,
        fetch: { await withCheckedContinuation { reply = $0 } },
        apply: { _, _, _ in writeCount += 1 })
    }
    while reply == nil { await Task.yield() }
    await controller.prepare(
      isWatched: true, aggregate: false,
      fetch: {
        Issue.record("Duplicate command read server state")
        return state()
      },
      apply: { _, _, _ in Issue.record("Duplicate command submitted a write") })
    reply?.resume(returning: state())
    await first.value
    #expect(writeCount == 1 && controller.pendingAction == nil && !controller.isWorking)
  }

  @Test func obsoleteFetchCannotReplaceNewProfileConfirmation() async throws {
    let controller = MediaWatchActionController()
    var reply: CheckedContinuation<WatchStateResponse, Never>?
    let old = Task {
      await controller.prepare(
        isWatched: true, aggregate: true,
        fetch: { await withCheckedContinuation { reply = $0 } },
        apply: { _, _, _ in Issue.record("Obsolete profile confirmation was applied") })
    }
    while reply == nil { await Task.yield() }
    controller.invalidate()
    var writtenToken: String?
    await controller.prepare(
      isWatched: false, aggregate: true, fetch: { state(count: 3, token: "new-profile") },
      apply: { response, _, _ in writtenToken = response.stateToken })
    reply?.resume(returning: state(count: 99, token: "old-profile"))
    await old.value
    #expect(controller.pendingAction?.state.affectedCount == 3)
    await controller.confirm()?.value
    #expect(writtenToken == "new-profile")
  }

  @Test func cancelledConfirmationAndConflictsNeverReplayWrites() async throws {
    let controller = MediaWatchActionController()
    var writes = 0
    await controller.prepare(
      isWatched: true, aggregate: true, fetch: { state() },
      apply: { _, _, _ in writes += 1 })
    controller.invalidate()
    #expect(controller.confirm() == nil && writes == 0)
    await controller.prepare(
      isWatched: true, aggregate: true, fetch: { state() },
      apply: { _, _, _ in
        writes += 1
        throw APIClientError.httpFailure(
          status: 409, retryAfter: nil, code: "state_conflict",
          message: "The watched status changed. Try again.")
      })
    await controller.confirm()?.value
    #expect(writes == 1 && controller.errorMessage == "The watched status changed. Try again.")
    #expect(controller.pendingAction == nil && controller.confirm() == nil)
  }

  @Test func staleVisibilityFailureDoesNotAffectNewProfile() async {
    let controller = MediaWatchActionController()
    var reply: CheckedContinuation<Void, any Error>?
    let old = Task {
      await controller.changeVisibility {
        try await withCheckedThrowingContinuation { reply = $0 }
      }
    }
    while reply == nil { await Task.yield() }
    controller.invalidate()
    await controller.changeVisibility {}
    reply?.resume(throwing: URLError(.notConnectedToInternet))
    await old.value
    #expect(controller.errorMessage == nil && !controller.isWorking)
  }

  @Test func cancelledStateReadLeavesActionsUsableAndDoesNotWrite() async {
    let controller = MediaWatchActionController()
    var reply: CheckedContinuation<WatchStateResponse, Never>?
    let task = Task {
      await controller.prepare(
        isWatched: true, aggregate: false,
        fetch: { await withCheckedContinuation { reply = $0 } },
        apply: { _, _, _ in Issue.record("Cancelled state request submitted a mutation") })
    }
    while reply == nil { await Task.yield() }
    task.cancel()
    reply?.resume(returning: state())
    await task.value
    #expect(
      !controller.isWorking && controller.pendingAction == nil && controller.errorMessage == nil)
  }

  @Test func storageMessagesDistinguishDriveFileAndAccessFailure() {
    #expect(
      MediaAvailabilityPresentation.message(
        availability: .missing, libraryAvailability: .unavailable)
        == "Media drive disconnected")
    #expect(
      MediaAvailabilityPresentation.message(availability: .missing, libraryAvailability: .available)
        == "Media file unavailable")
    #expect(
      MediaAvailabilityPresentation.message(availability: .error, libraryAvailability: .available)
        == "Media access unavailable")
    #expect(
      MediaAvailabilityPresentation.message(availability: .available, libraryAvailability: .error)
        == "Media access unavailable")
    #expect(
      MediaAvailabilityPresentation.message(availability: .available, libraryAvailability: nil)
        == nil)
    #expect(
      MediaAvailabilityPresentation.message(availability: .available, libraryAvailability: .unknown)
        == nil)
    #expect(!MediaAvailabilityPresentation.canPlay(item(kind: .series)))
    #expect(!MediaAvailabilityPresentation.canPlay(item(libraryAvailability: .unavailable)))
  }

  @Test func primaryLabelNamesResolvedEpisodeAndCompletedStateDoesNotShowProgress() {
    let series = item(kind: .series)
    let detail = CatalogDetailPresentation(
      item: series, metadata: metadata(series.id), seasons: [], supplements: [])
    let episode = item(kind: .episode, season: 2, episode: 5)
    for (action, prefix) in [
      (PlaybackPlanAction.play, "Play"), (.resume, "Resume"), (.playAgain, "Play Again"),
    ] {
      let plan = PlaybackPlanResponse(
        target: episode, seriesId: series.id, queue: [], action: action,
        continueWatchingEligible: true)
      #expect(DetailPlaybackPresentation.label(detail: detail, plan: plan) == "\(prefix) S02 E05")
    }
    #expect(MediaWatchPresentation.isWatched(item(watchState: .completed)))
    #expect(!MediaWatchPresentation.isWatched(item(watchState: .inProgress)))
    #expect(!MediaWatchPresentation.isWatched(item(watchState: .unplayed)))
  }

  private func state(count: Int = 1, token: String = "synthetic-state") -> WatchStateResponse {
    WatchStateResponse(
      mediaId: UUID(), scope: count == 1 ? .title : .series, seasonNumber: nil,
      watchState: .unplayed, affectedCount: count, stateToken: token, continueWatchingHidden: false)
  }

  private func item(
    kind: MediaKind = .movie, season: Int? = nil, episode: Int? = nil,
    watchState: CatalogWatchState? = nil, libraryAvailability: LibraryAvailability? = nil
  ) -> CatalogItemSummary {
    CatalogItemSummary(
      id: UUID(), kind: kind, title: "Synthetic", originalTitle: nil, year: nil,
      overview: nil, genres: [], poster: nil, backdrop: nil, availability: .available,
      isFavorite: false, progress: nil, addedAt: "2026-10-14T00:00:00Z",
      seasonNumber: season, episodeNumber: episode, watchState: watchState,
      libraryAvailability: libraryAvailability)
  }

  private func metadata(_ id: UUID) -> MediaMetadataSummary {
    MediaMetadataSummary(
      mediaId: id, title: "Synthetic Series", originalTitle: nil, overview: nil,
      releaseDate: nil, year: nil, runtimeMinutes: nil, rating: nil, contentRating: nil,
      genres: [], studios: [], countries: [], credits: [], poster: nil, backdrop: nil, still: nil,
      provider: nil, providerMediaId: nil, reviewState: .needsReview)
  }
}
