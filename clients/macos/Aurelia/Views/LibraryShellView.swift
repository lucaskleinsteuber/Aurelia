import SwiftUI

private enum LibraryDestination: String, CaseIterable, Identifiable {
  case home
  case library
  case recentlyAdded
  case tvShows
  case movies

  var id: String { rawValue }
  var title: String {
    switch self {
    case .home: "Home"
    case .library: "Library"
    case .recentlyAdded: "Recently Added"
    case .tvShows: "TV Shows"
    case .movies: "Movies"
    }
  }
  var symbol: String {
    switch self {
    case .home: "house.fill"
    case .library: "rectangle.stack.fill"
    case .recentlyAdded: "clock"
    case .tvShows: "tv"
    case .movies: "film.stack"
    }
  }
}

private enum MediaSelection: Hashable {
  case media(UUID)
  case collection(UUID)
}

struct LibraryShellView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var destination: LibraryDestination? = .home
  @State private var selection: MediaSelection?

  var body: some View {
    NavigationSplitView {
      List(selection: sidebarSelection) {
        Label(LibraryDestination.home.title, systemImage: LibraryDestination.home.symbol)
          .tag(LibraryDestination.home)
          .accessibilityIdentifier("sidebar-home")
        Section("Library") {
          ForEach([
            LibraryDestination.library, .recentlyAdded, .tvShows, .movies,
          ]) { item in
            Label(item.title, systemImage: item.symbol)
              .tag(item)
              .accessibilityIdentifier("sidebar-\(item.rawValue)")
          }
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .background(.ultraThinMaterial)
      .navigationSplitViewColumnWidth(
        min: 210, ideal: AureliaDesign.sidebarWidth, max: 300)
    } detail: {
      ZStack {
        AureliaBackdrop()
        content
      }
    }
    .navigationSplitViewStyle(.balanced)
    .toolbar(.hidden)
    .overlay(alignment: .bottom) {
      if let error = model.errorMessage {
        ErrorBanner(message: error) { Task { await model.refreshFromUI() } }
      }
    }
    .onChange(of: scenePhase) {
      if scenePhase == .active { Task { await model.refreshHome() } }
    }
  }

  private var sidebarSelection: Binding<LibraryDestination?> {
    Binding(
      get: { destination },
      set: { newValue in
        selection = nil
        destination = newValue
      })
  }

  @ViewBuilder
  private var content: some View {
    if let activeSelection = selection {
      switch activeSelection {
      case .media(let id):
        MediaDetailView(mediaId: id) { self.selection = nil }
      case .collection(let id):
        if let collection = model.collections.first(where: { $0.id == id }) {
          CollectionDetailView(
            collection: collection,
            onBack: { selection = nil },
            onSelect: { selection = .media($0) })
        }
      }
    } else {
      switch destination ?? .home {
      case .home:
        HomePage(
          onSelect: { selection = .media($0) },
          onSelectCollection: { selection = .collection($0) })
      case .library:
        LibraryPage(
          onSelect: { selection = .media($0) },
          onSelectCollection: { selection = .collection($0) })
      case .recentlyAdded:
        CatalogPage(
          title: "Recently Added",
          items: model.home?.recentlyAdded ?? model.catalogItems.sorted { $0.addedAt > $1.addedAt },
          emptyMessage: "Newly added movies and TV shows will appear here.",
          onSelect: { selection = .media($0) })
      case .tvShows:
        CatalogPage(
          title: "TV Shows",
          items: model.catalogItems.filter { $0.kind == .series },
          emptyMessage: "No TV shows have been added to this server yet.",
          onSelect: { selection = .media($0) })
      case .movies:
        CatalogPage(
          title: "Movies",
          items: model.catalogItems.filter { $0.kind == .movie },
          emptyMessage: "No movies have been added to this server yet.",
          onSelect: { selection = .media($0) })
      }
    }
  }
}

private struct HomePage: View {
  @EnvironmentObject private var model: AppModel
  let onSelect: (UUID) -> Void
  let onSelectCollection: (UUID) -> Void

  var body: some View {
    if model.catalogItems.isEmpty, model.home?.recommendation == nil {
      VStack(spacing: 16) {
        ContentUnavailableView(
          "Your Library Is Ready",
          systemImage: "play.rectangle.on.rectangle",
          description: Text("Add a folder or drive to begin building your library.")
        )
        if model.canManageMedia {
          Button("Add Media…") { model.showMediaManager() }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("home-add-media")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 30) {
          if let recommendation = model.home?.recommendation {
            HomeHero(item: recommendation) { onSelect(recommendation.id) }
          }
          landscapeRow(
            "Continue Watching",
            items: model.home?.continueWatching ?? [],
            eyebrow: "Continue Watching")
          ForEach(genreRows) { row in
            posterRow(row.title, items: row.items)
          }
          posterRow("Favorites", items: model.home?.favorites ?? [])
          collectionRow(model.home?.collections ?? [])
          posterRow("Recently Added", items: model.home?.recentlyAdded ?? [])
        }
        .padding(.bottom, 40)
      }
      .accessibilityIdentifier("home-page")
    }
  }

  private var genreRows: [HomeGenreRow] {
    HomePresentationLogic.genreRows(from: model.catalogItems)
  }

  @ViewBuilder
  private func landscapeRow(
    _ title: String,
    items: [CatalogItemSummary],
    eyebrow: String
  ) -> some View {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 14) {
        sectionTitle(title, count: items.count)
        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(spacing: 20) {
            ForEach(items) { item in
              Button {
                onSelect(item.id)
              } label: {
                LandscapeMediaCard(item: item, eyebrow: eyebrow)
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("continue-\(item.id.uuidString.lowercased())")
            }
          }
          .padding(.horizontal, AureliaDesign.pagePadding)
          .padding(.vertical, 4)
        }
      }
    }
  }

  @ViewBuilder
  private func posterRow(_ title: String, items: [CatalogItemSummary]) -> some View {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 14) {
        sectionTitle(title, count: items.count)
        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(alignment: .top, spacing: 20) {
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
          .padding(.horizontal, AureliaDesign.pagePadding)
          .padding(.vertical, 4)
        }
      }
    }
  }

  @ViewBuilder
  private func collectionRow(_ collections: [CollectionSummary]) -> some View {
    if !collections.isEmpty {
      VStack(alignment: .leading, spacing: 14) {
        sectionTitle("Collections", count: collections.count)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 20) {
            ForEach(collections) { collection in
              Button {
                onSelectCollection(collection.id)
              } label: {
                CollectionCard(collection: collection)
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, AureliaDesign.pagePadding)
          .padding(.vertical, 4)
        }
      }
    }
  }

  private func sectionTitle(_ title: String, count: Int) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title).font(AureliaDesign.sectionTitle)
      Text(String(count)).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
    }
    .padding(.horizontal, AureliaDesign.pagePadding)
  }
}

private struct HomeHero: View {
  let item: CatalogItemSummary
  let action: () -> Void

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      AuthenticatedArtwork(
        artwork: item.backdrop ?? item.poster,
        symbol: item.kind == .movie ? "film.fill" : "tv.fill",
        extendsBlurredEdges: true)
      LinearGradient(
        colors: [.black.opacity(0.82), .black.opacity(0.26), .clear],
        startPoint: .leading,
        endPoint: .trailing)
      LinearGradient(
        colors: [.clear, AureliaDesign.canvas.opacity(0.2), AureliaDesign.canvas],
        startPoint: .top,
        endPoint: .bottom)
      VStack(alignment: .leading, spacing: 12) {
        Text(
          [item.kind == .movie ? "MOVIE" : "TV SHOW", item.year.map(String.init)]
            .compactMap { $0 }.joined(separator: "  ·  ")
        )
        .font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.white.opacity(0.74))
        Text(item.title).font(AureliaDesign.heroTitle).lineLimit(2)
        if !item.genres.isEmpty {
          Text(item.genres.prefix(3).joined(separator: "  ·  "))
            .font(.callout.weight(.semibold)).foregroundStyle(.white.opacity(0.82))
        }
        if let overview = item.overview, !overview.isEmpty {
          Text(overview)
            .font(.body)
            .foregroundStyle(.white.opacity(0.82))
            .lineLimit(3)
            .frame(maxWidth: 600, alignment: .leading)
        }
        Button(action: action) {
          Label(item.progressFraction == nil ? "Open" : "Continue", systemImage: "arrow.right")
            .font(.headline).padding(.horizontal, 5)
        }
        .buttonStyle(.borderedProminent)
        .tint(.white)
        .foregroundStyle(.black)
        .controlSize(.large)
        .accessibilityIdentifier("home-hero-action")
      }
      .padding(AureliaDesign.pagePadding)
      .padding(.bottom, 18)
    }
    .frame(height: 500)
    .clipShape(
      UnevenRoundedRectangle(
        bottomLeadingRadius: AureliaDesign.heroRadius,
        bottomTrailingRadius: AureliaDesign.heroRadius)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("home-hero")
  }
}

private enum LibraryFilter: String, CaseIterable {
  case all = "All"
  case movies = "Movies"
  case shows = "TV Shows"
  case favorites = "Favorites"
}
private enum LibrarySort: String, CaseIterable {
  case title = "Title"
  case newest = "Recently Added"
  case year = "Year"
}

private struct LibraryPage: View {
  @EnvironmentObject private var model: AppModel
  let onSelect: (UUID) -> Void
  let onSelectCollection: (UUID) -> Void
  @State private var query = ""
  @State private var searchResults: [CatalogItemSummary]?
  @State private var filter: LibraryFilter = .all
  @State private var sort: LibrarySort = .title
  @State private var showingCollectionEditor = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AureliaDesign.sectionSpacing) {
        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Library").font(AureliaDesign.pageTitle)
              .accessibilityIdentifier("library-title")
            Text(
              "\(movieCount) movies · \(showCount) TV shows · \(model.collections.count) collections"
            )
            .font(.callout).foregroundStyle(.secondary)
          }
          Spacer()
          TextField("Search Library", text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(width: 300)
            .accessibilityIdentifier("library-search")
          Menu {
            ForEach(LibraryFilter.allCases, id: \.self) { value in
              Button(value.rawValue) { filter = value }
            }
          } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
          }
          Menu {
            ForEach(LibrarySort.allCases, id: \.self) { value in
              Button(value.rawValue) { sort = value }
            }
          } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down.circle")
          }
          if model.profile?.user?.role.canManageLibraries == true {
            Button("Add Media…") { model.showMediaManager() }
              .accessibilityIdentifier("library-add-media")
            Button {
              showingCollectionEditor = true
            } label: {
              Image(systemName: "plus").frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())
            .accessibilityLabel("Create Collection")
          }
        }

        if query.isEmpty, !model.collections.isEmpty {
          VStack(alignment: .leading, spacing: 14) {
            Text("Collections").font(AureliaDesign.sectionTitle)
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 20) {
                ForEach(model.collections) { collection in
                  Button {
                    onSelectCollection(collection.id)
                  } label: {
                    CollectionCard(collection: collection)
                  }.buttonStyle(.plain)
                }
              }.padding(.vertical, 4)
            }
          }
        }

        if displayedItems.isEmpty {
          ContentUnavailableView(
            query.isEmpty ? "No Media Yet" : "No Results",
            systemImage: query.isEmpty ? "rectangle.stack" : "magnifyingglass",
            description: Text(
              query.isEmpty
                ? "Movies and TV shows appear after a storage location is scanned."
                : "Try another title, person, genre, season, or episode.")
          )
          .frame(maxWidth: .infinity, minHeight: 320)
        } else {
          if query.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
              Text("Movies & TV Shows").font(AureliaDesign.sectionTitle)
              posterGrid(displayedItems, onSelect: onSelect)
            }
          } else {
            searchResultSections
          }
        }
      }
      .padding(AureliaDesign.pagePadding)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task(id: query) {
      guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        searchResults = nil
        return
      }
      try? await Task.sleep(for: .milliseconds(220))
      guard !Task.isCancelled else { return }
      searchResults = try? await model.searchCatalog(query)
    }
    .sheet(isPresented: $showingCollectionEditor) {
      CollectionEditorSheet(collection: nil)
        .environmentObject(model)
    }
  }

  private var movieCount: Int { model.catalogItems.filter { $0.kind == .movie }.count }
  private var showCount: Int { model.catalogItems.filter { $0.kind == .series }.count }
  private var displayedItems: [CatalogItemSummary] {
    var items = searchResults ?? model.catalogItems
    switch filter {
    case .all: break
    case .movies: items = items.filter { $0.kind == .movie }
    case .shows: items = items.filter { $0.kind == .series }
    case .favorites: items = items.filter(\.isFavorite)
    }
    switch sort {
    case .title:
      items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    case .newest: items.sort { $0.addedAt > $1.addedAt }
    case .year:
      items.sort {
        let leftYear = $0.year ?? 0
        let rightYear = $1.year ?? 0
        if leftYear != rightYear { return leftYear > rightYear }
        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
    }
    return items
  }

  @ViewBuilder
  private var searchResultSections: some View {
    let movies = displayedItems.filter { $0.kind == .movie }
    let shows = displayedItems.filter { $0.kind == .series }
    let episodes = displayedItems.filter { $0.kind == .episode }
    VStack(alignment: .leading, spacing: AureliaDesign.sectionSpacing) {
      if !movies.isEmpty {
        searchSectionTitle("Movies", count: movies.count)
        posterGrid(movies, onSelect: onSelect)
      }
      if !shows.isEmpty {
        searchSectionTitle("TV Shows", count: shows.count)
        posterGrid(shows, onSelect: onSelect)
      }
      if !episodes.isEmpty {
        searchSectionTitle("Episodes", count: episodes.count)
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 280, maximum: 340), spacing: 22)],
          alignment: .leading,
          spacing: 22
        ) {
          ForEach(episodes) { episode in
            Button {
              model.startPlayback(
                mediaId: episode.id,
                title: episode.title,
                subtitle: episodeSearchSubtitle(episode))
            } label: {
              LandscapeMediaCard(
                item: episode,
                width: 300,
                eyebrow: episodeSearchEyebrow(episode))
            }
            .buttonStyle(.plain)
            .disabled(!episode.isPlayable)
            .accessibilityLabel(
              "\(episode.title), \(episodeSearchSubtitle(episode) ?? "Episode")"
            )
            .accessibilityIdentifier("search-episode-\(episode.id.uuidString.lowercased())")
          }
        }
      }
    }
  }

  private func searchSectionTitle(_ title: String, count: Int) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title).font(AureliaDesign.sectionTitle)
      Text(String(count)).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
    }
  }

  private func episodeSearchEyebrow(_ item: CatalogItemSummary) -> String {
    let number = [
      item.seasonNumber.map { "S\($0)" },
      item.episodeNumber.map { "E\($0)" },
    ].compactMap { $0 }.joined(separator: " ")
    return [item.parentTitle, number.isEmpty ? nil : number].compactMap { $0 }
      .joined(separator: " · ")
  }

  private func episodeSearchSubtitle(_ item: CatalogItemSummary) -> String? {
    let number = [
      item.seasonNumber.map { "Season \($0)" },
      item.episodeNumber.map { "Episode \($0)" },
    ].compactMap { $0 }.joined(separator: " · ")
    return [item.parentTitle, number.isEmpty ? nil : number].compactMap { $0 }
      .joined(separator: " · ")
  }
}

private struct CatalogPage: View {
  let title: String
  let items: [CatalogItemSummary]
  let emptyMessage: String
  let onSelect: (UUID) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(title).font(AureliaDesign.pageTitle).accessibilityIdentifier("library-title")
          Text(String(items.count)).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        if items.isEmpty {
          ContentUnavailableView(
            title, systemImage: "rectangle.stack", description: Text(emptyMessage)
          )
          .frame(maxWidth: .infinity, minHeight: 360)
        } else {
          posterGrid(items, onSelect: onSelect)
        }
      }
      .padding(AureliaDesign.pagePadding)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct CollectionCard: View {
  let collection: CollectionSummary
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      AuthenticatedArtwork(artwork: collection.poster, symbol: "rectangle.stack.fill")
        .frame(width: 210, height: 280)
        .clipShape(RoundedRectangle(cornerRadius: AureliaDesign.cardRadius))
        .overlay {
          RoundedRectangle(cornerRadius: AureliaDesign.cardRadius)
            .stroke(.white.opacity(0.1), lineWidth: 1)
        }
      Text(collection.name).font(.headline).lineLimit(1).frame(width: 210, alignment: .leading)
      Text("\(collection.items.count) titles").font(.caption).foregroundStyle(.secondary)
    }
  }
}

private struct CollectionDetailView: View {
  @EnvironmentObject private var model: AppModel
  let collection: CollectionSummary
  let onBack: () -> Void
  let onSelect: (UUID) -> Void
  @State private var showingEditor = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        HStack {
          Button(action: onBack) { Image(systemName: "chevron.left").frame(width: 30, height: 30) }
            .buttonStyle(.bordered).clipShape(Circle()).accessibilityLabel("Back")
          Spacer()
          if model.profile?.user?.role.canManageLibraries == true {
            Button("Edit Collection") { showingEditor = true }
          }
        }
        HStack(alignment: .bottom, spacing: 26) {
          AuthenticatedArtwork(artwork: collection.poster, symbol: "rectangle.stack.fill")
            .frame(width: 180, height: 270)
            .clipShape(RoundedRectangle(cornerRadius: AureliaDesign.cardRadius))
          VStack(alignment: .leading, spacing: 8) {
            Text("COLLECTION").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(
              .secondary)
            Text(collection.name).font(AureliaDesign.heroTitle)
            Text("\(collection.items.count) titles").foregroundStyle(.secondary)
          }
        }
        posterGrid(collection.items, onSelect: onSelect)
      }
      .padding(AureliaDesign.pagePadding)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .sheet(isPresented: $showingEditor) {
      CollectionEditorSheet(collection: collection).environmentObject(model)
    }
  }
}

@ViewBuilder
@MainActor
private func posterGrid(_ items: [CatalogItemSummary], onSelect: @escaping (UUID) -> Void)
  -> some View
{
  LazyVGrid(
    columns: [GridItem(.adaptive(minimum: 154, maximum: 180), spacing: 22)],
    alignment: .leading,
    spacing: 28
  ) {
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
