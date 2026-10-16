import SwiftUI

struct TVHomeView: View {
  @EnvironmentObject private var model: TVAppModel
  @StateObject private var actions = TVLibraryActions()
  private enum Focus: Hashable {
    case title(TVBrowseSection, UUID)
    case collection(UUID)
    case all(TVBrowseSection)
    case allCollections
  }
  @FocusState private var focused: Focus?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 44) {
        Text("Aurelia").font(.system(size: 46, weight: .bold))
        if let home = model.home {
          row(
            "Continue Watching", items: home.continueWatching, section: .continueWatching,
            landscape: true)
          row("Favorites", items: home.favorites, section: .favorites)
          row("Recently Added", items: home.recentlyAdded, section: .recentlyAdded)
          if !home.collections.isEmpty {
            VStack(alignment: .leading, spacing: 22) {
              HStack {
                Text("Collections").font(.system(size: 34, weight: .bold))
                Spacer()
                NavigationLink("See All") { TVCollectionsView() }.buttonStyle(TVButtonStyle())
                  .accessibilityIdentifier("home-all-collections")
                  .focused($focused, equals: .allCollections)
                  .onMoveCommand { direction in
                    if direction == .down, let first = home.collections.first {
                      focused = .collection(first.id)
                    }
                  }
              }
              ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 30) {
                  ForEach(home.collections) { collection in
                    NavigationLink {
                      TVCollectionView(collection: collection)
                    } label: {
                      VStack(alignment: .leading, spacing: 14) {
                        TVArtworkView(
                          artwork: collection.poster, width: 640, symbol: "rectangle.stack"
                        ).frame(width: 250, height: 360).clipShape(
                          RoundedRectangle(cornerRadius: 14)
                        )
                        .overlay(
                          RoundedRectangle(cornerRadius: 14).stroke(
                            .white.opacity(focused == .collection(collection.id) ? 0.9 : 0),
                            lineWidth: 2))
                        Text(collection.name).font(.system(size: 27, weight: .semibold)).lineLimit(
                          2
                        ).frame(width: 250, alignment: .leading)
                      }.padding(8)
                    }.buttonStyle(TVContentButtonStyle()).focusEffectDisabled().focused(
                      $focused, equals: .collection(collection.id)
                    ).accessibilityIdentifier("collection-\(collection.id)")
                      .onMoveCommand { if $0 == .up { focused = .allCollections } }
                  }
                }.padding(8)
              }.focusSection()
            }
          }
          if home.continueWatching.isEmpty && home.favorites.isEmpty && home.recentlyAdded.isEmpty {
            ContentUnavailableView("Your Library Is Empty", systemImage: "film")
          }
        }
        if model.homeLoading && model.home == nil { ProgressView().frame(maxWidth: .infinity) }
        if let error = model.homeError {
          TVErrorText(message: error)
          Button("Try Again") { Task { await model.loadHome() } }.buttonStyle(TVButtonStyle())
        }
      }.padding(.horizontal, 64).padding(.vertical, 40)
    }.background(TVDesign.canvas.ignoresSafeArea())
      .task(id: model.libraryRefresh) { await model.loadHome() }
      .modifier(TVLibraryActionPresentation(actions: actions))
  }

  @ViewBuilder
  private func row(
    _ title: String, items: [TVCatalogItem], section: TVBrowseSection, landscape: Bool = false
  ) -> some View {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 22) {
        HStack {
          Text(title).font(.system(size: 34, weight: .bold))
          Spacer()
          NavigationLink("See All") { TVBrowseDestination(section: section) }.buttonStyle(
            TVButtonStyle()
          ).accessibilityIdentifier("home-all-\(section.rawValue)")
            .focused($focused, equals: .all(section))
            .onMoveCommand {
              if $0 == .down, let first = items.first { focused = .title(section, first.id) }
            }
        }
        ScrollView(.horizontal) {
          LazyHStack(alignment: .top, spacing: 30) {
            ForEach(items) { original in
              let item = model.overlay(original)
              NavigationLink {
                TVDetailView(id: item.detailID, initial: item)
              } label: {
                if landscape {
                  TVContinueLabel(item: item, focused: focused == .title(section, item.id))
                } else {
                  TVPosterLabel(item: item, isFocused: focused == .title(section, item.id)).frame(
                    width: 250)
                }
              }.buttonStyle(TVContentButtonStyle()).focusEffectDisabled().focused(
                $focused, equals: .title(section, item.id)
              ).accessibilityIdentifier("home-\(section.rawValue)-\(item.id)")
                .onMoveCommand { if $0 == .up { focused = .all(section) } }
                .contextMenu {
                  TVMediaContextActions(
                    item: item, actions: actions, continuation: section == .continueWatching)
                }
            }
          }.padding(8)
        }.focusSection()
      }
    }
  }
}

private struct TVContinueLabel: View {
  let item: TVCatalogItem
  let focused: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      TVArtworkView(artwork: item.backdrop ?? item.poster, width: 640, symbol: "play.rectangle")
        .frame(width: 430, height: 242).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
          RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(focused ? 0.9 : 0), lineWidth: 2)
        )
      Text(item.parentTitle ?? item.title).font(.system(size: 28, weight: .semibold)).lineLimit(1)
      if let episode = item.episodeLabel {
        Text("\(episode) · \(item.title)").font(.system(size: 22)).foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if let progress = item.progress, progress.durationMilliseconds > 0 {
        ProgressView(
          value: min(
            1, Double(progress.positionMilliseconds) / Double(progress.durationMilliseconds))
        ).tint(.white)
      }
      if let message = item.availabilityMessage {
        Text(message).font(.system(size: 20)).foregroundStyle(.secondary)
      }
    }.frame(width: 430, alignment: .leading).padding(6).scaleEffect(focused ? 1.025 : 1)
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
        Text("Collections").font(.system(size: 46, weight: .bold))
        ForEach(collections) { collection in
          NavigationLink {
            TVCollectionView(collection: collection)
          } label: {
            HStack(spacing: 24) {
              TVArtworkView(artwork: collection.poster, width: 320, symbol: "rectangle.stack")
                .frame(width: 100, height: 145).clipShape(RoundedRectangle(cornerRadius: 10))
              Text(collection.name).font(.title3)
              Spacer()
              Text("\(collection.items.count)").foregroundStyle(.secondary)
            }.padding(16)
          }.buttonStyle(TVButtonStyle(kind: .row)).onAppear {
            if collection.id == collections.last?.id { Task { await next() } }
          }
        }
        if loading { ProgressView() }
        if let error {
          TVErrorText(message: error)
          Button("Try Again") { Task { await next() } }
        }
        if complete && collections.isEmpty {
          Text("No collections available.").foregroundStyle(.secondary)
        }
      }.padding(64)
    }.background(TVDesign.canvas.ignoresSafeArea())
      .task(id: model.libraryRefresh) {
        generation = UUID()
        collections = []
        complete = false
        loading = false
        await next()
      }
  }
  private func next() async {
    guard !loading, !complete, let api = model.client else { return }
    let run = generation
    let session = model.session?.sessionId
    loading = true
    defer { if generation == run { loading = false } }
    do {
      let values = try await api.collections(offset: collections.count)
      guard !Task.isCancelled, generation == run, model.session?.sessionId == session else {
        return
      }
      let old = Set(collections.map(\.id))
      collections += values.filter { !old.contains($0.id) }
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
  @FocusState private var focus: UUID?
  @State private var current: TVCollection?
  @State private var loading = false
  @State private var unavailable = false
  @State private var error: String?
  @State private var requestID = UUID()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 32) {
        Text(current?.name ?? "Collection").font(.system(size: 46, weight: .bold))
        if let current {
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 36), count: 5), spacing: 40
          ) {
            ForEach(current.items) { original in
              let item = model.overlay(original)
              NavigationLink {
                TVDetailView(id: item.detailID, initial: item)
              } label: {
                TVPosterLabel(item: item, isFocused: focus == item.id)
              }
              .buttonStyle(TVContentButtonStyle()).focusEffectDisabled().focused(
                $focus, equals: item.id
              ).accessibilityIdentifier("collection-item-\(item.id)")
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
      }.padding(64)
    }.background(TVDesign.canvas.ignoresSafeArea())
      .task(id: model.libraryRefresh) { await reload() }
      .modifier(TVLibraryActionPresentation(actions: actions))
  }

  private func reload() async {
    guard let api = model.client, let sessionID = model.session?.sessionId else { return }
    let request = UUID()
    requestID = request
    loading = true
    unavailable = false
    error = nil
    current = nil
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
