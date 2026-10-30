import Foundation
import UIKit

#if canImport(MobileVLCKit)
  @preconcurrency import MobileVLCKit
#endif

@MainActor
public protocol IOSPlaybackEngine: AnyObject {
  var isPlaying: Bool { get }
  var isLoading: Bool { get }
  var positionMilliseconds: Int64 { get }
  var durationMilliseconds: Int64 { get }
  var onUpdate: (() -> Void)? { get set }
  var onEnded: (() -> Void)? { get set }

  func attach(to view: UIView)
  func play(url: URL, resumeMilliseconds: Int64?)
  func addSubtitleSlave(url: URL)
  func togglePlayPause()
  func seek(toMilliseconds: Int64)
  func stop()
}

@MainActor
public final class IOSVideoEngine: NSObject, IOSPlaybackEngine {
  public var onUpdate: (() -> Void)?
  public var onEnded: (() -> Void)?

  #if canImport(MobileVLCKit)
    private var player: VLCMediaPlayer?
  #endif
  private weak var targetView: UIView?
  private var timer: Timer?
  private var stateMachine = IOSPlaybackStateMachine()

  public var isPlaying: Bool { stateMachine.state.isPlaying }
  public var isLoading: Bool { stateMachine.state.isLoading }
  public var positionMilliseconds: Int64 { stateMachine.state.positionMilliseconds }
  public var durationMilliseconds: Int64 { stateMachine.state.durationMilliseconds }

  public override init() {
    super.init()
    #if canImport(MobileVLCKit)
      let p = VLCMediaPlayer(options: [
        "--quiet",
        "--no-video-title-show",
        "--no-play-and-pause",
        "--no-metadata-network-access",
      ])
      self.player = p
    #endif
  }

  public func attach(to view: UIView) {
    self.targetView = view
    #if canImport(MobileVLCKit)
      player?.drawable = view
    #endif
  }

  public func play(url: URL, resumeMilliseconds: Int64?) {
    stateMachine.reset(at: ProcessInfo.processInfo.systemUptime)
    #if canImport(MobileVLCKit)
      guard let player else { return }
      let media = VLCMedia(url: url)
      player.media = media
      if let view = targetView {
        player.drawable = view
      }
      player.play()
      if let resume = resumeMilliseconds, resume > 0 {
        player.time = VLCTime(int: Int32(resume))
      }
    #endif

    startPolling()
  }

  public func addSubtitleSlave(url: URL) {
    #if canImport(MobileVLCKit)
      player?.addPlaybackSlave(url, type: .subtitle, enforce: true)
    #endif
  }

  public func togglePlayPause() {
    #if canImport(MobileVLCKit)
      guard let player else { return }
      if player.isPlaying {
        player.pause()
        stateMachine.setWantsPlayback(false)
      } else {
        player.play()
        stateMachine.setWantsPlayback(true)
      }
    #endif
    sample()
  }

  public func seek(toMilliseconds: Int64) {
    #if canImport(MobileVLCKit)
      player?.time = VLCTime(int: Int32(toMilliseconds))
    #endif
    sample()
  }

  public func stop() {
    timer?.invalidate()
    timer = nil
    #if canImport(MobileVLCKit)
      player?.stop()
      player?.drawable = nil
    #endif
    stateMachine.stop()
    onUpdate?()
  }

  private func startPolling() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.sample()
      }
    }
  }

  private func sample() {
    #if canImport(MobileVLCKit)
      guard let player else { return }
      let posMs = Int64(player.time.intValue)
      let durMs = Int64(player.media?.length.intValue ?? 0)

      let decState: IOSDecoderState
      switch player.state {
      case .opening: decState = .opening
      case .buffering: decState = .buffering
      case .esAdded: decState = .streamsAdded
      case .playing: decState = .playing
      case .paused: decState = .paused
      case .ended: decState = .ended
      case .error: decState = .failed
      default: decState = .stopped
      }

      let snapshot = IOSDecoderSnapshot(
        state: decState,
        positionMilliseconds: posMs,
        durationMilliseconds: durMs,
        isPlaying: player.isPlaying,
        isSeekable: player.isSeekable
      )
      let now = ProcessInfo.processInfo.systemUptime
      stateMachine.sample(snapshot, at: now)

      if decState == .ended {
        onEnded?()
      }
    #endif

    onUpdate?()
  }
}
