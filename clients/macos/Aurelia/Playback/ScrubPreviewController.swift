import Combine
import CoreGraphics
@preconcurrency import Foundation
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import VLCKit

/// Timeline preview frames decoded live from the playing source, like Infuse. Shortly after a
/// title starts, frames for the whole timeline are prepared in the background, coarse to fine,
/// so hovering shows them at once; the pointer's own position is always decoded first. Frames
/// stay compressed in memory for the open title only: another title discards them, and nothing
/// is written to disk or the server.
@MainActor
final class ScrubPreviewController: NSObject, ObservableObject {
  static let minimumInterval: Int64 = 10_000
  static let maximumFrames = 720
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

  private var mediaID: UUID?
  private var source: URL?
  private var duration: Int64 = 0
  private var frames: [Int64: Data] = [:]
  private var failed: Set<Int64> = []
  private var requested: Int64?
  /// The step whose frame `image` actually shows.
  private var shownFrame: Int64?
  private var pendingInteractive: Int64?
  private var jobs: [ObjectIdentifier: Job] = [:]
  private var prefetchOrder: [Int64] = []
  private var prefetchIndex = 0
  private var prefetchBusy = 0
  private var slotEpoch = 0
  private var prefetchReady = false
  private var prefetchStart: Task<Void, Never>?
  private var generation = 0

  private struct Job {
    let thumbnailer: VLCMediaThumbnailer
    let bucket: Int64
    let interactive: Bool
    let timeout: Task<Void, Never>
  }

  /// Decoders for the background work, beside the pointer's own. Where the server gives
  /// previews their own budget, several cores work briefly so a whole episode is ready in
  /// seconds; older servers would count previews as playback streams, so they get one.
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
    prefetchAllowed: @escaping () -> Bool = { !ProcessInfo.processInfo.isLowPowerModeEnabled }
  ) {
    self.workerOverride = prefetchWorkers
    self.prefetchDelay = prefetchDelay
    self.prefetchPause = prefetchPause
    self.prefetchBackoff = prefetchBackoff
    self.prefetchAllowed = prefetchAllowed
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
      prefetchOrder = Self.prefetchOrder(duration: duration, interval: interval)
      prefetchIndex = 0
      fillPrefetchSlots()
    }
    if source != self.source {
      self.source = source
      cancelJobs()
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
    requested = bucket
    showBest(for: bucket)
    guard frames[bucket] == nil, !jobs.values.contains(where: { $0.bucket == bucket }) else {
      return
    }
    pendingInteractive = bucket
    startInteractiveIfIdle()
  }

  func reset() {
    generation += 1
    prefetchStart?.cancel()
    prefetchStart = nil
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
    frames = [:]
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
      job.thumbnailer.delegate = nil
    }
    jobs = [:]
    // Resting background slots belong to the cancelled work.
    prefetchBusy = 0
    restingUntil = nil
    slotEpoch += 1
  }

  /// The exact frame for `bucket`, else the closest prepared one within reach.
  func nearestFrame(to bucket: Int64) -> Int64? {
    if frames[bucket] != nil { return bucket }
    for steps in 1...Self.standInReach {
      for candidate in [bucket - steps * interval, bucket + steps * interval]
      where frames[candidate] != nil {
        return candidate
      }
    }
    return nil
  }

  private func showBest(for bucket: Int64) {
    guard let chosen = nearestFrame(to: bucket), let data = frames[chosen] else {
      if imageBucket != bucket {
        image = nil
        imageBucket = nil
        shownFrame = nil
      }
      return
    }
    guard chosen != shownFrame || imageBucket != bucket, let decoded = Self.decode(data) else {
      return
    }
    image = decoded
    imageBucket = bucket
    shownFrame = chosen
  }

  private func startInteractiveIfIdle() {
    guard !jobs.values.contains(where: \.interactive), let bucket = pendingInteractive else {
      return
    }
    pendingInteractive = nil
    guard frames[bucket] == nil, !jobs.values.contains(where: { $0.bucket == bucket }) else {
      return
    }
    start(bucket: bucket, interactive: true)
  }

  private func fillPrefetchSlots() {
    guard prefetchReady, source != nil, restingUntil == nil, prefetchAllowed() else { return }
    while prefetchBusy < backgroundWorkers, let bucket = nextPrefetchBucket() {
      prefetchBusy += 1
      start(bucket: bucket, interactive: false)
    }
  }

  private func nextPrefetchBucket() -> Int64? {
    while prefetchIndex < prefetchOrder.count {
      let bucket = prefetchOrder[prefetchIndex]
      prefetchIndex += 1
      if frames[bucket] == nil, !failed.contains(bucket),
        !jobs.values.contains(where: { $0.bucket == bucket })
      {
        return bucket
      }
    }
    return nil
  }

  private func start(bucket: Int64, interactive: Bool) {
    guard let source, duration > 0 else { return }
    let media = VLCMedia(url: source)
    media.addOption(":no-audio")
    media.addOption(":no-spu")
    let thumbnailer = VLCMediaThumbnailer(media: media, andDelegate: self)
    // The thumbnailer keeps the source's aspect ratio inside this box.
    thumbnailer.thumbnailWidth = 320
    thumbnailer.thumbnailHeight = 320
    let middle = Self.snapshotPosition(bucket: bucket, interval: interval, duration: duration)
    thumbnailer.snapshotPosition = Float(Double(middle) / Double(duration))
    let key = ObjectIdentifier(thumbnailer)
    let expected = generation
    let timeout = Task { [weak self] in
      try? await Task.sleep(for: Self.timeout)
      guard let self, !Task.isCancelled, self.generation == expected else { return }
      self.finish(key, image: nil)
    }
    jobs[key] = Job(
      thumbnailer: thumbnailer, bucket: bucket, interactive: interactive, timeout: timeout)
    thumbnailer.fetchThumbnail()
  }

  private func finish(_ key: ObjectIdentifier, image: CGImage?) {
    guard let job = jobs.removeValue(forKey: key) else { return }
    job.timeout.cancel()
    job.thumbnailer.delegate = nil
    if let image, let data = Self.encode(image) {
      frames[job.bucket] = data
      failed.remove(job.bucket)
      preparedCount = frames.count
      if let requested, shownFrame != requested { showBest(for: requested) }
    } else {
      failed.insert(job.bucket)
    }
    if job.interactive {
      startInteractiveIfIdle()
    } else {
      prefetchFailures = frames[job.bucket] == nil ? prefetchFailures + 1 : 0
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

  private func complete(_ thumbnailer: VLCMediaThumbnailer, image: CGImage?) {
    finish(ObjectIdentifier(thumbnailer), image: image)
  }

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

extension ScrubPreviewController: VLCMediaThumbnailerDelegate {
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
