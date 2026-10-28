import SwiftUI

struct MediaDetailView: View {
  @EnvironmentObject private var model: AppModel
  let mediaId: UUID
  let onBack: () -> Void
  @State private var detail: CatalogDetailPresentation?
  @State private var errorMessage: String?
  @State private var selectedSeason: Int?
  @State private var showingMetadataEditor = false
  @State private var showingMatchEditor = false
  @State private var showingRemoveConfirmation = false
  @State private var playbackPlan: PlaybackPlanResponse?
  @State private var isLoadingPlaybackPlan = false
  @State private var isStartingPlayback = false
  @State private var loadGeneration = UUID()
  @State private var loadedProfile: StoredServerProfile?
  @State private var primarySeasonApplied = false
  @State private var playbackTask: Task<Void, Never>?
  @State private var usedPreparedDetail = false
  @Environment(\.aureliaReduceMotion) private var reduceMotion
  @StateObject private var watchActions = MediaWatchActionController()

  /// What the page shows now: loaded details, else prepared ones, else the list entry that
  /// was just selected, so artwork, title and overview appear in the first frame.
  private var shownDetail: CatalogDetailPresentation? {
    if let detail { return detail }
    guard errorMessage == nil else { return nil }
    return model.preparedDetail(id: mediaId)?.detail
      ?? model.listedItem(id: mediaId).map(AppModel.provisionalDetail)
  }

  /// The page shows a list entry while the full details are still on their way.
  private var isWaitingForDetails: Bool {
    detail == nil && errorMessage == nil && model.preparedDetail(id: mediaId) == nil
  }

  private var shownPlan: PlaybackPlanResponse? {
    playbackPlan ?? (detail == nil ? model.preparedDetail(id: mediaId)?.plan : nil)
  }

  var body: some View {
    ScrollView {
      if let detail = shownDetail {
        LazyVStack(alignment: .leading, spacing: 38) {
          DetailHero(
            detail: detail,
            playLabel: DetailPlaybackPresentation.label(detail: detail, plan: shownPlan),
            playTarget: primaryTarget(detail),
            isPlayLoading: isLoadingPlaybackPlan || isStartingPlayback,
            canPlay: primaryTarget(detail).map(MediaAvailabilityPresentation.canPlay) == true,
            watchActions: watchActions,
            onBack: onBack,
            onPlay: { playPrimary(detail) },
            onFavorite: {
              Task {
                if await model.setFavorite(
                  mediaId: detail.item.id, isFavorite: !detail.item.isFavorite)
                {
                  await load()
                }
              }
            },
            isWatchlisted: model.isWatchlisted(detail.item.id),
            onWatchlist: model.supportsWatchlist
              ? {
                Task {
                  _ = await model.setWatchlist(
                    mediaId: detail.item.id,
                    isWatchlisted: !model.isWatchlisted(detail.item.id))
                }
              } : nil,
            // Editing waits for the full details; a list entry shown first is incomplete.
            metadataReady: self.detail != nil,
            onEdit: model.canEditMetadata
              ? { showingMetadataEditor = true } : nil,
            onMatch: model.canEditMetadata
              ? { showingMatchEditor = true } : nil,
            onRemove: model.canEditMetadata
              ? { showingRemoveConfirmation = true } : nil
          )

          if isWaitingForDetails {
            DetailLoadingPlaceholder(isSeries: detail.item.kind == .series)
              .transition(.opacity)
          } else {
            Group {
              if !detail.seasons.isEmpty {
                seasons(detail)
              }
              supplementSections(
                detail.supplements, parentTitle: detail.item.title,
                headingPrefix: detail.item.kind == .series ? "Series " : "")
              credits(detail.metadata.credits)
              about(detail)
            }
            .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 16)))
          }
        }
        .padding(.bottom, 48)
      } else if let errorMessage {
        ContentUnavailableView(
          "Media Unavailable",
          systemImage: "exclamationmark.triangle",
          description: Text(errorMessage)
        )
        .frame(maxWidth: .infinity, minHeight: 420)
        .padding(AureliaDesign.pagePadding)
      } else {
        ZStack {
          MediaArtworkPlaceholder(symbol: "film")
          LinearGradient(
            colors: [.clear, AureliaDesign.canvas],
            startPoint: .top,
            endPoint: .bottom)
          ProgressView("Loading details…")
            .controlSize(.large)
        }
        .frame(height: 500)
      }
    }
    .defaultScrollAnchor(.topLeading)
    .scrollClipDisabled()
    .scrollIndicators(.automatic, axes: .vertical)
    .aureliaOverlayScrollbars()
    .accessibilityIdentifier("media-detail-scroll")
    .aureliaCompactHeader(
      title: shownDetail?.metadata.title ?? "", threshold: 440, onBack: onBack
    )
    // Details prepared while the pointer rested on the title appear in the first frame.
    .onAppear { applyPreparedDetail() }
    .task(
      id: DetailRefreshKey(
        mediaId: mediaId, revision: model.catalogVisibilityRevision,
        profile: model.profile)
    ) { await load() }
    .modifier(MediaWatchActionConfirmation(controller: watchActions))
    .onDisappear {
      loadGeneration = UUID()
      playbackTask?.cancel()
      playbackTask = nil
      isStartingPlayback = false
    }
    .confirmationDialog(
      "Remove \(detail?.item.title ?? "Title")?", isPresented: $showingRemoveConfirmation,
      titleVisibility: .visible
    ) {
      Button("Remove from Library", role: .destructive) {
        Task {
          do {
            try await model.removeMedia(id: mediaId)
            onBack()
          } catch { errorMessage = error.localizedDescription }
        }
      }
    } message: {
      Text(
        "This removes Aurelia metadata, images, favorites and playback history, including associated episodes and extras. Videos are never changed. Scans will not reimport the excluded sources."
      )
    }
    .alert(
      "Library Action Failed",
      isPresented: Binding(
        get: { detail != nil && (errorMessage != nil || watchActions.errorMessage != nil) },
        set: {
          if !$0 {
            errorMessage = nil
            watchActions.errorMessage = nil
          }
        })
    ) {
      Button("OK") {
        errorMessage = nil
        watchActions.errorMessage = nil
      }
    } message: {
      Text(errorMessage ?? watchActions.errorMessage ?? "")
    }
    .sheet(isPresented: $showingMetadataEditor) {
      if let detail {
        MetadataEditorSheet(metadata: detail.metadata) { await load() }
          .environmentObject(model)
      }
    }
    .sheet(isPresented: $showingMatchEditor) {
      if let detail {
        MetadataMatchSheet(metadata: detail.metadata) { await load() }
          .environmentObject(model)
      }
    }
  }

  private func applyPreparedDetail() {
    guard detail == nil, let prepared = model.preparedDetail(id: mediaId) else { return }
    loadedProfile = model.profile
    detail = prepared.detail
    selectedSeason = prepared.detail.seasons.first?.number
    errorMessage = nil
    if model.supportsLibraryState, let plan = prepared.plan {
      apply(plan, to: prepared.detail)
    }
    isLoadingPlaybackPlan = false
    usedPreparedDetail = true
  }

  private func apply(_ plan: PlaybackPlanResponse, to detail: CatalogDetailPresentation) {
    playbackPlan = plan
    if !primarySeasonApplied, let targetSeason = plan.target?.seasonNumber,
      detail.seasons.contains(where: { $0.number == targetSeason })
    {
      selectedSeason = targetSeason
    }
    primarySeasonApplied = true
  }

  private func load() async {
    // The prepared detail is at most 30 seconds old and from this session and catalog revision.
    if usedPreparedDetail {
      usedPreparedDetail = false
      if detail?.item.id == mediaId, model.preparedDetail(id: mediaId) != nil { return }
    }
    let request = UUID()
    loadGeneration = request
    let profile = model.profile
    if detail?.item.id != mediaId || loadedProfile != profile {
      detail = nil
      playbackPlan = nil
      selectedSeason = nil
      primarySeasonApplied = false
      // Start the hero artwork together with the details instead of after them.
      if let summary = model.catalogItems.first(where: { $0.id == mediaId }),
        let backdrop = summary.backdrop
      {
        model.prefetchHeroArtwork(backdrop)
      }
    }
    loadedProfile = profile
    isLoadingPlaybackPlan = model.supportsLibraryState
    do {
      // Details and the playback plan load in parallel; the details appear first.
      async let loadedPlan = model.optionalPlaybackPlan(mediaId: mediaId)
      let loadedDetail = try await model.catalogDetail(id: mediaId)
      guard loadGeneration == request, model.profile == profile, !Task.isCancelled else { return }
      // Seasons, cast and information glide in under the hero that is already shown.
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.32)) { detail = loadedDetail }
      if !loadedDetail.seasons.contains(where: { $0.number == selectedSeason }) {
        selectedSeason = loadedDetail.seasons.first?.number
      }
      errorMessage = nil
      if let plan = try await loadedPlan {
        guard loadGeneration == request, model.profile == profile, !Task.isCancelled else { return }
        apply(plan, to: loadedDetail)
      }
      isLoadingPlaybackPlan = false
    } catch {
      guard loadGeneration == request, model.profile == profile, !Task.isCancelled else { return }
      isLoadingPlaybackPlan = false
      if !(error is CancellationError) { errorMessage = error.localizedDescription }
    }
  }

  private func primaryTarget(_ detail: CatalogDetailPresentation) -> CatalogItemSummary? {
    if model.supportsLibraryState { return shownPlan?.target }
    if detail.item.kind != .series { return detail.item }
    return episodes(in: detail).first?.item
  }

  private func playPrimary(_ detail: CatalogDetailPresentation) {
    if model.supportsLibraryState {
      requestPlannedPlayback(mediaId: detail.item.id)
    } else if detail.item.kind == .movie {
      model.startPlayback(
        mediaId: detail.item.id, title: detail.item.title,
        artwork: CatalogPlaybackLogic.artwork(for: detail.item))
    } else {
      let availableEpisodes = episodes(in: detail)
      if let episode = availableEpisodes.first {
        play(episode, seriesTitle: detail.item.title, allEpisodes: availableEpisodes)
      }
    }
  }

  private func play(
    _ episode: EpisodePresentation,
    seriesTitle: String,
    allEpisodes: [EpisodePresentation]
  ) {
    if model.supportsLibraryState {
      requestPlannedPlayback(mediaId: episode.id, intent: .play)
      return
    }
    let queue =
      episode.seasonNumber == 0
      ? []
      : allEpisodes
        .filter { $0.seasonNumber > 0 }
        .drop(while: { $0.id != episode.id }).dropFirst().map {
          queuedEpisode($0, seriesTitle: seriesTitle)
        }
    model.startPlayback(
      mediaId: episode.item.id,
      title: episode.item.title,
      subtitle:
        "\(seriesTitle) · S\(String(format: "%02d", episode.seasonNumber)) E\(String(format: "%02d", episode.episodeNumber))",
      queue: queue,
      previousItems: episode.seasonNumber == 0
        ? []
        : allEpisodes.filter { $0.seasonNumber > 0 }
          .prefix(while: { $0.id != episode.id }).map {
            queuedEpisode($0, seriesTitle: seriesTitle)
          },
      trackScope: episode.item.parentId,
      artwork: CatalogPlaybackLogic.artwork(for: episode.item)
    )
  }

  private func requestPlannedPlayback(mediaId: UUID, intent: PlaybackStartIntent? = nil) {
    guard !isStartingPlayback else { return }
    isStartingPlayback = true
    let profile = model.profile
    playbackTask = Task {
      do { try await model.startPlannedPlayback(mediaId: mediaId, intent: intent) } catch {
        if model.profile == profile, !Task.isCancelled, !(error is CancellationError) {
          errorMessage = error.localizedDescription
        }
      }
      if model.profile == profile, !Task.isCancelled { isStartingPlayback = false }
    }
  }

  private func episodes(in detail: CatalogDetailPresentation) -> [EpisodePresentation] {
    detail.seasons
      .sorted { $0.number < $1.number }
      .flatMap { $0.episodes.sorted { $0.episodeNumber < $1.episodeNumber } }
      .filter { MediaAvailabilityPresentation.canPlay($0.item) }
  }

  private func queuedEpisode(
    _ episode: EpisodePresentation,
    seriesTitle: String
  ) -> PlaybackQueueItem {
    PlaybackQueueItem(
      mediaId: episode.item.id,
      title: episode.item.title,
      subtitle:
        "\(seriesTitle) · S\(String(format: "%02d", episode.seasonNumber)) E\(String(format: "%02d", episode.episodeNumber))",
      artwork: CatalogPlaybackLogic.artwork(for: episode.item)
    )
  }

  private func seasons(_ detail: CatalogDetailPresentation) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center) {
        Menu {
          ForEach(detail.seasons) { season in
            Button {
              withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
                selectedSeason = season.number
              }
            } label: {
              if season.number == selectedSeason {
                Label(seasonTitle(season.number), systemImage: "checkmark")
              } else {
                Text(seasonTitle(season.number))
              }
            }
          }
          if let season = activeSeason(detail) {
            MediaWatchMenuItems(
              item: detail.item, controller: watchActions, scope: .season,
              seasonNumber: season.number, includeContinueWatching: false,
              subjectPrefix: "Season")
            MediaWatchMenuItems(
              item: detail.item, controller: watchActions, scope: .series,
              includeContinueWatching: false, subjectPrefix: "Series")
          }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "chevron.up.chevron.down")
              .font(.system(size: 13, weight: .medium))
            Text(seasonTitle(selectedSeason ?? detail.seasons.first?.number ?? 0))
              .font(AureliaDesign.sectionTitle)
            Image(systemName: "chevron.down")
              .font(.system(size: 11, weight: .semibold))
          }
          .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("season-\(selectedSeason ?? detail.seasons.first?.number ?? 0)")
        .contextMenu {
          if let season = activeSeason(detail) {
            MediaWatchMenuItems(
              item: detail.item, controller: watchActions, scope: .season,
              seasonNumber: season.number, includeContinueWatching: false,
              subjectPrefix: "Season")
            MediaWatchMenuItems(
              item: detail.item, controller: watchActions, scope: .series,
              includeContinueWatching: false, subjectPrefix: "Series")
          }
        }
        Spacer()
        if let season = activeSeason(detail) {
          if !season.episodes.isEmpty,
            season.episodes.allSatisfy({ MediaWatchPresentation.isWatched($0.item) })
          {
            Label("Watched", systemImage: "checkmark.circle.fill")
              .font(.caption).foregroundStyle(.secondary)
          }
          Text("\(season.episodes.count) episodes")
            .font(.callout)
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
        }
      }
      .padding(.horizontal, AureliaDesign.detailRailLeadingInset)

      if let season = activeSeason(detail) {
        AureliaHorizontalRail(
          leadingInset: AureliaDesign.detailRailLeadingInset, cardWidth: 420,
          itemCount: season.episodes.count, title: "Episodes"
        ) {
          ForEach(season.episodes) { episode in
            Button {
              guard MediaAvailabilityPresentation.canPlay(episode.item), !isStartingPlayback else {
                return
              }
              play(
                episode,
                seriesTitle: detail.item.title,
                allEpisodes: episodes(in: detail))
            } label: {
              EpisodeCard(episode: episode)
            }
            .buttonStyle(AureliaCardButtonStyle())
            .disabled(!MediaAvailabilityPresentation.canPlay(episode.item) || isStartingPlayback)
            .accessibilityIdentifier("episode-\(episode.seasonNumber)-\(episode.episodeNumber)")
            .mediaActions(
              item: episode.item, seasonNumber: season.number, showGoToSeries: false)
          }
        }
        .id(season.number)
        .transition(.opacity.combined(with: .offset(x: reduceMotion ? 0 : 28)))
        supplementSections(
          season.supplements,
          parentTitle: "\(detail.item.title) · Season \(season.number)")
      }
    }
  }

  private func activeSeason(_ detail: CatalogDetailPresentation) -> SeasonPresentation? {
    detail.seasons.first { $0.number == selectedSeason } ?? detail.seasons.first
  }

  private func seasonTitle(_ number: Int) -> String {
    number == 0 ? "Specials" : "Season \(number)"
  }

  @ViewBuilder
  private func supplementSections(
    _ supplements: [SupplementPresentation],
    parentTitle: String,
    headingPrefix: String = ""
  ) -> some View {
    ForEach(supplementGroups(supplements), id: \.title) { group in
      VStack(alignment: .leading, spacing: 14) {
        Text(headingPrefix + group.title).font(AureliaDesign.sectionTitle)
          .padding(.horizontal, AureliaDesign.detailRailLeadingInset)
        AureliaHorizontalRail(
          leadingInset: AureliaDesign.detailRailLeadingInset, cardWidth: 360,
          itemCount: group.items.count, title: headingPrefix + group.title
        ) {
          ForEach(group.items) { supplement in
            Button {
              model.startPlayback(
                mediaId: supplement.item.id,
                title: supplement.item.title,
                subtitle: parentTitle, artwork: CatalogPlaybackLogic.artwork(for: supplement.item))
            } label: {
              ZStack {
                LandscapeMediaCard(
                  item: supplement.item, width: 360, eyebrow: supplement.category)
                Image(systemName: "play.fill")
                  .font(.title2)
                  .frame(width: 50, height: 50)
                  .background(.ultraThinMaterial, in: Circle())
              }
            }
            .buttonStyle(AureliaCardButtonStyle())
            .disabled(!MediaAvailabilityPresentation.canPlay(supplement.item))
            .accessibilityIdentifier("supplement-\(supplement.id.uuidString)")
          }
        }
      }
    }
  }

  private func supplementGroups(
    _ supplements: [SupplementPresentation]
  ) -> [(title: String, items: [SupplementPresentation])] {
    let trailers = supplements.filter {
      $0.item.kind == .trailer || $0.category.localizedCaseInsensitiveContains("trailer")
    }
    let extras = supplements.filter { supplement in
      !trailers.contains { $0.id == supplement.id }
    }
    return [
      trailers.isEmpty ? nil : ("Trailers", trailers),
      extras.isEmpty ? nil : ("Extras", extras),
    ].compactMap { $0 }
  }

  @ViewBuilder
  private func credits(_ values: [CreditSummary]) -> some View {
    if !values.isEmpty {
      VStack(alignment: .leading, spacing: 16) {
        Text("Cast & Crew").font(AureliaDesign.sectionTitle)
          .padding(.horizontal, AureliaDesign.detailRailLeadingInset)
        AureliaHorizontalRail(
          spacing: 30,
          leadingInset: AureliaDesign.detailRailLeadingInset,
          cardWidth: 132, itemCount: CreditPresentation.people(values).count, title: "Cast & Crew",
          arrowHeight: 112
        ) {
          ForEach(CreditPresentation.people(values)) { credit in
            Button {
              model.requestedPersonDetail = PersonSelection(
                name: credit.name,
                personKey: credit.id.hasPrefix("unidentified:") ? nil : credit.id,
                profile: credit.profile,
                subtitle: credit.subtitle)
            } label: {
              VStack(spacing: 8) {
                AuthenticatedArtwork(artwork: credit.profile, symbol: "person.fill")
                  .frame(width: 112, height: 112)
                  .clipShape(Circle())
                  .overlay { Circle().stroke(.white.opacity(0.1), lineWidth: 1) }
                Text(credit.name).font(.callout.weight(.semibold)).lineLimit(1)
                if let subtitle = credit.subtitle {
                  Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
              }
              .frame(width: 132)
              .contentShape(Rectangle())
            }
            .buttonStyle(AureliaCardButtonStyle())
            .accessibilityIdentifier("person-\(credit.id)")
          }
        }
      }
      .accessibilityIdentifier("cast-and-crew")
    }
  }

  private func about(_ detail: CatalogDetailPresentation) -> some View {
    VStack(alignment: .leading, spacing: 22) {
      if let overview = detail.metadata.overview, !overview.isEmpty {
        VStack(alignment: .leading, spacing: 9) {
          Text("About \(detail.metadata.title)").font(AureliaDesign.sectionTitle)
          Text(overview).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      Text("Information").font(AureliaDesign.sectionTitle)
      LazyVGrid(
        columns: detail.item.kind == .series
          ? [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 46)]
          : Array(repeating: GridItem(.flexible(minimum: 160), alignment: .leading), count: 2),
        alignment: .leading,
        spacing: 22
      ) {
        ForEach(MediaInformationPresentation.fields(for: detail)) { field in
          InfoValue(title: field.title, value: field.value)
        }
      }
    }
    .padding(.horizontal, AureliaDesign.pagePadding)
    .frame(maxWidth: 1040, alignment: .leading)
    .accessibilityIdentifier("media-information")
  }
}

struct MediaInformationField: Identifiable, Equatable {
  let title: String
  let value: String?

  var id: String { title }
}

private struct DetailRefreshKey: Equatable {
  let mediaId: UUID
  let revision: UInt64
  let profile: StoredServerProfile?
}

enum DetailPlaybackPresentation {
  static func label(detail: CatalogDetailPresentation, plan: PlaybackPlanResponse?) -> String {
    guard let plan else { return detail.item.progressFraction == nil ? "Play" : "Resume" }
    let action: String
    switch plan.action {
    case .play: action = "Play"
    case .resume: action = "Resume"
    case .playAgain: action = "Play Again"
    }
    guard detail.item.kind == .series, let target = plan.target,
      let season = target.seasonNumber, let episode = target.episodeNumber
    else { return action }
    return "\(action) S\(String(format: "%02d", season)) E\(String(format: "%02d", episode))"
  }
}

enum MediaInformationPresentation {
  static func fields(for detail: CatalogDetailPresentation) -> [MediaInformationField] {
    let metadata = detail.metadata
    let country = metadata.countries.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let studio = metadata.studios.isEmpty ? nil : metadata.studios.joined(separator: ", ")
    let genres = metadata.genres.joined(separator: ", ")
    let year = metadata.year

    if detail.item.kind == .series {
      return [
        MediaInformationField(title: "Seasons", value: String(detail.seasons.count)),
        MediaInformationField(
          title: "Episodes",
          value: String(detail.seasons.reduce(0) { $0 + $1.episodes.count })),
        MediaInformationField(title: "Studio", value: studio),
        MediaInformationField(title: "Released", value: year.map(String.init)),
        MediaInformationField(title: "Country of Origin", value: country),
        MediaInformationField(title: "Genres", value: genres),
        MediaInformationField(title: "FSK", value: metadata.fskAge.map { "FSK \($0)" }),
      ]
    }

    var fields = [
      MediaInformationField(title: "Release Year", value: year.map(String.init)),
      MediaInformationField(title: "Genres", value: genres),
      MediaInformationField(title: "Studio", value: studio),
      MediaInformationField(title: "Country of Origin", value: country),
      MediaInformationField(title: "FSK", value: metadata.fskAge.map { "FSK \($0)" }),
    ]
    if detail.item.kind == .movie {
      fields.insert(
        MediaInformationField(title: "Runtime", value: metadata.runtimeMinutes.map { "\($0) min" }),
        at: 0)
    }
    return fields
  }
}

private struct DetailHero: View {
  let detail: CatalogDetailPresentation
  let playLabel: String
  let playTarget: CatalogItemSummary?
  let isPlayLoading: Bool
  let canPlay: Bool
  @ObservedObject var watchActions: MediaWatchActionController
  let onBack: () -> Void
  let onPlay: () -> Void
  let onFavorite: () -> Void
  var isWatchlisted = false
  var onWatchlist: (() -> Void)? = nil
  let metadataReady: Bool
  let onEdit: (() -> Void)?
  let onMatch: (() -> Void)?
  let onRemove: (() -> Void)?

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      AuthenticatedArtwork(
        artwork: AppModel.heroArtwork(detail),
        symbol: detail.item.kind == .movie ? "film.fill" : "tv.fill",
        contentMode: .fill,
        placeholderSymbolSize: 64
      )
      .aureliaHeroSettle()
      .backgroundExtensionEffect()
      LinearGradient(
        stops: [
          .init(color: .black.opacity(0.46), location: 0),
          .init(color: .black.opacity(0.24), location: 0.38),
          .init(color: .black.opacity(0.04), location: 0.72),
          .init(color: .clear, location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(maxWidth: 860)
      .frame(maxWidth: .infinity, alignment: .leading)
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0.42),
          .init(color: AureliaDesign.canvas.opacity(0.24), location: 0.64),
          .init(color: AureliaDesign.canvas.opacity(0.72), location: 0.86),
          .init(color: AureliaDesign.canvas, location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom)

      VStack(alignment: .leading, spacing: 12) {
        Text(metadataLine).font(.caption.weight(.bold)).tracking(1).foregroundStyle(
          .white.opacity(0.74)
        )
        .aureliaRiseIn(0)
        Text(detail.metadata.title)
          .font(AureliaDesign.heroTitle)
          .tracking(-0.6)
          .lineLimit(2)
          .aureliaRiseIn(1)
        if !detail.metadata.genres.isEmpty {
          Text(detail.metadata.genres.prefix(3).joined(separator: "  ·  "))
            .font(.callout.weight(.semibold)).foregroundStyle(.white.opacity(0.78))
            .aureliaRiseIn(2)
        }
        if let overview = detail.metadata.overview {
          Text(overview)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .foregroundStyle(.white.opacity(0.78))
            .lineSpacing(2)
            .frame(maxWidth: 620, alignment: .leading)
            .aureliaRiseIn(3)
        }
        HStack(spacing: 10) {
          Button(action: onPlay) {
            Label(isPlayLoading ? "Loading…" : playLabel, systemImage: "play.fill")
              .font(.headline).padding(.horizontal, 5)
          }
          .buttonStyle(AureliaPrimaryActionButtonStyle())
          .disabled(!canPlay || isPlayLoading)
          .accessibilityIdentifier("play-media")
          Button(action: onFavorite) {
            Label(
              detail.item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
              systemImage: detail.item.isFavorite ? "star.fill" : "star"
            )
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: detail.item.isFavorite)
          }
          .buttonStyle(.bordered).controlSize(.large)
          if let onWatchlist {
            Button(action: onWatchlist) {
              Label(
                isWatchlisted ? "Remove from Watchlist" : "Add to Watchlist",
                systemImage: isWatchlisted ? "bookmark.fill" : "bookmark"
              )
              .contentTransition(.symbolEffect(.replace))
              .symbolEffect(.bounce, value: isWatchlisted)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .accessibilityIdentifier("watchlist-media")
          }
          if let playTarget {
            AvailabilityBadge(
              availability: playTarget.availability,
              libraryAvailability: playTarget.libraryAvailability)
            if MediaAvailabilityPresentation.isOffline(playTarget) {
              Label(
                MediaAvailabilityPresentation.offlineDetailNotice,
                systemImage: "icloud.slash"
              )
              .font(.caption)
              .foregroundStyle(.white.opacity(0.85))
              .padding(.horizontal, 10)
              .padding(.vertical, 5)
              .background(.black.opacity(0.56), in: Capsule())
              .overlay { Capsule().stroke(.white.opacity(0.16), lineWidth: 1) }
            }
          }
          if MediaWatchPresentation.isWatched(detail.item) {
            Label("Watched", systemImage: "checkmark.circle.fill")
              .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.8))
          }
        }
        .aureliaRiseIn(4)
      }
      .padding(AureliaDesign.pagePadding)
      .padding(.bottom, 16)

      // The leading cast sits at the lower right of the artwork, as in the Apple TV app,
      // when the hero is wide enough to keep it clear of the overview.
      let starring = CreditPresentation.starring(detail.metadata.credits)
      if !starring.isEmpty {
        GeometryReader { geometry in
          if geometry.size.width >= 1_040 {
            Text(
              "Starring \(Text(starring.joined(separator: ", ")).foregroundStyle(.white.opacity(0.92)))"
            )
            .foregroundStyle(.white.opacity(0.6))
            .font(.callout.weight(.medium))
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
            .frame(maxWidth: 300, alignment: .trailing)
            .padding(AureliaDesign.pagePadding)
            .padding(.bottom, 22)
            .frame(
              width: geometry.size.width, height: geometry.size.height, alignment: .bottomTrailing
            )
            .aureliaRiseIn(5)
            .accessibilityIdentifier("media-starring")
          }
        }
        .allowsHitTesting(false)
      }

      VStack {
        HStack {
          Button(action: onBack) {
            Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 44)
              .background(.ultraThinMaterial, in: Circle())
              .overlay { Circle().stroke(AureliaDesign.hairline, lineWidth: 1) }
          }
          .buttonStyle(.plain).accessibilityLabel("Back")
          Spacer()
          HStack(spacing: 10) {
            AureliaIconMenu(symbol: "ellipsis", label: "More Actions") {
              MediaContextMenuItems(
                item: detail.item, controller: watchActions, onEdit: onEdit,
                onRemove: onRemove, metadataReady: metadataReady,
                seasonNumber: detail.seasons.first?.number)
              if let onMatch {
                Button("Find Metadata Match…", systemImage: "magnifyingglass", action: onMatch)
                  .disabled(!metadataReady)
              }
            }
            .help("More Actions")
            .accessibilityIdentifier("media-actions")
          }
        }
        .padding(AureliaDesign.pagePadding)
        Spacer()
      }
    }
    .frame(height: 540)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("media-hero")
  }

  private var metadataLine: String {
    var values = [detail.item.kind == .movie ? "MOVIE" : "TV SHOW"]
    if let year = detail.metadata.year { values.append(String(year)) }
    if detail.item.kind == .movie, let runtime = detail.metadata.runtimeMinutes {
      values.append("\(runtime) MIN")
    }
    return values.joined(separator: "  ·  ")
  }
}

private struct EpisodeCard: View {
  let episode: EpisodePresentation
  @State private var hovering = false
  @Environment(\.aureliaReduceMotion) private var reduceMotion

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      AuthenticatedArtwork(
        artwork: episode.item.backdrop ?? episode.item.poster,
        symbol: "play.rectangle")
      LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
      VStack(alignment: .leading, spacing: 5) {
        Text("EPISODE \(episode.episodeNumber)").font(.caption2.weight(.bold)).tracking(1.2)
        Text(episode.item.title).font(.headline).lineLimit(1)
        if let overview = episode.item.overview {
          Text(overview).font(.caption).foregroundStyle(.white.opacity(0.72)).lineLimit(2)
        }
        HStack {
          Text(episode.item.year.map(String.init) ?? "Episode").font(.caption)
          Spacer()
          if MediaWatchPresentation.isWatched(episode.item) {
            Label("Watched", systemImage: "checkmark.circle.fill")
              .font(.caption)
          }
          AvailabilityBadge(
            availability: episode.item.availability,
            libraryAvailability: episode.item.libraryAvailability)
        }
      }.padding(16)
      if let progress = episode.item.progressFraction {
        GeometryReader { geometry in
          VStack {
            Spacer()
            Capsule().fill(.white).frame(width: geometry.size.width * progress, height: 4)
          }
        }.padding(.horizontal, 10).padding(.bottom, 7)
      }
    }
    .frame(width: 420, height: 236)
    .clipShape(RoundedRectangle(cornerRadius: AureliaDesign.cardRadius))
    .overlay {
      RoundedRectangle(cornerRadius: AureliaDesign.cardRadius)
        .stroke(hovering ? .white.opacity(0.25) : AureliaDesign.hairline)
    }
    .shadow(color: .black.opacity(hovering ? 0.34 : 0), radius: 14, y: 8)
    .scaleEffect(hovering && !reduceMotion ? 1.012 : 1)
    .animation(reduceMotion ? nil : AureliaDesign.responsiveSpring, value: hovering)
    .onHover { hovering = $0 }
  }
}

private struct InfoValue: View {
  let title: String
  let value: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
      Text(value?.isEmpty == false ? value! : "—").foregroundStyle(.secondary).lineLimit(2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// Compatibility entry points retained for older navigation tests.
struct MovieDetailView: View {
  let movieId: UUID
  let onBack: () -> Void
  var body: some View { MediaDetailView(mediaId: movieId, onBack: onBack) }
}

struct SeriesDetailView: View {
  let seriesId: UUID
  let onBack: () -> Void
  var body: some View { MediaDetailView(mediaId: seriesId, onBack: onBack) }
}

/// Shimmering stand-ins for the episodes and cast while the details load.
private struct DetailLoadingPlaceholder: View {
  let isSeries: Bool
  @Environment(\.aureliaReduceMotion) private var reduceMotion
  @State private var phase: CGFloat = -1

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      bar(width: 160, height: 22)
      HStack(spacing: 18) {
        ForEach(0..<4, id: \.self) { _ in
          VStack(alignment: .leading, spacing: 10) {
            bar(width: isSeries ? 260 : 154, height: isSeries ? 146 : 231)
            bar(width: isSeries ? 180 : 120, height: 14)
          }
        }
      }
      bar(width: 140, height: 22).padding(.top, 12)
      HStack(spacing: 22) {
        ForEach(0..<6, id: \.self) { _ in
          Circle().fill(AureliaDesign.surface).frame(width: 74, height: 74)
            .overlay { shimmer.clipShape(Circle()) }
        }
      }
    }
    .padding(.horizontal, AureliaDesign.pagePadding)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading details")
    .accessibilityIdentifier("detail-loading")
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
    }
  }

  private func bar(width: CGFloat, height: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: min(12, height / 2), style: .continuous)
      .fill(AureliaDesign.surface)
      .frame(width: width, height: height)
      .overlay {
        shimmer.clipShape(RoundedRectangle(cornerRadius: min(12, height / 2), style: .continuous))
      }
  }

  private var shimmer: some View {
    GeometryReader { geometry in
      LinearGradient(
        colors: [.clear, .white.opacity(0.08), .clear], startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: geometry.size.width * 0.8)
      .offset(x: phase * geometry.size.width * 1.4)
    }
    .allowsHitTesting(false)
  }
}
