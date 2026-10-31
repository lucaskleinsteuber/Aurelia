import Foundation
import Testing

@testable import Aurelia

private final class ClientContractBundle: NSObject {}

struct ClientContractTests {
  private func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    let url = try #require(
      Bundle(for: ClientContractBundle.self).url(
        forResource: "client-contracts-v1", withExtension: "json"))
    let values = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let data = try JSONSerialization.data(withJSONObject: #require(values[name]))
    return try JSONDecoder().decode(type, from: data)
  }

  @Test func smartListRulesTravelInTheProtocolsNames() throws {
    let rules = SmartCollectionRules(
      kind: "movies", watched: "unwatched", search: "Alien", match: "any")
    let sent = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(rules)) as? [String: Any])
    #expect(sent["kind"] as? String == "movie")
    #expect(sent["watchedState"] as? String == "unwatched")
    #expect(sent["textContains"] as? String == "Alien")
    #expect(sent["combination"] as? String == "or")
    #expect(sent["watched"] == nil && sent["search"] == nil && sent["match"] == nil)
    // Read back from the server, and as earlier versions of the app saved it.
    #expect(try JSONDecoder().decode(SmartCollectionRules.self, from: JSONEncoder().encode(rules)) == rules)
    let legacy = try JSONDecoder().decode(
      SmartCollectionRules.self,
      from: Data(#"{"kind":"movies","watched":"watched","search":"x","match":"any"}"#.utf8))
    #expect(legacy == SmartCollectionRules(kind: "movies", watched: "watched", search: "x", match: "any"))
  }

  @Test func sharedArtworkFixturesRemainCompatible() throws {
    let old = try fixture("artworkLegacy", as: ArtworkSummary.self)
    let current = try fixture("artwork", as: ArtworkSummary.self)
    #expect(old.revision == nil)
    #expect(current.revision == 3)
    #expect(ArtworkVariantRequest.artwork(old, width: 320).path == old.path)
    #expect(ArtworkVariantRequest.artwork(current, width: 320).path.hasSuffix("?width=320"))
    #expect(ArtworkVariantRequest.width(for: 154, scale: 2) == 320)
    #expect(ArtworkVariantRequest.width(for: 500, scale: 2) == 1280)
    #expect(!APIClient.isValidArtworkPath(current.path + "?width=321"))
    #expect(!APIClient.isValidArtworkPath(current.path + "?width=320&other=1"))
    #expect(!APIClient.isValidArtworkPath(current.path + "?width=320#fragment"))
  }

  @Test func sharedReadinessAndPairingFixturesDecode() throws {
    let current = try fixture("status", as: ServerStatusSummary.self)
    let legacy = try fixture("statusLegacy", as: ServerStatusSummary.self)
    let pairing = try fixture("pairing", as: DeviceAuthorizationStatusResponse.self)
    #expect(current.readiness?.state == "degraded")
    #expect(current.readiness?.components.first?.detail == "Media drive disconnected")
    #expect(legacy.readiness == nil)
    #expect(pairing.state == .pending)
    #expect(pairing.authentication == nil)
    let approved = try fixture("pairingApproved", as: DeviceAuthorizationStatusResponse.self)
    #expect(approved.state == .approved)
    #expect(approved.authentication?.user.role == .owner)
    #expect(
      approved.authentication?.sessionId == UUID(uuidString: "15500000-0000-0000-0000-000000000003")
    )
    let unknown = try JSONDecoder().decode(
      DeviceAuthorizationState.self, from: Data("\"futureState\"".utf8))
    #expect(unknown == .unknown)
  }

  @Test func historyAndLibraryHealthFixturesDecode() throws {
    let history = try fixture("historyPage", as: WatchHistoryPage.self)
    #expect(history.total == 1)
    #expect(history.items.first?.eyebrow == "Example Show · S1E1")
    #expect(history.items.first?.completionPercentage == 50)
    #expect(history.items.first?.watchedDate != nil)

    let groups = try fixture("duplicateGroups", as: [DuplicateGroup].self)
    #expect(groups.first?.items.map(\.isAvailable) == [true, false])
    let offline = try fixture("offlineTitles", as: [OfflineTitleSummary].self)
    #expect(offline.first?.daysOffline == 59)
    #expect(offline.first?.lastSeenDate != nil)
    let unmatched = try fixture("unmatchedTitles", as: [UnmatchedTitleSummary].self)
    #expect(unmatched.first?.issueReason == "No metadata found")
  }

  @Test @MainActor func artworkRevisionChangesInvalidateSameID() async throws {
    var requests = 0
    let loader = ArtworkLoader { _, _ in
      requests += 1
      return Data([UInt8(requests)])
    }
    let base = try fixture("artwork", as: ArtworkSummary.self)
    var updated = base
    updated.revision = 4
    let profile = StoredServerProfile(
      serverId: UUID(), name: "Synthetic", baseURL: URL(string: "https://fixture.invalid")!,
      publicKeyFingerprint: "synthetic", token: "synthetic", sessionId: UUID(),
      expiresAt: "2099-01-01T00:00:00Z")
    #expect(try await loader.data(for: base, profile: profile, width: 320) == Data([1]))
    #expect(try await loader.data(for: base, profile: profile, width: 320) == Data([1]))
    #expect(try await loader.data(for: updated, profile: profile, width: 320) == Data([2]))
    #expect(try await loader.data(for: updated, profile: profile, width: 640) == Data([3]))
  }
}
