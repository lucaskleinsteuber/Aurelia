import Foundation
import Testing

@Suite("TV night mode, per-series tracks and end time")
struct TVPlayerComfortTests {
  @Test func endTimeFollowsRemainingTimeAndRate() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)  // 08:00 UTC
    let utc = TimeZone(identifier: "UTC")!
    let english = Locale(identifier: "en_GB")
    let normal = TVPlayerPolicy.endTimeLabel(
      position: 600_000, duration: 3_000_000, rate: 1, now: now, locale: english, timeZone: utc)
    #expect(normal == "Ends at 8:40", "\(normal ?? "nil")")
    // At double speed the remaining 40 minutes take 20.
    let fast = TVPlayerPolicy.endTimeLabel(
      position: 600_000, duration: 3_000_000, rate: 2, now: now, locale: english, timeZone: utc)
    #expect(fast == "Ends at 8:20", "\(fast ?? "nil")")
    #expect(TVPlayerPolicy.endTimeLabel(position: 0, duration: 0, rate: 1, now: now) == nil)
  }

  @Test func preferencesSavedBeforeNightModeKeepTheirValues() throws {
    let saved = Data(#"{"automaticResume":false,"seekInterval":30}"#.utf8)
    let value = try JSONDecoder().decode(TVPlaybackPreferences.self, from: saved)
    #expect(!value.automaticResume)
    #expect(value.seekInterval == 30)
    #expect(!value.nightMode)
    var changed = value
    changed.nightMode = true
    let roundTrip = try JSONDecoder().decode(
      TVPlaybackPreferences.self, from: JSONEncoder().encode(changed))
    #expect(roundTrip.nightMode)
  }

  @Test @MainActor func trackChoicesAreRememberedPerSeries() throws {
    let suite = "Aurelia-TV-Series-Tracks-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TVPlaybackPreferencesStore(defaults: defaults)
    let server = UUID()
    let profile = UUID()
    let breakingBad = UUID()
    let topGear = UUID()
    let english = TVPlaybackTrack(id: 1, title: "English [eng]").preference
    let german = TVPlaybackTrack(id: 2, title: "Deutsch [ger]").preference

    store.updateSeriesChoice(seriesID: breakingBad, serverID: server, profileID: profile) {
      $0.audio = english
      $0.subtitle = german
      $0.subtitleChosen = true
    }
    store.updateSeriesChoice(seriesID: topGear, serverID: server, profileID: profile) {
      $0.audio = german
      $0.subtitle = nil
      $0.subtitleChosen = true
    }

    var profileDefaults = TVPlaybackPreferences()
    profileDefaults.preferredAudioTrack = german
    profileDefaults.preferredSubtitleTrack = english
    let bad = profileDefaults.applying(
      store.seriesChoice(seriesID: breakingBad, serverID: server, profileID: profile))
    #expect(bad.preferredAudioTrack == english)
    #expect(bad.preferredSubtitleTrack == german)
    // Subtitles turned off in one series stay off there.
    let gear = profileDefaults.applying(
      store.seriesChoice(seriesID: topGear, serverID: server, profileID: profile))
    #expect(gear.preferredSubtitleTrack == nil)
    // Another series, another profile or a movie keeps the profile's last choice.
    #expect(profileDefaults.applying(nil) == profileDefaults)
    #expect(store.seriesChoice(seriesID: breakingBad, serverID: server, profileID: UUID()) == nil)

    store.forgetSeriesChoices(serverID: server, profileID: profile)
    #expect(store.seriesChoice(seriesID: breakingBad, serverID: server, profileID: profile) == nil)
  }
}
