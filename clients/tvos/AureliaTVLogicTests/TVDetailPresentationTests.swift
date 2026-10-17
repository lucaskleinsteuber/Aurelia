import Foundation
import Testing

@Suite("TV detail presentation")
struct TVDetailPresentationTests {
  @Test func creditsMergePeopleAndKeepBillingOrder() {
    let credits = [
      credit("Director", department: "Directing", job: "Director", order: 9, key: "d"),
      credit("Lead", department: "Acting", character: "Walter", order: 0, key: "a"),
      credit("Lead", department: "Writing", job: "Writer", order: 5, key: "a"),
      credit("Lead", department: "Acting", character: "Heisenberg", order: 1, key: "a"),
      credit("Support", department: "Acting", character: "Jesse", order: 2, key: nil),
    ]
    let people = TVDetailPresentation.people(credits)
    #expect(people.map(\.name) == ["Lead", "Support", "Director"])
    #expect(people[0].subtitle == "Walter, Heisenberg")
    #expect(people[2].subtitle == "Director")
  }

  @Test func trailersComeBeforeExtrasInServerOrder() {
    let groups = TVDetailPresentation.supplementGroups([
      supplement("Behind the Scenes", kind: .extra, category: "Featurette"),
      supplement("Teaser", kind: .extra, category: "Teaser Trailer"),
      supplement("Official Trailer", kind: .trailer, category: "Trailer"),
      supplement("Deleted Scene", kind: .extra, category: "Deleted Scenes"),
    ])
    #expect(groups.map(\.title) == ["Trailers", "Extras"])
    #expect(groups[0].items.map(\.item.title) == ["Teaser", "Official Trailer"])
    #expect(groups[1].items.map(\.item.title) == ["Behind the Scenes", "Deleted Scene"])
    #expect(TVDetailPresentation.supplementGroups([]).isEmpty)
  }

  @Test func informationSkipsEmptyFieldsAndCountsSeriesSeasons() {
    let movie = detail(kind: .movie, seasons: [])
    let fields = Dictionary(
      uniqueKeysWithValues: TVDetailPresentation.information(movie).map { ($0.title, $0.value) })
    #expect(fields["Runtime"] == "47 min")
    #expect(fields["Studio"] == "Synthetic Studio, Second Studio")
    #expect(fields["Country of Origin"] == "US")
    #expect(fields["Rating"] == "FSK 16")
    #expect(fields["Seasons"] == nil)

    let series = detail(
      kind: .series,
      seasons: [
        TVSeason(number: 0, episodes: [], supplements: []),
        TVSeason(number: 1, episodes: [], supplements: []),
        TVSeason(number: 2, episodes: [], supplements: []),
      ])
    let seriesFields = Dictionary(
      uniqueKeysWithValues: TVDetailPresentation.information(series).map { ($0.title, $0.value) })
    #expect(seriesFields["Seasons"] == "2", "Specials are not counted as a season.")
    #expect(seriesFields["Runtime"] == nil)
  }

  @Test func genreRowsAreAlphabeticalLimitedAndUnique() {
    let rows = TVDetailPresentation.genreRows(
      [
        item("A", genres: ["Drama", " Crime ", "Drama"]), item("B", genres: ["Action"]),
        item("C", genres: ["Crime", ""]), item("D", genres: ["Western"]),
      ], limit: 3)
    #expect(rows.map(\.genre) == ["Action", "Crime", "Drama"])
    #expect(rows[1].items.map(\.title) == ["A", "C"])
    #expect(rows[2].items.map(\.title) == ["A"], "An item appears once per genre.")
    #expect(TVDetailPresentation.genreRows([item("A", genres: ["Drama"])], limit: 0).isEmpty)
  }

  @Test func metadataWithoutNewerFieldsStillDecodes() throws {
    let json = Data(
      #"{"mediaId":"00000000-0000-4000-8000-000000000001","title":"Old","genres":[]}"#.utf8)
    let metadata = try JSONDecoder().decode(TVMediaMetadata.self, from: json)
    #expect(metadata.credits == nil && metadata.studios == nil && metadata.fskAge == nil)
  }

  private func credit(
    _ name: String, department: String, job: String? = nil, character: String? = nil,
    order: Int, key: String?
  ) -> TVCredit {
    TVCredit(
      name: name, department: department, job: job, character: character, order: order,
      profile: nil, id: nil, personKey: key)
  }

  private func item(_ title: String, kind: TVMediaKind = .movie, genres: [String] = [])
    -> TVCatalogItem
  {
    TVCatalogItem(
      id: UUID(), kind: kind, title: title, originalTitle: nil, year: 2026, overview: nil,
      genres: genres, poster: nil, backdrop: nil, availability: .available, isFavorite: false,
      progress: nil, addedAt: "2026-01-01T00:00:00Z", parentTitle: nil, seasonNumber: nil,
      episodeNumber: nil, parentId: nil, watchState: "unplayed", libraryAvailability: .available)
  }

  private func supplement(_ title: String, kind: TVMediaKind, category: String) -> TVSupplement {
    TVSupplement(item: item(title, kind: kind), category: category, seasonNumber: nil)
  }

  private func detail(kind: TVMediaKind, seasons: [TVSeason]) -> TVCatalogDetail {
    let item = item("Synthetic", kind: kind, genres: ["Drama"])
    return TVCatalogDetail(
      item: item,
      metadata: TVMediaMetadata(
        mediaId: item.id, title: "Synthetic", originalTitle: nil, overview: nil, releaseDate: nil,
        year: 2026, runtimeMinutes: 47, rating: nil, contentRating: "TV-14", genres: ["Drama"],
        poster: nil, backdrop: nil, still: nil, credits: [],
        studios: ["Synthetic Studio", "Second Studio"], countries: ["", "US"], fskAge: 16),
      seasons: seasons, supplements: [])
  }
}
