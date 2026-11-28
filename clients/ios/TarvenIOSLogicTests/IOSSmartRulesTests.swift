import Foundation
import Testing

/// Smart Lists on iPhone and iPad: their rules in the protocol's names, lists saved by older Mac
/// versions, and what stops a save.
@Suite struct IOSSmartRulesTests {
  @Test func rulesTravelInTheProtocolsNames() throws {
    var rules = IOSSmartRules()
    rules.kind = "movie"
    rules.genres = [" Drama ", "drama", ""]
    rules.decade = 1990
    rules.watchedState = "unwatched"
    rules.favoritesOnly = true
    rules.textContains = "  night "
    rules.combination = "or"
    let json = try #require(rules.json)
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(object["kind"] as? String == "movie")
    #expect(object["genres"] as? [String] == ["Drama"])
    #expect(object["decade"] as? Int == 1990)
    #expect(object["watchedState"] as? String == "unwatched")
    #expect(object["favoritesOnly"] as? Bool == true)
    #expect(object["watchlistOnly"] == nil)
    #expect(object["textContains"] as? String == "night")
    #expect(object["combination"] as? String == "or")
    #expect(rules.summary == "Movies or Drama or 1990s or Unwatched or Favorites or “night”")
  }

  @Test func listsSavedByOlderMacVersionsAreRead() {
    let rules = IOSSmartRules.decode(
      #"{"kind":"movies","watched":"completed","search":"Invented","match":"any","yearMin":1980}"#)
    #expect(rules.kind == "movie")
    #expect(rules.watchedState == "watched")
    #expect(rules.textContains == "Invented")
    #expect(rules.combination == "or")
    #expect(rules.yearMin == 1980)
    #expect(IOSSmartRules.decode(nil) == IOSSmartRules())
    #expect(IOSSmartRules.decode("not json") == IOSSmartRules())
  }

  @Test func impossibleRulesStopTheSave() {
    var rules = IOSSmartRules()
    #expect(rules.problem?.contains("at least one rule") == true)
    rules.yearMin = 2010
    rules.yearMax = 2000
    #expect(rules.problem == "The first year comes after the last.")
    rules.yearMax = 2020
    #expect(rules.problem == nil)
    rules.ratingMin = 11
    #expect(rules.problem == "Ratings go from 0 to 10.")
  }
}
