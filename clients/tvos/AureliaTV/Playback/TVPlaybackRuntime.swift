import Foundation
import UIKit

struct TVPlaybackTrack: Identifiable, Equatable {
  let id: Int32
  let title: String
}

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
  var audioTracks: [TVPlaybackTrack] { get }
  var subtitleTracks: [TVPlaybackTrack] { get }
  var audioTrackID: Int32 { get }
  var subtitleTrackID: Int32 { get }
  func attach(to view: UIView)
  func load(url: URL, resumeAt: Int64)
  func play()
  func pause()
  func stop()
  func seek(to milliseconds: Int64)
  func selectAudioTrack(_ id: Int32)
  func selectSubtitleTrack(_ id: Int32)
}

protocol TVPlaybackRelay: AnyObject, Sendable {
  func start() async throws -> URL
  func stop()
  func updateSourceURL(_ url: URL)
  func setFailureHandler(_ handler: @escaping @MainActor @Sendable (TVStreamFailure) -> Void)
}

extension TVStreamRelay: TVPlaybackRelay {}

@MainActor
struct TVPlaybackRuntime {
  let engine: any TVPlaybackEngine
  let makeRelay: (URL, String, String) throws -> any TVPlaybackRelay
  let managesAudioSession: Bool

  static func live() -> Self {
    Self(
      engine: TVVideoEngine(),
      makeRelay: { url, fingerprint, token in
        try TVStreamRelay(
          sourceURL: url, publicKeyFingerprint: fingerprint, authorizationToken: token)
      }, managesAudioSession: true)
  }
}
