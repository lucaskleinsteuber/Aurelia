@preconcurrency import Foundation
@preconcurrency import VLCKit

/// Decodes a stretch of a title's soundtrack to mono samples with VLC, as fast as the Mac can
/// decode. VLC writes the samples into a pipe that this process reads at once; a pipe is only a
/// small kernel buffer, so no audio is ever stored on disk. The samples are dropped once their
/// fingerprint has been computed.
@MainActor
final class VLCAudioSampleReader: NSObject {
  struct Output: Sendable {
    let samples: [Float]
    let durationMilliseconds: Int64
    let chapters: [PlaybackChapter]
    /// The layout VLC delivered, for diagnostics.
    let sourceLayout: String
  }

  enum ReadError: Error, LocalizedError {
    case failed
    case timedOut

    var errorDescription: String? {
      switch self {
      case .failed: "The soundtrack could not be read."
      case .timedOut: "Reading the soundtrack took too long."
      }
    }
  }

  private var player: VLCMediaPlayer?
  private var continuation: CheckedContinuation<Void, Error>?
  private var durationMilliseconds: Int64 = 0
  private var chapters: [PlaybackChapter] = []

  /// Reads `length` seconds starting at `start`. VLC stops on its own at the end of the stretch.
  func read(url: URL, start: Double, length: Double, timeout: Duration = .seconds(240))
    async throws -> Output
  {
    precondition(player == nil, "One read at a time")
    let media = VLCMedia(url: url)
    durationMilliseconds = 0
    chapters = []
    let pipe = try SamplePipe(
      limit: Int(length * AudioFingerprint.sampleRate) + Int(AudioFingerprint.sampleRate))
    defer { pipe.close() }
    pipe.startReading()

    let rate = Int(AudioFingerprint.sampleRate)
    media.addOption(
      ":sout=#transcode{acodec=s16l,channels=1,samplerate=\(rate)}"
        + ":std{access=file,mux=wav,dst=\"\(pipe.path)\"}")
    // VLC's own Matroska reader ignores the start time and decodes from the beginning, so the
    // credits window would hold the opening instead. FFmpeg's reader seeks reliably.
    media.addOption(":demux=avformat")
    media.addOption(":no-sout-video")
    media.addOption(":no-sout-spu")
    media.addOption(String(format: ":start-time=%.3f", max(0, start)))
    media.addOption(String(format: ":stop-time=%.3f", max(0, start) + length))
    let player = VLCMediaPlayer(options: [
      "--no-video", "--no-play-and-pause", "--quiet", "--no-stats",
    ])
    player.delegate = self
    player.media = media
    self.player = player

    let timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      self?.finish(.failure(ReadError.timedOut))
    }
    defer { timeoutTask.cancel() }
    do {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          self.continuation = continuation
          player.play()
        }
      } onCancel: {
        Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
      }
    } catch {
      await stopPlayer()
      throw error
    }
    await stopPlayer()
    // VLC has closed its end of the pipe; collect what remains in the buffer.
    let samples = await pipe.finish()
    return Output(
      samples: samples, durationMilliseconds: durationMilliseconds, chapters: chapters,
      sourceLayout: pipe.layoutDescription)
  }

  private func finish(_ result: Result<Void, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    captureMediaFacts()
    continuation.resume(with: result)
  }

  /// Stops VLC away from the main thread; stopping waits for VLC's own threads to finish.
  private func stopPlayer() async {
    guard let player else { return }
    self.player = nil
    player.delegate = nil
    let box = UncheckedPlayer(value: player)
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        box.value.stop()
        continuation.resume()
      }
    }
  }

  private func captureMediaFacts() {
    guard let player else { return }
    if let length = player.media?.length.value?.int64Value, length > 0 {
      durationMilliseconds = length
    }
    let titleIndex = player.currentTitleIndex
    guard chapters.isEmpty, titleIndex >= 0 else { return }
    chapters = player.chapterDescriptions(ofTitle: titleIndex).enumerated().compactMap {
      offset, raw in
      guard let values = raw as? [AnyHashable: Any] else { return nil }
      return PlaybackChapter(
        index: Int32(offset),
        title: (values[VLCChapterDescriptionName] as? String) ?? "",
        timeOffsetMilliseconds: Self.milliseconds(values[VLCChapterDescriptionTimeOffset]),
        durationMilliseconds: Self.milliseconds(values[VLCChapterDescriptionDuration]))
    }
  }

  private static func milliseconds(_ value: Any?) -> Int64 {
    if let value = value as? NSNumber { return max(0, value.int64Value) }
    if let value = value as? VLCTime { return max(0, value.value?.int64Value ?? 0) }
    return 0
  }

  fileprivate func stateChanged(_ state: VLCMediaPlayerState) {
    switch state {
    case .playing, .esAdded, .buffering:
      captureMediaFacts()
    case .ended, .stopped, .paused:
      finish(.success(()))
    case .error:
      finish(.failure(ReadError.failed))
    default:
      break
    }
  }
}

extension VLCAudioSampleReader: VLCMediaPlayerDelegate {
  nonisolated func mediaPlayerStateChanged(_ notification: Notification) {
    guard let player = notification.object as? VLCMediaPlayer else { return }
    let state = player.state
    Task { @MainActor [weak self] in self?.stateChanged(state) }
  }
}

private struct UncheckedPlayer: @unchecked Sendable { let value: VLCMediaPlayer }

/// A private named pipe that VLC writes a WAV stream into. A background thread turns the 16-bit
/// mono samples into floats as they arrive. The pipe stores nothing; it is removed afterwards.
final class SamplePipe: @unchecked Sendable {
  let path: String
  private let directory: URL
  private let limit: Int
  private let lock = NSLock()
  private var samples: [Float] = []
  /// The stream's real layout. VLC does not always downmix or resample as asked, so every
  /// stream is converted here to mono at the fingerprint rate.
  private var format = WAVFormat(
    channels: 1, sampleRate: Int(AudioFingerprint.sampleRate), bits: 16)
  private var phase = 0
  private var accumulated: Float = 0
  private var accumulatedCount = 0
  private var finished = false
  private var closed = false
  private var started = false
  private var descriptor: Int32 = -1
  private let done = DispatchSemaphore(value: 0)

  init(limit: Int) throws {
    self.limit = limit
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("Aurelia-Segments-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    path = directory.appendingPathComponent("audio.wav").path
    guard mkfifo(path, 0o600) == 0 else {
      try? FileManager.default.removeItem(at: directory)
      throw VLCAudioSampleReader.ReadError.failed
    }
    // A non-blocking open returns at once; reads switch to blocking once VLC has connected.
    descriptor = open(path, O_RDONLY | O_NONBLOCK)
    guard descriptor >= 0 else {
      try? FileManager.default.removeItem(at: directory)
      throw VLCAudioSampleReader.ReadError.failed
    }
  }

  var layoutDescription: String {
    lock.withLock { "\(format.channels) ch, \(format.sampleRate) Hz, \(format.bits) bit" }
  }

  func startReading() {
    started = true
    let thread = Thread { [self] in readLoop() }
    thread.qualityOfService = .utility
    thread.start()
  }

  /// Stops after draining what VLC has written and returns the samples.
  func finish() async -> [Float] {
    lock.withLock { finished = true }
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async { [self] in
        waitForReader()
        continuation.resume()
      }
    }
    return lock.withLock { samples }
  }

  /// Ends the reading thread first, then removes the pipe.
  func close() {
    lock.withLock {
      finished = true
      closed = true
    }
    if started {
      waitForReader()
    } else if descriptor >= 0 {
      Darwin.close(descriptor)
      descriptor = -1
    }
    try? FileManager.default.removeItem(at: directory)
  }

  /// The reader ends when VLC closes its end. Should VLC keep it open, the wait is bounded and
  /// the thread closes the pipe itself once it ends.
  private func waitForReader() {
    // Leave the signal for the next caller, which waits for the thread as well.
    if done.wait(timeout: .now() + .seconds(10)) == .success { done.signal() }
  }

  private func readLoop() {
    defer {
      Darwin.close(descriptor)
      done.signal()
    }
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    var pending: [UInt8] = []
    var headerParsed = false
    var connected = false
    var idleAfterFinish = 0
    while true {
      if lock.withLock({ closed }) { return }
      let count = read(descriptor, &buffer, buffer.count)
      if count > 0 {
        if !connected {
          // From VLC's first bytes on, wait inside read(). Short sleeps between non-blocking
          // reads are stretched by macOS on background threads, which limited VLC to playback
          // speed because a pipe holds only a few kilobytes.
          connected = true
          _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
        }
        pending.append(contentsOf: buffer[0..<count])
        if !headerParsed, let header = Self.header(in: pending) {
          pending.removeFirst(header.dataOffset)
          format = header.format
          headerParsed = true
        }
        // Even with enough samples the pipe keeps being drained: VLC must never block on a
        // full pipe, or stopping it would wait forever.
        if headerParsed { consume(&pending) }
        continue
      }
      // Once connected, an empty read means VLC has closed its end.
      if count == 0, connected { return }
      if count < 0, errno == EINTR { continue }
      if count < 0, errno != EAGAIN { return }
      // VLC has not connected or written yet.
      if lock.withLock({ finished }) {
        idleAfterFinish += 1
        if idleAfterFinish >= 100 { return }
      }
      usleep(2_000)
    }
  }

  private func consume(_ pending: inout [UInt8]) {
    let bytesPerSample = max(1, format.bits / 8)
    let frameBytes = bytesPerSample * max(1, format.channels)
    let frames = pending.count / frameBytes
    guard frames > 0 else { return }
    let target = Int(AudioFingerprint.sampleRate)
    let source = max(1, format.sampleRate)
    lock.lock()
    pending.withUnsafeBufferPointer { bytes in
      for frame in 0..<frames {
        guard samples.count < limit else { break }
        var sum: Float = 0
        for channel in 0..<format.channels {
          let offset = frame * frameBytes + channel * bytesPerSample
          sum += Self.sample(bytes, at: offset, bits: format.bits)
        }
        // Box-filter resampling: average the source frames that fall into each output sample.
        accumulated += sum / Float(max(1, format.channels))
        accumulatedCount += 1
        phase += target
        if phase >= source {
          phase -= source
          samples.append(accumulated / Float(accumulatedCount))
          accumulated = 0
          accumulatedCount = 0
        }
      }
    }
    lock.unlock()
    pending.removeFirst(frames * frameBytes)
  }

  private static func sample(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int, bits: Int)
    -> Float
  {
    switch bits {
    case 32:
      let raw =
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
        | UInt32(bytes[offset + 3]) << 24
      return Float(bitPattern: raw)
    case 24:
      let raw =
        Int32(bytes[offset]) << 8 | Int32(bytes[offset + 1]) << 16 | Int32(bytes[offset + 2]) << 24
      return Float(raw >> 8) / 8_388_608
    default:
      let raw = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
      return Float(raw) / 32_768
    }
  }

  struct WAVFormat: Equatable {
    let channels: Int
    let sampleRate: Int
    let bits: Int
  }

  /// The stream layout and the byte offset after the "data" chunk header.
  static func header(in bytes: [UInt8]) -> (format: WAVFormat, dataOffset: Int)? {
    guard bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8) else { return nil }
    func value(_ at: Int, _ length: Int) -> Int {
      (0..<length).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) }
    }
    var format = WAVFormat(channels: 1, sampleRate: Int(AudioFingerprint.sampleRate), bits: 16)
    var offset = 12
    while offset + 8 <= bytes.count {
      let size = value(offset + 4, 4)
      if bytes[offset..<offset + 4].elementsEqual("data".utf8) { return (format, offset + 8) }
      if bytes[offset..<offset + 4].elementsEqual("fmt ".utf8) {
        guard offset + 8 + 16 <= bytes.count else { return nil }
        let channels = value(offset + 10, 2)
        let rate = value(offset + 12, 4)
        let bits = value(offset + 22, 2)
        if (1...16).contains(channels), (4_000...384_000).contains(rate),
          [16, 24, 32].contains(bits)
        {
          format = WAVFormat(channels: channels, sampleRate: rate, bits: bits)
        }
      }
      offset += 8 + size + (size & 1)
    }
    return nil
  }

}
