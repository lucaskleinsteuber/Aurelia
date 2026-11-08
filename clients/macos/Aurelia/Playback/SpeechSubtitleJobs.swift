import Foundation

/// Subtitles being written from speech on this Mac, one job per title. A job goes on when its
/// editor closes; the finished subtitles are kept on the server for every device.
@MainActor
final class SpeechSubtitleJobs: ObservableObject {
  static let shared = SpeechSubtitleJobs()

  enum Phase: Equatable {
    case preparing
    /// The speech model for the language loads once.
    case loadingModel
    /// Share of the title listened to (0…1).
    case listening(Double)
    case saving
    case saved(DownloadedSubtitle)
    /// Written, but the server didn't take it yet (for example locked management); Save tries again.
    case unsaved(String)
    case failed(String)

    var isRunning: Bool {
      switch self {
      case .preparing, .loadingModel, .listening, .saving: true
      default: false
      }
    }
  }

  struct Job: Equatable {
    let mediaId: UUID
    let language: String
    var phase: Phase
    var subRip: String?
  }

  @Published private(set) var jobs: [UUID: Job] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]

  func job(_ mediaId: UUID) -> Job? { jobs[mediaId] }

  /// Writes subtitles for `mediaId` from sound track `track`, spoken in `language`.
  func start(
    mediaId: UUID, track: Int, language: String, profile: StoredServerProfile,
    save: @escaping @MainActor (String) async throws -> DownloadedSubtitle
  ) {
    guard jobs[mediaId]?.phase.isRunning != true else { return }
    jobs[mediaId] = Job(mediaId: mediaId, language: language, phase: .preparing)
    tasks[mediaId] = Task { [weak self] in
      guard let self else { return }
      do {
        let subRip = try await self.write(
          mediaId: mediaId, track: track, language: language, profile: profile)
        self.jobs[mediaId]?.subRip = subRip
        await self.store(mediaId, save: save)
      } catch is CancellationError {
        self.jobs[mediaId] = nil
      } catch {
        self.jobs[mediaId]?.phase = .failed(error.localizedDescription)
      }
      self.tasks[mediaId] = nil
    }
  }

  /// Hands finished subtitles to the server again, after it refused them.
  func saveAgain(_ mediaId: UUID, save: @escaping @MainActor (String) async throws -> DownloadedSubtitle) {
    guard case .unsaved = jobs[mediaId]?.phase else { return }
    Task { await store(mediaId, save: save) }
  }

  func cancel(_ mediaId: UUID) {
    tasks[mediaId]?.cancel()
    tasks[mediaId] = nil
    jobs[mediaId] = nil
  }

  func dismiss(_ mediaId: UUID) {
    guard jobs[mediaId]?.phase.isRunning != true else { return }
    jobs[mediaId] = nil
  }

  private func store(_ mediaId: UUID, save: @MainActor (String) async throws -> DownloadedSubtitle) async {
    guard let subRip = jobs[mediaId]?.subRip else { return }
    jobs[mediaId]?.phase = .saving
    do {
      jobs[mediaId]?.phase = .saved(try await save(subRip))
    } catch {
      jobs[mediaId]?.phase = .unsaved(error.localizedDescription)
    }
  }

  /// Shown in whole percents, not for every chunk of sound.
  private func listened(_ mediaId: UUID, share: Double) {
    guard let phase = jobs[mediaId]?.phase else { return }
    switch phase {
    case .listening(let shown) where Int(shown * 100) == Int(share * 100): return
    case .listening, .preparing, .loadingModel: jobs[mediaId]?.phase = .listening(share)
    default: return
    }
  }

  private func write(
    mediaId: UUID, track: Int, language: String, profile: StoredServerProfile
  ) async throws -> String {
    guard SpeechRecognizer.isAvailable else { throw SpeechSubtitleError.unavailable }
    guard
      let locale = SpeechLanguages.locale(
        for: language, among: await SpeechRecognizer.supportedLocales())
    else { throw SpeechSubtitleError.languageUnavailable(language) }
    let api = APIClient(profile: profile)
    let ticket = try await api.createPlayback(mediaId: mediaId)
    defer { Task { try? await api.revokePlayback(id: ticket.id) } }
    let duration = try await api.speechAudioTracks(streamPath: ticket.streamPath).durationSeconds
    let reader = try api.speechAudio(streamPath: ticket.streamPath, track: track)
    defer { reader.stop() }
    let words = try await SpeechRecognizer.words(
      locale: locale, audio: reader.chunks(),
      listened: { [weak self] seconds in
        // Without a known length the share stays at zero and the bar just runs.
        let share = duration.map { $0 > 0 ? min(0.99, seconds / $0) : 0 } ?? 0
        Task { @MainActor in self?.listened(mediaId, share: share) }
      },
      consumed: { count in reader.consumed(count) },
      preparing: { [weak self] in
        Task { @MainActor in self?.jobs[mediaId]?.phase = .loadingModel }
      })
    try Task.checkCancellation()
    let cues = SubtitleCueBuilder.cues(from: words)
    guard !cues.isEmpty else { throw SpeechSubtitleError.nothingHeard }
    return SubtitleCueBuilder.subRip(cues)
  }
}
