import Foundation
import UIKit

enum IOSVideoTerminal: Equatable { case ended, failed }

@MainActor
protocol IOSPlaybackEngine: AnyObject {
  var onUpdate: (() -> Void)? { get set }
  var onTerminal: ((IOSVideoTerminal) -> Void)? { get set }
  var isActive: Bool { get }
  var isPlaying: Bool { get }
  var isLoading: Bool { get }
  var isSeekable: Bool { get }
  var position: Int64 { get }
  var duration: Int64 { get }
  var hasObservedPlayback: Bool { get }
  var progressPosition: Int64? { get }
  var playbackRate: Double { get set }
  var audioSelectionPending: Bool { get }
  var subtitleSelectionPending: Bool { get }
  var audioTracks: [IOSPlaybackTrack] { get }
  var subtitleTracks: [IOSPlaybackTrack] { get }
  var audioTrackID: Int32 { get }
  var subtitleTrackID: Int32 { get }
  var audioProcessingError: String? { get }
  /// The file's chapters once the decoder has read them; empty without any.
  var chapters: [IOSPlaybackChapter] { get }
  func applyDialogueBoost(_ mode: DialogueBoost) -> AudioChangeResult
  func applyPreferences(_ preferences: IOSPlaybackPreferences)
  func sample()
  func attach(to view: UIView)
  func load(url: URL, resumeAt: Int64)
  func load(url: URL, resumeAt: Int64, paused: Bool)
  func play()
  func pause()
  func stop()
  func seek(to milliseconds: Int64)
  func selectAudioTrack(_ id: Int32)
  func selectSubtitleTrack(_ id: Int32)
  func addSubtitleSlave(url: URL)
}

extension IOSPlaybackEngine {
  func load(url: URL, resumeAt: Int64, paused: Bool) {
    load(url: url, resumeAt: resumeAt)
    if paused { pause() }
  }
  var audioProcessingError: String? { nil }
  var chapters: [IOSPlaybackChapter] { [] }
  func applyDialogueBoost(_ mode: DialogueBoost) -> AudioChangeResult { .applied }
  func addSubtitleSlave(url: URL) {}
}

protocol IOSPlaybackRelay: AnyObject, Sendable {
  func start() async throws -> URL
  func stop()
  func updateSourceURL(_ url: URL)
  func setFailureHandler(_ handler: @escaping @MainActor @Sendable (IOSStreamFailure) -> Void)
  func subtitleURL(index: Int) -> URL?
}

extension IOSPlaybackRelay {
  func subtitleURL(index: Int) -> URL? { nil }
}

extension IOSStreamRelay: IOSPlaybackRelay {}

@MainActor
struct IOSPlaybackRuntime {
  let engine: any IOSPlaybackEngine
  let makeRelay: (URL, String, String) throws -> any IOSPlaybackRelay
  let managesAudioSession: Bool
  /// A second relay for timeline previews; nil keeps previews off, as in the UI tests.
  var makePreviewRelay: ((URL, String, String) throws -> any IOSPlaybackRelay)? = nil
  var sleepTimerSleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
    try await Task.sleep(for: .seconds(seconds))
  }
  var setIdleTimerDisabled: @MainActor (Bool) -> Void = { disabled in
    UIApplication.shared.isIdleTimerDisabled = disabled
  }

  static func live() -> Self {
    Self(
      engine: IOSVideoEngine(),
      makeRelay: { url, fingerprint, token in
        try IOSStreamRelay(
          sourceURL: url, publicKeyFingerprint: fingerprint, authorizationToken: token)
      }, managesAudioSession: true,
      makePreviewRelay: { url, fingerprint, token in
        try IOSStreamRelay(
          sourceURL: url, publicKeyFingerprint: fingerprint, authorizationToken: token,
          streamPurpose: "preview")
      },
      setIdleTimerDisabled: { disabled in
        UIApplication.shared.isIdleTimerDisabled = disabled
      })
  }
}
