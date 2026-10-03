import Foundation

// Home can be refreshed by sync, navigation, activation and player shutdown.
// A request started before the latest progress save must not replace a newer Home.
@MainActor
final class HomeRefreshCoordinator {
  private var latestRequest = UUID()
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
