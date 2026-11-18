import Foundation
import Testing

/// Default languages and the look of subtitles in Settings › Playback. Invented tracks only.
@Suite struct TVTrackDefaultsTests {
  private let audio = [
    TVPlaybackTrack(id: 1, title: "Track 1 - [jpn]"),
    TVPlaybackTrack(id: 2, title: "Track 2 - [eng]"),
    TVPlaybackTrack(id: 3, title: "Commentary - [ger]"),
  ]
  private let subtitles = [
    TVPlaybackTrack(id: 4, title: "Forced - [eng]"),
    TVPlaybackTrack(id: 5, title: "Full - [eng]"),
    TVPlaybackTrack(id: 6, title: "Track 3 - [fre]"),
  ]

  @Test func defaultLanguagesApplyUntilATrackIsChosen() {
    var preferences = TVPlaybackPreferences()
    #expect(TVTrackSelection.audio(preferences, tracks: audio) == .keep)
    #expect(TVTrackSelection.subtitle(preferences, tracks: subtitles) == .off)
    preferences.defaultAudioLanguage = "de"
    preferences.defaultSubtitleLanguage = "en"
    #expect(TVTrackSelection.audio(preferences, tracks: audio) == .track(3))
    // Forced subtitles carry only foreign lines; the full track comes first.
    #expect(TVTrackSelection.subtitle(preferences, tracks: subtitles) == .track(5))
    preferences.defaultSubtitleLanguage = "ja"
    #expect(TVTrackSelection.subtitle(preferences, tracks: subtitles) == .off)
  }

  @Test func aChosenTrackOrChosenOffWinsOverTheDefaultLanguage() {
    var preferences = TVPlaybackPreferences()
    preferences.defaultAudioLanguage = "de"
    preferences.defaultSubtitleLanguage = "fr"
    preferences.preferredAudioTrack = TVPlaybackTrackPreference(language: "jpn", title: "x")
    #expect(TVTrackSelection.audio(preferences, tracks: audio) == .track(1))
    preferences.subtitleTrackChosen = true
    #expect(TVTrackSelection.subtitle(preferences, tracks: subtitles) == .off)
    // A remembered track that has not appeared yet is waited for, not replaced.
    preferences.preferredSubtitleTrack = TVPlaybackTrackPreference(language: "spa", title: "y")
    #expect(TVTrackSelection.subtitle(preferences, tracks: subtitles) == .wait)
  }

  @Test func aSeriesChoiceCountsAsChosen() {
    var preferences = TVPlaybackPreferences()
    preferences.defaultSubtitleLanguage = "en"
    let series = TVSeriesTrackChoice(subtitle: nil, subtitleChosen: true, updatedAt: Date())
    #expect(TVTrackSelection.subtitle(preferences.applying(series), tracks: subtitles) == .off)
  }

  @Test func oldSavedPreferencesDecodeWithTheDefaults() throws {
    let saved = Data(#"{"automaticResume":false,"preferredSubtitleTrack":null}"#.utf8)
    let decoded = try JSONDecoder().decode(TVPlaybackPreferences.self, from: saved)
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
      TVPlaybackPreferences.self, from: JSONEncoder().encode(changed.normalized))
    #expect(again.subtitleSize == .large && again.subtitleBackground == .solid)
  }

  @Test func subtitleLookBecomesVLCOptions() {
    #expect(TVSubtitleAppearance.vlcOptions(size: .medium, background: .transparent).isEmpty)
    #expect(
      TVSubtitleAppearance.vlcOptions(size: .large, background: .semiTransparent) == [
        "--sub-text-scale=140", "--freetype-background-opacity=140",
        "--freetype-background-color=0",
      ])
    #expect(
      TVSubtitleAppearance.vlcOptions(size: .small, background: .solid).first
        == "--sub-text-scale=70")
  }
}
