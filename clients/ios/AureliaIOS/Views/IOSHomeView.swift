import SwiftUI

/// Home follows the Mac layout: a full-bleed hero, then quiet section headers and
/// horizontal shelves. Focus moves only through the native focus engine.
struct IOSHomeView: View {
  @EnvironmentObject private var model: IOSAppModel
  @StateObject private var actions = IOSLibraryActions()
  @State private var playback: IOSHomePlayback?
  @State private var launching = false
  @State private var detailItem: IOSHomeDetail?
  @State private var unavailable: IOSCatalogItem?
  /// The server returns at most this many items in Home's catalog shelves.
  private static let shelfLimit = 30

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: IOSDesign.s(54)) {
        if let home = model.home {
          if let hero = hero(home) {
            IOSHomeHero(item: model.overlay(hero), launching: launching) { play($0) }
          } else {
            Text("Home").font(.system(size: IOSDesign.s(52), weight: .bold))
              .padding(.horizontal, IOSDesign.pagePadding).padding(.top, IOSDesign.s(170))
          }
          // Same order as the Mac Home page.
          shelf("Continue Watching", items: home.continueWatching, section: .continueWatching)
          if model.supportsWatchlist && !model.watchlistItems.isEmpty {
            shelf("Watchlist", items: model.watchlistItems, section: .watchlist)
          }
          ForEach(model.homeGenres) { row in genreShelf(row) }
          shelf("Favorites", items: home.favorites, section: .favorites)
          if !home.collections.isEmpty { collections(home.collections) }
          shelf("Recently Added", items: home.recentlyAdded, section: .recentlyAdded)
          if home.continueWatching.isEmpty && model.watchlistItems.isEmpty && home.favorites.isEmpty
            && home.recentlyAdded.isEmpty
          {
            ContentUnavailableView("Your Library Is Empty", systemImage: "film")
          }
        }
        if model.homeLoading && model.home == nil {
          ProgressView().frame(maxWidth: .infinity).padding(.top, IOSDesign.s(200))
        }
        if let error = model.homeError {
          VStack(alignment: .leading, spacing: IOSDesign.s(20)) {
            IOSErrorText(message: error)
            Button("Try Again") { Task { await model.loadHome() } }.buttonStyle(IOSButtonStyle())
          }.padding(.horizontal, IOSDesign.pagePadding)
        }
      }.padding(.bottom, IOSDesign.s(80))
    }
    // The hero artwork reaches the top edge beneath the native tab bar.
    .ignoresSafeArea(edges: .top)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .task(id: model.libraryRefresh) {
      await model.loadHome()
      await model.preloadLibrary()
    }
    .modifier(IOSLibraryActionPresentation(actions: actions))
    .navigationDestination(item: $detailItem) { value in
      IOSDetailView(id: value.item.detailID, initial: value.item)
    }
    .fullScreenCover(
      item: $playback,
      onDismiss: {
        model.playerPresented = false
        Task { await model.loadHome() }
      },
      content: { request in
        if let connection = model.connection, let session = model.session {
          IOSPlayerView(makeController: {
            IOSPlaybackController(
              connection: connection, session: session, mediaID: request.target.id,
              title: request.title, outbox: model.environment.outbox,
              api: model.makeClient(connection: connection, session: session),
              runtime: model.environment.makePlaybackRuntime(),
              queue: request.queue,
              seriesID: request.target.kind == .episode ? request.target.parentId : nil,
              preferencesStore: model.environment.preferences,
              onClose: { playback = nil },
              onSessionFailure: { failure in
                guard model.session?.sessionId == session.sessionId else { return }
                model.handleSessionFailure(failure)
                playback = nil
              })
          })
        }
      }
    )
    .onChange(of: model.session?.sessionId) { _, _ in playback = nil }
    .onChange(of: model.remotePlaybackItem) { _, item in
      if let item {
        playback = IOSHomePlayback(target: item, queue: [], title: item.title)
        model.remotePlaybackItem = nil
      }
    }
    .alert(
      "Not Available",
      isPresented: Binding(get: { unavailable != nil }, set: { if !$0 { unavailable = nil } }),
      presenting: unavailable
    ) { item in
      Button("Show Details") {
        detailItem = IOSHomeDetail(item: item)
        unavailable = nil
      }
      Button("OK", role: .cancel) { unavailable = nil }
    } message: { item in
      Text(
        "\(item.availabilityMessage ?? "This title can't be played right now.") Connect the drive on your Mac, then try again."
      )
    }
  }

  /// Continue Watching starts playback right away from the server's resume target.
  private func play(_ item: IOSCatalogItem) {
    // Offline titles stay reachable in Continue Watching; selecting one explains why.
    guard item.isPlayable else {
      unavailable = item
      return
    }
    guard !launching, playback == nil, let api = model.client else { return }
    launching = true
    let sessionID = model.session?.sessionId
    Task {
      defer { launching = false }
      do {
        let plan = try await api.playbackPlan(mediaID: item.id)
        guard model.session?.sessionId == sessionID, playback == nil else { return }
        guard let target = plan.target else {
          detailItem = IOSHomeDetail(item: item)
          return
        }
        guard target.isPlayable else {
          unavailable = target
          return
        }
        let series = target.parentTitle ?? item.parentTitle
        let title = target.episodeLabel.map { "\(series ?? target.title) · \($0)" } ?? target.title
        model.playerPresented = true
        playback = IOSHomePlayback(target: target, queue: plan.queue, title: title)
      } catch {
        guard model.session?.sessionId == sessionID else { return }
        actions.error = error.localizedDescription
        model.handleSessionFailure(error)
      }
    }
  }

  private func hero(_ home: IOSHome) -> IOSCatalogItem? {
    home.recommendation ?? home.continueWatching.first ?? home.recentlyAdded.first
  }

  @ViewBuilder
  private func shelf(_ title: String, items: [IOSCatalogItem], section: IOSBrowseSection)
    -> some View
  {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: IOSDesign.s(26)) {
        IOSSectionHeader(title: title, count: items.count).padding(
          .horizontal, IOSDesign.pagePadding)
        ScrollView(.horizontal) {
          LazyHStack(alignment: .top, spacing: IOSDesign.s(48)) {
            ForEach(items) { original in
              let item = model.overlay(original)
              Group {
                if section == .continueWatching {
                  Button {
                    play(item)
                  } label: {
                    IOSContinueCard(item: item)
                  }
                } else {
                  NavigationLink {
                    IOSDetailView(id: item.detailID, initial: item)
                  } label: {
                    IOSPosterLabel(item: item).frame(width: IOSDesign.posterWidth)
                  }
                }
              }
              .buttonStyle(.borderless)
              .accessibilityIdentifier("home-\(section.rawValue)-\(item.id)")
              .contextMenu {
                if section == .continueWatching {
                  Button("Show Details") { detailItem = IOSHomeDetail(item: item) }
                }
                IOSMediaContextActions(
                  item: item, actions: actions, continuation: section == .continueWatching)
              }
            }
            if section != .continueWatching, items.count >= Self.shelfLimit {
              NavigationLink {
                IOSBrowseDestination(section: section)
              } label: {
                IOSShowAllTile()
              }.buttonStyle(.borderless).accessibilityIdentifier("home-all-\(section.rawValue)")
            }
          }.padding(.horizontal, IOSDesign.pagePadding).padding(.vertical, IOSDesign.s(16))
        }.scrollIndicators(.hidden).scrollClipDisabled()
      }
    }
  }

  private func genreShelf(_ row: IOSHomeGenreRow) -> some View {
    VStack(alignment: .leading, spacing: IOSDesign.s(26)) {
      IOSSectionHeader(title: row.genre, count: row.items.count).padding(
        .horizontal, IOSDesign.pagePadding)
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: IOSDesign.s(48)) {
          ForEach(row.items) { original in
            let item = model.overlay(original)
            NavigationLink {
              IOSDetailView(id: item.detailID, initial: item)
            } label: {
              IOSPosterLabel(item: item).frame(width: IOSDesign.posterWidth)
            }.buttonStyle(.borderless)
              .accessibilityIdentifier("home-genre-\(row.genre)-\(item.id)")
              .contextMenu { IOSMediaContextActions(item: item, actions: actions) }
          }
        }.padding(.horizontal, IOSDesign.pagePadding).padding(.vertical, IOSDesign.s(16))
      }.scrollIndicators(.hidden).scrollClipDisabled()
    }
  }

  private func collections(_ values: [IOSCollection]) -> some View {
    VStack(alignment: .leading, spacing: IOSDesign.s(26)) {
      IOSSectionHeader(title: "Collections", count: values.count).padding(
        .horizontal, IOSDesign.pagePadding)
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: IOSDesign.s(48)) {
          ForEach(values) { collection in
            NavigationLink {
              IOSCollectionView(collection: collection)
            } label: {
              IOSCollectionCard(collection: collection).frame(width: IOSDesign.posterWidth)
            }.buttonStyle(.borderless).accessibilityIdentifier("collection-\(collection.id)")
          }
          if values.count >= Self.shelfLimit {
            NavigationLink {
              IOSCollectionsView()
            } label: {
              IOSShowAllTile()
            }.buttonStyle(.borderless).accessibilityIdentifier("home-all-collections")
          }
        }.padding(.horizontal, IOSDesign.pagePadding).padding(.vertical, IOSDesign.s(16))
      }.scrollIndicators(.hidden).scrollClipDisabled()
    }
  }
}

/// Full-bleed artwork with the Mac hero gradients and one primary action.
private struct IOSHomeHero: View {
  let item: IOSCatalogItem
  let launching: Bool
  let play: (IOSCatalogItem) -> Void
  var body: some View {
    ZStack(alignment: .bottomLeading) {
      IOSHeroBackdrop(artwork: item.backdrop ?? item.poster)
      VStack(alignment: .leading, spacing: IOSDesign.s(18)) {
        IOSEyebrow(
          text: (item.kind == .episode
            ? ["TV Show", item.episodeLabel] : [item.kindLabel, item.year.map(String.init)])
            .compactMap { $0 }.joined(separator: " · "))
        Text(item.parentTitle ?? item.title).font(.system(size: IOSDesign.s(72), weight: .bold))
          .tracking(-0.8).lineLimit(2)
        if !item.genres.isEmpty {
          Text(item.genres.prefix(3).joined(separator: " · ")).font(
            .system(size: IOSDesign.s(24), weight: .semibold))
        }
        if let overview = item.overview {
          Text(overview).font(.system(size: IOSDesign.s(26))).lineLimit(3).frame(
            maxWidth: IOSDesign.s(1000), alignment: .leading
          )
          .foregroundStyle(.white.opacity(0.88))
        }
        Group {
          if item.progressFraction != nil {
            Button {
              play(item)
            } label: {
              Label("Continue", systemImage: "play.fill")
            }.disabled(launching)
          } else {
            NavigationLink {
              IOSDetailView(id: item.detailID, initial: item)
            } label: {
              Label("Open", systemImage: "arrow.right")
            }
          }
        }.buttonStyle(IOSButtonStyle(kind: .primary)).padding(.top, IOSDesign.s(10))
          .accessibilityIdentifier("home-hero")
      }.padding(.horizontal, IOSDesign.pagePadding).padding(.bottom, IOSDesign.s(60))
    }.frame(maxWidth: .infinity, minHeight: IOSDesign.s(760), alignment: .bottomLeading)
  }
}

/// Backdrop with the Mac's left-to-right and bottom fades into the canvas.
struct IOSHeroBackdrop: View {
  let artwork: IOSArtwork?
  var body: some View {
    IOSArtworkView(artwork: artwork, width: 1920, symbol: nil)
      .overlay {
        LinearGradient(
          stops: [
            .init(color: .black.opacity(0.82), location: 0),
            .init(color: .black.opacity(0.5), location: 0.36),
            .init(color: .clear, location: 0.74),
          ], startPoint: .leading, endPoint: .trailing)
      }
      .overlay {
        LinearGradient(
          stops: [
            .init(color: .clear, location: 0.45),
            .init(color: IOSDesign.canvas.opacity(0.4), location: 0.74),
            .init(color: IOSDesign.canvas, location: 1),
          ], startPoint: .top, endPoint: .bottom)
      }
      .ignoresSafeArea()
      .accessibilityHidden(true)
  }
}

/// Landscape Continue Watching card with its text and progress inside the image.
struct IOSContinueCard: View {
  let item: IOSCatalogItem
  var body: some View {
    ZStack(alignment: .bottomLeading) {
      IOSArtworkView(artwork: item.backdrop ?? item.poster, width: 1280, symbol: nil)
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0.35), .init(color: .black.opacity(0.25), location: 0.55),
          .init(color: .black.opacity(0.9), location: 1),
        ], startPoint: .top, endPoint: .bottom)
      VStack(alignment: .leading, spacing: IOSDesign.s(6)) {
        IOSEyebrow(text: "Continue Watching", size: 16)
        Text(item.parentTitle ?? item.title).font(.system(size: IOSDesign.s(26), weight: .bold))
          .lineLimit(1)
        Text(detail).font(.system(size: IOSDesign.s(20))).foregroundStyle(.white.opacity(0.75))
          .lineLimit(1)
        if let fraction = item.progressFraction {
          IOSProgressBar(fraction: fraction).padding(.top, IOSDesign.s(8))
        }
      }.padding(IOSDesign.s(20))
    }
    .frame(width: IOSDesign.landscapeWidth, height: IOSDesign.landscapeWidth * 9 / 16)
    .clipShape(RoundedRectangle(cornerRadius: IOSDesign.cardRadius, style: .continuous))
    .hoverEffect(.highlight)
  }
  private var detail: String {
    if let message = item.availabilityMessage { return message }
    if let episode = item.episodeLabel { return "\(episode) · \(item.title)" }
    return item.year.map(String.init) ?? item.kindLabel
  }
}

struct IOSCollectionCard: View {
  let collection: IOSCollection
  var body: some View {
    VStack(alignment: .leading, spacing: IOSDesign.s(18)) {
      ZStack(alignment: .topLeading) {
        IOSArtworkView(artwork: collection.poster, width: 640, symbol: "rectangle.stack")
          .aspectRatio(2 / 3, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: IOSDesign.cardRadius, style: .continuous))
          .hoverEffect(.highlight)
        if collection.isSmart {
          Text("Smart")
            .font(.system(size: IOSDesign.s(16), weight: .bold))
            .padding(.horizontal, IOSDesign.s(10))
            .padding(.vertical, IOSDesign.s(4))
            .background(.ultraThinMaterial, in: Capsule())
            .padding(IOSDesign.s(12))
        }
      }
      VStack(alignment: .leading, spacing: IOSDesign.s(6)) {
        Text(collection.name).font(.system(size: IOSDesign.s(24), weight: .semibold)).lineLimit(1)
        let count = collection.totalCount > 0 ? collection.totalCount : collection.items.count
        Text(count == 1 ? "1 title" : "\(count) titles")
          .font(.system(size: IOSDesign.s(20))).foregroundStyle(.secondary)
      }
    }
  }
}

/// A single end-of-shelf tile instead of header buttons on every row.
struct IOSShowAllTile: View {
  var body: some View {
    VStack(spacing: IOSDesign.s(18)) {
      Image(systemName: "chevron.right").font(.system(size: IOSDesign.s(34), weight: .semibold))
      Text("Show All").font(.system(size: IOSDesign.s(24), weight: .semibold))
    }
    .frame(width: IOSDesign.posterWidth, height: IOSDesign.posterWidth * 3 / 2)
    .background(IOSDesign.surface, in: RoundedRectangle(cornerRadius: IOSDesign.cardRadius))
    .hoverEffect(.highlight)
  }
}

struct IOSCollectionsView: View {
  @EnvironmentObject private var model: IOSAppModel
  @State private var collections: [IOSCollection] = []
  @State private var loading = false
  @State private var complete = false
  @State private var error: String?
  @State private var generation = UUID()
  @FocusState private var focused: UUID?
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: IOSDesign.s(24)) {
        IOSSectionHeader(title: "Collections", count: collections.isEmpty ? nil : collections.count)
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: IOSDesign.s(48)), count: 6),
          spacing: IOSDesign.s(56)
        ) {
          ForEach(collections) { collection in
            NavigationLink {
              IOSCollectionView(collection: collection)
            } label: {
              IOSCollectionCard(collection: collection)
            }.buttonStyle(.borderless).focused($focused, equals: collection.id).onAppear {
              if collection.id == collections.last?.id { Task { await next() } }
            }
          }
        }.defaultFocus($focused, collections.first?.id, priority: .userInitiated)
        if loading { ProgressView() }
        if let error {
          IOSErrorText(message: error)
          Button("Try Again") { Task { await next() } }.buttonStyle(IOSButtonStyle())
        }
        if complete && collections.isEmpty {
          Text("No collections available.").foregroundStyle(.secondary)
        }
      }.padding(.horizontal, IOSDesign.pagePadding).padding(.vertical, IOSDesign.s(40))
    }.background(IOSDesign.canvas.ignoresSafeArea())
      .task(id: model.libraryRefresh) {
        generation = UUID()
        complete = false
        loading = false
        await next(replacing: true)
      }
  }
  /// `replacing` refreshes the first page in place instead of emptying the grid.
  private func next(replacing: Bool = false) async {
    guard !loading, !complete, let api = model.client else { return }
    let run = generation
    let session = model.session?.sessionId
    loading = true
    defer { if generation == run { loading = false } }
    do {
      let values = try await api.collections(offset: replacing ? 0 : collections.count)
      guard !Task.isCancelled, generation == run, model.session?.sessionId == session else {
        return
      }
      if replacing {
        collections = values
      } else {
        let old = Set(collections.map(\.id))
        collections += values.filter { !old.contains($0.id) }
      }
      complete = values.count < 60
      error = nil
    } catch {
      guard generation == run, model.session?.sessionId == session else { return }
      self.error = error.localizedDescription
      model.handleSessionFailure(error)
    }
  }
}

struct IOSCollectionView: View {
  @EnvironmentObject private var model: IOSAppModel
  let collection: IOSCollection
  @StateObject private var actions = IOSLibraryActions()
  @State private var current: IOSCollection?
  @State private var loading = false
  @State private var unavailable = false
  @State private var error: String?
  @State private var requestID = UUID()
  @FocusState private var focused: UUID?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: IOSDesign.s(32)) {
        IOSSectionHeader(title: current?.name ?? "Collection", count: current?.items.count)
        if let current {
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: IOSDesign.s(48)), count: 6),
            spacing: IOSDesign.s(56)
          ) {
            ForEach(current.items) { original in
              let item = model.overlay(original)
              NavigationLink {
                IOSDetailView(id: item.detailID, initial: item)
              } label: {
                IOSPosterLabel(item: item)
              }
              .buttonStyle(.borderless).focused($focused, equals: item.id)
              .accessibilityIdentifier("collection-item-\(item.id)")
              .contextMenu { IOSMediaContextActions(item: item, actions: actions) }
            }
          }.defaultFocus($focused, current.items.first?.id, priority: .userInitiated)

          if current.items.isEmpty {
            ContentUnavailableView("No Titles Available", systemImage: "rectangle.stack")
          }
        }
        if loading { ProgressView().accessibilityIdentifier("collection-loading") }
        if unavailable {
          ContentUnavailableView("Collection Unavailable", systemImage: "rectangle.stack")
            .accessibilityIdentifier("collection-unavailable")
        }
        if let error {
          IOSErrorText(message: error)
          Button("Try Again") { Task { await reload() } }.buttonStyle(IOSButtonStyle())
        }
      }.padding(.horizontal, IOSDesign.pagePadding).padding(.vertical, IOSDesign.s(40))
    }.background(IOSDesign.canvas.ignoresSafeArea())
      .task(id: model.libraryRefresh) { await reload() }
      .modifier(IOSLibraryActionPresentation(actions: actions))
  }

  private func reload() async {
    guard let api = model.client, let sessionID = model.session?.sessionId else { return }
    let request = UUID()
    requestID = request
    loading = current == nil
    unavailable = false
    error = nil
    defer {
      if requestID == request, model.session?.sessionId == sessionID { loading = false }
    }
    do {
      var offset = 0
      while true {
        let page = try await api.collections(offset: offset)
        guard !Task.isCancelled, requestID == request, model.session?.sessionId == sessionID else {
          return
        }
        if let value = page.first(where: { $0.id == collection.id }) {
          for item in value.items { model.updateSummary(item) }
          current = value
          return
        }
        if page.count < 60 {
          unavailable = true
          return
        }
        offset += page.count
      }
    } catch {
      guard !Task.isCancelled, requestID == request, model.session?.sessionId == sessionID else {
        return
      }
      self.error = error.localizedDescription
      model.handleSessionFailure(error)
    }
  }
}

private struct IOSHomeDetail: Hashable {
  let item: IOSCatalogItem
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.item.id == rhs.item.id }
  func hash(into hasher: inout Hasher) { hasher.combine(item.id) }
}

private struct IOSHomePlayback: Identifiable {
  let target: IOSCatalogItem
  let queue: [IOSCatalogItem]
  let title: String
  var id: UUID { target.id }
}
