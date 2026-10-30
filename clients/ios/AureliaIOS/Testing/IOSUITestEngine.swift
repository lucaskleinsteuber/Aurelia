#if DEBUG
  import Foundation
  import UIKit

  @MainActor
  final class IOSUITestEngine: IOSPlaybackEngine {
    var onUpdate: (() -> Void)?
    var onTerminal: ((IOSVideoTerminal) -> Void)?
    private(set) var isActive = false
    var isPlaying: Bool { machine.state.isPlaying }
    var isLoading: Bool { machine.state.isLoading }
    var isSeekable: Bool { machine.state.isSeekable }
    var position: Int64 { machine.state.position }
    var duration: Int64 { machine.state.duration }
    var hasObservedPlayback: Bool { machine.state.hasObservedPlayback }
    var progressPosition: Int64? { machine.state.progressPosition }
    private(set) var audioTracks: [IOSPlaybackTrack] = []
    private(set) var subtitleTracks: [IOSPlaybackTrack] = []
    private(set) var audioTrackID: Int32 = 1
    private(set) var subtitleTrackID: Int32 = -1
    var audioSelectionPending: Bool { pendingAudio != nil }
    var subtitleSelectionPending: Bool { pendingSubtitle != nil }
    var playbackRate: Double = 1
    private var preferences = IOSPlaybackPreferences.defaultValue
    private let availableAudio: [IOSPlaybackTrack]
    private let availableSubtitles: [IOSPlaybackTrack]
    private let scenario: IOSUITestScenario
    private var machine = IOSPlaybackStateMachine()
    private var clock: Task<Void, Never>?
    private var generation = UUID()
    private var deliveredTerminal = false
    private var isSampling = false
    private var rawPosition: Double = 0
    private var rawDuration: Int64 = 5_400_000
    private var wantsPlayback = true
    private var startedAt: TimeInterval = 0
    private var sampledAt: TimeInterval = 0
    private var pendingAudio: (id: Int32, readyAt: TimeInterval)?
    private var pendingSubtitle: (id: Int32, readyAt: TimeInterval)?
    private var audioPreferenceApplied = false
    private var subtitlePreferenceApplied = false

    init(scenario: IOSUITestScenario) {
      self.scenario = scenario
      rawDuration = scenario.rawValue == "nextEpisode" ? 8_000 : 5_400_000
      availableAudio =
        scenario == .limitedTracks
        ? []
        : (1...14).map {
          IOSPlaybackTrack(
            id: Int32($0),
            title: String(format: "Audio Track %02d — Extended Synthetic Language Name", $0))
        }
      availableSubtitles =
        scenario == .limitedTracks
        ? []
        : (1...14).map {
          IOSPlaybackTrack(
            id: Int32($0),
            title: String(format: "Subtitle Track %02d — Extended Synthetic Language Name", $0))
        }
    }

    static func runtime(scenario: IOSUITestScenario) -> IOSPlaybackRuntime {
      IOSPlaybackRuntime(
        engine: IOSUITestEngine(scenario: scenario), makeRelay: { _, _, _ in IOSUITestRelay() },
        managesAudioSession: false)
    }

    func applyPreferences(_ preferences: IOSPlaybackPreferences) {
      self.preferences = preferences.normalized
      playbackRate = self.preferences.defaultPlaybackRate
      audioPreferenceApplied = false
      subtitlePreferenceApplied = false
      if isActive { sample() }
    }

    func attach(to view: UIView) {
      view.backgroundColor = UIColor(red: 0.06, green: 0.10, blue: 0.17, alpha: 1)
    }

    func load(url: URL, resumeAt: Int64) {
      stop()
      generation = UUID()
      let operation = generation
      isActive = true
      deliveredTerminal = false
      wantsPlayback = true
      let resume = min(max(0, resumeAt), max(0, rawDuration - 500))
      rawPosition = Double(resume)
      startedAt = now
      sampledAt = startedAt
      audioPreferenceApplied = false
      subtitlePreferenceApplied = false
      machine.reset(at: startedAt)
      if resume > 0 { machine.seek(to: resume, at: startedAt) }
      sample()
      clock = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
          guard let self, self.isActive, self.generation == operation else { return }
          self.sample()
        }
      }
    }

    func play() {
      guard isActive else { return }
      wantsPlayback = true
      machine.setWantsPlayback(true)
      sampledAt = now
      sample()
    }

    func pause() {
      guard isActive else { return }
      sample(notify: false)
      wantsPlayback = false
      machine.setWantsPlayback(false)
      sample()
    }

    func stop() {
      isActive = false
      generation = UUID()
      clock?.cancel()
      clock = nil
      pendingAudio = nil
      pendingSubtitle = nil
      machine.stop()
    }

    func seek(to milliseconds: Int64) {
      guard isActive else { return }
      let target = IOSPlayerPolicy.seekPosition(
        current: 0, offset: milliseconds, duration: duration)
      machine.seek(to: target, at: now)
      rawPosition = Double(target)
      sampledAt = now
      sample()
    }

    func selectAudioTrack(_ id: Int32) {
      guard availableAudio.contains(where: { $0.id == id }) else { return }
      audioPreferenceApplied = true
      pendingAudio = (id, now + 0.25)
      sample()
    }

    func selectSubtitleTrack(_ id: Int32) {
      guard id == -1 || availableSubtitles.contains(where: { $0.id == id }) else { return }
      subtitlePreferenceApplied = true
      pendingSubtitle = (id, now + 0.25)
      sample()
    }

    func sample() { sample(notify: true) }

    private func sample(notify: Bool) {
      guard isActive, !isSampling else { return }
      isSampling = true
      defer { isSampling = false }
      let time = now
      let elapsed = max(0, time - sampledAt)
      sampledAt = time
      if wantsPlayback { rawPosition += elapsed * 1_000 * playbackRate }
      let delayed = scenario == .delayed && time - startedAt < 1.25
      audioTracks = delayed ? [] : availableAudio
      subtitleTracks = delayed ? [] : availableSubtitles
      if !audioPreferenceApplied, !audioTracks.isEmpty {
        audioPreferenceApplied = true
        if let track = IOSPlaybackTrack.matching(preferences.preferredAudioTrack, in: audioTracks) {
          audioTrackID = track.id
        }
      }
      if !subtitlePreferenceApplied, !subtitleTracks.isEmpty {
        subtitlePreferenceApplied = true
        subtitleTrackID =
          IOSPlaybackTrack.matching(preferences.preferredSubtitleTrack, in: subtitleTracks)?.id
          ?? -1
      }
      if let pendingAudio, time >= pendingAudio.readyAt {
        audioTrackID = pendingAudio.id
        self.pendingAudio = nil
      }
      if let pendingSubtitle, time >= pendingSubtitle.readyAt {
        subtitleTrackID = pendingSubtitle.id
        self.pendingSubtitle = nil
      }
      let ended = rawPosition >= Double(rawDuration)
      // Deliberately keep the raw driver in buffering while its clock moves.
      // This executes the same normalization path that handles VLC's sticky state.
      machine.update(
        IOSDecoderSnapshot(
          state: ended ? .ended : (wantsPlayback ? .buffering : .paused),
          position: Int64(min(rawPosition, Double(rawDuration))),
          duration: delayed ? nil : rawDuration, isPlaying: wantsPlayback, isSeekable: !delayed),
        at: time, playbackRate: playbackRate)
      if notify { onUpdate?() }
      if notify, ended, !deliveredTerminal {
        deliveredTerminal = true
        clock?.cancel()
        onTerminal?(.ended)
      }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
  }

  private final class IOSUITestRelay: IOSPlaybackRelay, Sendable {
    func start() async throws -> URL { URL(string: "https://fixture.invalid/simulated-frame")! }
    func stop() {}
    func updateSourceURL(_ url: URL) {}
    func setFailureHandler(_ handler: @escaping @MainActor @Sendable (IOSStreamFailure) -> Void) {}
  }
#endif
