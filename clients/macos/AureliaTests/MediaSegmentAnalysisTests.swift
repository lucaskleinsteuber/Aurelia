import Foundation
import Testing

@testable import Aurelia

/// Synthetic sound only: seeded noise and tones, never real media.
private struct SyntheticAudio {
  private var state: UInt64

  init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

  mutating func noise(seconds: Double) -> [Float] {
    let count = Int(seconds * AudioFingerprint.sampleRate)
    var result = [Float](repeating: 0, count: count)
    var low: Float = 0
    for index in 0..<count {
      state ^= state << 13
      state ^= state >> 7
      state ^= state << 17
      let white = Float(Int64(bitPattern: state % 2_000_001) - 1_000_000) / 1_000_000
      // Gently filtered noise with a slowly changing tone, like dialogue under ambience.
      low = low * 0.92 + white * 0.08
      let tone = sin(Float(index) * 0.03 + Float(index / 4_000)) * 0.15
      result[index] = low * 0.6 + tone
    }
    return result
  }

  /// A recognisable "theme": a melody of chords that changes every quarter second.
  static func theme(seconds: Double) -> [Float] {
    let count = Int(seconds * AudioFingerprint.sampleRate)
    let notes: [Float] = [440, 523, 659, 587, 494, 392, 349, 330, 294, 523, 698, 784]
    return (0..<count).map { index in
      let time = Float(index) / Float(AudioFingerprint.sampleRate)
      let note = notes[(index / 2_756) % notes.count]
      return 0.3 * sin(2 * .pi * note * time) + 0.2 * sin(2 * .pi * note * 1.5 * time)
        + 0.1 * sin(2 * .pi * note * 2.01 * time)
    }
  }
}

struct SkipSegmentLogicTests {
  private func chapter(_ index: Int32, _ title: String, _ start: Int64, _ length: Int64)
    -> PlaybackChapter
  {
    PlaybackChapter(
      index: index, title: title, timeOffsetMilliseconds: start, durationMilliseconds: length)
  }

  @Test func namedChaptersBecomeIntroAndCredits() {
    let duration: Int64 = 2_700_000
    let chapters = [
      chapter(0, "Cold Open", 0, 150_000), chapter(1, "Intro", 150_000, 22_000),
      chapter(2, "Part 1", 172_000, 2_300_000), chapter(3, "End Credits", 2_640_000, 60_000),
    ]
    let segments = SkipSegmentLogic.fromChapters(chapters, duration: duration)
    #expect(segments.introStart == 150_000 && segments.introEnd == 172_000)
    #expect(segments.creditsStart == 2_640_000)
    // Ordinary numbered chapters and an "Introduction" offer nothing to skip.
    #expect(
      SkipSegmentLogic.fromChapters(
        [chapter(0, "Introduction", 0, 60_000), chapter(1, "Chapter 2", 60_000, 600_000)],
        duration: duration
      ).isEmpty)
  }

  @Test func serverTimesWinAndAnAnalyzedEmptyResultSkipsNothing() {
    let chapters = [chapter(0, "Opening", 10_000, 30_000)]
    let stored = MediaSegments(
      mediaId: UUID(), analyzed: true, introStartMilliseconds: 100_000,
      introEndMilliseconds: 120_000, creditsStartMilliseconds: nil, source: .detected,
      analysisVersion: 1)
    #expect(
      SkipSegmentLogic.resolve(server: stored, chapters: chapters, duration: 2_000_000).introEnd
        == 120_000)
    let none = MediaSegments(
      mediaId: UUID(), analyzed: true, introStartMilliseconds: nil, introEndMilliseconds: nil,
      creditsStartMilliseconds: nil, source: .none, analysisVersion: 1)
    #expect(SkipSegmentLogic.resolve(server: none, chapters: chapters, duration: 2_000_000).isEmpty)
    #expect(
      SkipSegmentLogic.resolve(server: nil, chapters: chapters, duration: 2_000_000).introEnd
        == 40_000)
  }

  @Test func promptsAppearOnlyInsideTheirParts() {
    let segments = SkipSegments(introStart: 60_000, introEnd: 90_000, creditsStart: 2_600_000)
    let duration: Int64 = 2_700_000
    #expect(
      SkipSegmentLogic.prompt(position: 30_000, duration: duration, segments: segments) == nil)
    #expect(
      SkipSegmentLogic.prompt(position: 61_000, duration: duration, segments: segments)
        == .intro(target: 90_000))
    #expect(
      SkipSegmentLogic.prompt(position: 89_000, duration: duration, segments: segments) == nil)
    #expect(
      SkipSegmentLogic.prompt(position: 2_610_000, duration: duration, segments: segments)
        == .credits(target: 2_699_500))
    #expect(
      SkipSegmentLogic.prompt(position: 2_699_000, duration: duration, segments: segments) == nil)
  }
}

struct AudioFingerprintMatchingTests {
  @Test func sharedThemeIsFoundWhereverItStarts() {
    var first = SyntheticAudio(seed: 1)
    var second = SyntheticAudio(seed: 2)
    let theme = SyntheticAudio.theme(seconds: 24)
    // Different cold opens: the theme starts at 95 s in one episode and 170 s in the other.
    let episodeA = first.noise(seconds: 95) + theme + first.noise(seconds: 60)
    let episodeB = second.noise(seconds: 170) + theme + second.noise(seconds: 45)
    let match = SegmentMatcher.longestCommon(
      AudioFingerprint.compute(episodeA), AudioFingerprint.compute(episodeB), minimum: 10,
      maximum: 150)
    let found = try! #require(match)
    #expect(abs(found.firstStart - 95) < 1)
    #expect(abs(found.firstEnd - 119) < 1)
    #expect(abs(found.secondStart - 170) < 1)
  }

  @Test func unrelatedSoundHasNoCommonPassage() {
    var first = SyntheticAudio(seed: 3)
    var second = SyntheticAudio(seed: 4)
    let match = SegmentMatcher.longestCommon(
      AudioFingerprint.compute(first.noise(seconds: 120)),
      AudioFingerprint.compute(second.noise(seconds: 120)), minimum: 10, maximum: 150)
    #expect(match == nil)
  }

  @Test func theLargestAgreeingGroupWinsOverARecapClip() {
    let chosen = SegmentConsensus.choose([
      (start: 95.0, end: 119.0), (start: 300.0, end: 340.0), (start: 95.4, end: 118.8),
    ])
    #expect(chosen.map { abs($0.start - 95.4) < 0.5 && abs($0.end - 119) < 0.5 } == true)
  }
}

/// A writer that delivers far more than the reader needs must never block: VLC blocked on a
/// full pipe made stopping it wait forever and froze the app in 1.7.0.
struct SamplePipeTests {
  @Test(.timeLimit(.minutes(1))) func keepsDrainingPastTheLimitSoTheWriterNeverBlocks() async throws {
    let pipe = try SamplePipe(limit: 1_000)
    pipe.startReading()
    let path = pipe.path
    let wrote = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
      DispatchQueue.global().async {
        let descriptor = open(path, O_WRONLY)
        var header = [UInt8](repeating: 0, count: 44)
        header.replaceSubrange(0..<4, with: Array("RIFF".utf8))
        header.replaceSubrange(8..<16, with: Array("WAVEfmt ".utf8))
        header[16] = 16
        header.replaceSubrange(36..<40, with: Array("data".utf8))
        var total = header.withUnsafeBytes { write(descriptor, $0.baseAddress, 44) }
        // About 4 MB: far more than a pipe holds, so this only finishes if it keeps draining.
        let block = [UInt8](repeating: 1, count: 65_536)
        for _ in 0..<64 {
          total += block.withUnsafeBytes { write(descriptor, $0.baseAddress, block.count) }
        }
        close(descriptor)
        continuation.resume(returning: total)
      }
    }
    #expect(wrote == 44 + 64 * 65_536)
    let samples = await pipe.finish()
    pipe.close()
    #expect(samples.count == 1_000)
  }
}

/// Runs VLC's in-memory audio output on a synthetic file written for this test only.
@MainActor
struct VLCAudioSampleReaderTests {
  @Test func decodesASyntheticSoundtrackIntoMemory() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AureliaSegmentTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var generator = SyntheticAudio(seed: 7)
    let samples =
      generator.noise(seconds: 20) + SyntheticAudio.theme(seconds: 15)
      + generator.noise(seconds: 10)
    let url = directory.appendingPathComponent("synthetic.wav")
    try Self.writeWAV(samples, to: url)

    let reader = VLCAudioSampleReader()
    let output = try await reader.read(url: url, start: 5, length: 30, timeout: .seconds(60))
    let seconds = Double(output.samples.count) / AudioFingerprint.sampleRate
    #expect(seconds > 28 && seconds < 32)
    #expect(output.durationMilliseconds > 40_000)
    // The theme decoded from the file matches the generated theme at 15 s into the read.
    let match = SegmentMatcher.longestCommon(
      AudioFingerprint.compute(output.samples),
      AudioFingerprint.compute(SyntheticAudio.theme(seconds: 15)), minimum: 8, maximum: 60)
    let found = try #require(match)
    #expect(abs(found.firstStart - 15) < 1)
  }

  private static func writeWAV(_ samples: [Float], to url: URL) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    let rate = UInt32(AudioFingerprint.sampleRate)
    let byteCount = UInt32(samples.count * 2)
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36) + byteCount)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(1))
    append(rate)
    append(rate * 2)
    append(UInt16(2))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(byteCount)
    for sample in samples {
      append(Int16(max(-1, min(1, sample)) * 32_767))
    }
    try data.write(to: url)
  }
}
