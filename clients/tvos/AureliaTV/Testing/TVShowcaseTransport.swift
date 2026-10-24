#if DEBUG
  import Foundation

  /// README screenshots: answers the library requests from the fictional showcase library that
  /// scripts/make-showcase.swift writes as server-format JSON with generated pictures.
  /// AURELIA_SHOWCASE_DIR is that folder or the loopback address scripts/capture-showcase.sh
  /// serves it from; there is no server, media or personal data.
  actor TVShowcaseTransport: TVHTTPTransport {
    static let session = TVProfileSession(
      user: TVUser(id: TVUITestFixtures.profileID, username: "Alex", role: "owner"),
      sessionId: TVUITestFixtures.profileID, token: String(repeating: "P", count: 43),
      expiresAt: TVUITestFixtures.expiry)

    private let directory: URL = {
      let path = ProcessInfo.processInfo.environment["AURELIA_SHOWCASE_DIR"] ?? ""
      return path.hasPrefix("http://127.0.0.1:")
        ? URL(string: path)! : URL(fileURLWithPath: path, isDirectory: true)
    }()

    private func file(_ name: String) throws -> Data {
      try Data(contentsOf: directory.appendingPathComponent(name))
    }

    private func object(_ name: String) throws -> Any {
      try JSONSerialization.jsonObject(with: file(name))
    }

    private func catalog() throws -> [[String: Any]] {
      (try object("catalog-all.json") as? [String: Any])?["items"] as? [[String: Any]] ?? []
    }

    func execute(_ request: URLRequest, trust: TVTrustMode) async throws -> TVHTTPResponse {
      guard let url = request.url, url.host == "fixture.invalid" else {
        throw TVCoreError.invalidAddress
      }
      let path = url.path
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      func parameter(_ key: String) -> String? { query.first { $0.name == key }?.value }
      let first = (Int(parameter("offset") ?? "0") ?? 0) == 0
      let components = url.pathComponents
      var status = 200
      let body: Any
      if path.hasPrefix("/api/v1/artwork/") {
        return TVHTTPResponse(
          statusCode: 200, headers: ["Content-Type": "image/jpeg"],
          body: try file("artwork/\(url.lastPathComponent.lowercased()).jpg"),
          fingerprint: TVUITestFixtures.fingerprint)
      } else if path == "/api/v1/home" {
        body = try object("home.json")
      } else if path == "/api/v1/catalog/collections" {
        body = first ? try object("collections.json") : []
      } else if path == "/api/v1/catalog/items" || path == "/api/v1/catalog/search" {
        var items = try catalog()
        if let kind = parameter("kind") { items = items.filter { $0["kind"] as? String == kind } }
        if let term = parameter("query"), !term.isEmpty {
          items = items.filter {
            ($0["title"] as? String ?? "").localizedCaseInsensitiveContains(term)
          }
        }
        body = [
          "items": first ? items : [], "offset": Int(parameter("offset") ?? "0") ?? 0,
          "limit": 200, "total": items.count, "revision": "showcase",
        ]
      } else if path.hasSuffix("/summary"), components.count >= 2 {
        let id = components[components.count - 2].lowercased()
        body = try catalog().first { ($0["id"] as? String)?.lowercased() == id } ?? [:]
      } else if path.hasPrefix("/api/v1/catalog/items/") {
        body = try object("items/\(url.lastPathComponent.lowercased()).json")
      } else if path.hasSuffix("/playback-plan"), components.count >= 2 {
        let id = components[components.count - 2].lowercased()
        let detail = try? object("items/\(id).json") as? [String: Any]
        let episodes =
          (detail?["seasons"] as? [[String: Any]])?.first?["episodes"] as? [[String: Any]] ?? []
        let target = episodes.first?["item"] ?? detail?["item"] ?? [:]
        body = [
          "target": target, "seriesId": episodes.isEmpty ? NSNull() : id as Any, "queue": [],
          "action": "play", "continueWatchingEligible": true,
        ]
      } else if path == "/api/v1/sync/changes" {
        try await Task.sleep(for: .seconds(25))
        body = [
          "cursor": 1, "resetRequired": false, "changedAreas": [], "changedMediaIds": [],
          "generation": "showcase",
        ]
      } else {
        status = 404
        body = ["code": "not_found", "message": "Not part of the showcase."]
      }
      return TVHTTPResponse(
        statusCode: status, headers: ["Content-Type": "application/json"],
        body: try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed]),
        fingerprint: TVUITestFixtures.fingerprint)
    }
  }
#endif
