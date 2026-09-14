import AppKit
import Foundation

@MainActor
protocol PlaybackClientProtocol: AnyObject {
  var profile: StoredServerProfile { get }
  func createPlayback(mediaId: UUID) async throws -> PlaybackSourceResponse
  func updatePlaybackProgress(
    mediaId: UUID,
    positionMilliseconds: Int64,
    durationMilliseconds: Int64,
    isFinished: Bool
  ) async throws -> PlaybackProgressResponse
  func revokePlayback(id: UUID) async throws
  func streamURL(path: String) throws -> URL
}

@MainActor
final class APIPlaybackClient: PlaybackClientProtocol {
  let api: APIClient
  var profile: StoredServerProfile { api.profile }

  init(profile: StoredServerProfile) {
    api = APIClient(profile: profile)
  }

  func createPlayback(mediaId: UUID) async throws -> PlaybackSourceResponse {
    try await api.createPlayback(mediaId: mediaId)
  }

  func updatePlaybackProgress(
    mediaId: UUID,
    positionMilliseconds: Int64,
    durationMilliseconds: Int64,
    isFinished: Bool
  ) async throws -> PlaybackProgressResponse {
    try await api.updatePlaybackProgress(
      mediaId: mediaId,
      positionMilliseconds: positionMilliseconds,
      durationMilliseconds: durationMilliseconds,
      isFinished: isFinished)
  }

  func revokePlayback(id: UUID) async throws {
    try await api.revokePlayback(id: id)
  }

  func streamURL(path: String) throws -> URL {
    try api.streamURL(path: path)
  }
}

@MainActor
protocol PlaybackRelayProtocol: AnyObject {
  func start() async throws -> URL
  func updateSourceURL(_ url: URL)
  func stop()
}

extension LoopbackStreamRelay: PlaybackRelayProtocol {}

@MainActor
final class PlaybackController: ObservableObject {
  @Published private(set) var isPreparing = true
  @Published private(set) var isPlaying = false
  @Published private(set) var currentTimeMilliseconds: Int64 = 0
  @Published private(set) var durationMilliseconds: Int64 = 0
  @Published private(set) var audioTracks: [PlaybackTrack] = []
  @Published private(set) var subtitleTracks: [PlaybackTrack] = []
  @Published private(set) var selectedAudioTrackID: Int32?
  @Published private(set) var selectedSubtitleTrackID: Int32?
  @Published var volume: Double = 1
  @Published var isMuted = false
  @Published var errorMessage: String?

  let presentation: PlaybackPresentation

  private let client: any PlaybackClientProtocol
  private let engine: PlaybackEngine
  private let relayFactory: (URL, String) throws -> any PlaybackRelayProtocol
  private var relay: (any PlaybackRelayProtocol)?
  private var activePlayback: PlaybackSourceResponse?
  private var playbackIDs: Set<UUID> = []
  private var renewalTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?
  private var started = false
  private var stopped = false
  private var appliedResumePosition = false
  private var resumePositionMilliseconds: Int64 = 0
  private var lastPeriodicSave = Date.distantPast

  init(
    profile: StoredServerProfile,
    presentation: PlaybackPresentation,
    engine: PlaybackEngine = VLCPlaybackEngine()
  ) {
    self.client = APIPlaybackClient(profile: profile)
    self.presentation = presentation
    self.engine = engine
    self.relayFactory = { url, fingerprint in
      try LoopbackStreamRelay(sourceURL: url, publicKeyFingerprint: fingerprint)
    }
    connectEngineCallbacks()
  }

  init(
    client: any PlaybackClientProtocol,
    presentation: PlaybackPresentation,
    engine: PlaybackEngine,
    relayFactory: @escaping (URL, String) throws -> any PlaybackRelayProtocol
  ) {
    self.client = client
    self.presentation = presentation
    self.engine = engine
    self.relayFactory = relayFactory
    connectEngineCallbacks()
  }

  private func connectEngineCallbacks() {
    engine.onUpdate = { [weak self] in self?.engineUpdated() }
    engine.onEnded = { [weak self] in self?.engineEnded() }
    engine.onError = { [weak self] message in self?.engineFailed(message) }
  }

  func attachVideoView(_ view: NSView) {
    engine.attach(to: view)
  }

  func start() async {
    guard !started else { return }
    started = true
    stopped = false
    isPreparing = true
    errorMessage = nil

    do {
      let source = try await client.createPlayback(mediaId: presentation.mediaId)
      try await begin(source)
    } catch {
      isPreparing = false
      errorMessage = error.localizedDescription
    }
  }

  func retry() async {
    await shutdown(saveProgress: false)
    started = false
    stopped = false
    await start()
  }

  func togglePlayback() {
    if engine.isPlaying {
      engine.pause()
      enqueueProgressSave(isFinished: false)
    } else {
      engine.play()
    }
    engineUpdated()
  }

  func skip(seconds: Int64) {
    seek(to: currentTimeMilliseconds + seconds * 1_000)
  }

  func seek(to milliseconds: Int64) {
    let upper = durationMilliseconds > 0 ? durationMilliseconds : Int64.max
    let target = min(max(milliseconds, 0), upper)
    engine.seek(to: target)
    currentTimeMilliseconds = target
    enqueueProgressSave(isFinished: false)
  }

  func setVolume(_ value: Double) {
    volume = min(max(value, 0), 1)
    engine.volume = volume
    if volume > 0 { isMuted = false }
  }

  func toggleMute() {
    isMuted.toggle()
    engine.isMuted = isMuted
  }

  func selectAudioTrack(_ id: Int32) {
    engine.selectAudioTrack(id: id)
    engineUpdated()
  }

  func selectSubtitleTrack(_ id: Int32?) {
    engine.selectSubtitleTrack(id: id)
    engineUpdated()
  }

  func shutdown(saveProgress: Bool = true) async {
    guard !stopped else { return }
    stopped = true
    renewalTask?.cancel()
    renewalTask = nil

    if saveProgress {
      enqueueProgressSave(isFinished: false)
      await saveTask?.value
    }

    engine.stop()
    relay?.stop()
    relay = nil
    for id in playbackIDs {
      try? await client.revokePlayback(id: id)
    }
    playbackIDs.removeAll()
    activePlayback = nil
  }

  private func begin(_ source: PlaybackSourceResponse) async throws {
    let sourceURL = try client.streamURL(path: source.streamPath)
    let relay = try relayFactory(sourceURL, client.profile.publicKeyFingerprint)
    let localURL = try await relay.start()
    self.relay = relay
    activePlayback = source
    playbackIDs.insert(source.id)
    resumePositionMilliseconds = source.progress.isCompleted
      ? 0
      : source.progress.positionMilliseconds
    appliedResumePosition = resumePositionMilliseconds == 0
    engine.load(url: localURL)
    engine.volume = volume
    engine.isMuted = isMuted
    scheduleRenewal(for: source)
    engine.play()
  }

  private func engineUpdated() {
    isPlaying = engine.isPlaying
    currentTimeMilliseconds = engine.currentTimeMilliseconds
    durationMilliseconds = engine.durationMilliseconds
    volume = engine.volume
    isMuted = engine.isMuted
    audioTracks = engine.audioTracks
    subtitleTracks = engine.subtitleTracks
    selectedAudioTrackID = engine.selectedAudioTrackID
    selectedSubtitleTrackID = engine.selectedSubtitleTrackID
    isPreparing = durationMilliseconds <= 0 && !isPlaying

    if !appliedResumePosition, durationMilliseconds > 0 {
      appliedResumePosition = true
      engine.seek(to: min(resumePositionMilliseconds, durationMilliseconds))
      currentTimeMilliseconds = min(resumePositionMilliseconds, durationMilliseconds)
    }

    if isPlaying, Date().timeIntervalSince(lastPeriodicSave) >= 15 {
      lastPeriodicSave = Date()
      enqueueProgressSave(isFinished: false)
    }
  }

  private func engineEnded() {
    isPlaying = false
    currentTimeMilliseconds = durationMilliseconds
    enqueueProgressSave(isFinished: true)
  }

  private func engineFailed(_ message: String) {
    isPreparing = false
    isPlaying = false
    errorMessage = message
  }

  private func enqueueProgressSave(isFinished: Bool) {
    let position = currentTimeMilliseconds
    let duration = durationMilliseconds
    guard duration > 0, position >= 0, position <= duration else { return }
    let previous = saveTask
    let client = client
    let mediaID = presentation.mediaId
    saveTask = Task {
      await previous?.value
      _ = try? await client.updatePlaybackProgress(
        mediaId: mediaID,
        positionMilliseconds: position,
        durationMilliseconds: duration,
        isFinished: isFinished)
    }
  }

  private func scheduleRenewal(for source: PlaybackSourceResponse) {
    renewalTask?.cancel()
    let delay = TicketRenewalPolicy.delayUntilRenewal(expiresAt: source.expiresAt)
    renewalTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      await self?.renewTicket()
    }
  }

  private func renewTicket() async {
    guard !stopped, let old = activePlayback else { return }
    do {
      let renewed = try await client.createPlayback(mediaId: presentation.mediaId)
      let renewedURL = try client.streamURL(path: renewed.streamPath)
      relay?.updateSourceURL(renewedURL)
      activePlayback = renewed
      playbackIDs.insert(renewed.id)
      try? await client.revokePlayback(id: old.id)
      playbackIDs.remove(old.id)
      scheduleRenewal(for: renewed)
    } catch {
      errorMessage = "The playback authorization could not be renewed. \(error.localizedDescription)"
    }
  }
}

enum TicketRenewalPolicy {
  static func delayUntilRenewal(
    expiresAt: String,
    now: Date = Date()
  ) -> TimeInterval {
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let expiration = fractionalFormatter.date(from: expiresAt)
      ?? ISO8601DateFormatter().date(from: expiresAt)
      ?? now.addingTimeInterval(60)
    return max(1, expiration.timeIntervalSince(now) - 5 * 60)
  }
}

@MainActor
final class PlaybackShutdownCoordinator {
  static let shared = PlaybackShutdownCoordinator()

  private weak var controller: PlaybackController?
  var hasActivePlayback: Bool { controller != nil }

  func register(_ controller: PlaybackController) {
    self.controller = controller
  }

  func unregister(_ controller: PlaybackController) {
    if self.controller === controller { self.controller = nil }
  }

  func shutdown() async {
    await controller?.shutdown()
    controller = nil
  }
}
