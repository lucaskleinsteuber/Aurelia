import Combine
import CoreGraphics
@preconcurrency import Foundation
@preconcurrency import VLCKit

/// Decodes a single frame near a timeline position live from the playing source, like Infuse.
/// Frames stay in memory for the open player only; nothing is written to disk or the server.
@MainActor
final class ScrubPreviewController: NSObject, ObservableObject {
  static let bucketMilliseconds: Int64 = 5_000
  static let cacheLimit = 90
  private static let timeout: Duration = .seconds(6)

  @Published private(set) var image: CGImage?
  @Published private(set) var imageBucket: Int64?

  private var source: URL?
  private var duration: Int64 = 0
  private var cache: [Int64: CGImage] = [:]
  private var cacheOrder: [Int64] = []
  private var requested: Int64?
  private var pending: Int64?
  private var inFlight: VLCMediaThumbnailer?
  private var inFlightBucket: Int64?
  private var timeoutTask: Task<Void, Never>?
  private var generation = 0

  func configure(source: URL?, duration: Int64) {
    if source != self.source {
      reset()
      self.source = source
    }
    self.duration = duration
  }

  static func bucket(for milliseconds: Int64) -> Int64 {
    max(0, milliseconds) / bucketMilliseconds * bucketMilliseconds
  }

  /// Shows the frame for `milliseconds` as soon as it is decoded. Only the latest request is
  /// fetched next, so fast pointer movement never queues up work.
  func request(at milliseconds: Int64) {
    guard source != nil, duration > 0 else { return }
    let bucket = Self.bucket(for: min(milliseconds, duration - 1))
    requested = bucket
    if let cached = cache[bucket] {
      image = cached
      imageBucket = bucket
      return
    }
    guard inFlightBucket != bucket else { return }
    pending = bucket
    startNextIfIdle()
  }

  func reset() {
    generation += 1
    timeoutTask?.cancel()
    timeoutTask = nil
    inFlight?.delegate = nil
    inFlight = nil
    inFlightBucket = nil
    pending = nil
    requested = nil
    cache = [:]
    cacheOrder = []
    image = nil
    imageBucket = nil
  }

  private func startNextIfIdle() {
    guard inFlight == nil, let bucket = pending, let source, duration > 0 else { return }
    pending = nil
    let media = VLCMedia(url: source)
    media.addOption(":no-audio")
    media.addOption(":no-spu")
    let thumbnailer = VLCMediaThumbnailer(media: media, andDelegate: self)
    // The thumbnailer keeps the source's aspect ratio inside this box.
    thumbnailer.thumbnailWidth = 320
    thumbnailer.thumbnailHeight = 320
    let middle = min(duration - 1, bucket + Self.bucketMilliseconds / 2)
    thumbnailer.snapshotPosition = Float(Double(middle) / Double(duration))
    inFlight = thumbnailer
    inFlightBucket = bucket
    let expected = generation
    timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: Self.timeout)
      guard let self, !Task.isCancelled, self.generation == expected,
        self.inFlightBucket == bucket
      else { return }
      self.finish(bucket: bucket, image: nil)
    }
    thumbnailer.fetchThumbnail()
  }

  private func finish(bucket: Int64, image: CGImage?) {
    guard inFlightBucket == bucket else { return }
    timeoutTask?.cancel()
    timeoutTask = nil
    inFlight?.delegate = nil
    inFlight = nil
    inFlightBucket = nil
    if let image {
      cache[bucket] = image
      cacheOrder.append(bucket)
      if cacheOrder.count > Self.cacheLimit {
        cache[cacheOrder.removeFirst()] = nil
      }
      if requested == bucket {
        self.image = image
        imageBucket = bucket
      }
    }
    startNextIfIdle()
  }

  private func complete(_ thumbnailer: VLCMediaThumbnailer, image: CGImage?) {
    guard thumbnailer === inFlight, let bucket = inFlightBucket else { return }
    finish(bucket: bucket, image: image)
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
