#if DEBUG
  import Foundation

  enum TVUITestScenario: String, Sendable {
    case library, profiles, delayed, offline, limitedTracks
    static var current: Self? {
      guard ProcessInfo.processInfo.arguments.contains("--aurelia-ui-testing") else { return nil }
      return ProcessInfo.processInfo.environment["AURELIA_TV_UI_SCENARIO"].flatMap(
        Self.init(rawValue:))
    }
  }

  enum TVUITestFixtures {
    static let serverID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let profileID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let movieID = UUID(uuidString: "00000000-0000-4000-8000-000000000010")!
    static let seriesID = UUID(uuidString: "00000000-0000-4000-8000-000000000020")!
    static let resumeID = episodeID(season: 2, episode: 2)
    static let fingerprint = String(repeating: "A", count: 64)
    static let expiry = "2099-01-01T00:00:00Z"
    static let stamp = "2026-01-01T00:00:00Z"
    static var connection: TVStoredConnection {
      TVStoredConnection(
        serverID: serverID, name: "Synthetic Server",
        baseURL: URL(string: "https://fixture.invalid:43111")!, fingerprint: fingerprint,
        deviceToken: String(repeating: "D", count: 43), deviceSessionID: serverID)
    }
    static var session: TVProfileSession {
      TVProfileSession(
        user: TVUser(id: profileID, username: "Test Viewer", role: "viewer"),
        sessionId: profileID, token: String(repeating: "P", count: 43), expiresAt: expiry)
    }
    static func episodeID(season: Int, episode: Int) -> UUID {
      UUID(
        uuidString: String(format: "00000000-0000-4000-8000-%012d", 100 + season * 20 + episode))!
    }
    static func progress(
      id: UUID, position: Int64 = 90_000, revision: Int64 = 0,
      mutation: String? = nil
    ) -> [String: Any] {
      [
        "mediaId": id.uuidString, "positionMilliseconds": position,
        "durationMilliseconds": 5_400_000, "isCompleted": false,
        "lastPlayedAt": stamp, "updatedAt": stamp, "revision": revision,
        "lastMutationId": mutation.map { $0 as Any } ?? NSNull(),
      ]
    }
    static func item(
      id: UUID, kind: String, title: String, season: Int? = nil,
      episode: Int? = nil, offline: Bool = false
    ) -> [String: Any] {
      var value: [String: Any] = [
        "id": id.uuidString, "kind": kind, "title": title,
        "year": 2026, "overview": "A synthetic title for remote navigation and layout checks.",
        "genres": ["Drama"], "availability": offline ? "missing" : "available",
        "isFavorite": false, "addedAt": stamp,
        "libraryAvailability": offline ? "unavailable" : "available",
        "watchState": id == resumeID || id == movieID ? "inProgress" : "unplayed",
      ]
      if id == resumeID || id == movieID { value["progress"] = progress(id: id) }
      if let season, let episode {
        value["parentId"] = seriesID.uuidString
        value["parentTitle"] = "Aurelia Test Series"
        value["seasonNumber"] = season
        value["episodeNumber"] = episode
      }
      return value
    }
    static func episode(season: Int, number: Int, offline: Bool = false) -> [String: Any] {
      item(
        id: episodeID(season: season, episode: number), kind: "episode",
        title: number == 2
          ? "A Long Episode Title That Must Stay Inside Its Focus Frame" : "Episode \(number)",
        season: season, episode: number, offline: offline && season == 2 && number == 2)
    }
    static func movie() -> [String: Any] {
      item(id: movieID, kind: "movie", title: "Aurelia Test Movie")
    }
    static func series() -> [String: Any] {
      item(id: seriesID, kind: "series", title: "Aurelia Test Series")
    }
    static func catalog(kind: String) -> [[String: Any]] {
      [kind == "series" ? series() : movie()]
        + (1...7).map { index in
          item(
            id: episodeID(season: kind == "series" ? 8 : 9, episode: index), kind: kind,
            title: "Test \(kind == "series" ? "Series" : "Movie") \(index) with a Longer Title")
        }
    }
    static func detail(id: UUID, offline: Bool) -> [String: Any] {
      let isSeries = id == seriesID
      let selected = isSeries ? series() : movie()
      let seasons: [[String: Any]] =
        isSeries
        ? [0, 1, 2].map { season in
          [
            "number": season,
            "episodes": (1...(season == 0 ? 2 : 8)).map { number in
              [
                "item": episode(season: season, number: number, offline: offline),
                "seasonNumber": season, "episodeNumber": number,
              ] as [String: Any]
            }, "supplements": [],
          ]
        } : []
      return [
        "item": selected,
        "metadata": [
          "mediaId": id.uuidString,
          "title": selected["title"]!, "overview": selected["overview"]!, "year": 2026,
          "runtimeMinutes": 90, "genres": ["Drama"],
        ], "seasons": seasons, "supplements": [],
      ]
    }
  }

  actor TVUITestTransport: TVHTTPTransport {
    let scenario: TVUITestScenario
    private var saved: [UUID: [String: Any]] = [:]
    init(scenario: TVUITestScenario) { self.scenario = scenario }

    func execute(_ request: URLRequest, trust: TVTrustMode) async throws -> TVHTTPResponse {
      guard let url = request.url, url.host == "fixture.invalid" else {
        throw TVCoreError.invalidAddress
      }
      let path = url.path
      var status = 200
      let body: Any
      if path == "/api/v1/profiles" {
        body = [
          "formatVersion": 2, "minimumClientVersion": "1.5.1", "managementSetupRequired": false,
          "profiles": [
            [
              "id": TVUITestFixtures.profileID.uuidString, "name": "Test Viewer",
              "role": "viewer", "needsPinSetup": false, "pinProtectionEnabled": true,
            ],
            [
              "id": TVUITestFixtures.movieID.uuidString, "name": "Another Viewer with a Long Name",
              "role": "viewer", "needsPinSetup": true, "pinProtectionEnabled": true,
            ],
          ],
        ]
      } else if path.hasSuffix("/unlock") {
        let payload =
          try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        if payload?["pin"] as? String != "1234" {
          status = 401
          body = ["code": "invalid_profile_pin", "message": "Incorrect PIN."]
        } else {
          let data = try JSONEncoder().encode(TVUITestFixtures.session)
          return TVHTTPResponse(
            statusCode: 200, headers: [:], body: data, fingerprint: TVUITestFixtures.fingerprint)
        }
      } else if path == "/api/v1/catalog/items" {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let kind = query.first { $0.name == "kind" }?.value ?? "movie"
        let offset = Int(query.first { $0.name == "offset" }?.value ?? "0") ?? 0
        let all = TVUITestFixtures.catalog(kind: kind)
        body = [
          "items": Array(all.dropFirst(offset)), "offset": offset,
          "limit": 60, "total": all.count, "revision": "fixture-1",
        ]
      } else if path.hasPrefix("/api/v1/catalog/items/") {
        if scenario == .delayed { try await Task.sleep(for: .seconds(1.5)) }
        let id = UUID(uuidString: url.lastPathComponent)!
        body = TVUITestFixtures.detail(id: id, offline: scenario == .offline)
      } else if path.hasSuffix("/playback-plan") {
        let id = UUID(uuidString: url.pathComponents[url.pathComponents.count - 2])!
        body = [
          "target": id == TVUITestFixtures.seriesID
            ? TVUITestFixtures.episode(season: 2, number: 2, offline: scenario == .offline)
            : TVUITestFixtures.movie(),
          "seriesId": id == TVUITestFixtures.seriesID ? id.uuidString as Any : NSNull(),
          "queue": [], "action": "resume", "continueWatchingEligible": true,
        ]
      } else if path.hasSuffix("/playback") && request.httpMethod == "POST" {
        let id = UUID(uuidString: url.pathComponents[url.pathComponents.count - 2])!
        body = [
          "id": UUID().uuidString, "mediaId": id.uuidString,
          "streamPath": "/api/v1/streams/" + String(repeating: "S", count: 43),
          "contentType": "video/mp4", "contentLength": 1_000_000,
          "expiresAt": TVUITestFixtures.expiry,
          "progress": saved[id] ?? TVUITestFixtures.progress(id: id),
        ]
      } else if path.hasSuffix("/progress") {
        let id = UUID(uuidString: url.pathComponents[url.pathComponents.count - 2])!
        if request.httpMethod == "PUT" {
          let payload =
            try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
          let revision = (payload["expectedRevision"] as? NSNumber)?.int64Value ?? 0
          let position = (payload["positionMilliseconds"] as? NSNumber)?.int64Value ?? 0
          saved[id] = TVUITestFixtures.progress(
            id: id, position: position,
            revision: revision + 1, mutation: payload["clientMutationId"] as? String)
        }
        body = saved[id] ?? TVUITestFixtures.progress(id: id)
      } else if request.httpMethod == "DELETE" || path == "/api/v1/profile/end" {
        return TVHTTPResponse(
          statusCode: 204, headers: [:], body: Data(), fingerprint: TVUITestFixtures.fingerprint)
      } else {
        throw TVCoreError.invalidResponse
      }
      return TVHTTPResponse(
        statusCode: status, headers: ["Content-Type": "application/json"],
        body: try JSONSerialization.data(withJSONObject: body),
        fingerprint: TVUITestFixtures.fingerprint)
    }
  }
#endif
