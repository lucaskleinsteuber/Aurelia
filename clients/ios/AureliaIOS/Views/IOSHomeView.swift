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
  @State private var movieNight: IOSMovieNightLaunch?
  @State private var movieNights: [IOSMovieNightSummary] = []
  @State private var monthlyWrapped: IOSWrappedLaunch?
  /// The server returns at most this many items in Home's catalog shelves.
  private static let shelfLimit = 30

  /// Parties others started at home, to join with one tap.
  private var watchTogether: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Watch Together").font(.title2.bold())
      ForEach(model.watchParties) { party in
        Button {
          Task { await model.joinWatchTogether(party) }
        } label: {
          Label("Join \(party.hostName) · \(party.title)", systemImage: "person.2.fill")
        }
        .buttonStyle(IOSButtonStyle(kind: .secondary, fullWidth: true))
        .accessibilityIdentifier("home-watch-together")
      }
    }.padding(.horizontal, IOSDesign.margin)
  }

  /// Starts a Movie Night, or joins one someone else started.
  private var movieNightStrip: some View {
    let open = movieNights.first
    return Button {
      movieNight = IOSMovieNightLaunch(joining: open)
    } label: {
      HStack(spacing: 14) {
        ZStack {
          RoundedRectangle(cornerRadius: 5).fill(Color(red: 1, green: 0.30, blue: 0.35))
            .frame(width: 22, height: 32).rotationEffect(.degrees(-12)).offset(x: -10)
          RoundedRectangle(cornerRadius: 5).fill(IOSDesign.raised).frame(width: 22, height: 32)
          RoundedRectangle(cornerRadius: 5).fill(Color(red: 1, green: 0.79, blue: 0.24))
            .frame(width: 22, height: 32).rotationEffect(.degrees(12)).offset(x: 10)
        }
        .frame(width: 46, height: 40)
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(open.map { "\($0.hostName)'s Movie Night is on" } ?? "Can't decide what to watch?")
            .font(.body.weight(.semibold))
          Text(open == nil ? "Start a Movie Night and let everyone swipe." : "Join and start swiping.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right").foregroundStyle(.secondary)
      }
      .padding(14)
      .background(IOSDesign.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .padding(.horizontal, IOSDesign.margin)
    .accessibilityIdentifier("home-movie-night")
  }

  private var familyWishesStrip: some View {
    let badge = model.wishBadgeCount
    return NavigationLink {
      IOSWishesView()
    } label: {
      HStack(spacing: 14) {
        ZStack {
          RoundedRectangle(cornerRadius: 10, style: .continuous).fill(IOSDesign.raised)
            .frame(width: 44, height: 40)
          Image(systemName: "sparkles").font(.headline).foregroundStyle(.white)
        }
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text("Family Wishes").font(.body.weight(.semibold))
          Text(
            badge > 0
              ? (model.isWishAdmin
                ? "\(badge) open or awaiting review"
                : "\(badge) new update\(badge == 1 ? "" : "s")")
              : "Request a movie or TV show."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if badge > 0 {
          Text("\(badge)")
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white, in: Capsule())
        }
        Image(systemName: "chevron.right").foregroundStyle(.secondary)
      }
      .padding(14)
      .background(IOSDesign.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .padding(.horizontal, IOSDesign.margin)
    .accessibilityIdentifier("home-wishes")
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        if let home = model.home {
          if let hero = hero(home) {
            IOSHomeHero(item: model.overlay(hero), launching: launching) { play($0) }
          } else {
            Text("Home").font(.largeTitle.bold())
              .padding(.horizontal, IOSDesign.margin).padding(.top, 60)
          }
          if !model.watchParties.isEmpty { watchTogether }
          if model.supportsMonthlyWrapped, IOSWrapped.monthIsNew() {
            IOSMonthlyWrappedButton { monthlyWrapped = $0 }.padding(.horizontal, IOSDesign.margin)
          }
          if model.supportsMovieNight { movieNightStrip }
          if model.supportsWishes { familyWishesStrip }
          // Same order as the Mac Home page.
          shelf("Continue Watching", items: home.continueWatching, section: .continueWatching)
          ForEach(home.becauseYouWatched ?? []) { rail in
            genreShelf(
              IOSHomeGenreRow(
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
            ContentUnavailableView(
              "Your Library Is Empty", systemImage: "film",
              description: Text("Add a storage location in Aurelia on your Mac."))
          }
        }
        if model.homeLoading && model.home == nil {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 160)
        }
        if let error = model.homeError {
          VStack(spacing: 12) {
            IOSErrorText(message: error)
            Button("Try Again") { Task { await model.loadHome() } }.buttonStyle(IOSButtonStyle())
          }
          .frame(maxWidth: .infinity)
          .padding(.horizontal, IOSDesign.margin).padding(.top, model.home == nil ? 120 : 0)
        }
      }.padding(.bottom, 32)
    }
    // The hero artwork reaches the top edge, under the status bar.
    .ignoresSafeArea(edges: .top)
    .toolbar(.hidden, for: .navigationBar)
    .background(IOSDesign.canvas.ignoresSafeArea())
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
      #if DEBUG
        if IOSShowcasePage.current == "detail", detailItem == nil, let home = model.home,
          let featured = hero(home)
        {
          detailItem = IOSHomeDetail(item: featured)
        }
      #endif
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
              adaptiveStreaming: model.supportsAdaptiveStreaming,
              supportsSuggestions: model.supportsSuggestions,
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
    .fullScreenCover(item: $monthlyWrapped) { launch in
      IOSWrappedView(launch: launch).environmentObject(model)
    }
    .fullScreenCover(item: $movieNight) { launch in
      if let api = model.client {
        IOSMovieNightView(api: api, deviceName: model.deviceName, joining: launch.joining) { mediaID in
          Task {
            // The match plays the way Home plays anything, once Movie Night has closed: the plan
            // picks the episode for a show.
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
  /// `viaPlan` plays a show from its plan (Movie Night's match, a suggestion): a show itself is
  /// not playable; its plan picks the episode.
  private func play(_ item: IOSCatalogItem, viaPlan: Bool = false) {
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
      VStack(alignment: .leading, spacing: 10) {
        if section != .continueWatching, items.count >= Self.shelfLimit {
          IOSSectionHeader(
            title: title, count: nil, destination: IOSBrowseDestination(section: section))
        } else {
          IOSSectionHeader(title: title)
        }
        IOSShelf {
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
            .buttonStyle(IOSContentButtonStyle())
            .accessibilityIdentifier("home-\(section.rawValue)-\(item.id)")
            .contextMenu {
              if section == .continueWatching {
                Button("Show Details", systemImage: "info.circle") {
                  detailItem = IOSHomeDetail(item: item)
                }
              }
              IOSMediaContextActions(
                item: item, actions: actions, continuation: section == .continueWatching)
            }
          }
        }
      }
    }
  }

  private func genreShelf(_ row: IOSHomeGenreRow) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      IOSSectionHeader(title: row.genre)
      IOSShelf {
        ForEach(row.items) { original in
          let item = model.overlay(original)
          NavigationLink {
            IOSDetailView(id: item.detailID, initial: item)
          } label: {
            IOSPosterLabel(item: item).frame(width: IOSDesign.posterWidth)
          }.buttonStyle(IOSContentButtonStyle())
            .accessibilityIdentifier("home-genre-\(row.genre)-\(item.id)")
            .contextMenu { IOSMediaContextActions(item: item, actions: actions) }
        }
      }
    }
  }

  private func collections(_ values: [IOSCollection]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      IOSSectionHeader(title: "Collections", count: nil, destination: IOSCollectionsView())
      IOSShelf {
        ForEach(values) { collection in
          NavigationLink {
            IOSCollectionView(collection: collection)
          } label: {
            IOSCollectionCard(collection: collection).frame(width: IOSDesign.posterWidth)
          }.buttonStyle(IOSContentButtonStyle()).accessibilityIdentifier(
            "collection-\(collection.id)")
        }
      }
    }
  }
}

/// The featured title across the top: its artwork to the screen edges, fading into the page,
/// with the title and one main action, like the Apple TV app on iPhone.
private struct IOSHomeHero: View {
  let item: IOSCatalogItem
  let launching: Bool
  let play: (IOSCatalogItem) -> Void

  var body: some View {
    ZStack(alignment: .bottom) {
      IOSHeroBackdrop(artwork: item.backdrop ?? item.poster)
      VStack(spacing: 10) {
        IOSEyebrow(text: eyebrow)
        Text(item.parentTitle ?? item.title).font(.system(.largeTitle, weight: .bold))
          .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
        if !item.genres.isEmpty {
          Text(item.genres.prefix(3).joined(separator: " · ")).font(.subheadline)
            .foregroundStyle(.white.opacity(0.75))
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
              Label("Details", systemImage: "info.circle")
            }
          }
        }
        .buttonStyle(IOSButtonStyle(kind: .primary)).frame(minWidth: 180).padding(.top, 6)
        .accessibilityIdentifier("home-hero")
      }
      .padding(.horizontal, IOSDesign.margin).padding(.bottom, 8)
    }
    .frame(maxWidth: .infinity)
  }

  private var eyebrow: String {
    (item.kind == .episode
      ? ["TV Show", item.episodeLabel] : [item.kindLabel, item.year.map(String.init)])
      .compactMap { $0 }.joined(separator: " · ")
  }
}

/// Wide artwork that fills the top of a page and fades into the canvas below.
struct IOSHeroBackdrop: View {
  let artwork: IOSArtwork?
  var body: some View {
    GeometryReader { geometry in
      IOSArtworkView(artwork: artwork, width: 1280, symbol: nil)
        .frame(width: geometry.size.width, height: geometry.size.height)
        .overlay {
          LinearGradient(
            stops: [
              .init(color: .black.opacity(0.35), location: 0),
              .init(color: .clear, location: 0.25),
              .init(color: .clear, location: 0.45),
              .init(color: IOSDesign.canvas.opacity(0.75), location: 0.78),
              .init(color: IOSDesign.canvas, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
    }
    .frame(height: IOSDesign.isPad ? 560 : 470)
    .accessibilityHidden(true)
  }
}

/// A wide Continue Watching card: artwork with progress, the title and what comes next below.
struct IOSContinueCard: View {
  let item: IOSCatalogItem
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      IOSArtworkView(artwork: item.backdrop ?? item.poster, width: 640, symbol: "play.rectangle")
        .frame(width: IOSDesign.landscapeWidth, height: IOSDesign.landscapeWidth * 9 / 16)
        .overlay(alignment: .bottomLeading) {
          if let fraction = item.progressFraction {
            IOSProgressBar(fraction: fraction).padding(.horizontal, 10).padding(.bottom, 10)
          }
        }
        .overlay(alignment: .center) {
          Image(systemName: "play.fill").font(.title3).foregroundStyle(.white)
            .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
        }
        .clipShape(RoundedRectangle(cornerRadius: IOSDesign.cardRadius, style: .continuous))
      Text(item.parentTitle ?? item.title).font(.footnote.weight(.semibold)).lineLimit(1)
      Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
    .frame(width: IOSDesign.landscapeWidth, alignment: .leading)
  }
  private var detail: String {
    if let message = item.availabilityMessage { return message }
    if let episode = item.episodeLabel { return "\(episode) · \(item.title)" }
    return item.year.map(String.init) ?? item.kindLabel
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

/// Opens Movie Night: a new night, or the one to join.
struct IOSMovieNightLaunch: Identifiable {
  let id = UUID()
  let joining: IOSMovieNightSummary?
}
