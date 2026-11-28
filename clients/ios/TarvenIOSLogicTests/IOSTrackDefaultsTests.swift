import Foundation
import Testing

/// Default languages and the look of subtitles in Settings › Playback. Invented tracks only.
@Suite struct IOSTrackDefaultsTests {
  private let audio = [
    IOSPlaybackTrack(id: 1, title: "Track 1 - [jpn]"),
    IOSPlaybackTrack(id: 2, title: "Track 2 - [eng]"),
    IOSPlaybackTrack(id: 3, title: "Commentary - [ger]"),
  ]
  private let subtitles = [
    IOSPlaybackTrack(id: 4, title: "Forced - [eng]"),
    IOSPlaybackTrack(id: 5, title: "Full - [eng]"),
    IOSPlaybackTrack(id: 6, title: "Track 3 - [fre]"),
  ]

  @Test func defaultLanguagesApplyUntilATrackIsChosen() {
    var preferences = IOSPlaybackPreferences()
    #expect(IOSTrackSelection.audio(preferences, tracks: audio) == .keep)
    #expect(IOSTrackSelection.subtitle(preferences, tracks: subtitles) == .off)
    preferences.defaultAudioLanguage = "de"
    preferences.defaultSubtitleLanguage = "en"
    #expect(IOSTrackSelection.audio(preferences, tracks: audio) == .track(3))
    // Forced subtitles carry only foreign lines; the full track comes first.
    #expect(IOSTrackSelection.subtitle(preferences, tracks: subtitles) == .track(5))
    preferences.defaultSubtitleLanguage = "ja"
    #expect(IOSTrackSelection.subtitle(preferences, tracks: subtitles) == .off)
  }

  @Test func aChosenTrackOrChosenOffWinsOverTheDefaultLanguage() {
    var preferences = IOSPlaybackPreferences()
    preferences.defaultAudioLanguage = "de"
    preferences.defaultSubtitleLanguage = "fr"
    preferences.preferredAudioTrack = IOSPlaybackTrackPreference(language: "jpn", title: "x")
    #expect(IOSTrackSelection.audio(preferences, tracks: audio) == .track(1))
    preferences.subtitleTrackChosen = true
    #expect(IOSTrackSelection.subtitle(preferences, tracks: subtitles) == .off)
    // A remembered track that has not appeared yet is waited for, not replaced.
    preferences.preferredSubtitleTrack = IOSPlaybackTrackPreference(language: "spa", title: "y")
    #expect(IOSTrackSelection.subtitle(preferences, tracks: subtitles) == .wait)
  }

  @Test func aSeriesChoiceCountsAsChosen() {
    var preferences = IOSPlaybackPreferences()
    preferences.defaultSubtitleLanguage = "en"
    let series = IOSSeriesTrackChoice(subtitle: nil, subtitleChosen: true, updatedAt: Date())
    #expect(IOSTrackSelection.subtitle(preferences.applying(series), tracks: subtitles) == .off)
  }

  @Test func oldSavedPreferencesDecodeWithTheDefaults() throws {
    let saved = Data(#"{"automaticResume":false,"preferredSubtitleTrack":null}"#.utf8)
    let decoded = try JSONDecoder().decode(IOSPlaybackPreferences.self, from: saved)
    #expect(!decoded.automaticResume)
    #expect(decoded.defaultAudioLanguage == "original")
    #expect(decoded.defaultSubtitleLanguage == "off")
    #expect(decoded.subtitleSize == .medium)
    #expect(decoded.subtitleBackground == .transparent)
    #expect(!decoded.subtitleTrackChosen)
    var changed = decoded
    changed.defaultAudioLanguage = "xx"
    #expect(changed.normalized.defaultAudioLanguage == "original")
    changed.subtitleSize = .large
    changed.subtitleBackground = .solid
    let again = try JSONDecoder().decode(
      IOSPlaybackPreferences.self, from: JSONEncoder().encode(changed.normalized))
    #expect(again.subtitleSize == .large && again.subtitleBackground == .solid)
  }

  @Test func subtitleLookBecomesVLCOptions() {
    #expect(IOSSubtitleAppearance.vlcOptions(size: .medium, background: .transparent).isEmpty)
    #expect(
      IOSSubtitleAppearance.vlcOptions(size: .large, background: .semiTransparent) == [
        "--sub-text-scale=140", "--freetype-background-opacity=140",
        "--freetype-background-color=0",
      ])
    #expect(
      IOSSubtitleAppearance.vlcOptions(size: .small, background: .solid).first
        == "--sub-text-scale=70")
  }
}
