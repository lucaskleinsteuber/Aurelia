#if DEBUG
  import AppKit
  import Foundation

  // Invented library for scripts/audit-render-screens.sh, which draws screens offscreen to PNG
  // files so they can be checked for visual bugs. Every answer is made here in memory: no server,
  // no media, no personal data and no network. Long and Unicode titles find truncation bugs.
  @MainActor enum AuditRenderFixture {
    nonisolated static var enabled: Bool {
      ProcessInfo.processInfo.environment["AURELIA_UI_TEST_MODE"] == "audit-render"
    }

    /// Set per screen: empty lists, or every answer failing like an unreachable server.
    static var emptyData = false
    static var failing = false
    private static var unanswered: [String] = []

    /// A request no fixture answers: the page shows an error that only the fixture causes.
    static func noteUnanswered(_ request: String) {
      if !unanswered.contains(request) { unanswered.append(request) }
    }

    static func takeUnanswered() -> [String] {
      defer { unanswered = [] }
      return unanswered
    }

    // MARK: Identities

    private static func id(_ group: Int, _ number: Int) -> UUID {
      UUID(uuidString: String(format: "A%07d-0000-0000-0000-%012d", group, number))!
    }

    static let serverId = id(0, 1)
    static let ownerUser = UserSummary(
      id: id(0, 2), username: "owner", role: .owner, createdAt: "2026-01-01T00:00:00Z",
      displayName: "Maximilian-Alexander Øhlenschläger von Hohenzollern-Sigmaringen",
      pictureKey: "symbol:sparkles:violet")
    static let memberUser = UserSummary(
      id: id(0, 3), username: "zoe", role: .user, createdAt: "2026-01-02T00:00:00Z",
      displayName: "Zoë", ageLimit: 12)

    /// The address never answers: every request is served by `response` before it is sent.
    static let baseURL = URL(string: "https://127.0.0.1:9")!

    static func profile(user: UserSummary = ownerUser, viewing: Bool = true) -> StoredServerProfile
    {
      StoredServerProfile(
        serverId: serverId, name: "Ünïcødé Heimkino-Server in der Dachgeschosswohnung",
        baseURL: baseURL, publicKeyFingerprint: String(repeating: "A", count: 64),
        token: "audit-render-token", sessionId: id(0, 4), expiresAt: "2099-01-01T00:00:00Z",
        user: user, viewingSession: viewing)
    }

    static let capabilities: Set<String> = [
      "watchlist-people-v1", "artwork-variants-v1", "server-readiness-v1",
      "device-authorization-v1", "security-v1",
      ServerFeatureNames.wishes, ServerFeatureNames.people,
      ServerFeatureNames.yearWrapped, ServerFeatureNames.monthlyWrapped,
      ServerFeatureNames.profilePersonalization, ServerFeatureNames.ageLimits,
      ServerFeatureNames.screenTime, ServerFeatureNames.mediaSegments,
      ServerFeatureNames.serverSpeech, ServerFeatureNames.fileChecks,
      ServerFeatureNames.convertedDownloads, ServerFeatureNames.suggestions,
    ]

    // MARK: Titles

    static let longTitle: String = {
      let base =
        "The Extraordinarily Long and Winding Chronicle of a Lighthouse Keeper Who Counted Every "
        + "Single Wave Along the Northern Coast Before the Dawn Finally Came Home"
      return String(base.prefix(140))
    }()

    static let unicodeMovieID = id(1, 1)
    static let longMovieID = id(1, 2)
    static let missingMovieID = id(1, 6)
    static let seriesID = id(2, 1)

    private static func artwork(_ owner: UUID, _ kind: ArtworkKind) -> ArtworkSummary {
      let number: Int
      switch kind {
      case .poster: number = 1
      case .backdrop: number = 2
      case .still: number = 3
      case .profile: number = 4
      }
      let digits = owner.uuidString.suffix(6)
      return ArtworkSummary(
        id: UUID(uuidString: "B000000\(number)-0000-0000-0000-000000\(digits)")!, kind: kind,
        path: "/api/v1/artwork/B000000\(number)-0000-0000-0000-000000\(digits)",
        contentType: "image/png", contentLength: 4096)
    }

    private static func progress(_ id: UUID, _ fraction: Double) -> PlaybackProgressResponse {
      PlaybackProgressResponse(
        mediaId: id, positionMilliseconds: Int64(7_200_000 * fraction),
        durationMilliseconds: 7_200_000, isCompleted: false,
        lastPlayedAt: "2026-11-20T20:00:00Z", updatedAt: "2026-11-20T20:00:00Z")
    }

    private static func movie(
      _ id: UUID, _ title: String, _ year: Int, genres: [String], overview: String,
      availability: MediaAvailability = .available, favorite: Bool = false,
      progress fraction: Double? = nil, artwork: Bool = true
    ) -> CatalogItemSummary {
      CatalogItemSummary(
        id: id, kind: .movie, title: title, originalTitle: nil, year: year, overview: overview,
        genres: genres, poster: artwork ? self.artwork(id, .poster) : nil,
        backdrop: artwork ? self.artwork(id, .backdrop) : nil, availability: availability,
        isFavorite: favorite, progress: fraction.map { progress(id, $0) },
        addedAt: "2026-11-1\(id.uuidString.last.map(String.init) ?? "0")T08:00:00Z")
    }

    static let movies: [CatalogItemSummary] = [
      movie(
        unicodeMovieID, "Ünïcødé Fjörd – Ärger im Ødland", 2023, genres: ["Drama", "Thriller"],
        overview:
          "Ågot Bjørnstad kehrt nach zwanzig Jahren in ihr Heimatdorf am Fjord zurück – und findet "
          + "dort ein Geheimnis, das älter ist als die Ölbohrinsel vor der Küste.",
        favorite: true, progress: 0.42),
      movie(
        longMovieID, longTitle, 2021, genres: ["Adventure", "Mystery", "Historical Drama"],
        overview: String(
          repeating: "A lighthouse keeper writes down every wave he sees, night after night. ",
          count: 6), progress: 0.87),
      movie(
        id(1, 3), "Nachtzug nach Kraków", 2019, genres: ["Romance"],
        overview: "Zwei Fremde, ein Schlafwagen und eine Grenze, die nicht schläft."),
      movie(
        id(1, 4), "東京の夜明け (Tokyo Dawn)", 2022, genres: ["Animation", "Family"],
        overview: "夜明け前の東京で、少女は失われた猫を探す。"),
      movie(
        id(1, 5), "مدينة الرمال", 2020, genres: ["Documentary"],
        overview: "رحلة عبر مدينة تغيرها الرمال كل يوم."),
      movie(
        missingMovieID, "Offline: Der verschollene Film", 2018, genres: ["Drama"],
        overview: "The drive with this title is disconnected; it keeps its place in the library.",
        availability: .missing),
      movie(
        id(1, 7), "Up", 2009, genres: ["Animation"], overview: "Short title.", artwork: false),
      movie(
        id(1, 8), "Zoë & Chloé: Ein Sommer am Ærøskøbing-Hafen", 2024,
        genres: ["Comedy", "Romance", "Coming of Age", "Summer"],
        overview: "Zwei Cousinen, ein Fahrrad mit drei Gängen und viel zu viel Sonnencreme."),
    ]

    static let series: [CatalogItemSummary] = [
      CatalogItemSummary(
        id: seriesID, kind: .series, title: "Die Ölmühle von Åsgårdstrand", originalTitle: nil,
        year: 2024, overview: "Eine Familie, eine Mühle und drei Generationen voller Streit.",
        genres: ["Drama", "Family"], poster: artwork(seriesID, .poster),
        backdrop: artwork(seriesID, .backdrop), availability: .available, isFavorite: false,
        progress: nil, addedAt: "2026-11-18T08:00:00Z"),
      CatalogItemSummary(
        id: id(2, 2), kind: .series,
        title: "Signals from the Very Distant Northern Lighthouse Archipelago", originalTitle: nil,
        year: 2025, overview: "Strange radio signals reach a tiny island every winter.",
        genres: ["Science Fiction"], poster: artwork(id(2, 2), .poster),
        backdrop: artwork(id(2, 2), .backdrop), availability: .available, isFavorite: true,
        progress: nil, addedAt: "2026-11-19T08:00:00Z"),
    ]

    private static let episodeTitles = [
      "Pilot", "Der Müller und das Meer",
      "Ein außergewöhnlich langer Episodentitel, der in keiner Zeile Platz findet – oder doch?",
      "Ærø", "Ölpreis", "Schnee über Åsgårdstrand", "Die Rückkehr", "Finale – Teil 1",
    ]

    static func episodes(season: Int) -> [CatalogItemSummary] {
      let count = season == 1 ? 8 : season == 2 ? 5 : 1
      return (1...count).map { number in
        let identifier = id(3, season * 100 + number)
        return CatalogItemSummary(
          id: identifier, kind: .episode, title: episodeTitles[(number - 1) % episodeTitles.count],
          originalTitle: nil, year: 2023 + season,
          overview: "Episode \(number) der Staffel \(season): Ärger, Öl und Übermut.",
          genres: ["Drama"], poster: nil, backdrop: artwork(identifier, .still),
          availability: season == 3 ? .missing : .available, isFavorite: false,
          progress: season == 1 && number == 2 ? progress(identifier, 0.3) : nil,
          addedAt: "2026-11-18T08:00:00Z", parentTitle: series[0].title, seasonNumber: season,
          episodeNumber: number, parentId: seriesID)
      }
    }

    static var catalog: [CatalogItemSummary] { emptyData ? [] : movies + series }

    static var collections: [CollectionSummary] {
      if emptyData { return [] }
      var nordic = CollectionSummary(
        id: id(4, 1), name: "Nordic Nights ✦ Skandinavische Klassiker für lange Winterabende",
        poster: artwork(id(4, 1), .poster), items: [movies[0], movies[2], series[0]])
      nordic.overview = "Filme und Serien aus dem hohen Norden – mit Ø, Å und Æ."
      nordic.itemCount = 3
      nordic.totalCount = 3
      var smart = CollectionSummary(
        id: id(4, 2), name: "Unwatched", poster: nil, items: Array(movies.prefix(5)))
      smart.isSmart = true
      smart.itemCount = 5
      smart.totalCount = 5
      return [nordic, smart]
    }

    static var home: HomeResponse {
      if emptyData {
        return HomeResponse(
          recommendation: nil, continueWatching: [], recentlyAdded: [], favorites: [],
          collections: [], recommendationChangesAt: "2099-01-01T00:00:00Z")
      }
      return HomeResponse(
        recommendation: series[0],
        continueWatching: [movies[0], movies[1], episodes(season: 1)[1]],
        recentlyAdded: catalog, favorites: catalog.filter(\.isFavorite),
        collections: collections, recommendationChangesAt: "2099-01-01T00:00:00Z")
    }

    static func summary(_ id: UUID) -> CatalogItemSummary? {
      (movies + series + (1...3).flatMap(episodes(season:))).first { $0.id == id }
    }

    private static let credits: [CreditSummary] = [
      ("Ågot Bjørnstad-Kierkegaard", "Acting", "Ågot"),
      ("Björk Guðmundsdóttir", "Acting", "Die Müllerin"),
      ("渡辺 健", "Acting", "Kenji"),
      ("Jean-Baptiste Emmanuel Zorg de la Montagne-Sainte-Geneviève", "Acting", "Der Erzähler"),
      ("Søren Østergaard", "Directing", nil),
    ].enumerated().map { index, entry in
      CreditSummary(
        name: entry.0, department: entry.1, job: entry.1 == "Directing" ? "Director" : nil,
        character: entry.2, order: index, profile: nil, personKey: "tmdb:\(9000 + index)")
    }

    static func detail(_ id: UUID) -> CatalogDetailPresentation? {
      guard let item = summary(id) else { return nil }
      let metadata = MediaMetadataSummary(
        mediaId: item.id, title: item.title, originalTitle: item.originalTitle,
        overview: item.overview, releaseDate: item.year.map { "\($0)-03-14" }, year: item.year,
        runtimeMinutes: item.kind == .movie ? 128 : 52, rating: 7.8, contentRating: "FSK 12",
        genres: item.genres, studios: ["Nordlys Filmproduksjon AS", "Ölmühlen-Studios GmbH"],
        countries: ["Norway", "Germany"], credits: credits, poster: item.poster,
        backdrop: item.backdrop, still: nil, provider: "TMDB", providerMediaId: "audit",
        reviewState: .matched, fskAge: 12)
      let seasons: [SeasonPresentation] =
        item.id == seriesID
        ? (1...3).map { season in
          SeasonPresentation(
            number: season,
            episodes: episodes(season: season).map {
              EpisodePresentation(
                item: $0, seasonNumber: season, episodeNumber: $0.episodeNumber ?? 1)
            }, supplements: [])
        } : []
      let trailer = CatalogItemSummary(
        id: UUID(uuidString: "C" + item.id.uuidString.dropFirst())!, kind: .trailer,
        title: "Offizieller Trailer – Ünïcødé Edition", originalTitle: nil, year: item.year,
        overview: nil, genres: [], poster: nil, backdrop: nil, availability: .available,
        isFavorite: false, progress: nil, addedAt: "2026-11-18T08:00:00Z")
      return CatalogDetailPresentation(
        item: item, metadata: metadata, seasons: seasons,
        supplements: item.kind == .episode
          ? [] : [SupplementPresentation(item: trailer, category: "Trailer", seasonNumber: nil)],
        franchise: item.id == unicodeMovieID ? collections.first : nil)
    }

    static let person = PersonSelection(
      name: credits[0].name, personKey: credits[0].personKey, profile: nil, subtitle: "Acting")

    static var watchingProfiles: [WatchingProfile] {
      [
        WatchingProfile(
          id: ownerUser.id, name: ownerUser.displayName ?? "owner", role: .owner,
          needsPinSetup: false, pictureKey: "symbol:sparkles:violet"),
        WatchingProfile(
          id: memberUser.id, name: "Zoë", role: .user, needsPinSetup: false, ageLimit: 12),
        WatchingProfile(
          id: id(0, 5), name: "Øystein", role: .admin, needsPinSetup: true,
          pinProtectionEnabled: true),
        WatchingProfile(
          id: id(0, 6), name: "Kinderzimmer – Gute Nacht", role: .user, needsPinSetup: false,
          pinProtectionEnabled: false, ageLimit: 6, closedUntil: "2099-01-01T07:00:00Z"),
        WatchingProfile(
          id: id(0, 7), name: "渡辺", role: .user, needsPinSetup: false),
      ]
    }

    // MARK: Answers

    /// The answer for a request, or nil when this fixture does not know the path.
    static func response(path: String, method: String, body: Data?) throws -> Data? {
      if failing {
        throw APIClientError.serverRejected(
          code: "audit_unreachable",
          message: "The server could not be reached. (Synthetic audit error)")
      }
      let route = String(path.split(separator: "?", maxSplits: 1).first ?? "")
      let encoder = JSONEncoder()
      if method == "GET", route.hasPrefix("/api/v1/artwork/") || route.contains("/editor/artwork/")
      {
        return picture(for: route)
      }
      if route == "/api/v1/metadata/reviews" || route.hasSuffix("/editor") {
        return try MetadataEditorUITestFixture.response(path: route, method: method, body: body)
      }
      guard method == "GET" else { return nil }
      switch route {
      case "/api/v1/profiles":
        let profiles = watchingProfiles.map { profile in
          """
          {"id":"\(profile.id.uuidString)","name":"\(profile.name)","role":"\(profile.role.rawValue)",
          "needsPinSetup":\(profile.needsPinSetup),"pinProtectionEnabled":\(profile.pinProtectionEnabled),
          "pictureKey":\(profile.pictureKey.map { "\"\($0)\"" } ?? "null"),"pictureRevision":0,
          "ageLimit":\(profile.ageLimit.map(String.init) ?? "null"),
          "closedUntil":\(profile.closedUntil.map { "\"\($0)\"" } ?? "null")}
          """
        }
        return Data(
          """
          {"formatVersion":1,"minimumClientVersion":"1.0.0","managementSetupRequired":false,
          "profiles":[\(profiles.joined(separator: ","))]}
          """.utf8)
      case "/api/v1/devices/players": return Data("[]".utf8)
      case "/api/v1/server/info":
        return try encoder.encode(
          ServerInfoResponse(
            serverId: serverId, name: profile().name, version: "2.27.0", isSetup: true,
            lanAccessEnabled: true, lanHttpsPort: 43_111,
            publicKeyFingerprint: String(repeating: "A", count: 64),
            displayFingerprint: "AAAA-AAAA-AAAA-AAAA-AAAA-AAAA"))
      case "/api/v1/home": return try encoder.encode(home)
      case "/api/v1/catalog/collections": return try encoder.encode(collections)
      case "/api/v1/catalog/person":
        return try encoder.encode(
          PersonDetailResponse(
            name: person.name, subtitle: "Acting · 3 titles", profile: nil,
            items: emptyData ? [] : [movies[0], movies[2], series[0]]))
      case "/api/v1/people":
        let people =
          emptyData
          ? []
          : credits.map {
            PersonSummary(
              name: $0.name, personKey: $0.personKey ?? "", profile: nil,
              titleCount: 3 + $0.order, department: $0.department)
          }
        return try encoder.encode(
          PeoplePageResponse(items: people, total: people.count, offset: 0, limit: 60))
      case "/api/v1/people/profile":
        return try encoder.encode(
          PersonProfileResponse(
            about: PersonAbout(
              biography: String(
                repeating:
                  "Geboren in einem Dorf am Fjord, spielte sie zuerst Theater in Ålesund. ",
                count: 5),
              birthday: "1981-02-29", deathday: nil,
              placeOfBirth: "Ålesund, Møre og Romsdal, Norge",
              knownForDepartment: "Acting", provider: "TMDB", providerPersonId: "9000"),
            knownFor: []))
      case "/api/v1/wishes": return try encoder.encode(wishes)
      case "/api/v1/wishes/summary":
        return try encoder.encode(
          WishSummaryResponse(openCount: emptyData ? 0 : 2, newlyFulfilledCount: emptyData ? 0 : 1))
      case "/api/v1/history":
        return try encoder.encode(
          WatchHistoryPage(items: emptyData ? [] : history, offset: 0, limit: 50, total: 3))
      case "/api/v1/statistics": return try encoder.encode(statistics)
      case "/api/v1/watchlist":
        return try encoder.encode(
          WatchlistResponse(
            items: emptyData ? [] : [movies[2], series[1]],
            mediaIds: emptyData ? [] : [movies[2].id, series[1].id]))
      default:
        if route.hasPrefix("/api/v1/statistics/year/"), route.hasSuffix("/wrapped") {
          return try encoder.encode(wrapped)
        }
        if route.hasPrefix("/api/v1/statistics/year/") {
          return try encoder.encode(
            YearInReview(
              year: 2025, totalHoursWatched: emptyData ? 0 : 612.5, titlesWatched: 140,
              moviesWatched: 52, episodesWatched: 88, topGenre: "Drama",
              topTitle: emptyData ? nil : longTitle, busiestDay: "2025-12-24",
              busiestDayHours: 9.5))
        }
        let parts = route.split(separator: "/").map(String.init)
        if parts.count >= 5, parts[2] == "catalog", parts[3] == "items",
          let item = UUID(uuidString: parts[4])
        {
          if parts.count == 6, parts[5] == "summary" {
            return try summary(item).map { try encoder.encode($0) }
          }
          return try detail(item).map { try encoder.encode($0) }
        }
        if parts.count == 4, parts[2] == "collections", let collection = UUID(uuidString: parts[3]),
          let summary = collections.first(where: { $0.id == collection })
        {
          var detail = CollectionDetail(id: summary.id, name: summary.name)
          detail.overview = summary.overview
          detail.poster = summary.poster
          detail.backdrop = summary.backdrop ?? summary.items.first?.backdrop
          detail.isSmart = summary.isSmart
          detail.itemCount = summary.items.count
          detail.watchedCount = 1
          detail.yearRange = "2019–2024"
          detail.totalRuntimeSeconds = 7 * 3600 + 23 * 60
          detail.genres = ["Drama", "Thriller", "Family"]
          struct Member: Encodable {
            let id: UUID
            let mediaId: UUID
            let kind: MediaKind
            let title: String
            let item: CatalogItemSummary
          }
          detail.members = try JSONDecoder().decode(
            [CollectionMember].self,
            from: encoder.encode(
              summary.items.map {
                Member(id: $0.id, mediaId: $0.id, kind: $0.kind, title: $0.title, item: $0)
              }))
          return try encoder.encode(detail)
        }
        return nil
      }
    }

    private static var wishes: WishListResponse {
      func wish(
        _ number: Int, _ title: String, _ state: WishState, note: String?, supporters: Int
      ) -> WishSummary {
        WishSummary(
          id: id(5, number), userId: memberUser.id, userName: "Zoë", kind: .movie,
          provider: "TMDB", providerMediaId: "\(number)", title: title, year: 2020 + number,
          overview: "Ein Wunsch mit Ümlauten und einem sehr langen Überblickstext.",
          posterPath: nil, posterUrl: nil, ageRating: "FSK 6", minimumAge: 6, note: note,
          state: state, resolvedByUserId: state == .open ? nil : ownerUser.id,
          resolvedByUserName: state == .open ? nil : "Maximilian-Alexander",
          resolutionNote: state == .declined ? "Leider nicht mehr erhältlich." : nil,
          fulfilledMediaItemId: state == .fulfilled ? movies[2].id : nil,
          createdAt: "2026-11-0\(number)T10:00:00Z",
          resolvedAt: state == .open ? nil : "2026-11-1\(number)T10:00:00Z", seenByWisherAt: nil,
          canSupport: true, supportedByCaller: number == 1,
          supporters: (0..<supporters).map {
            WishSupportPerson(userId: id(6, $0), name: ["Øystein", "渡辺", "Zoë"][$0 % 3])
          }, suggestions: [])
      }
      let list =
        emptyData
        ? []
        : [
          wish(
            1, "Ünïcødé Fjörd II – Die Rückkehr ins Ødland", .open, note: "Bitte bald!",
            supporters: 3),
          wish(
            2, longTitle, .open, note: String(repeating: "Sehr wichtig. ", count: 12), supporters: 0
          ),
          wish(3, "Nachtzug nach Kraków", .fulfilled, note: nil, supporters: 1),
          wish(4, "Der abgelehnte Wunsch", .declined, note: nil, supporters: 0),
        ]
      return WishListResponse(
        wishes: list, openCount: emptyData ? 0 : 2, newlyFulfilledCount: emptyData ? 0 : 1,
        providerEnabled: true)
    }

    private static var history: [WatchHistoryItem] {
      [movies[0], movies[1], episodes(season: 1)[2]].enumerated().map { index, item in
        WatchHistoryItem(
          id: id(7, index), mediaId: item.id, title: item.title,
          eyebrow: item.kind == .episode
            ? "\(item.parentTitle ?? "") · S1E\(item.episodeNumber ?? 1)"
            : item.year.map(String.init),
          year: item.year, kind: item.kind.rawValue, poster: item.poster,
          watchedAt: "2026-11-2\(index)T21:00:00Z", positionMilliseconds: 3_000_000,
          durationMilliseconds: 7_200_000, secondsWatched: 3000, isCompleted: index == 1)
      }
    }

    private static var statistics: UserStatistics {
      UserStatistics(
        totalHoursWatched: emptyData ? 0 : 1234.5, hoursPast7Days: emptyData ? 0 : 12.25,
        hoursPast30Days: emptyData ? 0 : 48,
        hoursByWeek: emptyData
          ? []
          : (1...12).map { PeriodHours(period: "2026-W\(30 + $0)", hours: Double($0 % 5) * 2.5) },
        hoursByMonth: emptyData
          ? []
          : (1...11).map {
            PeriodHours(period: "2026-\(String(format: "%02d", $0))", hours: Double($0) * 3)
          },
        topGenres: emptyData
          ? []
          : [
            NamedCount(name: "Drama", count: 42, hours: 80),
            NamedCount(name: "Science Fiction & Fantasy", count: 12, hours: 20),
          ],
        topTitles: emptyData ? [] : [NamedCount(name: movies[0].title, count: 3, hours: 6)],
        currentStreakDays: emptyData ? 0 : 7, longestStreakDays: emptyData ? 0 : 31,
        busiestWeekday: "Sunday", busiestTimeOfDay: "Evening", completionRate: 0.73,
        yearsAvailable: emptyData ? [] : [2025, 2026])
    }

    private static var wrapped: YearWrapped {
      YearWrapped(
        year: 2025, profileName: "Maximilian-Alexander",
        slides: [
          WrappedSlide(
            kind: "hours", eyebrow: "Dein Jahr", headline: "Du hast sehr viel geschaut",
            bigNumber: "1.234", unit: "Stunden", detail: "Das sind 51 Tage am Stück.",
            quip: "Ein Sofa mit Ölmühlen-Blick.", accent: "violet", mediaId: nil, poster: nil,
            posters: nil, facts: [WrappedFact(label: "Filme", value: "87")]),
          WrappedSlide(
            kind: "title", eyebrow: "Dein Lieblingstitel", headline: longTitle, bigNumber: nil,
            unit: nil, detail: nil, quip: "Dreimal gesehen.", accent: "orange",
            mediaId: movies[1].id, poster: movies[1].poster, posters: nil, facts: nil),
        ])
    }

    // MARK: Pictures

    private static var pictures: [String: Data] = [:]

    /// A generated gradient with the artwork's kind written on it; posters are 2:3, the rest 16:9.
    private static func picture(for path: String) -> Data {
      if let cached = pictures[path] { return cached }
      let isPoster = path.contains("/B0000001-")
      let size = isPoster ? NSSize(width: 400, height: 600) : NSSize(width: 960, height: 540)
      var hash: UInt64 = 1_469_598_103_934_665_603
      for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
      let hue = CGFloat(hash % 360) / 360
      guard
        let bitmap = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
      else { return Data() }
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
      NSGradient(
        starting: NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1),
        ending: NSColor(
          hue: (hue + 0.18).truncatingRemainder(dividingBy: 1), saturation: 0.7,
          brightness: 0.25, alpha: 1))?
        .draw(in: NSRect(origin: .zero, size: size), angle: -60)
      let label = isPoster ? "POSTER" : path.contains("/B0000003-") ? "STILL" : "BACKDROP"
      (label as NSString).draw(
        at: NSPoint(x: 24, y: 24),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 28, weight: .heavy),
          .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ])
      NSGraphicsContext.restoreGraphicsState()
      let data = bitmap.representation(using: .png, properties: [:]) ?? Data()
      pictures[path] = data
      return data
    }
  }
#endif
