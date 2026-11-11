import Foundation
import Testing

@testable import Aurelia

@MainActor
struct GeneralPreferencesTests {
  @Test func fillingTheScreenCropsThePictureToTheWindowShape() throws {
    #expect(VideoFill.cropGeometry(fills: false, size: CGSize(width: 1470, height: 956)) == nil)
    #expect(VideoFill.cropGeometry(fills: true, size: CGSize(width: 1469.6, height: 956.2)) == "1470:956")
    #expect(VideoFill.cropGeometry(fills: true, size: .zero) == nil)
    var preferences = PlaybackPreferences.defaultValue
    preferences.fillsScreen = true
    let decoded = try JSONDecoder().decode(
      PlaybackPreferences.self, from: JSONEncoder().encode(preferences))
    #expect(decoded.fillsScreen)
  }

  @Test func settingsSavedBeforeExtendedOptionsKeepTheirDefaults() throws {
    let saved = Data(
      """
      {"automaticResume":true,"defaultPlaybackRate":1.0,"defaultVolume":1.0,
      "controlsAutoHideDelay":3,"seekInterval":15,"preventSleepDuringPlayback":true,
      "automaticallyPlayNextEpisode":true,"nightMode":false,
      "markWatchedThresholdPercent":95,"subtitleSize":"large"}
      """.utf8)
    let value = try JSONDecoder().decode(PlaybackPreferences.self, from: saved)
    // The behavior before these options existed: Up Next 20 seconds before the end, no start-over.
    #expect(value.upNextCountdownSeconds == 20)
    #expect(value.resumeThresholdSeconds == 0)
    #expect(value.defaultAudioLanguage == "original")
    #expect(!value.fillsScreen)
    #expect(value.defaultSubtitleLanguage == "off")
    #expect(!value.skipIntrosAutomatically)

    var modified = value
    modified.upNextCountdownSeconds = 25
    modified.resumeThresholdSeconds = 60
    modified.defaultAudioLanguage = "de"
    modified.defaultSubtitleLanguage = "en"

    let roundTrip = try JSONDecoder().decode(
      PlaybackPreferences.self, from: JSONEncoder().encode(modified))
    #expect(roundTrip == modified)

    modified.defaultAudioLanguage = "klingon"
    #expect(modified.normalized.defaultAudioLanguage == "original")
  }

  @Test func defaultLanguagesPickTheMatchingVLCTrack() {
    let tracks = [
      PlaybackTrack(id: 1, title: "Track 1 - [English]"),
      PlaybackTrack(id: 2, title: "Commentary - [eng]"),
      PlaybackTrack(id: 3, title: "Forced - [ger]"),
      PlaybackTrack(id: 4, title: "Deutsch - [deu]"),
    ]
    #expect(PlaybackLanguage.track(in: tracks, for: "en")?.id == 2)
    #expect(PlaybackLanguage.track(in: tracks, for: "de")?.id == 4)
    #expect(PlaybackLanguage.track(in: tracks, for: "ja") == nil)
    #expect(PlaybackLanguage.track(in: tracks, for: "original") == nil)
    #expect(PlaybackLanguage.track(in: tracks, for: "off") == nil)
  }

  @Test func displaySettingsFilterRowsAndGrids() throws {
    let suite = "aurelia.display-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    func item(_ availability: MediaAvailability, _ state: CatalogWatchState) -> CatalogItemSummary {
      CatalogItemSummary(
        id: UUID(), kind: .movie, title: "Title", originalTitle: nil, year: nil, overview: nil,
        genres: [], poster: nil, backdrop: nil, availability: availability, isFavorite: false,
        progress: nil, addedAt: "2026-10-30T12:00:00Z", watchState: state)
    }
    let watched = item(.available, .completed)
    let offline = item(.missing, .unplayed)
    let fresh = item(.available, .unplayed)
    let all = [watched, offline, fresh]

    #expect(LibraryDisplayPreferences.visible(all, keepWatched: false, defaults: defaults) == all)
    defaults.set(false, forKey: GeneralPreferenceKeys.showWatchedInRows)
    defaults.set(true, forKey: GeneralPreferenceKeys.hideOfflineTitles)
    #expect(
      LibraryDisplayPreferences.visible(all, keepWatched: false, defaults: defaults) == [fresh])
    #expect(
      LibraryDisplayPreferences.visible(all, keepWatched: true, defaults: defaults) == [
        watched, fresh,
      ])
    defaults.set("large", forKey: GeneralPreferenceKeys.posterSize)
    #expect(LibraryDisplayPreferences.posterSize(defaults) == .large)
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

  @Test func skipIntrosAutomaticallyIsSavedAndStartsOff() throws {
    var value = PlaybackPreferences.defaultValue
    #expect(!value.skipIntrosAutomatically)
    value.skipIntrosAutomatically = true
    let restored = try JSONDecoder().decode(
      PlaybackPreferences.self, from: JSONEncoder().encode(value))
    #expect(restored.skipIntrosAutomatically)
  }

  @Test func introAndCreditsPoliciesKeepTheirWindows() {
    #expect(!SkipIntroPolicy.showsButton(position: 28_999, introStart: 30_000, introEnd: 90_000))
    #expect(SkipIntroPolicy.showsButton(position: 29_000, introStart: 30_000, introEnd: 90_000))
    #expect(!SkipIntroPolicy.showsButton(position: 88_000, introStart: 30_000, introEnd: 90_000))
    #expect(!SkipIntroPolicy.showsButton(position: 50_000, introStart: 90_000, introEnd: 30_000))
    #expect(
      SkipIntroPolicy.skipsAutomatically(
        enabled: true, alreadySkipped: false, movedIntoIntro: false, buttonShown: true))
    for (enabled, skipped, moved, shown) in [
      (false, false, false, true), (true, true, false, true), (true, false, true, true),
      (true, false, false, false),
    ] {
      #expect(
        !SkipIntroPolicy.skipsAutomatically(
          enabled: enabled, alreadySkipped: skipped, movedIntoIntro: moved, buttonShown: shown))
    }

    let duration: Int64 = 1_500_000
    // Credits are trusted only in the second half and before the end.
    #expect(UpNextPolicy.credits(1_380_000, duration: duration) == 1_380_000)
    #expect(UpNextPolicy.credits(600_000, duration: duration) == nil)
    #expect(UpNextPolicy.credits(1_499_500, duration: duration) == nil)
    #expect(
      UpNextPolicy.shows(
        position: 1_380_000, duration: duration, hasNext: true, autoplay: true, stopsAtEnd: false,
        dismissed: false, creditsStart: 1_380_000))
    #expect(
      !UpNextPolicy.shows(
        position: 1_379_000, duration: duration, hasNext: true, autoplay: true, stopsAtEnd: false,
        dismissed: false, creditsStart: 1_380_000))
    #expect(
      !UpNextPolicy.shows(
        position: 1_400_000, duration: duration, hasNext: true, autoplay: false, stopsAtEnd: false,
        dismissed: false, creditsStart: 1_380_000))
    // The countdown runs from where the card appeared, and never past the end of the title.
    #expect(
      UpNextPolicy.seconds(
        position: 1_385_000, duration: duration, creditsAnchor: 1_380_000, lead: 20_000) == 15)
    #expect(
      UpNextPolicy.seconds(
        position: 1_495_000, duration: duration, creditsAnchor: 1_490_000, lead: 20_000) == 5)
    #expect(UpNextPolicy.seconds(position: 1_490_000, duration: duration) == 10)
    // Next Episode from the credits on counts the episode as watched.
    #expect(
      UpNextPolicy.nextFinishesCurrent(
        position: 1_340_000, duration: duration, upNextShown: false, creditsStart: 1_330_000))
    #expect(
      !UpNextPolicy.nextFinishesCurrent(
        position: 1_340_000, duration: duration, upNextShown: false))
  }

  @Test func segmentTimeFieldsReadMinutesAndSeconds() {
    #expect(MediaSegmentTimeText.text(84_600) == "1:24")
    #expect(MediaSegmentTimeText.text(nil).isEmpty)
    #expect(
      MediaSegmentTimeText.request(introStart: "", introEnd: "1:30", creditsStart: "42:10")
        == SetMediaSegmentsRequest(
          introStartMilliseconds: 0, introEndMilliseconds: 90_000,
          creditsStartMilliseconds: 2_530_000))
    #expect(
      MediaSegmentTimeText.request(introStart: "", introEnd: "", creditsStart: "")
        == SetMediaSegmentsRequest(
          introStartMilliseconds: nil, introEndMilliseconds: nil, creditsStartMilliseconds: nil))
    #expect(MediaSegmentTimeText.request(introStart: "soon", introEnd: "1:30", creditsStart: "") == nil)
    // Older servers send no times; the ticket still decodes.
    let ticket = Data(
      """
      {"id":"00000000-0000-0000-0000-000000000001","mediaId":"00000000-0000-0000-0000-000000000002",
      "streamPath":"/api/v1/streams/t","contentType":"video/mp4","contentLength":1,
      "expiresAt":"2099-01-01T00:00:00Z","progress":{"mediaId":"00000000-0000-0000-0000-000000000002",
      "positionMilliseconds":0,"durationMilliseconds":0,"isCompleted":false}}
      """.utf8)
    #expect((try? JSONDecoder().decode(PlaybackSourceResponse.self, from: ticket))?.segments == nil)
  }

  @Test func generalPreferenceEnumsRoundTrip() {
    #expect(PosterSizePreference(rawValue: "standard") == .standard)
    #expect(PosterSizePreference(rawValue: "compact") == .compact)
    #expect(PosterSizePreference(rawValue: "large") == .large)

    #expect(StartScreenPreference.allCases.first == .lastScreen)
    #expect(StartScreenPreference(rawValue: "home") == .home)
    #expect(StartScreenPreference(rawValue: "library") == .library)
    #expect(StartScreenPreference(rawValue: "continueWatching") == .continueWatching)
    #expect(StartScreenPreference(rawValue: "collections") == .collections)
    #expect(StartScreenPreference(rawValue: "watchlist") == .watchlist)
    #expect(StartScreenPreference(rawValue: "movies") == .movies)
    #expect(StartScreenPreference(rawValue: "series") == .series)
    #expect(StartScreenPreference(rawValue: "recentlyAdded") == .recentlyAdded)

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

  @Test func activityPagesJoinTheSidebarOnlyWhenTurnedOn() {
    SidebarPreferences.resetToDefaults()
    defer { SidebarPreferences.resetToDefaults() }
    #expect(!SidebarPreferences.isVisible(.history))
    #expect(!SidebarPreferences.isVisible(.statistics))
    #expect(SidebarPreferences.loadOrder().contains(.history), "They stay in the customizer's list.")
    SidebarPreferences.setVisible(.statistics, isVisible: true)
    #expect(SidebarPreferences.isVisible(.statistics))
    #expect(!SidebarPreferences.isVisible(.history))
  }

  @Test func draggingASidebarItemMovesOnlyThatItem() {
    let items: [LibraryDestination] = [.home, .library, .collections, .watchlist]
    #expect(SidebarReorder.moving(.watchlist, to: 0, in: items) == [.watchlist, .home, .library, .collections])
    #expect(SidebarReorder.moving(.home, to: 2, in: items) == [.library, .collections, .home, .watchlist])
    #expect(SidebarReorder.moving(.library, to: 1, in: items) == items)
    #expect(SidebarReorder.moving(.library, to: 9, in: items) == items)
  }
}
