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
              ? { showingMatchEditor = true } : nil,
            onRemove: model.profile?.user?.role.canManageLibraries == true
              ? { showingRemoveConfirmation = true } : nil
          )

          if !detail.seasons.isEmpty {
            seasons(detail)
          }
          supplementSections(
            detail.supplements, parentTitle: detail.item.title,
            headingPrefix: detail.item.kind == .series ? "Series " : "")
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
      }
    }
    .defaultScrollAnchor(.topLeading)
    .scrollClipDisabled()
    .scrollIndicators(.automatic, axes: .vertical)
    .aureliaOverlayScrollbars()
    .accessibilityIdentifier("media-detail-scroll")
    .task(id: mediaId) { await load() }
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
        get: { detail != nil && errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    ) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
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

  private func load() async {
    if detail?.item.id != mediaId {
      detail = nil
      selectedSeason = nil
    }
    do {
      let loadedDetail = try await model.catalogDetail(id: mediaId)
      guard !Task.isCancelled else { return }
      detail = loadedDetail
      if !loadedDetail.seasons.contains(where: { $0.number == selectedSeason }) {
        selectedSeason = loadedDetail.seasons.first?.number
      }
      errorMessage = nil
    } catch {
      if !Task.isCancelled, detail == nil { errorMessage = error.localizedDescription }
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
        Menu {
          ForEach(detail.seasons) { season in
            Button {
              selectedSeason = season.number
            } label: {
              if season.number == selectedSeason {
                Label("Season \(season.number)", systemImage: "checkmark")
              } else {
                Text("Season \(season.number)")
              }
            }
          }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "chevron.up.chevron.down")
              .font(.system(size: 13, weight: .medium))
            Text("Season \(selectedSeason ?? detail.seasons.first?.number ?? 0)")
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
        Spacer()
        if let season = activeSeason(detail) {
          Text("\(season.episodes.count) episodes")
            .font(.callout)
            .foregroundStyle(.secondary)
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
              guard episode.item.availability == .available else { return }
              play(
                episode,
                seriesTitle: detail.item.title,
                allEpisodes: episodes(in: detail))
            } label: {
              EpisodeCard(episode: episode)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("episode-\(episode.seasonNumber)-\(episode.episodeNumber)")
            .mediaActions(item: episode.item)
          }
        }
        .id(season.number)
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
          .padding(.horizontal, AureliaDesign.detailRailLeadingInset)
        AureliaHorizontalRail(
          spacing: 30,
          leadingInset: AureliaDesign.detailRailLeadingInset,
          cardWidth: 132, itemCount: CreditPresentation.people(values).count, title: "Cast & Crew",
          arrowHeight: 112
        ) {
          ForEach(CreditPresentation.people(values)) { credit in
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
  let onBack: () -> Void
  let onPlay: () -> Void
  let onFavorite: () -> Void
  let onEdit: (() -> Void)?
  let onMatch: (() -> Void)?
  let onRemove: (() -> Void)?

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      AuthenticatedArtwork(
        artwork: detail.metadata.backdrop ?? detail.metadata.still ?? detail.item.backdrop,
        symbol: detail.item.kind == .movie ? "film.fill" : "tv.fill",
        extendsBlurredEdges: true,
        placeholderSymbolSize: 64
      )
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
          .white.opacity(0.74))
        Text(detail.metadata.title)
          .font(AureliaDesign.heroTitle)
          .tracking(-0.6)
          .lineLimit(2)
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
              if let onRemove {
                Divider()
                Button("Remove from Library…", role: .destructive, action: onRemove)
              }
            } label: {
              Image(systemName: "gearshape").font(.headline).frame(width: 44, height: 44)
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
