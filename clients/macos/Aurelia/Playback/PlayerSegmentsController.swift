import Combine
import Foundation

@MainActor
protocol MediaSegmentsClient: Sendable {
  func mediaSegments(mediaId: UUID) async throws -> MediaSegments
}

extension APIClient: MediaSegmentsClient {}

/// Loads the intro and credits times for the title in the player. A missing or older server
/// simply means there are no stored times; chapters can still offer a skip.
@MainActor
final class PlayerSegmentsController: ObservableObject {
  @Published private(set) var segments: MediaSegments?
  private let client: any MediaSegmentsClient
  private var mediaId: UUID
  private var loadTask: Task<Void, Never>?

  init(profile: StoredServerProfile, mediaId: UUID) {
    client = APIClient(profile: profile)
    self.mediaId = mediaId
  }

  init(client: any MediaSegmentsClient, mediaId: UUID) {
    self.client = client
    self.mediaId = mediaId
  }

  func changeMedia(_ id: UUID) {
    guard id != mediaId else { return }
    mediaId = id
    segments = nil
    load()
  }

  func load() {
    loadTask?.cancel()
    let id = mediaId
    loadTask = Task { [weak self] in
      guard let self else { return }
      let result = try? await client.mediaSegments(mediaId: id)
      guard !Task.isCancelled, mediaId == id else { return }
      segments = result
    }
  }

  func stop() {
    loadTask?.cancel()
    loadTask = nil
  }
}
