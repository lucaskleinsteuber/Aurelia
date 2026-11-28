@preconcurrency import AVFoundation
import AVKit
import Foundation
import UIKit

/// A view whose layer is Apple's player layer, for Picture in Picture and the picture while
/// Apple's player plays.
final class IOSPlayerLayerView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var playerLayer: AVPlayerLayer {
    guard let layer = layer as? AVPlayerLayer else {
      preconditionFailure("IOSPlayerLayerView's layer is an AVPlayerLayer.")
    }
    return layer
  }
}

/// Apple's player for the server's HLS stream, used while the title is in Picture in Picture or
/// on an AirPlay screen (IOSHandoffEngine). It has the file's default sound and no subtitles.
/// State is read every quarter second on the main actor; the one notification it observes is
/// delivered on the main queue.
@MainActor
final class IOSSystemVideoEngine {
  let player = AVPlayer()
  var onUpdate: (() -> Void)?
  var onTerminal: ((IOSVideoTerminal) -> Void)?

  private var samplingTask: Task<Void, Never>?
  private var endObserver: NSObjectProtocol?
  private var generation = UUID()
  private var wantsPlayback = false
  private(set) var hasObservedPlayback = false
  private var deliveredTerminal = false
  var requestedRate: Double = 1

  init() {
    player.allowsExternalPlayback = true
    player.usesExternalPlaybackWhileExternalScreenIsActive = true
  }

  var isActive: Bool { player.currentItem != nil }
  var isPlaying: Bool { isActive && player.timeControlStatus == .playing }
  var isLoading: Bool {
    guard let item = player.currentItem else { return false }
    return item.status != .readyToPlay
      || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
  }
  var isSeekable: Bool { player.currentItem?.status == .readyToPlay && duration > 0 }
  var isReady: Bool { player.currentItem?.status == .readyToPlay }
  var isExternalPlaybackActive: Bool { player.isExternalPlaybackActive }
  var position: Int64 {
    let time = player.currentTime()
    return time.isNumeric ? max(0, Int64(time.seconds * 1_000)) : 0
  }
  var duration: Int64 {
    guard let time = player.currentItem?.duration, time.isNumeric, time.seconds.isFinite else {
      return 0
    }
    return max(0, Int64(time.seconds * 1_000))
  }
  var failureMessage: String? {
    player.currentItem?.status == .failed
      ? (player.currentItem?.error?.localizedDescription ?? "Apple's player could not play this.")
      : nil
  }

  func load(url: URL, resumeAt: Int64, paused: Bool) {
    stop()
    let operation = UUID()
    generation = operation
    deliveredTerminal = false
    hasObservedPlayback = false
    let item = AVPlayerItem(url: url)
    item.preferredForwardBufferDuration = 12
    player.replaceCurrentItem(with: item)
    if resumeAt > 0 {
      player.seek(
        to: CMTime(value: resumeAt, timescale: 1_000), toleranceBefore: .zero,
        toleranceAfter: CMTime(value: 1, timescale: 2))
    }
    wantsPlayback = !paused
    if wantsPlayback { player.playImmediately(atRate: Float(requestedRate)) }
    endObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
    ) { [weak self] _ in
      // Delivered on the main queue, as asked for above.
      MainActor.assumeIsolated {
        guard let self, self.generation == operation else { return }
        self.deliver(.ended)
      }
    }
    samplingTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        guard let self, self.generation == operation else { return }
        self.sample()
      }
    }
  }

  func play() {
    wantsPlayback = true
    player.playImmediately(atRate: Float(requestedRate))
    onUpdate?()
  }

  func pause() {
    wantsPlayback = false
    player.pause()
    onUpdate?()
  }

  func seek(to milliseconds: Int64) {
    guard isActive else { return }
    let target = duration > 0 ? min(max(0, milliseconds), duration) : max(0, milliseconds)
    player.seek(
      to: CMTime(value: target, timescale: 1_000), toleranceBefore: .zero,
      toleranceAfter: .zero)
    onUpdate?()
  }

  func setRate(_ rate: Double) {
    requestedRate = rate
    if wantsPlayback, isActive { player.rate = Float(rate) }
  }

  func stop() {
    generation = UUID()
    samplingTask?.cancel()
    samplingTask = nil
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    wantsPlayback = false
  }

  func sample() {
    guard isActive else { return }
    if isPlaying { hasObservedPlayback = true }
    if failureMessage != nil {
      deliver(.failed)
      return
    }
    onUpdate?()
  }

  private func deliver(_ terminal: IOSVideoTerminal) {
    guard !deliveredTerminal else { return }
    deliveredTerminal = true
    onTerminal?(terminal)
  }
}
