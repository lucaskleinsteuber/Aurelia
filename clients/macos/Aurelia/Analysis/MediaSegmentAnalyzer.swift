import Combine
import Foundation
import os

/// Finds intros and credits in the background on an administrator's Mac and stores only the
/// resulting times on the server. Files are read through the normal authorized stream; no audio,
/// fingerprint or image is ever written. Work pauses while something plays.
@MainActor
final class MediaSegmentAnalyzer: ObservableObject {
  /// 2: streams are converted to mono 11 kHz from their real layout (1.7.3).
  static let analysisVersion = 2
  static let introWindow: Double = 420
  static let creditsWindow: Double = 240

  /// How far detection is, for the settings view.
  struct Progress: Equatable {
    /// Titles finished on the server, out of all titles that can be analyzed.
    var done: Int
    var total: Int
    /// The season or movie being read, for example "Breaking Bad · Season 2".
    var title: String?
    /// The title being read within that season, counting from 1.
    var step: Int
    var steps: Int
  }

  enum Status: Equatable {
    case idle
    case analyzing(Progress)
    case waiting
    case upToDate
    case failed(String)
  }

  @Published private(set) var status: Status = .idle
  private static let logger = Logger(subsystem: "com.lucas.aurelia.media", category: "Segments")
  private var task: Task<Void, Never>?
  private var profileKey: String?
  /// Names a season or movie for the progress line; set by the app model.
  var titleResolver: (@MainActor (MediaSegmentAnalysisGroup) -> String?)?
  private var done = 0
  private var total = 0
  /// Titles that could not be read in this session; they are retried in a later pass.
  private var failed: Set<UUID> = []

  /// Starts or keeps working for this profile; `canRun` is checked between titles.
  func start(profile: StoredServerProfile, canRun: @escaping @MainActor () -> Bool) {
    let key = "\(profile.serverId):\(profile.sessionId)"
    guard key != profileKey || task == nil else { return }
    stop()
    profileKey = key
    task = Task { [weak self] in await self?.run(profile: profile, canRun: canRun) }
  }

  func stop() {
    task?.cancel()
    task = nil
    profileKey = nil
    status = .idle
  }

  /// Looks for new work at once, for example after a library scan.
  func refresh(profile: StoredServerProfile, canRun: @escaping @MainActor () -> Bool) {
    stop()
    start(profile: profile, canRun: canRun)
  }

  private func run(profile: StoredServerProfile, canRun: @escaping @MainActor () -> Bool) async {
    let client = APIClient(profile: profile)
    while !Task.isCancelled {
      guard canRun() else {
        status = .waiting
        try? await Task.sleep(for: .seconds(20))
        continue
      }
      do {
        let queue = try await client.mediaSegmentAnalysisQueue(
          analysisVersion: Self.analysisVersion, limit: 50)
        done = queue.analyzedTitles ?? 0
        total = queue.totalTitles ?? 0
        let groups = queue.groups.filter { group in
          group.items.contains { $0.needsAnalysis && !failed.contains($0.mediaId) }
        }
        guard !groups.isEmpty else {
          status = .upToDate
          try? await Task.sleep(for: .seconds(30 * 60))
          failed = []
          continue
        }
        for group in groups {
          guard !Task.isCancelled else { return }
          try await analyze(group, client: client, profile: profile, canRun: canRun)
        }
      } catch is CancellationError {
        return
      } catch {
        status = .failed(error.localizedDescription)
        try? await Task.sleep(for: .seconds(5 * 60))
      }
    }
  }

  private struct Prints {
    let intro: [UInt32]
    let introLimit: Double
    let credits: [UInt32]
    let creditsOffset: Double
    let duration: Int64
    let chapters: [PlaybackChapter]
  }

  private func analyze(
    _ group: MediaSegmentAnalysisGroup, client: APIClient, profile: StoredServerProfile,
    canRun: @MainActor () -> Bool
  ) async throws {
    var prints: [UUID: Prints] = [:]
    // Only titles needing analysis and their nearest neighbours are read.
    let needed = Set(
      group.items.indices.filter {
        group.items[$0].needsAnalysis && !failed.contains(group.items[$0].mediaId)
      }
      .flatMap { ($0 - 2)...($0 + 2) })
    let title = titleResolver?(group)
    let reading = group.items.indices.filter { needed.contains($0) }
    for (index, item) in group.items.enumerated() where needed.contains(index) {
      while !canRun() {
        status = .waiting
        try await Task.sleep(for: .seconds(20))
      }
      status = .analyzing(
        Progress(
          done: done, total: total, title: title,
          step: (reading.firstIndex(of: index) ?? 0) + 1, steps: reading.count))
      do {
        prints[item.mediaId] = try await read(item.mediaId, client: client, profile: profile)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // An unreadable title is left out; its neighbours are still compared.
        failed.insert(item.mediaId)
        continue
      }
    }
    let ordered = group.items.map(\.mediaId).filter { prints[$0] != nil }
    for (index, id) in ordered.enumerated() {
      guard let item = group.items.first(where: { $0.mediaId == id }), item.needsAnalysis,
        let own = prints[id]
      else { continue }
      let neighbours = [index + 1, index - 1, index + 2, index - 2]
        .filter { ordered.indices.contains($0) }.compactMap { prints[ordered[$0]] }
      let result = Self.segments(for: own, neighbours: neighbours)
      _ = try await client.saveMediaSegments(
        mediaId: id, introStart: result.introStart, introEnd: result.introEnd,
        creditsStart: result.creditsStart, source: result.source,
        analysisVersion: Self.analysisVersion)
      done += 1
    }
  }

  private func read(_ mediaId: UUID, client: APIClient, profile: StoredServerProfile) async throws
    -> Prints
  {
    let source = try await client.createPlayback(mediaId: mediaId)
    let relay = try LoopbackStreamRelay(
      sourceURL: client.streamURL(path: source.streamPath),
      publicKeyFingerprint: profile.publicKeyFingerprint,
      authorizationToken: profile.token)
    defer {
      relay.stop()
      Task { try? await client.revokePlayback(id: source.id) }
    }
    let url = try await relay.start()
    let reader = VLCAudioSampleReader()
    let started = Date()
    let opening = try await reader.read(url: url, start: 0, length: Self.introWindow)
    Self.logger.info(
      "Read \(Double(opening.samples.count) / AudioFingerprint.sampleRate, format: .fixed(precision: 0)) s of audio in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s (\(opening.sourceLayout, privacy: .public))"
    )
    let duration = opening.durationMilliseconds
    let seconds = Double(duration) / 1_000
    // An intro sits in the first third; credits in the last part of the title.
    let introLimit = min(Self.introWindow, seconds > 0 ? seconds * 0.35 : Self.introWindow)
    let introSamples = Array(
      opening.samples.prefix(Int(introLimit * AudioFingerprint.sampleRate)))
    let intro = AudioFingerprint.compute(introSamples)
    var credits: [UInt32] = []
    var creditsOffset: Double = 0
    if seconds > Self.creditsWindow * 2 {
      creditsOffset = max(seconds * 0.6, seconds - Self.creditsWindow)
      let ending = try await reader.read(
        url: url, start: creditsOffset, length: seconds - creditsOffset)
      credits = AudioFingerprint.compute(ending.samples)
    }
    return Prints(
      intro: intro, introLimit: introLimit, credits: credits, creditsOffset: creditsOffset,
      duration: duration, chapters: opening.chapters)
  }

  struct Result: Equatable {
    var introStart: Int64?
    var introEnd: Int64?
    var creditsStart: Int64?
    var source: MediaSegmentSource
  }

  /// Chapters win where a file names its intro or credits; otherwise the passage shared with
  /// neighbouring episodes is used.
  private static func segments(for own: Prints, neighbours: [Prints]) -> Result {
    let chapters = SkipSegmentLogic.fromChapters(own.chapters, duration: own.duration)
    var result = Result(
      introStart: chapters.introStart, introEnd: chapters.introEnd,
      creditsStart: chapters.creditsStart, source: chapters.isEmpty ? .none : .chapters)
    if result.introEnd == nil {
      let candidates = neighbours.compactMap { neighbour in
        SegmentMatcher.longestCommon(own.intro, neighbour.intro, minimum: 10, maximum: 150)
          .map { (start: $0.firstStart, end: $0.firstEnd) }
      }
      if let intro = SegmentConsensus.choose(candidates) {
        result.introStart = Int64(intro.start * 1_000)
        result.introEnd = Int64(intro.end * 1_000)
        result.source = .detected
      }
    }
    if result.creditsStart == nil, !own.credits.isEmpty {
      let candidates = neighbours.compactMap { neighbour -> (start: Double, end: Double)? in
        guard !neighbour.credits.isEmpty else { return nil }
        return SegmentMatcher.longestCommon(
          own.credits, neighbour.credits, minimum: 12, maximum: creditsWindow
        ).map { (start: $0.firstStart, end: $0.firstEnd) }
      }
      if let credits = SegmentConsensus.choose(candidates) {
        result.creditsStart = Int64((own.creditsOffset + credits.start) * 1_000)
        result.source = .detected
      }
    }
    return result
  }
}
