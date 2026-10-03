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
  @State private var destination: LibraryDestination = .home
  @State private var selection: MediaSelection?
  @State private var sidebarVisible = true
  @State private var sidebarWidth = AureliaDesign.sidebarWidth
  @State private var resizeStartWidth: CGFloat?

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        AureliaDesign.canvas
          .ignoresSafeArea()
        content
          .environment(\.aureliaSidebarOverlap, sidebarVisible ? sidebarWidth : 0)
          .safeAreaInset(edge: .leading, spacing: 0) {
            Color.clear.frame(width: sidebarVisible ? sidebarWidth : 0)
          }
          .frame(
            width: geometry.size.width,
            height: geometry.size.height + geometry.safeAreaInsets.top
          )
          .background(AureliaDesign.canvas)
          .offset(y: -geometry.safeAreaInsets.top)
        if sidebarVisible {
          AureliaSidebarBackground()
            .frame(
              width: sidebarWidth,
              height: geometry.size.height + geometry.safeAreaInsets.top
            )
            .clipped()
            .offset(y: -geometry.safeAreaInsets.top)
            .contentShape(Rectangle())
            .onTapGesture {}  // Obscured cards must never receive navigation clicks.
          sidebar
            .frame(width: sidebarWidth, height: geometry.size.height)
            .clipped()
          Color.clear
            .frame(width: 8, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
              DragGesture(minimumDistance: 2)
                .onChanged { value in
                  if resizeStartWidth == nil { resizeStartWidth = sidebarWidth }
                  sidebarWidth = min(
                    max((resizeStartWidth ?? sidebarWidth) + value.translation.width, 210), 300)
                }
                .onEnded { _ in resizeStartWidth = nil }
            )
            .offset(x: sidebarWidth - 4)
        }
      }
      .overlay(alignment: .topLeading) {
        sidebarToggle
          .padding(.leading, sidebarVisible ? sidebarWidth - 44 : 76)
          .padding(.top, 8 - geometry.safeAreaInsets.top)
      }
      .aureliaRemoveEmptyWindowToolbar()
    }
    .background(AureliaDesign.canvas)
    .overlay(alignment: .bottom) {
      if let error = model.errorMessage {
        ErrorBanner(
          message: error,
          retry: {
            Task {
              if model.canRestoreLocalHosting {
                await model.restoreLocalHosting()
              } else {
                await model.refreshFromUI()
              }
            }
          },
          retryLabel: model.canRestoreLocalHosting ? "Start Local Server" : "Try Again",
          retryDisabled: model.isRecoveringLocalHost)
      }
    }
    .onChange(of: scenePhase) {
      if scenePhase == .active { Task { await model.refreshHome() } }
    }
  }

  private var sidebar: some View {
    List(selection: $destination) {
      Section {
        sidebarButton(.home)
      }
      Section("Library") {
        sidebarButton(.library)
        sidebarButton(.recentlyAdded)
        sidebarButton(.tvShows)
        sidebarButton(.movies)
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .accessibilityIdentifier("primary-sidebar")
  }

  private var sidebarToggle: some View {
    Button {
      sidebarVisible.toggle()
    } label: {
      Image(systemName: "sidebar.left")
        .font(.system(size: 15, weight: .medium))
        .frame(width: 34, height: 34)
        .background(.ultraThinMaterial, in: Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
    .accessibilityIdentifier("toggle-sidebar")
    .keyboardShortcut("s", modifiers: [.command, .control])
  }

  private func sidebarButton(_ item: LibraryDestination) -> some View {
    Button {
      selection = nil
      destination = item
      if item == .home { Task { await model.refreshHome() } }
    } label: {
      Label(item.title, systemImage: item.symbol)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .tag(item)
    .accessibilityIdentifier("sidebar-\(item.rawValue)")
  }

  @ViewBuilder
  private var content: some View {
    if let activeSelection = selection {
      switch activeSelection {
      case .media(let id):
        MediaDetailView(
          mediaId: id,
          onBack: { selection = nil })
      case .collection(let id):
        if let collection = model.collections.first(where: { $0.id == id }) {
          CollectionDetailView(
            collection: collection,
            onBack: { selection = nil },
            onSelect: { selection = .media($0) })
        }
      }
    } else {
      switch destination {
      case .home:
        HomePage(
          onSelect: { selection = .media($0) },
          onSelectCollection: { selection = .collection($0) }
        )
        .task { await model.refreshHome() }
      case .library:
        LibraryPage(
          onSelect: { selection = .media($0) },
          onSelectCollection: { selection = .collection($0) })
      case .recentlyAdded:
        CatalogPage(
          title: "Recently Added",
          subtitle: "The newest movies and shows on this server.",
          items: model.home?.recentlyAdded
            ?? model.catalogItems.sorted { $0.addedAt > $1.addedAt },
          emptyMessage: "Newly added movies and TV shows will appear here.",
          onSelect: { selection = .media($0) })
      case .tvShows:
        CatalogPage(
          title: "TV Shows",
          subtitle: "Every series in your library.",
          items: model.catalogItems.filter { $0.kind == .series },
          emptyMessage: "No TV shows have been added to this server yet.",
          onSelect: { selection = .media($0) })
      case .movies:
        CatalogPage(
          title: "Movies",
          subtitle: "Every movie in your library.",
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
    if model.catalogItems.isEmpty, model.home?.recommendation == nil,
      model.home?.continueWatching.isEmpty != false
    {
      Group {
        if model.errorMessage != nil || model.isRecoveringLocalHost {
          ContentUnavailableView(
            model.isRecoveringLocalHost ? "Starting Local Server" : "Server Unavailable",
            systemImage: "server.rack",
            description: Text(
              "Your saved connection is intact. Your library will appear when the server is ready.")
          )
        } else {
          EmptyLibraryState(
            title: "Your Library Is Ready",
            message: "Add a folder or drive to begin building your private library.",
            action: model.canManageMedia ? { model.showMediaManager() } : nil
          )
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("home-page")
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 34) {
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
        .padding(.bottom, 48)
      }
      .scrollClipDisabled()
      .defaultScrollAnchor(.top)
      .scrollIndicators(.automatic, axes: .vertical)
      .aureliaOverlayScrollbars()
      .accessibilityElement(children: .contain)
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
        AureliaSectionHeading(title: title, count: items.count)
          .padding(.horizontal, AureliaDesign.pagePadding)
        AureliaHorizontalRail(
          leadingInset: AureliaDesign.homeRailLeadingInset, cardWidth: 320, itemCount: items.count,
          title: title
        ) {
          ForEach(items) { item in
            Button {
              model.startPlayback(item: item)
            } label: {
              LandscapeMediaCard(item: item, eyebrow: eyebrow)
            }
            .buttonStyle(.plain)
            .disabled(!item.isPlayable)
            .accessibilityLabel(
              ["Continue \(item.title)", CatalogPlaybackLogic.subtitle(for: item)]
                .compactMap { $0 }.joined(separator: ", ")
            )
            .accessibilityIdentifier("continue-\(item.id.uuidString.lowercased())")
          }
        }
      }
    }
  }

  @ViewBuilder
  private func posterRow(_ title: String, items: [CatalogItemSummary]) -> some View {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 14) {
        AureliaSectionHeading(title: title, count: items.count)
          .padding(.horizontal, AureliaDesign.pagePadding)
        AureliaHorizontalRail(
          leadingInset: AureliaDesign.homeRailLeadingInset, itemCount: items.count, title: title
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
    }
  }

  @ViewBuilder
  private func collectionRow(_ collections: [CollectionSummary]) -> some View {
    if !collections.isEmpty {
      VStack(alignment: .leading, spacing: 14) {
        AureliaSectionHeading(title: "Collections", count: collections.count)
          .padding(.horizontal, AureliaDesign.pagePadding)
        AureliaHorizontalRail(
          leadingInset: AureliaDesign.homeRailLeadingInset, cardWidth: 210,
          itemCount: collections.count, title: "Collections"
        ) {
          ForEach(collections) { collection in
            Button {
              onSelectCollection(collection.id)
            } label: {
              CollectionCard(collection: collection)
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
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
        extendsBlurredEdges: true,
        placeholderSymbolSize: 64
      )
      .backgroundExtensionEffect()
      LinearGradient(
        stops: [
          .init(color: .black.opacity(0.88), location: 0),
          .init(color: .black.opacity(0.54), location: 0.34),
          .init(color: .clear, location: 0.72),
        ],
        startPoint: .leading,
        endPoint: .trailing)
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0.48),
          .init(color: AureliaDesign.canvas.opacity(0.35), location: 0.76),
          .init(color: AureliaDesign.canvas, location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom)

      VStack(alignment: .leading, spacing: 12) {
        Text(
          [item.kind == .movie ? "MOVIE" : "TV SHOW", item.year.map(String.init)]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
        )
        .font(.caption.weight(.bold))
        .tracking(1)
        .foregroundStyle(.white.opacity(0.72))

        Text(item.title)
          .font(AureliaDesign.heroTitle)
          .tracking(-0.6)
          .lineLimit(2)

        if !item.genres.isEmpty {
          Text(item.genres.prefix(3).joined(separator: "  ·  "))
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white.opacity(0.8))
        }

        if let overview = item.overview, !overview.isEmpty {
          Text(overview)
            .font(.body)
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(3)
            .lineSpacing(2)
            .frame(maxWidth: 610, alignment: .leading)
        }

        Button(action: action) {
          Label(
            item.progressFraction == nil ? "Open" : "Continue",
            systemImage: item.progressFraction == nil ? "arrow.right" : "play.fill"
          )
          .font(.headline)
          .padding(.horizontal, 5)
        }
        .buttonStyle(AureliaPrimaryActionButtonStyle())
        .accessibilityIdentifier("home-hero-action")
      }
      .padding(AureliaDesign.pagePadding)
      .padding(.bottom, 22)
    }
    .frame(height: 500)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("home-hero")
  }
}

private enum LibraryFilter: String, CaseIterable {
  case all = "All Media"
  case movies = "Movies"
  case shows = "TV Shows"
  case favorites = "Favorites"
}

private enum LibrarySort: String, CaseIterable {
  case title = "Title"
  case newest = "Recently Added"
  case year = "Release Year"
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
  @State private var showingMetadataReviewQueue = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AureliaDesign.sectionSpacing) {
        libraryHeader

        if query.isEmpty, !model.collections.isEmpty {
          VStack(alignment: .leading, spacing: 14) {
            AureliaSectionHeading(title: "Collections", count: model.collections.count)
            AureliaHorizontalRail(
              cardWidth: 210, itemCount: model.collections.count, title: "Collections"
            ) {
              ForEach(model.collections) { collection in
                Button {
                  onSelectCollection(collection.id)
                } label: {
                  CollectionCard(collection: collection)
                }
                .buttonStyle(.plain)
              }
            }
          }
        }

        if displayedItems.isEmpty {
          EmptyCatalogResults(
            query: query,
            canAddMedia: model.canManageMedia,
            addMedia: { model.showMediaManager() })
        } else if query.isEmpty {
          mediaSections
        } else {
          searchResultSections
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

  private var libraryHeader: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 20) {
        libraryTitle
        Spacer(minLength: 28)
        libraryControls
      }
      VStack(alignment: .leading, spacing: 18) {
        libraryTitle
        libraryControls
      }
    }
  }

  private var libraryTitle: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Library")
        .font(AureliaDesign.pageTitle)
        .tracking(-0.35)
        .accessibilityIdentifier("library-title")
      Text("\(movieCount) movies · \(showCount) TV shows · \(model.collections.count) collections")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private var libraryControls: some View {
    HStack(spacing: 10) {
      AureliaSearchField(prompt: "Search Library", text: $query)
        .frame(minWidth: 220, idealWidth: 300, maxWidth: 340)
        .accessibilityIdentifier("library-search")

      Menu {
        ForEach(LibraryFilter.allCases, id: \.self) { value in
          Button {
            filter = value
          } label: {
            if filter == value {
              Label(value.rawValue, systemImage: "checkmark")
            } else {
              Text(value.rawValue)
            }
          }
        }
      } label: {
        Image(systemName: "line.3.horizontal.decrease")
          .frame(width: 36, height: 36)
          .background(AureliaDesign.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
          .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(AureliaDesign.hairline)
          }
      }
      .menuStyle(.borderlessButton)
      .accessibilityLabel("Filter: \(filter.rawValue)")

      Menu {
        ForEach(LibrarySort.allCases, id: \.self) { value in
          Button {
            sort = value
          } label: {
            if sort == value {
              Label(value.rawValue, systemImage: "checkmark")
            } else {
              Text(value.rawValue)
            }
          }
        }
      } label: {
        Image(systemName: "arrow.up.arrow.down")
          .frame(width: 36, height: 36)
          .background(AureliaDesign.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
          .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(AureliaDesign.hairline)
          }
      }
      .menuStyle(.borderlessButton)
      .accessibilityLabel("Sort: \(sort.rawValue)")

      if model.canManageMedia {
        Button {
          showingMetadataReviewQueue = true
        } label: {
          Label("Review Matches", systemImage: "checklist")
            .font(.callout.weight(.medium))
            .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("library-review-metadata")
        .help("Review uncertain metadata matches")
        .sheet(isPresented: $showingMetadataReviewQueue) {
          MetadataReviewQueueSheet()
            .environmentObject(model)
        }

        Button {
          model.showMediaManager()
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 38, height: 38)
        }
        .buttonStyle(.borderedProminent)
        .clipShape(Circle())
        .accessibilityLabel("Add Media")
        .accessibilityIdentifier("library-add-media")

        Button {
          showingCollectionEditor = true
        } label: {
          Image(systemName: "rectangle.stack.badge.plus")
            .frame(width: 36, height: 36)
            .background(AureliaDesign.raisedSurface, in: Circle())
            .overlay { Circle().stroke(AureliaDesign.hairline) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Create Collection")
      }
    }
  }

  @ViewBuilder
  private var mediaSections: some View {
    let movies = displayedItems.filter { $0.kind == .movie }
    let shows = displayedItems.filter { $0.kind == .series }
    VStack(alignment: .leading, spacing: 34) {
      if !movies.isEmpty {
        VStack(alignment: .leading, spacing: 16) {
          AureliaSectionHeading(title: "Movies", count: movies.count)
          posterGrid(movies, onSelect: onSelect)
        }
      }
      if !shows.isEmpty {
        VStack(alignment: .leading, spacing: 16) {
          AureliaSectionHeading(title: "TV Shows", count: shows.count)
          posterGrid(shows, onSelect: onSelect)
        }
      }
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
    case .newest:
      items.sort { $0.addedAt > $1.addedAt }
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
    VStack(alignment: .leading, spacing: 34) {
      if !movies.isEmpty {
        VStack(alignment: .leading, spacing: 16) {
          AureliaSectionHeading(title: "Movies", count: movies.count)
          posterGrid(movies, onSelect: onSelect)
        }
      }
      if !shows.isEmpty {
        VStack(alignment: .leading, spacing: 16) {
          AureliaSectionHeading(title: "TV Shows", count: shows.count)
          posterGrid(shows, onSelect: onSelect)
        }
      }
      if !episodes.isEmpty {
        VStack(alignment: .leading, spacing: 16) {
          AureliaSectionHeading(title: "Episodes", count: episodes.count)
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 280, maximum: 340), spacing: 22)],
            alignment: .leading,
            spacing: 22
          ) {
            ForEach(episodes) { episode in
              Button {
                model.startPlayback(item: episode)
              } label: {
                LandscapeMediaCard(
                  item: episode,
                  width: 300,
                  eyebrow: episodeSearchEyebrow(episode))
              }
              .buttonStyle(.plain)
              .disabled(!episode.isPlayable)
              .accessibilityLabel(
                "\(episode.title), \(CatalogPlaybackLogic.subtitle(for: episode) ?? "Episode")"
              )
              .accessibilityIdentifier("search-episode-\(episode.id.uuidString.lowercased())")
            }
          }
        }
      }
    }
  }

  private func episodeSearchEyebrow(_ item: CatalogItemSummary) -> String {
    let number = [
      item.seasonNumber.map { "S\($0)" },
      item.episodeNumber.map { "E\($0)" },
    ].compactMap { $0 }.joined(separator: " ")
    return [item.parentTitle, number.isEmpty ? nil : number]
      .compactMap { $0 }
      .joined(separator: " · ")
  }

}

private struct CatalogPage: View {
  let title: String
  let subtitle: String
  let items: [CatalogItemSummary]
  let emptyMessage: String
  let onSelect: (UUID) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        VStack(alignment: .leading, spacing: 5) {
          HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(title)
              .font(AureliaDesign.pageTitle)
              .tracking(-0.35)
              .accessibilityIdentifier("library-title")
            Text(String(items.count))
              .font(.caption.weight(.semibold))
              .foregroundStyle(.tertiary)
          }
          Text(subtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        if items.isEmpty {
          ContentUnavailableView(
            title,
            systemImage: "rectangle.stack",
            description: Text(emptyMessage)
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

private struct EmptyLibraryState: View {
  let title: String
  let message: String
  let action: (() -> Void)?

  var body: some View {
    VStack(spacing: 22) {
      Image(systemName: "play.rectangle.on.rectangle")
        .font(.system(size: 54, weight: .light))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.white.opacity(0.7))
      VStack(spacing: 8) {
        Text(title)
          .font(.title.bold())
        Text(message)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 460)
      }
      if let action {
        Button("Add Media…", action: action)
          .buttonStyle(AureliaPrimaryActionButtonStyle())
          .controlSize(.large)
          .accessibilityIdentifier("home-add-media")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(40)
  }
}

private struct EmptyCatalogResults: View {
  let query: String
  let canAddMedia: Bool
  let addMedia: () -> Void

  var body: some View {
    VStack(spacing: 18) {
      ContentUnavailableView(
        query.isEmpty ? "No Media Yet" : "No Results",
        systemImage: query.isEmpty ? "rectangle.stack" : "magnifyingglass",
        description: Text(
          query.isEmpty
            ? "Movies and TV shows appear after a storage location is scanned."
            : "Try another title, person, genre, season, or episode.")
      )
      if query.isEmpty, canAddMedia {
        Button("Add Media…", action: addMedia)
          .buttonStyle(AureliaPrimaryActionButtonStyle())
      }
    }
    .frame(maxWidth: .infinity, minHeight: 330)
  }
}

private struct CollectionCard: View {
  let collection: CollectionSummary
  @State private var hovering = false
  @Environment(\.aureliaReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      AuthenticatedArtwork(artwork: collection.poster, symbol: "rectangle.stack.fill")
        .frame(width: 210, height: 280)
        .clipShape(RoundedRectangle(cornerRadius: AureliaDesign.cardRadius))
        .overlay {
          RoundedRectangle(cornerRadius: AureliaDesign.cardRadius)
            .stroke(hovering ? .white.opacity(0.25) : AureliaDesign.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(hovering ? 0.34 : 0), radius: 14, y: 8)
      Text(collection.name)
        .font(.headline)
        .lineLimit(1)
        .frame(width: 210, alignment: .leading)
      Text("\(collection.items.count) titles")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .scaleEffect(hovering && !reduceMotion ? 1.012 : 1)
    .animation(reduceMotion ? nil : AureliaDesign.responsiveSpring, value: hovering)
    .onHover { hovering = $0 }
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
      VStack(alignment: .leading, spacing: 30) {
        collectionHero
        VStack(alignment: .leading, spacing: 16) {
          AureliaSectionHeading(title: "Titles", count: collection.items.count)
          posterGrid(collection.items, onSelect: onSelect)
        }
        .padding(.horizontal, AureliaDesign.pagePadding)
      }
      .padding(.bottom, 48)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .sheet(isPresented: $showingEditor) {
      CollectionEditorSheet(collection: collection).environmentObject(model)
    }
  }

  private var collectionHero: some View {
    ZStack(alignment: .bottomLeading) {
      AuthenticatedArtwork(
        artwork: collection.items.first?.backdrop ?? collection.poster,
        symbol: "rectangle.stack.fill",
        extendsBlurredEdges: true
      )
      .backgroundExtensionEffect()
      LinearGradient(
        colors: [.black.opacity(0.84), .black.opacity(0.24), .clear],
        startPoint: .leading,
        endPoint: .trailing)
      LinearGradient(
        colors: [.clear, AureliaDesign.canvas.opacity(0.18), AureliaDesign.canvas],
        startPoint: .top,
        endPoint: .bottom)

      VStack(alignment: .leading, spacing: 8) {
        Text("COLLECTION")
          .font(.caption.weight(.bold))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.7))
        Text(collection.name)
          .font(AureliaDesign.heroTitle)
          .tracking(-0.5)
        Text("\(collection.items.count) titles")
          .foregroundStyle(.white.opacity(0.7))
      }
      .padding(AureliaDesign.pagePadding)
      .padding(.bottom, 16)

      VStack {
        HStack {
          AureliaIconControl(symbol: "chevron.left", label: "Back", action: onBack)
          Spacer()
          if model.canManageMedia {
            AureliaIconControl(
              symbol: "ellipsis",
              label: "Edit Collection",
              action: { showingEditor = true })
          }
        }
        .padding(AureliaDesign.pagePadding)
        Spacer()
      }
    }
    .frame(height: 420)
    .clipShape(
      UnevenRoundedRectangle(
        bottomLeadingRadius: AureliaDesign.heroRadius,
        bottomTrailingRadius: AureliaDesign.heroRadius)
    )
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
    spacing: 30
  ) {
    ForEach(items) { item in
      Button {
        onSelect(item.id)
      } label: {
        MediaPosterCard(item: item)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("media-\(item.id.uuidString)")
      .mediaActions(item: item)
    }
  }
}
