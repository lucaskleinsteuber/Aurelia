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
    .onChange(of: model.session?.sessionId) { _, _ in
      actions.pending = nil
      actions.error = nil
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
  }
}
