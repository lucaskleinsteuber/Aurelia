import SwiftUI

struct MovieDetailView: View {
  @EnvironmentObject private var model: AppModel
  let movieId: UUID
  let onBack: () -> Void
  @State private var detail: MovieDetailResponse?
  @State private var errorMessage: String?

  var body: some View {
    detailPage {
      if let detail {
        VStack(alignment: .leading, spacing: AureliaHomeDesign.sectionSpacing) {
          detailHeader(
            title: detail.title,
            subtitle: detail.year.map(String.init),
            availability: detail.availability,
            symbol: "film")
          Button {
            model.startPlayback(mediaId: detail.id, title: detail.title)
          } label: {
            Label("Play", systemImage: "play.fill")
              .font(.headline)
              .padding(.horizontal, 8)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(detail.availability != .available)
          .accessibilityIdentifier("play-media")
          supplementSection(detail.supplements) { supplement in
            model.startPlayback(
              mediaId: supplement.id,
              title: supplement.title,
              subtitle: detail.title)
          }
        }
      } else if let errorMessage {
        ContentUnavailableView(
          "Movie Unavailable",
          systemImage: "exclamationmark.triangle",
          description: Text(errorMessage))
      } else {
        ProgressView("Loading movie…")
          .frame(maxWidth: .infinity, minHeight: 360)
      }
    }
    .task(id: movieId) {
      do {
        detail = try await model.movieDetail(id: movieId)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func detailPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    ScrollView {
      content()
        .padding(AureliaHomeDesign.pagePadding)
        .frame(maxWidth: 920, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(AureliaHomeBackdrop())
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Button(action: onBack) {
          Label("Back", systemImage: "chevron.left")
        }
      }
    }
  }
}

struct SeriesDetailView: View {
  @EnvironmentObject private var model: AppModel
  let seriesId: UUID
  let onBack: () -> Void
  @State private var detail: SeriesDetailResponse?
  @State private var errorMessage: String?

  var body: some View {
    ScrollView {
      Group {
        if let detail {
          VStack(alignment: .leading, spacing: AureliaHomeDesign.sectionSpacing) {
            detailHeader(
              title: detail.title,
              subtitle: "\(detail.seasons.count) seasons",
              availability: detail.availability,
              symbol: "tv")
            supplementSection(detail.supplements) { supplement in
              model.startPlayback(
                mediaId: supplement.id,
                title: supplement.title,
                subtitle: detail.title)
            }
            ForEach(detail.seasons) { season in
              seasonSection(season, seriesTitle: detail.title)
            }
          }
        } else if let errorMessage {
          ContentUnavailableView(
            "TV Show Unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text(errorMessage))
        } else {
          ProgressView("Loading TV show…")
            .frame(maxWidth: .infinity, minHeight: 360)
        }
      }
      .padding(AureliaHomeDesign.pagePadding)
      .frame(maxWidth: 920, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(AureliaHomeBackdrop())
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Button(action: onBack) {
          Label("Back", systemImage: "chevron.left")
        }
      }
    }
    .task(id: seriesId) {
      do {
        detail = try await model.seriesDetail(id: seriesId)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func seasonSection(_ season: SeasonSummary, seriesTitle: String) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Season \(season.number)")
        .font(AureliaHomeDesign.sectionTitle)
        .accessibilityIdentifier("season-\(season.number)")
      VStack(spacing: 0) {
        ForEach(Array(season.episodes.enumerated()), id: \.element.id) { index, episode in
          Button {
            model.startPlayback(
              mediaId: episode.id,
              title: episode.title,
              subtitle: "\(seriesTitle) · S\(String(format: "%02d", episode.seasonNumber)) E\(String(format: "%02d", episode.episodeNumber))")
          } label: {
            HStack(spacing: 14) {
              Text("\(episode.episodeNumber)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
              Text(episode.title)
                .frame(maxWidth: .infinity, alignment: .leading)
              if episode.availability == .available {
                Image(systemName: "play.fill")
                  .foregroundStyle(.secondary)
              }
              AvailabilityBadge(availability: episode.availability)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(episode.availability != .available)
          .padding(.vertical, 12)
          .accessibilityIdentifier(
            "episode-\(episode.seasonNumber)-\(episode.episodeNumber)")
          if index < season.episodes.count - 1 {
            Divider()
          }
        }
      }
      .padding(.horizontal, 16)
      .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
      supplementSection(season.supplements) { supplement in
        model.startPlayback(
          mediaId: supplement.id,
          title: supplement.title,
          subtitle: "\(seriesTitle) · Season \(season.number)")
      }
    }
  }
}

@ViewBuilder
@MainActor
private func detailHeader(
  title: String,
  subtitle: String?,
  availability: MediaAvailability,
  symbol: String
) -> some View {
  HStack(alignment: .top, spacing: 24) {
    ZStack {
      RoundedRectangle(cornerRadius: 20)
        .fill(.white.opacity(0.08))
      Image(systemName: symbol)
        .font(.system(size: 46, weight: .light))
        .foregroundStyle(.white.opacity(0.72))
    }
    .frame(width: 150, height: 225)

    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.system(size: 38, weight: .bold))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      if let subtitle {
        Text(subtitle)
          .font(.title3)
          .foregroundStyle(.secondary)
      }
      AvailabilityBadge(availability: availability)
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(minHeight: 225, alignment: .top)
    .layoutPriority(1)
  }
}

@ViewBuilder
@MainActor
private func supplementSection(
  _ supplements: [SupplementSummary],
  onPlay: @escaping (SupplementSummary) -> Void
) -> some View {
  if !supplements.isEmpty {
    VStack(alignment: .leading, spacing: 12) {
      Text("Extras")
        .font(AureliaHomeDesign.sectionTitle)
      ForEach(supplements) { supplement in
        Button {
          onPlay(supplement)
        } label: {
          HStack(spacing: 12) {
            Image(systemName: supplement.kind == .trailer ? "play.rectangle" : "sparkles.tv")
              .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(supplement.title)
              if !supplement.category.isEmpty {
                Text(supplement.category)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            Spacer()
            if supplement.availability == .available {
              Image(systemName: "play.fill")
                .foregroundStyle(.secondary)
            }
            AvailabilityBadge(availability: supplement.availability)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(supplement.availability != .available)
        .accessibilityIdentifier("supplement-\(supplement.id.uuidString)")
        .padding(14)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
      }
    }
  }
}
