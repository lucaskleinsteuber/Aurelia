import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var profile: StoredServerProfile?
  @Published private(set) var inspectedServer: InspectedServer?
  @Published private(set) var movies: [MovieSummary] = []
  @Published private(set) var series: [SeriesSummary] = []
  @Published private(set) var playback: PlaybackPresentation?
  @Published private(set) var isStarting = true
  @Published private(set) var isWorking = false
  @Published var errorMessage: String?

  private let store: KeychainServerStore
  private var hasStarted = false

  init(store: KeychainServerStore = KeychainServerStore()) {
    self.store = store
  }

  func start() async {
    guard !hasStarted else { return }
    hasStarted = true

    #if DEBUG
      if Self.uiTestMode == "library" {
        profile = Self.previewProfile
        movies = [
          MovieSummary(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            title: "El Camino",
            year: 2019,
            availability: .available)
        ]
        series = [
          SeriesSummary(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            title: "Breaking Bad",
            availability: .available,
            seasonCount: 5,
            episodeCount: 62)
        ]
        isStarting = false
        return
      }
      if Self.uiTestMode == "pairing" {
        isStarting = false
        return
      }
    #endif

    do {
      profile = try store.load()
      if profile != nil {
        try await refresh()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
    isStarting = false
  }

  func inspect(address: String) async {
    isWorking = true
    errorMessage = nil
    inspectedServer = nil
    defer { isWorking = false }
    do {
      let baseURL = try APIClient.normalizedServerURL(address)
      inspectedServer = try await APIClient.inspect(baseURL: baseURL)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func inspect(discovered: DiscoveredServer) async {
    await inspect(address: discovered.baseURL.absoluteString)
  }

  func cancelInspection() {
    inspectedServer = nil
    errorMessage = nil
  }

  func pair(code: String) async -> Bool {
    guard let inspectedServer else { return false }
    let normalizedCode = code.filter(\.isNumber)
    guard normalizedCode.count == 8 else {
      errorMessage = "Enter the eight-digit pairing code."
      return false
    }

    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let paired = try await APIClient.pair(
        inspected: inspectedServer,
        code: normalizedCode,
        deviceName: Host.current().localizedName ?? "Mac")
      try store.save(paired)
      profile = paired
      self.inspectedServer = nil
      try await refresh()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func refresh() async throws {
    guard let profile else { return }
    isWorking = true
    defer { isWorking = false }
    let client = APIClient(profile: profile)
    let info = try await client.serverInfo()
    guard info.serverId == profile.serverId else {
      throw APIClientError.serverIdentityMismatch
    }
    async let loadedMovies = client.movies()
    async let loadedSeries = client.series()
    movies = try await loadedMovies
    series = try await loadedSeries
  }

  func refreshFromUI() async {
    errorMessage = nil
    do {
      try await refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func movieDetail(id: UUID) async throws -> MovieDetailResponse {
    #if DEBUG
      if Self.uiTestMode == "library" {
        return MovieDetailResponse(
          id: id,
          title: "El Camino - A Breaking Bad Movie",
          year: 2019,
          availability: .available,
          supplements: [
            SupplementSummary(
              id: UUID(uuidString: "10000000-0000-0000-0000-000000000010")!,
              title: "Official Trailer",
              kind: .trailer,
              category: "Trailers",
              seasonNumber: nil,
              availability: .available)
          ])
      }
    #endif
    guard let profile else { throw APIClientError.invalidResponse }
    return try await APIClient(profile: profile).movie(id: id)
  }

  func seriesDetail(id: UUID) async throws -> SeriesDetailResponse {
    #if DEBUG
      if Self.uiTestMode == "library" {
        return SeriesDetailResponse(
          id: id,
          title: "Breaking Bad",
          availability: .available,
          seasons: [
            SeasonSummary(
              number: 1,
              episodes: [
                EpisodeSummary(
                  id: UUID(uuidString: "20000000-0000-0000-0000-000000000010")!,
                  title: "Pilot",
                  seasonNumber: 1,
                  episodeNumber: 1,
                  availability: .available)
              ],
              supplements: [])
          ],
          supplements: [
            SupplementSummary(
              id: UUID(uuidString: "20000000-0000-0000-0000-000000000020")!,
              title: "Behind the Scenes",
              kind: .extra,
              category: "Special Features",
              seasonNumber: nil,
              availability: .available)
          ])
      }
    #endif
    guard let profile else { throw APIClientError.invalidResponse }
    return try await APIClient(profile: profile).series(id: id)
  }

  func startPlayback(mediaId: UUID, title: String, subtitle: String? = nil) {
    guard profile != nil else { return }
    playback = PlaybackPresentation(mediaId: mediaId, title: title, subtitle: subtitle)
  }

  func closePlayback() {
    playback = nil
  }

  func disconnect() async {
    let current = profile
    profile = nil
    movies = []
    series = []
    inspectedServer = nil
    playback = nil
    errorMessage = nil
    if Self.uiTestMode == nil {
      try? store.delete()
      if let current {
        try? await APIClient(profile: current).logout()
      }
    }
  }

  #if DEBUG
    private static let previewProfile = StoredServerProfile(
      serverId: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
      name: "Aurelia Home",
      baseURL: URL(string: "https://aurelia-home.local:43111")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      token: "ui-test-token",
      sessionId: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
      expiresAt: "2099-01-01T00:00:00Z")
  #endif

  private static var uiTestMode: String? {
    #if DEBUG
      ProcessInfo.processInfo.environment["AURELIA_HOME_UI_TEST_MODE"]
    #else
      nil
    #endif
  }
}
