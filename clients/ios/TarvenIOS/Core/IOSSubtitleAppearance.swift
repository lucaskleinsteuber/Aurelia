import Foundation

/// How large subtitles are (Settings › Playback), as on the Mac, in Linux and in the browser.
enum IOSSubtitleSize: String, Codable, CaseIterable, Identifiable, Sendable {
  case small, medium, large

  var id: String { rawValue }
  var title: String {
    switch self {
    case .small: "Small"
    case .medium: "Medium"
    case .large: "Large"
    }
  }
  /// VLC's text scale in percent.
  var textScale: Int {
    switch self {
    case .small: 70
    case .medium: 100
    case .large: 140
    }
  }
}

/// What is behind the subtitles (Settings › Playback).
enum IOSSubtitleBackground: String, Codable, CaseIterable, Identifiable, Sendable {
  case transparent, semiTransparent, solid

  var id: String { rawValue }
  var title: String {
    switch self {
    case .transparent: "Transparent"
    case .semiTransparent: "Semi-Transparent"
    case .solid: "Solid Black"
    }
  }
  /// VLC's background opacity, 0…255, behind black.
  var opacity: Int {
    switch self {
    case .transparent: 0
    case .semiTransparent: 140
    case .solid: 255
    }
  }
}

/// VLC draws subtitles into the picture, so their look is an option of the player, which is made
/// for every title: a change applies from the next title. Medium on a transparent background is
/// VLC's own look and adds nothing.
enum IOSSubtitleAppearance {
  static func vlcOptions(size: IOSSubtitleSize, background: IOSSubtitleBackground) -> [String] {
    guard size != .medium || background != .transparent else { return [] }
    return [
      "--sub-text-scale=\(size.textScale)",
      "--freetype-background-opacity=\(background.opacity)",
      "--freetype-background-color=0",
    ]
  }
}

/// The default languages of Settings › Playback, matched against VLC's "[eng]" track tags. They
/// apply until a track is chosen for a series or anywhere on this profile, as on the Mac.
enum IOSPlaybackLanguage {
  static let choices = ["en", "de", "fr", "es", "it", "ja"]
  static let original = "original"
  static let off = "off"
  private static let aliases: [String: Set<String>] = [
    "en": ["en", "eng"], "de": ["de", "deu", "ger"], "fr": ["fr", "fra", "fre"],
    "es": ["es", "spa"], "it": ["it", "ita"], "ja": ["ja", "jpn"],
  ]

  static func title(_ language: String) -> String {
    switch language {
    case "en": "English"
    case "de": "German"
    case "fr": "French"
    case "es": "Spanish"
    case "it": "Italian"
    case "ja": "Japanese"
    case off: "Off"
    default: "Original"
    }
  }

  static func normalized(_ value: String, fallback: String) -> String {
    choices.contains(value) ? value : fallback
  }

  static func matches(_ code: String?, _ language: String) -> Bool {
    guard let code = code?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first else {
      return false
    }
    return aliases[language, default: [language]].contains(code.lowercased())
  }

  /// The first track in that language, avoiding forced subtitles, or nil for "original", "off"
  /// or no match.
  static func track(in tracks: [IOSPlaybackTrack], for language: String) -> IOSPlaybackTrack? {
    guard choices.contains(language) else { return nil }
    let matching = tracks.filter { matches($0.preference.language, language) }
    return matching.first { !$0.title.localizedCaseInsensitiveContains("forced") }
      ?? matching.first
  }
}

/// Which tracks a title opens with: a remembered choice (the series' own first), else the default
/// language of Settings › Playback.
enum IOSTrackSelection: Equatable, Sendable {
  /// Keep waiting: the remembered track may still appear in a later parse update.
  case wait
  /// Leave the file's own choice.
  case keep
  case track(Int32)
  /// Subtitles off.
  case off

  static func audio(_ preferences: IOSPlaybackPreferences, tracks: [IOSPlaybackTrack]) -> Self {
    if let preferred = preferences.preferredAudioTrack {
      return IOSPlaybackTrack.matching(preferred, in: tracks).map { .track($0.id) } ?? .wait
    }
    return IOSPlaybackLanguage.track(in: tracks, for: preferences.defaultAudioLanguage)
      .map { .track($0.id) } ?? .keep
  }

  static func subtitle(_ preferences: IOSPlaybackPreferences, tracks: [IOSPlaybackTrack]) -> Self {
    if preferences.subtitleTrackChosen || preferences.preferredSubtitleTrack != nil {
      guard let preferred = preferences.preferredSubtitleTrack else { return .off }
      return IOSPlaybackTrack.matching(preferred, in: tracks).map { .track($0.id) } ?? .wait
    }
    return IOSPlaybackLanguage.track(in: tracks, for: preferences.defaultSubtitleLanguage)
      .map { .track($0.id) } ?? .off
  }
}
