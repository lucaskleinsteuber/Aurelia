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
          supplementSection(detail.supplements)
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
            supplementSection(detail.supplements)
            ForEach(detail.seasons) { season in
              seasonSection(season)
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

  private func seasonSection(_ season: SeasonSummary) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Season \(season.number)")
        .font(AureliaHomeDesign.sectionTitle)
        .accessibilityIdentifier("season-\(season.number)")
      VStack(spacing: 0) {
        ForEach(Array(season.episodes.enumerated()), id: \.element.id) { index, episode in
          HStack(spacing: 14) {
            Text("\(episode.episodeNumber)")
              .font(.callout.monospacedDigit())
              .foregroundStyle(.secondary)
              .frame(width: 34, alignment: .trailing)
            Text(episode.title)
              .frame(maxWidth: .infinity, alignment: .leading)
            AvailabilityBadge(availability: episode.availability)
          }
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
      supplementSection(season.supplements)
    }
  }
}

@ViewBuilder
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
        .textSelection(.enabled)
      if let subtitle {
        Text(subtitle)
          .font(.title3)
          .foregroundStyle(.secondary)
      }
      AvailabilityBadge(availability: availability)
      Spacer()
    }
    .frame(height: 225, alignment: .top)
  }
}

@ViewBuilder
private func supplementSection(_ supplements: [SupplementSummary]) -> some View {
  if !supplements.isEmpty {
    VStack(alignment: .leading, spacing: 12) {
      Text("Extras")
        .font(AureliaHomeDesign.sectionTitle)
      ForEach(supplements) { supplement in
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
          AvailabilityBadge(availability: supplement.availability)
        }
        .padding(14)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
      }
    }
  }
}
