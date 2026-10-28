import SwiftUI

struct MediaActionsModifier: ViewModifier {
  @EnvironmentObject private var model: AppModel
  let item: CatalogItemSummary
  var onRemoved: (() -> Void)?
  var onPlay: (() -> Void)?
  var onResume: (() -> Void)?
  var onGoToSeries: ((UUID) -> Void)?
  var seasonNumber: Int? = nil
  @State private var editing: MediaMetadataSummary?
  @State private var removing = false
  @State private var error: String?
  @StateObject private var watchActions = MediaWatchActionController()
  func body(content: Content) -> some View {
    content.contextMenu {
      MediaContextMenuItems(
        item: item, controller: watchActions,
        onEdit: {
          Task {
            guard model.canManageMedia, let profile = model.profile else { return }
            do {
              let metadata = try await APIClient(profile: profile).mediaMetadata(id: item.id)
              guard profile == model.profile, model.canManageMedia else { return }
              editing = metadata
            } catch {
              guard profile == model.profile, !(error is CancellationError) else { return }
              self.error = error.localizedDescription
            }
          }
        }, onRemove: { removing = true }, onPlay: onPlay, onResume: onResume,
        onGoToSeries: onGoToSeries, seasonNumber: seasonNumber)
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

/// Menu visibility follows the current server capabilities; episodes keep their series identity.
enum MediaContextMenuPolicy {
  static func canResume(_ item: CatalogItemSummary) -> Bool {
    guard item.progress?.isCompleted != true, item.watchState != .completed else { return false }
    return (item.progress?.positionMilliseconds ?? 0) > 0 || item.watchState == .inProgress
  }

  static func seriesID(_ item: CatalogItemSummary) -> UUID? {
    item.kind == .episode ? item.parentId : nil
  }

  static func canFavorite(_ item: CatalogItemSummary) -> Bool {
    item.kind == .movie || item.kind == .series
  }
}

struct MediaContextMenuItems: View {
  @EnvironmentObject private var model: AppModel
  let item: CatalogItemSummary
  @ObservedObject var controller: MediaWatchActionController
  var onEdit: (() -> Void)? = nil
  var onRemove: (() -> Void)? = nil
  var metadataReady = true
  var onPlay: (() -> Void)? = nil
  var onResume: (() -> Void)? = nil
  var onGoToSeries: ((UUID) -> Void)? = nil
  var seasonNumber: Int? = nil

  var body: some View {
    Button("Play", systemImage: "play.fill") {
      if let onPlay { onPlay() } else { model.startPlayback(item: item, intent: .play) }
    }
    .disabled(item.kind != .series && !item.isPlayable)
    if MediaContextMenuPolicy.canResume(item) {
      Button("Resume", systemImage: "play.fill") {
        if let onResume { onResume() } else { model.startPlayback(item: item, intent: .resume) }
      }
      .disabled(item.kind != .series && !item.isPlayable)
    }
    if let series = MediaContextMenuPolicy.seriesID(item) {
      Button("Go to Series", systemImage: "tv") {
        if let onGoToSeries { onGoToSeries(series) } else { model.requestedMediaDetail = series }
      }
    }
    if item.kind == .episode, let seriesId = item.parentId {
      MediaWatchMenuItems(
        item: item, controller: controller, scope: .title, includeContinueWatching: false)
      let resolvedSeason = item.seasonNumber ?? seasonNumber
      if let resolvedSeason {
        let seriesSummary = CatalogItemSummary(
          stubId: seriesId, kind: .series, title: item.parentTitle ?? item.title,
          availability: item.availability, isFavorite: false)
        MediaWatchMenuItems(
          item: seriesSummary, controller: controller, scope: .season,
          seasonNumber: resolvedSeason, includeContinueWatching: false, subjectPrefix: "Season")
      }
      let seriesSummary = CatalogItemSummary(
        stubId: seriesId, kind: .series, title: item.parentTitle ?? item.title,
        availability: item.availability, isFavorite: false)
      MediaWatchMenuItems(
        item: seriesSummary, controller: controller, scope: .series,
        includeContinueWatching: false, subjectPrefix: "Series")
    } else {
      if item.kind == .series, let seasonNumber {
        MediaWatchMenuItems(
          item: item, controller: controller, scope: .season,
          seasonNumber: seasonNumber, includeContinueWatching: false, subjectPrefix: "Season")
      }
      MediaWatchMenuItems(
        item: item, controller: controller, includeContinueWatching: false,
        subjectPrefix: item.kind == .series && seasonNumber != nil ? "Series" : nil)
    }
    if MediaContextMenuPolicy.canFavorite(item) {
      Button(
        item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
        systemImage: item.isFavorite ? "star.slash" : "star"
      ) {
        Task { _ = await model.setFavorite(mediaId: item.id, isFavorite: !item.isFavorite) }
      }
      if model.supportsWatchlist {
        let watchlisted = model.isWatchlisted(item.id)
        Button(
          watchlisted ? "Remove from Watchlist" : "Add to Watchlist",
          systemImage: watchlisted ? "bookmark.slash" : "bookmark"
        ) {
          Task { _ = await model.setWatchlist(mediaId: item.id, isWatchlisted: !watchlisted) }
        }
      }
    }
    MediaContinueWatchingMenuItem(item: item, controller: controller)
    if model.canManageMedia, let onEdit {
      Divider()
      Button("Edit Metadata…", systemImage: "pencil", action: onEdit)
        .disabled(!metadataReady)
    }
    if model.canManageMedia, let onRemove {
      Divider()
      Button("Remove from Library…", systemImage: "trash", role: .destructive, action: onRemove)
    }
  }
}

struct MediaContinueWatchingMenuItem: View {
  @EnvironmentObject private var model: AppModel
  let item: CatalogItemSummary
  @ObservedObject var controller: MediaWatchActionController

  var body: some View {
    if [.movie, .series, .episode].contains(item.kind) {
      Button(
        item.continueWatchingHidden ? "Show in Continue Watching" : "Remove from Continue Watching",
        systemImage: item.continueWatchingHidden ? "eye" : "eye.slash"
      ) {
        let hidden = !item.continueWatchingHidden
        Task {
          await controller.changeVisibility {
            _ = try await model.setContinueWatchingHidden(mediaId: item.id, isHidden: hidden)
          }
        }
      }
      .disabled(!model.supportsLibraryState || controller.isWorking)
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
  var subjectPrefix: String? = nil

  private var resolvedScope: WatchStateScope { scope ?? (item.kind == .series ? .series : .title) }
  private var aggregate: Bool { resolvedScope == .series || resolvedScope == .season }
  private var subject: String {
    if let subjectPrefix { return "\(subjectPrefix) " }
    return resolvedScope == .season ? "Season " : ""
  }

  var body: some View {
    if item.kind == .movie || item.kind == .series || item.kind == .episode {
      Divider()
      Button("Mark \(subject)as Watched", systemImage: "checkmark.circle") { mark(watched: true) }
        .disabled(!model.supportsLibraryState || controller.isWorking)
      Button("Mark \(subject)as Unwatched", systemImage: "circle") { mark(watched: false) }
        .disabled(!model.supportsLibraryState || controller.isWorking)
      if includeContinueWatching {
        MediaContinueWatchingMenuItem(item: item, controller: controller)
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
  func mediaActions(
    item: CatalogItemSummary, onRemoved: (() -> Void)? = nil, onPlay: (() -> Void)? = nil,
    onResume: (() -> Void)? = nil,
    onGoToSeries: ((UUID) -> Void)? = nil,
    seasonNumber: Int? = nil
  ) -> some View {
    modifier(
      MediaActionsModifier(
        item: item, onRemoved: onRemoved, onPlay: onPlay, onResume: onResume,
        onGoToSeries: onGoToSeries, seasonNumber: seasonNumber))
  }
}
