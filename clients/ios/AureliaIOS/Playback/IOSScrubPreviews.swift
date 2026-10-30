import Combine
import CoreGraphics
@preconcurrency import Foundation
import ImageIO
@preconcurrency import MobileVLCKit
import UniformTypeIdentifiers

/// Timeline preview frames decoded live from the playing title through its preview relay.
/// Shortly after a title starts, frames for the whole timeline are prepared in the background,
/// coarse to fine, so scrubbing shows them at once; the scrub position's own frame is always
/// decoded first. Frames stay compressed in memory for the open title only: another title
/// discards them, and nothing is written to disk or the server.
@MainActor
final class IOSScrubPreviews: NSObject, ObservableObject {
  private static let timeout: Duration = .seconds(6)
  static let failuresBeforeBackoff = 3

  @Published private(set) var image: CGImage?
  /// The timeline step `image` is shown for; it may be a nearby stand-in frame.
  @Published private(set) var imageBucket: Int64?
  @Published private(set) var preparedCount = 0

  private(set) var interval = IOSScrubPreviewPlan.minimumInterval
  private let prefetchDelay: Duration
  private let prefetchBackoff: Duration
  private var parallel = false
  private var mediaID: UUID?
  private var source: URL?
  private var duration: Int64 = 0
  private var frames: [Int64: Data] = [:]
  private var failed: Set<Int64> = []
  private var requested: Int64?
  private var shownFrame: Int64?
  private var pendingInteractive: Int64?
  private var jobs: [UUID: Job] = [:]
  private var thumbnailerKeys: [ObjectIdentifier: UUID] = [:]
  private var order: [Int64] = []
  private var orderIndex = 0
  private var busy = 0
  private var failures = 0
  private var resting = false
  private var ready = false
  private var startTask: Task<Void, Never>?
  private var epoch = 0
  private var serverFrameFetcher: (@MainActor (UUID, Int64) async -> Data?)?

  private struct Job {
    var thumbnailer: VLCMediaThumbnailer?
    var task: Task<Void, Never>?
    let bucket: Int64
    let interactive: Bool
    let timeout: Task<Void, Never>
  }

  init(prefetchDelay: Duration = .seconds(4), prefetchBackoff: Duration = .seconds(60)) {
    self.prefetchDelay = prefetchDelay
    self.prefetchBackoff = prefetchBackoff
  }

  var backgroundWorkers: Int { IOSScrubPreviewPlan.workers(parallel: parallel) }

  /// Frames belong to `mediaID`; a reconnect to the same title keeps them.
  func configure(
    mediaID: UUID?, source: URL?, duration: Int64, parallel: Bool,
    serverFrameFetcher: (@MainActor (UUID, Int64) async -> Data?)? = nil
  ) {
    if mediaID != self.mediaID {
      reset()
      self.mediaID = mediaID
    }
    self.serverFrameFetcher = serverFrameFetcher
    self.parallel = parallel
    let duration = max(0, duration)
    if duration != self.duration {
      self.duration = duration
      let interval = IOSScrubPreviewPlan.interval(for: duration)
      if interval != self.interval {
        discardFrames()
        self.interval = interval
      }
      order = IOSScrubPreviewPlan.order(duration: duration, interval: interval)
      orderIndex = 0
    }
    if source != self.source {
      self.source = source
      cancelJobs()
      startTask?.cancel()
      startTask = nil
      ready = false
    }
    if startTask == nil && !ready && (source != nil || serverFrameFetcher != nil) {
      let expected = epoch
      startTask = Task { [weak self, prefetchDelay] in
        try? await Task.sleep(for: prefetchDelay)
        guard let self, !Task.isCancelled, self.epoch == expected else { return }
        self.ready = true
        self.fill()
      }
      startInteractiveIfIdle()
    } else if ready {
      fill()
    }
  }

  func bucket(for milliseconds: Int64) -> Int64 {
    IOSScrubPreviewPlan.bucket(for: milliseconds, interval: interval)
  }

  /// Shows the frame for `milliseconds`, or a nearby prepared one until it is decoded.
  func request(at milliseconds: Int64) {
    guard source != nil || serverFrameFetcher != nil, duration > 0 else { return }
    let bucket = bucket(for: min(milliseconds, duration - 1))
    requested = bucket
    show(bucket)
    guard frames[bucket] == nil, !jobs.values.contains(where: { $0.bucket == bucket }) else {
      return
    }
    pendingInteractive = bucket
    startInteractiveIfIdle()
  }

  func reset() {
    startTask?.cancel()
    startTask = nil
    ready = false
    cancelJobs()
    discardFrames()
    mediaID = nil
    source = nil
    serverFrameFetcher = nil
    duration = 0
    interval = IOSScrubPreviewPlan.minimumInterval
    order = []
  }

  private func discardFrames() {
    frames = [:]
    failed = []
    requested = nil
    shownFrame = nil
    pendingInteractive = nil
    orderIndex = 0
    preparedCount = 0
    image = nil
    imageBucket = nil
  }

  private func cancelJobs() {
    for job in jobs.values {
      job.timeout.cancel()
      job.task?.cancel()
      job.thumbnailer?.delegate = nil
    }
    jobs = [:]
    thumbnailerKeys = [:]
    busy = 0
    resting = false
    failures = 0
    epoch += 1
  }

  private func show(_ bucket: Int64) {
    guard
      let chosen = IOSScrubPreviewPlan.nearest(
        to: bucket, interval: interval, prepared: { self.frames[$0] != nil }),
      let data = frames[chosen]
    else {
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

  private func fill() {
    guard ready, source != nil || serverFrameFetcher != nil, !resting,
      !ProcessInfo.processInfo.isLowPowerModeEnabled
    else {
      return
    }
    while busy < backgroundWorkers, let bucket = nextBucket() {
      busy += 1
      start(bucket: bucket, interactive: false)
    }
  }

  private func nextBucket() -> Int64? {
    while orderIndex < order.count {
      let bucket = order[orderIndex]
      orderIndex += 1
      if frames[bucket] == nil, !failed.contains(bucket),
        !jobs.values.contains(where: { $0.bucket == bucket })
      {
        return bucket
      }
    }
    return nil
  }

  private func start(bucket: Int64, interactive: Bool) {
    guard duration > 0 else { return }
    let key = UUID()
    let expected = epoch
    let timeout = Task { [weak self] in
      try? await Task.sleep(for: Self.timeout)
      guard let self, !Task.isCancelled, self.epoch == expected else { return }
      self.finish(key, image: nil)
    }
    let position = IOSScrubPreviewPlan.snapshotPosition(
      bucket: bucket, interval: interval, duration: duration)
    if let mediaID, let fetcher = serverFrameFetcher {
      let seconds = max(0, position / 1_000)
      let task = Task { [weak self] in
        if let data = await fetcher(mediaID, seconds), Self.decode(data) != nil {
          guard let self, !Task.isCancelled, self.epoch == expected else { return }
          self.finishData(key, data: data)
          return
        }
        guard let self, !Task.isCancelled, self.epoch == expected else { return }
        self.startLocalThumbnailer(key: key, bucket: bucket)
      }
      jobs[key] = Job(
        thumbnailer: nil, task: task, bucket: bucket, interactive: interactive, timeout: timeout)
      return
    }
    jobs[key] = Job(
      thumbnailer: nil, task: nil, bucket: bucket, interactive: interactive, timeout: timeout)
    startLocalThumbnailer(key: key, bucket: bucket)
  }

  private func startLocalThumbnailer(key: UUID, bucket: Int64) {
    guard var job = jobs[key], let source, duration > 0 else {
      finish(key, image: nil)
      return
    }
    let media = VLCMedia(url: source)
    media.addOption(":no-audio")
    media.addOption(":no-spu")
    let thumbnailer = VLCMediaThumbnailer(media: media, andDelegate: self)
    thumbnailer.thumbnailWidth = 480
    thumbnailer.thumbnailHeight = 480
    let position = IOSScrubPreviewPlan.snapshotPosition(
      bucket: bucket, interval: interval, duration: duration)
    thumbnailer.snapshotPosition = Float(Double(position) / Double(duration))
    thumbnailerKeys[ObjectIdentifier(thumbnailer)] = key
    job.thumbnailer = thumbnailer
    job.task = nil
    jobs[key] = job
    thumbnailer.fetchThumbnail()
  }

  private func finishData(_ key: UUID, data: Data) {
    guard let job = jobs.removeValue(forKey: key) else { return }
    job.timeout.cancel()
    job.task?.cancel()
    if let thumbnailer = job.thumbnailer {
      thumbnailerKeys.removeValue(forKey: ObjectIdentifier(thumbnailer))
      thumbnailer.delegate = nil
    }
    frames[job.bucket] = data
    failed.remove(job.bucket)
    preparedCount = frames.count
    if let requested, shownFrame != requested { show(requested) }
    if job.interactive {
      startInteractiveIfIdle()
      return
    }
    busy = max(0, busy - 1)
    failures = 0
    fill()
  }

  private func finish(_ key: UUID, image: CGImage?) {
    guard let job = jobs.removeValue(forKey: key) else { return }
    job.timeout.cancel()
    job.task?.cancel()
    if let thumbnailer = job.thumbnailer {
      thumbnailerKeys.removeValue(forKey: ObjectIdentifier(thumbnailer))
      thumbnailer.delegate = nil
    }
    if let image, let data = Self.encode(image) {
      frames[job.bucket] = data
      failed.remove(job.bucket)
      preparedCount = frames.count
      if let requested, shownFrame != requested { show(requested) }
    } else {
      failed.insert(job.bucket)
    }
    if job.interactive {
      startInteractiveIfIdle()
      return
    }
    busy = max(0, busy - 1)
    failures = frames[job.bucket] == nil ? failures + 1 : 0
    if failures >= Self.failuresBeforeBackoff, !resting {
      // All background decoders rest together, for example while the server is busy.
      failures = 0
      resting = true
      let expected = epoch
      Task { [weak self, prefetchBackoff] in
        try? await Task.sleep(for: prefetchBackoff)
        guard let self, self.epoch == expected else { return }
        self.resting = false
        self.fill()
      }
      return
    }
    fill()
  }

  private func complete(_ thumbnailer: VLCMediaThumbnailer, image: CGImage?) {
    guard let key = thumbnailerKeys.removeValue(forKey: ObjectIdentifier(thumbnailer)) else {
      return
    }
    finish(key, image: image)
  }

  /// Compressed in memory: an hour-long episode needs about 30 MB.
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

extension IOSScrubPreviews: VLCMediaThumbnailerDelegate {
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
