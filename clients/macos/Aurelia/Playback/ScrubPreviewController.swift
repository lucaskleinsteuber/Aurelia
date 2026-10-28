import Combine
import CoreGraphics
@preconcurrency import Foundation
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import VLCKit

/// Debounced timeline stills from the playing source. A small coarse pass and
/// nearby frames prepare likely requests; displayed compressed frames stay in a
/// bounded memory LRU for this title. Nothing is written to disk or the server.
@MainActor
final class ScrubPreviewController: NSObject, ObservableObject {
  static let minimumInterval: Int64 = 10_000
  static let maximumFrames = 720
  static let memoryFrameLimit = 120
  static let maximumCachedBytes = 8 * 1024 * 1024
  static let backgroundPreparationLimit = 24
  /// While the exact frame is still on its way, a prepared frame up to this many steps away
  /// stands in for it.
  static let standInReach: Int64 = 4
  private static let timeout: Duration = .seconds(6)

  @Published private(set) var image: CGImage?
  /// The timeline step `image` is shown for; it may be a nearby stand-in frame.
  @Published private(set) var imageBucket: Int64?
  @Published private(set) var preparedCount = 0

  private(set) var interval = minimumInterval
  private let workerOverride: Int?
  /// Whether the server gives previews their own budget ("preview-streams-v1").
  private var parallel = false
  private var restingUntil: ContinuousClock.Instant?
  private let prefetchDelay: Duration
  private let prefetchPause: Duration
  private let prefetchBackoff: Duration
  private var prefetchFailures = 0
  static let failuresBeforeBackoff = 3
  private let prefetchAllowed: () -> Bool
  private let interactiveDelay: Duration
  private let decoderFactory: @MainActor () -> any ScrubPreviewDecoding
  private var interactiveStart: Task<Void, Never>?
  private var neighboringBuckets: [Int64] = []

  private var mediaID: UUID?
  private var source: URL?
  private var duration: Int64 = 0
  private var frames: ScrubPreviewMemoryCache
  private var failed: Set<Int64> = []
  private var requested: Int64?
  /// The step whose frame `image` actually shows.
  private var shownFrame: Int64?
  private var pendingInteractive: Int64?
  private var jobs: [UUID: Job] = [:]
  private var prefetchOrder: [Int64] = []
  private var prefetchIndex = 0
  private var prefetchBusy = 0
  private var slotEpoch = 0
  private var prefetchReady = false
  private var prefetchStart: Task<Void, Never>?
  private var generation = 0

  private struct Job {
    let decoder: any ScrubPreviewDecoding
    let bucket: Int64
    let interactive: Bool
    let timeout: Task<Void, Never>
  }

  /// Existing preview budgets cap simultaneous background decoders beside the
  /// pointer's own. The initial coarse pass itself has a separate work limit.
  static var parallelWorkers: Int {
    min(6, max(2, ProcessInfo.processInfo.activeProcessorCount - 4))
  }

  static let serverFeature = "preview-streams-v1"

  var backgroundWorkers: Int { workerOverride ?? (parallel ? Self.parallelWorkers : 1) }

  /// A long rest after repeated failures (a busy server) and the low-power check keep
  /// playback smooth.
  init(
    prefetchWorkers: Int? = nil, prefetchDelay: Duration = .seconds(4),
    prefetchPause: Duration = .zero, prefetchBackoff: Duration = .seconds(60),
    prefetchAllowed: @escaping () -> Bool = { !ProcessInfo.processInfo.isLowPowerModeEnabled },
    interactiveDelay: Duration = .milliseconds(90),
    cacheFrameLimit: Int = ScrubPreviewController.memoryFrameLimit,
    cacheByteLimit: Int = ScrubPreviewController.maximumCachedBytes,
    decoderFactory: @escaping @MainActor () -> any ScrubPreviewDecoding = {
      NativeScrubPreviewDecoder()
    }
  ) {
    self.workerOverride = prefetchWorkers
    self.prefetchDelay = prefetchDelay
    self.prefetchPause = prefetchPause
    self.prefetchBackoff = prefetchBackoff
    self.prefetchAllowed = prefetchAllowed
    self.interactiveDelay = interactiveDelay
    self.decoderFactory = decoderFactory
    self.frames = ScrubPreviewMemoryCache(frameLimit: cacheFrameLimit, byteLimit: cacheByteLimit)
  }

  /// Frames belong to `mediaID`. A new source for the same title, after a reconnect, keeps
  /// them; another title starts over.
  func configure(mediaID: UUID?, source: URL?, duration: Int64, parallel: Bool = false) {
    if mediaID != self.mediaID {
      reset()
      self.mediaID = mediaID
    }
    if parallel != self.parallel {
      self.parallel = parallel
      fillPrefetchSlots()
    }
    let duration = max(0, duration)
    if duration != self.duration {
      self.duration = duration
      let interval = Self.interval(for: duration)
      if interval != self.interval {
        discardFrames()
        self.interval = interval
      }
      prefetchOrder = Array(
        Self.prefetchOrder(duration: duration, interval: interval).prefix(
          Self.backgroundPreparationLimit))
      prefetchIndex = 0
      fillPrefetchSlots()
    }
    if source != self.source {
      self.source = source
      generation += 1
      interactiveStart?.cancel()
      interactiveStart = nil
      cancelJobs()
      pendingInteractive = requested.flatMap { frames.contains($0) ? nil : $0 }
      neighboringBuckets =
        requested.map {
          Self.neighbors(of: $0, interval: self.interval, duration: self.duration)
        } ?? []
      prefetchStart?.cancel()
      prefetchStart = nil
      prefetchReady = false
      guard source != nil else { return }
      let expected = generation
      prefetchStart = Task { [weak self, prefetchDelay] in
        try? await Task.sleep(for: prefetchDelay)
        guard let self, !Task.isCancelled, self.generation == expected else { return }
        self.prefetchReady = true
        self.fillPrefetchSlots()
      }
      startInteractiveIfIdle()
    }
  }

  static func interval(for duration: Int64) -> Int64 {
    let spread = (max(0, duration) + Int64(maximumFrames) - 1) / Int64(maximumFrames)
    return max(minimumInterval, (spread + 999) / 1_000 * 1_000)
  }

  /// Every step once: first every eighth, then the ones between, so the whole timeline is
  /// roughly covered early on.
  static func prefetchOrder(duration: Int64, interval: Int64) -> [Int64] {
    guard duration > 0, interval > 0 else { return [] }
    let count = Int((duration + interval - 1) / interval)
    var seen = [Bool](repeating: false, count: count)
    var order: [Int64] = []
    order.reserveCapacity(count)
    var step = 8
    while step >= 1 {
      for index in stride(from: 0, to: count, by: step) where !seen[index] {
        seen[index] = true
        order.append(Int64(index) * interval)
      }
      step /= 2
    }
    return order
  }

  func bucket(for milliseconds: Int64) -> Int64 {
    max(0, milliseconds) / interval * interval
  }

  /// Shows the frame for `milliseconds`, or a nearby prepared one until it is decoded. Only the
  /// latest request is fetched next, so fast pointer movement never queues up work.
  func request(at milliseconds: Int64) {
    guard source != nil, duration > 0 else { return }
    let bucket = bucket(for: min(milliseconds, duration - 1))
    let changed = requested != bucket
    requested = bucket
    showBest(for: bucket)
    guard changed else { return }
    interactiveStart?.cancel()
    pendingInteractive = nil
    let expected = generation
    interactiveStart = Task { [weak self, interactiveDelay] in
      try? await Task.sleep(for: interactiveDelay)
      guard let self, !Task.isCancelled, self.generation == expected, self.requested == bucket
      else { return }
      self.interactiveStart = nil
      self.neighboringBuckets = Self.neighbors(
        of: bucket, interval: self.interval, duration: self.duration)
      if !self.frames.contains(bucket), !self.jobs.values.contains(where: { $0.bucket == bucket }) {
        self.pendingInteractive = bucket
        self.startInteractiveIfIdle()
      }
      self.fillPrefetchSlots()
    }
  }

  func reset() {
    generation += 1
    prefetchStart?.cancel()
    prefetchStart = nil
    interactiveStart?.cancel()
    interactiveStart = nil
    prefetchReady = false
    cancelJobs()
    discardFrames()
    mediaID = nil
    source = nil
    duration = 0
    interval = Self.minimumInterval
    prefetchOrder = []
  }

  private func discardFrames() {
    frames.removeAll()
    neighboringBuckets = []
    failed = []
    requested = nil
    shownFrame = nil
    pendingInteractive = nil
    prefetchIndex = 0
    preparedCount = 0
    image = nil
    imageBucket = nil
  }

  private func cancelJobs() {
    for job in jobs.values {
      job.timeout.cancel()
      job.decoder.cancel()
    }
    jobs = [:]
    // Resting background slots belong to the cancelled work.
    prefetchBusy = 0
    restingUntil = nil
    slotEpoch += 1
  }

  /// The exact frame for `bucket`, else the closest prepared one within reach.
  func nearestFrame(to bucket: Int64) -> Int64? {
    if frames.contains(bucket) { return bucket }
    for steps in 1...Self.standInReach {
      for candidate in [bucket - steps * interval, bucket + steps * interval]
      where frames.contains(candidate) {
        return candidate
      }
    }
    return nil
  }

  private func showBest(for bucket: Int64) {
    guard let chosen = nearestFrame(to: bucket), let data = frames.data(for: chosen) else {
      if imageBucket != bucket {
        image = nil
        imageBucket = nil
        shownFrame = nil
      }
      return
    }
    if chosen == shownFrame, image != nil {
      imageBucket = bucket
      return
    }
    guard let decoded = Self.decode(data) else { return }
    image = decoded
    imageBucket = bucket
    shownFrame = chosen
  }

  private func startInteractiveIfIdle() {
    guard !jobs.values.contains(where: \.interactive), let bucket = pendingInteractive else {
      return
    }
    pendingInteractive = nil
    guard !frames.contains(bucket), !jobs.values.contains(where: { $0.bucket == bucket }) else {
      return
    }
    start(bucket: bucket, interactive: true)
  }

  private func fillPrefetchSlots() {
    guard source != nil, restingUntil == nil, prefetchAllowed() else { return }
    while prefetchBusy < backgroundWorkers, let bucket = nextPrefetchBucket() {
      prefetchBusy += 1
      start(bucket: bucket, interactive: false)
    }
  }

  private func nextPrefetchBucket() -> Int64? {
    while !neighboringBuckets.isEmpty {
      let bucket = neighboringBuckets.removeFirst()
      if !frames.contains(bucket), !failed.contains(bucket),
        !jobs.values.contains(where: { $0.bucket == bucket })
      {
        return bucket
      }
    }
    guard prefetchReady else { return nil }
    while prefetchIndex < prefetchOrder.count {
      let bucket = prefetchOrder[prefetchIndex]
      prefetchIndex += 1
      if !frames.contains(bucket), !failed.contains(bucket),
        !jobs.values.contains(where: { $0.bucket == bucket })
      {
        return bucket
      }
    }
    return nil
  }

  private func start(bucket: Int64, interactive: Bool) {
    guard let source, duration > 0 else { return }
    let decoder = decoderFactory()
    let key = UUID()
    let expected = generation
    let timeout = Task { [weak self] in
      try? await Task.sleep(for: Self.timeout)
      guard let self, !Task.isCancelled, self.generation == expected else { return }
      self.finish(key, image: nil)
    }
    jobs[key] = Job(
      decoder: decoder, bucket: bucket, interactive: interactive, timeout: timeout)
    let middle = Self.snapshotPosition(bucket: bucket, interval: interval, duration: duration)
    decoder.start(source: source, position: Float(Double(middle) / Double(duration))) {
      [weak self] image in
      self?.finish(key, image: image)
    }
  }

  private func finish(_ key: UUID, image: CGImage?) {
    guard let job = jobs.removeValue(forKey: key) else { return }
    job.timeout.cancel()
    job.decoder.cancel()
    if let image, let data = Self.encode(image) {
      frames.insert(data, for: job.bucket)
      failed.remove(job.bucket)
      preparedCount = frames.count
      if let requested, shownFrame != requested { showBest(for: requested) }
    } else {
      failed.insert(job.bucket)
    }
    if job.interactive {
      startInteractiveIfIdle()
    } else {
      prefetchFailures = !frames.contains(job.bucket) ? prefetchFailures + 1 : 0
      let epoch = slotEpoch
      if prefetchFailures >= Self.failuresBeforeBackoff, restingUntil == nil {
        // All background decoders rest together; hovering keeps working.
        prefetchFailures = 0
        restingUntil = .now + prefetchBackoff
        Task { [weak self, prefetchBackoff] in
          try? await Task.sleep(for: prefetchBackoff)
          guard let self, self.slotEpoch == epoch else { return }
          self.restingUntil = nil
          self.fillPrefetchSlots()
        }
      }
      Task { [weak self, prefetchPause] in
        try? await Task.sleep(for: prefetchPause)
        guard let self, self.slotEpoch == epoch, self.prefetchBusy > 0 else { return }
        self.prefetchBusy -= 1
        self.fillPrefetchSlots()
      }
    }
  }

  static func neighbors(of bucket: Int64, interval: Int64, duration: Int64) -> [Int64] {
    guard interval > 0, duration > 0 else { return [] }
    return [1, -1, 2, -2].compactMap { distance in
      let (offset, multiplicationOverflow) = interval.multipliedReportingOverflow(
        by: Int64(distance))
      let (candidate, additionOverflow) = bucket.addingReportingOverflow(offset)
      guard !multiplicationOverflow, !additionOverflow, candidate >= 0, candidate < duration
      else { return nil }
      return candidate
    }
  }

  var cachedByteCount: Int { frames.byteCount }

  /// Where a step's frame is taken: its middle, but never in the last seconds, where VLC finds
  /// no frame to decode after the seek.
  static func snapshotPosition(bucket: Int64, interval: Int64, duration: Int64) -> Int64 {
    max(0, min(bucket + interval / 2, duration - endMargin))
  }
  static let endMargin: Int64 = 3_000

  /// About 45 KB per frame instead of 230 KB decoded: an hour-long episode needs about 16 MB.
  static func encode(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }

  static func decode(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(
      source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
  }
}

/// A controllable decode boundary lets scheduling and lifetime tests use generated
/// images without opening a media engine, network connection or real media file.
@MainActor
protocol ScrubPreviewDecoding: AnyObject {
  func start(source: URL, position: Float, completion: @escaping @MainActor (CGImage?) -> Void)
  func cancel()
}

@MainActor
private final class NativeScrubPreviewDecoder: NSObject, ScrubPreviewDecoding {
  private var thumbnailer: VLCMediaThumbnailer?
  private var completion: (@MainActor (CGImage?) -> Void)?

  isolated deinit { cancel() }

  func start(source: URL, position: Float, completion: @escaping @MainActor (CGImage?) -> Void) {
    self.completion = completion
    let media = VLCMedia(url: source)
    media.addOption(":no-audio")
    media.addOption(":no-spu")
    let thumbnailer = VLCMediaThumbnailer(media: media, andDelegate: self)
    thumbnailer.thumbnailWidth = 320
    thumbnailer.thumbnailHeight = 320
    thumbnailer.snapshotPosition = position
    self.thumbnailer = thumbnailer
    thumbnailer.fetchThumbnail()
  }

  func cancel() {
    thumbnailer?.delegate = nil
    thumbnailer = nil
    completion = nil
  }

  private func complete(_ thumbnailer: VLCMediaThumbnailer, image: CGImage?) {
    guard self.thumbnailer === thumbnailer else { return }
    let completion = completion
    cancel()
    completion?(image)
  }
}

extension NativeScrubPreviewDecoder: VLCMediaThumbnailerDelegate {
  nonisolated func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
    let box = UncheckedThumbnailer(value: mediaThumbnailer)
    Task { @MainActor [weak self] in self?.complete(box.value, image: nil) }
  }

  nonisolated func mediaThumbnailer(
    _ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage
  ) {
    let box = UncheckedThumbnailer(value: mediaThumbnailer)
    let image = UncheckedImage(value: thumbnail)
    Task { @MainActor [weak self] in self?.complete(box.value, image: image.value) }
  }
}

private struct UncheckedThumbnailer: @unchecked Sendable { let value: VLCMediaThumbnailer }
private struct UncheckedImage: @unchecked Sendable { let value: CGImage }
