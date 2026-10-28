import CoreGraphics
import Foundation
import Testing

@testable import Aurelia

/// All decoded images are invented pixels supplied by the fake. These tests never
/// construct VLCMedia/thumbnailers, start playback, connect to a server or use files.
@MainActor
struct ScrubPreviewSchedulingTests {
  @Test func rapidPointerMovementOnlyStartsTheLatestSettledBucket() async throws {
    let recorder = PreviewDecodeRecorder()
    let previews = makeController(recorder: recorder, delay: .milliseconds(40))
    defer { previews.reset() }
    previews.configure(mediaID: UUID(), source: source(1), duration: 100_000)
    for position in stride(from: Int64(0), to: 50_000, by: 100) { previews.request(at: position) }
    #expect(recorder.decoders.isEmpty)
    try await waitUntil { recorder.decoders.count == 1 }
    #expect(abs(recorder.decoders[0].position - 0.45) < 0.0001)
    recorder.decoders[0].complete(try pixels())
    #expect(previews.imageBucket == 40_000)
    #expect(previews.preparedCount == 1)
    previews.request(at: 49_000)
    #expect(previews.image != nil)
    #expect(recorder.decoders.count == 1)
  }

  @Test func latestPendingHoverWinsAndACachedFrameShowsImmediately() async throws {
    let recorder = PreviewDecodeRecorder()
    let previews = makeController(recorder: recorder)
    defer { previews.reset() }
    previews.configure(mediaID: UUID(), source: source(1), duration: 100_000)
    previews.request(at: 0)
    try await waitUntil { recorder.decoders.count == 1 }
    previews.request(at: 20_000)
    previews.request(at: 40_000)
    try await Task.sleep(for: .milliseconds(20))
    #expect(recorder.decoders.count == 1)
    recorder.decoders[0].complete(try pixels())
    try await waitUntil { recorder.decoders.count == 2 }
    #expect(abs(recorder.decoders[1].position - 0.45) < 0.0001)
    previews.request(at: 0)
    #expect(previews.imageBucket == 0)
    #expect(previews.image != nil)
    recorder.decoders[1].complete(try pixels())
    #expect(previews.imageBucket == 0)
    #expect(recorder.decoders.count == 2)
  }

  @Test func immediateNeighborsHavePriorityOverTheDeferredCoarsePass() async throws {
    let recorder = PreviewDecodeRecorder()
    let previews = makeController(recorder: recorder, neighbors: true)
    defer { previews.reset() }
    previews.configure(mediaID: UUID(), source: source(1), duration: 100_000)
    previews.request(at: 50_000)
    try await waitUntil { recorder.decoders.count == 2 }
    #expect(abs(recorder.decoders[0].position - 0.55) < 0.0001)
    #expect(abs(recorder.decoders[1].position - 0.65) < 0.0001)
    recorder.decoders[1].complete(try pixels())
    try await waitUntil { recorder.decoders.count == 3 }
    #expect(abs(recorder.decoders[2].position - 0.45) < 0.0001)
    #expect(previews.preparedCount == 1)
    recorder.decoders[0].complete(try pixels())
    #expect(previews.imageBucket == 50_000)
    #expect(previews.image != nil)
  }

  @Test func compressedCacheEvictsLeastRecentlyDisplayedFramesWithinItsLimits() async throws {
    let recorder = PreviewDecodeRecorder()
    let previews = makeController(recorder: recorder, cacheFrameLimit: 2)
    defer { previews.reset() }
    previews.configure(mediaID: UUID(), source: source(1), duration: 100_000)
    for (index, position) in [Int64(0), 20_000, 40_000].enumerated() {
      previews.request(at: position)
      try await waitUntil { recorder.decoders.count == index + 1 }
      recorder.decoders[index].complete(try pixels())
    }
    #expect(previews.preparedCount == 2)
    #expect(previews.cachedByteCount <= ScrubPreviewController.maximumCachedBytes)
    previews.request(at: 20_000)
    #expect(previews.imageBucket == 20_000)
    #expect(previews.image != nil)
    previews.request(at: 0)
    try await waitUntil { recorder.decoders.count == 4 }
    #expect(abs(recorder.decoders[3].position - 0.05) < 0.0001)
  }

  @Test func sourceRenewalAndTitleChangesRejectLateDecoderCallbacks() async throws {
    let recorder = PreviewDecodeRecorder()
    let previews = makeController(recorder: recorder)
    defer { previews.reset() }
    let media = UUID()
    previews.configure(mediaID: media, source: source(1), duration: 100_000)
    previews.request(at: 20_000)
    try await waitUntil { recorder.decoders.count == 1 }
    previews.configure(mediaID: media, source: source(2), duration: 100_000)
    try await waitUntil { recorder.decoders.count == 2 }
    #expect(recorder.decoders[0].cancelled)
    recorder.decoders[0].complete(try pixels())
    #expect(previews.image == nil)
    #expect(previews.preparedCount == 0)
    recorder.decoders[1].complete(try pixels())
    #expect(previews.imageBucket == 20_000)
    #expect(previews.preparedCount == 1)
    previews.configure(mediaID: media, source: source(3), duration: 100_000)
    #expect(previews.preparedCount == 1)
    #expect(previews.image != nil)
    previews.configure(mediaID: UUID(), source: source(3), duration: 100_000)
    #expect(previews.image == nil)
    #expect(previews.preparedCount == 0)
    #expect(previews.cachedByteCount == 0)
    recorder.decoders[1].complete(try pixels())
    #expect(previews.image == nil)
  }

  @Test func resetCancelsDebouncedAndActiveWorkWithoutAStalePublication() async throws {
    let recorder = PreviewDecodeRecorder()
    let previews = makeController(recorder: recorder, delay: .milliseconds(40))
    previews.configure(mediaID: UUID(), source: source(1), duration: 100_000)
    previews.request(at: 20_000)
    previews.reset()
    try await Task.sleep(for: .milliseconds(60))
    #expect(recorder.decoders.isEmpty)
    previews.configure(mediaID: UUID(), source: source(1), duration: 100_000)
    previews.request(at: 40_000)
    try await waitUntil { recorder.decoders.count == 1 }
    previews.reset()
    #expect(recorder.decoders[0].cancelled)
    recorder.decoders[0].complete(try pixels())
    #expect(previews.preparedCount == 0)
    #expect(previews.image == nil)
  }

  @Test func coarseBackgroundPreparationHasAFixedWorkBudget() async throws {
    let recorder = PreviewDecodeRecorder()
    let previews = ScrubPreviewController(
      prefetchWorkers: 1, prefetchDelay: .zero, prefetchAllowed: { true },
      interactiveDelay: .zero, decoderFactory: recorder.make)
    defer { previews.reset() }
    previews.configure(mediaID: UUID(), source: source(1), duration: 3_600_000)
    for index in 0..<ScrubPreviewController.backgroundPreparationLimit {
      try await waitUntil { recorder.decoders.count > index }
      recorder.decoders[index].complete(try pixels())
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(recorder.decoders.count == ScrubPreviewController.backgroundPreparationLimit)
    #expect(previews.preparedCount == ScrubPreviewController.backgroundPreparationLimit)
  }

  @Test func neighborBoundsNeverRequestOutsideTheTitle() {
    #expect(
      ScrubPreviewController.neighbors(of: 0, interval: 10_000, duration: 30_000) == [
        10_000, 20_000,
      ])
    #expect(
      ScrubPreviewController.neighbors(of: 20_000, interval: 10_000, duration: 30_000) == [
        10_000, 0,
      ])
    #expect(
      ScrubPreviewController.neighbors(of: Int64.max - 1, interval: 10, duration: Int64.max) == [
        Int64.max - 11, Int64.max - 21,
      ])
  }

  private func makeController(
    recorder: PreviewDecodeRecorder, delay: Duration = .zero, neighbors: Bool = false,
    cacheFrameLimit: Int = ScrubPreviewController.memoryFrameLimit
  ) -> ScrubPreviewController {
    ScrubPreviewController(
      prefetchWorkers: 1, prefetchDelay: .seconds(3600), prefetchAllowed: { neighbors },
      interactiveDelay: delay, cacheFrameLimit: cacheFrameLimit, decoderFactory: recorder.make)
  }

  private func source(_ number: Int) -> URL {
    URL(string: "https://preview-\(number).invalid/invented")!
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<1000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("The fake preview decoder did not receive its scheduled request.")
    throw CancellationError()
  }

  private func pixels() throws -> CGImage {
    let data = Data(repeating: 255, count: 16 * 16 * 4)
    let provider = try #require(CGDataProvider(data: data as CFData))
    return try #require(
      CGImage(
        width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
  }
}

@MainActor
private final class PreviewDecodeRecorder {
  var decoders: [FakeScrubPreviewDecoder] = []
  func make() -> any ScrubPreviewDecoding {
    let decoder = FakeScrubPreviewDecoder()
    decoders.append(decoder)
    return decoder
  }
}

@MainActor
private final class FakeScrubPreviewDecoder: ScrubPreviewDecoding {
  private(set) var position: Float = 0
  private(set) var cancelled = false
  private var completion: (@MainActor (CGImage?) -> Void)?

  func start(source: URL, position: Float, completion: @escaping @MainActor (CGImage?) -> Void) {
    self.position = position
    self.completion = completion
  }
  func cancel() { cancelled = true }
  // Deliberately deliver even after cancel, as a native callback already in flight might.
  func complete(_ image: CGImage?) { completion?(image) }
}
