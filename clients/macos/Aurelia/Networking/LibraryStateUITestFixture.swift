#if DEBUG
  import Foundation

  @MainActor enum LibraryStateUITestFixture {
    static var enabled: Bool {
      ProcessInfo.processInfo.environment["AURELIA_LIBRARY_STATE_UI_TESTS"] == "1"
        && ["library", "library-admin"].contains(
          ProcessInfo.processInfo.environment["AURELIA_UI_TEST_MODE"] ?? "")
    }
    static let seriesID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    static let movieID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private static var version = 1
    private static var hidden: Set<UUID> = []
    private static var changes: [UUID: PlaybackProgressResponse] = [
      episodeID(1, 1): progress(episodeID(1, 1), position: 0, completed: true),
      episodeID(1, 2): progress(episodeID(1, 2), position: 35_000),
      movieID: progress(movieID, position: 35_000),
    ]

    private static func episodeID(_ season: Int, _ episode: Int) -> UUID {
      UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", season * 100 + episode))!
    }

    private static func progress(_ id: UUID, position: Int64, completed: Bool = false)
      -> PlaybackProgressResponse
    {
      PlaybackProgressResponse(
        mediaId: id, positionMilliseconds: position, durationMilliseconds: 120_000,
        isCompleted: completed,
        lastPlayedAt: completed ? "2026-10-14T09:00:00Z" : "2026-10-14T10:00:00Z",
        updatedAt: "2026-10-14T10:00:00Z", revision: Int64(version))
    }

    private static func rawEpisodes(_ catalog: [CatalogItemSummary]) -> [CatalogItemSummary] {
      guard let show = catalog.first(where: { $0.kind == .series }) else { return [] }
      return CinemaUITestFixture.detail(show).seasons.flatMap(\.episodes).map {
        var item = $0.item
        item.parentId = show.id
        return item
      }
    }

    static func decorate(_ item: CatalogItemSummary) -> CatalogItemSummary {
      guard enabled else { return item }
      var result = item
      result.libraryAvailability = .available
      result.continueWatchingHidden = hidden.contains(item.parentId ?? item.id)
      if let changed = changes[item.id] {
        result = CatalogItemSummary(
          id: item.id, kind: item.kind, title: item.title,
          originalTitle: item.originalTitle, year: item.year, overview: item.overview,
          genres: item.genres,
          poster: item.poster, backdrop: item.backdrop, availability: item.availability,
          isFavorite: item.isFavorite,
          progress: changed, addedAt: item.addedAt, parentTitle: item.parentTitle,
          seasonNumber: item.seasonNumber,
          episodeNumber: item.episodeNumber, libraryAvailability: .available,
          parentId: item.parentId,
          continueWatchingHidden: hidden.contains(item.parentId ?? item.id))
      }
      if item.kind == .series {
        let episodes = rawEpisodes([item])
        result.watchState = state(episodes.map { changes[$0.id] ?? $0.progress })
      } else {
        result.watchState = state([result.progress])
      }
      if ProcessInfo.processInfo.environment["AURELIA_LIBRARY_STATE_DRIVE_UI_TESTS"] == "1",
        item.id == episodeID(1, 2)
      {
        result.libraryAvailability = .unavailable
      }
      return result
    }

    private static func state(_ values: [PlaybackProgressResponse?]) -> CatalogWatchState {
      if !values.isEmpty, values.allSatisfy({ $0?.isCompleted == true }) { return .completed }
      if values.contains(where: {
        $0?.isCompleted == true || ($0?.positionMilliseconds ?? 0) > 10_000
      }) {
        return .inProgress
      }
      return .unplayed
    }

    static func playbackProgress(mediaId: UUID) -> PlaybackProgressResponse {
      changes[mediaId]
        ?? PlaybackProgressResponse(
          mediaId: mediaId, positionMilliseconds: 0,
          durationMilliseconds: 120_000, isCompleted: false, lastPlayedAt: nil, updatedAt: nil)
    }

    static func detail(_ item: CatalogItemSummary) -> CatalogDetailPresentation {
      let base = CinemaUITestFixture.detail(item)
      return CatalogDetailPresentation(
        item: decorate(base.item), metadata: base.metadata,
        seasons: base.seasons.map { season in
          SeasonPresentation(
            number: season.number,
            episodes: season.episodes.map {
              var episode = $0.item
              episode.parentId = item.id
              return EpisodePresentation(
                item: decorate(episode), seasonNumber: $0.seasonNumber,
                episodeNumber: $0.episodeNumber)
            }, supplements: season.supplements)
        }, supplements: base.supplements)
    }

    static func browse(_ input: [CatalogItemSummary], query: CatalogBrowseQuery, search: String)
      -> [CatalogItemSummary]
    {
      let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
      var items = (enabled ? input + rawEpisodes(input) : input).map(decorate)
      if search.isEmpty { items = items.filter { $0.kind == .movie || $0.kind == .series } }
      if !search.isEmpty {
        items = items.filter {
          ([$0.title, $0.parentTitle ?? "", $0.originalTitle ?? "", $0.overview ?? ""] + $0.genres)
            .joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
      }
      items = items.filter { item in
        (query.kind == nil || item.kind == query.kind)
          && (!query.favoritesOnly || item.isFavorite)
          && (query.genre == nil || item.genres.contains(query.genre!))
          && (query.yearFrom == nil || (item.year ?? 0) >= query.yearFrom!)
          && (query.yearTo == nil || (item.year ?? 0) <= query.yearTo!)
          && (query.watchState == .all
            || (query.watchState == .unwatched
              && (item.watchState ?? state([item.progress])) == .unplayed)
            || (query.watchState == .inProgress
              && (item.watchState ?? state([item.progress])) == .inProgress)
            || (query.watchState == .watched
              && (item.watchState ?? state([item.progress])) == .completed))
      }
      items.sort {
        let ascending: Bool
        switch query.sort ?? .title {
        case .title:
          ascending = $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        case .dateAdded: ascending = $0.addedAt < $1.addedAt
        case .releaseYear:
          ascending =
            ($0.year ?? 0) == ($1.year ?? 0) ? $0.title < $1.title : ($0.year ?? 0) < ($1.year ?? 0)
        case .lastPlayed:
          ascending = ($0.progress?.lastPlayedAt ?? "") < ($1.progress?.lastPlayedAt ?? "")
        }
        if query.descending { return !ascending && $0.id != $1.id }
        return ascending
      }
      return items
    }

    static func playbackPlan(mediaId: UUID, catalog: [CatalogItemSummary]) throws
      -> PlaybackPlanResponse
    {
      let episodes = rawEpisodes(catalog).map(decorate)
      let items = catalog.map(decorate) + episodes
      guard let requested = items.first(where: { $0.id == mediaId }) else {
        throw APIClientError.invalidResponse
      }
      let target: CatalogItemSummary?
      if requested.kind == .series {
        let latest = episodes.filter { $0.progress?.lastPlayedAt != nil }.sorted {
          ($0.progress?.lastPlayedAt ?? "") > ($1.progress?.lastPlayedAt ?? "")
        }.first
        if let latest {
          target =
            latest.progress?.isCompleted == true
            ? episodes.drop(while: { $0.id != latest.id }).dropFirst().first {
              $0.progress?.isCompleted != true
            } ?? episodes.first
            : latest
        } else {
          target = episodes.first { $0.progress?.isCompleted != true } ?? episodes.first
        }
      } else {
        target = requested
      }
      let queue =
        target?.kind == .episode
        ? Array(episodes.drop(while: { $0.id != target?.id }).dropFirst()) : []
      return PlaybackPlanResponse(
        target: target, seriesId: requested.kind == .movie ? nil : seriesID,
        queue: queue,
        action: (target?.progress?.positionMilliseconds ?? 0) > 10_000
          && target?.progress?.isCompleted != true
          ? .resume : (requested.watchState == .completed ? .playAgain : .play),
        continueWatchingEligible: target?.watchState == .inProgress
          || (requested.kind == .series && target?.watchState != .completed
            && episodes.contains { $0.progress?.isCompleted == true })
      )
    }

    private static func targets(
      _ id: UUID, scope: WatchStateScope, seasonNumber: Int?, catalog: [CatalogItemSummary]
    ) -> [CatalogItemSummary] {
      if id == seriesID {
        return rawEpisodes(catalog).filter { scope != .season || $0.seasonNumber == seasonNumber }
      }
      return (catalog + rawEpisodes(catalog)).filter { $0.id == id }
    }

    static func watchState(
      mediaId: UUID, scope: WatchStateScope, seasonNumber: Int?, catalog: [CatalogItemSummary]
    ) throws -> WatchStateResponse {
      let values = targets(mediaId, scope: scope, seasonNumber: seasonNumber, catalog: catalog)
      guard !values.isEmpty else { throw APIClientError.invalidResponse }
      return WatchStateResponse(
        mediaId: mediaId, scope: scope, seasonNumber: seasonNumber,
        watchState: state(values.map { changes[$0.id] ?? $0.progress }),
        affectedCount: values.count,
        stateToken: String(version), continueWatchingHidden: hidden.contains(mediaId))
    }

    static func setWatchState(
      mediaId: UUID, request: SetWatchStateRequest, catalog: [CatalogItemSummary]
    ) throws -> WatchStateResponse {
      guard request.stateToken == String(version) else {
        throw APIClientError.httpFailure(
          status: 409, retryAfter: nil, code: "watch_state_conflict",
          message: "Watch state changed. Try again.")
      }
      version += 1
      for item in targets(
        mediaId, scope: request.scope, seasonNumber: request.seasonNumber, catalog: catalog)
      {
        let original = changes[item.id] ?? item.progress
        changes[item.id] = PlaybackProgressResponse(
          mediaId: item.id, positionMilliseconds: 0,
          durationMilliseconds: original?.durationMilliseconds ?? 0, isCompleted: request.isWatched,
          lastPlayedAt: original?.lastPlayedAt,
          updatedAt: "2026-10-14T12:00:00Z", revision: Int64(version))
      }
      return try watchState(
        mediaId: mediaId, scope: request.scope, seasonNumber: request.seasonNumber, catalog: catalog
      )
    }

    static func setContinueWatchingHidden(
      mediaId: UUID, request: SetContinueWatchingRequest, catalog: [CatalogItemSummary]
    ) throws -> WatchStateResponse {
      guard request.stateToken == String(version) else { throw APIClientError.invalidResponse }
      if request.isHidden { hidden.insert(mediaId) } else { hidden.remove(mediaId) }
      version += 1
      return try watchState(mediaId: mediaId, scope: .title, seasonNumber: nil, catalog: catalog)
    }

    static func home(_ base: HomeResponse, catalog: [CatalogItemSummary]) -> HomeResponse {
      guard enabled else { return base }
      var continuing = catalog.filter { $0.kind == .movie }.map(decorate).filter {
        ($0.progress?.positionMilliseconds ?? 0) > 10_000 && $0.progress?.isCompleted != true
          && !hidden.contains($0.id)
      }
      if !hidden.contains(seriesID),
        let plan = try? playbackPlan(mediaId: seriesID, catalog: catalog),
        let target = plan.target, plan.continueWatchingEligible
      {
        continuing.append(target)
      }
      return HomeResponse(
        recommendation: base.recommendation.map(decorate), continueWatching: continuing,
        recentlyAdded: base.recentlyAdded.map(decorate), favorites: base.favorites.map(decorate),
        collections: base.collections, recommendationChangesAt: base.recommendationChangesAt)
    }
  }
#endif
