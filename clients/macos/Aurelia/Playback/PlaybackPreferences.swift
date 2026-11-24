import Foundation

struct PlaybackTrack: Identifiable, Equatable, Sendable {
  let id: Int32
  let title: String

  var preference: PlaybackTrackPreference {
    PlaybackTrackPreference(
      language: Self.language(in: title),
      title: title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }

  private static func language(in title: String) -> String? {
    guard let open = title.lastIndex(of: "["),
      let close = title[open...].firstIndex(of: "]"),
      open < close
    else { return nil }
    let value = title[title.index(after: open)..<close]
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return value.isEmpty ? nil : value
  }
}

/// Track names as the player's menus show them. VLC names tracks like "Track 1 - [English]";
/// the menus show "English", "Commentary (English)", and number tracks that would read the same
/// ("English", "English (2)"). The track's own title stays as it is for saved preferences.
enum PlaybackTrackNames {
  static func menuTitle(for track: PlaybackTrack, in tracks: [PlaybackTrack]) -> String {
    let names = tracks.map { plain($0.title) }
    guard let position = tracks.firstIndex(where: { $0.id == track.id }) else {
      return plain(track.title)
    }
    let name = names[position]
    let earlier = names[..<position].filter { $0.caseInsensitiveCompare(name) == .orderedSame }
      .count
    return earlier == 0 ? name : "\(name) (\(earlier + 1))"
  }

  static func plain(_ title: String) -> String {
    var value = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if let prefix = value.range(of: #"^Track \d+\s*-\s*"#, options: .regularExpression) {
      value.removeSubrange(prefix)
    }
    if let tag = value.range(of: #"\[[^\]]+\]$"#, options: .regularExpression) {
      let language = String(value[tag].dropFirst().dropLast())
        .trimmingCharacters(in: .whitespaces)
      var rest = String(value[..<tag.lowerBound]).trimmingCharacters(in: .whitespaces)
      if rest.hasSuffix("-") { rest = String(rest.dropLast()).trimmingCharacters(in: .whitespaces) }
      if rest.isEmpty {
        value = language
      } else if language.isEmpty || rest.localizedCaseInsensitiveContains(language) {
        value = rest
      } else {
        value = "\(rest) (\(language))"
      }
    }
    return value.isEmpty ? title : value
  }
}

/// The default languages of Settings › Playback, matched against VLC's "[eng]" track tags.
enum PlaybackLanguage {
  static let choices = ["en", "de", "fr", "es", "it", "ja"]
  private static let aliases: [String: Set<String>] = [
    "en": ["en", "eng"], "de": ["de", "deu", "ger"], "fr": ["fr", "fra", "fre"],
    "es": ["es", "spa"], "it": ["it", "ita"], "ja": ["ja", "jpn"],
  ]

  static func isChoice(_ value: String, off: String) -> Bool {
    value == off || choices.contains(value)
  }

  static func matches(_ code: String?, _ language: String) -> Bool {
    guard let code = code?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first else {
      return false
    }
    return aliases[language, default: [language]].contains(code.lowercased())
  }

  /// The first track in that language, or nil for "original", "off" or no match.
  static func track(in tracks: [PlaybackTrack], for language: String) -> PlaybackTrack? {
    guard choices.contains(language) else { return nil }
    let matching = tracks.filter { matches($0.preference.language, language) }
    return matching.first { !isForcedSubtitle($0) } ?? matching.first
  }

  static func isForcedSubtitle(_ track: PlaybackTrack) -> Bool {
    track.title.localizedCaseInsensitiveContains("forced")
  }

  static func sameLanguage(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs, let rhs else { return false }
    let left = normalizedCode(lhs)
    let right = normalizedCode(rhs)
    guard !left.isEmpty, !right.isEmpty else { return false }
    if left == right { return true }
    for group in aliases.values where group.contains(left) && group.contains(right) {
      return true
    }
    return false
  }

  private static func normalizedCode(_ code: String) -> String {
    code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
  }

  /// When a series remembers subtitles "Off", regular subtitles stay disabled while preserving
  /// forced subtitles for foreign-language passages in the active audio language (or the file's
  /// own forced default when audio has no language tag).
  static func forcedSubtitleTrackWhenOff(
    subtitleTracks: [PlaybackTrack],
    currentSubtitleID: Int32?,
    audioTracks: [PlaybackTrack],
    currentAudioID: Int32?
  ) -> PlaybackTrack? {
    let forcedTracks = subtitleTracks.filter { isForcedSubtitle($0) }
    guard !forcedTracks.isEmpty else { return nil }
    let activeAudioLanguage =
      currentAudioID
      .flatMap { id in audioTracks.first(where: { $0.id == id })?.preference.language }
      ?? audioTracks.first?.preference.language
    let currentForced = currentSubtitleID.flatMap { id in
      forcedTracks.first(where: { $0.id == id })
    }
    if let activeAudioLanguage, !normalizedCode(activeAudioLanguage).isEmpty {
      if let currentForced, sameLanguage(currentForced.preference.language, activeAudioLanguage) {
        return currentForced
      }
      return forcedTracks.first { sameLanguage($0.preference.language, activeAudioLanguage) }
    }
    return currentForced
  }
}

struct PlaybackTrackPreference: Codable, Equatable, Sendable {
  let language: String?
  let title: String
}

struct PlaybackChapter: Identifiable, Equatable, Sendable {
  let index: Int32
  let title: String
  let timeOffsetMilliseconds: Int64
  let durationMilliseconds: Int64

  var id: Int32 { index }
}

struct PlaybackPreferences: Codable, Equatable, Sendable {
  static let supportedRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
  static let defaultValue = PlaybackPreferences(
    automaticResume: true,
    defaultPlaybackRate: 1,
    defaultVolume: 1,
    controlsAutoHideDelay: 2,
    seekInterval: 10,
    preventSleepDuringPlayback: true,
    automaticallyPlayNextEpisode: true,
    nightMode: false,
    upNextCountdownSeconds: 20,
    resumeThresholdSeconds: 0,
    defaultAudioLanguage: "original",
    defaultSubtitleLanguage: "off")

  var automaticResume: Bool
  var defaultPlaybackRate: Double
  var defaultVolume: Double
  var controlsAutoHideDelay: Double
  var seekInterval: Int
  var preventSleepDuringPlayback: Bool
  var automaticallyPlayNextEpisode: Bool
  /// Softens loud scenes and lifts quiet dialogue.
  var dialogueBoost: DialogueBoost = .off
  var volumeLeveling: VolumeLeveling = .off
  /// Compatibility accessor for older code and the persisted Night Mode key.
  var nightMode: Bool {
    get { volumeLeveling != .off }
    set { volumeLeveling = newValue ? .standard : .off }
  }
  /// How long before the end the next episode is offered.
  var upNextCountdownSeconds: Int
  /// Resume starts over when less than this was watched.
  var resumeThresholdSeconds: Int
  /// Used until a sound track is chosen for a series ("original" keeps the file's default).
  var defaultAudioLanguage: String
  /// Used until subtitles are chosen for a series ("off" keeps the file's own default).
  var defaultSubtitleLanguage: String
  /// The picture fills the window, cutting off its edges, instead of showing black bars.
  var fillsScreen = false
  /// Cinema mode: before a film started from the beginning, an ad and trailers, as at the cinema.
  var cinemaMode = false
  /// Cinema mode shows one of Aurelia's made-up ads first.
  var cinemaAds = true
  /// Trailers of films not watched yet that cinema mode plays (0…3).
  var cinemaTrailers = 2
  /// The original file, or the server's live conversion in a quality the connection carries.
  var streamingQuality: StreamingQuality = .original
  /// What the player does with an intro the server found.
  var introSkipping: IntroSkipping = .button
  /// The next episode is offered when the credits begin, not only in the last seconds.
  var upNextAtCredits = true
  /// After a movie or a series' last episode, the server's suggestion starts on its own.
  var playSuggestionsAutomatically = false
  /// Shows the quiet Good-Night screen when playback ends at a sleep timer.
  var showGoodNightOnSleepTimer = false
  /// How large subtitles are and what is behind them; applies from the next title.
  var subtitleSize: SubtitleSize = .medium
  var subtitleBackground: SubtitleBackground = .transparent

  /// Kept for code and settings from 2.8 and 2.9, where this was a single switch.
  var skipIntrosAutomatically: Bool {
    get { introSkipping == .automatic }
    set { introSkipping = newValue ? .automatic : .button }
  }

  init(
    automaticResume: Bool,
    defaultPlaybackRate: Double,
    defaultVolume: Double,
    controlsAutoHideDelay: Double,
    seekInterval: Int,
    preventSleepDuringPlayback: Bool,
    automaticallyPlayNextEpisode: Bool,
    nightMode: Bool,
    upNextCountdownSeconds: Int = 20,
    resumeThresholdSeconds: Int = 0,
    defaultAudioLanguage: String = "original",
    defaultSubtitleLanguage: String = "off",
    dialogueBoost: DialogueBoost = .off, volumeLeveling: VolumeLeveling? = nil,
    fillsScreen: Bool = false,
    cinemaMode: Bool = false, cinemaAds: Bool = true, cinemaTrailers: Int = 2
  ) {
    self.automaticResume = automaticResume
    self.defaultPlaybackRate = defaultPlaybackRate
    self.defaultVolume = defaultVolume
    self.controlsAutoHideDelay = controlsAutoHideDelay
    self.seekInterval = seekInterval
    self.preventSleepDuringPlayback = preventSleepDuringPlayback
    self.automaticallyPlayNextEpisode = automaticallyPlayNextEpisode
    self.volumeLeveling = volumeLeveling ?? (nightMode ? .standard : .off)
    self.dialogueBoost = dialogueBoost
    self.upNextCountdownSeconds = upNextCountdownSeconds
    self.resumeThresholdSeconds = resumeThresholdSeconds
    self.defaultAudioLanguage = defaultAudioLanguage
    self.defaultSubtitleLanguage = defaultSubtitleLanguage
    self.fillsScreen = fillsScreen
    self.cinemaMode = cinemaMode
    self.cinemaAds = cinemaAds
    self.cinemaTrailers = cinemaTrailers
  }

  var normalized: PlaybackPreferences {
    var value = self
    if !Self.supportedRates.contains(value.defaultPlaybackRate) {
      value.defaultPlaybackRate = 1
    }
    value.defaultVolume = min(max(value.defaultVolume, 0), 1)
    value.controlsAutoHideDelay = min(max(value.controlsAutoHideDelay, 1), 10)
    value.seekInterval = min(max(value.seekInterval, 5), 60)
    value.upNextCountdownSeconds = min(max(value.upNextCountdownSeconds, 5), 30)
    value.resumeThresholdSeconds = min(max(value.resumeThresholdSeconds, 0), 120)
    value.cinemaTrailers = min(max(value.cinemaTrailers, 0), 3)
    if !PlaybackLanguage.isChoice(value.defaultAudioLanguage, off: "original") {
      value.defaultAudioLanguage = "original"
    }
    if !PlaybackLanguage.isChoice(value.defaultSubtitleLanguage, off: "off") {
      value.defaultSubtitleLanguage = "off"
    }
    return value
  }
}

extension PlaybackPreferences {
  private enum CodingKeys: String, CodingKey {
    case automaticResume, defaultPlaybackRate, defaultVolume, controlsAutoHideDelay
    case seekInterval, preventSleepDuringPlayback, automaticallyPlayNextEpisode, nightMode
    case upNextCountdownSeconds, resumeThresholdSeconds
    case defaultAudioLanguage, defaultSubtitleLanguage, dialogueBoost, volumeLeveling
    case fillsScreen, cinemaMode, cinemaAds, cinemaTrailers, streamingQuality
    case skipIntrosAutomatically, introSkipping, upNextAtCredits, playSuggestionsAutomatically
    case showGoodNightOnSleepTimer, subtitleSize, subtitleBackground
  }

  /// Settings saved before a newer option existed keep their values; the new option starts off.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      automaticResume: try container.decode(Bool.self, forKey: .automaticResume),
      defaultPlaybackRate: try container.decode(Double.self, forKey: .defaultPlaybackRate),
      defaultVolume: try container.decode(Double.self, forKey: .defaultVolume),
      controlsAutoHideDelay: try container.decode(Double.self, forKey: .controlsAutoHideDelay),
      seekInterval: try container.decode(Int.self, forKey: .seekInterval),
      preventSleepDuringPlayback: try container.decode(
        Bool.self, forKey: .preventSleepDuringPlayback),
      automaticallyPlayNextEpisode: try container.decode(
        Bool.self, forKey: .automaticallyPlayNextEpisode),
      nightMode: try container.decodeIfPresent(Bool.self, forKey: .nightMode) ?? false,
      upNextCountdownSeconds: try container.decodeIfPresent(
        Int.self, forKey: .upNextCountdownSeconds) ?? 20,
      resumeThresholdSeconds: try container.decodeIfPresent(
        Int.self, forKey: .resumeThresholdSeconds) ?? 0,
      defaultAudioLanguage: try container.decodeIfPresent(
        String.self, forKey: .defaultAudioLanguage) ?? "original",
      defaultSubtitleLanguage: try container.decodeIfPresent(
        String.self, forKey: .defaultSubtitleLanguage) ?? "off",
      dialogueBoost: try container.decodeIfPresent(DialogueBoost.self, forKey: .dialogueBoost)
        ?? .off,
      volumeLeveling: try container.decodeIfPresent(VolumeLeveling.self, forKey: .volumeLeveling),
      fillsScreen: try container.decodeIfPresent(Bool.self, forKey: .fillsScreen) ?? false,
      cinemaMode: try container.decodeIfPresent(Bool.self, forKey: .cinemaMode) ?? false,
      cinemaAds: try container.decodeIfPresent(Bool.self, forKey: .cinemaAds) ?? true,
      cinemaTrailers: try container.decodeIfPresent(Int.self, forKey: .cinemaTrailers) ?? 2)
    streamingQuality =
      (try? container.decodeIfPresent(StreamingQuality.self, forKey: .streamingQuality))
      ?? .original
    let automatic =
      try container.decodeIfPresent(Bool.self, forKey: .skipIntrosAutomatically) ?? false
    introSkipping =
      (try? container.decodeIfPresent(IntroSkipping.self, forKey: .introSkipping))
      ?? (automatic ? .automatic : .button)
    upNextAtCredits = try container.decodeIfPresent(Bool.self, forKey: .upNextAtCredits) ?? true
    playSuggestionsAutomatically =
      try container.decodeIfPresent(Bool.self, forKey: .playSuggestionsAutomatically) ?? false
    showGoodNightOnSleepTimer =
      try container.decodeIfPresent(Bool.self, forKey: .showGoodNightOnSleepTimer) ?? false
    subtitleSize =
      (try? container.decodeIfPresent(SubtitleSize.self, forKey: .subtitleSize)) ?? .medium
    subtitleBackground =
      (try? container.decodeIfPresent(SubtitleBackground.self, forKey: .subtitleBackground))
      ?? .transparent
  }
  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(automaticResume, forKey: .automaticResume)
    try values.encode(defaultPlaybackRate, forKey: .defaultPlaybackRate)
    try values.encode(defaultVolume, forKey: .defaultVolume)
    try values.encode(controlsAutoHideDelay, forKey: .controlsAutoHideDelay)
    try values.encode(seekInterval, forKey: .seekInterval)
    try values.encode(preventSleepDuringPlayback, forKey: .preventSleepDuringPlayback)
    try values.encode(automaticallyPlayNextEpisode, forKey: .automaticallyPlayNextEpisode)
    try values.encode(nightMode, forKey: .nightMode)
    try values.encode(upNextCountdownSeconds, forKey: .upNextCountdownSeconds)
    try values.encode(resumeThresholdSeconds, forKey: .resumeThresholdSeconds)
    try values.encode(defaultAudioLanguage, forKey: .defaultAudioLanguage)
    try values.encode(defaultSubtitleLanguage, forKey: .defaultSubtitleLanguage)
    try values.encode(dialogueBoost, forKey: .dialogueBoost)
    try values.encode(volumeLeveling, forKey: .volumeLeveling)
    try values.encode(fillsScreen, forKey: .fillsScreen)
    try values.encode(cinemaMode, forKey: .cinemaMode)
    try values.encode(cinemaAds, forKey: .cinemaAds)
    try values.encode(cinemaTrailers, forKey: .cinemaTrailers)
    try values.encode(streamingQuality, forKey: .streamingQuality)
    try values.encode(skipIntrosAutomatically, forKey: .skipIntrosAutomatically)
    try values.encode(introSkipping, forKey: .introSkipping)
    try values.encode(upNextAtCredits, forKey: .upNextAtCredits)
    try values.encode(playSuggestionsAutomatically, forKey: .playSuggestionsAutomatically)
    try values.encode(showGoodNightOnSleepTimer, forKey: .showGoodNightOnSleepTimer)
    try values.encode(subtitleSize, forKey: .subtitleSize)
    try values.encode(subtitleBackground, forKey: .subtitleBackground)
  }

}

/// What the player does when an episode's intro plays.
enum IntroSkipping: String, Codable, CaseIterable, Identifiable, Sendable {
  /// Nothing is offered; the intro plays.
  case off
  /// A Skip Intro button is offered while the intro plays.
  case button
  /// The intro is skipped without asking, once per episode.
  case automatic

  var id: String { rawValue }

  var title: String {
    switch self {
    case .off: "Don't Offer"
    case .button: "Show Skip Intro"
    case .automatic: "Skip Automatically"
    }
  }
}

/// How the picture fills the player when black bars are not wanted.
enum VideoFill {
  /// The crop VLC applies: the window's own shape, so the picture covers it exactly. Nil shows
  /// the whole picture with bars.
  static func cropGeometry(fills: Bool, size: CGSize) -> String? {
    guard fills, size.width >= 1, size.height >= 1 else { return nil }
    return "\(Int(size.width.rounded())):\(Int(size.height.rounded()))"
  }
}

/// Which stream the player opens: the original file, or the server's adaptive HLS stream,
/// converted live in memory, in the best quality the connection carries or up to a fixed size.
enum StreamingQuality: String, Codable, CaseIterable, Identifiable, Sendable {
  case original
  case automatic = "auto"
  case p1080 = "1080p"
  case p720 = "720p"
  case p480 = "480p"

  static let feature = "adaptive-streaming-v1"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .original: "Original"
    case .automatic: "Automatic"
    case .p1080: "Up to 1080p"
    case .p720: "Up to 720p"
    case .p480: "Up to 480p"
    }
  }

  /// The tallest picture VLC may pick from the master playlist, or nil for any.
  var maximumHeight: Int? {
    switch self {
    case .original, .automatic: nil
    case .p1080: 1080
    case .p720: 720
    case .p480: 480
    }
  }

  /// What plays when the server can or cannot stream adaptively.
  func effective(serverSupports: Bool) -> StreamingQuality { serverSupports ? self : .original }

  /// The address to play: the relay's stream itself, or its HLS master playlist below it.
  func playbackURL(for stream: URL) -> URL {
    guard self != .original else { return stream }
    return stream.appendingPathComponent("hls").appendingPathComponent("master.m3u8")
  }

  /// VLC's options for the HLS stream: a fixed quality caps the size and keeps to the best below it.
  var vlcOptions: [String] {
    guard self != .original else { return [] }
    var options = [":network-caching=1500"]
    if let maximumHeight {
      options.append(":adaptive-maxheight=\(maximumHeight)")
      options.append(":adaptive-logic=highest")
    }
    return options
  }
}
