import SwiftUI

/// Home follows the Mac layout: a full-bleed hero, then quiet section headers and
/// horizontal shelves. Focus moves only through the native focus engine.
struct TVHomeView: View {
  @EnvironmentObject private var model: TVAppModel
  @StateObject private var actions = TVLibraryActions()
  /// The server returns at most this many items in Home's catalog shelves.
  private static let shelfLimit = 30

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 54) {
        if let home = model.home {
          if let hero = hero(home) {
            TVHomeHero(item: model.overlay(hero))
          } else {
            Text("Home").font(.system(size: 52, weight: .bold))
              .padding(.horizontal, TVDesign.pagePadding).padding(.top, 170)
          }
          shelf("Continue Watching", items: home.continueWatching, section: .continueWatching)
          shelf("Favorites", items: home.favorites, section: .favorites)
          shelf("Recently Added", items: home.recentlyAdded, section: .recentlyAdded)
          if !home.collections.isEmpty { collections(home.collections) }
          if home.continueWatching.isEmpty && home.favorites.isEmpty && home.recentlyAdded.isEmpty {
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
    .task(id: model.libraryRefresh) { await model.loadHome() }
    .modifier(TVLibraryActionPresentation(actions: actions))
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
              NavigationLink {
                TVDetailView(id: item.detailID, initial: item)
              } label: {
                if section == .continueWatching {
                  TVContinueCard(item: item)
                } else {
                  TVPosterLabel(item: item).frame(width: TVDesign.posterWidth)
                }
              }
              .buttonStyle(.borderless)
              .accessibilityIdentifier("home-\(section.rawValue)-\(item.id)")
              .contextMenu {
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
        NavigationLink {
          TVDetailView(id: item.detailID, initial: item)
        } label: {
          Label(item.progressFraction == nil ? "Open" : "Continue", systemImage: "arrow.right")
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
      TVArtworkView(artwork: item.backdrop ?? item.poster, width: 960, symbol: "play.rectangle")
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
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      TVArtworkView(artwork: collection.poster, width: 640, symbol: "rectangle.stack")
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: TVDesign.cardRadius, style: .continuous))
        .hoverEffect(.highlight)
      VStack(alignment: .leading, spacing: 6) {
        Text(collection.name).font(.system(size: 24, weight: .semibold)).lineLimit(1)
        Text(collection.items.count == 1 ? "1 title" : "\(collection.items.count) titles")
          .font(.system(size: 20)).foregroundStyle(.secondary)
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
  @State private var loading = false
  @State private var complete = false
  @State private var error: String?
  @State private var generation = UUID()
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        TVSectionHeader(title: "Collections", count: collections.isEmpty ? nil : collections.count)
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 48), count: 6), spacing: 56
        ) {
          ForEach(collections) { collection in
            NavigationLink {
              TVCollectionView(collection: collection)
            } label: {
              TVCollectionCard(collection: collection)
            }.buttonStyle(.borderless).onAppear {
              if collection.id == collections.last?.id { Task { await next() } }
            }
          }
        }.focusSection()
        if loading { ProgressView() }
        if let error {
          TVErrorText(message: error)
          Button("Try Again") { Task { await next() } }.buttonStyle(TVButtonStyle())
        }
        if complete && collections.isEmpty {
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

struct TVCollectionView: View {
  @EnvironmentObject private var model: TVAppModel
  let collection: TVCollection
  @StateObject private var actions = TVLibraryActions()
  @State private var current: TVCollection?
  @State private var loading = false
  @State private var unavailable = false
  @State private var error: String?
  @State private var requestID = UUID()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 32) {
        TVSectionHeader(title: current?.name ?? "Collection", count: current?.items.count)
        if let current {
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 48), count: 6), spacing: 56
          ) {
            ForEach(current.items) { original in
              let item = model.overlay(original)
              NavigationLink {
                TVDetailView(id: item.detailID, initial: item)
              } label: {
                TVPosterLabel(item: item)
              }
              .buttonStyle(.borderless).accessibilityIdentifier("collection-item-\(item.id)")
              .contextMenu { TVMediaContextActions(item: item, actions: actions) }
            }
          }.focusSection()
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
          TVErrorText(message: error)
          Button("Try Again") { Task { await reload() } }.buttonStyle(TVButtonStyle())
        }
      }.padding(.horizontal, TVDesign.pagePadding).padding(.vertical, 40)
    }.background(TVDesign.canvas.ignoresSafeArea())
      .task(id: model.libraryRefresh) { await reload() }
      .modifier(TVLibraryActionPresentation(actions: actions))
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
