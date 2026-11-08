import AVFoundation
import Foundation
import Speech

/// One recognized word and when it is spoken, in seconds from the start of the title.
struct SpeechWord: Equatable, Sendable {
  let text: String
  let start: Double
  let end: Double
}

/// One subtitle on screen: one or two lines from `start` to `end` seconds.
struct SubtitleCue: Equatable, Sendable {
  let start: Double
  let end: Double
  let lines: [String]
}

/// Turns recognized words into subtitles that read like written ones: at most two lines of 42
/// characters, a new subtitle after a sentence or a pause, none longer than about six seconds,
/// each on screen long enough to read and never over the next one.
enum SubtitleCueBuilder {
  static let lineLength = 42
  static let longestCue = 6.0
  static let shortestCue = 1.0
  static let pauseBreak = 0.8
  static let lingering = 0.4

  static func cues(from words: [SpeechWord]) -> [SubtitleCue] {
    var groups: [[SpeechWord]] = []
    var current: [SpeechWord] = []
    func characters(_ words: [SpeechWord]) -> Int {
      words.reduce(0) { $0 + $1.text.count } + max(0, words.count - 1)
    }
    for word in words.map(clean).compactMap({ $0 }) {
      if let last = current.last, let first = current.first {
        let pause = word.start - last.end
        let tooLong = word.end - first.start > longestCue
        let tooWide = characters(current + [word]) > lineLength * 2
        // A comma is a good place to break a subtitle that is already long.
        let longClause = last.text.hasSuffix(",") && characters(current) > lineLength
        if pause >= pauseBreak || tooLong || tooWide || endsSentence(last.text) || longClause {
          groups.append(current)
          current = []
        }
      }
      current.append(word)
    }
    if !current.isEmpty { groups.append(current) }

    var cues: [SubtitleCue] = []
    for (index, group) in groups.enumerated() {
      guard let first = group.first, let last = group.last else { continue }
      let next = index + 1 < groups.count ? groups[index + 1].first?.start : nil
      let limit = next.map { $0 - 0.05 } ?? .infinity
      var end = min(last.end + lingering, limit)
      if end - first.start < shortestCue { end = min(first.start + shortestCue, limit) }
      end = max(end, last.end)
      cues.append(
        SubtitleCue(start: first.start, end: end, lines: lines(group.map(\.text).joined(separator: " "))))
    }
    return cues
  }

  /// Splits a subtitle into two lines near its middle when it doesn't fit on one, preferring the
  /// space after a comma.
  static func lines(_ text: String) -> [String] {
    guard text.count > lineLength else { return [text] }
    let characters = Array(text)
    let middle = characters.count / 2
    let spaces = characters.indices.filter { characters[$0] == " " }
    guard !spaces.isEmpty else { return [text] }
    let best = spaces.min { left, right in
      score(left, middle: middle, after: characters) < score(right, middle: middle, after: characters)
    }!
    return [
      String(characters[..<best]).trimmingCharacters(in: .whitespaces),
      String(characters[(best + 1)...]).trimmingCharacters(in: .whitespaces),
    ]
  }

  private static func score(_ space: Int, middle: Int, after characters: [Character]) -> Int {
    let distance = abs(space - middle)
    let afterPunctuation = space > 0 && ",;:".contains(characters[space - 1])
    return afterPunctuation ? distance - 8 : distance
  }

  static func endsSentence(_ text: String) -> Bool {
    guard let last = text.last else { return false }
    return ".?!…".contains(last)
  }

  private static func clean(_ word: SpeechWord) -> SpeechWord? {
    let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, word.end >= word.start, word.start.isFinite, word.end.isFinite else {
      return nil
    }
    return SpeechWord(text: text, start: max(0, word.start), end: word.end)
  }

  /// SubRip text, the format the server keeps.
  static func subRip(_ cues: [SubtitleCue]) -> String {
    cues.enumerated().map { index, cue in
      "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.lines.joined(separator: "\n"))\n"
    }.joined(separator: "\n")
  }

  static func timestamp(_ seconds: Double) -> String {
    let total = Int((max(0, seconds) * 1000).rounded())
    let hours = total / 3_600_000
    let minutes = total / 60_000 % 60
    let secs = total / 1000 % 60
    let millis = total % 1000
    return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
  }
}

/// The languages speech can be written in on this Mac, and the one a sound track is in.
enum SpeechLanguages {
  /// A sound track's language tag ("ger", "deu", "en") as a two-letter code.
  static func code(forTrack tag: String?) -> String? {
    guard let tag = tag?.lowercased(), !tag.isEmpty, tag != "und" else { return nil }
    if tag.count == 2 { return tag }
    let known: [String: String] = [
      "eng": "en", "ger": "de", "deu": "de", "fre": "fr", "fra": "fr", "spa": "es", "ita": "it",
      "dut": "nl", "nld": "nl", "por": "pt", "swe": "sv", "dan": "da", "nor": "no", "nob": "no",
      "fin": "fi", "pol": "pl", "cze": "cs", "ces": "cs", "tur": "tr", "rus": "ru", "jpn": "ja",
      "kor": "ko", "chi": "zh", "zho": "zh", "ara": "ar", "hin": "hi", "ukr": "uk", "gre": "el",
      "ell": "el", "hun": "hu", "rum": "ro", "ron": "ro",
    ]
    return known[tag] ?? Locale.LanguageCode(tag).identifier(.alpha2)
  }

  /// The best of the supported locales for a language: this Mac's own region first.
  static func locale(for code: String, among supported: [Locale], region: String? = Locale.current
    .region?.identifier) -> Locale?
  {
    let matching = supported.filter { $0.language.languageCode?.identifier == code }
    if let region, let local = matching.first(where: { $0.region?.identifier == region }) {
      return local
    }
    let usual = ["en": "US", "de": "DE", "fr": "FR", "es": "ES", "pt": "BR", "it": "IT", "nl": "NL"]
    if let usualRegion = usual[code],
      let common = matching.first(where: { $0.region?.identifier == usualRegion })
    {
      return common
    }
    return matching.first
  }

  /// One entry per language, by its English name.
  static func choices(_ supported: [Locale]) -> [String] {
    Array(Set(supported.compactMap { $0.language.languageCode?.identifier }))
      .sorted { SubtitleLanguages.name($0) < SubtitleLanguages.name($1) }
  }
}

/// Where words really start. The recognizer counts the silence before a word as part of it, so
/// after a pause a word seems to start when the previous one ended. The loudness of the sound,
/// measured every 20 ms while it is read, shows where speaking starts again.
enum SpeechTiming {
  static let frame = 0.02

  /// Moves the start of each word that begins with a quiet stretch to where it gets loud.
  static func trimmingSilence(_ words: [SpeechWord], levels: [Float]) -> [SpeechWord] {
    guard levels.count > 50 else { return words }
    let sorted = levels.sorted()
    // The quiet parts of the title: its tenth-quietest frames.
    let floor = sorted[sorted.count / 10]
    let loud = sorted[sorted.count * 9 / 10]
    let threshold = max(floor * 4, floor + (loud - floor) * 0.12, 1e-4)
    return words.map { word in
      guard word.end - word.start > 0.3 else { return word }
      let first = max(0, Int(word.start / frame))
      let last = min(levels.count, Int(word.end / frame))
      guard first < last, levels[first] < threshold,
        let loudFrame = (first..<last).first(where: { levels[$0] >= threshold })
      else { return word }
      let start = min(Double(loudFrame) * frame, word.end - 0.1)
      return start > word.start ? SpeechWord(text: word.text, start: start, end: word.end) : word
    }
  }
}

/// Writes subtitles from 16 kHz mono speech with the Mac's own speech recognition. Everything
/// happens on this Mac; the sound is never stored.
enum SpeechRecognizer {
  static var isAvailable: Bool { SpeechTranscriber.isAvailable }

  static func supportedLocales() async -> [Locale] { await SpeechTranscriber.supportedLocales }

  /// The words spoken in `audio` (little-endian 16-bit PCM at 16 kHz, one channel).
  /// `listened` reports how many seconds of sound have been read.
  static func words(
    locale: Locale, audio: AsyncThrowingStream<Data, Error>,
    listened: @escaping @Sendable (Double) -> Void,
    consumed: @escaping @Sendable (Int) -> Void = { _ in },
    preparing: @escaping @Sendable () -> Void = {}
  ) async throws -> [SpeechWord] {
    let transcriber = SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [],
      attributeOptions: [.audioTimeRange])
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      // The language's speech model is loaded once from Apple and then stays on this Mac.
      preparing()
      try await request.downloadAndInstall()
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let source = AVAudioFormat(
      commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let target =
      await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? source
    let converter = target == source ? nil : AVAudioConverter(from: source, to: target)
    let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()

    let collector = Task {
      var words: [SpeechWord] = []
      for try await result in transcriber.results {
        for run in result.text.runs {
          guard let range = run.audioTimeRange else { continue }
          let text = String(result.text[run.range].characters)
          words.append(SpeechWord(text: text, start: range.start.seconds, end: range.end.seconds))
        }
      }
      return words
    }
    do {
      try await analyzer.start(inputSequence: input)
      var carry = Data()
      var samples: Int64 = 0
      var meter = LoudnessMeter()
      for try await chunk in audio {
        try Task.checkCancellation()
        consumed(chunk.count)
        carry.append(chunk)
        let usable = carry.count - carry.count % 2
        guard usable > 0 else { continue }
        let bytes = carry.prefix(usable)
        carry.removeFirst(usable)
        guard let buffer = pcmBuffer(bytes, format: source) else { continue }
        meter.add(buffer)
        samples += Int64(buffer.frameLength)
        feed.yield(AnalyzerInput(buffer: try convert(buffer, with: converter, to: target)))
        listened(Double(samples) / 16_000)
      }
      feed.finish()
      // With no sound at all there is nothing to finish; the analyzer would wait for it.
      guard samples > 0 else { throw SpeechSubtitleError.nothingHeard }
      try await analyzer.finalizeAndFinishThroughEndOfInput()
      return SpeechTiming.trimmingSilence(try await collector.value, levels: meter.levels)
    } catch {
      feed.finish()
      await analyzer.cancelAndFinishNow()
      collector.cancel()
      throw error
    }
  }

  /// The loudness of every 20 ms of sound (root mean square, 0…1).
  private struct LoudnessMeter {
    private(set) var levels: [Float] = []
    private var sum: Float = 0
    private var count = 0

    mutating func add(_ buffer: AVAudioPCMBuffer) {
      guard let channel = buffer.int16ChannelData?[0] else { return }
      for index in 0..<Int(buffer.frameLength) {
        let value = Float(channel[index]) / 32_768
        sum += value * value
        count += 1
        if count == 320 {
          levels.append((sum / 320).squareRoot())
          sum = 0
          count = 0
        }
      }
    }
  }

  private static func pcmBuffer(_ bytes: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let frames = AVAudioFrameCount(bytes.count / 2)
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
      let channel = buffer.int16ChannelData
    else { return nil }
    buffer.frameLength = frames
    bytes.withUnsafeBytes { raw in
      let samples = raw.bindMemory(to: Int16.self)
      for index in 0..<Int(frames) { channel[0][index] = Int16(littleEndian: samples[index]) }
    }
    return buffer
  }

  private static func convert(
    _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?, to format: AVAudioFormat
  ) throws -> AVAudioPCMBuffer {
    guard let converter else { return buffer }
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      throw SpeechSubtitleError.audioUnreadable
    }
    nonisolated(unsafe) var delivered = false
    var failure: NSError?
    converter.convert(to: output, error: &failure) { _, status in
      if delivered {
        status.pointee = .noDataNow
        return nil
      }
      delivered = true
      status.pointee = .haveData
      return buffer
    }
    if let failure { throw failure }
    return output
  }
}

enum SpeechSubtitleError: LocalizedError, Equatable {
  case unavailable
  case languageUnavailable(String)
  case audioUnreadable
  case nothingHeard
  case tooFewSubtitles
  case noMatch

  var errorDescription: String? {
    switch self {
    case .unavailable: "This Mac can’t recognize speech."
    case .languageUnavailable(let code):
      "This Mac can’t recognize \(SubtitleLanguages.name(code))."
    case .audioUnreadable: "The sound track couldn’t be read."
    case .nothingHeard: "No speech was found in this sound track."
    case .tooFewSubtitles: "These subtitles have too few lines to sync."
    case .noMatch:
      "These subtitles don’t fit this sound track at any offset. They may be for another version of the film, or the spoken language is set wrong. Nothing was changed."
    }
  }
}
