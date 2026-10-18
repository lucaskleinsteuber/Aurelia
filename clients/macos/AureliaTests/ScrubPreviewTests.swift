import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import Aurelia

@MainActor
struct ScrubPreviewTests {
  @Test func intervalGrowsOnlyForLongTitles() {
    #expect(ScrubPreviewController.interval(for: 0) == 10_000)
    #expect(ScrubPreviewController.interval(for: 45 * 60_000) == 10_000)
    // Three hours stay within the frame limit with 15 s steps.
    #expect(ScrubPreviewController.interval(for: 3 * 3_600_000) == 15_000)
    let long = Int64(4 * 3_600_000 + 1)
    let steps =
      (long + ScrubPreviewController.interval(for: long) - 1)
      / ScrubPreviewController.interval(for: long)
    #expect(steps <= Int64(ScrubPreviewController.maximumFrames))
  }

  @Test func severalDecodersOnlyWhereTheServerKeepsPreviewsApart() {
    let previews = ScrubPreviewController()
    previews.configure(mediaID: UUID(), source: nil, duration: 60_000)
    #expect(previews.backgroundWorkers == 1)
    previews.configure(mediaID: nil, source: nil, duration: 60_000, parallel: true)
    #expect(previews.backgroundWorkers == ScrubPreviewController.parallelWorkers)
    #expect((2...6).contains(ScrubPreviewController.parallelWorkers))
    // With the pointer's own decoder this stays within the server's 8 per device.
    #expect(ScrubPreviewController.parallelWorkers + 1 <= 8)
  }

  @Test func framesAreTakenMidStepButNotAtTheVeryEnd() {
    #expect(
      ScrubPreviewController.snapshotPosition(bucket: 20_000, interval: 10_000, duration: 60_000)
        == 25_000)
    // A last step that ends 1.5 s after it starts (a real 60 min episode) is taken 3 s
    // before the end, where VLC still finds a frame.
    #expect(
      ScrubPreviewController.snapshotPosition(
        bucket: 3_610_000, interval: 10_000, duration: 3_611_480) == 3_608_480)
    #expect(
      ScrubPreviewController.snapshotPosition(bucket: 0, interval: 10_000, duration: 1_000) == 0)
  }

  @Test func backgroundOrderCoversTheTimelineCoarseFirstAndEveryStepOnce() {
    let order = ScrubPreviewController.prefetchOrder(duration: 265_000, interval: 10_000)
    #expect(order.count == 27)
    #expect(Set(order) == Set((0..<27).map { Int64($0) * 10_000 }))
    #expect(Array(order.prefix(4)) == [0, 80_000, 160_000, 240_000])
    #expect(ScrubPreviewController.prefetchOrder(duration: 0, interval: 10_000).isEmpty)
  }

  /// Decodes a synthetic 40 s video whose brightness changes every 10 s, entirely in memory.
  @Test(.timeLimit(.minutes(1))) func framesArePreparedInTheBackgroundAndDiscardedForTheNextTitle()
    async throws
  {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AureliaScrubPreview-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let video = directory.appendingPathComponent("steps.mp4")
    let levels: [UInt8] = [20, 90, 160, 235]
    try await Self.writeVideo(levels: levels, secondsPerLevel: 10, to: video)

    let previews = ScrubPreviewController(prefetchDelay: .zero)
    let started = Date()
    previews.configure(mediaID: UUID(), source: video, duration: 40_000, parallel: true)
    try await Self.waitUntil { previews.preparedCount == 4 }
    print("Prepared 4 preview frames in \(Date().timeIntervalSince(started)) s")

    // Hovering now shows the prepared frame at once, without decoding anything.
    for (index, level) in levels.enumerated() {
      previews.request(at: Int64(index) * 10_000 + 4_000)
      #expect(previews.imageBucket == Int64(index) * 10_000)
      let brightness = try #require(previews.image.map(Self.brightness))
      #expect(abs(brightness - Double(level)) < 20, "step \(index): \(brightness)")
    }

    previews.configure(mediaID: UUID(), source: video, duration: 40_000)
    #expect(previews.preparedCount == 0)
    #expect(previews.image == nil)
  }

  @Test(.timeLimit(.minutes(1))) func hoveringStillDecodesWhenBackgroundWorkIsOff() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AureliaScrubPreview-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let video = directory.appendingPathComponent("steps.mp4")
    try await Self.writeVideo(levels: [20, 235], secondsPerLevel: 10, to: video)

    let previews = ScrubPreviewController(prefetchDelay: .zero, prefetchAllowed: { false })
    previews.configure(mediaID: UUID(), source: video, duration: 20_000)
    try await Task.sleep(for: .milliseconds(500))
    #expect(previews.preparedCount == 0)

    previews.request(at: 15_000)
    try await Self.waitUntil { previews.imageBucket == 10_000 && previews.image != nil }
    #expect(previews.preparedCount == 1)
    let brightness = try #require(previews.image.map(Self.brightness))
    #expect(brightness > 200, "\(brightness)")
  }

  private static func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(30)
    while !condition() {
      guard Date() < deadline else {
        Issue.record("Timed out waiting for preview frames")
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  private static func brightness(_ image: CGImage) -> Double {
    var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
    let context = CGContext(
      data: &pixels, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
    let green = stride(from: 1, to: pixels.count, by: 4).map { Double(pixels[$0]) }
    return green.reduce(0, +) / Double(green.count)
  }

  /// One gray frame per second, each a key frame, so every position decodes exactly.
  static func writeVideo(levels: [UInt8], secondsPerLevel: Int, to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1],
      ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
      ])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let seconds = levels.count * secondsPerLevel
    for second in 0..<seconds {
      while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
      let pool = try #require(adaptor.pixelBufferPool)
      var buffer: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
      let pixels = try #require(buffer)
      CVPixelBufferLockBaseAddress(pixels, [])
      memset(
        CVPixelBufferGetBaseAddress(pixels), Int32(levels[second / secondsPerLevel]),
        CVPixelBufferGetDataSize(pixels))
      CVPixelBufferUnlockBaseAddress(pixels, [])
      #expect(
        adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(second), timescale: 1)))
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: Int64(seconds), timescale: 1))
    await writer.finishWriting()
    #expect(writer.status == .completed, "\(String(describing: writer.error))")
  }
}
