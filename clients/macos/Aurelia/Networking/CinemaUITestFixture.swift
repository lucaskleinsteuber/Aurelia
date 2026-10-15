#if DEBUG
  import AppKit
  import SwiftUI

  // These opt-in fixtures use generated pixels and in-memory state, never media or a live server.
  @MainActor enum CinemaUITestFixture {
    static var enabled: Bool {
      ProcessInfo.processInfo.environment["AURELIA_CINEMA_UI_TESTS"] == "1"
        && ProcessInfo.processInfo.environment["AURELIA_UI_TEST_MODE"] == "library-admin"
    }
    static let assetID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    private static var notesByMedia: [UUID: [SceneNote]] = [:]
    static func sceneNotes(path: String, method: String, body: Data?) throws -> Data {
      let parts = path.split(separator: "?")[0].split(separator: "/")
      guard parts.count >= 5, let media = UUID(uuidString: String(parts[3])) else {
        throw APIClientError.invalidResponse
      }
      if method == "GET" { return try JSONEncoder().encode(notesByMedia[media] ?? []) }
      guard parts.count == 6, let id = UUID(uuidString: String(parts[5])) else {
        throw APIClientError.invalidResponse
      }
      if method == "DELETE" {
        notesByMedia[media]?.removeAll { $0.id == id }
        return Data()
      }
      struct Payload: Decodable {
        let startMilliseconds: Int64
        let endMilliseconds: Int64?
        let text: String
        let revision: Int64
      }
      guard let body else { throw APIClientError.invalidResponse }
      let request = try JSONDecoder().decode(Payload.self, from: body)
      let existing = notesByMedia[media]?.first { $0.id == id }
      guard (existing?.revision ?? 0) == request.revision else {
        throw APIClientError.serverRejected(
          code: "scene_note_conflict", message: "The scene note changed on another device.")
      }
      let note = SceneNote(
        id: id, mediaId: media, startMilliseconds: request.startMilliseconds,
        endMilliseconds: request.endMilliseconds, text: request.text, revision: request.revision + 1
      )
      var items = notesByMedia[media] ?? []
      items.removeAll { $0.id == id }
      items.append(note)
      notesByMedia[media] = items.sorted { $0.startMilliseconds < $1.startMilliseconds }
      return try JSONEncoder().encode(note)
    }
    static let artwork = ArtworkSummary(
      id: assetID, kind: .backdrop, path: "/api/v1/artwork/\(assetID)",
      contentType: "image/png", contentLength: 1)
    static let png: Data = {
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 800,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
      let context = NSGraphicsContext(bitmapImageRep: bitmap)!
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      if ProcessInfo.processInfo.environment["AURELIA_HERO_EDGE_UI_TESTS"] == "1" {
        // Narrow stripes distinguish actual image detail from a blurred filler strip.
        for x in stride(from: 0, to: 1200, by: 12) {
          (x % 24 == 0 ? NSColor.white : NSColor.systemBlue).setFill()
          NSRect(x: x, y: 0, width: 12, height: 800).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
      }
      for (index, color) in [NSColor.systemTeal, .systemOrange, .systemIndigo, .systemYellow]
        .enumerated()
      {
        color.setFill()
        NSRect(x: index % 2 * 600, y: index / 2 * 400, width: 600, height: 400).fill()
      }
      NSColor.white.setFill()
      NSBezierPath(ovalIn: NSRect(x: 700, y: 130, width: 200, height: 280)).fill()
      ("SYNTHETIC • TOP LEFT" as NSString).draw(
        at: NSPoint(x: 40, y: 710),
        withAttributes: [.font: NSFont.boldSystemFont(ofSize: 42), .foregroundColor: NSColor.white])
      NSGraphicsContext.restoreGraphicsState()
      return bitmap.representation(using: .png, properties: [:])!
    }()

    static func decorate(_ item: CatalogItemSummary) -> CatalogItemSummary {
      CatalogItemSummary(
        id: item.id, kind: item.kind, title: item.title,
        originalTitle: item.originalTitle, year: item.year, overview: item.overview,
        genres: item.genres, poster: artwork, backdrop: artwork, availability: item.availability,
        isFavorite: item.isFavorite, progress: item.progress, addedAt: item.addedAt,
        parentTitle: item.parentTitle, seasonNumber: item.seasonNumber,
        episodeNumber: item.episodeNumber)
    }
    static func home(_ base: HomeResponse) -> HomeResponse {
      guard enabled else { return base }
      let items = (1...12).map { index in
        CatalogItemSummary(
          id: UUID(uuidString: String(format: "60000000-0000-0000-0000-%012d", index))!,
          kind: .movie, title: "Generated Film \(index)", originalTitle: nil, year: 2020,
          overview: "Generated Home card for layout testing.", genres: [], poster: artwork,
          backdrop: artwork, availability: .available, isFavorite: false, progress: nil,
          addedAt: "2026-10-02T00:00:00Z")
      }
      return HomeResponse(
        recommendation: base.recommendation.map(decorate),
        continueWatching: continuationCards(base) ?? base.continueWatching.map(decorate),
        recentlyAdded: items,
        favorites: base.favorites.map(decorate),
        collections: base.collections.map {
          CollectionSummary(
            id: $0.id, name: $0.name, poster: artwork, items: $0.items.map(decorate))
        },
        recommendationChangesAt: base.recommendationChangesAt)
    }

    static var testsContinueWatching: Bool {
      enabled && ProcessInfo.processInfo.environment["AURELIA_CONTINUE_UI_TESTS"] != nil
    }

    private static let resumeEpisodeID = UUID(
      uuidString: "20000000-0000-0000-0000-000000000010")!
    private static let resumeMovieID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static var savedProgress: [UUID: PlaybackProgressResponse] = {
      guard ProcessInfo.processInfo.environment["AURELIA_CONTINUE_UI_TESTS"] == "seeded" else {
        return [:]
      }
      return Dictionary(
        uniqueKeysWithValues: [(resumeEpisodeID, Int64(30_000)), (resumeMovieID, 45_000)]
          .map { id, position in
            (
              id,
              PlaybackProgressResponse(
                mediaId: id, positionMilliseconds: position, durationMilliseconds: 120_000,
                isCompleted: false, lastPlayedAt: "2026-10-03T00:00:00Z",
                updatedAt: "2026-10-03T00:00:00Z")
            )
          })
    }()

    private static func continuationCards(_ base: HomeResponse) -> [CatalogItemSummary]? {
      guard testsContinueWatching else { return nil }
      let episodes = [
        (resumeEpisodeID, "Pilot"),
        (UUID(uuidString: "20000000-0000-0000-0000-000000000101")!, "Episode 1"),
      ]
      .map { id, title in
        CatalogItemSummary(
          id: id, kind: .episode, title: title, originalTitle: nil, year: 2008,
          overview: "A synthetic saved episode, absent from the top-level catalog.",
          genres: ["Drama"], poster: artwork, backdrop: artwork, availability: .available,
          isFavorite: false, progress: nil, addedAt: "2026-10-03T00:00:00Z",
          parentTitle: "Breaking Bad", seasonNumber: 1, episodeNumber: 1)
      }
      return (episodes + base.continueWatching).compactMap { item in
        guard let progress = savedProgress[item.id], !progress.isCompleted,
          progress.positionMilliseconds > 10_000
        else { return nil }
        return CatalogItemSummary(
          id: item.id, kind: item.kind, title: item.title, originalTitle: item.originalTitle,
          year: item.year, overview: item.overview, genres: item.genres,
          poster: artwork, backdrop: artwork, availability: item.availability,
          isFavorite: item.isFavorite, progress: progress, addedAt: item.addedAt,
          parentTitle: item.parentTitle, seasonNumber: item.seasonNumber,
          episodeNumber: item.episodeNumber)
      }
    }
    static let credits: [CreditSummary] =
      (0..<14).map { index in
        CreditSummary(
          name: index == 0 ? "Bryan Cranston" : "Person \(index)", department: "Acting",
          job: nil, character: index == 0 ? "Walter White" : "Character \(index)", order: index,
          profile: artwork, personKey: "tmdb:person:\(index)", creditId: UUID())
      } + [
        CreditSummary(
          name: "Bryan Cranston", department: "Production", job: "Producer",
          character: nil, order: 20, profile: artwork, personKey: "tmdb:person:0", creditId: UUID())
      ]

    static func detail(_ input: CatalogItemSummary) -> CatalogDetailPresentation {
      let item = decorate(input)
      let metadata = MediaMetadataSummary(
        mediaId: item.id, title: item.title, originalTitle: nil,
        overview: item.overview, releaseDate: nil, year: item.year,
        runtimeMinutes: item.kind == .movie ? 122 : nil, rating: nil, contentRating: nil,
        genres: item.genres, studios: ["Test Studio"], countries: ["US"], credits: credits,
        poster: artwork, backdrop: artwork, still: nil, provider: "TMDB",
        providerMediaId: "fixture",
        reviewState: .matched)
      let seasons: [SeasonPresentation] =
        item.kind == .series
        ? [1, 2].map { season in
          SeasonPresentation(
            number: season,
            episodes: (1...(season == 1 ? 12 : 2)).map { episode in
              let id = UUID(
                uuidString: String(format: "20000000-0000-0000-0000-%012d", season * 100 + episode))!
              let video = CatalogItemSummary(
                id: id, kind: .episode, title: "Episode \(episode)",
                originalTitle: nil, year: 2008,
                overview: "Generated episode card for layout testing.",
                genres: [], poster: nil, backdrop: artwork, availability: .available,
                isFavorite: false,
                progress: nil, addedAt: "2026-10-02T00:00:00Z", parentTitle: item.title,
                seasonNumber: season, episodeNumber: episode)
              return EpisodePresentation(item: video, seasonNumber: season, episodeNumber: episode)
            }, supplements: [])
        } : []
      let supplements = (0..<18).map { index in
        let trailer = index >= 10
        let id = UUID(uuidString: String(format: "50000000-0000-0000-0000-%012d", index + 1))!
        let video = CatalogItemSummary(
          id: id, kind: trailer ? .trailer : .extra,
          title: trailer ? "Trailer \(index - 9)" : "Extra \(index + 1)", originalTitle: nil,
          year: 2008, overview: nil, genres: [], poster: nil, backdrop: artwork,
          availability: .available, isFavorite: false, progress: nil,
          addedAt: "2026-10-02T00:00:00Z")
        return SupplementPresentation(
          item: video, category: trailer ? "Trailers" : "Extras", seasonNumber: nil)
      }
      return CatalogDetailPresentation(
        item: item, metadata: metadata, seasons: seasons, supplements: supplements)
    }

    static func player(profile: StoredServerProfile, presentation: PlaybackPresentation)
      -> PlaybackController
    {
      var preferences = PlaybackPreferences.defaultValue
      preferences.preventSleepDuringPlayback = false
      return PlaybackController(
        client: FixturePlaybackClient(profile: profile), presentation: presentation,
        engine: FixturePlaybackEngine(), preferences: preferences,
        relayFactory: { _, _ in FixturePlaybackRelay() })
    }
  }

  @MainActor private final class FixturePlaybackClient: PlaybackClientProtocol {
    let profile: StoredServerProfile
    init(profile: StoredServerProfile) { self.profile = profile }
    func createPlayback(mediaId: UUID) async throws -> PlaybackSourceResponse {
      if LibraryStateUITestFixture.enabled {
        return PlaybackSourceResponse(
          id: UUID(), mediaId: mediaId, streamPath: "/synthetic", contentType: "video/test",
          contentLength: 0, expiresAt: "2099-01-01T00:00:00Z",
          progress: LibraryStateUITestFixture.playbackProgress(mediaId: mediaId))
      }
      return PlaybackSourceResponse(
        id: UUID(), mediaId: mediaId, streamPath: "/synthetic",
        contentType: "video/test", contentLength: 0, expiresAt: "2099-01-01T00:00:00Z",
        progress: PlaybackProgressResponse(
          mediaId: mediaId,
          positionMilliseconds: CinemaUITestFixture.testsContinueWatching
            ? CinemaUITestFixture.savedProgress[mediaId]?.positionMilliseconds ?? 0 : 0,
          durationMilliseconds: 120_000, isCompleted: false, lastPlayedAt: nil, updatedAt: nil))
    }
    func updatePlaybackProgress(
      mediaId: UUID, positionMilliseconds: Int64,
      durationMilliseconds: Int64, isFinished: Bool
    ) async throws -> PlaybackProgressResponse {
      let completed = isFinished || positionMilliseconds >= durationMilliseconds - 45_000
      let result = PlaybackProgressResponse(
        mediaId: mediaId,
        positionMilliseconds: completed || positionMilliseconds <= 10_000
          ? 0 : positionMilliseconds,
        durationMilliseconds: durationMilliseconds, isCompleted: completed, lastPlayedAt: nil,
        updatedAt: nil)
      if CinemaUITestFixture.testsContinueWatching {
        CinemaUITestFixture.savedProgress[mediaId] = result
      }
      return result
    }
    func revokePlayback(id: UUID) async throws {}
    func streamURL(path: String) throws -> URL { URL(string: "https://fixture.invalid/synthetic")! }
  }
  @MainActor private final class FixturePlaybackRelay: PlaybackRelayProtocol {
    func start() async throws -> URL { URL(string: "https://fixture.invalid/synthetic")! }
    func updateSourceURL(_ url: URL) {}
    func stop() {}
  }
  @MainActor private final class FixturePlaybackEngine: PlaybackEngine {
    private var tickTask: Task<Void, Never>?
    var onUpdate: (() -> Void)?
    var onEnded: (() -> Void)?
    var onError: ((String) -> Void)?
    var isPlaying = false
    var currentTimeMilliseconds: Int64 = 0
    let durationMilliseconds: Int64 = 120_000
    var volume = 1.0
    var isMuted = false
    var playbackRate = 1.0
    let audioTracks = [
      PlaybackTrack(id: 1, title: "English"), PlaybackTrack(id: 2, title: "German"),
    ]
    let subtitleTracks = [PlaybackTrack(id: 3, title: "English SDH")]
    let chapters = [
      PlaybackChapter(
        index: 0, title: "Introduction", timeOffsetMilliseconds: 0,
        durationMilliseconds: 60_000)
    ]
    var currentChapterIndex: Int32? = 0
    var selectedAudioTrackID: Int32? = 1
    var selectedSubtitleTrackID: Int32?
    func attach(to view: NSView) {
      view.wantsLayer = true
      view.layer?.backgroundColor = NSColor.darkGray.cgColor
    }
    func load(url: URL) {}  // No URL is opened, downloaded or decoded.
    func play() {
      isPlaying = true
      onUpdate?()
      // Stress overlay/layout updates during these opt-in idle-pointer tests.
      // Other fixtures retain their deterministic, explicitly stepped timeline.
      guard ProcessInfo.processInfo.environment["AURELIA_AUTO_HIDE_UI_TESTS"] == "1",
        tickTask == nil
      else { return }
      tickTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(250))
          guard let self, !Task.isCancelled, self.isPlaying else { return }
          self.currentTimeMilliseconds += 250
          self.onUpdate?()
        }
      }
    }
    func pause() {
      isPlaying = false
      tickTask?.cancel()
      tickTask = nil
      onUpdate?()
    }
    func stop() {
      isPlaying = false
      tickTask?.cancel()
      tickTask = nil
    }
    func seek(to milliseconds: Int64) {
      currentTimeMilliseconds = milliseconds
      onUpdate?()
    }
    func selectAudioTrack(id: Int32) {
      selectedAudioTrackID = id
      onUpdate?()
    }
    func selectSubtitleTrack(id: Int32?) {
      selectedSubtitleTrackID = id
      onUpdate?()
    }
    func selectChapter(index: Int32) {
      currentChapterIndex = index
      onUpdate?()
    }
  }
#endif
