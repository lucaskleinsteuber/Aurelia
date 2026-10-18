@preconcurrency import AppKit
import Combine
@preconcurrency import Foundation
@preconcurrency import VLCKit

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
    nightMode: false)

  var automaticResume: Bool
  var defaultPlaybackRate: Double
  var defaultVolume: Double
  var controlsAutoHideDelay: Double
  var seekInterval: Int
  var preventSleepDuringPlayback: Bool
  var automaticallyPlayNextEpisode: Bool
  /// Softens loud scenes and lifts quiet dialogue.
  var nightMode: Bool

  var normalized: PlaybackPreferences {
    var value = self
    if !Self.supportedRates.contains(value.defaultPlaybackRate) {
      value.defaultPlaybackRate = 1
    }
    value.defaultVolume = min(max(value.defaultVolume, 0), 1)
    value.controlsAutoHideDelay = min(max(value.controlsAutoHideDelay, 1), 10)
    value.seekInterval = min(max(value.seekInterval, 5), 60)
    return value
  }
}

extension PlaybackPreferences {
  private enum CodingKeys: String, CodingKey {
    case automaticResume, defaultPlaybackRate, defaultVolume, controlsAutoHideDelay
    case seekInterval, preventSleepDuringPlayback, automaticallyPlayNextEpisode, nightMode
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
      nightMode: try container.decodeIfPresent(Bool.self, forKey: .nightMode) ?? false)
  }
}

@MainActor
protocol PlaybackEngine: AnyObject {
  var onUpdate: (() -> Void)? { get set }
  var onEnded: (() -> Void)? { get set }
  var onError: ((String) -> Void)? { get set }
  var isPlaying: Bool { get }
  var currentTimeMilliseconds: Int64 { get }
  var durationMilliseconds: Int64 { get }
  var volume: Double { get set }
  var isMuted: Bool { get set }
  var playbackRate: Double { get set }
  var audioTracks: [PlaybackTrack] { get }
  var subtitleTracks: [PlaybackTrack] { get }
  var chapters: [PlaybackChapter] { get }
  var currentChapterIndex: Int32? { get }
  var selectedAudioTrackID: Int32? { get }
  var selectedSubtitleTrackID: Int32? { get }
  /// The series whose audio and subtitle choices apply; set before `load(url:)`.
  var trackScope: UUID? { get set }

  func attach(to view: NSView)
  func load(url: URL)
  func play()
  func pause()
  func stop()
  func seek(to milliseconds: Int64)
  func selectAudioTrack(id: Int32)
  func selectSubtitleTrack(id: Int32?)
  func selectChapter(index: Int32)
}

extension PlaybackEngine {
  var trackScope: UUID? {
    get { nil }
    set {}
  }
}

@MainActor
final class VLCPlaybackEngine: PlaybackEngine {
  static let defaultPlayerOptions = [
    "--no-video-title-show",
    // Half a second of prebuffering after a seek, as on the Apple TV.
    "--network-caching=500",
    "--no-metadata-network-access",
    // VLCKit's macOS defaults pause at EOF, suppressing the completion
    // event that drives progress completion and the next episode.
    "--no-play-and-pause",
  ]

  /// Night mode compresses the soundtrack: peaks above -24 dB are reduced 4:1 and the result is
  /// raised by 12 dB, so explosions stay calmer and quiet speech becomes easier to hear. The
  /// compressor itself is switched on by `makePlayer(nightMode:output:)`.
  static let nightModeOptions = [
    "--compressor-rms-peak=0.2",
    "--compressor-attack=15",
    "--compressor-release=300",
    "--compressor-threshold=-24",
    "--compressor-ratio=4",
    "--compressor-knee=6",
    "--compressor-makeup-gain=12",
  ]

  static func playerOptions(nightMode: Bool) -> [String] {
    defaultPlayerOptions + (nightMode ? nightModeOptions : [])
  }

  /// A player for one title; `output` is the audio output module, Core Audio by default.
  static func makePlayer(nightMode: Bool, output: String = "auhal", extraOptions: [String] = [])
    -> VLCMediaPlayer
  {
    let player = VLCMediaPlayer(options: playerOptions(nightMode: nightMode) + extraOptions)
    if nightMode { VLCAudioFilter.enable("compressor", on: player, output: output) }
    return player
  }

  var onUpdate: (() -> Void)?
  var onEnded: (() -> Void)?
  var onError: ((String) -> Void)?

  private var player: VLCMediaPlayer
  private let playerFactory: @MainActor () -> VLCMediaPlayer
  private weak var attachedVideoView: NSView?
  private var timeObserver: NSObjectProtocol?
  private var stateObserver: NSObjectProtocol?
  private var appliedTrackPreferences = false
  private var playbackGeneration: UInt64 = 0
  private var acceptsPlayerEvents = false
  private var deliveredTerminalEvent = false
  private var lastKnownTimeMilliseconds: Int64 = 0
  private var lastKnownDurationMilliseconds: Int64 = 0
  private var requestedVolume: Double = 1
  private var requestedMuted = false
  private var requestedRate: Double = 1
  var trackScope: UUID?

  init(
    playerFactory: @escaping @MainActor () -> VLCMediaPlayer = {
      // A player is created for every title, so a changed night mode applies to the next load.
      VLCPlaybackEngine.makePlayer(
        nightMode: PlaybackPreferencesStore.shared.preferences.nightMode)
    }
  ) {
    self.playerFactory = playerFactory
    player = playerFactory()
  }

  private func observeCurrentPlayer() {
    let generation = playbackGeneration
    timeObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name(rawValue: VLCMediaPlayerTimeChanged),
      object: player,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.acceptsPlayerEvents, self.playbackGeneration == generation else {
          return
        }
        self.captureProgress()
        Task { @MainActor [weak self] in
          guard let self, self.acceptsPlayerEvents, self.playbackGeneration == generation else {
            return
          }
          self.update()
        }
      }
    }
    stateObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name(rawValue: VLCMediaPlayerStateChanged),
      object: player,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.acceptsPlayerEvents, self.playbackGeneration == generation else {
          return
        }
        // Snapshot before yielding: a following stopped event may replace
        // VLC's cached ended state before this MainActor task gets a turn.
        let state = self.player.state
        self.captureProgress()
        Task { @MainActor [weak self] in
          guard let self, self.acceptsPlayerEvents, self.playbackGeneration == generation else {
            return
          }
          self.stateChanged(state)
        }
      }
    }
  }

  deinit {
    if let timeObserver { NotificationCenter.default.removeObserver(timeObserver) }
    if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
  }

  var isPlaying: Bool { player.isPlaying }

  var currentTimeMilliseconds: Int64 {
    captureProgress()
    return lastKnownTimeMilliseconds
  }

  var durationMilliseconds: Int64 {
    captureProgress()
    return lastKnownDurationMilliseconds
  }

  var volume: Double {
    get { requestedVolume }
    set {
      requestedVolume = min(max(newValue, 0), 1)
      player.audio?.volume = Int32((requestedVolume * 100).rounded())
    }
  }

  var isMuted: Bool {
    get { requestedMuted }
    set {
      requestedMuted = newValue
      player.audio?.isMuted = newValue
    }
  }

  var playbackRate: Double {
    get { requestedRate }
    set {
      requestedRate = newValue
      player.rate = Float(newValue)
    }
  }

  var audioTracks: [PlaybackTrack] {
    tracks(names: player.audioTrackNames, indexes: player.audioTrackIndexes)
  }

  var subtitleTracks: [PlaybackTrack] {
    tracks(names: player.videoSubTitlesNames, indexes: player.videoSubTitlesIndexes)
  }

  var selectedAudioTrackID: Int32? {
    let value = player.currentAudioTrackIndex
    return value >= 0 ? value : nil
  }

  var selectedSubtitleTrackID: Int32? {
    let value = player.currentVideoSubTitleIndex
    return value >= 0 ? value : nil
  }

  var chapters: [PlaybackChapter] {
    let titleIndex = player.currentTitleIndex
    guard titleIndex >= 0 else { return [] }
    return player.chapterDescriptions(ofTitle: titleIndex).enumerated().compactMap { offset, raw in
      guard let values = raw as? [AnyHashable: Any] else { return nil }
      let time = chapterTime(values[VLCChapterDescriptionTimeOffset])
      let duration = chapterTime(values[VLCChapterDescriptionDuration])
      let suppliedTitle = values[VLCChapterDescriptionName] as? String
      let title = suppliedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return PlaybackChapter(
        index: Int32(offset),
        title: title.isEmpty ? "Chapter \(offset + 1)" : title,
        timeOffsetMilliseconds: max(0, time),
        durationMilliseconds: max(0, duration))
    }
  }

  var currentChapterIndex: Int32? {
    let value = player.currentChapterIndex
    return value >= 0 ? value : nil
  }

  func attach(to view: NSView) {
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.black.cgColor
    attachedVideoView = view
    player.drawable = view
  }

  func load(url: URL) {
    retireCurrentPlayer()
    // A separate player prevents delayed terminal events from a previous input
    // from being interpreted as the end of a retry or the next episode.
    player = playerFactory()
    player.drawable = attachedVideoView
    appliedTrackPreferences = false
    deliveredTerminalEvent = false
    lastKnownTimeMilliseconds = 0
    lastKnownDurationMilliseconds = 0
    acceptsPlayerEvents = true
    observeCurrentPlayer()
    let media = VLCMedia(url: url)
    media.addOption(":http-reconnect")
    player.media = media
    volume = requestedVolume
    isMuted = requestedMuted
    playbackRate = requestedRate
  }

  func play() {
    guard player.media != nil else { return }
    player.play()
  }

  func pause() {
    player.pause()
  }

  func stop() {
    captureProgress()
    retireCurrentPlayer()
  }

  private func retireCurrentPlayer() {
    acceptsPlayerEvents = false
    playbackGeneration &+= 1
    if let timeObserver { NotificationCenter.default.removeObserver(timeObserver) }
    if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
    timeObserver = nil
    stateObserver = nil
    player.stop()
    player.drawable = nil
    player.media = nil
  }

  func seek(to milliseconds: Int64) {
    player.time = VLCTime(number: NSNumber(value: max(milliseconds, 0)))
  }

  func selectAudioTrack(id: Int32) {
    player.currentAudioTrackIndex = id
    if let track = audioTracks.first(where: { $0.id == id }) {
      PlaybackTrackPreferenceStore.shared.rememberAudio(track.preference, scope: trackScope)
    }
    onUpdate?()
  }

  func selectSubtitleTrack(id: Int32?) {
    player.currentVideoSubTitleIndex = id ?? -1
    PlaybackTrackPreferenceStore.shared.rememberSubtitle(
      id.flatMap { selected in
        subtitleTracks.first(where: { $0.id == selected })?.preference
      }, scope: trackScope)
    onUpdate?()
  }

  func selectChapter(index: Int32) {
    player.currentChapterIndex = index
    onUpdate?()
  }

  private func stateChanged(_ state: VLCMediaPlayerState) {
    let generation = playbackGeneration
    update()
    guard acceptsPlayerEvents, generation == playbackGeneration else { return }
    switch state {
    case .ended:
      guard !deliveredTerminalEvent else { return }
      deliveredTerminalEvent = true
      onEnded?()
    case .error:
      guard !deliveredTerminalEvent else { return }
      deliveredTerminalEvent = true
      onError?("The playback engine could not read this media stream.")
    default:
      break
    }
  }

  private func update() {
    captureProgress()
    applyTrackPreferencesIfNeeded()
    onUpdate?()
  }

  private func captureProgress() {
    let duration = player.media?.length.value?.int64Value ?? 0
    if duration > 0 { lastKnownDurationMilliseconds = duration }
    let time = player.time.value?.int64Value ?? -1
    // VLC may reset its clock as an input closes. Preserve the last actual
    // position so the controller can distinguish an early EOF from completion.
    switch player.state {
    case .ended, .error:
      // A positive terminal clock is still useful. Do not infer position from
      // duration: a disconnected drive can produce EOF far before the end.
      if time > 0 { lastKnownTimeMilliseconds = max(lastKnownTimeMilliseconds, time) }
    case .stopped:
      return
    default:
      if time >= 0, time > 0 || lastKnownTimeMilliseconds == 0 || player.state != .buffering {
        lastKnownTimeMilliseconds = time
      }
    }
  }

  private func applyTrackPreferencesIfNeeded() {
    guard !appliedTrackPreferences, !audioTracks.isEmpty || !subtitleTracks.isEmpty else {
      return
    }
    appliedTrackPreferences = true

    let store = PlaybackTrackPreferenceStore.shared
    if let preference = store.audio(scope: trackScope),
      let track = bestMatch(preference, tracks: audioTracks)
    {
      player.currentAudioTrackIndex = track.id
    }
    if let preference = store.subtitle(scope: trackScope),
      let track = bestMatch(preference, tracks: subtitleTracks)
    {
      player.currentVideoSubTitleIndex = track.id
    } else {
      player.currentVideoSubTitleIndex = -1
    }
  }

  private func bestMatch(
    _ preference: PlaybackTrackPreference,
    tracks: [PlaybackTrack]
  ) -> PlaybackTrack? {
    tracks.first(where: { $0.preference == preference })
      ?? tracks.first(where: {
        preference.language != nil && $0.preference.language == preference.language
      })
  }

  private func tracks(names: [Any], indexes: [Any]) -> [PlaybackTrack] {
    zip(names, indexes).compactMap { name, index in
      guard let name = name as? String,
        let index = index as? NSNumber,
        index.int32Value >= 0
      else { return nil }
      return PlaybackTrack(id: index.int32Value, title: displayTitle(name))
    }
  }

  private func displayTitle(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Unknown track" : trimmed
  }

  private func chapterTime(_ value: Any?) -> Int64 {
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? VLCTime { return value.value?.int64Value ?? 0 }
    return 0
  }
}

@MainActor
final class PlaybackPreferencesStore: ObservableObject {
  static let shared = PlaybackPreferencesStore()

  @Published var preferences: PlaybackPreferences {
    didSet {
      let normalized = preferences.normalized
      if normalized != preferences { preferences = normalized }
      save(normalized)
    }
  }

  private let defaults: UserDefaults
  private let key = "playback.preferences.v1"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    preferences =
      defaults.data(forKey: key)
      .flatMap { try? JSONDecoder().decode(PlaybackPreferences.self, from: $0) }?
      .normalized ?? .defaultValue
  }

  func restoreDefaults() {
    preferences = .defaultValue
  }

  private func save(_ value: PlaybackPreferences) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: key)
  }
}

/// Audio and subtitle choices made in one series. `subtitleChosen` tells "subtitles off" apart
/// from "never chosen here".
struct SeriesTrackChoice: Codable, Equatable, Sendable {
  var audio: PlaybackTrackPreference?
  var subtitle: PlaybackTrackPreference?
  var subtitleChosen = false
  var updatedAt: Date
}

@MainActor
final class PlaybackTrackPreferenceStore {
  static let shared = PlaybackTrackPreferenceStore()
  /// The most recently used series are kept; older choices fall back to the last global choice.
  static let seriesLimit = 300

  private let defaults: UserDefaults
  private let audioKey = "playback.preferredAudioTrack"
  private let subtitleKey = "playback.preferredSubtitleTrack"
  private let seriesKey = "playback.seriesTrackChoices.v1"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The series' own choice, or else the last choice made anywhere.
  func audio(scope: UUID?) -> PlaybackTrackPreference? {
    scope.flatMap { seriesChoices()[$0.uuidString]?.audio } ?? audio
  }

  /// nil means subtitles off.
  func subtitle(scope: UUID?) -> PlaybackTrackPreference? {
    if let scope, let choice = seriesChoices()[scope.uuidString], choice.subtitleChosen {
      return choice.subtitle
    }
    return subtitle
  }

  func rememberAudio(_ preference: PlaybackTrackPreference, scope: UUID?) {
    audio = preference
    updateSeries(scope) { $0.audio = preference }
  }

  func rememberSubtitle(_ preference: PlaybackTrackPreference?, scope: UUID?) {
    subtitle = preference
    updateSeries(scope) {
      $0.subtitle = preference
      $0.subtitleChosen = true
    }
  }

  func forgetAll() {
    audio = nil
    subtitle = nil
    defaults.removeObject(forKey: seriesKey)
  }

  private func updateSeries(_ scope: UUID?, _ change: (inout SeriesTrackChoice) -> Void) {
    guard let scope else { return }
    var choices = seriesChoices()
    var choice = choices[scope.uuidString] ?? SeriesTrackChoice(updatedAt: Date())
    change(&choice)
    choice.updatedAt = Date()
    choices[scope.uuidString] = choice
    if choices.count > Self.seriesLimit {
      for key in choices.sorted(by: { $0.value.updatedAt < $1.value.updatedAt })
        .prefix(choices.count - Self.seriesLimit).map(\.key)
      {
        choices.removeValue(forKey: key)
      }
    }
    if let data = try? JSONEncoder().encode(choices) { defaults.set(data, forKey: seriesKey) }
  }

  private func seriesChoices() -> [String: SeriesTrackChoice] {
    defaults.data(forKey: seriesKey).flatMap {
      try? JSONDecoder().decode([String: SeriesTrackChoice].self, from: $0)
    } ?? [:]
  }

  var audio: PlaybackTrackPreference? {
    get { load(key: audioKey) }
    set { save(newValue, key: audioKey) }
  }

  var subtitle: PlaybackTrackPreference? {
    get { load(key: subtitleKey) }
    set { save(newValue, key: subtitleKey) }
  }

  private func load(key: String) -> PlaybackTrackPreference? {
    defaults.data(forKey: key).flatMap {
      try? JSONDecoder().decode(PlaybackTrackPreference.self, from: $0)
    }
  }

  private func save(_ value: PlaybackTrackPreference?, key: String) {
    if let value, let data = try? JSONEncoder().encode(value) {
      defaults.set(data, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }
}
