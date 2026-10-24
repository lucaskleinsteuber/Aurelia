#if DEBUG
  import Foundation

  // README screenshots: a fictional library from scripts/make-showcase.swift in server-format JSON
  // with generated pictures. AURELIA_SHOWCASE_DIR is a folder, or the loopback address where
  // scripts/capture-showcase.sh serves it, because the sandboxed app cannot read that folder.
  // Opt-in, in memory, no server, media or personal data.
  @MainActor enum ShowcaseUITestFixture {
    static var directory: URL? {
      let environment = ProcessInfo.processInfo.environment
      guard environment["AURELIA_UI_TEST_MODE"] == "library-admin",
        let path = environment["AURELIA_SHOWCASE_DIR"], !path.isEmpty
      else { return nil }
      return path.hasPrefix("http://127.0.0.1:")
        ? URL(string: path) : URL(fileURLWithPath: path, isDirectory: true)
    }
    static var enabled: Bool { directory != nil }

    static let profile = StoredServerProfile(
      serverId: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
      name: "Home Server",
      baseURL: URL(string: "https://127.0.0.1:43111")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      token: "showcase-token",
      sessionId: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
      expiresAt: "2099-01-01T00:00:00Z",
      user: UserSummary(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
        username: "Alex", role: .owner, createdAt: "2099-01-01T00:00:00Z"))

    private struct Page: Decodable { let items: [CatalogItemSummary] }

    private static func load<Value: Decodable>(_ type: Value.Type, _ name: String) -> Value? {
      guard let directory,
        let data = try? Data(contentsOf: directory.appendingPathComponent(name))
      else { return nil }
      return try? JSONDecoder().decode(type, from: data)
    }

    static var home: HomeResponse? { load(HomeResponse.self, "home.json") }
    static var catalog: [CatalogItemSummary] {
      load(Page.self, "catalog-all.json")?.items ?? []
    }
    static var movies: [MovieSummary] {
      catalog.filter { $0.kind == .movie }.map {
        MovieSummary(id: $0.id, title: $0.title, year: $0.year, availability: $0.availability)
      }
    }
    static var series: [SeriesSummary] {
      catalog.filter { $0.kind == .series }.map { item in
        let seasons = detail(item.id)?.seasons ?? []
        return SeriesSummary(
          id: item.id, title: item.title, availability: item.availability,
          seasonCount: seasons.count, episodeCount: seasons.map(\.episodes.count).reduce(0, +))
      }
    }
    static func detail(_ id: UUID) -> CatalogDetailPresentation? {
      load(CatalogDetailPresentation.self, "items/\(id.uuidString.lowercased()).json")
    }
    /// The generated picture behind an artwork path such as /api/v1/artwork/<id>.
    static func artwork(path: String) -> Data? {
      guard let directory, let id = path.split(separator: "?")[0].split(separator: "/").last,
        let uuid = UUID(uuidString: String(id))
      else { return nil }
      return try? Data(
        contentsOf: directory.appendingPathComponent(
          "artwork/\(uuid.uuidString.lowercased()).jpg"))
    }
  }
#endif
