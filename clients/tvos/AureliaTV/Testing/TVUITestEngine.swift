#if DEBUG
  import Foundation
  import UIKit

  @MainActor
  final class TVUITestEngine: TVPlaybackEngine {
    var onUpdate: (() -> Void)?
    var onTerminal: ((TVVideoTerminal) -> Void)?
    private(set) var isActive = false
    private(set) var isPlaying = false
    var isLoading: Bool { false }
    var isSeekable: Bool { true }
    private(set) var position: Int64 = 90_000
    let duration: Int64 = 5_400_000
    var hasObservedPlayback: Bool { isActive }
    let audioTracks: [TVPlaybackTrack]
    let subtitleTracks: [TVPlaybackTrack]
    private(set) var audioTrackID: Int32 = 1
    private(set) var subtitleTrackID: Int32 = -1
    private var clock: Task<Void, Never>?

    init(scenario: TVUITestScenario) {
      audioTracks =
        scenario == .limitedTracks
        ? []
        : (1...14).map {
          TVPlaybackTrack(
            id: Int32($0),
            title: String(format: "Audio Track %02d — Extended Synthetic Language Name", $0))
        }
      subtitleTracks =
        scenario == .limitedTracks
        ? []
        : (1...14).map {
          TVPlaybackTrack(
            id: Int32($0),
            title: String(format: "Subtitle Track %02d — Extended Synthetic Language Name", $0))
        }
    }
    static func runtime(scenario: TVUITestScenario) -> TVPlaybackRuntime {
      TVPlaybackRuntime(
        engine: TVUITestEngine(scenario: scenario), makeRelay: { _, _, _ in TVUITestRelay() },
        managesAudioSession: false)
    }
    func attach(to view: UIView) {
      view.backgroundColor = UIColor(red: 0.06, green: 0.10, blue: 0.17, alpha: 1)
    }
    func load(url: URL, resumeAt: Int64) {
      isActive = true
      isPlaying = true
      position = resumeAt
      onUpdate?()
      clock = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(1)) } catch { return }
          guard let self, self.isActive else { return }
          if self.isPlaying {
            self.position += 1_000
            self.onUpdate?()
          }
        }
      }
    }
    func play() {
      isPlaying = true
      onUpdate?()
    }
    func pause() {
      isPlaying = false
      onUpdate?()
    }
    func stop() {
      isPlaying = false
      isActive = false
      clock?.cancel()
    }
    func seek(to milliseconds: Int64) {
      position = milliseconds
      onUpdate?()
    }
    func selectAudioTrack(_ id: Int32) {
      audioTrackID = id
      onUpdate?()
    }
    func selectSubtitleTrack(_ id: Int32) {
      subtitleTrackID = id
      onUpdate?()
    }
  }

  private final class TVUITestRelay: TVPlaybackRelay, Sendable {
    func start() async throws -> URL { URL(string: "https://fixture.invalid/simulated-frame")! }
    func stop() {}
    func updateSourceURL(_ url: URL) {}
    func setFailureHandler(_ handler: @escaping @MainActor @Sendable (TVStreamFailure) -> Void) {}
  }
#endif
