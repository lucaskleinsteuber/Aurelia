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
    automaticallyPlayNextEpisode: true)

  var automaticResume: Bool
  var defaultPlaybackRate: Double
  var defaultVolume: Double
  var controlsAutoHideDelay: Double
  var seekInterval: Int
  var preventSleepDuringPlayback: Bool
  var automaticallyPlayNextEpisode: Bool

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

@MainActor
final class VLCPlaybackEngine: PlaybackEngine {
  var onUpdate: (() -> Void)?
  var onEnded: (() -> Void)?
  var onError: ((String) -> Void)?

  private let player: VLCMediaPlayer
  private var timeObserver: NSObjectProtocol?
  private var stateObserver: NSObjectProtocol?
  private var appliedTrackPreferences = false

  init() {
    player = VLCMediaPlayer(options: [
      "--no-video-title-show",
      "--network-caching=1000",
      "--no-metadata-network-access",
    ])
    timeObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name(rawValue: VLCMediaPlayerTimeChanged),
      object: player,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.update() }
    }
    stateObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name(rawValue: VLCMediaPlayerStateChanged),
      object: player,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.stateChanged() }
    }
  }

  deinit {
    if let timeObserver { NotificationCenter.default.removeObserver(timeObserver) }
    if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
  }

  var isPlaying: Bool { player.isPlaying }

  var currentTimeMilliseconds: Int64 {
    max(0, player.time.value?.int64Value ?? 0)
  }

  var durationMilliseconds: Int64 {
    max(0, player.media?.length.value?.int64Value ?? 0)
  }

  var volume: Double {
    get { Double(player.audio?.volume ?? 100) / 100 }
    set { player.audio?.volume = Int32((min(max(newValue, 0), 1) * 100).rounded()) }
  }

  var isMuted: Bool {
    get { player.audio?.isMuted ?? false }
    set { player.audio?.isMuted = newValue }
  }

  var playbackRate: Double {
    get { Double(player.rate) }
    set { player.rate = Float(newValue) }
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
    player.drawable = view
  }

  func load(url: URL) {
    appliedTrackPreferences = false
    let media = VLCMedia(url: url)
    media.addOption(":http-reconnect")
    player.media = media
  }

  func play() {
    player.play()
  }

  func pause() {
    player.pause()
  }

  func stop() {
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
      PlaybackTrackPreferenceStore.shared.audio = track.preference
    }
    onUpdate?()
  }

  func selectSubtitleTrack(id: Int32?) {
    player.currentVideoSubTitleIndex = id ?? -1
    PlaybackTrackPreferenceStore.shared.subtitle = id.flatMap { selected in
      subtitleTracks.first(where: { $0.id == selected })?.preference
    }
    onUpdate?()
  }

  func selectChapter(index: Int32) {
    player.currentChapterIndex = index
    onUpdate?()
  }

  private func stateChanged() {
    applyTrackPreferencesIfNeeded()
    update()
    switch player.state {
    case .ended:
      onEnded?()
    case .error:
      onError?("The playback engine could not read this media stream.")
    default:
      break
    }
  }

  private func update() {
    applyTrackPreferencesIfNeeded()
    onUpdate?()
  }

  private func applyTrackPreferencesIfNeeded() {
    guard !appliedTrackPreferences, !audioTracks.isEmpty || !subtitleTracks.isEmpty else {
      return
    }
    appliedTrackPreferences = true

    if let preference = PlaybackTrackPreferenceStore.shared.audio,
      let track = bestMatch(preference, tracks: audioTracks)
    {
      player.currentAudioTrackIndex = track.id
    }
    if let preference = PlaybackTrackPreferenceStore.shared.subtitle,
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

@MainActor
final class PlaybackTrackPreferenceStore {
  static let shared = PlaybackTrackPreferenceStore()

  private let defaults = UserDefaults.standard
  private let audioKey = "playback.preferredAudioTrack"
  private let subtitleKey = "playback.preferredSubtitleTrack"

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
