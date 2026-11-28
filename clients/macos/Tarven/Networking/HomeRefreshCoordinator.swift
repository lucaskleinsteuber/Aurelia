import Foundation

// Home can be refreshed by sync, navigation, activation and player shutdown.
// A request started before the latest progress save must not replace a newer Home.
// A Home-only refresh never supersedes a complete library snapshot in flight;
// it is deferred and runs once that snapshot has finished.
@MainActor
final class HomeRefreshCoordinator {
  private var latestRequest = UUID()
  private var activeSnapshots = 0
  private var deferredHomeRefresh = false
  private let fetch: (StoredServerProfile) async throws -> HomeResponse

  init(
    fetch: @escaping (StoredServerProfile) async throws -> HomeResponse = {
      try await APIClient(profile: $0).home()
    }
  ) {
    self.fetch = fetch
  }

  func beginRequest() -> UUID {
    latestRequest = UUID()
    return latestRequest
  }

  func beginSnapshot() -> UUID {
    activeSnapshots += 1
    return beginRequest()
  }

  /// Returns true when a Home-only refresh was deferred and should run now.
  func endSnapshot() -> Bool {
    activeSnapshots = max(0, activeSnapshots - 1)
    guard activeSnapshots == 0, deferredHomeRefresh else { return false }
    deferredHomeRefresh = false
    return true
  }

  /// Returns nil while a complete snapshot is loading; the refresh is deferred.
  func beginHomeOnlyRequest() -> UUID? {
    guard activeSnapshots == 0 else {
      deferredHomeRefresh = true
      return nil
    }
    return beginRequest()
  }

  func invalidate() {
    latestRequest = UUID()
  }

  func isCurrent(_ request: UUID) -> Bool {
    request == latestRequest
  }

  func load(request: UUID, profile: StoredServerProfile) async throws -> HomeResponse? {
    guard request == latestRequest, !Task.isCancelled else { return nil }
    do {
      let response = try await fetch(profile)
      guard request == latestRequest, !Task.isCancelled else { return nil }
      return response
    } catch {
      guard request == latestRequest, !Task.isCancelled else { return nil }
      throw error
    }
  }
}
