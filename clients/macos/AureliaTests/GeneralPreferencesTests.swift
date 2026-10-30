import Foundation
import Testing

@testable import Aurelia

@MainActor
struct GeneralPreferencesTests {
  @Test func settingsSavedBeforeExtendedOptionsKeepTheirDefaults() throws {
    let saved = Data(
      """
      {"automaticResume":true,"defaultPlaybackRate":1.0,"defaultVolume":1.0,
      "controlsAutoHideDelay":3,"seekInterval":15,"preventSleepDuringPlayback":true,
      "automaticallyPlayNextEpisode":true,"nightMode":false}
      """.utf8)
    let value = try JSONDecoder().decode(PlaybackPreferences.self, from: saved)
    #expect(value.upNextCountdownSeconds == 15)
    #expect(value.resumeThresholdSeconds == 10)
    #expect(value.markWatchedThresholdPercent == 90)
    #expect(value.defaultAudioLanguage == "original")
    #expect(value.defaultSubtitleLanguage == "off")
    #expect(value.subtitleSize == "medium")
    #expect(value.subtitleBackground == "transparent")

    var modified = value
    modified.upNextCountdownSeconds = 25
    modified.resumeThresholdSeconds = 15
    modified.markWatchedThresholdPercent = 95
    modified.defaultAudioLanguage = "de"
    modified.defaultSubtitleLanguage = "en"
    modified.subtitleSize = "large"
    modified.subtitleBackground = "solid"

    let roundTrip = try JSONDecoder().decode(
      PlaybackPreferences.self, from: JSONEncoder().encode(modified))
    #expect(roundTrip == modified)
  }

  @Test func upNextPolicyRespectsCustomLeadSeconds() {
    let duration: Int64 = 600_000
    let lead15s: Int64 = 15_000
    #expect(
      !UpNextPolicy.shows(
        position: 584_000, duration: duration, hasNext: true, autoplay: true, stopsAtEnd: false,
        dismissed: false, lead: lead15s))
    #expect(
      UpNextPolicy.shows(
        position: 585_000, duration: duration, hasNext: true, autoplay: true, stopsAtEnd: false,
        dismissed: false, lead: lead15s))
    #expect(
      UpNextPolicy.shows(
        position: 599_000, duration: duration, hasNext: true, autoplay: true, stopsAtEnd: false,
        dismissed: false, lead: lead15s))

    let lead5s: Int64 = 5_000
    #expect(
      !UpNextPolicy.shows(
        position: 594_000, duration: duration, hasNext: true, autoplay: true, stopsAtEnd: false,
        dismissed: false, lead: lead5s))
    #expect(
      UpNextPolicy.shows(
        position: 595_000, duration: duration, hasNext: true, autoplay: true, stopsAtEnd: false,
        dismissed: false, lead: lead5s))
  }

  @Test func generalPreferenceEnumsRoundTrip() {
    #expect(PosterSizePreference(rawValue: "standard") == .standard)
    #expect(PosterSizePreference(rawValue: "compact") == .compact)
    #expect(PosterSizePreference(rawValue: "large") == .large)

    #expect(StartScreenPreference(rawValue: "home") == .home)
    #expect(StartScreenPreference(rawValue: "library") == .library)
    #expect(StartScreenPreference(rawValue: "continueWatching") == .continueWatching)
    #expect(StartScreenPreference(rawValue: "collections") == .collections)
    #expect(StartScreenPreference(rawValue: "watchlist") == .watchlist)
    #expect(StartScreenPreference(rawValue: "movies") == .movies)
    #expect(StartScreenPreference(rawValue: "series") == .series)
    #expect(StartScreenPreference(rawValue: "recentlyAdded") == .recentlyAdded)

    #expect(SubtitleSizePreference(rawValue: "medium") == .medium)
    #expect(SubtitleBackgroundPreference(rawValue: "semiTransparent") == .semiTransparent)
    #expect(LibraryRescanInterval(rawValue: "1h") == .oneHour)
  }

  @Test func sidebarPreferencesOrderAndVisibility() {
    SidebarPreferences.resetToDefaults()
    let defaultOrder = SidebarPreferences.loadOrder()
    #expect(defaultOrder.first == .home)
    #expect(SidebarPreferences.isVisible(.home) == true)

    var customOrder = defaultOrder
    let home = customOrder.removeFirst()
    customOrder.append(home)
    SidebarPreferences.saveOrder(customOrder)

    let loadedCustom = SidebarPreferences.loadOrder()
    #expect(loadedCustom.last == .home)

    SidebarPreferences.setVisible(.home, isVisible: false)
    #expect(SidebarPreferences.isVisible(.home) == false)

    SidebarPreferences.resetToDefaults()
    let resetOrder = SidebarPreferences.loadOrder()
    #expect(resetOrder.first == .home)
    #expect(SidebarPreferences.isVisible(.home) == true)
  }
}
