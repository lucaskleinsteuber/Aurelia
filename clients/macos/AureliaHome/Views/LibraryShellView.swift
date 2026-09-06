import SwiftUI

private enum LibraryDestination: String, CaseIterable, Identifiable {
  case movies
  case tvShows

  var id: String { rawValue }

  var title: String {
    switch self {
    case .movies: "Movies"
    case .tvShows: "TV Shows"
    }
  }

  var symbol: String {
    switch self {
    case .movies: "film.stack"
    case .tvShows: "tv"
    }
  }
}

private enum MediaSelection: Hashable {
  case movie(UUID)
  case series(UUID)
}

struct LibraryShellView: View {
  @EnvironmentObject private var model: AppModel
  @State private var destination: LibraryDestination? = .movies
  @State private var selection: MediaSelection?

  var body: some View {
    NavigationSplitView {
      List(LibraryDestination.allCases, selection: $destination) { item in
        Label(item.title, systemImage: item.symbol)
          .tag(item)
          .accessibilityIdentifier("sidebar-\(item.rawValue)")
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .background(.ultraThinMaterial)
      .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 300)
      .safeAreaInset(edge: .bottom) {
        if let profile = model.profile {
          VStack(alignment: .leading, spacing: 3) {
            Text(profile.name)
              .font(.caption.weight(.semibold))
            Text("Connected securely")
              .font(.caption2)
              .foregroundStyle(.green)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
        }
      }
    } detail: {
      NavigationStack {
        content
      }
    }
    .navigationSplitViewStyle(.balanced)
    .toolbar {
      ToolbarItem {
        Button {
          Task { await model.refreshFromUI() }
        } label: {
          Label("Refresh Library", systemImage: "arrow.clockwise")
        }
        .disabled(model.isWorking)
        .accessibilityIdentifier("refresh-library")
      }
    }
    .overlay(alignment: .bottom) {
      if let error = model.errorMessage {
        ErrorBanner(message: error) {
          Task { await model.refreshFromUI() }
        }
      }
    }
    .onChange(of: destination) {
      selection = nil
    }
  }

  @ViewBuilder
  private var content: some View {
    if let selection {
      switch selection {
      case .movie(let id):
        MovieDetailView(movieId: id) { self.selection = nil }
      case .series(let id):
        SeriesDetailView(seriesId: id) { self.selection = nil }
      }
    } else {
      switch destination ?? .movies {
      case .movies:
        MediaGridPage(
          title: "Movies",
          emptyMessage: "No movies have been added to this server yet.",
          items: model.movies.map {
            MediaCardItem(
              id: $0.id,
              title: $0.title,
              subtitle: $0.year.map(String.init),
              symbol: "film",
              availability: $0.availability)
          },
          onSelect: { selection = .movie($0) })
      case .tvShows:
        MediaGridPage(
          title: "TV Shows",
          emptyMessage: "No TV shows have been added to this server yet.",
          items: model.series.map {
            MediaCardItem(
              id: $0.id,
              title: $0.title,
              subtitle: "\($0.seasonCount) seasons · \($0.episodeCount) episodes",
              symbol: "tv",
              availability: $0.availability)
          },
          onSelect: { selection = .series($0) })
      }
    }
  }
}

private struct MediaCardItem: Identifiable {
  let id: UUID
  let title: String
  let subtitle: String?
  let symbol: String
  let availability: MediaAvailability
}

private struct MediaGridPage: View {
  let title: String
  let emptyMessage: String
  let items: [MediaCardItem]
  let onSelect: (UUID) -> Void

  private let columns = [GridItem(.adaptive(minimum: 168, maximum: 210), spacing: 22)]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text(title)
          .font(AureliaHomeDesign.pageTitle)
          .accessibilityIdentifier("library-title")

        if items.isEmpty {
          ContentUnavailableView(
            title,
            systemImage: "rectangle.stack",
            description: Text(emptyMessage)
          )
          .frame(maxWidth: .infinity, minHeight: 360)
        } else {
          LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
            ForEach(items) { item in
              Button {
                onSelect(item.id)
              } label: {
                MediaPosterCard(item: item)
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("media-\(item.id.uuidString)")
            }
          }
        }
      }
      .padding(AureliaHomeDesign.pagePadding)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(AureliaHomeBackdrop())
  }
}

private struct MediaPosterCard: View {
  let item: MediaCardItem
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ZStack {
        LinearGradient(
          colors: [Color.white.opacity(0.16), Color.white.opacity(0.035)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing)
        Image(systemName: item.symbol)
          .font(.system(size: 42, weight: .light))
          .foregroundStyle(.white.opacity(0.72))
      }
      .aspectRatio(2 / 3, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: AureliaHomeDesign.cardRadius))
      .overlay {
        RoundedRectangle(cornerRadius: AureliaHomeDesign.cardRadius)
          .stroke(.white.opacity(0.1), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.35), radius: 18, y: 9)

      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(item.title)
          .font(.headline)
          .lineLimit(2)
        if item.availability == .missing {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
      if let subtitle = item.subtitle {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .scaleEffect(hovering ? 1.012 : 1)
    .animation(.snappy(duration: 0.14, extraBounce: 0), value: hovering)
    .onHover { hovering = $0 }
  }
}
