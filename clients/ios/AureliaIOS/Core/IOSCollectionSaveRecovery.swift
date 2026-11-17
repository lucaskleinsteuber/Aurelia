import Combine
import Foundation

/// A collection's details and artwork are separate operations. Once creating the details
/// succeeds, every retry updates that identity, even if attaching artwork then fails.
@MainActor
final class IOSCollectionSaveRecovery: ObservableObject {
  @Published private(set) var savedCollection: IOSCollection?

  func saveDetails(existingID: UUID?, payload: IOSSaveCollection, api: IOSAPIClient) async throws
    -> IOSCollection
  {
    let saved: IOSCollection
    if let id = savedCollection?.id ?? existingID {
      saved = try await api.updateCollection(id: id, payload)
    } else {
      saved = try await api.createCollection(payload)
    }
    savedCollection = saved
    return saved
  }
}
