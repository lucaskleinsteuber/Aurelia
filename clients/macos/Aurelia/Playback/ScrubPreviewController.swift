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
  private let prefetchWorkers: Int
  private let prefetchDelay: Duration
  private let prefetchPause: Duration
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

  /// Two background decoders, a short pause after each frame and the low-power check keep
  /// playback smooth and the server's per-address request budget untouched.
  init(
    prefetchWorkers: Int = 2, prefetchDelay: Duration = .seconds(4),
    prefetchPause: Duration = .milliseconds(250),
    prefetchAllowed: @escaping () -> Bool = { !ProcessInfo.processInfo.isLowPowerModeEnabled }
  ) {
    self.prefetchWorkers = prefetchWorkers
    self.prefetchDelay = prefetchDelay
    self.prefetchPause = prefetchPause
    self.prefetchAllowed = prefetchAllowed
  }

  /// Frames belong to `mediaID`. A new source for the same title, after a reconnect, keeps
  /// them; another title starts over.
  func configure(mediaID: UUID?, source: URL?, duration: Int64) {
    if mediaID != self.mediaID {
      reset()
      self.mediaID = mediaID
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
    guard prefetchReady, source != nil, prefetchAllowed() else { return }
    while prefetchBusy < prefetchWorkers, let bucket = nextPrefetchBucket() {
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
    let middle = min(duration - 1, bucket + interval / 2)
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
      let epoch = slotEpoch
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

  /// About 10 KB per frame instead of 230 KB decoded, so a whole film fits in a few MB.
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
