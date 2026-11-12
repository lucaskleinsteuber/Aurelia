import SwiftUI

/// Home follows the Mac layout: a full-bleed hero, then quiet section headers and
/// horizontal shelves. Focus moves only through the native focus engine.
struct TVHomeView: View {
  @EnvironmentObject private var model: TVAppModel
  @StateObject private var actions = TVLibraryActions()
  @State private var playback: TVHomePlayback?
  @State private var launching = false
  @State private var detailItem: TVHomeDetail?
  @State private var unavailable: TVCatalogItem?
  @State private var movieNight: TVMovieNightLaunch?
  @State private var movieNights: [TVMovieNightSummary] = []
  /// The server returns at most this many items in Home's catalog shelves.
  private static let shelfLimit = 30

  /// Parties others started at home, to join with one press.
  private var watchTogether: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Watch Together").font(.system(size: 34, weight: .bold))
      HStack(spacing: 26) {
        ForEach(model.watchParties) { party in
          Button {
            Task { await model.joinWatchTogether(party) }
          } label: {
            Label("Join \(party.hostName) · \(party.title)", systemImage: "person.2.fill")
          }.buttonStyle(TVButtonStyle())
            .accessibilityIdentifier("home-watch-together")
        }
      }.focusSection()
    }.padding(.horizontal, TVDesign.pagePadding)
  }

  /// Movie Night: this Apple TV becomes the screen everyone looks at while the phones swipe.
  private var movieNightRow: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Movie Night").font(.system(size: 34, weight: .bold))
      HStack(spacing: 26) {
        Button {
          movieNight = TVMovieNightLaunch(joining: nil)
        } label: {
          Label("Can't Decide? Start Movie Night", systemImage: "rectangle.stack.fill")
        }
        .buttonStyle(TVButtonStyle())
        .accessibilityIdentifier("home-movie-night")
        ForEach(movieNights) { night in
          Button {
            movieNight = TVMovieNightLaunch(joining: night)
          } label: {
            Label("Show \(night.hostName)'s Movie Night", systemImage: "person.3.fill")
          }
          .buttonStyle(TVButtonStyle())
        }
      }.focusSection()
    }.padding(.horizontal, TVDesign.pagePadding)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 54) {
        if let home = model.home {
          if let hero = hero(home) {
            TVHomeHero(item: model.overlay(hero), launching: launching) { play($0) }
          } else {
            Text("Home").font(.system(size: 52, weight: .bold))
              .padding(.horizontal, TVDesign.pagePadding).padding(.top, 170)
          }
          if !model.watchParties.isEmpty { watchTogether }
          if model.supportsMovieNight { movieNightRow }
          // Same order as the Mac Home page.
          shelf("Continue Watching", items: home.continueWatching, section: .continueWatching)
          ForEach(home.becauseYouWatched ?? []) { rail in
            genreShelf(
              TVHomeGenreRow(
                genre: "Because You Watched \(rail.sourceTitle)", items: rail.suggestions.map(\.item)))
          }
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
          ProgressView().frame(maxWidth: .infinity).padding(.top, 200)
        }
        if let error = model.homeError {
          VStack(alignment: .leading, spacing: 20) {
            TVErrorText(message: error)
            Button("Try Again") { Task { await model.loadHome() } }.buttonStyle(TVButtonStyle())
          }.padding(.horizontal, TVDesign.pagePadding)
        }
      }.padding(.bottom, 80)
    }
    // The hero artwork reaches the top edge beneath the native tab bar.
    .ignoresSafeArea(edges: .top)
    .background(TVDesign.canvas.ignoresSafeArea())
    .task(id: model.session?.sessionId) {
      // Parties others start appear on Home within a few seconds.
      while !Task.isCancelled {
        await model.refreshWatchParties()
        if model.supportsMovieNight, let api = model.client {
          movieNights = (try? await api.movieNights()) ?? movieNights
        }
        try? await Task.sleep(for: .seconds(15))
      }
    }
    .task(id: model.libraryRefresh) {
      await model.loadHome()
      await model.preloadLibrary()
    }
    .modifier(TVLibraryActionPresentation(actions: actions))
    .navigationDestination(item: $detailItem) { value in
      TVDetailView(id: value.item.detailID, initial: value.item)
    }
    .fullScreenCover(
      item: $playback,
      onDismiss: {
        model.playerPresented = false
        Task { await model.loadHome() }
      },
      content: { request in
        if let connection = model.connection, let session = model.session {
          TVPlayerView(makeController: {
            TVPlaybackController(
              connection: connection, session: session, mediaID: request.target.id,
              title: request.title, outbox: model.environment.outbox,
              api: model.makeClient(connection: connection, session: session),
              runtime: model.environment.makePlaybackRuntime(),
              queue: request.queue,
              seriesID: request.target.kind == .episode ? request.target.parentId : nil,
              preferencesStore: model.environment.preferences,
              adaptiveStreaming: model.supportsAdaptiveStreaming,
              supportsSuggestions: model.supportsSuggestions,
              onClose: { playback = nil },
              onSessionFailure: { failure in
                guard model.session?.sessionId == session.sessionId else { return }
                model.handleSessionFailure(failure)
                playback = nil
              },
              startOver: request.startOver)
          })
        }
      }
    )
    .fullScreenCover(item: $movieNight) { launch in
      if let api = model.client {
        TVMovieNightView(api: api, deviceName: model.deviceName, joining: launch.joining) { mediaID in
          Task {
            // The match plays the way Home plays anything, once Movie Night has closed.
            try? await Task.sleep(for: .milliseconds(700))
            if let item = try? await model.client?.summary(id: mediaID) { play(item, viaPlan: true) }
          }
        }
        .environmentObject(model)
      }
    }
    .onChange(of: model.session?.sessionId) { _, _ in
      playback = nil
      movieNight = nil
    }
    .onChange(of: model.remoteStopRequests) { _, _ in playback = nil }
    .onChange(of: model.suggestedPlaybackItem) { _, item in
      guard let item else { return }
      model.suggestedPlaybackItem = nil
      Task {
        // The player closes first, so it saves its progress, then the suggestion plays.
        if model.playerPresented { model.stopPlayer() }
        for _ in 0..<20 where model.playerPresented {
          try? await Task.sleep(for: .milliseconds(100))
        }
        play(item, viaPlan: true)
      }
    }
    .onChange(of: model.remotePlaybackItem) { _, item in
      guard let item else { return }
      model.remotePlaybackItem = nil
      Task {
        // A player that is already open closes first, so it saves its progress.
        if model.playerPresented { model.stopPlayer() }
        for _ in 0..<20 where model.playerPresented {
          try? await Task.sleep(for: .milliseconds(100))
        }
        // The same way as choosing the title: playable check, resume target, next episode.
        play(item)
      }
    }
    .alert(
      "Not Available",
      isPresented: Binding(get: { unavailable != nil }, set: { if !$0 { unavailable = nil } }),
      presenting: unavailable
    ) { item in
      Button("Show Details") {
        detailItem = TVHomeDetail(item: item)
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
  /// `viaPlan` plays a show from its plan (Movie Night's match, a suggestion): a show itself is
  /// not playable; its plan picks the episode.
  private func play(_ item: TVCatalogItem, viaPlan: Bool = false) {
    // Offline titles stay reachable in Continue Watching; selecting one explains why. A show
    // from Movie Night is not playable itself; its plan picks the episode.
    guard item.isPlayable || (viaPlan && item.kind == .series) else {
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
          detailItem = TVHomeDetail(item: item)
          return
        }
        guard target.isPlayable else {
          unavailable = target
          return
        }
        let series = target.parentTitle ?? item.parentTitle
        let title = target.episodeLabel.map { "\(series ?? target.title) · \($0)" } ?? target.title
        model.playerPresented = true
        playback = TVHomePlayback(target: target, queue: plan.queue, title: title)
      } catch {
        guard model.session?.sessionId == sessionID else { return }
        actions.error = error.localizedDescription
        model.handleSessionFailure(error)
      }
    }
  }

  private func hero(_ home: TVHome) -> TVCatalogItem? {
    home.recommendation ?? home.continueWatching.first ?? home.recentlyAdded.first
  }

  @ViewBuilder
  private func shelf(_ title: String, items: [TVCatalogItem], section: TVBrowseSection)
    -> some View
  {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 26) {
        TVSectionHeader(title: title, count: items.count).padding(
          .horizontal, TVDesign.pagePadding)
        ScrollView(.horizontal) {
          LazyHStack(alignment: .top, spacing: 48) {
            ForEach(items) { original in
              let item = model.overlay(original)
              Group {
                if section == .continueWatching {
                  Button {
                    play(item)
                  } label: {
                    TVContinueCard(item: item)
                  }
                } else {
                  NavigationLink {
                    TVDetailView(id: item.detailID, initial: item)
                  } label: {
                    TVPosterLabel(item: item).frame(width: TVDesign.posterWidth)
                  }
                }
              }
              .buttonStyle(.borderless)
              .accessibilityIdentifier("home-\(section.rawValue)-\(item.id)")
              .contextMenu {
                if section == .continueWatching {
                  Button("Show Details") { detailItem = TVHomeDetail(item: item) }
                }
                TVMediaContextActions(
                  item: item, actions: actions, continuation: section == .continueWatching)
              }
            }
            if section != .continueWatching, items.count >= Self.shelfLimit {
              NavigationLink {
                TVBrowseDestination(section: section)
              } label: {
                TVShowAllTile()
              }.buttonStyle(.borderless).accessibilityIdentifier("home-all-\(section.rawValue)")
            }
          }.padding(.horizontal, TVDesign.pagePadding).padding(.vertical, 16)
        }.scrollIndicators(.hidden).scrollClipDisabled().focusSection()
      }
    }
  }

  private func genreShelf(_ row: TVHomeGenreRow) -> some View {
    VStack(alignment: .leading, spacing: 26) {
      TVSectionHeader(title: row.genre, count: row.items.count).padding(
        .horizontal, TVDesign.pagePadding)
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: 48) {
          ForEach(row.items) { original in
            let item = model.overlay(original)
            NavigationLink {
              TVDetailView(id: item.detailID, initial: item)
            } label: {
              TVPosterLabel(item: item).frame(width: TVDesign.posterWidth)
            }.buttonStyle(.borderless)
              .accessibilityIdentifier("home-genre-\(row.genre)-\(item.id)")
              .contextMenu { TVMediaContextActions(item: item, actions: actions) }
          }
        }.padding(.horizontal, TVDesign.pagePadding).padding(.vertical, 16)
      }.scrollIndicators(.hidden).scrollClipDisabled().focusSection()
    }
  }

  private func collections(_ values: [TVCollection]) -> some View {
    VStack(alignment: .leading, spacing: 26) {
      TVSectionHeader(title: "Collections", count: values.count).padding(
        .horizontal, TVDesign.pagePadding)
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: 48) {
          ForEach(values) { collection in
            NavigationLink {
              TVCollectionView(collection: collection)
            } label: {
              TVCollectionCard(collection: collection).frame(width: TVDesign.posterWidth)
            }.buttonStyle(.borderless).accessibilityIdentifier("collection-\(collection.id)")
          }
          if values.count >= Self.shelfLimit {
            NavigationLink {
              TVCollectionsView()
            } label: {
              TVShowAllTile()
            }.buttonStyle(.borderless).accessibilityIdentifier("home-all-collections")
          }
        }.padding(.horizontal, TVDesign.pagePadding).padding(.vertical, 16)
      }.scrollIndicators(.hidden).scrollClipDisabled().focusSection()
    }
  }
}

/// Full-bleed artwork with the Mac hero gradients and one primary action.
private struct TVHomeHero: View {
  let item: TVCatalogItem
  let launching: Bool
  let play: (TVCatalogItem) -> Void
  var body: some View {
    ZStack(alignment: .bottomLeading) {
      TVHeroBackdrop(artwork: item.backdrop ?? item.poster)
      VStack(alignment: .leading, spacing: 18) {
        TVEyebrow(
          text: (item.kind == .episode
            ? ["TV Show", item.episodeLabel] : [item.kindLabel, item.year.map(String.init)])
            .compactMap { $0 }.joined(separator: " · "))
        Text(item.parentTitle ?? item.title).font(.system(size: 72, weight: .bold))
          .tracking(-0.8).lineLimit(2)
        if !item.genres.isEmpty {
          Text(item.genres.prefix(3).joined(separator: " · ")).font(
            .system(size: 24, weight: .semibold))
        }
        if let overview = item.overview {
          Text(overview).font(.system(size: 26)).lineLimit(3).frame(
            maxWidth: 1000, alignment: .leading
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
              TVDetailView(id: item.detailID, initial: item)
            } label: {
              Label("Open", systemImage: "arrow.right")
            }
          }
        }.buttonStyle(TVButtonStyle(kind: .primary)).padding(.top, 10)
          .accessibilityIdentifier("home-hero")
      }.padding(.horizontal, TVDesign.pagePadding).padding(.bottom, 60).focusSection()
    }.frame(maxWidth: .infinity, minHeight: 760, alignment: .bottomLeading)
  }
}

/// Backdrop with the Mac's left-to-right and bottom fades into the canvas.
struct TVHeroBackdrop: View {
  let artwork: TVArtwork?
  var body: some View {
    TVArtworkView(artwork: artwork, width: 1920, symbol: nil)
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
            .init(color: TVDesign.canvas.opacity(0.4), location: 0.74),
            .init(color: TVDesign.canvas, location: 1),
          ], startPoint: .top, endPoint: .bottom)
      }
      .ignoresSafeArea()
      .accessibilityHidden(true)
  }
}

/// Landscape Continue Watching card with its text and progress inside the image.
struct TVContinueCard: View {
  let item: TVCatalogItem
  var body: some View {
    ZStack(alignment: .bottomLeading) {
      TVArtworkView(artwork: item.backdrop ?? item.poster, width: 1280, symbol: nil)
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0.35), .init(color: .black.opacity(0.25), location: 0.55),
          .init(color: .black.opacity(0.9), location: 1),
        ], startPoint: .top, endPoint: .bottom)
      VStack(alignment: .leading, spacing: 6) {
        TVEyebrow(text: "Continue Watching", size: 16)
        Text(item.parentTitle ?? item.title).font(.system(size: 26, weight: .bold)).lineLimit(1)
        Text(detail).font(.system(size: 20)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
        if let fraction = item.progressFraction {
          TVProgressBar(fraction: fraction).padding(.top, 8)
        }
      }.padding(20)
    }
    .frame(width: TVDesign.landscapeWidth, height: TVDesign.landscapeWidth * 9 / 16)
    .clipShape(RoundedRectangle(cornerRadius: TVDesign.cardRadius, style: .continuous))
    .hoverEffect(.highlight)
  }
  private var detail: String {
    if let message = item.availabilityMessage { return message }
    if let episode = item.episodeLabel { return "\(episode) · \(item.title)" }
    return item.year.map(String.init) ?? item.kindLabel
  }
}

struct TVCollectionCard: View {
  let collection: TVCollection
  private var previewArtwork: TVArtwork? {
    collection.poster ?? collection.backdrop ?? collection.items.lazy.compactMap(\.poster).first
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      ZStack(alignment: .top) {
        RoundedRectangle(cornerRadius: TVDesign.cardRadius, style: .continuous)
          .fill(Color.white.opacity(0.08))
          .padding(.horizontal, 18)
          .offset(y: -12)
        RoundedRectangle(cornerRadius: TVDesign.cardRadius, style: .continuous)
          .fill(Color.white.opacity(0.14))
          .padding(.horizontal, 9)
          .offset(y: -6)
        ZStack(alignment: .topLeading) {
          TVArtworkView(artwork: previewArtwork, width: 640, symbol: "rectangle.stack")
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay(alignment: .bottom) {
              if let fraction = collection.progressFraction, fraction < 1 {
                TVProgressBar(fraction: fraction).padding(.horizontal, 14).padding(.bottom, 14)
              }
            }
            .clipShape(RoundedRectangle(cornerRadius: TVDesign.cardRadius, style: .continuous))
            .hoverEffect(.highlight)
          if let badge = TVCollectionPresentation.providerLabel(for: collection) {
            Text(badge)
              .font(.system(size: 16, weight: .bold))
              .padding(.horizontal, 10)
              .padding(.vertical, 4)
              .background(.ultraThinMaterial, in: Capsule())
              .padding(12)
          }
        }
      }
      .padding(.top, 12)
      VStack(alignment: .leading, spacing: 6) {
        Text(collection.name).font(.system(size: 24, weight: .semibold)).lineLimit(1)
        Text(TVCollectionPresentation.cardSubtitle(collection))
          .font(.system(size: 20)).foregroundStyle(.secondary).lineLimit(1)
      }
    }
  }
}

/// A single end-of-shelf tile instead of header buttons on every row.
struct TVShowAllTile: View {
  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "chevron.right").font(.system(size: 34, weight: .semibold))
      Text("Show All").font(.system(size: 24, weight: .semibold))
    }
    .frame(width: TVDesign.posterWidth, height: TVDesign.posterWidth * 3 / 2)
    .background(TVDesign.surface, in: RoundedRectangle(cornerRadius: TVDesign.cardRadius))
    .hoverEffect(.highlight)
  }
}

struct TVCollectionsView: View {
  @EnvironmentObject private var model: TVAppModel
  @State private var collections: [TVCollection] = []
  @State private var franchises: [TVCollection] = []
  @State private var loading = false
  @State private var complete = false
  @State private var error: String?
  @State private var generation = UUID()
  @FocusState private var focused: UUID?
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 36) {
        TVSectionHeader(title: "Collections", count: collections.isEmpty ? nil : collections.count)
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 48), count: 6), spacing: 56
        ) {
          ForEach(collections) { collection in
            NavigationLink {
              TVCollectionView(collection: collection)
            } label: {
              TVCollectionCard(collection: collection)
            }.buttonStyle(.borderless).focused($focused, equals: collection.id).onAppear {
              if collection.id == collections.last?.id { Task { await next() } }
            }
          }
        }.defaultFocus($focused, collections.first?.id, priority: .userInitiated).focusSection()
        if !franchises.isEmpty {
          TVSectionHeader(title: "Universes", count: franchises.count).padding(.top, 12)
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 48), count: 6), spacing: 56
          ) {
            ForEach(franchises) { franchise in
              NavigationLink {
                TVCollectionView(collection: franchise)
              } label: {
                TVCollectionCard(collection: franchise)
              }.buttonStyle(.borderless).focused($focused, equals: franchise.id)
            }
          }.focusSection()
        }
        if loading { ProgressView() }
        if let error {
          TVErrorText(message: error)
          Button("Try Again") { Task { await next() } }.buttonStyle(TVButtonStyle())
        }
        if complete && collections.isEmpty && franchises.isEmpty {
          Text("No collections available.").foregroundStyle(.secondary)
        }
      }.padding(.horizontal, TVDesign.pagePadding).padding(.vertical, 40)
    }.background(TVDesign.canvas.ignoresSafeArea())
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
      if replacing {
        async let loadedCollections = api.collections(offset: 0)
        let loadedFranchises = (try? await api.franchises()) ?? []
        let values = try await loadedCollections
        guard !Task.isCancelled, generation == run, model.session?.sessionId == session else {
          return
        }
        collections = values
        franchises = loadedFranchises
        complete = values.count < 60
        error = nil
      } else {
        let values = try await api.collections(offset: collections.count)
        guard !Task.isCancelled, generation == run, model.session?.sessionId == session else {
          return
        }
        let old = Set(collections.map(\.id))
        collections += values.filter { !old.contains($0.id) }
        complete = values.count < 60
        error = nil
      }
    } catch {
      guard generation == run, model.session?.sessionId == session else { return }
      self.error = error.localizedDescription
      model.handleSessionFailure(error)
    }
  }
}

struct TVCollectionView: View {
  @EnvironmentObject private var model: TVAppModel
  let collection: TVCollection
  @StateObject private var actions = TVLibraryActions()
  @State private var detail: TVCollectionDetail?
  @State private var loading = false
  @State private var launching = false
  @State private var unavailable = false
  @State private var unavailableItem: TVCatalogItem?
  @State private var error: String?
  @State private var playback: TVHomePlayback?
  @State private var selectedSeasonMemberID: UUID?
  @State private var requestID = UUID()
  @FocusState private var focused: CollectionFocus?

  private enum CollectionFocus: Hashable {
    case play
    case member(UUID)
    case episode(UUID)
    case openShow(UUID)
  }

  private var resolvedDetail: TVCollectionDetail { detail ?? TVCollectionDetail(collection: collection) }
  private var members: [TVCollectionMember] { resolvedDetail.resolvedMembers }
  private var playableItems: [TVCatalogItem] { TVCollectionPresentation.playableItems(in: resolvedDetail) }
  private var selectedSeasonMember: TVCollectionMember? {
    members.first { $0.id == selectedSeasonMemberID && !($0.episodes ?? []).isEmpty }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 44) {
        if let detail {
          hero(detail)
          membersGrid(detail)
          if let seasonMember = selectedSeasonMember {
            seasonEpisodesShelf(seasonMember, in: detail)
          }
        } else {
          Text(collection.name)
            .font(.system(size: 52, weight: .bold))
            .padding(.horizontal, TVDesign.pagePadding)
            .padding(.top, 120)
        }
        if loading {
          ProgressView()
            .padding(.horizontal, TVDesign.pagePadding)
            .accessibilityIdentifier("collection-loading")
        }
        if unavailable {
          ContentUnavailableView("Collection Unavailable", systemImage: "rectangle.stack")
            .accessibilityIdentifier("collection-unavailable")
        }
        if let error {
          VStack(alignment: .leading, spacing: 20) {
            TVErrorText(message: error)
            Button("Try Again") { Task { await reload() } }.buttonStyle(TVButtonStyle())
          }
          .padding(.horizontal, TVDesign.pagePadding)
        }
      }
      .padding(.bottom, 80)
    }
    .ignoresSafeArea(edges: .top)
    .background(TVDesign.canvas.ignoresSafeArea())
    .defaultFocus($focused, defaultFocusTarget, priority: .userInitiated)
    .task(id: model.libraryRefresh) { await reload() }
    .onChange(of: model.session?.sessionId) { _, _ in playback = nil }
    .onChange(of: model.remoteStopRequests) { _, _ in playback = nil }
    .modifier(TVLibraryActionPresentation(actions: actions))
    .fullScreenCover(
      item: $playback,
      onDismiss: {
        model.playerPresented = false
        Task { await reload() }
      },
      content: { request in
        if let connection = model.connection, let session = model.session {
          TVPlayerView(makeController: {
            TVPlaybackController(
              connection: connection, session: session, mediaID: request.target.id,
              title: request.title, outbox: model.environment.outbox,
              api: model.makeClient(connection: connection, session: session),
              runtime: model.environment.makePlaybackRuntime(),
              queue: request.queue,
              seriesID: request.target.kind == .episode ? request.target.parentId : nil,
              preferencesStore: model.environment.preferences,
              adaptiveStreaming: model.supportsAdaptiveStreaming,
              supportsSuggestions: model.supportsSuggestions,
              onClose: { playback = nil },
              onSessionFailure: { failure in
                guard model.session?.sessionId == session.sessionId else { return }
                model.handleSessionFailure(failure)
                playback = nil
              },
              startOver: request.startOver)
          })
        }
      }
    )
    .alert(
      "Not Available",
      isPresented: Binding(get: { unavailableItem != nil }, set: { if !$0 { unavailableItem = nil } }),
      presenting: unavailableItem
    ) { _ in
      Button("OK", role: .cancel) { unavailableItem = nil }
    } message: { item in
      Text(
        "\(item.availabilityMessage ?? "This title can't be played right now.") Connect the drive on your Mac, then try again."
      )
    }
  }

  private var defaultFocusTarget: CollectionFocus? {
    if !playableItems.isEmpty { return .play }
    return members.first.map { .member($0.id) }
  }

  private func hero(_ detail: TVCollectionDetail) -> some View {
    let summary = detail.summary
    let firstItem = members.compactMap { $0.item ?? $0.episodes?.first }.first ?? detail.items.first
    let heroArtwork = detail.backdrop ?? detail.poster ?? firstItem?.backdrop ?? firstItem?.poster
    let coverArtwork = detail.poster ?? detail.backdrop ?? firstItem?.poster ?? firstItem?.backdrop
    return ZStack(alignment: .bottomLeading) {
      TVHeroBackdrop(artwork: heroArtwork)
      HStack(alignment: .bottom, spacing: 42) {
        TVArtworkView(artwork: coverArtwork, width: 640, symbol: "rectangle.stack")
          .frame(width: 210, height: 315)
          .clipShape(RoundedRectangle(cornerRadius: TVDesign.cardRadius, style: .continuous))
          .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
        VStack(alignment: .leading, spacing: 16) {
          TVEyebrow(
            text: [
              TVCollectionPresentation.providerLabel(for: summary) ?? "Collection",
              detail.yearRange,
            ].compactMap { $0 }.joined(separator: " · "))
          Text(detail.name)
            .font(.system(size: 68, weight: .bold))
            .tracking(-0.8)
            .lineLimit(2)
          if let genres = detail.genres, !genres.isEmpty {
            Text(genres.prefix(4).joined(separator: " · "))
              .font(.system(size: 24, weight: .semibold))
          }
          if let stats = TVCollectionPresentation.statsLine(detail) {
            Text(stats)
              .font(.system(size: 22, weight: .semibold))
              .foregroundStyle(.white.opacity(0.8))
          }
          if let fraction = summary.progressFraction, fraction < 1 {
            TVProgressBar(fraction: fraction).frame(maxWidth: 420)
          }
          if let overview = TVCollectionPresentation.cleanedOverview(detail.overview) {
            Text(overview)
              .font(.system(size: 25))
              .lineLimit(3)
              .frame(maxWidth: 1020, alignment: .leading)
              .foregroundStyle(.white.opacity(0.88))
          }
          if !playableItems.isEmpty {
            HStack(spacing: 22) {
              Button {
                playBoxSet(detail)
              } label: {
                Label(TVCollectionPresentation.playLabel(for: detail), systemImage: "play.fill")
              }
              .buttonStyle(TVButtonStyle(kind: .primary))
              .disabled(launching)
              .focused($focused, equals: .play)
              .accessibilityIdentifier("collection-play")
            }
            .padding(.top, 6)
          }
        }
      }
      .padding(.horizontal, TVDesign.pagePadding)
      .padding(.bottom, 54)
      .focusSection()
    }
    .frame(maxWidth: .infinity, minHeight: 620, alignment: .bottomLeading)
  }

  @ViewBuilder
  private func membersGrid(_ detail: TVCollectionDetail) -> some View {
    VStack(alignment: .leading, spacing: 26) {
      TVSectionHeader(
        title: "Titles", count: members.isEmpty ? nil : members.count
      )
      .padding(.horizontal, TVDesign.pagePadding)
      if members.isEmpty {
        ContentUnavailableView("No Titles Available", systemImage: "rectangle.stack")
          .padding(.horizontal, TVDesign.pagePadding)
      } else {
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 48), count: 6), spacing: 56
        ) {
          ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
            memberCard(member, index: index)
          }
        }
        .padding(.horizontal, TVDesign.pagePadding)
        .focusSection()
      }
    }
  }

  @ViewBuilder
  private func memberCard(_ member: TVCollectionMember, index: Int) -> some View {
    let rawItem = member.item.map { model.overlay($0) }
    let firstEpisode = member.episodes?.first.map { model.overlay($0) }
    if member.kind == .series, member.seasonNumber != nil, !(member.episodes ?? []).isEmpty {
      let isSelected = selectedSeasonMemberID == member.id
      Button {
        selectedSeasonMemberID = member.id
      } label: {
        memberCardLabel(
          member: member, index: index, item: rawItem, fallback: firstEpisode, selected: isSelected)
      }
      .buttonStyle(.borderless)
      .focused($focused, equals: .member(member.id))
      .accessibilityIdentifier("collection-item-\(member.mediaId)")
    } else if let target = rawItem ?? firstEpisode {
      NavigationLink {
        TVDetailView(
          id: target.detailID, initial: target,
          selectedEpisodeID: member.kind == .episode ? target.id : nil)
      } label: {
        memberCardLabel(member: member, index: index, item: rawItem, fallback: firstEpisode)
      }
      .buttonStyle(.borderless)
      .focused($focused, equals: .member(member.id))
      .accessibilityIdentifier("collection-item-\(member.mediaId)")
      .contextMenu { TVMediaContextActions(item: target, actions: actions) }
    }
  }

  private func memberCardLabel(
    member: TVCollectionMember, index: Int, item: TVCatalogItem?, fallback: TVCatalogItem?,
    selected: Bool = false
  ) -> some View {
    let artwork = item?.poster ?? fallback?.poster ?? fallback?.backdrop
    let fraction: Double? = {
      if let f = item?.progressFraction { return f }
      if let wc = member.watchedCount, let ic = member.itemCount, ic > 1, wc > 0, wc < ic {
        return Double(wc) / Double(ic)
      }
      return nil
    }()
    return VStack(alignment: .leading, spacing: 14) {
      TVArtworkView(artwork: artwork, width: 640, symbol: member.kind == .movie ? "film" : "tv")
        .aspectRatio(2 / 3, contentMode: .fit)
        .overlay(alignment: .topTrailing) {
          if let item { TVItemBadges(item: item).padding(10) }
        }
        .overlay(alignment: .bottom) {
          if let fraction { TVProgressBar(fraction: fraction).padding(.horizontal, 14).padding(.bottom, 14) }
        }
        .overlay {
          if selected {
            RoundedRectangle(cornerRadius: TVDesign.cardRadius, style: .continuous)
              .stroke(Color.white.opacity(0.9), lineWidth: 3)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: TVDesign.cardRadius, style: .continuous))
        .hoverEffect(.highlight)
      VStack(alignment: .leading, spacing: 4) {
        Text("\(index + 1). \(member.displayTitle)")
          .font(.system(size: 24, weight: .semibold))
          .lineLimit(2)
        if let subtitle = memberSubtitle(member, item: item) {
          Text(subtitle).font(.system(size: 20)).foregroundStyle(.secondary).lineLimit(1)
        }
      }
    }
  }

  private func memberSubtitle(_ member: TVCollectionMember, item: TVCatalogItem?) -> String? {
    var parts: [String] = []
    if member.kind == .episode, let label = item?.episodeLabel {
      parts.append(label)
    } else if let year = item?.year {
      parts.append(String(year))
    }
    if let wc = member.watchedCount, let ic = member.itemCount, ic > 1 {
      parts.append("\(wc) of \(ic) watched")
    } else if (member.watchedCount ?? 0) > 0 {
      parts.append("Watched")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func seasonEpisodesShelf(_ member: TVCollectionMember, in detail: TVCollectionDetail)
    -> some View
  {
    let episodes = (member.episodes ?? []).map { model.overlay($0) }
    return VStack(alignment: .leading, spacing: 24) {
      HStack(spacing: 24) {
        TVSectionHeader(title: member.displayTitle, count: episodes.count)
        if let show = member.item {
          NavigationLink {
            TVDetailView(id: show.detailID, initial: show)
          } label: {
            Label("Open Show", systemImage: "tv")
          }
          .buttonStyle(TVButtonStyle())
          .focused($focused, equals: .openShow(member.id))
        }
      }
      .padding(.horizontal, TVDesign.pagePadding)
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: 44) {
          ForEach(episodes) { episode in
            Button {
              playEpisode(episode, in: detail)
            } label: {
              TVCollectionEpisodeCard(episode: episode)
            }
            .buttonStyle(.borderless)
            .disabled(launching)
            .focused($focused, equals: .episode(episode.id))
            .contextMenu { TVMediaContextActions(item: episode, actions: actions) }
          }
        }
        .padding(.horizontal, TVDesign.pagePadding)
        .padding(.vertical, 16)
      }
      .scrollIndicators(.hidden)
      .scrollClipDisabled()
      .focusSection()
    }
  }

  private func playBoxSet(_ detail: TVCollectionDetail) {
    guard !launching, playback == nil, let api = model.client else { return }
    launching = true
    let sessionID = model.session?.sessionId
    Task {
      defer { launching = false }
      let next = try? await api.collectionNext(id: detail.id)
      guard !Task.isCancelled, model.session?.sessionId == sessionID, playback == nil else { return }
      let fallback = TVCollectionPresentation.playableItems(in: detail).first
      guard let rawTarget = next?.item ?? fallback else { return }
      let target = model.overlay(rawTarget)
      guard target.isPlayable else {
        unavailableItem = target
        return
      }
      let queue = TVCollectionPresentation.playbackQueue(in: detail, startingAt: target.id)
      let startOver = next.map { !$0.resume } ?? false
      launchPlayback(target: target, queue: queue, startOver: startOver, fallbackTitle: detail.name)
    }
  }

  private func playEpisode(_ episode: TVCatalogItem, in detail: TVCollectionDetail) {
    guard episode.isPlayable else {
      unavailableItem = episode
      return
    }
    guard playback == nil else { return }
    let queue = TVCollectionPresentation.playbackQueue(in: detail, startingAt: episode.id)
    launchPlayback(target: episode, queue: queue, startOver: false, fallbackTitle: detail.name)
  }

  private func launchPlayback(
    target: TVCatalogItem, queue: [TVCatalogItem], startOver: Bool, fallbackTitle: String
  ) {
    let title: String = {
      if let label = target.episodeLabel {
        return "\(target.parentTitle ?? fallbackTitle) · \(label)"
      }
      return target.title
    }()
    model.playerPresented = true
    playback = TVHomePlayback(target: target, queue: queue, title: title, startOver: startOver)
  }

  private func reload() async {
    guard let api = model.client, let sessionID = model.session?.sessionId else { return }
    let request = UUID()
    requestID = request
    loading = detail == nil
    unavailable = false
    error = nil
    defer {
      if requestID == request, model.session?.sessionId == sessionID { loading = false }
    }
    if var loaded = try? await api.collectionDetail(id: collection.id) {
      guard !Task.isCancelled, requestID == request, model.session?.sessionId == sessionID else {
        return
      }
      for item in loaded.items { model.updateSummary(item) }
      for member in loaded.resolvedMembers {
        if let item = member.item { model.updateSummary(item) }
        for episode in member.episodes ?? [] { model.updateSummary(episode) }
      }
      if loaded.nextItem == nil, model.supportsCollectionsV3 {
        loaded.nextItem = try? await api.collectionNext(id: collection.id)
      }
      guard !Task.isCancelled, requestID == request, model.session?.sessionId == sessionID else {
        return
      }
      detail = loaded
      if selectedSeasonMemberID == nil {
        selectedSeasonMemberID = loaded.resolvedMembers.first { !($0.episodes ?? []).isEmpty }?.id
      }
      return
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
          detail = TVCollectionDetail(collection: value)
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

private struct TVCollectionEpisodeCard: View {
  let episode: TVCatalogItem
  private let width: CGFloat = 420
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      TVArtworkView(artwork: episode.backdrop ?? episode.poster, width: 1280, symbol: "play.rectangle")
        .frame(width: width, height: width * 9 / 16)
        .overlay(alignment: .topTrailing) { TVItemBadges(item: episode).padding(10) }
        .overlay(alignment: .bottom) {
          if let fraction = episode.progressFraction {
            TVProgressBar(fraction: fraction).padding(.horizontal, 14).padding(.bottom, 14)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: TVDesign.cardRadius, style: .continuous))
        .hoverEffect(.highlight)
      Text("\(episode.episodeLabel ?? "Episode") · \(episode.title)")
        .font(.system(size: 23, weight: .semibold))
        .lineLimit(2)
      if let message = episode.availabilityMessage {
        Text(message).font(.system(size: 19, weight: .semibold)).foregroundStyle(.orange)
      } else if let overview = episode.overview {
        Text(overview).font(.system(size: 19)).foregroundStyle(.secondary).lineLimit(2)
      }
    }
    .frame(width: width, alignment: .leading)
    .opacity(episode.isPlayable ? 1 : 0.55)
  }
}

private struct TVHomeDetail: Hashable {
  let item: TVCatalogItem
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.item.id == rhs.item.id }
  func hash(into hasher: inout Hasher) { hasher.combine(item.id) }
}

private struct TVHomePlayback: Identifiable {
  let target: TVCatalogItem
  let queue: [TVCatalogItem]
  let title: String
  var startOver: Bool = false
  var id: UUID { target.id }
}

/// Opens Movie Night: a new night, or the one to show.
struct TVMovieNightLaunch: Identifiable {
  let id = UUID()
  let joining: TVMovieNightSummary?
}
