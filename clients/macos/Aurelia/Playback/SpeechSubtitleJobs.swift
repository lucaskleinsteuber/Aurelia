import Foundation

/// Subtitles being written from speech, or synced to it, on this Mac: one job per title. A job
/// goes on when its editor closes; the finished subtitles are kept on the server for every device.
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
    /// Syncing found the subtitles already fit; nothing was saved.
    case alreadyInSync
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

  enum Kind: Equatable {
    case create
    /// Syncing one of the title's subtitle tracks, by its name.
    case sync(String)
  }

  struct Job: Equatable {
    let mediaId: UUID
    let kind: Kind
    /// The language of the subtitles that are saved.
    let language: String
    var phase: Phase
    var subRip: String?
    /// What syncing changed, for example "Moved 2.4 s later. Fits 88 % of the speech (was 31 %)."
    var summary: String?
  }

  typealias Saver = @MainActor (String) async throws -> DownloadedSubtitle

  @Published private(set) var jobs: [UUID: Job] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]
  /// What was heard in a sound track, so syncing a second track or creating subtitles after
  /// syncing doesn't listen again. Kept in memory for a few titles only.
  private var heard: [String: [SpeechWord]] = [:]
  private var heardOrder: [String] = []

  func job(_ mediaId: UUID) -> Job? { jobs[mediaId] }

  /// Writes subtitles for `mediaId` from sound track `track`, spoken in `language`.
  func start(
    mediaId: UUID, track: Int, language: String, profile: StoredServerProfile, save: @escaping Saver
  ) {
    run(
      Job(mediaId: mediaId, kind: .create, language: language, phase: .preparing),
      profile: profile, save: save
    ) {
      api, ticket in
      let words = try await self.listen(
        mediaId: mediaId, track: track, language: language, api: api, ticket: ticket)
      let cues = SubtitleCueBuilder.cues(from: words)
      guard !cues.isEmpty else { throw SpeechSubtitleError.nothingHeard }
      return SubtitleCueBuilder.subRip(cues)
    }
  }

  /// Moves subtitle track `subtitles` (saved in `language`) to fit the speech of sound track
  /// `track`, spoken in `spoken`. The result is saved as a synced copy; the original stays.
  func sync(
    mediaId: UUID, subtitles: LiveSubtitleTrack, language: String, track: Int, spoken: String,
    profile: StoredServerProfile, save: @escaping Saver
  ) {
    let job = Job(
      mediaId: mediaId, kind: .sync(subtitles.title.isEmpty ? "Subtitles" : subtitles.title),
      language: language, phase: .preparing)
    run(job, profile: profile, save: save) { api, ticket in
      let text = try await api.streamSubtitleText(
        streamPath: ticket.streamPath, index: subtitles.index)
      let cues = SubtitleText.cues(webVTT: text)
      guard cues.count >= 10 else { throw SpeechSubtitleError.tooFewSubtitles }
      let words = try await self.listen(
        mediaId: mediaId, track: track, language: spoken, api: api, ticket: ticket)
      let speech = SubtitleSync.speech(from: words)
      guard speech.count >= 10 else { throw SpeechSubtitleError.nothingHeard }
      let result = SubtitleSync.find(
        speech: speech, cues: cues.map { TimeSpan(start: $0.start, end: $0.end) })
      switch result.verdict {
      case .noMatch: throw SpeechSubtitleError.noMatch
      case .alreadyInSync: return nil
      case .shifted:
        self.jobs[mediaId]?.summary = Self.summary(result)
        return SubtitleCueBuilder.subRip(result.timing.apply(cues))
      }
    }
  }

  /// Hands finished subtitles to the server again, after it refused them.
  func saveAgain(_ mediaId: UUID, save: @escaping Saver) {
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

  /// "Moved 2.4 s later, adjusted for another frame rate. Fits 88 % of the speech (was 31 %)."
  nonisolated static func summary(_ result: SubtitleSyncResult) -> String {
    var parts: [String] = []
    let segments = result.timing.segments
    if segments.count > 1 {
      parts.append("Moved in \(segments.count) parts, as for another cut of the film")
    } else {
      let offset = segments[0].offset
      let amount = String(format: "%.1f", abs(offset))
      if abs(offset) >= 0.1 { parts.append("Moved \(amount) s \(offset > 0 ? "later" : "earlier")") }
    }
    if result.timing.scale != 1 {
      parts.append(parts.isEmpty ? "Adjusted for another frame rate" : "adjusted for another frame rate")
    }
    let fit = "Fits \(Int(result.fitAfter * 100)) % of the speech (was \(Int(result.fitBefore * 100)) %)."
    return parts.joined(separator: ", ") + ". " + fit
  }

  // MARK: Running

  /// Runs one job: a playback ticket for its reads, the work, and saving the result. Work that
  /// returns nil saved nothing because nothing had to change.
  private func run(
    _ job: Job, profile: StoredServerProfile, save: @escaping Saver,
    work: @escaping @MainActor (APIClient, PlaybackSourceResponse) async throws -> String?
  ) {
    let mediaId = job.mediaId
    guard jobs[mediaId]?.phase.isRunning != true else { return }
    jobs[mediaId] = job
    tasks[mediaId] = Task { [weak self] in
      guard let self else { return }
      do {
        let api = APIClient(profile: profile)
        let ticket = try await api.createPlayback(mediaId: mediaId)
        defer { Task { try? await api.revokePlayback(id: ticket.id) } }
        if let subRip = try await work(api, ticket) {
          try Task.checkCancellation()
          self.jobs[mediaId]?.subRip = subRip
          await self.store(mediaId, save: save)
        } else {
          self.jobs[mediaId]?.phase = .alreadyInSync
        }
      } catch is CancellationError {
        self.jobs[mediaId] = nil
      } catch {
        self.jobs[mediaId]?.phase = .failed(error.localizedDescription)
      }
      self.tasks[mediaId] = nil
    }
  }

  private func store(_ mediaId: UUID, save: Saver) async {
    guard let subRip = jobs[mediaId]?.subRip else { return }
    jobs[mediaId]?.phase = .saving
    do {
      jobs[mediaId]?.phase = .saved(try await save(subRip))
    } catch {
      jobs[mediaId]?.phase = .unsaved(error.localizedDescription)
    }
  }

  /// The words spoken in a sound track; from memory when this track was heard before.
  private func listen(
    mediaId: UUID, track: Int, language: String, api: APIClient, ticket: PlaybackSourceResponse
  ) async throws -> [SpeechWord] {
    let key = "\(mediaId.uuidString)/\(track)/\(language)"
    if let known = heard[key] { return known }
    guard SpeechRecognizer.isAvailable else { throw SpeechSubtitleError.unavailable }
    guard
      let locale = SpeechLanguages.locale(
        for: language, among: await SpeechRecognizer.supportedLocales())
    else { throw SpeechSubtitleError.languageUnavailable(language) }
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
    heard[key] = words
    heardOrder.append(key)
    while heardOrder.count > 3 { heard[heardOrder.removeFirst()] = nil }
    return words
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
}
