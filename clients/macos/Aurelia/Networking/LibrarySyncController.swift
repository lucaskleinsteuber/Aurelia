import Foundation

actor LibrarySyncController {
  typealias ChangeFetcher = @Sendable (StoredServerProfile, Int64, Int) async throws
    -> SyncChangesResponse

  private let fetchChanges: ChangeFetcher
  private var pollingTask: Task<Void, Never>?
  private var isForeground = true
  private var activeProfileID: UUID?
  private var cursors: [UUID: Int64] = [:]

  init(
    fetchChanges: @escaping ChangeFetcher = { profile, cursor, waitSeconds in
      try await APIClient(profile: profile).syncChanges(
        after: cursor,
        waitSeconds: waitSeconds)
    }
  ) {
    self.fetchChanges = fetchChanges
  }

  func start(
    profile: StoredServerProfile,
    onChanges: @escaping @MainActor @Sendable (SyncChangesResponse) async -> Void
  ) {
    stop()
    activeProfileID = profile.serverId
    guard isForeground else { return }
    pollingTask = Task {
      var cursor = cursors[profile.serverId] ?? 0
      while !Task.isCancelled, activeProfileID == profile.serverId, isForeground {
        do {
          let changes = try await fetchChanges(profile, cursor, 30)
          try Task.checkCancellation()
          cursor = changes.cursor
          cursors[profile.serverId] = cursor
          if changes.resetRequired || !changes.changedAreas.isEmpty {
            await onChanges(changes)
          }
        } catch is CancellationError {
          return
        } catch APIClientError.invalidResponse {
          // Aurelia 1.0.12 does not provide the sync endpoint. Its existing
          // event and manual refresh behavior remains the compatibility path.
          return
        } catch {
          do {
            try await Task.sleep(for: .seconds(3))
          } catch {
            return
          }
        }
      }
    }
  }

  func setForeground(
    _ foreground: Bool,
    profile: StoredServerProfile?,
    onChanges: @escaping @MainActor @Sendable (SyncChangesResponse) async -> Void
  ) {
    isForeground = foreground
    if foreground, let profile {
      start(profile: profile, onChanges: onChanges)
    } else {
      stop()
    }
  }

  func stop() {
    pollingTask?.cancel()
    pollingTask = nil
    activeProfileID = nil
  }
}
