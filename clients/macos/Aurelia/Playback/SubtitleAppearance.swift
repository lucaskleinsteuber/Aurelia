import Foundation

/// How large subtitles are (Settings › Playback), as in the browser and the Linux app.
enum SubtitleSize: String, Codable, CaseIterable, Identifiable, Sendable {
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

/// What is behind the subtitles (Settings › Playback), as in the browser and the Linux app.
enum SubtitleBackground: String, Codable, CaseIterable, Identifiable, Sendable {
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
enum SubtitleAppearance {
  static func vlcOptions(size: SubtitleSize, background: SubtitleBackground) -> [String] {
    guard size != .medium || background != .transparent else { return [] }
    return [
      "--sub-text-scale=\(size.textScale)",
      "--freetype-background-opacity=\(background.opacity)",
      "--freetype-background-color=0",
    ]
  }
}
