import SwiftUI

/// Cmd-F focuses the library search; coming from Home or a detail page starts a new search.
private struct FindRequest: Equatable {
  let id = UUID()
  let startsNewSearch: Bool
}

private enum MediaSelection: Hashable {
  case media(UUID)
  case collection(UUID)
  case person(PersonSelection)
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
  @AppStorage(GeneralPreferenceKeys.sidebarVisibilityRevision) private
    var sidebarVisibilityRevision = 0
  @AppStorage(GeneralPreferenceKeys.sidebarItemOrder) private var sidebarItemOrder = ""
  @AppStorage(GeneralPreferenceKeys.showMoviesInSidebar) private var showMoviesInSidebar = true
  @AppStorage(GeneralPreferenceKeys.showSeriesInSidebar) private var showSeriesInSidebar = true
  @AppStorage(GeneralPreferenceKeys.showWatchlistInSidebar) private var showWatchlistInSidebar =
    true
  @AppStorage(GeneralPreferenceKeys.showCollectionsInSidebar) private var showCollectionsInSidebar =
    true
  @AppStorage(GeneralPreferenceKeys.defaultStartScreen) private var defaultStartScreen = "movies"

  var body: some View {
    GeometryReader { geometry in
      // Top-aligned: a vertically centred sidebar would sink below the window by half the
      // title bar height and cut off the profile at its foot.
      ZStack(alignment: .topLeading) {
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
            // Same top position as before the stack was top-aligned.
            .padding(
              .top, max(0, 44 - geometry.safeAreaInsets.top) + geometry.safeAreaInsets.top / 2
            )
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
      VStack(spacing: 12) {
        if let device = model.activeRemotePlayer {
          MacMiniRemoteView(device: device)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
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
            retryDisabled: model.isRecoveringLocalHost
          )
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .padding(.bottom, 24)
    }
    .animation(
      reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.82),
      value: model.visibleErrorMessage
    )
    .sheet(isPresented: $model.showingCollectionEditor) {
      CollectionEditorSheet(collection: nil).environmentObject(model)
    }
    .onChange(of: scenePhase) {
      if scenePhase == .active { Task { await model.refreshHome() } }
    }
    .onChange(of: model.requestedMediaDetail) { _, id in
      guard let id else { return }
      selection = .media(id)
      model.requestedMediaDetail = nil
    }
    .onChange(of: model.requestedPersonDetail) { _, person in
      guard let person else { return }
      selection = .person(person)
      model.requestedPersonDetail = nil
    }
    .onChange(of: model.catalogVisibilityRevision) {
      if case .media(let id) = selection, !model.catalogItems.contains(where: { $0.id == id }) {
        selection = nil
      }
      if case .collection(let id) = selection, !model.collections.contains(where: { $0.id == id }) {
        selection = nil
      }
    }
    .onAppear {
      restoreDestination()
    }
    .onChange(of: model.profile?.sessionId) {
      restoreDestination()
    }
    .onChange(of: destination) { _, newDestination in
      persistDestination(newDestination)
    }
  }

  private var visibleSidebarItems: [LibraryDestination] {
    _ = sidebarVisibilityRevision
    _ = sidebarItemOrder
    let order = SidebarPreferences.loadOrder()
    return order.filter { item in
      guard SidebarPreferences.isVisible(item) else { return false }
      if item == .watchlist && !model.supportsWatchlist { return false }
      return true
    }
  }

  private func restoreDestination() {
    guard let profile = model.profile else { return }
    let targetDestination: LibraryDestination
    switch defaultStartScreen {
    case "home": targetDestination = .home
    case "library": targetDestination = .library
    case "movies": targetDestination = .movies
    case "series": targetDestination = .tvShows
    case "continueWatching": targetDestination = .home
    case "collections": targetDestination = .collections
    case "watchlist": targetDestination = model.supportsWatchlist ? .watchlist : .library
    case "recentlyAdded": targetDestination = .recentlyAdded
    default:
      let store = LibraryDestinationStore(
        defaults: LibraryBrowsePreferenceStore.applicationDefaults)
      let restored = store.load(
        serverId: profile.serverId, userId: profile.user?.id ?? profile.sessionId)
      targetDestination = (restored == .watchlist && !model.supportsWatchlist) ? .home : restored
    }

    let visible = visibleSidebarItems
    if visible.contains(targetDestination) {
      destination = targetDestination
    } else if let first = visible.first {
      destination = first
    } else {
      destination = .library
    }
  }

  private func persistDestination(_ newDestination: LibraryDestination) {
    guard let profile = model.profile else { return }
    let store = LibraryDestinationStore(
      defaults: LibraryBrowsePreferenceStore.applicationDefaults)
    store.save(
      newDestination, serverId: profile.serverId, userId: profile.user?.id ?? profile.sessionId)
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      List(selection: $destination) {
        ForEach(visibleSidebarItems) { item in
          sidebarButton(item)
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      // The profile sits at the foot of the sidebar, like the account in the Apple TV app.
      if model.profile?.isViewingSession == true {
        Button {
          Task { await model.switchWatchingProfile() }
        } label: {
          HStack(spacing: 10) {
            AureliaProfileAvatar(
              id: model.profile?.user?.id, name: model.profile?.user?.username ?? "?", size: 30)
            Text(model.profile?.user?.username ?? "Switch Profile")
              .font(.body.weight(.semibold))
              .lineLimit(1)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 10)
          .frame(height: 46)
          .contentShape(Rectangle())
        }
        .buttonStyle(SidebarFooterButtonStyle())
        // Clears the window's rounded bottom corner.
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
        .disabled(model.isSelectingProfile)
        .help("Switch Profile")
        .accessibilityLabel("Switch Profile, \(model.profile?.user?.username ?? "")")
        .accessibilityIdentifier("switch-watching-profile")
      }
    }
    .accessibilityElement(children: .contain)
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
      Label {
        Text(item.title).font(.body.weight(destination == item ? .semibold : .regular))
      } icon: {
        // Tinted symbols, as in the Apple TV app's sidebar; on the selection they turn white
        // so they stay visible on the accent highlight.
        Image(systemName: item.symbol)
          .foregroundStyle(destination == item ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
      }
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
      // Switching pages in the sidebar cross-fades instead of cutting.
      browsePage
        .id(destination)
        .transition(.opacity)
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
                insertion: .opacity.combined(with: .scale(scale: 0.985)),
                removal: .opacity.combined(with: .scale(scale: 1.01)))
          )
          .zIndex(1)
      }
    }
    .animation(
      reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.4, dampingFraction: 0.86),
      value: selection
    )
    .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.22), value: destination)
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
    case .person(let person):
      PersonDetailView(
        person: person,
        onBack: { selection = nil },
        onSelect: { selection = .media($0) })
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
    case .watchlist:
      WatchlistPage(onSelect: { selection = .media($0) })
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
    case .collections:
      CollectionsPage(onSelectCollection: { selection = .collection($0) })
    case .history:
      HistoryPage(onSelect: { selection = .media($0) })
    case .statistics:
      StatisticsPage()
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
              model.startPlayback(item: item, intent: .resume)
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
            .mediaActions(item: item)
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
      .aureliaHeroSettle()
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
        .aureliaRiseIn(0)

        Text(item.title)
          .font(AureliaDesign.heroTitle)
          .tracking(-0.6)
          .lineLimit(2)
          .aureliaRiseIn(1)

        if !item.genres.isEmpty {
          Text(item.genres.prefix(3).joined(separator: "  ·  "))
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white.opacity(0.8))
            .aureliaRiseIn(2)
        }

        if let overview = item.overview, !overview.isEmpty {
          Text(overview)
            .font(.body)
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(3)
            .lineSpacing(2)
            .frame(maxWidth: 610, alignment: .leading)
            .aureliaRiseIn(3)
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
        .aureliaRiseIn(4)
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

  /// A list for this profile and page is shown; newer requests replace it in place.
  private var hasResultForContext: Bool {
    loadedContext == context && completedRequestKey.hasPrefix(context + ":")
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AureliaDesign.sectionSpacing) {
        if loadedContext == context {
          libraryHeader
          if section == .library, search.isEmpty, !hasFilters, !model.collections.isEmpty {
            collectionRow
          }
        } else {
          Text(section.title)
            .font(AureliaDesign.pageTitle)
            .accessibilityIdentifier("library-title")
        }

        if !hasResultForContext || (browser.items.isEmpty && browser.isLoading) {
          // Known lists appear at once; a spinner only shows when loading takes a moment.
          AureliaDelayedProgress()
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
      let cached = model.cachedBrowse(section: section, query: query, search: search)
      if let cached {
        browser.show(cached)
        completedRequestKey = request
      }
      let loadedQuery = query
      let loadedSearch = search
      await browser.load(query: query, search: search, quietly: cached != nil) { query, search in
        let items = try await model.browseCatalog(query: query, search: search)
        guard profile?.serverId == model.profile?.serverId,
          profile?.user?.id == model.profile?.user?.id,
          profile?.sessionId == model.profile?.sessionId,
          revision == model.catalogVisibilityRevision
        else { throw CancellationError() }
        return items
      }
      guard !Task.isCancelled, request == requestKey else { return }
      if browser.errorMessage == nil {
        model.storeBrowse(browser.items, section: section, query: loadedQuery, search: loadedSearch)
      }
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
        LibrarySortButton(query: $query, isSearching: !search.isEmpty)
      }
      LibraryFilterBar(
        section: section, query: $query, genres: genres, years: years,
        isSearching: !search.isEmpty, supportsWatchState: model.supportsLibraryState)
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
    .padding(.horizontal, 14)
    .frame(height: 38)
    .background(.white.opacity(0.08), in: Capsule())
    .overlay { Capsule().strokeBorder(AureliaDesign.hairline) }
    .frame(maxWidth: 520)
  }

  private var genres: [String] {
    Set(model.catalogItems.flatMap(\.genres)).sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
  }

  private var years: [Int] { Set(model.catalogItems.compactMap(\.year)).sorted(by: >) }

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
          model.startPlayback(item: episode, intent: .play)
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
      ZStack(alignment: .topTrailing) {
        AuthenticatedArtwork(artwork: collection.poster, symbol: "rectangle.stack.fill")
          .frame(width: 210, height: 280)
          .clipShape(RoundedRectangle(cornerRadius: AureliaDesign.cardRadius))
          .overlay {
            RoundedRectangle(cornerRadius: AureliaDesign.cardRadius)
              .stroke(hovering ? .white.opacity(0.25) : AureliaDesign.hairline, lineWidth: 1)
          }
          .shadow(color: .black.opacity(hovering ? 0.34 : 0), radius: 14, y: 8)

        if collection.isSmart {
          Label("Smart", systemImage: "sparkles")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().stroke(.white.opacity(0.25), lineWidth: 1) }
            .padding(10)
        }
      }
      Text(collection.name)
        .font(.headline)
        .lineLimit(1)
        .frame(width: 210, alignment: .leading)
      Text("\(collection.totalCount > 0 ? collection.totalCount : collection.items.count) titles")
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
    .scrollClipDisabled()
    .aureliaOverlayScrollbars()
    .aureliaCompactHeader(title: collection.name, threshold: 360, onBack: onBack)
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
      .aureliaHeroSettle()
      LinearGradient(
        stops: [
          .init(color: .black.opacity(0.7), location: 0),
          .init(color: .black.opacity(0.3), location: 0.4),
          .init(color: .clear, location: 0.75),
        ],
        startPoint: .leading,
        endPoint: .trailing)
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0.42),
          .init(color: AureliaDesign.canvas.opacity(0.3), location: 0.66),
          .init(color: AureliaDesign.canvas.opacity(0.78), location: 0.88),
          .init(color: AureliaDesign.canvas, location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom)

      VStack(alignment: .leading, spacing: 8) {
        Text(collection.isSmart ? "SMART COLLECTION" : "COLLECTION")
          .font(.caption.weight(.bold))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.72))
          .aureliaRiseIn(0)
        Text(collection.name)
          .font(AureliaDesign.heroTitle)
          .tracking(-0.6)
          .lineLimit(2)
          .aureliaRiseIn(1)
        Text("\(collection.totalCount > 0 ? collection.totalCount : collection.items.count) titles")
          .font(.callout.weight(.semibold))
          .foregroundStyle(.white.opacity(0.78))
          .aureliaRiseIn(2)
      }
      .padding(AureliaDesign.pagePadding)
      .padding(.bottom, 16)

      VStack {
        HStack {
          AureliaIconControl(symbol: "chevron.left", label: "Back", action: onBack)
          Spacer()
          let canEdit =
            collection.userId == model.profile?.user?.id
            || (collection.isShared && model.canManageMedia)
          if canEdit {
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
    // Full-bleed like every other hero; artwork continues beneath the sidebar.
    .frame(height: 460)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("collection-hero")
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
  // Filtering and sorting let cards glide to their new places instead of jumping.
  .aureliaListMotion(items.map(\.id))
}

private struct WatchlistPage: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.aureliaSidebarOverlap) private var sidebarOverlap
  let onSelect: (UUID) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        AureliaSectionHeading(title: "Watchlist", count: model.watchlistItems.count)
          .padding(.leading, max(0, sidebarOverlap - AureliaDesign.pagePadding + 24))
        if model.watchlistItems.isEmpty {
          ContentUnavailableView(
            "Your Watchlist Is Empty",
            systemImage: "bookmark",
            description: Text(
              "Save movies and TV shows you want to watch later from their detail page or context menu."
            )
          )
          .frame(maxWidth: .infinity, minHeight: 330)
        } else {
          posterGrid(model.watchlistItems, onSelect: onSelect)
        }
      }
      .padding(AureliaDesign.pagePadding)
      .padding(.top, 22)
    }
    .scrollClipDisabled()
    .aureliaOverlayScrollbars()
    .task { await model.refreshWatchlist() }
    .accessibilityIdentifier("watchlist-page")
  }
}

private struct PersonDetailView: View {
  @EnvironmentObject private var model: AppModel
  let person: PersonSelection
  let onBack: () -> Void
  let onSelect: (UUID) -> Void
  @State private var detail: PersonDetailResponse?
  @State private var isLoading = true
  @State private var errorMessage: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        HStack(spacing: 18) {
          AureliaIconControl(symbol: "chevron.left", label: "Back", action: onBack)
          AuthenticatedArtwork(
            artwork: detail?.profile ?? person.profile,
            symbol: "person.fill"
          )
          .frame(width: 84, height: 84)
          .clipShape(Circle())
          .overlay { Circle().stroke(AureliaDesign.hairline, lineWidth: 1) }
          VStack(alignment: .leading, spacing: 6) {
            Text((detail?.subtitle ?? person.subtitle ?? "Cast & Crew").uppercased())
              .font(.caption.weight(.bold))
              .tracking(1)
              .foregroundStyle(.secondary)
            Text(detail?.name ?? person.name)
              .font(AureliaDesign.heroTitle)
              .lineLimit(2)
            if let items = detail?.items {
              Text("\(items.count) \(items.count == 1 ? "title" : "titles") in your library")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
        }
        if isLoading {
          ProgressView("Loading titles…")
            .frame(maxWidth: .infinity, minHeight: 240)
        } else if let errorMessage {
          ContentUnavailableView(
            "Couldn’t Load Person",
            systemImage: "exclamationmark.triangle",
            description: Text(errorMessage)
          )
          .frame(maxWidth: .infinity, minHeight: 260)
        } else if let items = detail?.items, !items.isEmpty {
          posterGrid(items, onSelect: onSelect)
        } else {
          ContentUnavailableView(
            "No Titles Found",
            systemImage: "person.crop.circle.badge.questionmark",
            description: Text("No accessible movies or TV shows in this library match this person.")
          )
          .frame(maxWidth: .infinity, minHeight: 260)
        }
      }
      .padding(AureliaDesign.pagePadding)
      .padding(.top, 28)
      .padding(.bottom, 48)
    }
    .scrollClipDisabled()
    .aureliaOverlayScrollbars()
    .aureliaCompactHeader(title: detail?.name ?? person.name, threshold: 200, onBack: onBack)
    .task(id: person) {
      isLoading = true
      errorMessage = nil
      do {
        detail = try await model.personDetail(person)
        isLoading = false
      } catch {
        if !(error is CancellationError) {
          errorMessage = error.localizedDescription
          isLoading = false
        }
      }
    }
    .accessibilityIdentifier("person-detail-page")
  }
}

private struct CollectionsPage: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.aureliaSidebarOverlap) private var sidebarOverlap
  let onSelectCollection: (UUID) -> Void
  @State private var showingCreate = false
  @State private var franchises: [CollectionSummary] = []
  @State private var isLoadingFranchises = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 32) {
        HStack {
          AureliaSectionHeading(title: "Collections", count: model.collections.count)
          Spacer()
          Button {
            showingCreate = true
          } label: {
            Label("New Collection", systemImage: "plus")
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("new-collection-button")
        }
        .padding(.leading, max(0, sidebarOverlap - AureliaDesign.pagePadding + 24))

        if model.collections.isEmpty {
          ContentUnavailableView(
            "No Collections Yet",
            systemImage: "square.stack.3d.up",
            description: Text("Create manual collections or rule-based smart lists.")
          )
          .frame(maxWidth: .infinity, minHeight: 280)
        } else {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 210, maximum: 240), spacing: 22)],
            alignment: .leading,
            spacing: 30
          ) {
            ForEach(model.collections) { collection in
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

        if !franchises.isEmpty {
          Divider().padding(.top, 16)
          VStack(alignment: .leading, spacing: 14) {
            Text("Franchises in Library")
              .font(AureliaDesign.sectionTitle)
            Text(
              "Movie series detected by TMDB. Save any franchise to create an organized collection."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 210, maximum: 240), spacing: 22)],
              alignment: .leading,
              spacing: 24
            ) {
              ForEach(franchises) { franchise in
                VStack(alignment: .leading, spacing: 8) {
                  AuthenticatedArtwork(artwork: franchise.poster, symbol: "film.stack")
                    .frame(width: 210, height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: AureliaDesign.cardRadius))
                    .overlay {
                      RoundedRectangle(cornerRadius: AureliaDesign.cardRadius)
                        .stroke(AureliaDesign.hairline, lineWidth: 1)
                    }
                  Text(franchise.name)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(width: 210, alignment: .leading)
                  HStack {
                    Text("\(franchise.items.count) titles")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") {
                      Task {
                        _ = try? await model.createCollectionFromFranchise(franchise.id.uuidString)
                        await loadFranchises()
                      }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                  }
                  .frame(width: 210)
                }
              }
            }
          }
        }
      }
      .padding(AureliaDesign.pagePadding)
      .padding(.top, 22)
    }
    .scrollClipDisabled()
    .aureliaOverlayScrollbars()
    .task {
      await loadFranchises()
    }
    .sheet(isPresented: $showingCreate) {
      CollectionEditorSheet(collection: nil).environmentObject(model)
    }
    .accessibilityIdentifier("collections-page")
  }

  private func loadFranchises() async {
    guard let profile = model.profile else { return }
    isLoadingFranchises = true
    franchises = (try? await APIClient(profile: profile).franchises()) ?? []
    isLoadingFranchises = false
  }
}

private struct HistoryPage: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.aureliaSidebarOverlap) private var sidebarOverlap
  let onSelect: (UUID) -> Void
  @State private var items: [WatchHistoryItem] = []
  @State private var totalCount: Int = 0
  @State private var isLoading = false
  @State private var showingClearConfirmation = false
  @State private var errorMessage: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        HStack {
          AureliaSectionHeading(title: "Watch History", count: totalCount)
          Spacer()
          if !items.isEmpty {
            Button(role: .destructive) {
              showingClearConfirmation = true
            } label: {
              Label("Clear History", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("clear-history-button")
          }
        }
        .padding(.leading, max(0, sidebarOverlap - AureliaDesign.pagePadding + 24))

        if isLoading && items.isEmpty {
          ProgressView("Loading history…")
            .frame(maxWidth: .infinity, minHeight: 280)
        } else if items.isEmpty {
          ContentUnavailableView(
            "No Watch History",
            systemImage: "clock.arrow.circlepath",
            description: Text("Movies and episodes you watch will appear here.")
          )
          .frame(maxWidth: .infinity, minHeight: 280)
        } else {
          LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(items) { item in
              HStack(spacing: 16) {
                AuthenticatedArtwork(
                  artwork: item.poster,
                  symbol: item.kind == "movie" ? "film" : "tv"
                )
                .frame(width: 80, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                  RoundedRectangle(cornerRadius: 6).stroke(AureliaDesign.hairline, lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: 4) {
                  Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                  HStack(spacing: 8) {
                    if let eyebrow = item.eyebrow { Text(eyebrow) }
                    if let watched = item.watchedDate {
                      Text("·")
                      Text(watched.formatted(date: .abbreviated, time: .shortened))
                    }
                    Text("·")
                    Text("\(Int(item.completionPercentage))% completed")
                  }
                  .font(.caption)
                  .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                  onSelect(item.mediaId)
                } label: {
                  Image(systemName: "play.circle.fill")
                    .font(.title2)
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                  Task { await deleteItem(item) }
                } label: {
                  Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
              }
              .padding(.vertical, 4)
              Divider()
            }

            if items.count < totalCount {
              Button("Load More") {
                Task { await load(offset: items.count) }
              }
              .frame(maxWidth: .infinity)
              .padding(.top, 12)
            }
          }
        }
      }
      .padding(AureliaDesign.pagePadding)
      .padding(.top, 22)
    }
    .scrollClipDisabled()
    .aureliaOverlayScrollbars()
    .task { await load(offset: 0) }
    .confirmationDialog(
      "Clear Watch History?", isPresented: $showingClearConfirmation, titleVisibility: .visible
    ) {
      Button("Clear History", role: .destructive) {
        Task { await clearAll() }
      }
    } message: {
      Text(
        "All playback history for your profile will be removed. Media files and library items are untouched."
      )
    }
    .accessibilityIdentifier("history-page")
  }

  private func load(offset: Int) async {
    guard let profile = model.profile else { return }
    isLoading = true
    do {
      let page = try await APIClient(profile: profile).history(offset: offset, limit: 50)
      if offset == 0 {
        items = page.items
      } else {
        items.append(contentsOf: page.items)
      }
      totalCount = page.total
      isLoading = false
    } catch {
      isLoading = false
      errorMessage = error.localizedDescription
    }
  }

  private func deleteItem(_ item: WatchHistoryItem) async {
    guard let profile = model.profile else { return }
    do {
      try await APIClient(profile: profile).deleteHistoryItem(id: item.id)
      items.removeAll(where: { $0.id == item.id })
      totalCount = max(0, totalCount - 1)
    } catch {}
  }

  private func clearAll() async {
    guard let profile = model.profile else { return }
    do {
      try await APIClient(profile: profile).clearHistory()
      items.removeAll()
      totalCount = 0
    } catch {}
  }
}

private struct StatisticsPage: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.aureliaSidebarOverlap) private var sidebarOverlap
  @State private var stats: UserStatistics?
  @State private var isLoading = false
  @State private var selectedYear: Int?
  @State private var yearReview: YearInReview?
  @State private var errorMessage: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 32) {
        AureliaSectionHeading(title: "Statistics", count: nil)
          .padding(.leading, max(0, sidebarOverlap - AureliaDesign.pagePadding + 24))

        if isLoading && stats == nil {
          ProgressView("Loading statistics…")
            .frame(maxWidth: .infinity, minHeight: 280)
        } else if let error = errorMessage, stats == nil {
          VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 38))
              .foregroundStyle(.orange)
            Text("Could Not Load Statistics")
              .font(.headline)
            Text(error)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .frame(maxWidth: 400)
            Button("Try Again") {
              Task { await load() }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
          }
          .frame(maxWidth: .infinity, minHeight: 280)
        } else if let stats {
          if stats.totalHoursWatched == 0 && (stats.topGenres ?? []).isEmpty {
            VStack(spacing: 16) {
              Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
              Text("No Viewing Activity Yet")
                .font(.title3.weight(.semibold))
              Text(
                "Start watching movies or series in Aurelia to see your total watch time, streaks, and favorite genres here."
              )
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, minHeight: 280)
          } else {
            // Stat cards row
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)], spacing: 16
            ) {
              statCard(
                "Total Hours", value: String(format: "%.1f h", stats.totalHoursWatched),
                icon: "clock.fill")
              statCard(
                "Past 7 Days",
                value: String(format: "%.1f h", stats.hoursPast7Days ?? 0),
                icon: "calendar")
              statCard(
                "Past 30 Days",
                value: String(format: "%.1f h", stats.hoursPast30Days ?? 0),
                icon: "calendar.badge.clock")
              statCard(
                "Current Streak",
                value:
                  "\(stats.currentStreakDays ?? 0) \((stats.currentStreakDays ?? 0) == 1 ? "day" : "days")",
                icon: "flame.fill")
              statCard(
                "Longest Streak",
                value:
                  "\(stats.longestStreakDays ?? 0) \((stats.longestStreakDays ?? 0) == 1 ? "day" : "days")",
                icon: "trophy.fill")
              statCard(
                "Completion Rate",
                value: String(format: "%.0f%%", stats.completionRatePercent),
                icon: "checkmark.seal.fill")
            }

            // Busiest watching times
            HStack(spacing: 20) {
              statCard("Busiest Day", value: stats.busiestDayOfWeek, icon: "calendar")
              statCard(
                "Most Active Time", value: stats.busiestTimeOfDay ?? "—",
                icon: "clock")
            }

            // Top Genres
            if let genres = stats.topGenres, !genres.isEmpty {
              VStack(alignment: .leading, spacing: 14) {
                Text("Top Genres").font(AureliaDesign.sectionTitle)
                HStack(spacing: 10) {
                  ForEach(genres.prefix(6), id: \.name) { genre in
                    HStack(spacing: 6) {
                      Text(genre.name).font(.body.weight(.medium))
                      Text("\(genre.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.1), in: Capsule())
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AureliaDesign.surface, in: RoundedRectangle(cornerRadius: 10))
                  }
                }
              }
            }

            // Weekly Hours Visual Bar
            if !stats.weeklyHours.isEmpty {
              VStack(alignment: .leading, spacing: 14) {
                Text("Hours by Week").font(AureliaDesign.sectionTitle)
                HStack(alignment: .bottom, spacing: 12) {
                  let maxHours = max(1.0, stats.weeklyHours.map(\.hours).max() ?? 1.0)
                  ForEach(stats.weeklyHours, id: \.period) { item in
                    VStack(spacing: 6) {
                      Text(String(format: "%.1f", item.hours))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                      RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor)
                        .frame(width: 32, height: max(6, CGFloat(item.hours / maxHours) * 120))
                      Text(item.period.components(separatedBy: "-W").last ?? item.period)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                  }
                }
                .frame(height: 160)
              }
            }

            // Year in Review
            if let years = stats.yearsAvailable, !years.isEmpty {
              VStack(alignment: .leading, spacing: 14) {
                HStack {
                  Text("Year in Review").font(AureliaDesign.sectionTitle)
                  Spacer()
                  Picker(
                    "Year",
                    selection: Binding(
                      get: {
                        selectedYear ?? years.first
                          ?? Calendar.current.component(.year, from: Date())
                      },
                      set: { year in
                        selectedYear = year
                        Task { await loadYear(year) }
                      }
                    )
                  ) {
                    ForEach(years, id: \.self) { y in
                      Text("\(y)").tag(y)
                    }
                  }
                  .frame(width: 120)
                }

                if let review = yearReview {
                  HStack(spacing: 16) {
                    statCard(
                      "Total Hours", value: String(format: "%.1f h", review.totalHours),
                      icon: "clock"
                    )
                    statCard("Total Titles", value: "\(review.totalTitles)", icon: "film.stack")
                    statCard("Movies", value: "\(review.movieCount)", icon: "film")
                    statCard("Episodes", value: "\(review.episodeCount)", icon: "tv")
                  }
                }
              }
            }
          }
        }
      }
      .padding(AureliaDesign.pagePadding)
      .padding(.top, 22)
    }
    .scrollClipDisabled()
    .aureliaOverlayScrollbars()
    .task { await load() }
    .accessibilityIdentifier("statistics-page")
  }

  private func statCard(_ title: String, value: String, icon: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Image(systemName: icon).foregroundStyle(.tint).font(.caption)
      }
      Text(value).font(.title2.weight(.bold))
    }
    .padding(16)
    .background(AureliaDesign.surface, in: RoundedRectangle(cornerRadius: AureliaDesign.cardRadius))
    .overlay {
      RoundedRectangle(cornerRadius: AureliaDesign.cardRadius).stroke(
        AureliaDesign.hairline, lineWidth: 1)
    }
  }

  private func load() async {
    guard let profile = model.profile else {
      errorMessage = "No active profile session."
      return
    }
    isLoading = true
    errorMessage = nil
    do {
      let loaded = try await APIClient(profile: profile).statistics()
      stats = loaded
      if let years = loaded.yearsAvailable, let firstYear = years.first {
        selectedYear = firstYear
        await loadYear(firstYear)
      }
      isLoading = false
    } catch {
      isLoading = false
      errorMessage = error.localizedDescription
    }
  }

  private func loadYear(_ year: Int) async {
    guard let profile = model.profile else { return }
    yearReview = try? await APIClient(profile: profile).yearInReview(year: year)
  }
}

struct MacMiniRemoteView: View {
  @EnvironmentObject private var model: AppModel
  let device: RemotePlayerDevice

  var body: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Image(systemName: "airplayvideo")
            .foregroundStyle(Color.accentColor)
          Text("Playing on \(device.deviceName)")
            .font(.caption.bold())
            .foregroundStyle(Color.accentColor)
        }
        if let title = model.remotePlaybackTitle {
          Text(title)
            .font(.subheadline.bold())
            .lineLimit(1)
            .foregroundStyle(.white)
        }
      }
      .frame(minWidth: 140, maxWidth: 220, alignment: .leading)

      HStack(spacing: 12) {
        Button {
          model.sendRemotePlaybackCommand(action: "skip", skipSeconds: -10)
        } label: {
          Image(systemName: "gobackward.10")
            .font(.system(size: 14))
        }
        .buttonStyle(.plain)

        Button {
          model.sendRemotePlaybackCommand(action: model.isRemotePlaying ? "pause" : "resume")
        } label: {
          Image(systemName: model.isRemotePlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 18))
        }
        .buttonStyle(.plain)

        Button {
          model.sendRemotePlaybackCommand(action: "skip", skipSeconds: 10)
        } label: {
          Image(systemName: "goforward.10")
            .font(.system(size: 14))
        }
        .buttonStyle(.plain)
      }

      if model.remotePlaybackDuration > 0 {
        Slider(
          value: Binding(
            get: { model.remotePlaybackPosition },
            set: { model.sendRemotePlaybackCommand(action: "seek", positionSeconds: $0) }
          ),
          in: 0...model.remotePlaybackDuration
        )
        .frame(minWidth: 160, maxWidth: 280)
      }

      Button {
        model.stopRemotePlayback()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 16))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Stop remote playback")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    .overlay(
      RoundedRectangle(cornerRadius: 16)
        .stroke(Color.white.opacity(0.12), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
  }
}
