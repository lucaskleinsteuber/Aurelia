import Foundation

struct IOSPlaybackTrackPreference: Codable, Equatable, Sendable {
  let language: String?
  let title: String

  init(language: String?, title: String) {
    self.language = language.map {
      String($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(32))
    }.flatMap { $0.isEmpty ? nil : $0 }
    self.title = String(
      title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(256))
  }
}

struct IOSPlaybackTrack: Identifiable, Equatable, Sendable {
  let id: Int32
  let title: String

  var preference: IOSPlaybackTrackPreference {
    var language: String?
    if let open = title.lastIndex(of: "["), let close = title[open...].firstIndex(of: "]") {
      language = String(title[title.index(after: open)..<close])
    }
    return IOSPlaybackTrackPreference(language: language, title: title)
  }

  static func matching(
    _ preference: IOSPlaybackTrackPreference?, in tracks: [Self]
  ) -> Self? {
    guard let preference else { return nil }
    if let exact = tracks.first(where: { $0.preference.title == preference.title }) { return exact }
    guard let language = preference.language else { return nil }
    return tracks.first(where: { $0.preference.language == language })
  }
}

/// What the player does while an episode's intro plays (Mac: IntroSkipping).
enum IOSIntroSkipping: String, Codable, CaseIterable, Identifiable, Sendable {
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

struct IOSPlaybackPreferences: Codable, Equatable, Sendable {
  static let supportedRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
  static let defaultValue = Self()

  var automaticResume = true
  var automaticallyPlayNextEpisode = true
  var defaultPlaybackRate: Double = 1
  var controlsDelay: TimeInterval = 4
  var seekInterval = 10
  var preferredAudioTrack: IOSPlaybackTrackPreference?
  // nil explicitly means Off, matching the default on the Mac.
  var preferredSubtitleTrack: IOSPlaybackTrackPreference?
  /// Softens loud scenes and lifts quiet dialogue.
  var dialogueBoost: DialogueBoost = .off
  var volumeLeveling: VolumeLeveling = .off
  /// The original file, or the server's live conversion in a quality the connection carries.
  var streamingQuality: IOSStreamingQuality = .original
  /// What the player does while an episode's intro plays.
  var introSkipping: IOSIntroSkipping = .button
  /// Up Next appears when the credits begin, not only in the last seconds.
  var upNextAtCredits = true
  /// After a movie or a series' last episode, the server's suggestion starts on its own.
  var playSuggestionsAutomatically = false
  /// Before a film that starts from its beginning: a made-up ad, trailers and the curtain.
  var cinemaMode = false
  var cinemaAds = true
  /// How many trailers of films nobody has watched yet, 0 to 3.
  var cinemaTrailers = 2
  /// Compatibility accessor for older code and the persisted Night Mode key.
  var nightMode: Bool {
    get { volumeLeveling != .off }
    set { volumeLeveling = newValue ? .standard : .off }
  }

  var normalized: Self {
    var value = self
    if !Self.supportedRates.contains(value.defaultPlaybackRate) { value.defaultPlaybackRate = 1 }
    value.cinemaTrailers = min(max(value.cinemaTrailers, 0), 3)
    value.controlsDelay = value.controlsDelay.isFinite ? min(max(value.controlsDelay, 1), 10) : 4
    value.seekInterval = min(max(value.seekInterval, 5), 60)
    value.preferredAudioTrack = value.preferredAudioTrack.map {
      IOSPlaybackTrackPreference(language: $0.language, title: $0.title)
    }
    value.preferredSubtitleTrack = value.preferredSubtitleTrack.map {
      IOSPlaybackTrackPreference(language: $0.language, title: $0.title)
    }
    return value
  }

  init() {}

  private enum CodingKeys: String, CodingKey {
    case automaticResume, automaticallyPlayNextEpisode, defaultPlaybackRate, controlsDelay
    case seekInterval, preferredAudioTrack, preferredSubtitleTrack, nightMode, dialogueBoost,
      volumeLeveling, streamingQuality, introSkipping, upNextAtCredits, cinemaMode, cinemaAds,
      cinemaTrailers, playSuggestionsAutomatically
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    automaticResume = try values.decodeIfPresent(Bool.self, forKey: .automaticResume) ?? true
    automaticallyPlayNextEpisode =
      try values.decodeIfPresent(Bool.self, forKey: .automaticallyPlayNextEpisode) ?? true
    defaultPlaybackRate = try values.decodeIfPresent(Double.self, forKey: .defaultPlaybackRate) ?? 1
    controlsDelay = try values.decodeIfPresent(Double.self, forKey: .controlsDelay) ?? 4
    seekInterval = try values.decodeIfPresent(Int.self, forKey: .seekInterval) ?? 10
    preferredAudioTrack = try values.decodeIfPresent(
      IOSPlaybackTrackPreference.self, forKey: .preferredAudioTrack)
    preferredSubtitleTrack = try values.decodeIfPresent(
      IOSPlaybackTrackPreference.self, forKey: .preferredSubtitleTrack)
    let legacy = try values.decodeIfPresent(Bool.self, forKey: .nightMode) ?? false
    volumeLeveling =
      try values.decodeIfPresent(VolumeLeveling.self, forKey: .volumeLeveling)
      ?? (legacy ? .standard : .off)
    dialogueBoost = try values.decodeIfPresent(DialogueBoost.self, forKey: .dialogueBoost) ?? .off
    streamingQuality =
      (try? values.decodeIfPresent(IOSStreamingQuality.self, forKey: .streamingQuality)) ?? .original
    introSkipping =
      (try? values.decodeIfPresent(IOSIntroSkipping.self, forKey: .introSkipping)) ?? .button
    upNextAtCredits = try values.decodeIfPresent(Bool.self, forKey: .upNextAtCredits) ?? true
    cinemaMode = try values.decodeIfPresent(Bool.self, forKey: .cinemaMode) ?? false
    cinemaAds = try values.decodeIfPresent(Bool.self, forKey: .cinemaAds) ?? true
    cinemaTrailers = try values.decodeIfPresent(Int.self, forKey: .cinemaTrailers) ?? 2
    playSuggestionsAutomatically =
      try values.decodeIfPresent(Bool.self, forKey: .playSuggestionsAutomatically) ?? false
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(automaticResume, forKey: .automaticResume)
    try values.encode(automaticallyPlayNextEpisode, forKey: .automaticallyPlayNextEpisode)
    try values.encode(defaultPlaybackRate, forKey: .defaultPlaybackRate)
    try values.encode(controlsDelay, forKey: .controlsDelay)
    try values.encode(seekInterval, forKey: .seekInterval)
    try values.encode(preferredAudioTrack, forKey: .preferredAudioTrack)
    try values.encode(preferredSubtitleTrack, forKey: .preferredSubtitleTrack)
    try values.encode(nightMode, forKey: .nightMode)
    try values.encode(dialogueBoost, forKey: .dialogueBoost)
    try values.encode(volumeLeveling, forKey: .volumeLeveling)
    try values.encode(streamingQuality, forKey: .streamingQuality)
    try values.encode(introSkipping, forKey: .introSkipping)
    try values.encode(upNextAtCredits, forKey: .upNextAtCredits)
    try values.encode(cinemaMode, forKey: .cinemaMode)
    try values.encode(cinemaAds, forKey: .cinemaAds)
    try values.encode(cinemaTrailers, forKey: .cinemaTrailers)
    try values.encode(playSuggestionsAutomatically, forKey: .playSuggestionsAutomatically)
  }

  /// These preferences with a series' own track choices, where it has them.
  func applying(_ choice: IOSSeriesTrackChoice?) -> Self {
    guard let choice else { return self }
    var value = self
    if let audio = choice.audio { value.preferredAudioTrack = audio }
    if choice.subtitleChosen { value.preferredSubtitleTrack = choice.subtitle }
    return value
  }
}

/// Audio and subtitle choices made in one series. `subtitleChosen` tells "subtitles off" apart
/// from "never chosen here".
struct IOSSeriesTrackChoice: Codable, Equatable, Sendable {
  var audio: IOSPlaybackTrackPreference?
  var subtitle: IOSPlaybackTrackPreference?
  var subtitleChosen = false
  var updatedAt: Date
}

@MainActor
final class IOSPlaybackPreferencesStore {
  static let shared = IOSPlaybackPreferencesStore()
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  func preferences(serverID: UUID, profileID: UUID) -> IOSPlaybackPreferences {
    guard let data = defaults.data(forKey: key(serverID: serverID, profileID: profileID)),
      data.count <= 4_096,
      let value = try? JSONDecoder().decode(IOSPlaybackPreferences.self, from: data)
    else { return .defaultValue }
    return value.normalized
  }

  @discardableResult
  func save(_ value: IOSPlaybackPreferences, serverID: UUID, profileID: UUID) -> Bool {
    guard let data = try? JSONEncoder().encode(value.normalized), data.count <= 4_096 else {
      return false
    }
    let storageKey = key(serverID: serverID, profileID: profileID)
    defaults.set(data, forKey: storageKey)
    return defaults.data(forKey: storageKey) == data
  }

  /// The most recently used series are kept; older ones fall back to the profile's last choice.
  static let seriesLimit = 200

  func seriesChoice(seriesID: UUID, serverID: UUID, profileID: UUID) -> IOSSeriesTrackChoice? {
    seriesChoices(serverID: serverID, profileID: profileID)[seriesID.uuidString]
  }

  func updateSeriesChoice(
    seriesID: UUID, serverID: UUID, profileID: UUID, _ change: (inout IOSSeriesTrackChoice) -> Void
  ) {
    var choices = seriesChoices(serverID: serverID, profileID: profileID)
    var choice = choices[seriesID.uuidString] ?? IOSSeriesTrackChoice(updatedAt: Date())
    change(&choice)
    choice.updatedAt = Date()
    choices[seriesID.uuidString] = choice
    if choices.count > Self.seriesLimit {
      for key in choices.sorted(by: { $0.value.updatedAt < $1.value.updatedAt })
        .prefix(choices.count - Self.seriesLimit).map(\.key)
      {
        choices.removeValue(forKey: key)
      }
    }
    if let data = try? JSONEncoder().encode(choices) {
      defaults.set(data, forKey: seriesKey(serverID: serverID, profileID: profileID))
    }
  }

  func forgetSeriesChoices(serverID: UUID, profileID: UUID) {
    defaults.removeObject(forKey: seriesKey(serverID: serverID, profileID: profileID))
  }

  private func seriesChoices(serverID: UUID, profileID: UUID) -> [String: IOSSeriesTrackChoice] {
    defaults.data(forKey: seriesKey(serverID: serverID, profileID: profileID)).flatMap {
      try? JSONDecoder().decode([String: IOSSeriesTrackChoice].self, from: $0)
    } ?? [:]
  }

  private func key(serverID: UUID, profileID: UUID) -> String {
    "tv.playback.preferences.v1.\(serverID.uuidString).\(profileID.uuidString)"
  }

  private func seriesKey(serverID: UUID, profileID: UUID) -> String {
    "tv.playback.seriesTracks.v1.\(serverID.uuidString).\(profileID.uuidString)"
  }
}

/// Which stream the player opens: the original file, or the server's adaptive HLS stream,
/// converted live in memory, in the best quality the connection carries or up to a fixed size.
enum IOSStreamingQuality: String, Codable, CaseIterable, Identifiable, Sendable {
  case original
  case automatic = "auto"
  case p1080 = "1080p"
  case p720 = "720p"
  case p480 = "480p"

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

  var maximumHeight: Int? {
    switch self {
    case .original, .automatic: nil
    case .p1080: 1080
    case .p720: 720
    case .p480: 480
    }
  }

  func effective(serverSupports: Bool) -> Self { serverSupports ? self : .original }

  /// The relay's stream itself, or its HLS master playlist below it.
  func playbackURL(for stream: URL) -> URL {
    guard self != .original else { return stream }
    return stream.appendingPathComponent("hls").appendingPathComponent("master.m3u8")
  }

  /// VLC's options: more buffer for HLS, and a fixed quality caps the size and keeps to the best below it.
  var vlcOptions: [String] {
    guard self != .original else { return [":network-caching=500"] }
    var options = [":network-caching=1500"]
    if let maximumHeight {
      options.append(":adaptive-maxheight=\(maximumHeight)")
      options.append(":adaptive-logic=highest")
    }
    return options
  }
}
