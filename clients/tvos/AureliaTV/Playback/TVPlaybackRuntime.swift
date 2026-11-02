import Foundation
import UIKit

enum TVVideoTerminal: Equatable { case ended, failed }

@MainActor
protocol TVPlaybackEngine: AnyObject {
  var onUpdate: (() -> Void)? { get set }
  var onTerminal: ((TVVideoTerminal) -> Void)? { get set }
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
  var audioTracks: [TVPlaybackTrack] { get }
  var subtitleTracks: [TVPlaybackTrack] { get }
  var audioTrackID: Int32 { get }
  var subtitleTrackID: Int32 { get }
  var audioProcessingError: String? { get }
  func applyDialogueBoost(_ mode: DialogueBoost) -> AudioChangeResult
  func applyPreferences(_ preferences: TVPlaybackPreferences)
  func sample()
  func attach(to view: UIView)
  func load(url: URL, resumeAt: Int64)
  func play()
  func pause()
  func stop()
  func seek(to milliseconds: Int64)
  func selectAudioTrack(_ id: Int32)
  func selectSubtitleTrack(_ id: Int32)
  func addSubtitleSlave(url: URL)
}

extension TVPlaybackEngine {
  var audioProcessingError: String? { nil }
  func applyDialogueBoost(_ mode: DialogueBoost) -> AudioChangeResult { .applied }
  func addSubtitleSlave(url: URL) {}
}

protocol TVPlaybackRelay: AnyObject, Sendable {
  func start() async throws -> URL
  func stop()
  func updateSourceURL(_ url: URL)
  func setFailureHandler(_ handler: @escaping @MainActor @Sendable (TVStreamFailure) -> Void)
  func subtitleURL(index: Int) -> URL?
}

extension TVPlaybackRelay {
  func subtitleURL(index: Int) -> URL? { nil }
}

extension TVStreamRelay: TVPlaybackRelay {}

@MainActor
struct TVPlaybackRuntime {
  let engine: any TVPlaybackEngine
  let makeRelay: (URL, String, String) throws -> any TVPlaybackRelay
  let managesAudioSession: Bool
  /// A second relay for timeline previews; nil keeps previews off, as in the UI tests.
  var makePreviewRelay: ((URL, String, String) throws -> any TVPlaybackRelay)? = nil

  static func live() -> Self {
    Self(
      engine: TVVideoEngine(),
      makeRelay: { url, fingerprint, token in
        try TVStreamRelay(
          sourceURL: url, publicKeyFingerprint: fingerprint, authorizationToken: token)
      }, managesAudioSession: true,
      makePreviewRelay: { url, fingerprint, token in
        try TVStreamRelay(
          sourceURL: url, publicKeyFingerprint: fingerprint, authorizationToken: token,
          streamPurpose: "preview")
      })
  }
}
