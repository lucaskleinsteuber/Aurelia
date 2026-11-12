import SwiftUI

@MainActor
final class IOSLibraryActions: ObservableObject {
  struct Pending {
    let item: IOSCatalogItem
    let state: IOSWatchState
    let watched: Bool
    let sessionID: UUID
    var title: String {
      "Mark \(state.affectedCount) episodes as \(watched ? "watched" : "unwatched")?"
    }
  }
  @Published var pending: Pending?
  @Published var error: String?
  /// The title whose collections are being chosen ("Add to Collection…").
  @Published var collecting: IOSCatalogItem?
  @Published private(set) var busy = false

  func favorite(_ item: IOSCatalogItem, model: IOSAppModel) async {
    await perform(model: model) { api in
      _ = try await api.setFavorite(mediaID: item.id, isFavorite: !item.isFavorite)
      return try await api.summary(id: item.id)
    }
  }
  func watch(
    _ item: IOSCatalogItem, scope: IOSWatchScope, season: Int? = nil, watched: Bool,
    model: IOSAppModel
  ) async {
    guard !busy, let api = model.client, let sessionID = model.session?.sessionId else { return }
    busy = true
    defer { busy = false }
    do {
      let state = try await api.watchState(mediaID: item.id, scope: scope, season: season)
      guard model.session?.sessionId == sessionID, !Task.isCancelled else { return }
      if scope != .title {
        pending = Pending(item: item, state: state, watched: watched, sessionID: sessionID)
      } else {
        try await apply(
          item: item, state: state, watched: watched, model: model, sessionID: sessionID)
      }
    } catch { failure(error, model: model, sessionID: sessionID) }
  }
  func confirm(_ pending: Pending, model: IOSAppModel) async {
    guard !busy, model.session?.sessionId == pending.sessionID else {
      self.pending = nil
      return
    }
    self.pending = nil
    busy = true
    defer { busy = false }
    do {
      try await apply(
        item: pending.item, state: pending.state, watched: pending.watched, model: model,
        sessionID: pending.sessionID)
    } catch { failure(error, model: model, sessionID: pending.sessionID) }
  }
  private func apply(
    item: IOSCatalogItem, state: IOSWatchState, watched: Bool, model: IOSAppModel, sessionID: UUID
  ) async throws {
    guard let api = model.client, model.session?.sessionId == sessionID else { return }
    _ = try await api.setWatchState(
      mediaID: item.id,
      request: IOSSetWatchState(
        isWatched: watched, scope: state.scope, seasonNumber: state.seasonNumber,
        stateToken: state.stateToken, clientMutationId: UUID()))
    guard model.session?.sessionId == sessionID else { return }
    let updated = try await api.summary(id: item.id)
    guard model.session?.sessionId == sessionID else { return }
    model.applyMutationSummary(updated)
    model.scheduleLibraryRefresh()
  }
  func continuation(_ item: IOSCatalogItem, hidden: Bool, model: IOSAppModel) async {
    let id = item.kind == .episode ? item.parentId ?? item.id : item.id
    let scope: IOSWatchScope = item.kind == .series || item.kind == .episode ? .series : .title
    await perform(model: model) { api in
      let state = try await api.watchState(mediaID: id, scope: scope)
      _ = try await api.setContinueWatchingHidden(
        mediaID: id,
        request: IOSSetContinueWatching(
          isHidden: hidden, stateToken: state.stateToken, clientMutationId: UUID()))
      return try await api.summary(id: id)
    }
  }
  private func perform(model: IOSAppModel, operation: (IOSAPIClient) async throws -> IOSCatalogItem)
    async
  {
    guard !busy, let api = model.client, let sessionID = model.session?.sessionId else { return }
    busy = true
    defer { busy = false }
    do {
      let updated = try await operation(api)
      guard !Task.isCancelled, model.session?.sessionId == sessionID else { return }
      model.applyMutationSummary(updated)
      model.scheduleLibraryRefresh()
    } catch { failure(error, model: model, sessionID: sessionID) }
  }
  private func failure(_ failure: Error, model: IOSAppModel, sessionID: UUID) {
    guard model.session?.sessionId == sessionID else { return }
    if (failure as? IOSCoreError)?.isConflict == true {
      error = "This title changed on another device. Review its updated state and try again."
      model.scheduleLibraryRefresh()
    } else {
      error = failure.localizedDescription
      model.handleSessionFailure(failure)
    }
  }
}

struct IOSLibraryActionPresentation: ViewModifier {
  @EnvironmentObject private var model: IOSAppModel
  @ObservedObject var actions: IOSLibraryActions
  func body(content: Content) -> some View {
    content.confirmationDialog(
      actions.pending?.title ?? "Update watch status?",
      isPresented: Binding(
        get: { actions.pending != nil }, set: { if !$0 { actions.pending = nil } }),
      titleVisibility: .visible, presenting: actions.pending
    ) { pending in
      Button(
        pending.watched ? "Mark as Watched" : "Mark as Unwatched",
        role: pending.watched ? nil : .destructive
      ) { Task { await actions.confirm(pending, model: model) } }
      Button("Cancel", role: .cancel) { actions.pending = nil }
    } message: { pending in
      Text(
        !pending.watched
          ? "Playback positions for these episodes will be reset. Favorites, collections and scene notes are kept."
          : "The selected episodes will be marked as watched.")
    }
    .alert(
      "Couldn't Update Title",
      isPresented: Binding(get: { actions.error != nil }, set: { if !$0 { actions.error = nil } })
    ) {
      Button("OK") { actions.error = nil }
    } message: {
      Text(actions.error ?? "")
    }
    .sheet(item: $actions.collecting) { item in IOSAddToCollectionSheet(item: item) }
    .onChange(of: model.session?.sessionId) { _, _ in
      actions.pending = nil
      actions.error = nil
      actions.collecting = nil
    }
  }
}

struct IOSMediaContextActions: View {
  @EnvironmentObject private var model: IOSAppModel
  let item: IOSCatalogItem
  @ObservedObject var actions: IOSLibraryActions
  var continuation = false
  var includeFavorite = true
  var body: some View {
    if includeFavorite, item.kind == .movie || item.kind == .series {
      Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
        Task { await actions.favorite(item, model: model) }
      }.disabled(actions.busy)
    }
    let watched = item.watchState == "completed" || item.progress?.isCompleted == true
    Button(watched ? "Mark as Unwatched" : "Mark as Watched") {
      Task {
        await actions.watch(
          item, scope: item.kind == .series ? .series : .title, watched: !watched, model: model)
      }
    }.disabled(actions.busy)
    if model.supportsWatchlist, item.kind == .movie || item.kind == .series {
      let watchlisted = model.isWatchlisted(item.id)
      Button(watchlisted ? "Remove from Watchlist" : "Add to Watchlist") {
        Task { _ = await model.setWatchlist(mediaId: item.id, isWatchlisted: !watchlisted) }
      }.disabled(actions.busy)
    }
    if continuation || item.kind == .movie || item.kind == .series {
      let hidden = item.continueWatchingHidden == true
      Button(hidden ? "Show in Continue Watching" : "Remove from Continue Watching") {
        Task { await actions.continuation(item, hidden: !hidden, model: model) }
      }.disabled(actions.busy)
    }
    if model.supportsCollections, item.kind == .movie || item.kind == .series {
      Button("Add to Collection…") { actions.collecting = item }
    }
    IOSDownloadMenuItems(item: item, store: model.offline)
  }
}

/// Chooses which of the editable collections hold a title, or starts a new one with it.
struct IOSAddToCollectionSheet: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.dismiss) private var dismiss
  let item: IOSCatalogItem
  @State private var collections: [IOSCollection] = []
  @State private var loading = true
  @State private var newName = ""
  @State private var error: String?
  @State private var working = false

  private var editable: [IOSCollection] {
    collections.filter {
      IOSCollectionRules.canEdit(
        $0, userID: model.session?.user.id, role: model.session?.user.role)
    }
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            TextField("New Collection", text: $newName)
              .accessibilityIdentifier("collection-new-name")
            Button("Create") { Task { await create() } }
              .disabled(IOSCollectionRules.cleanedName(newName) == nil || working)
          }
        } footer: {
          Text("A new collection is yours alone; it starts with \(item.title).")
        }
        Section("Your Collections") {
          if loading { ProgressView() }
          if !loading && editable.isEmpty { Text("No collections yet.").foregroundStyle(.secondary) }
          ForEach(editable) { collection in
            let included = collection.items.contains { $0.id == item.id }
            Button {
              Task { await toggle(collection, included: !included) }
            } label: {
              HStack {
                Text(collection.name).foregroundStyle(.primary)
                Spacer()
                if included { Image(systemName: "checkmark").foregroundStyle(.tint) }
              }
            }
            .disabled(working)
            .accessibilityAddTraits(included ? .isSelected : [])
          }
        }
        if let error { Section { IOSErrorText(message: error) } }
      }
      .navigationTitle("Add to Collection")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .task { await reload() }
    }
  }

  private func reload() async {
    guard let api = model.client else { return }
    defer { loading = false }
    do {
      collections = try await api.editableCollections()
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func create() async {
    guard let api = model.client, let name = IOSCollectionRules.cleanedName(newName) else { return }
    working = true
    defer { working = false }
    do {
      _ = try await api.createCollection(name: name, mediaIDs: [item.id])
      newName = ""
      model.scheduleLibraryRefresh()
      await reload()
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func toggle(_ collection: IOSCollection, included: Bool) async {
    guard let api = model.client else { return }
    working = true
    defer { working = false }
    do {
      try await api.setCollectionItem(collectionID: collection.id, mediaID: item.id, included: included)
      model.scheduleLibraryRefresh()
      await reload()
    } catch {
      self.error = error.localizedDescription
    }
  }
}
