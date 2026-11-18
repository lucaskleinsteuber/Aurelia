import Foundation
import Testing

@testable import Aurelia

/// Subtitle size and background: VLC's options and saved settings from before they existed.
struct SubtitleAppearanceTests {
  @Test func vlcsOwnLookAddsNothingAndAChosenLookAddsItsOptions() {
    #expect(SubtitleAppearance.vlcOptions(size: .medium, background: .transparent).isEmpty)
    #expect(
      SubtitleAppearance.vlcOptions(size: .large, background: .solid) == [
        "--sub-text-scale=140", "--freetype-background-opacity=255",
        "--freetype-background-color=0",
      ])
    #expect(
      SubtitleAppearance.vlcOptions(size: .small, background: .transparent).first
        == "--sub-text-scale=70")
    #expect(
      SubtitleAppearance.vlcOptions(size: .medium, background: .semiTransparent)[1]
        == "--freetype-background-opacity=140")
  }

  @Test func savedSettingsKeepTheirLookAndOlderOnesStartWithVLCsOwn() throws {
    var chosen = PlaybackPreferences.defaultValue
    chosen.subtitleSize = .large
    chosen.subtitleBackground = .semiTransparent
    let decoded = try JSONDecoder().decode(
      PlaybackPreferences.self, from: JSONEncoder().encode(chosen))
    #expect(decoded.subtitleSize == .large)
    #expect(decoded.subtitleBackground == .semiTransparent)

    var older =
      try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(PlaybackPreferences.defaultValue)) as! [String: Any]
    older.removeValue(forKey: "subtitleSize")
    older["subtitleBackground"] = "neon"
    let restored = try JSONDecoder().decode(
      PlaybackPreferences.self, from: JSONSerialization.data(withJSONObject: older))
    #expect(restored.subtitleSize == .medium)
    #expect(restored.subtitleBackground == .transparent)
  }
}
