import SwiftUI

struct MediaActionsModifier: ViewModifier {
  @EnvironmentObject private var model: AppModel
  let item: CatalogItemSummary
  var onRemoved: (() -> Void)?
  @State private var editing: MediaMetadataSummary?
  @State private var removing = false
  @State private var error: String?
  @StateObject private var watchActions = MediaWatchActionController()
  func body(content: Content) -> some View {
    content.contextMenu {
      if item.kind == .movie || item.kind == .series {
        Button(
          item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
          systemImage: item.isFavorite ? "star.slash" : "star"
        ) {
          Task { _ = await model.setFavorite(mediaId: item.id, isFavorite: !item.isFavorite) }
        }
      }
      MediaWatchMenuItems(item: item, controller: watchActions)
      if model.canManageMedia {
        Button("Edit Metadata…", systemImage: "pencil") {
          Task {
            guard let profile = model.profile else { return }
            do { editing = try await APIClient(profile: profile).mediaMetadata(id: item.id) } catch
            { self.error = error.localizedDescription }
          }
        }
        Divider()
        Button("Remove from Library…", systemImage: "trash", role: .destructive) { removing = true }
      }
    }
    .modifier(MediaWatchActionConfirmation(controller: watchActions))
    .sheet(item: $editing) { metadata in
      MetadataEditorSheet(metadata: metadata) { try? await model.refresh() }.environmentObject(
        model)
    }
    .confirmationDialog("Remove \(item.title)?", isPresented: $removing, titleVisibility: .visible)
    {
      Button("Remove from Library", role: .destructive) {
        Task {
          do {
            try await model.removeMedia(id: item.id)
            onRemoved?()
          } catch { self.error = error.localizedDescription }
        }
      }
    } message: {
      Text(
        "Aurelia metadata, images, favorites and playback history for this title and its associated content will be removed for all users. Video files are never changed. Future scans will keep this source excluded."
      )
    }
    .alert(
      "Library Action Failed",
      isPresented: Binding(
        get: { error != nil || watchActions.errorMessage != nil },
        set: {
          if !$0 {
            error = nil
            watchActions.errorMessage = nil
          }
        })
    ) {
      Button("OK") {
        error = nil
        watchActions.errorMessage = nil
      }
    } message: {
      Text(error ?? watchActions.errorMessage ?? "")
    }
  }
}

@MainActor
final class MediaWatchActionController: ObservableObject {
  struct PendingAction {
    let state: WatchStateResponse
    let isWatched: Bool
    let clientMutationId: UUID

    var title: String {
      "Mark \(state.affectedCount) \(state.affectedCount == 1 ? "episode" : "episodes") as \(isWatched ? "watched" : "unwatched")?"
    }
    var message: String {
      isWatched
        ? "This marks the selected episodes as watched."
        : "This resets playback positions for the selected episodes."
    }
  }

  typealias Apply = @MainActor (WatchStateResponse, Bool, UUID) async throws -> Void
  @Published private(set) var pendingAction: PendingAction?
  @Published private(set) var isWorking = false
  @Published var errorMessage: String?
  private var generation = UUID()
  private var apply: Apply?

  func prepare(
    isWatched: Bool, aggregate: Bool,
    fetch: @MainActor () async throws -> WatchStateResponse,
    apply: @escaping Apply
  ) async {
    guard !isWorking, pendingAction == nil else { return }
    let request = UUID()
    generation = request
    isWorking = true
    errorMessage = nil
    do {
      let state = try await fetch()
      guard accepts(request) else { return }
      let pending = PendingAction(state: state, isWatched: isWatched, clientMutationId: UUID())
      if aggregate {
        self.apply = apply
        pendingAction = pending
        isWorking = false
      } else {
        try await apply(state, isWatched, pending.clientMutationId)
        guard accepts(request) else { return }
        isWorking = false
      }
    } catch {
      guard accepts(request) else { return }
      isWorking = false
      if !(error is CancellationError) { errorMessage = error.localizedDescription }
    }
  }

  @discardableResult
  func confirm() -> Task<Void, Never>? {
    guard !isWorking, let pending = pendingAction, let apply else { return nil }
    let request = generation
    pendingAction = nil
    self.apply = nil
    isWorking = true
    return Task {
      do {
        try await apply(pending.state, pending.isWatched, pending.clientMutationId)
        guard accepts(request) else { return }
        isWorking = false
      } catch {
        guard accepts(request) else { return }
        isWorking = false
        if !(error is CancellationError) { errorMessage = error.localizedDescription }
      }
    }
  }

  func changeVisibility(operation: @MainActor () async throws -> Void) async {
    guard !isWorking, pendingAction == nil else { return }
    let request = UUID()
    generation = request
    isWorking = true
    errorMessage = nil
    do {
      try await operation()
      guard accepts(request) else { return }
      isWorking = false
    } catch {
      guard accepts(request) else { return }
      isWorking = false
      if !(error is CancellationError) { errorMessage = error.localizedDescription }
    }
  }

  func cancelConfirmation() {
    pendingAction = nil
    apply = nil
  }

  private func accepts(_ request: UUID) -> Bool {
    guard generation == request else { return false }
    if Task.isCancelled {
      isWorking = false
      return false
    }
    return true
  }

  func invalidate() {
    generation = UUID()
    isWorking = false
    errorMessage = nil
    cancelConfirmation()
  }
}

struct MediaWatchMenuItems: View {
  @EnvironmentObject private var model: AppModel
  let item: CatalogItemSummary
  @ObservedObject var controller: MediaWatchActionController
  var scope: WatchStateScope? = nil
  var seasonNumber: Int? = nil
  var includeContinueWatching = true

  private var resolvedScope: WatchStateScope { scope ?? (item.kind == .series ? .series : .title) }
  private var aggregate: Bool { resolvedScope == .series || resolvedScope == .season }
  private var subject: String {
    resolvedScope == .season ? "Season " : resolvedScope == .series ? "Series " : ""
  }

  var body: some View {
    if item.kind == .movie || item.kind == .series || item.kind == .episode {
      Divider()
      Button("Mark \(subject)as Watched", systemImage: "checkmark.circle") { mark(watched: true) }
        .disabled(!model.supportsLibraryState || controller.isWorking)
      Button("Mark \(subject)as Unwatched", systemImage: "circle") { mark(watched: false) }
        .disabled(!model.supportsLibraryState || controller.isWorking)
      if includeContinueWatching {
        Button(
          item.continueWatchingHidden
            ? "Show in Continue Watching" : "Remove from Continue Watching",
          systemImage: item.continueWatchingHidden ? "eye" : "eye.slash"
        ) {
          Task {
            await controller.changeVisibility {
              _ = try await model.setContinueWatchingHidden(
                mediaId: item.id, isHidden: !item.continueWatchingHidden)
            }
          }
        }
        .disabled(!model.supportsLibraryState || controller.isWorking)
      }
      if !model.supportsLibraryState { Text("Requires Aurelia Server 1.5.3") }
    }
  }

  private func mark(watched: Bool) {
    Task {
      await controller.prepare(
        isWatched: watched, aggregate: aggregate,
        fetch: {
          try await model.watchState(
            mediaId: item.id, scope: resolvedScope, seasonNumber: seasonNumber)
        },
        apply: { state, isWatched, mutationId in
          _ = try await model.setWatchState(
            mediaId: item.id, isWatched: isWatched, scope: resolvedScope,
            seasonNumber: seasonNumber, stateToken: state.stateToken,
            clientMutationId: mutationId)
        })
    }
  }
}

struct MediaWatchActionConfirmation: ViewModifier {
  @EnvironmentObject private var model: AppModel
  @ObservedObject var controller: MediaWatchActionController

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        controller.pendingAction?.title ?? "Update Watched Status?",
        isPresented: Binding(
          get: { controller.pendingAction != nil },
          set: { if !$0 { controller.cancelConfirmation() } }),
        titleVisibility: .visible
      ) {
        Button(
          controller.pendingAction?.isWatched == true ? "Mark as Watched" : "Mark as Unwatched"
        ) {
          controller.confirm()
        }
        Button("Cancel", role: .cancel) { controller.cancelConfirmation() }
      } message: {
        Text(controller.pendingAction?.message ?? "")
      }
      .onChange(of: model.profile) { _, _ in controller.invalidate() }
      .onDisappear { controller.invalidate() }
  }
}

extension View {
  func mediaActions(item: CatalogItemSummary, onRemoved: (() -> Void)? = nil) -> some View {
    modifier(MediaActionsModifier(item: item, onRemoved: onRemoved))
  }
}
