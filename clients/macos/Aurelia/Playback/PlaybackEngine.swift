@preconcurrency import AppKit
import Combine
@preconcurrency import Foundation
@preconcurrency import VLCKit

@MainActor
protocol PlaybackEngine: AnyObject {
  var onUpdate: (() -> Void)? { get set }
  var onEnded: (() -> Void)? { get set }
  var onError: ((String) -> Void)? { get set }
  var isPlaying: Bool { get }
  var isSeekable: Bool { get }
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
  /// The active profile ID so track choices stay scoped per profile.
  var profileScope: UUID? { get set }

  func applyDialogueBoost(_ mode: DialogueBoost) -> AudioChangeResult
  func attach(to view: NSView)
  func load(url: URL)
  /// Opens `url` directly at `milliseconds`, where the engine can, instead of starting at the
  /// beginning and seeking once the title is known.
  func load(url: URL, startAt milliseconds: Int64)
  /// Whether `load(url:startAt:)` can open at the position; otherwise the caller seeks.
  var opensAtStartPosition: Bool { get }
  func play()
  func pause()
  func stop()
  func seek(to milliseconds: Int64)
  func selectAudioTrack(id: Int32)
  func selectSubtitleTrack(id: Int32?)
  func addSubtitleSlave(url: URL)
  func selectChapter(index: Int32)
}

extension PlaybackEngine {
  func applyDialogueBoost(_ mode: DialogueBoost) -> AudioChangeResult { .unavailable }
  var isSeekable: Bool { false }
  func load(url: URL, startAt milliseconds: Int64) { load(url: url) }
  func addSubtitleSlave(url: URL) {}
  var opensAtStartPosition: Bool { false }

  var trackScope: UUID? {
    get { nil }
    set {}
  }

  var profileScope: UUID? {
    get { nil }
    set {}
  }
}

@MainActor
final class VLCPlaybackEngine: PlaybackEngine {
  static let defaultPlayerOptions = [
    "--no-video-title-show",
    // Half a second of prebuffering after a seek, as on the Apple TV. A server on this Mac
    // needs less; see `networkCachingMilliseconds`.
    "--network-caching=500",
    "--no-metadata-network-access",
    // VLCKit's macOS defaults pause at EOF, suppressing the completion
    // event that drives progress completion and the next episode.
    "--no-play-and-pause",
  ]

  static let nightModeOptions = VolumeLeveling.standard.options

  static func playerOptions(nightMode: Bool) -> [String] {
    defaultPlayerOptions + (nightMode ? nightModeOptions : [])
  }

  /// Loads VLC's modules once, shortly after launch, so the first Play does not pay for it
  /// (about 40 ms); later players are created in about a millisecond.
  static func warmUp() {
    _ = makePlayer(nightMode: false).state
  }

  /// A player for one title; `output` is the audio output module, Core Audio by default.
  static func makePlayer(
    nightMode: Bool = false, output: String = "auhal", extraOptions: [String] = [],
    dialogueBoost: DialogueBoost = .off, volumeLeveling: VolumeLeveling? = nil
  ) -> VLCMediaPlayer {
    let processing = AudioProcessing(
      dialogue: dialogueBoost, leveling: volumeLeveling ?? (nightMode ? .standard : .off))
    let player = VLCMediaPlayer(
      options: defaultPlayerOptions + processing.leveling.options + extraOptions)
    if !processing.filters.isEmpty {
      _ = VLCAudioFilter.apply(processing, on: player, output: output)
    }
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
  var profileScope: UUID?
  /// Prebuffering before the picture starts and after a seek. The local relay reads a server
  /// on this Mac fast enough for 300 ms; remote servers keep the default 500 ms.
  var networkCachingMilliseconds: Int?
  var opensAtStartPosition: Bool { true }

  init(
    playerFactory: @escaping @MainActor () -> VLCMediaPlayer = {
      // A player is created for every title, so a changed night mode applies to the next load.
      VLCPlaybackEngine.makePlayer(
        dialogueBoost: PlaybackPreferencesStore.shared.preferences.dialogueBoost,
        volumeLeveling: PlaybackPreferencesStore.shared.preferences.volumeLeveling)
    }
  ) {
    self.playerFactory = playerFactory
    player = playerFactory()
  }

  func applyDialogueBoost(_ mode: DialogueBoost) -> AudioChangeResult {
    VLCAudioFilter.applyDialogue(
      mode, leveling: PlaybackPreferencesStore.shared.preferences.volumeLeveling, on: player)
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
  var isSeekable: Bool { player.isSeekable }

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
    load(url: url, startAt: 0)
  }

  func load(url: URL, startAt milliseconds: Int64) {
    retireCurrentPlayer()
    // A separate player prevents delayed terminal events from a previous input
    // from being interpreted as the end of a retry or the next episode.
    player = playerFactory()
    let preferences = PlaybackPreferencesStore.shared.preferences
    let processing = AudioProcessing(
      dialogue: preferences.dialogueBoost, leveling: preferences.volumeLeveling)
    guard
      processing.filters.isEmpty || VLCAudioFilter.apply(processing, on: player, output: "auhal")
    else {
      onError?(
        "Dialogue Boost or Volume Leveling is unavailable in this VLC installation. Turn it off in Playback settings."
      )
      return
    }
    player.drawable = attachedVideoView
    appliedTrackPreferences = false
    deliveredTerminalEvent = false
    lastKnownTimeMilliseconds = 0
    lastKnownDurationMilliseconds = 0
    acceptsPlayerEvents = true
    observeCurrentPlayer()
    let media = VLCMedia(url: url)
    media.addOption(":http-reconnect")
    if let networkCachingMilliseconds {
      media.addOption(":network-caching=\(networkCachingMilliseconds)")
    }
    if milliseconds > 0 {
      // Opening at the resume position avoids buffering the beginning only to seek away.
      media.addOption(":start-time=\(String(format: "%.3f", Double(milliseconds) / 1_000))")
    }
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
      PlaybackTrackPreferenceStore.shared.rememberAudio(
        track.preference, scope: trackScope, profileId: profileScope)
    }
    onUpdate?()
  }

  func selectSubtitleTrack(id: Int32?) {
    player.currentVideoSubTitleIndex = id ?? -1
    PlaybackTrackPreferenceStore.shared.rememberSubtitle(
      id.flatMap { selected in
        subtitleTracks.first(where: { $0.id == selected })?.preference
      }, scope: trackScope, profileId: profileScope)
    onUpdate?()
  }

  func addSubtitleSlave(url: URL) {
    player.addPlaybackSlave(url, type: .subtitle, enforce: false)
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
    let defaults = PlaybackPreferencesStore.shared.preferences
    if let preference = store.audio(scope: trackScope, profileId: profileScope) {
      if let track = bestMatch(preference, tracks: audioTracks) {
        player.currentAudioTrackIndex = track.id
      }
    } else if let track = PlaybackLanguage.track(
      in: audioTracks, for: defaults.defaultAudioLanguage)
    {
      player.currentAudioTrackIndex = track.id
    }
    let subChoice = store.subtitleChoice(scope: trackScope, profileId: profileScope)
    if !subChoice.chosen {
      // Without a choice for this series, Settings › Playback may pick a subtitle language;
      // otherwise the file's own default (such as forced subtitles) stays.
      if let track = PlaybackLanguage.track(
        in: subtitleTracks, for: defaults.defaultSubtitleLanguage)
      {
        player.currentVideoSubTitleIndex = track.id
      }
    } else {
      if let preference = subChoice.preference {
        if let track = bestMatch(preference, tracks: subtitleTracks) {
          player.currentVideoSubTitleIndex = track.id
        }
      } else {
        player.currentVideoSubTitleIndex = -1
      }
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
  private let baseAudioKey = "playback.preferredAudioTrack"
  private let baseSubtitleKey = "playback.preferredSubtitleTrack"
  private let baseSeriesKey = "playback.seriesTrackChoices.v1"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  private func audioKey(_ profileId: UUID?) -> String {
    profileId.map { "playback.preferredAudioTrack.\($0.uuidString)" } ?? baseAudioKey
  }

  private func subtitleKey(_ profileId: UUID?) -> String {
    profileId.map { "playback.preferredSubtitleTrack.\($0.uuidString)" } ?? baseSubtitleKey
  }

  private func seriesKey(_ profileId: UUID?) -> String {
    profileId.map { "playback.seriesTrackChoices.\($0.uuidString).v1" } ?? baseSeriesKey
  }

  /// The series' own choice, or else the last choice made anywhere for this profile.
  func audio(scope: UUID?, profileId: UUID? = nil) -> PlaybackTrackPreference? {
    scope.flatMap { seriesChoices(profileId: profileId)[$0.uuidString]?.audio }
      ?? load(key: audioKey(profileId))
  }

  /// Tells whether a subtitle choice was explicitly made, and returns the preferred track (nil if Off).
  func subtitleChoice(scope: UUID?, profileId: UUID? = nil) -> (
    chosen: Bool, preference: PlaybackTrackPreference?
  ) {
    if let scope, let choice = seriesChoices(profileId: profileId)[scope.uuidString],
      choice.subtitleChosen
    {
      return (true, choice.subtitle)
    }
    if let global = load(key: subtitleKey(profileId)) {
      return (true, global)
    }
    return (false, nil)
  }

  /// nil means subtitles off or unchosen.
  func subtitle(scope: UUID?, profileId: UUID? = nil) -> PlaybackTrackPreference? {
    subtitleChoice(scope: scope, profileId: profileId).preference
  }

  func rememberAudio(
    _ preference: PlaybackTrackPreference, scope: UUID?, profileId: UUID? = nil
  ) {
    save(preference, key: audioKey(profileId))
    updateSeries(scope, profileId: profileId) { $0.audio = preference }
  }

  func rememberSubtitle(
    _ preference: PlaybackTrackPreference?, scope: UUID?, profileId: UUID? = nil
  ) {
    save(preference, key: subtitleKey(profileId))
    updateSeries(scope, profileId: profileId) {
      $0.subtitle = preference
      $0.subtitleChosen = true
    }
  }

  func forgetAll(profileId: UUID? = nil) {
    save(nil, key: audioKey(profileId))
    save(nil, key: subtitleKey(profileId))
    defaults.removeObject(forKey: seriesKey(profileId))
    if profileId != nil {
      save(nil, key: baseAudioKey)
      save(nil, key: baseSubtitleKey)
      defaults.removeObject(forKey: baseSeriesKey)
    }
  }

  private func updateSeries(
    _ scope: UUID?, profileId: UUID? = nil, _ change: (inout SeriesTrackChoice) -> Void
  ) {
    guard let scope else { return }
    let key = seriesKey(profileId)
    var choices = seriesChoices(profileId: profileId)
    var choice = choices[scope.uuidString] ?? SeriesTrackChoice(updatedAt: Date())
    change(&choice)
    choice.updatedAt = Date()
    choices[scope.uuidString] = choice
    if choices.count > Self.seriesLimit {
      for oldKey in choices.sorted(by: { $0.value.updatedAt < $1.value.updatedAt })
        .prefix(choices.count - Self.seriesLimit).map(\.key)
      {
        choices.removeValue(forKey: oldKey)
      }
    }
    if let data = try? JSONEncoder().encode(choices) { defaults.set(data, forKey: key) }
  }

  private func seriesChoices(profileId: UUID? = nil) -> [String: SeriesTrackChoice] {
    let key = seriesKey(profileId)
    return defaults.data(forKey: key).flatMap {
      try? JSONDecoder().decode([String: SeriesTrackChoice].self, from: $0)
    } ?? [:]
  }

  var audio: PlaybackTrackPreference? {
    get { load(key: baseAudioKey) }
    set { save(newValue, key: baseAudioKey) }
  }

  var subtitle: PlaybackTrackPreference? {
    get { load(key: baseSubtitleKey) }
    set { save(newValue, key: baseSubtitleKey) }
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
