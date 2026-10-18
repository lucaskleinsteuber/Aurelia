import Foundation
@preconcurrency import TVVLCKit
import UIKit

@MainActor
final class TVVideoEngine: TVPlaybackEngine {
  typealias Terminal = TVVideoTerminal

  var onUpdate: (() -> Void)?
  var onTerminal: ((Terminal) -> Void)?

  private var player = TVVideoEngine.makePlayer()
  private weak var videoView: UIView?
  private var observers: [NSObjectProtocol] = []
  private var samplingTask: Task<Void, Never>?
  private var generation = UUID()
  private var acceptsEvents = false
  private var deliveredTerminal = false
  private var isSampling = false
  private var pendingResume: Int64?
  private var machine = TVPlaybackStateMachine()
  private var preferences = TVPlaybackPreferences.defaultValue
  private var requestedRate: Double = 1
  private var appliedAudioPreference = false
  private var appliedSubtitlePreference = false
  private var pendingAudio: (id: Int32, deadline: TimeInterval)?
  private var pendingSubtitle: (id: Int32, deadline: TimeInterval)?
  private(set) var audioTracks: [TVPlaybackTrack] = []
  private(set) var subtitleTracks: [TVPlaybackTrack] = []
  private(set) var audioTrackID: Int32 = -1
  private(set) var subtitleTrackID: Int32 = -1

  var isActive: Bool { acceptsEvents && player.media != nil }
  var isPlaying: Bool { machine.state.isPlaying }
  var isLoading: Bool { machine.state.isLoading }
  var isSeekable: Bool { machine.state.isSeekable }
  var position: Int64 { machine.state.position }
  var duration: Int64 { machine.state.duration }
  var hasObservedPlayback: Bool { machine.state.hasObservedPlayback }
  var progressPosition: Int64? { machine.state.progressPosition }
  var audioSelectionPending: Bool { pendingAudio != nil }
  var subtitleSelectionPending: Bool { pendingSubtitle != nil }
  var playbackRate: Double {
    get { requestedRate }
    set {
      guard TVPlaybackPreferences.supportedRates.contains(newValue) else { return }
      requestedRate = newValue
      if isActive { player.rate = Float(newValue) }
    }
  }

  func applyPreferences(_ preferences: TVPlaybackPreferences) {
    self.preferences = preferences.normalized
    playbackRate = preferences.normalized.defaultPlaybackRate
    appliedAudioPreference = false
    appliedSubtitlePreference = false
    if isActive { sample() }
  }

  func attach(to view: UIView) {
    videoView = view
    player.drawable = view
  }

  func load(url: URL, resumeAt: Int64) {
    stop()
    player = Self.makePlayer(nightMode: preferences.nightMode)
    player.drawable = videoView
    generation = UUID()
    acceptsEvents = true
    deliveredTerminal = false
    pendingResume = resumeAt > 0 ? resumeAt : nil
    appliedAudioPreference = false
    appliedSubtitlePreference = false
    machine.reset(at: now)
    let operation = generation
    for name in [VLCMediaPlayerTimeChanged, VLCMediaPlayerStateChanged] {
      let observer = NotificationCenter.default.addObserver(
        forName: Notification.Name(rawValue: name), object: player, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.acceptsEvents, operation == self.generation else { return }
          self.sample()
        }
      }
      observers.append(observer)
    }
    let media = VLCMedia(url: url)
    // The decoder sees only a random loopback route. All remote TLS and
    // authentication is performed by TVStreamRelay, with no video disk cache.
    // Half a second of prebuffer keeps seeks quick on a local network.
    media.addOption(":network-caching=500")
    player.media = media
    player.play()
    player.rate = Float(requestedRate)
    samplingTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        guard let self, self.acceptsEvents, operation == self.generation else { return }
        self.sample()
      }
    }
  }

  func play() {
    guard isActive else { return }
    machine.setWantsPlayback(true)
    player.play()
    player.rate = Float(requestedRate)
    sample()
  }

  func pause() {
    guard isActive else { return }
    // Capture the moving clock before the driver's pause notification can reset it.
    sample(notify: false)
    machine.setWantsPlayback(false)
    player.pause()
    sample()
  }

  func stop() {
    if acceptsEvents { sample(notify: false) }
    acceptsEvents = false
    generation = UUID()
    samplingTask?.cancel()
    samplingTask = nil
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    pendingResume = nil
    pendingAudio = nil
    pendingSubtitle = nil
    machine.stop()
    player.stop()
    player.drawable = nil
    player.media = nil
    audioTracks = []
    subtitleTracks = []
  }

  func seek(to milliseconds: Int64) {
    guard isActive, player.isSeekable else { return }
    pendingResume = nil
    let target = TVPlayerPolicy.seekPosition(current: 0, offset: milliseconds, duration: duration)
    machine.seek(to: target, at: now)
    player.time = VLCTime(number: NSNumber(value: target))
    sample()
  }

  func selectAudioTrack(_ id: Int32) {
    guard isActive, audioTracks.contains(where: { $0.id == id }) else { return }
    appliedAudioPreference = true
    pendingAudio = (id, now + 2)
    player.currentAudioTrackIndex = id
    sample()
  }

  func selectSubtitleTrack(_ id: Int32) {
    guard isActive, id == -1 || subtitleTracks.contains(where: { $0.id == id }) else { return }
    appliedSubtitlePreference = true
    pendingSubtitle = (id, now + 2)
    player.currentVideoSubTitleIndex = id
    sample()
  }

  func sample() { sample(notify: true) }

  private func sample(notify: Bool) {
    guard acceptsEvents, !isSampling else { return }
    isSampling = true
    defer { isSampling = false }
    let rawState = decoderState
    let time = now
    machine.update(
      TVDecoderSnapshot(
        state: rawState, position: player.time.value?.int64Value,
        duration: player.media?.length.value?.int64Value,
        isPlaying: player.isPlaying, isSeekable: player.isSeekable),
      at: time, playbackRate: requestedRate)
    applyResume()
    if machine.state.isPlaying, abs(Double(player.rate) - requestedRate) > 0.01 {
      player.rate = Float(requestedRate)
    }
    audioTracks = tracks(names: player.audioTrackNames, indexes: player.audioTrackIndexes)
    subtitleTracks = tracks(
      names: player.videoSubTitlesNames, indexes: player.videoSubTitlesIndexes)
    audioTrackID = player.currentAudioTrackIndex
    subtitleTrackID = player.currentVideoSubTitleIndex
    if let pendingAudio, audioTrackID == pendingAudio.id || time >= pendingAudio.deadline {
      self.pendingAudio = nil
    }
    if let pendingSubtitle,
      subtitleTrackID == pendingSubtitle.id || time >= pendingSubtitle.deadline
    {
      self.pendingSubtitle = nil
    }
    applyTrackPreferences()
    if notify { onUpdate?() }
    guard notify, !deliveredTerminal, rawState == .ended || rawState == .failed else { return }
    deliveredTerminal = true
    onTerminal?(rawState == .ended ? .ended : .failed)
  }

  private func applyResume() {
    guard let resume = pendingResume, player.isSeekable,
      decoderState == .playing || decoderState == .paused || decoderState == .buffering
    else { return }
    pendingResume = nil
    let target = TVPlayerPolicy.seekPosition(current: 0, offset: resume, duration: duration)
    machine.seek(to: target, at: now)
    player.time = VLCTime(number: NSNumber(value: target))
  }

  private func applyTrackPreferences() {
    if !appliedAudioPreference, !audioTracks.isEmpty {
      if let track = TVPlaybackTrack.matching(preferences.preferredAudioTrack, in: audioTracks) {
        pendingAudio = (track.id, now + 2)
        player.currentAudioTrackIndex = track.id
      }
      // The matching track can arrive in a later parse update; keep checking
      // until a match exists. No preference means the driver's default audio.
      appliedAudioPreference = preferences.preferredAudioTrack == nil || pendingAudio != nil
    }
    if !appliedSubtitlePreference, !subtitleTracks.isEmpty {
      if let preference = preferences.preferredSubtitleTrack {
        if let track = TVPlaybackTrack.matching(preference, in: subtitleTracks) {
          pendingSubtitle = (track.id, now + 2)
          player.currentVideoSubTitleIndex = track.id
          appliedSubtitlePreference = true
        }
      } else {
        pendingSubtitle = (-1, now + 2)
        player.currentVideoSubTitleIndex = -1
        appliedSubtitlePreference = true
      }
    }
  }

  private var decoderState: TVDecoderState {
    switch player.state {
    case .opening: .opening
    case .buffering: .buffering
    case .esAdded: .streamsAdded
    case .playing: .playing
    case .paused: .paused
    case .ended: .ended
    case .error: .failed
    default: .stopped
    }
  }

  private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

  private func tracks(names: [Any], indexes: [Any]) -> [TVPlaybackTrack] {
    var seen = Set<Int32>()
    return zip(names, indexes).compactMap { name, index in
      guard let title = name as? String, let number = index as? NSNumber,
        number.int32Value >= 0, seen.insert(number.int32Value).inserted
      else { return nil }
      let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
      return TVPlaybackTrack(
        id: number.int32Value, title: trimmed.isEmpty ? "Unknown track" : trimmed)
    }
  }

  /// Night mode compresses the soundtrack: peaks above -24 dB are reduced 4:1 and the result is
  /// raised by 12 dB, so explosions stay calmer and quiet speech becomes easier to hear.
  static let nightModeOptions = [
    "--compressor-rms-peak=0.2", "--compressor-attack=15", "--compressor-release=300",
    "--compressor-threshold=-24", "--compressor-ratio=4", "--compressor-knee=6",
    "--compressor-makeup-gain=12",
  ]

  private static func makePlayer(nightMode: Bool = false) -> VLCMediaPlayer {
    let player = VLCMediaPlayer(
      options: [
        "--quiet", "--no-video-title-show", "--no-play-and-pause", "--no-metadata-network-access",
      ] + (nightMode ? nightModeOptions : []))
    if nightMode { TVAudioFilter.enable("compressor", on: player, output: "audiounit_ios") }
    return player
  }
}
