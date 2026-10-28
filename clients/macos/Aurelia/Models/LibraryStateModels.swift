import Foundation

enum CatalogWatchState: String, Codable, Sendable {
  case unplayed, inProgress, completed
}

enum WatchStateScope: String, Codable, Sendable {
  case title, season, series
}

enum PlaybackPlanAction: String, Codable, Sendable {
  case play, resume, playAgain
}

struct PlaybackPlanResponse: Codable, Equatable, Sendable {
  let target: CatalogItemSummary?
  let seriesId: UUID?
  let queue: [CatalogItemSummary]
  let action: PlaybackPlanAction
  let continueWatchingEligible: Bool

  var presentation: PlaybackPresentation? { makePresentation() }

  func makePresentation(
    intent: PlaybackStartIntent? = nil, previousItems: [PlaybackQueueItem] = []
  ) -> PlaybackPresentation? {
    guard let target, target.isPlayable else { return nil }
    return PlaybackPresentation(
      mediaId: target.id, title: target.title,
      subtitle: CatalogPlaybackLogic.subtitle(for: target),
      queue: queue.filter { $0.isPlayable }.map {
        PlaybackQueueItem(
          mediaId: $0.id, title: $0.title, subtitle: CatalogPlaybackLogic.subtitle(for: $0),
          artwork: CatalogPlaybackLogic.artwork(for: $0))
      }, previousItems: previousItems, startIntent: intent ?? (action == .resume ? .resume : .play),
      trackScope: seriesId, artwork: CatalogPlaybackLogic.artwork(for: target))
  }
}

struct WatchStateResponse: Codable, Equatable, Sendable {
  let mediaId: UUID
  let scope: WatchStateScope
  let seasonNumber: Int?
  let watchState: CatalogWatchState
  let affectedCount: Int
  let stateToken: String
  let continueWatchingHidden: Bool
}

struct SetWatchStateRequest: Encodable, Sendable {
  let isWatched: Bool
  let scope: WatchStateScope
  let seasonNumber: Int?
  let stateToken: String
  let clientMutationId: UUID
}

struct SetContinueWatchingRequest: Encodable, Sendable {
  let isHidden: Bool
  let stateToken: String
  let clientMutationId: UUID
}

@MainActor
protocol LibraryStateServing {
  func playbackPlan(mediaId: UUID) async throws -> PlaybackPlanResponse
  func watchState(mediaId: UUID, scope: WatchStateScope, seasonNumber: Int?) async throws
    -> WatchStateResponse
  func setWatchState(mediaId: UUID, request: SetWatchStateRequest) async throws
    -> WatchStateResponse
  func setContinueWatchingHidden(mediaId: UUID, request: SetContinueWatchingRequest) async throws
    -> WatchStateResponse
}

extension APIClient: LibraryStateServing {}
