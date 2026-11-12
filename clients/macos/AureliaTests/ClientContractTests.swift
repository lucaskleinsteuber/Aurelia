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

  @Test func remotePlayersAndCommandsDecodeAsTheServerWritesThem() throws {
    let time = "2026-10-31T16:50:00.1234567+00:00"
    let players = Data(
      #"[{"deviceId":"tv","deviceName":"Living Room","clientType":"tvos","isPlaying":true,"mediaId":null,"title":"Synthetic","positionSeconds":12.5,"durationSeconds":60,"isPaused":false,"lastSeen":"\#(time)"}]"#
        .utf8)
    #expect(try JSONDecoder().decode([RemotePlayerDevice].self, from: players).first?.deviceName == "Living Room")
    let commands = Data(
      #"[{"commandId":"5f0c2f1e-4c7b-4a39-9a3e-0d6c1c2b8a11","action":"pause","mediaId":null,"positionSeconds":null,"skipSeconds":null,"createdAt":"\#(time)"}]"#
        .utf8)
    #expect(try JSONDecoder().decode([RemotePlaybackCommand].self, from: commands).first?.action == "pause")
    #expect(
      try JSONDecoder().decode(
        PlayerHeartbeatResponse.self, from: Data(#"{"success":true,"timestamp":"\#(time)"}"#.utf8)
      ).success)
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

  @Test func collectionArtworkPathsAndQueryVariantsValidate() throws {
    let collectionId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let basePoster = "/api/v1/artwork/collection/11111111-1111-1111-1111-111111111111?kind=poster"
    let baseBackdrop = "/api/v1/artwork/collection/11111111-1111-1111-1111-111111111111?kind=backdrop"
    let poster = ArtworkSummary(
      id: collectionId, kind: .poster, path: basePoster, contentType: "image/jpeg",
      contentLength: 1024, revision: 2)
    let sized = ArtworkVariantRequest.artwork(poster, width: 320)
    #expect(sized.path == "\(basePoster)&width=320")
    #expect(APIClient.isValidArtworkPath(basePoster))
    #expect(APIClient.isValidArtworkPath(baseBackdrop))
    #expect(APIClient.isValidArtworkPath(sized.path))
    #expect(APIClient.isValidArtworkPath("\(basePoster)&width=320&rev=2"))
    #expect(!APIClient.isValidArtworkPath("/api/v1/artwork/collection/11111111-1111-1111-1111-111111111111?kind=other"))
    #expect(!APIClient.isValidArtworkPath("\(basePoster)&width=321"))
    #expect(!APIClient.isValidArtworkPath("\(basePoster)&other=1"))
  }

  @Test func boxSetModelsAndPlaybackQueueLogicDecodeAndOrderUnits() throws {
    let legacyData = Data(#"{"id":"11111111-1111-1111-1111-111111111111","name":"Legacy","items":[]}"#.utf8)
    let legacy = try JSONDecoder().decode(CollectionSummary.self, from: legacyData)
    #expect(legacy.canEdit)
    #expect(legacy.itemCount == 0)

    let tmdbData = Data(#"{"id":"11111111-1111-1111-1111-111111111111","name":"Sci-Fi Trilogy","overview":"Box desc","provider":"tmdb","canEdit":false,"itemCount":3,"watchedCount":1,"yearRange":"1999 - 2003","sortMode":"release","items":[]}"#.utf8)
    let tmdb = try JSONDecoder().decode(CollectionSummary.self, from: tmdbData)
    #expect(!tmdb.canEdit)
    #expect(BoxSetLogic.providerLabel(tmdb.provider) == "TMDB Collection")
    #expect(BoxSetLogic.cardSubtitle(for: tmdb) == "TMDB Collection · 1999 - 2003 · 1 of 3 watched")

    let detailJSON = #"""
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "name": "Galaxy Box",
      "overview": "All parts.",
      "provider": null,
      "canEdit": true,
      "isSmart": false,
      "isShared": true,
      "sortMode": "custom",
      "itemCount": 3,
      "watchedCount": 1,
      "yearRange": "2020 - 2024",
      "totalRuntimeSeconds": 5400,
      "genres": ["Sci-Fi"],
      "members": [
        {
          "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
          "mediaId": "22222222-2222-2222-2222-222222222222",
          "kind": "movie",
          "title": "Opening Film",
          "seasonNumber": null,
          "watchedCount": 1,
          "itemCount": 1,
          "totalRuntimeSeconds": 3600,
          "item": {
            "id": "22222222-2222-2222-2222-222222222222",
            "kind": "movie",
            "title": "Opening Film",
            "year": 2020,
            "genres": ["Sci-Fi"],
            "availability": "available",
            "isFavorite": false,
            "addedAt": "2026-01-01T00:00:00Z"
          }
        },
        {
          "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
          "mediaId": "33333333-3333-3333-3333-333333333333",
          "kind": "series",
          "title": "Mini Show",
          "seasonNumber": 0,
          "watchedCount": 0,
          "itemCount": 2,
          "totalRuntimeSeconds": 1800,
          "item": {
            "id": "33333333-3333-3333-3333-333333333333",
            "kind": "series",
            "title": "Mini Show",
            "year": 2024,
            "genres": ["Sci-Fi"],
            "availability": "available",
            "isFavorite": false,
            "addedAt": "2026-01-01T00:00:00Z"
          },
          "episodes": [
            {
              "id": "44444444-4444-4444-4444-444444444444",
              "kind": "episode",
              "title": "Special Pilot",
              "seasonNumber": 0,
              "episodeNumber": 1,
              "genres": [],
              "availability": "available",
              "isFavorite": false,
              "addedAt": "2026-01-01T00:00:00Z",
              "parentId": "33333333-3333-3333-3333-333333333333"
            },
            {
              "id": "55555555-5555-5555-5555-555555555555",
              "kind": "episode",
              "title": "Special Finale",
              "seasonNumber": 0,
              "episodeNumber": 2,
              "genres": [],
              "availability": "available",
              "isFavorite": false,
              "addedAt": "2026-01-01T00:00:00Z",
              "parentId": "33333333-3333-3333-3333-333333333333"
            }
          ]
        }
      ],
      "nextItem": {
        "item": {
          "id": "44444444-4444-4444-4444-444444444444",
          "kind": "episode",
          "title": "Special Pilot",
          "seasonNumber": 0,
          "episodeNumber": 1,
          "genres": [],
          "availability": "available",
          "isFavorite": false,
          "addedAt": "2026-01-01T00:00:00Z",
          "parentId": "33333333-3333-3333-3333-333333333333"
        },
        "resume": true,
        "positionMilliseconds": 45000,
        "itemIndex": 1,
        "totalItems": 3
      }
    }
    """#
    let detail = try JSONDecoder().decode(CollectionDetail.self, from: Data(detailJSON.utf8))
    #expect(detail.members[1].seasonNumber == 0)
    #expect(BoxSetLogic.playLabel(for: detail.nextItem) == "Resume · S00 E01")
    #expect(BoxSetLogic.statsLine(for: detail).contains("1 h 30 min"))

    let playlist = BoxSetLogic.playableItems(from: detail.members)
    #expect(playlist.map(\.title) == ["Opening Film", "Special Pilot", "Special Finale"])
    let slices = BoxSetLogic.queueSlices(for: playlist[1], in: playlist)
    #expect(slices.previous.map(\.title) == ["Opening Film"])
    #expect(slices.upcoming.map(\.title) == ["Special Finale"])
  }
}
