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

  @Test func anUnnamedClosingChapterCountsAsCreditsOnlyWhenNeighboursAgree() {
    func chapters(_ starts: [Int64]) -> [PlaybackChapter] {
      starts.enumerated().map {
        PlaybackChapter(
          index: Int32($0.offset), title: "Disc 1", timeOffsetMilliseconds: $0.element,
          durationMilliseconds: 0)
      }
    }
    // Like a disc release: a 45 s credits chapter and a two-second sliver at the very end.
    let own = chapters([0, 332_000, 1_386_000, 2_848_000, 2_891_000])
    let neighbour = chapters([0, 200_000, 2_846_000, 2_890_000])
    #expect(
      SkipSegmentLogic.closingChapter(
        own, duration: 2_893_000, neighbours: [(neighbour, 2_892_000)]) == 2_848_000)
    // A story chapter of a different length in the neighbour does not confirm it.
    let story = chapters([0, 200_000, 2_700_000])
    #expect(
      SkipSegmentLogic.closingChapter(own, duration: 2_893_000, neighbours: [(story, 2_892_000)])
        == nil)
    // Nor does a long final chapter count.
    let long = chapters([0, 2_400_000])
    #expect(
      SkipSegmentLogic.closingChapter(long, duration: 2_893_000, neighbours: [(long, 2_893_000)])
        == nil)
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
  @Test(.timeLimit(.minutes(1))) func keepsDrainingPastTheLimitSoTheWriterNeverBlocks() async throws
  {
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

  /// A pipe holds only a few kilobytes, so the reader must take data as soon as it arrives.
  /// Waiting between reads once limited analysis to playback speed.
  @Test(.timeLimit(.minutes(1))) func drainsFasterThanPlaybackOnABackgroundThread() async throws {
    let pipe = try SamplePipe(limit: 1_000)
    pipe.startReading()
    let path = pipe.path
    let start = ContinuousClock.now
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global(qos: .utility).async {
        let descriptor = open(path, O_WRONLY)
        var header = [UInt8](repeating: 0, count: 44)
        header.replaceSubrange(0..<4, with: Array("RIFF".utf8))
        header.replaceSubrange(8..<16, with: Array("WAVEfmt ".utf8))
        header[16] = 16
        header.replaceSubrange(36..<40, with: Array("data".utf8))
        _ = header.withUnsafeBytes { write(descriptor, $0.baseAddress, 44) }
        // 16 MB is about 87 seconds of 48 kHz stereo audio.
        let block = [UInt8](repeating: 1, count: 65_536)
        for _ in 0..<256 {
          _ = block.withUnsafeBytes { write(descriptor, $0.baseAddress, block.count) }
        }
        close(descriptor)
        continuation.resume()
      }
    }
    _ = await pipe.finish()
    pipe.close()
    #expect(ContinuousClock.now - start < .seconds(8))
  }

  @Test(.timeLimit(.minutes(1))) func endsWhenNoWriterEverConnects() async throws {
    let pipe = try SamplePipe(limit: 1_000)
    pipe.startReading()
    let samples = await pipe.finish()
    pipe.close()
    #expect(samples.isEmpty)
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
    // Mono at the fingerprint rate, and stereo at 48 kHz as in real films: VLC may hand either
    // through unchanged, and both must end up as the same mono 11 kHz samples.
    for (channels, rate) in [(1, 11_025), (2, 48_000)] {
      let url = directory.appendingPathComponent("synthetic-\(channels)-\(rate).wav")
      try Self.writeWAV(Self.upsample(samples, to: rate), channels: channels, rate: rate, to: url)
      let reader = VLCAudioSampleReader()
      let output = try await reader.read(url: url, start: 5, length: 30, timeout: .seconds(60))
      let seconds = Double(output.samples.count) / AudioFingerprint.sampleRate
      #expect(seconds > 28 && seconds < 32, "\(channels) channels at \(rate) Hz")
      #expect(output.durationMilliseconds > 40_000)
      // The theme decoded from the file matches the generated theme at 15 s into the read.
      let match = SegmentMatcher.longestCommon(
        AudioFingerprint.compute(output.samples),
        AudioFingerprint.compute(SyntheticAudio.theme(seconds: 15)), minimum: 8, maximum: 60)
      let found = try #require(match, "\(channels) channels at \(rate) Hz")
      #expect(abs(found.firstStart - 15) < 1)
    }
  }

  /// Real episodes are mostly Matroska files. With video and compressed sound, VLC's own
  /// Matroska reader ignored the start time, so the credits window held the opening. This
  /// synthetic file cannot carry video, but the reader now in use must still start each window
  /// where it was asked to.
  @Test func readsAMatroskaWindowFromWhereItWasAsked() async throws {
    var generator = SyntheticAudio(seed: 9)
    let samples =
      generator.noise(seconds: 40) + SyntheticAudio.theme(seconds: 15)
      + generator.noise(seconds: 20)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AureliaMatroskaTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("synthetic.mkv")
    try Self.writeMatroska(Self.upsample(samples, to: 48_000), rate: 48_000, to: file)

    let reader = VLCAudioSampleReader()
    let started = Date()
    let output = try await reader.read(url: file, start: 30, length: 30, timeout: .seconds(60))
    let seconds = Double(output.samples.count) / AudioFingerprint.sampleRate
    #expect(seconds > 28 && seconds < 32)
    #expect(Date().timeIntervalSince(started) < 15, "decoding must be faster than real time")
    let match = SegmentMatcher.longestCommon(
      AudioFingerprint.compute(output.samples),
      AudioFingerprint.compute(SyntheticAudio.theme(seconds: 15)), minimum: 8, maximum: 60)
    let found = try #require(match)
    #expect(abs(found.firstStart - 10) < 1)
  }

  /// A minimal Matroska file: 16-bit stereo PCM in one-second clusters with a cue index.
  private static func writeMatroska(_ samples: [Float], rate: Int, to url: URL) throws {
    func element(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] {
      // An eight-byte size keeps every element's length predictable.
      let size = UInt64(payload.count)
      return id + [0x01] + (0..<7).reversed().map { UInt8(truncatingIfNeeded: size >> (8 * $0)) }
        + payload
    }
    func unsigned(_ id: [UInt8], _ value: UInt64) -> [UInt8] {
      element(id, (0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }
    func float(_ id: [UInt8], _ value: Double) -> [UInt8] {
      unsigned(id, value.bitPattern)
    }
    func text(_ id: [UInt8], _ value: String) -> [UInt8] { element(id, Array(value.utf8)) }

    let header = element(
      [0x1A, 0x45, 0xDF, 0xA3],
      unsigned([0x42, 0x86], 1) + unsigned([0x42, 0xF7], 1) + unsigned([0x42, 0xF2], 4)
        + unsigned([0x42, 0xF3], 8) + text([0x42, 0x82], "matroska")
        + unsigned([0x42, 0x87], 4) + unsigned([0x42, 0x85], 2))
    let durationMilliseconds = Double(samples.count) / Double(rate) * 1_000
    let info = element(
      [0x15, 0x49, 0xA9, 0x66],
      unsigned([0x2A, 0xD7, 0xB1], 1_000_000) + float([0x44, 0x89], durationMilliseconds)
        + text([0x4D, 0x80], "AureliaTests") + text([0x57, 0x41], "AureliaTests"))
    let tracks = element(
      [0x16, 0x54, 0xAE, 0x6B],
      element(
        [0xAE],
        unsigned([0xD7], 1) + unsigned([0x73, 0xC5], 1) + unsigned([0x83], 2)
          + text([0x86], "A_PCM/INT/LIT")
          + element(
            [0xE1],
            float([0xB5], Double(rate)) + unsigned([0x9F], 2) + unsigned([0x62, 0x64], 16))))
    var clusters: [[UInt8]] = []
    let block = rate / 10
    for second in 0..<((samples.count + rate - 1) / rate) {
      var payload = unsigned([0xE7], UInt64(second * 1_000))
      for part in 0..<10 {
        let low = second * rate + part * block
        guard low < samples.count else { break }
        var bytes: [UInt8] = [0x81, UInt8(part * 100 >> 8), UInt8(part * 100 & 0xFF), 0x80]
        for sample in samples[low..<min(samples.count, low + block)] {
          let value = UInt16(bitPattern: Int16(max(-1, min(1, sample)) * 32_767))
          let pair = [UInt8(value & 0xFF), UInt8(value >> 8)]
          bytes += pair + pair
        }
        payload += element([0xA3], bytes)
      }
      clusters.append(element([0x1F, 0x43, 0xB6, 0x75], payload))
    }
    func cues(_ positions: [UInt64]) -> [UInt8] {
      element(
        [0x1C, 0x53, 0xBB, 0x6B],
        positions.enumerated().flatMap { index, position in
          element(
            [0xBB],
            unsigned([0xB3], UInt64(index * 1_000))
              + element([0xB7], unsigned([0xF7], 1) + unsigned([0xF1], position)))
        })
    }
    // Cue positions count from the start of the segment's content.
    var position = UInt64(info.count + tracks.count + cues(clusters.map { _ in 0 }).count)
    var positions: [UInt64] = []
    for cluster in clusters {
      positions.append(position)
      position += UInt64(cluster.count)
    }
    let segment = element(
      [0x18, 0x53, 0x80, 0x67], info + tracks + cues(positions) + clusters.flatMap { $0 })
    try Data(header + segment).write(to: url)
  }

  /// Linear interpolation from the fingerprint rate to `rate`.
  private static func upsample(_ samples: [Float], to rate: Int) -> [Float] {
    guard rate != Int(AudioFingerprint.sampleRate) else { return samples }
    let ratio = AudioFingerprint.sampleRate / Double(rate)
    let count = Int(Double(samples.count) / ratio)
    return (0..<count).map { index in
      let position = Double(index) * ratio
      let low = min(Int(position), samples.count - 1)
      let high = min(low + 1, samples.count - 1)
      let fraction = Float(position - Double(low))
      return samples[low] * (1 - fraction) + samples[high] * fraction
    }
  }

  private static func writeWAV(_ samples: [Float], channels: Int, rate: Int, to url: URL) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    let byteCount = UInt32(samples.count * 2 * channels)
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36) + byteCount)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(channels))
    append(UInt32(rate))
    append(UInt32(rate * 2 * channels))
    append(UInt16(2 * channels))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(byteCount)
    for sample in samples {
      for _ in 0..<channels { append(Int16(max(-1, min(1, sample)) * 32_767)) }
    }
    try data.write(to: url)
  }
}
