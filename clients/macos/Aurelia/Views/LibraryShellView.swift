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

/// Cmd-F focuses the library search; coming from Home or a detail page starts a new search.
private struct FindRequest: Equatable {
  let id = UUID()
  let startsNewSearch: Bool
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
  @State private var findRequest: FindRequest?
  @Environment(\.aureliaReduceMotion) private var reduceMotion

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
            .padding(.top, max(0, 44 - geometry.safeAreaInsets.top))
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
          .padding(
            .leading,
            sidebarVisible ? sidebarWidth - 44 : (geometry.safeAreaInsets.top > 0 ? 76 : 12)
          )
          .padding(.top, 8 - geometry.safeAreaInsets.top)
      }
      .aureliaRemoveEmptyWindowToolbar()
    }
    .background(AureliaDesign.canvas)
    .background {
      LibraryFindShortcut(isBlocked: { model.playback != nil }) {
        let leaving = destination == .home || selection != nil
        if leaving {
          selection = nil
          destination = .library
        }
        findRequest = FindRequest(startsNewSearch: leaving)
      }
      .frame(width: 0, height: 0)
    }
    .overlay(alignment: .bottom) {
      if let error = model.visibleErrorMessage {
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
    .onChange(of: model.catalogVisibilityRevision) {
      if case .media(let id) = selection, !model.catalogItems.contains(where: { $0.id == id }) {
        selection = nil
      }
      if case .collection(let id) = selection, !model.collections.contains(where: { $0.id == id }) {
        selection = nil
      }
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
      if model.profile?.isViewingSession == true {
        Section {
          Button {
            Task { await model.switchWatchingProfile() }
          } label: {
            Label(
              model.profile?.user?.username ?? "Switch Profile", systemImage: "person.crop.circle")
          }.disabled(model.isSelectingProfile).accessibilityIdentifier("switch-watching-profile")
        }
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
      findRequest = nil
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

  /// The browsing page stays alive underneath a detail page, so going back keeps its scroll
  /// position and artwork exactly where they were.
  private var content: some View {
    ZStack {
      browsePage
        .opacity(selection == nil ? 1 : 0)
        .allowsHitTesting(selection == nil)
        .accessibilityHidden(selection != nil)
      if let activeSelection = selection {
        // A detail page rises gently into place; going back fades it away over the page.
        selectedPage(activeSelection)
          .id(activeSelection)
          .transition(
            reduceMotion
              ? .opacity
              : .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.97)).combined(
                  with: .offset(y: 18)),
                removal: .opacity.combined(with: .scale(scale: 1.015)))
          )
          .zIndex(1)
      }
    }
    .animation(
      reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.4, dampingFraction: 0.86),
      value: selection
    )
    .onChange(of: selection) { _, value in
      if value == nil, destination == .home { Task { await model.refreshHome() } }
      // Typing must never reach a search field hidden underneath the detail page.
      if value != nil { NSApp.keyWindow?.makeFirstResponder(nil) }
    }
  }

  @ViewBuilder
  private func selectedPage(_ activeSelection: MediaSelection) -> some View {
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
  }

  @ViewBuilder
  private var browsePage: some View {
    switch destination {
    case .home:
      HomePage(
        onSelect: { selection = .media($0) },
        onSelectCollection: { selection = .collection($0) }
      )
      .task { await model.refreshHome() }
    case .library:
      LibraryPage(
        section: .library, findRequest: findRequest,
        onSelect: { selection = .media($0) },
        onSelectCollection: { selection = .collection($0) })
    case .recentlyAdded:
      LibraryPage(
        section: .recentlyAdded, findRequest: findRequest,
        onSelect: { selection = .media($0) },
        onSelectCollection: { selection = .collection($0) })
    case .tvShows:
      LibraryPage(
        section: .tvShows, findRequest: findRequest,
        onSelect: { selection = .media($0) },
        onSelectCollection: { selection = .collection($0) })
    case .movies:
      LibraryPage(
        section: .movies, findRequest: findRequest,
        onSelect: { selection = .media($0) },
        onSelectCollection: { selection = .collection($0) })
    }
  }
}

private struct HomePage: View {
  @EnvironmentObject private var model: AppModel
  let onSelect: (UUID) -> Void
  let onSelectCollection: (UUID) -> Void
  @State private var continueWatchingError: String?

  var body: some View {
    if model.catalogItems.isEmpty, model.home?.recommendation == nil,
      model.home?.continueWatching.isEmpty != false
    {
      Group {
        if model.visibleErrorMessage != nil || model.isRecoveringLocalHost {
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
      .alert(
        "Couldn't Update Continue Watching",
        isPresented: Binding(
          get: { continueWatchingError != nil },
          set: { if !$0 { continueWatchingError = nil } })
      ) {
        Button("OK") { continueWatchingError = nil }
      } message: {
        Text(continueWatchingError ?? "")
      }
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
            .buttonStyle(AureliaCardButtonStyle())
            .disabled(!item.isPlayable)
            .accessibilityLabel(
              ["Continue \(item.title)", CatalogPlaybackLogic.subtitle(for: item)]
                .compactMap { $0 }.joined(separator: ", ")
            )
            .accessibilityIdentifier("continue-\(item.id.uuidString.lowercased())")
            .contextMenu {
              Button("Remove from Continue Watching") {
                let profile = model.profile
                Task {
                  do {
                    try await model.setContinueWatchingHidden(mediaId: item.id, isHidden: true)
                  } catch {
                    guard !(error is CancellationError),
                      profile?.sessionId == model.profile?.sessionId,
                      profile?.serverId == model.profile?.serverId
                    else { return }
                    continueWatchingError = error.localizedDescription
                  }
                }
              }
              .disabled(!model.supportsLibraryState)
              if !model.supportsLibraryState { Text("Requires server version 1.5.3") }
            }
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
            .buttonStyle(AureliaCardButtonStyle())
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
            .buttonStyle(AureliaCardButtonStyle())
            .accessibilityIdentifier("collection-\(collection.id.uuidString.lowercased())")
          }
        }
      }
    }
  }
}

private struct HomeHero: View {
  @EnvironmentObject private var model: AppModel
  let item: CatalogItemSummary
  let action: () -> Void

  var body: some View {
    heroContent
      // The hero leads to its detail page; prepare it while Home is shown.
      .task(id: item.id) { model.prepareDetail(for: item) }
  }

  private var heroContent: some View {
    ZStack(alignment: .bottomLeading) {
      AuthenticatedArtwork(
        artwork: item.backdrop ?? item.poster,
        symbol: item.kind == .movie ? "film.fill" : "tv.fill",
        contentMode: .fill,
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

private struct LibraryPage: View {
  @EnvironmentObject private var model: AppModel
  let section: CatalogBrowseSection
  let findRequest: FindRequest?
  let onSelect: (UUID) -> Void
  let onSelectCollection: (UUID) -> Void
  @StateObject private var browser = LibraryBrowseController()
  @State private var search = ""
  @State private var query = CatalogBrowseQuery()
  @State private var loadedContext = ""
  @State private var completedRequestKey = ""
  @State private var retryRevision = 0
  @State private var showingCollectionEditor = false
  @State private var showingMetadataReviewQueue = false
  @FocusState private var searchFocused: Bool

  private var context: String {
    [
      model.profile?.serverId.uuidString ?? "none",
      model.profile?.user?.id.uuidString ?? "none",
      model.profile?.sessionId.uuidString ?? "none", section.rawValue,
    ].joined(separator: ":")
  }

  private var requestKey: String {
    "\(context):\(loadedContext):\(query.requestKey):\(search):\(model.catalogVisibilityRevision):\(retryRevision)"
  }

  private var hasFilters: Bool { section.hasUserFilters(query) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AureliaDesign.sectionSpacing) {
        if loadedContext == context {
          libraryHeader
          if hasFilters { activeFilters }
          if section == .library, search.isEmpty, !hasFilters, !model.collections.isEmpty {
            collectionRow
          }
        } else {
          Text(section.title)
            .font(AureliaDesign.pageTitle)
            .accessibilityIdentifier("library-title")
        }

        if loadedContext != context || completedRequestKey != requestKey || browser.isLoading {
          ProgressView()
            .frame(maxWidth: .infinity, minHeight: 250)
            .accessibilityLabel("Loading Library")
        } else if let error = browser.errorMessage {
          ContentUnavailableView {
            Label("Library Unavailable", systemImage: "wifi.exclamationmark")
          } description: {
            Text(error)
          } actions: {
            Button("Try Again") { retryRevision += 1 }
          }
          .frame(maxWidth: .infinity, minHeight: 250)
        } else if browser.items.isEmpty {
          if !search.isEmpty || hasFilters {
            ContentUnavailableView(
              "No Results", systemImage: "magnifyingglass",
              description: Text("Try another search or clear your filters.")
            )
            .frame(maxWidth: .infinity, minHeight: 300)
          } else {
            EmptyCatalogResults(
              query: search, canAddMedia: model.canManageMedia,
              addMedia: { model.showMediaManager() })
          }
        } else {
          resultSections
        }
      }
      .padding(AureliaDesign.pagePadding)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier("browse-\(section.rawValue)")
    .task(id: requestKey) {
      if loadedContext != context {
        browser.invalidate()
        search = ""
        if let profile = model.profile {
          query = LibraryBrowsePreferenceStore(
            defaults: LibraryBrowsePreferenceStore.applicationDefaults
          ).load(
            serverId: profile.serverId, userId: profile.user?.id ?? profile.sessionId,
            section: section)
        } else {
          query = section.defaultQuery
        }
        loadedContext = context
        return
      }
      let profile = model.profile
      let revision = model.catalogVisibilityRevision
      let request = requestKey
      await browser.load(query: query, search: search) { query, search in
        let items = try await model.browseCatalog(query: query, search: search)
        guard profile?.serverId == model.profile?.serverId,
          profile?.user?.id == model.profile?.user?.id,
          profile?.sessionId == model.profile?.sessionId,
          revision == model.catalogVisibilityRevision
        else { throw CancellationError() }
        return items
      }
      guard !Task.isCancelled, request == requestKey else { return }
      completedRequestKey = request
    }
    .task(id: "\(context):\(loadedContext):\(findRequest?.id.uuidString ?? "none")") {
      guard loadedContext == context, let findRequest else { return }
      if findRequest.startsNewSearch { search = "" }
      searchFocused = false
      await Task.yield()
      guard !Task.isCancelled, loadedContext == context else { return }
      searchFocused = true
    }
    .onChange(of: query) {
      guard loadedContext == context, let profile = model.profile else { return }
      LibraryBrowsePreferenceStore(defaults: LibraryBrowsePreferenceStore.applicationDefaults).save(
        query, serverId: profile.serverId, userId: profile.user?.id ?? profile.sessionId,
        section: section)
    }
    .onDisappear { browser.invalidate() }
    .sheet(isPresented: $showingCollectionEditor) {
      CollectionEditorSheet(collection: nil).environmentObject(model)
    }
    .sheet(isPresented: $showingMetadataReviewQueue) {
      MetadataReviewQueueSheet().environmentObject(model)
    }
  }

  private var libraryHeader: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(section.title)
          .font(AureliaDesign.pageTitle)
          .tracking(-0.35)
          .accessibilityIdentifier("library-title")
        if completedRequestKey == requestKey, !browser.isLoading {
          Text(String(browser.items.count))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
        Spacer()
        if model.canManageMedia, section == .library { managementActions }
      }
      HStack(spacing: 10) {
        searchField
        filterMenu
        sortMenu
      }
    }
  }

  private var searchField: some View {
    HStack(spacing: 9) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Search \(section.title)", text: $search)
        .textFieldStyle(.plain)
        .focused($searchFocused)
        .accessibilityIdentifier("library-search")
      if !search.isEmpty {
        Button {
          search = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear Search")
      }
    }
    .padding(.horizontal, 12)
    .frame(height: 38)
    .background(AureliaDesign.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
    .overlay { RoundedRectangle(cornerRadius: 10).stroke(AureliaDesign.hairline) }
  }

  private var filterMenu: some View {
    Menu {
      if section == .library {
        Picker("Media Type", selection: $query.kind) {
          Text("All Media").tag(Optional<MediaKind>.none)
          Text("Movies").tag(Optional(MediaKind.movie))
          Text("TV Shows").tag(Optional(MediaKind.series))
        }
      }
      Toggle("Favorites Only", isOn: $query.favoritesOnly)
      Picker("Genre", selection: $query.genre) {
        Text("All Genres").tag(Optional<String>.none)
        ForEach(genres, id: \.self) { Text($0).tag(Optional($0)) }
      }
      Menu("Release Year") {
        Picker("From", selection: fromYear) {
          Text("Any Year").tag(Optional<Int>.none)
          ForEach(years, id: \.self) { Text(String($0)).tag(Optional($0)) }
        }
        Picker("To", selection: toYear) {
          Text("Any Year").tag(Optional<Int>.none)
          ForEach(years, id: \.self) { Text(String($0)).tag(Optional($0)) }
        }
      }
      Picker("Watch Status", selection: $query.watchState) {
        ForEach(CatalogWatchFilter.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .disabled(!model.supportsLibraryState)
      if !model.supportsLibraryState { Text("Watch filters require server version 1.5.3") }
      Divider()
      Button("Clear Filters") { query.clearFilters(preserving: section.fixedKind) }
        .disabled(!hasFilters)
    } label: {
      Image(
        systemName: hasFilters
          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease"
      )
      .frame(width: 38, height: 38)
      .background(AureliaDesign.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
      .overlay { RoundedRectangle(cornerRadius: 10).stroke(AureliaDesign.hairline) }
    }
    .menuStyle(.borderlessButton)
    .accessibilityLabel("Filter Library")
    .accessibilityIdentifier("library-filters")
  }

  private var sortMenu: some View {
    Menu {
      Picker("Sort By", selection: $query.sort) {
        Text(search.isEmpty ? "Default" : "Relevance").tag(Optional<CatalogBrowseSort>.none)
        ForEach(CatalogBrowseSort.allCases, id: \.self) {
          Text($0.title).tag(Optional($0))
        }
      }
      Divider()
      Picker("Direction", selection: $query.descending) {
        Text("Ascending").tag(false)
        Text("Descending").tag(true)
      }
      .disabled(query.sort == nil)
    } label: {
      Image(systemName: "arrow.up.arrow.down")
        .frame(width: 38, height: 38)
        .background(AureliaDesign.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(AureliaDesign.hairline) }
    }
    .menuStyle(.borderlessButton)
    .accessibilityLabel("Sort: \(query.sort?.title ?? (search.isEmpty ? "Default" : "Relevance"))")
    .accessibilityIdentifier("library-sort")
  }

  private var activeFilters: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(filterSummary)
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("library-active-filters")
      Spacer(minLength: 8)
      Button("Clear Filters") { query.clearFilters(preserving: section.fixedKind) }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityIdentifier("library-clear-filters")
    }
  }

  private var filterSummary: String {
    var parts: [String] = []
    if section == .library, let kind = query.kind {
      parts.append(kind == .movie ? "Movies" : "TV Shows")
    }
    if query.favoritesOnly { parts.append("Favorites") }
    if let genre = query.genre { parts.append(genre) }
    if let from = query.yearFrom, let to = query.yearTo {
      parts.append(from == to ? String(from) : "\(from)–\(to)")
    } else if let from = query.yearFrom {
      parts.append("From \(from)")
    } else if let to = query.yearTo {
      parts.append("Through \(to)")
    }
    if query.watchState != .all { parts.append(query.watchState.title) }
    return parts.joined(separator: " · ")
  }

  private var genres: [String] {
    Set(model.catalogItems.flatMap(\.genres)).sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
  }

  private var years: [Int] { Set(model.catalogItems.compactMap(\.year)).sorted(by: >) }

  private var fromYear: Binding<Int?> {
    Binding(
      get: { query.yearFrom },
      set: { value in
        query.yearFrom = value
        if let value, let to = query.yearTo, value > to { query.yearTo = value }
      })
  }

  private var toYear: Binding<Int?> {
    Binding(
      get: { query.yearTo },
      set: { value in
        query.yearTo = value
        if let value, let from = query.yearFrom, value < from { query.yearFrom = value }
      })
  }

  private var managementActions: some View {
    HStack(spacing: 10) {
      Button {
        showingMetadataReviewQueue = true
      } label: {
        Label("Review Matches", systemImage: "checklist")
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("library-review-metadata")
      Button {
        model.showMediaManager()
      } label: {
        Image(systemName: "plus").frame(width: 32, height: 32)
      }
      .buttonStyle(.borderedProminent)
      .clipShape(Circle())
      .accessibilityLabel("Add Media")
      .accessibilityIdentifier("library-add-media")
      Button {
        showingCollectionEditor = true
      } label: {
        Image(systemName: "rectangle.stack.badge.plus").frame(width: 32, height: 32)
      }
      .buttonStyle(.bordered)
      .accessibilityLabel("Create Collection")
    }
  }

  private var collectionRow: some View {
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
          .buttonStyle(AureliaCardButtonStyle())
        }
      }
    }
  }

  @ViewBuilder private var resultSections: some View {
    let movies = browser.items.filter { $0.kind == .movie }
    let shows = browser.items.filter { $0.kind == .series }
    let episodes = browser.items.filter { $0.kind == .episode }
    if section == .movies || section == .tvShows
      || (section == .recentlyAdded && episodes.isEmpty)
    {
      posterGrid(browser.items, onSelect: onSelect)
    } else {
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
            episodeResults(episodes)
          }
        }
      }
    }
  }

  private func episodeResults(_ episodes: [CatalogItemSummary]) -> some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 280, maximum: 340), spacing: 22)],
      alignment: .leading, spacing: 22
    ) {
      ForEach(episodes) { episode in
        Button {
          model.startPlayback(item: episode)
        } label: {
          LandscapeMediaCard(item: episode, width: 300, eyebrow: episodeSearchEyebrow(episode))
        }
        .buttonStyle(AureliaCardButtonStyle())
        .disabled(!episode.isPlayable)
        .accessibilityLabel(
          "\(episode.title), \(CatalogPlaybackLogic.subtitle(for: episode) ?? "Episode")"
        )
        .accessibilityIdentifier("search-episode-\(episode.id.uuidString.lowercased())")
        .mediaActions(item: episode)
      }
    }
  }

  private func episodeSearchEyebrow(_ item: CatalogItemSummary) -> String {
    let number = [item.seasonNumber.map { "S\($0)" }, item.episodeNumber.map { "E\($0)" }]
      .compactMap { $0 }.joined(separator: " ")
    return [item.parentTitle, number.isEmpty ? nil : number].compactMap { $0 }.joined(
      separator: " · ")
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
        contentMode: .fill
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
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("collection-hero")
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
      .buttonStyle(AureliaCardButtonStyle())
      .accessibilityIdentifier("media-\(item.id.uuidString)")
      .mediaActions(item: item)
    }
  }
}
