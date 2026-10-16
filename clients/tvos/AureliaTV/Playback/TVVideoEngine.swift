import Foundation
@preconcurrency import TVVLCKit
import UIKit

struct TVPlaybackTrack: Identifiable, Equatable {
  let id: Int32
  let title: String
}

@MainActor
final class TVVideoEngine {
  enum Terminal: Equatable { case ended, failed }

  var onUpdate: (() -> Void)?
  var onTerminal: ((Terminal) -> Void)?

  private var player = TVVideoEngine.makePlayer()
  private weak var videoView: UIView?
  private var observers: [NSObjectProtocol] = []
  private var generation = UUID()
  private var acceptsEvents = false
  private var deliveredTerminal = false
  private var pendingResume: Int64?
  private var lastTime: Int64 = 0
  private var lastDuration: Int64 = 0
  private(set) var hasObservedPlayback = false

  var isActive: Bool { acceptsEvents && player.media != nil }
  var isPlaying: Bool { player.isPlaying }
  var isLoading: Bool { player.state == .opening || player.state == .buffering }
  var isSeekable: Bool { player.isSeekable }
  var position: Int64 {
    capture()
    return lastTime
  }
  var duration: Int64 {
    capture()
    return lastDuration
  }
  var audioTracks: [TVPlaybackTrack] {
    tracks(names: player.audioTrackNames, indexes: player.audioTrackIndexes)
  }
  var subtitleTracks: [TVPlaybackTrack] {
    tracks(names: player.videoSubTitlesNames, indexes: player.videoSubTitlesIndexes)
  }
  var audioTrackID: Int32 { player.currentAudioTrackIndex }
  var subtitleTrackID: Int32 { player.currentVideoSubTitleIndex }

  func attach(to view: UIView) {
    videoView = view
    player.drawable = view
  }

  func load(url: URL, resumeAt: Int64) {
    stop()
    player = Self.makePlayer()
    player.drawable = videoView
    generation = UUID()
    acceptsEvents = true
    deliveredTerminal = false
    lastTime = 0
    lastDuration = 0
    hasObservedPlayback = false
    pendingResume = resumeAt > 0 ? resumeAt : nil
    let operation = generation
    for name in [VLCMediaPlayerTimeChanged, VLCMediaPlayerStateChanged] {
      let observer = NotificationCenter.default.addObserver(
        forName: Notification.Name(rawValue: name), object: player, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.acceptsEvents, operation == self.generation else { return }
          let state = self.player.state
          self.capture()
          self.applyResume()
          self.onUpdate?()
          guard !self.deliveredTerminal else { return }
          if state == .ended || state == .error {
            self.deliveredTerminal = true
            self.onTerminal?(state == .ended ? .ended : .failed)
          }
        }
      }
      observers.append(observer)
    }
    let media = VLCMedia(url: url)
    // The decoder sees only a random loopback route. All remote TLS and
    // authentication is performed by TVStreamRelay, with no video disk cache.
    media.addOption(":network-caching=1000")
    player.media = media
    player.play()
  }

  func play() { if player.media != nil { player.play() } }
  func pause() {
    player.pause()
    capture()
    onUpdate?()
  }

  func stop() {
    capture()
    acceptsEvents = false
    generation = UUID()
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    pendingResume = nil
    player.stop()
    player.drawable = nil
    player.media = nil
  }

  func seek(to milliseconds: Int64) {
    guard player.isSeekable else { return }
    pendingResume = nil
    player.time = VLCTime(number: NSNumber(value: max(0, milliseconds)))
    onUpdate?()
  }

  func selectAudioTrack(_ id: Int32) {
    player.currentAudioTrackIndex = id
    onUpdate?()
  }
  func selectSubtitleTrack(_ id: Int32) {
    player.currentVideoSubTitleIndex = id
    onUpdate?()
  }

  private func applyResume() {
    guard let position = pendingResume, player.isSeekable,
      player.state == .playing || player.state == .paused
    else { return }
    pendingResume = nil
    let upper = duration > 0 ? min(position, max(0, duration - 500)) : position
    player.time = VLCTime(number: NSNumber(value: upper))
  }

  private func capture() {
    let knownDuration = player.media?.length.value?.int64Value ?? 0
    if knownDuration > 0 { lastDuration = knownDuration }
    let current = player.time.value?.int64Value ?? -1
    switch player.state {
    case .playing:
      if current >= 0 {
        if current > lastTime, current - lastTime <= 5_000 { hasObservedPlayback = true }
        lastTime = current
      }
    case .ended, .error:
      if current > 0 { lastTime = max(lastTime, current) }
    case .paused:
      if current >= 0 { lastTime = current }
    case .opening, .buffering:
      if current > 0 { lastTime = current }
    default:
      break
    }
  }

  private func tracks(names: [Any], indexes: [Any]) -> [TVPlaybackTrack] {
    zip(names, indexes).compactMap { name, index in
      guard let title = name as? String, let number = index as? NSNumber, number.int32Value >= 0
      else { return nil }
      let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
      return TVPlaybackTrack(
        id: number.int32Value, title: trimmed.isEmpty ? "Unknown track" : trimmed)
    }
  }

  private static func makePlayer() -> VLCMediaPlayer {
    VLCMediaPlayer(options: [
      "--quiet", "--no-video-title-show", "--no-play-and-pause", "--no-metadata-network-access",
    ])
  }
}
