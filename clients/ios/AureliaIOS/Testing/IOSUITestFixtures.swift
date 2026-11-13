#if DEBUG
  import Foundation

  enum IOSUITestScenario: String, Sendable {
    case library, profiles, delayed, offline, limitedTracks, nextEpisode, showcase, admin
    static var current: Self? {
      guard ProcessInfo.processInfo.arguments.contains("--aurelia-ui-testing") else { return nil }
      return ProcessInfo.processInfo.environment["AURELIA_IOS_UI_SCENARIO"].flatMap(
        Self.init(rawValue:))
    }
  }

  enum IOSUITestFixtures {
    static let serverID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let profileID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let movieID = UUID(uuidString: "00000000-0000-4000-8000-000000000010")!
    static let seriesID = UUID(uuidString: "00000000-0000-4000-8000-000000000020")!
    static let resumeID = episodeID(season: 2, episode: 2)
    static let trailerID = UUID(uuidString: "00000000-0000-4000-8000-000000000060")!
    static let extraID = UUID(uuidString: "00000000-0000-4000-8000-000000000061")!
    static let seasonExtraID = UUID(uuidString: "00000000-0000-4000-8000-000000000062")!
    static let fingerprint = String(repeating: "A", count: 64)
    static let expiry = "2099-01-01T00:00:00Z"
    static let stamp = "2026-01-01T00:00:00Z"
    static var connection: IOSStoredConnection {
      IOSStoredConnection(
        serverID: serverID, name: "Synthetic Server",
        baseURL: URL(string: "https://fixture.invalid:43111")!, fingerprint: fingerprint,
        deviceToken: String(repeating: "D", count: 43), deviceSessionID: serverID)
    }
    /// The owner, for the "admin" scenario's Settings screens.
    static var ownerSession: IOSProfileSession {
      IOSProfileSession(
        user: IOSUser(id: profileID, username: "Alex", role: "owner"),
        sessionId: profileID, token: String(repeating: "P", count: 43), expiresAt: expiry)
    }
    static var session: IOSProfileSession {
      IOSProfileSession(
        user: IOSUser(id: profileID, username: "Test Viewer", role: "viewer"),
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
    static func supplement(id: UUID, kind: String, title: String, category: String, season: Int?)
      -> [String: Any]
    {
      [
        "item": item(id: id, kind: kind, title: title), "category": category,
        "seasonNumber": season.map { $0 as Any } ?? NSNull(),
      ]
    }
    static func credits() -> [[String: Any]] {
      let rows: [[Any]] = [
        ["Lead Actor", "Acting", NSNull(), "Main Character", 0, "lead"],
        ["Support Actor", "Acting", NSNull(), "Best Friend", 1, "support"],
        ["Lead Actor", "Writing", "Writer", NSNull(), 4, "lead"],
        ["Synthetic Director", "Directing", "Director", NSNull(), 9, "director"],
      ]
      return rows.map { value in
        [
          "name": value[0], "department": value[1], "job": value[2], "character": value[3],
          "order": value[4], "profile": NSNull(), "personKey": value[5],
        ]
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
            },
            "supplements": season == 2
              ? [
                supplement(
                  id: seasonExtraID, kind: "extra", title: "Season Two Recap",
                  category: "Featurette", season: 2)
              ] : [],
          ]
        } : []
      return [
        "item": selected,
        "metadata": [
          "mediaId": id.uuidString,
          "title": selected["title"]!, "overview": selected["overview"]!, "year": 2026,
          "runtimeMinutes": 90, "genres": ["Drama"], "credits": credits(),
          "studios": ["Synthetic Studio"], "countries": ["US"], "fskAge": 12,
        ], "seasons": seasons,
        "supplements": [
          supplement(
            id: trailerID, kind: "trailer", title: "Official Trailer", category: "Trailer",
            season: nil),
          supplement(
            id: extraID, kind: "extra", title: "Behind the Scenes", category: "Featurette",
            season: nil),
        ],
      ]
    }
  }

  actor IOSUITestTransport: IOSHTTPTransport {
    let scenario: IOSUITestScenario
    private var saved: [UUID: [String: Any]] = [:]
    private var favorites = Set<UUID>()
    private var hidden = Set<UUID>()
    private var watched = Set<UUID>()
    private var watchlist = Set<UUID>()
    private var revision = 1
    private func item(_ value: [String: Any]) -> [String: Any] {
      var value = value
      let id = UUID(uuidString: value["id"] as! String)!
      value["isFavorite"] = favorites.contains(id)
      value["continueWatchingHidden"] = hidden.contains(id)
      if let progress = saved[id] {
        value["progress"] = progress
        value["watchState"] =
          progress["isCompleted"] as? Bool == true
          ? "completed"
          : (progress["positionMilliseconds"] as? Int64 ?? 0) > 0 ? "inProgress" : "unplayed"
      }
      if watched.contains(id) {
        value["watchState"] = "completed"
        var state = IOSUITestFixtures.progress(id: id, position: 0)
        state["isCompleted"] = true
        value["progress"] = state
      }
      return value
    }
    private func collection() -> [String: Any] {
      [
        "id": "00000000-0000-4000-8000-000000000030", "name": "Test Collection",
        "items": [item(IOSUITestFixtures.movie()), item(IOSUITestFixtures.series())],
      ]
    }
    private func watchState(id: UUID, scope: String, season: Int?) -> [String: Any] {
      [
        "mediaId": id.uuidString, "scope": scope,
        "seasonNumber": season.map { $0 as Any } ?? NSNull(),
        "watchState": watched.contains(id) ? "completed" : "unplayed",
        "affectedCount": scope == "season" ? 8 : scope == "series" ? 16 : 1,
        "stateToken": "fixture-\(revision)", "continueWatchingHidden": hidden.contains(id),
      ]
    }
    init(scenario: IOSUITestScenario) { self.scenario = scenario }

    func execute(_ request: URLRequest, trust: IOSTrustMode) async throws -> IOSHTTPResponse {
      guard let url = request.url, url.host == "fixture.invalid" else {
        throw IOSCoreError.invalidAddress
      }
      let path = url.path
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      func parameter(_ key: String) -> String? { query.first { $0.name == key }?.value }
      let payload =
        request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        ?? [:]
      if scenario == .admin,
        let answer = IOSAdminFixture.answer(
          path: path, method: request.httpMethod ?? "GET",
          query: Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first }))
      {
        return IOSHTTPResponse(
          statusCode: 200, headers: ["Content-Type": "application/json"],
          body: try JSONSerialization.data(withJSONObject: answer, options: [.fragmentsAllowed]),
          fingerprint: IOSUITestFixtures.fingerprint)
      }
      var status = 200
      let body: Any
      if path == "/api/v1/profiles" {
        body = [
          "formatVersion": 2, "minimumClientVersion": "1.5.1", "managementSetupRequired": false,
          "profiles": [
            [
              "id": IOSUITestFixtures.profileID.uuidString, "name": "Test Viewer",
              "role": "viewer", "needsPinSetup": false, "pinProtectionEnabled": true,
            ],
            [
              "id": IOSUITestFixtures.movieID.uuidString, "name": "Another Viewer with a Long Name",
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
          let data = try JSONEncoder().encode(IOSUITestFixtures.session)
          return IOSHTTPResponse(
            statusCode: 200, headers: [:], body: data, fingerprint: IOSUITestFixtures.fingerprint)
        }
      } else if path == "/api/v1/home" {
        body = [
          "continueWatching": hidden.contains(IOSUITestFixtures.seriesID)
            ? []
            : [
              item(IOSUITestFixtures.episode(season: 2, number: 2, offline: scenario == .offline))
            ],
          "recentlyAdded": [item(IOSUITestFixtures.movie()), item(IOSUITestFixtures.series())],
          "favorites": favorites.isEmpty ? [] : [item(IOSUITestFixtures.movie())],
          "collections": [collection()], "recommendationChangesAt": IOSUITestFixtures.expiry,
        ]
      } else if path == "/api/v1/catalog/collections" {
        body = parameter("offset") == "0" ? [collection()] : []
      } else if path == "/api/v1/sync/changes" {
        try await Task.sleep(for: .seconds(1))
        body = [
          "cursor": revision, "resetRequired": false, "changedAreas": [], "changedMediaIds": [],
          "generation": "fixture",
        ]
      } else if path == "/api/v1/catalog/items" || path == "/api/v1/catalog/search" {
        let kind = parameter("kind")
        let offset = Int(parameter("offset") ?? "0") ?? 0
        let limit = Int(parameter("limit") ?? "60") ?? 60
        var all =
          (kind.map { IOSUITestFixtures.catalog(kind: $0) }
          ?? (IOSUITestFixtures.catalog(kind: "movie") + IOSUITestFixtures.catalog(kind: "series")))
          .map(item)
        if let term = parameter("query"), !term.isEmpty {
          all = all.filter { ($0["title"] as? String ?? "").localizedCaseInsensitiveContains(term) }
        }
        if parameter("favorite") == "true" {
          all = all.filter { $0["isFavorite"] as? Bool == true }
        }
        if let status = parameter("watchState") {
          all = all.filter {
            $0["watchState"] as? String == status
              || ($0["id"] as? String == IOSUITestFixtures.seriesID.uuidString
                && status == "inProgress")
          }
        }
        body = [
          "items": Array(all.dropFirst(offset).prefix(limit)), "offset": offset,
          "limit": limit, "total": all.count, "revision": "fixture-\(revision)",
        ]
      } else if path.hasSuffix("/summary") {
        let id = UUID(uuidString: url.pathComponents[url.pathComponents.count - 2])!
        body = item(
          id == IOSUITestFixtures.seriesID ? IOSUITestFixtures.series() : IOSUITestFixtures.movie())
      } else if path.hasPrefix("/api/v1/catalog/items/") {
        if scenario == .delayed { try await Task.sleep(for: .seconds(1.5)) }
        let id = UUID(uuidString: url.lastPathComponent)!
        var detail = IOSUITestFixtures.detail(id: id, offline: scenario == .offline)
        detail["item"] = item(detail["item"] as! [String: Any])
        body = detail
      } else if path.hasSuffix("/favorite") {
        let id = UUID(uuidString: url.pathComponents[url.pathComponents.count - 2])!
        if payload["isFavorite"] as? Bool == true {
          favorites.insert(id)
        } else {
          favorites.remove(id)
        }
        revision += 1
        body = favorites.contains(id)
      } else if path.hasSuffix("/watch-state") || path.hasSuffix("/continue-watching") {
        let id = UUID(uuidString: url.pathComponents[url.pathComponents.count - 2])!
        let scope =
          payload["scope"] as? String ?? parameter("scope")
          ?? (id == IOSUITestFixtures.seriesID ? "series" : "title")
        let season = payload["seasonNumber"] as? Int ?? parameter("seasonNumber").flatMap(Int.init)
        if request.httpMethod == "PUT" {
          if path.hasSuffix("/continue-watching") {
            if payload["isHidden"] as? Bool == true { hidden.insert(id) } else { hidden.remove(id) }
          } else {
            if payload["isWatched"] as? Bool == true {
              watched.insert(id)
            } else {
              watched.remove(id)
              saved[id] = IOSUITestFixtures.progress(id: id, position: 0)
            }
          }
          revision += 1
        }
        body = watchState(id: id, scope: scope, season: season)
      } else if path.hasSuffix("/playback-plan") {
        let id = UUID(uuidString: url.pathComponents[url.pathComponents.count - 2])!
        let isSeries = id == IOSUITestFixtures.seriesID
        let selectedEpisode = (0...2).flatMap { season in
          (1...8).map { IOSUITestFixtures.episode(season: season, number: $0) }
        }.first { $0["id"] as? String == id.uuidString }
        let target =
          isSeries
          ? IOSUITestFixtures.episode(season: 2, number: 2, offline: scenario == .offline)
          : selectedEpisode ?? IOSUITestFixtures.movie()
        let regular = target["seasonNumber"] as? Int ?? 0 > 0
        let number = target["episodeNumber"] as? Int ?? 8
        let remaining =
          regular && number < 8
          ? ((number + 1)...8).map { IOSUITestFixtures.episode(season: 2, number: $0) } : []
        body = [
          "target": item(target),
          "seriesId": isSeries || selectedEpisode != nil
            ? IOSUITestFixtures.seriesID.uuidString as Any : NSNull(),
          "queue": remaining.map(item), "action": "resume", "continueWatchingEligible": true,
        ]
      } else if path.hasSuffix("/playback") && request.httpMethod == "POST" {
        let id = UUID(uuidString: url.pathComponents[url.pathComponents.count - 2])!
        body = [
          "id": UUID().uuidString, "mediaId": id.uuidString,
          "streamPath": "/api/v1/streams/" + String(repeating: "S", count: 43),
          "contentType": "video/mp4", "contentLength": 1_000_000,
          "expiresAt": IOSUITestFixtures.expiry,
          "progress": saved[id]
            ?? IOSUITestFixtures.progress(id: id, position: scenario == .nextEpisode ? 0 : 90_000),
        ]
      } else if path.hasSuffix("/progress") {
        let id = UUID(uuidString: url.pathComponents[url.pathComponents.count - 2])!
        if request.httpMethod == "PUT" {
          let payload =
            try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
          let revision = (payload["expectedRevision"] as? NSNumber)?.int64Value ?? 0
          let position = (payload["positionMilliseconds"] as? NSNumber)?.int64Value ?? 0
          saved[id] = IOSUITestFixtures.progress(
            id: id, position: position,
            revision: revision + 1, mutation: payload["clientMutationId"] as? String)
          saved[id]?["isCompleted"] = payload["isFinished"] as? Bool ?? false
        }
        body = saved[id] ?? IOSUITestFixtures.progress(id: id)
      } else if path == "/api/v1/watchlist" {
        let items = watchlist.map { id in
          let itemPayload =
            id == IOSUITestFixtures.seriesID
            ? IOSUITestFixtures.series()
            : IOSUITestFixtures.movie()
          return item(itemPayload)
        }
        body = [
          "items": items,
          "mediaIds": Array(watchlist).map(\.uuidString),
        ]
      } else if path.hasSuffix("/watchlist") && request.httpMethod == "PUT" {
        let id = UUID(uuidString: url.pathComponents[url.pathComponents.count - 2])!
        let isWatchlisted = payload["isWatchlisted"] as? Bool ?? false
        if isWatchlisted { watchlist.insert(id) } else { watchlist.remove(id) }
        body = [
          "mediaId": id.uuidString,
          "isWatchlisted": isWatchlisted,
        ]
      } else if path == "/api/v1/catalog/person" {
        let name = parameter("name") ?? "Unknown"
        body = [
          "name": name,
          "subtitle": "Actor",
          "profile": NSNull(),
          "items": [item(IOSUITestFixtures.movie())],
        ]
      } else if path == "/api/v1/history", request.httpMethod != "DELETE" {
        let now = Date()
        let entries: [(UUID, String, String?, Int, Bool, Double)] = [
          (IOSUITestFixtures.movieID, "Aurelia Test Movie", "2026", 2_700, false, 0),
          (
            IOSUITestFixtures.episodeID(season: 2, episode: 1), "The First Synthetic Episode",
            "Aurelia Test Series · S2E1", 2_880, true, 1
          ),
        ]
        body = [
          "items": entries.map { id, title, eyebrow, seconds, completed, daysAgo in
            [
              "id": UUID().uuidString, "mediaId": id.uuidString, "title": title,
              "eyebrow": eyebrow as Any, "year": 2026, "kind": completed ? "episode" : "movie",
              "poster": NSNull(),
              "watchedAt": ISO8601DateFormatter().string(
                from: now.addingTimeInterval(-daysAgo * 86_400 - 3_600)),
              "positionMilliseconds": seconds * 1_000, "durationMilliseconds": 5_400_000,
              "secondsWatched": seconds, "isCompleted": completed,
            ] as [String: Any]
          },
          "offset": 0, "limit": 50, "total": entries.count,
        ]
      } else if path == "/api/v1/statistics" {
        body = [
          "totalHoursWatched": 52.4, "hoursPast7Days": 3.25, "hoursPast30Days": 14.5,
          "hoursByWeek": (0..<12).map { week in
            ["period": "2026-W\(32 + week)", "hours": Double((week * 7) % 9) + 0.5]
          },
          "topTitles": [
            ["name": "Aurelia Test Series", "count": 14, "hours": 11.2],
            ["name": "Aurelia Test Movie", "count": 2, "hours": 3.1],
          ],
          "topGenres": [["name": "Drama", "count": 16, "hours": 14.3]],
          "currentStreakDays": 3, "longestStreakDays": 9, "busiestWeekday": "Saturday",
          "completionRate": 82.0, "yearsAvailable": [2025, 2026],
        ]
      } else if path.hasPrefix("/api/v1/statistics/year/") {
        body = [
          "year": Int(url.lastPathComponent) ?? 2026, "totalHoursWatched": 40.5,
          "titlesWatched": 12, "moviesWatched": 4, "episodesWatched": 31,
          "topGenre": "Drama", "topTitle": "Aurelia Test Series",
        ]
      } else if path.contains("/scrub-previews/") {
        return IOSHTTPResponse(
          statusCode: 503, headers: [:], body: Data(), fingerprint: IOSUITestFixtures.fingerprint)
      } else if request.httpMethod == "DELETE" || path == "/api/v1/profile/end" {
        return IOSHTTPResponse(
          statusCode: 204, headers: [:], body: Data(), fingerprint: IOSUITestFixtures.fingerprint)
      } else {
        throw IOSCoreError.invalidResponse
      }
      return IOSHTTPResponse(
        statusCode: status, headers: ["Content-Type": "application/json"],
        body: try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed]),
        fingerprint: IOSUITestFixtures.fingerprint)
    }
  }
#endif
