import SwiftUI

struct MediaDetailView: View {
  @EnvironmentObject private var model: AppModel
  let mediaId: UUID
  let onBack: () -> Void
  var onHeroOffsetChange: (CGFloat) -> Void = { _ in }
  @State private var detail: CatalogDetailPresentation?
  @State private var errorMessage: String?
  @State private var selectedSeason: Int?
  @State private var showingMetadataEditor = false
  @State private var showingMatchEditor = false

  var body: some View {
    ScrollView {
      if let detail {
        LazyVStack(alignment: .leading, spacing: 38) {
          DetailHero(
            detail: detail,
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
            onEdit: model.profile?.user?.role.canManageLibraries == true
              ? { showingMetadataEditor = true } : nil,
            onMatch: model.profile?.user?.role.canManageLibraries == true
              ? { showingMatchEditor = true } : nil)
          .aureliaTrackHeroOffset(onChange: onHeroOffsetChange)

          if !detail.seasons.isEmpty {
            seasons(detail)
          }
          supplementSections(detail.supplements, parentTitle: detail.item.title)
          credits(detail.metadata.credits)
          about(detail)
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
        .clipShape(
          UnevenRoundedRectangle(
            bottomLeadingRadius: AureliaDesign.heroRadius,
            bottomTrailingRadius: AureliaDesign.heroRadius)
        )
      }
    }
    .coordinateSpace(name: "aurelia-content-scroll")
    .defaultScrollAnchor(.top)
    .scrollIndicators(.visible)
    .accessibilityIdentifier("media-detail-scroll")
    .task(id: mediaId) { await load() }
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

  private func load() async {
    do {
      detail = try await model.catalogDetail(id: mediaId)
      selectedSeason = selectedSeason ?? detail?.seasons.first?.number
      errorMessage = nil
    } catch {
      if detail == nil { errorMessage = error.localizedDescription }
    }
  }

  private func playPrimary(_ detail: CatalogDetailPresentation) {
    if detail.item.kind == .movie {
      model.startPlayback(mediaId: detail.item.id, title: detail.item.title)
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
    let queue = allEpisodes.drop(while: { $0.id != episode.id }).dropFirst().map {
      queuedEpisode($0, seriesTitle: seriesTitle)
    }
    model.startPlayback(
      mediaId: episode.item.id,
      title: episode.item.title,
      subtitle:
        "\(seriesTitle) · S\(String(format: "%02d", episode.seasonNumber)) E\(String(format: "%02d", episode.episodeNumber))",
      queue: queue
    )
  }

  private func episodes(in detail: CatalogDetailPresentation) -> [EpisodePresentation] {
    detail.seasons
      .sorted { $0.number < $1.number }
      .flatMap { $0.episodes.sorted { $0.episodeNumber < $1.episodeNumber } }
      .filter { $0.item.availability == .available }
  }

  private func queuedEpisode(
    _ episode: EpisodePresentation,
    seriesTitle: String
  ) -> PlaybackQueueItem {
    PlaybackQueueItem(
      mediaId: episode.item.id,
      title: episode.item.title,
      subtitle:
        "\(seriesTitle) · S\(String(format: "%02d", episode.seasonNumber)) E\(String(format: "%02d", episode.episodeNumber))"
    )
  }

  private func seasons(_ detail: CatalogDetailPresentation) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center) {
        Picker(
          "Season",
          selection: Binding(
            get: { selectedSeason ?? detail.seasons.first?.number ?? 0 },
            set: { selectedSeason = $0 })
        ) {
          ForEach(detail.seasons) { season in Text("Season \(season.number)").tag(season.number) }
        }
        .pickerStyle(.menu)
        .font(AureliaDesign.sectionTitle)
        .accessibilityIdentifier("season-\(selectedSeason ?? detail.seasons.first?.number ?? 0)")
        Spacer()
        if let season = activeSeason(detail) {
          Text("\(season.episodes.count) episodes")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, AureliaDesign.pagePadding)

      if let season = activeSeason(detail) {
        AureliaHorizontalRail {
          ForEach(season.episodes) { episode in
            Button {
              play(
                episode,
                seriesTitle: detail.item.title,
                allEpisodes: episodes(in: detail))
            } label: {
              EpisodeCard(episode: episode)
            }
            .buttonStyle(.plain)
            .disabled(episode.item.availability != .available)
            .accessibilityIdentifier("episode-\(episode.seasonNumber)-\(episode.episodeNumber)")
          }
        }
        supplementSections(
          season.supplements,
          parentTitle: "\(detail.item.title) · Season \(season.number)")
      }
    }
  }

  private func activeSeason(_ detail: CatalogDetailPresentation) -> SeasonPresentation? {
    detail.seasons.first { $0.number == selectedSeason } ?? detail.seasons.first
  }

  @ViewBuilder
  private func supplementSections(
    _ supplements: [SupplementPresentation],
    parentTitle: String
  ) -> some View {
    ForEach(supplementGroups(supplements), id: \.title) { group in
      VStack(alignment: .leading, spacing: 14) {
        Text(group.title).font(AureliaDesign.sectionTitle)
          .padding(.horizontal, AureliaDesign.pagePadding)
        AureliaHorizontalRail {
          ForEach(group.items) { supplement in
            Button {
              model.startPlayback(
                mediaId: supplement.item.id,
                title: supplement.item.title,
                subtitle: parentTitle)
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
            .buttonStyle(.plain)
            .disabled(supplement.item.availability != .available)
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
          .padding(.horizontal, AureliaDesign.pagePadding)
        AureliaHorizontalRail(spacing: 30) {
          ForEach(values.sorted { $0.order < $1.order }) { credit in
            VStack(spacing: 8) {
              AuthenticatedArtwork(artwork: credit.profile, symbol: "person.fill")
                .frame(width: 112, height: 112)
                .clipShape(Circle())
                .overlay { Circle().stroke(.white.opacity(0.1), lineWidth: 1) }
              Text(credit.name).font(.callout.weight(.semibold)).lineLimit(1)
              Text(credit.job ?? credit.department).font(.caption).foregroundStyle(.secondary)
              if let character = credit.character {
                Text(character).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
              }
            }
            .frame(width: 132)
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
        columns: [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 46)],
        alignment: .leading,
        spacing: 22
      ) {
        InfoValue(
          title: "Released",
          value: detail.metadata.releaseDate ?? detail.metadata.year.map(String.init))
        InfoValue(title: "Runtime", value: detail.metadata.runtimeMinutes.map { "\($0) min" })
        InfoValue(title: "Content Rating", value: detail.metadata.contentRating)
        InfoValue(title: "Studio", value: detail.metadata.studios.first)
        InfoValue(title: "Country", value: detail.metadata.countries.joined(separator: ", "))
        InfoValue(title: "Genres", value: detail.metadata.genres.joined(separator: ", "))
        if !detail.seasons.isEmpty {
          InfoValue(title: "Seasons", value: String(detail.seasons.count))
          InfoValue(
            title: "Episodes",
            value: String(detail.seasons.reduce(0) { $0 + $1.episodes.count }))
          InfoValue(title: "Original Title", value: detail.metadata.originalTitle)
        }
      }
    }
    .padding(.horizontal, AureliaDesign.pagePadding)
    .frame(maxWidth: 1040, alignment: .leading)
    .accessibilityIdentifier("media-information")
  }
}

private struct DetailHero: View {
  let detail: CatalogDetailPresentation
  let onBack: () -> Void
  let onPlay: () -> Void
  let onFavorite: () -> Void
  let onEdit: (() -> Void)?
  let onMatch: (() -> Void)?

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      AuthenticatedArtwork(
        artwork: detail.metadata.backdrop ?? detail.metadata.still ?? detail.item.backdrop,
        symbol: detail.item.kind == .movie ? "film.fill" : "tv.fill",
        extendsBlurredEdges: true,
        placeholderSymbolSize: 64)
      LinearGradient(
        stops: [
          .init(color: .black.opacity(0.9), location: 0),
          .init(color: .black.opacity(0.52), location: 0.36),
          .init(color: .clear, location: 0.74),
        ],
        startPoint: .leading,
        endPoint: .trailing)
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0.5),
          .init(color: AureliaDesign.canvas.opacity(0.26), location: 0.76),
          .init(color: AureliaDesign.canvas, location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom)

      VStack(alignment: .leading, spacing: 12) {
        Text(metadataLine).font(.caption.weight(.bold)).tracking(1).foregroundStyle(
          .white.opacity(0.74))
        Text(detail.metadata.title)
          .font(AureliaDesign.heroTitle)
          .tracking(-0.6)
          .lineLimit(2)
        if let original = detail.metadata.originalTitle, original != detail.metadata.title {
          Text(original).font(.title3).foregroundStyle(.white.opacity(0.7))
        }
        if !detail.metadata.genres.isEmpty {
          Text(detail.metadata.genres.prefix(3).joined(separator: "  ·  "))
            .font(.callout.weight(.semibold)).foregroundStyle(.white.opacity(0.78))
        }
        if let overview = detail.metadata.overview {
          Text(overview)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .foregroundStyle(.white.opacity(0.78))
            .lineSpacing(2)
            .frame(maxWidth: 620, alignment: .leading)
        }
        HStack(spacing: 10) {
          Button(action: onPlay) {
            Label(detail.item.progressFraction == nil ? "Play" : "Resume", systemImage: "play.fill")
              .font(.headline).padding(.horizontal, 5)
          }
          .buttonStyle(AureliaPrimaryActionButtonStyle())
          .disabled(
            detail.item.availability != .available
              || (detail.item.kind == .series && detail.seasons.isEmpty)
          )
          .accessibilityIdentifier("play-media")
          Button(action: onFavorite) {
            Label(
              detail.item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
              systemImage: detail.item.isFavorite ? "star.fill" : "star")
          }
          .buttonStyle(.bordered).controlSize(.large)
          AvailabilityBadge(availability: detail.item.availability)
        }
      }
      .padding(AureliaDesign.pagePadding)
      .padding(.bottom, 16)

      VStack {
        HStack {
          Button(action: onBack) {
            Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 44)
              .background(.ultraThinMaterial, in: Circle())
              .overlay { Circle().stroke(AureliaDesign.hairline, lineWidth: 1) }
          }
          .buttonStyle(.plain).accessibilityLabel("Back")
          Spacer()
          if onEdit != nil || onMatch != nil {
            Menu {
              if let onEdit { Button("Edit Metadata", action: onEdit) }
              if let onMatch { Button("Find Metadata Match", action: onMatch) }
            } label: {
              Image(systemName: "ellipsis").font(.headline).frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().stroke(AureliaDesign.hairline, lineWidth: 1) }
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("More Actions")
            .accessibilityIdentifier("media-actions")
          }
        }
        .padding(AureliaDesign.pagePadding)
        Spacer()
      }
    }
    .frame(height: 540)
    .clipShape(
      UnevenRoundedRectangle(
        bottomLeadingRadius: AureliaDesign.heroRadius,
        bottomTrailingRadius: AureliaDesign.heroRadius)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("media-hero")
  }

  private var metadataLine: String {
    var values = [detail.item.kind == .movie ? "MOVIE" : "TV SHOW"]
    if let year = detail.metadata.year { values.append(String(year)) }
    if let runtime = detail.metadata.runtimeMinutes { values.append("\(runtime) MIN") }
    if let rating = detail.metadata.contentRating { values.append(rating.uppercased()) }
    return values.joined(separator: "  ·  ")
  }
}

private struct EpisodeCard: View {
  let episode: EpisodePresentation
  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
          AvailabilityBadge(availability: episode.item.availability)
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
