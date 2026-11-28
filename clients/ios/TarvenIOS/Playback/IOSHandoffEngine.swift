@preconcurrency import AVFoundation
import AVKit
import Foundation
import UIKit

/// The player's engine: VLC plays the original as before, and for Picture in Picture or an AirPlay
/// screen the title moves to Apple's player at the same position, over the server's HLS stream,
/// and back to VLC when that ends. The controller sees one engine throughout.
@MainActor
final class IOSHandoffEngine: NSObject, IOSPlaybackEngine {
  let vlc = IOSVideoEngine()
  let system = IOSSystemVideoEngine()
  private let systemView = IOSPlayerLayerView()
  private weak var hostView: UIView?
  private var pictureInPicture: AVPictureInPictureController?
  private var routeObserver: NSObjectProtocol?
  private var startTask: Task<Void, Never>?
  private var streamURL: URL?

  /// The server converts live (adaptive-streaming-v1) and this is not an offline title.
  var isSystemPlaybackAvailable = false
  /// Starts the relay on this device's network address for an AirPlay receiver, which can't reach
  /// 127.0.0.1, and answers its stream address.
  var networkStream: (@MainActor () async throws -> URL)?
  /// Told when the title moves between the players or a hand-over fails.
  var onPhaseChange: ((IOSSystemPlaybackPhase, String?) -> Void)?
  private(set) var phase: IOSSystemPlaybackPhase = .vlc

  var onUpdate: (() -> Void)?
  var onTerminal: ((IOSVideoTerminal) -> Void)?

  override init() {
    super.init()
    systemView.playerLayer.player = system.player
    systemView.playerLayer.videoGravity = .resizeAspect
    systemView.backgroundColor = .black
    systemView.isHidden = true
    vlc.onUpdate = { [weak self] in
      guard let self, self.phase == .vlc || self.isStarting else { return }
      self.onUpdate?()
    }
    vlc.onTerminal = { [weak self] terminal in
      guard let self, self.phase == .vlc else { return }
      self.onTerminal?(terminal)
    }
    system.onUpdate = { [weak self] in
      guard let self else { return }
      if case .starting(let reason, _, _) = self.phase, self.system.isReady {
        self.enter(.system(reason))
      }
      guard case .system = self.phase else { return }
      if self.phase.reason == .airPlay, !self.system.isExternalPlaybackActive,
        !self.currentRouteIsAirPlay
      {
        self.returnToVLC(message: nil)
        return
      }
      self.onUpdate?()
    }
    system.onTerminal = { [weak self] terminal in
      guard let self, self.phase != .vlc else { return }
      if terminal == .ended, case .system = self.phase {
        let ended = self.system.position
        self.returnToVLC(message: nil, at: ended, resume: false)
        self.onTerminal?(.ended)
      } else {
        self.returnToVLC(message: "Apple's player could not play this title, so it plays here.")
      }
    }
    routeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      // Delivered on the main queue, as asked for above.
      MainActor.assumeIsolated { self?.routeChanged() }
    }
  }

  private var isStarting: Bool {
    if case .starting = phase { return true }
    return false
  }

  private var currentRouteIsAirPlay: Bool {
    IOSSystemPlayback.isAirPlay(
      portTypes: AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue))
  }

  private var onSystem: Bool {
    if case .system = phase { return true }
    return false
  }

  // MARK: The engine the controller sees

  var isActive: Bool { onSystem ? system.isActive : vlc.isActive }
  var isPlaying: Bool { onSystem ? system.isPlaying : vlc.isPlaying }
  var isLoading: Bool { onSystem ? system.isLoading : (isStarting || vlc.isLoading) }
  var isSeekable: Bool { onSystem ? system.isSeekable : vlc.isSeekable }
  var position: Int64 {
    if case .starting(_, let position, _) = phase { return position }
    return onSystem ? system.position : vlc.position
  }
  var duration: Int64 { onSystem && system.duration > 0 ? system.duration : vlc.duration }
  var hasObservedPlayback: Bool { vlc.hasObservedPlayback || system.hasObservedPlayback }
  var progressPosition: Int64? {
    onSystem ? (system.hasObservedPlayback ? system.position : nil) : vlc.progressPosition
  }
  var playbackRate: Double {
    get { vlc.playbackRate }
    set {
      vlc.playbackRate = newValue
      system.setRate(newValue)
    }
  }
  var audioSelectionPending: Bool { onSystem ? false : vlc.audioSelectionPending }
  var subtitleSelectionPending: Bool { onSystem ? false : vlc.subtitleSelectionPending }
  // Apple's player has the file's default sound and no subtitles to choose from.
  var audioTracks: [IOSPlaybackTrack] { onSystem ? [] : vlc.audioTracks }
  var subtitleTracks: [IOSPlaybackTrack] { onSystem ? [] : vlc.subtitleTracks }
  var audioTrackID: Int32 { vlc.audioTrackID }
  var subtitleTrackID: Int32 { vlc.subtitleTrackID }
  var audioProcessingError: String? { vlc.audioProcessingError }
  var chapters: [IOSPlaybackChapter] { vlc.chapters }

  func applyDialogueBoost(_ mode: DialogueBoost) -> AudioChangeResult {
    vlc.applyDialogueBoost(mode)
  }
  func applyPreferences(_ preferences: IOSPlaybackPreferences) {
    vlc.applyPreferences(preferences)
  }
  func sample() { onSystem ? system.sample() : vlc.sample() }

  func attach(to view: UIView) {
    hostView = view
    vlc.attach(to: view)
    systemView.frame = view.bounds
    systemView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    if systemView.superview !== view { view.addSubview(systemView) }
  }

  func load(url: URL, resumeAt: Int64) { load(url: url, resumeAt: resumeAt, paused: false) }

  func load(url: URL, resumeAt: Int64, paused: Bool) {
    leaveSystem()
    enter(.vlc)
    streamURL = url
    vlc.load(url: url, resumeAt: resumeAt, paused: paused)
  }

  func play() { onSystem ? system.play() : vlc.play() }
  func pause() { onSystem ? system.pause() : vlc.pause() }

  func stop() {
    leaveSystem()
    enter(.vlc)
    vlc.stop()
  }

  func seek(to milliseconds: Int64) {
    onSystem ? system.seek(to: milliseconds) : vlc.seek(to: milliseconds)
  }
  func selectAudioTrack(_ id: Int32) { if !onSystem { vlc.selectAudioTrack(id) } }
  func selectSubtitleTrack(_ id: Int32) { if !onSystem { vlc.selectSubtitleTrack(id) } }
  func addSubtitleSlave(url: URL) { vlc.addSubtitleSlave(url: url) }

  // MARK: Picture in Picture

  var canStartPictureInPicture: Bool {
    isSystemPlaybackAvailable && phase == .vlc && streamURL != nil && vlc.isActive
      && AVPictureInPictureController.isPictureInPictureSupported()
  }

  /// Moves the title to Apple's player and into Picture in Picture.
  func startPictureInPicture() {
    guard canStartPictureInPicture, let streamURL else { return }
    begin(.pictureInPicture, url: IOSSystemPlayback.hlsURL(for: streamURL))
    let controller = AVPictureInPictureController(playerLayer: systemView.playerLayer)
    controller?.delegate = self
    pictureInPicture = controller
    startTask = Task { [weak self] in
      // Picture in Picture becomes possible once the layer shows the stream's first picture.
      for _ in 0..<80 {
        do { try await Task.sleep(for: .milliseconds(125)) } catch { return }
        guard let self, self.phase.reason == .pictureInPicture else { return }
        if let controller, controller.isPictureInPicturePossible, self.system.isReady {
          controller.startPictureInPicture()
          return
        }
      }
      self?.returnToVLC(message: "Picture in Picture could not start. Try again in a moment.")
    }
  }

  func stopPictureInPicture() {
    pictureInPicture?.stopPictureInPicture()
  }

  // MARK: AirPlay

  private func routeChanged() {
    if currentRouteIsAirPlay {
      guard isSystemPlaybackAvailable, phase == .vlc, vlc.isActive, let networkStream else {
        return
      }
      let position = vlc.position
      let playing = vlc.isPlaying
      vlc.pause()
      enter(.starting(.airPlay, position: position, playing: playing))
      startTask = Task { [weak self] in
        do {
          let url = try await networkStream()
          guard let self, self.phase.reason == .airPlay else { return }
          self.system.load(
            url: IOSSystemPlayback.hlsURL(for: url), resumeAt: position, paused: !playing)
          self.showSystemView(true)
        } catch {
          self?.returnToVLC(
            message: "AirPlay needs Wi-Fi to send the picture. The sound plays there instead.")
        }
      }
    } else if phase.reason == .airPlay {
      returnToVLC(message: nil)
    }
  }

  // MARK: Hand-over

  private func begin(_ reason: IOSSystemPlaybackReason, url: URL) {
    let position = vlc.position
    let playing = vlc.isPlaying
    vlc.pause()
    enter(.starting(reason, position: position, playing: playing))
    system.requestedRate = vlc.playbackRate
    system.load(url: url, resumeAt: position, paused: !playing)
    showSystemView(true)
  }

  private func enter(_ phase: IOSSystemPlaybackPhase, message: String? = nil) {
    guard self.phase != phase || message != nil else { return }
    self.phase = phase
    onPhaseChange?(phase, message)
    onUpdate?()
  }

  private func showSystemView(_ shown: Bool) {
    systemView.isHidden = !shown
    if shown { hostView?.bringSubviewToFront(systemView) }
  }

  /// Back to VLC at Apple's player's position; it plays on if Apple's player was playing.
  private func returnToVLC(message: String?, at end: Int64? = nil, resume: Bool? = nil) {
    guard phase != .vlc else { return }
    let started = onSystem
    let fallback: (position: Int64, playing: Bool)
    if case .starting(_, let position, let playing) = phase {
      fallback = (position, playing)
    } else {
      fallback = (system.position, system.isPlaying)
    }
    let position = started ? (end ?? fallback.position) : fallback.position
    let playing = resume ?? fallback.playing
    leaveSystem()
    enter(.vlc, message: message)
    vlc.seek(to: IOSSystemPlayback.returnPosition(position, duration: vlc.duration))
    if playing { vlc.play() }
  }

  private func leaveSystem() {
    startTask?.cancel()
    startTask = nil
    if pictureInPicture?.isPictureInPictureActive == true {
      pictureInPicture?.stopPictureInPicture()
    }
    pictureInPicture?.delegate = nil
    pictureInPicture = nil
    system.stop()
    showSystemView(false)
  }
}

extension IOSHandoffEngine: AVPictureInPictureControllerDelegate {
  // AVKit calls its delegate on the main thread; the hop keeps that explicit.
  nonisolated func pictureInPictureControllerDidStopPictureInPicture(
    _ controller: AVPictureInPictureController
  ) {
    Task { @MainActor [weak self] in
      guard let self, self.phase.reason == .pictureInPicture else { return }
      self.returnToVLC(message: nil)
    }
  }

  nonisolated func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    Task { @MainActor [weak self] in
      self?.returnToVLC(message: "Picture in Picture could not start. Try again in a moment.")
    }
  }

  nonisolated func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
      @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }
}
