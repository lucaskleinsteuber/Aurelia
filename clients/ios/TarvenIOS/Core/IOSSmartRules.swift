import Foundation

/// A Smart List's rules, written in the protocol's names (`SmartCollectionRules`: kind, genres,
/// yearMin, yearMax, decade, ratingMin, watchedState, addedWithinDays, favoritesOnly,
/// watchlistOnly, textContains, combination). Lists the Mac saved in its older names are read too.
struct IOSSmartRules: Codable, Equatable, Sendable {
  /// "movie", "series" or nil for both.
  var kind: String?
  var genres: [String] = []
  var yearMin: Int?
  var yearMax: Int?
  /// The first year of a decade, such as 1990.
  var decade: Int?
  /// 0 to 10, TMDB's rating.
  var ratingMin: Double?
  /// "watched", "unwatched", "inProgress" or nil for any.
  var watchedState: String?
  var addedWithinDays: Int?
  var favoritesOnly = false
  var watchlistOnly = false
  var textContains: String?
  /// "and": every rule; "or": any rule.
  var combination = "and"

  static let decades = Array(stride(from: 2020, through: 1920, by: -10))
  static let addedChoices = [7, 30, 90, 365]

  init() {}

  private enum CodingKeys: String, CodingKey {
    case kind, genres, yearMin, yearMax, decade, ratingMin, watchedState, addedWithinDays
    case favoritesOnly, watchlistOnly, textContains, combination
    case watched, watchState, search, match
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decodeIfPresent(String.self, forKey: .kind)?.lowercased() {
    case "movie", "movies": kind = "movie"
    case "series", "show", "shows", "tv": kind = "series"
    default: kind = nil
    }
    genres = (try values.decodeIfPresent([String].self, forKey: .genres)) ?? []
    yearMin = try values.decodeIfPresent(Int.self, forKey: .yearMin)
    yearMax = try values.decodeIfPresent(Int.self, forKey: .yearMax)
    decade = try values.decodeIfPresent(Int.self, forKey: .decade)
    ratingMin = try values.decodeIfPresent(Double.self, forKey: .ratingMin)
    let watched =
      try values.decodeIfPresent(String.self, forKey: .watchedState)
      ?? values.decodeIfPresent(String.self, forKey: .watchState)
      ?? values.decodeIfPresent(String.self, forKey: .watched)
    switch watched?.lowercased().replacingOccurrences(of: "_", with: "") {
    case "unwatched", "unplayed": watchedState = "unwatched"
    case "inprogress": watchedState = "inProgress"
    case "watched", "completed": watchedState = "watched"
    default: watchedState = nil
    }
    addedWithinDays = try values.decodeIfPresent(Int.self, forKey: .addedWithinDays)
    favoritesOnly = (try values.decodeIfPresent(Bool.self, forKey: .favoritesOnly)) ?? false
    watchlistOnly = (try values.decodeIfPresent(Bool.self, forKey: .watchlistOnly)) ?? false
    textContains =
      try values.decodeIfPresent(String.self, forKey: .textContains)
      ?? values.decodeIfPresent(String.self, forKey: .search)
    if let combination = try values.decodeIfPresent(String.self, forKey: .combination) {
      self.combination = combination.lowercased() == "or" ? "or" : "and"
    } else if let match = try values.decodeIfPresent(String.self, forKey: .match) {
      combination = ["any", "or", "matchany"].contains(match.lowercased()) ? "or" : "and"
    }
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encodeIfPresent(kind, forKey: .kind)
    if !cleanGenres.isEmpty { try values.encode(cleanGenres, forKey: .genres) }
    try values.encodeIfPresent(yearMin, forKey: .yearMin)
    try values.encodeIfPresent(yearMax, forKey: .yearMax)
    try values.encodeIfPresent(decade, forKey: .decade)
    try values.encodeIfPresent(ratingMin, forKey: .ratingMin)
    try values.encodeIfPresent(watchedState, forKey: .watchedState)
    try values.encodeIfPresent(addedWithinDays, forKey: .addedWithinDays)
    if favoritesOnly { try values.encode(true, forKey: .favoritesOnly) }
    if watchlistOnly { try values.encode(true, forKey: .watchlistOnly) }
    try values.encodeIfPresent(cleanText, forKey: .textContains)
    try values.encode(combination, forKey: .combination)
  }

  private var cleanGenres: [String] {
    var seen = Set<String>()
    return genres.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
  }

  private var cleanText: String? {
    let text = textContains?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return text.isEmpty ? nil : text
  }

  /// The rules from a list's saved text; unreadable or missing text gives no rules.
  static func decode(_ json: String?) -> Self {
    guard let data = json?.data(using: .utf8),
      let rules = try? JSONDecoder().decode(Self.self, from: data)
    else { return Self() }
    return rules
  }

  var json: String? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  var hasRules: Bool {
    kind != nil || !cleanGenres.isEmpty || yearMin != nil || yearMax != nil || decade != nil
      || ratingMin != nil || watchedState != nil || addedWithinDays != nil || favoritesOnly
      || watchlistOnly || cleanText != nil
  }

  /// What stops the save, such as a year range the wrong way round.
  var problem: String? {
    if let yearMin, let yearMax, yearMin > yearMax { return "The first year comes after the last." }
    for year in [yearMin, yearMax].compactMap({ $0 }) where !(1800...3000).contains(year) {
      return "Years go from 1800 to 3000."
    }
    if let ratingMin, !(0...10).contains(ratingMin) { return "Ratings go from 0 to 10." }
    if !hasRules { return "Add at least one rule, so the list knows what to show." }
    return nil
  }

  /// "Movies · Drama · 1990s · Unwatched", the rules in a line.
  var summary: String {
    var parts: [String] = []
    if let kind { parts.append(kind == "movie" ? "Movies" : "Shows") }
    parts.append(contentsOf: cleanGenres)
    if let decade { parts.append("\(decade)s") }
    switch (yearMin, yearMax) {
    case (let low?, let high?): parts.append("\(low)–\(high)")
    case (let low?, nil): parts.append("From \(low)")
    case (nil, let high?): parts.append("Until \(high)")
    default: break
    }
    if let ratingMin { parts.append("Rated \(ratingMin.formatted()) or more") }
    switch watchedState {
    case "watched": parts.append("Watched")
    case "unwatched": parts.append("Unwatched")
    case "inProgress": parts.append("In Progress")
    default: break
    }
    if let addedWithinDays { parts.append("Added in the last \(addedWithinDays) days") }
    if favoritesOnly { parts.append("Favorites") }
    if watchlistOnly { parts.append("Watchlist") }
    if let cleanText { parts.append("“\(cleanText)”") }
    guard !parts.isEmpty else { return "No rules yet" }
    return parts.joined(separator: combination == "or" ? " or " : " · ")
  }
}
