import Accelerate
import Foundation

/// A stretch of time in seconds.
struct TimeSpan: Equatable, Sendable {
  let start: Double
  let end: Double
}

/// How subtitles are moved to fit the speech: `corrected = original × scale + offset`.
struct SubtitleShift: Equatable, Sendable {
  let offset: Double
  let scale: Double

  func apply(_ seconds: Double) -> Double { max(0, seconds * scale + offset) }
  static let none = SubtitleShift(offset: 0, scale: 1)
}

/// Where a different cut of the film starts: from `from` (original subtitle time) on, `offset`.
struct SubtitleSegment: Equatable, Sendable {
  let from: Double
  let offset: Double
}

/// The shift of a whole film, in parts when the subtitles were made for another cut.
struct SubtitleTiming: Equatable, Sendable {
  let scale: Double
  /// Sorted by `from`; the first starts at zero.
  let segments: [SubtitleSegment]

  init(_ shift: SubtitleShift) {
    scale = shift.scale
    segments = [SubtitleSegment(from: 0, offset: shift.offset)]
  }

  init(scale: Double, segments: [SubtitleSegment]) {
    self.scale = scale
    self.segments = segments
  }

  func shift(at seconds: Double) -> SubtitleShift {
    let segment = segments.last { $0.from <= seconds } ?? segments[0]
    return SubtitleShift(offset: segment.offset, scale: scale)
  }

  func apply(_ seconds: Double) -> Double { shift(at: seconds).apply(seconds) }

  /// Moves cues and drops what a part's new place would put over the part before it.
  func apply(_ cues: [SubtitleCue]) -> [SubtitleCue] {
    var moved: [SubtitleCue] = []
    for cue in cues {
      let shift = shift(at: cue.start)
      var start = shift.apply(cue.start)
      let end = shift.apply(cue.end)
      if let last = moved.last { start = max(start, last.end + 0.05) }
      guard end - start >= 0.3 else { continue }
      moved.append(SubtitleCue(start: start, end: end, lines: cue.lines))
    }
    return moved
  }
}

/// What syncing found.
struct SubtitleSyncResult: Equatable, Sendable {
  enum Verdict: Equatable, Sendable {
    /// The subtitles fit better after the shift.
    case shifted
    /// They already fit; nothing needs to change.
    case alreadyInSync
    /// No shift makes them fit: probably subtitles for another version or language track.
    case noMatch
  }
  let verdict: Verdict
  let timing: SubtitleTiming
  /// Share of subtitle time that lies on speech, before and after (0…1).
  let fitBefore: Double
  let fitAfter: Double
  /// Share of the film's parts that still don't fit after the shift, for example after a cut.
  let poorParts: Double
}

/// Finds the shift that lays subtitles over the speech of a sound track. It compares where
/// people speak (from the speech recognizer's word times) with where subtitles are shown, for
/// every offset up to ten minutes at once, and for the frame-rate mix-ups between 23.976, 24 and
/// 25 frames per second. It changes nothing unless the result fits clearly better.
enum SubtitleSync {
  /// Time resolution of the comparison: 20 ms.
  static let step = 0.02
  static let longestOffset = 600.0
  static let scales: [Double] = [
    1, 25 / 23.976, 23.976 / 25, 24 / 23.976, 23.976 / 24, 25 / 24, 24 / 25,
  ]
  /// Decisions use the agreement between speech and subtitles: the correlation of "someone
  /// speaks" with "a subtitle shows" over the film (-1…1). Unlike the share of subtitles on
  /// speech it does not depend on how much is spoken, so dense dialogue syncs as well.
  /// A shift must raise it by this much to be worth applying.
  static let worthwhile = 0.08
  /// Below this the subtitles are taken not to belong to this sound track.
  static let plausible = 0.3

  /// The speech of a sound track: words that are close together become one stretch.
  static func speech(from words: [SpeechWord], joining gap: Double = 0.35) -> [TimeSpan] {
    var spans: [TimeSpan] = []
    for word in words.sorted(by: { $0.start < $1.start }) where word.end > word.start {
      if let last = spans.last, word.start - last.end <= gap {
        spans[spans.count - 1] = TimeSpan(start: last.start, end: max(last.end, word.end))
      } else {
        spans.append(TimeSpan(start: word.start, end: word.end))
      }
    }
    return spans
  }

  static func find(speech: [TimeSpan], cues: [TimeSpan]) -> SubtitleSyncResult {
    let usable = cues.filter { $0.end > $0.start && $0.start >= 0 }
    guard !speech.isEmpty, !usable.isEmpty else {
      return SubtitleSyncResult(
        verdict: .noMatch, timing: SubtitleTiming(.none), fitBefore: 0, fitAfter: 0, poorParts: 1)
    }
    let before = score(speech: speech, cues: usable, shift: .none)
    var best = (shift: SubtitleShift.none, fit: before)
    for scale in scales {
      guard let found = bestOffset(speech: speech, cues: usable, scale: scale) else { continue }
      // A frame-rate change has to earn its place over keeping the speed.
      let bonus = scale == 1 ? 0.01 : 0
      if found.fit + bonus > best.fit + (best.shift.scale == 1 ? 0.01 : 0) {
        best = found
      }
    }
    // Refine to the exact best offset around the coarse one.
    best = refine(speech: speech, cues: usable, around: best.shift)
    var timing = SubtitleTiming(best.shift)
    var after = best.fit
    // Subtitles for another cut fit in parts only; each part then gets its own offset.
    if poorParts(speech: speech, cues: usable, timing: timing) > 0.1,
      let parted = segments(speech: speech, cues: usable, around: best.shift),
      parted.fit >= after + worthwhile
    {
      timing = parted.timing
      after = parted.fit
    }
    timing = alignStarts(speech: speech, cues: usable, timing: timing)
    after = score(speech: speech, cues: usable, timing: timing)
    let poor = poorParts(speech: speech, cues: usable, timing: timing)
    // What is shown: the share of subtitle time on speech, before and after.
    let shareBefore = fit(speech: speech, cues: usable, shift: .none)
    if after < plausible {
      return SubtitleSyncResult(
        verdict: .noMatch, timing: SubtitleTiming(.none), fitBefore: shareBefore,
        fitAfter: shareBefore, poorParts: poor)
    }
    let moved = timing.segments.count > 1 || abs(timing.segments[0].offset) >= 0.1
      || timing.scale != 1
    if !moved || after - before < worthwhile {
      return SubtitleSyncResult(
        verdict: .alreadyInSync, timing: SubtitleTiming(.none), fitBefore: shareBefore,
        fitAfter: shareBefore,
        poorParts: poorParts(speech: speech, cues: usable, timing: SubtitleTiming(.none)))
    }
    return SubtitleSyncResult(
      verdict: .shifted, timing: timing, fitBefore: shareBefore,
      fitAfter: fit(speech: speech, cues: usable, timing: timing), poorParts: poor)
  }

  /// Subtitles appear when a sentence starts. The last fine step moves each part so that the
  /// typical subtitle start lies where speech starts after a pause: the median of the nearest
  /// distances, at most half a second, and only when enough subtitles have a start nearby.
  static func alignStarts(speech: [TimeSpan], cues: [TimeSpan], timing: SubtitleTiming)
    -> SubtitleTiming
  {
    let onsets = speech.map(\.start)
    guard !onsets.isEmpty else { return timing }
    var segments: [SubtitleSegment] = []
    for (index, segment) in timing.segments.enumerated() {
      let until = index + 1 < timing.segments.count ? timing.segments[index + 1].from : .infinity
      let shift = SubtitleShift(offset: segment.offset, scale: timing.scale)
      var distances: [Double] = []
      var members = 0
      for cue in cues where cue.start >= segment.from && cue.start < until {
        members += 1
        let start = shift.apply(cue.start)
        // The nearest onset by binary search.
        var low = 0
        var high = onsets.count
        while low < high {
          let middle = (low + high) / 2
          if onsets[middle] < start { low = middle + 1 } else { high = middle }
        }
        let near = [low - 1, low].filter { onsets.indices.contains($0) }
          .map { onsets[$0] - start }.min { abs($0) < abs($1) }
        if let near, abs(near) <= 0.75 { distances.append(near) }
      }
      var offset = segment.offset
      if members > 0, distances.count >= max(5, members * 3 / 10) {
        let median = distances.sorted()[distances.count / 2]
        if abs(median) <= 0.5 { offset += median }
      }
      segments.append(SubtitleSegment(from: segment.from, offset: offset))
    }
    let aligned = SubtitleTiming(scale: timing.scale, segments: segments)
    // Kept only when it doesn't make the agreement clearly worse.
    return score(speech: speech, cues: cues, timing: aligned)
      >= score(speech: speech, cues: cues, timing: timing) - 0.02 ? aligned : timing
  }

  /// Ten-minute parts by original subtitle time, each with at least ten subtitles.
  private static func parts(_ cues: [TimeSpan]) -> [[TimeSpan]] {
    guard let last = cues.last?.start else { return [] }
    var parts: [[TimeSpan]] = []
    var start = 0.0
    while start <= last {
      let part = cues.filter { $0.start >= start && $0.start < start + partLength }
      if part.count >= 10 { parts.append(part) } else if !part.isEmpty, !parts.isEmpty {
        parts[parts.count - 1] += part
      } else if !part.isEmpty { parts.append(part) }
      start += partLength
    }
    return parts
  }

  static let partLength = 600.0
  /// How far a part of another cut may be from the whole film's offset.
  static let partReach = 120.0

  /// Offsets per part: each part's best offset near the whole film's, parts with the same
  /// offset joined, and the change placed at the subtitle gap that fits best.
  private static func segments(
    speech: [TimeSpan], cues: [TimeSpan], around shift: SubtitleShift
  ) -> (timing: SubtitleTiming, fit: Double)?
  {
    let parts = parts(cues)
    guard parts.count >= 2 else { return nil }
    var offsets: [Double] = []
    for part in parts {
      var best = (offset: shift.offset, fit: score(speech: speech, cues: part, shift: shift))
      let global = best.fit
      var candidate = shift.offset - partReach
      while candidate <= shift.offset + partReach {
        let value = score(
          speech: speech, cues: part, shift: SubtitleShift(offset: candidate, scale: shift.scale))
        if value > best.fit { best = (candidate, value) }
        candidate += 0.05
      }
      // A part moves away from the whole only when that clearly fits.
      offsets.append(best.fit >= plausible && best.fit - global >= 0.15 ? best.offset : shift.offset)
    }
    // Neighboring parts with (nearly) the same offset are one segment.
    var groups: [(parts: Range<Int>, offset: Double)] = []
    for (index, offset) in offsets.enumerated() {
      if let last = groups.last, abs(last.offset - offset) < 0.3 {
        groups[groups.count - 1] = (last.parts.lowerBound..<(index + 1), last.offset)
      } else {
        groups.append((index..<(index + 1), offset))
      }
    }
    guard groups.count >= 2, groups.count <= 6 else { return nil }
    // Each segment's exact offset over all its subtitles.
    let exact = groups.map { group -> Double in
      let members = group.parts.flatMap { parts[$0] }
      return refine(speech: speech, cues: members,
        around: SubtitleShift(offset: group.offset, scale: shift.scale)).shift.offset
    }
    var segments = [SubtitleSegment(from: 0, offset: exact[0])]
    for index in 1..<groups.count {
      // The change lies between the last part of one segment and the first of the next.
      let near = parts[groups[index - 1].parts.upperBound - 1] + parts[groups[index].parts.lowerBound]
      var best = (from: near.first!.start, fit: -1.0)
      for cue in near {
        let trial = SubtitleTiming(
          scale: shift.scale,
          segments: segments + [SubtitleSegment(from: cue.start, offset: exact[index])])
        let value = score(speech: speech, cues: near, timing: trial)
        if value > best.fit { best = (cue.start, value) }
      }
      segments.append(SubtitleSegment(from: best.from, offset: exact[index]))
    }
    let timing = SubtitleTiming(scale: shift.scale, segments: segments)
    return (timing, score(speech: speech, cues: cues, timing: timing))
  }

  static func fit(speech: [TimeSpan], cues: [TimeSpan], timing: SubtitleTiming) -> Double {
    let moved = cues.map { TimeSpan(start: timing.apply($0.start), end: timing.apply($0.end)) }
      .sorted { $0.start < $1.start }
    return fit(speech: speech, cues: moved, shift: .none)
  }

  /// The agreement of speech and moved subtitles: the correlation of the two on/off signals
  /// over the time the subtitles cover, from -1 to 1, 0 for chance.
  static func score(speech: [TimeSpan], cues: [TimeSpan], shift: SubtitleShift) -> Double {
    agreement(speech, cues.map { TimeSpan(start: shift.apply($0.start), end: shift.apply($0.end)) })
  }

  static func score(speech: [TimeSpan], cues: [TimeSpan], timing: SubtitleTiming) -> Double {
    agreement(speech, cues.map { TimeSpan(start: timing.apply($0.start), end: timing.apply($0.end)) })
  }

  private static func agreement(_ speech: [TimeSpan], _ moved: [TimeSpan]) -> Double {
    let shown = union(moved)
    guard let first = shown.first?.start, let last = shown.last?.end else { return 0 }
    let from = max(0, first - 2)
    let to = last + 2
    let spoken = union(
      speech.compactMap { span in
        let start = max(from, span.start)
        let end = min(to, span.end)
        return end > start ? TimeSpan(start: start, end: end) : nil
      })
    let length = to - from
    let speaking = total(spoken) / length
    let showing = total(shown) / length
    let both = overlap(spoken, shown) / length
    let spread = (speaking * (1 - speaking) * showing * (1 - showing)).squareRoot()
    return spread > 1e-9 ? (both - speaking * showing) / spread : 0
  }

  /// Sorted spans with overlapping ones joined.
  private static func union(_ spans: [TimeSpan]) -> [TimeSpan] {
    var joined: [TimeSpan] = []
    for span in spans.sorted(by: { $0.start < $1.start }) where span.end > span.start {
      if let last = joined.last, span.start <= last.end {
        joined[joined.count - 1] = TimeSpan(start: last.start, end: max(last.end, span.end))
      } else {
        joined.append(span)
      }
    }
    return joined
  }

  private static func total(_ spans: [TimeSpan]) -> Double {
    spans.reduce(0) { $0 + $1.end - $1.start }
  }

  /// Time covered by both of two joined, sorted span lists.
  private static func overlap(_ a: [TimeSpan], _ b: [TimeSpan]) -> Double {
    var i = 0
    var j = 0
    var both = 0.0
    while i < a.count, j < b.count {
      both += max(0, min(a[i].end, b[j].end) - max(a[i].start, b[j].start))
      if a[i].end < b[j].end { i += 1 } else { j += 1 }
    }
    return both
  }

  /// Share of the subtitles' time that lies on speech after `shift`.
  static func fit(speech: [TimeSpan], cues: [TimeSpan], shift: SubtitleShift) -> Double {
    var total = 0.0
    var covered = 0.0
    var index = 0
    for cue in cues {
      let start = shift.apply(cue.start)
      let end = shift.apply(cue.end)
      guard end > start else { continue }
      total += end - start
      while index < speech.count, speech[index].end <= start { index += 1 }
      var probe = index
      while probe < speech.count, speech[probe].start < end {
        covered += max(0, min(end, speech[probe].end) - max(start, speech[probe].start))
        probe += 1
      }
    }
    return total > 0 ? covered / total : 0
  }

  /// The best offset for one speed, found for all offsets at once with a cross-correlation.
  private static func bestOffset(speech: [TimeSpan], cues: [TimeSpan], scale: Double)
    -> (shift: SubtitleShift, fit: Double)?
  {
    let shifted = cues.map { TimeSpan(start: $0.start * scale, end: $0.end * scale) }
    let length = max(speech.last!.end, shifted.last!.end) + longestOffset
    let samples = Int((length / step).rounded(.up))
    var size = 1
    while size < samples * 2 { size <<= 1 }
    guard size <= 1 << 24 else { return nil }
    let content = Int((max(speech.last!.end, shifted.last!.end) / step).rounded(.up))
    let a = mask(speech, size: size, content: content)
    let b = mask(shifted, size: size, content: content)
    guard let correlation = correlate(a, b, size: size) else { return nil }
    // The correlation's strongest peaks are candidates; the exact agreement decides among them,
    // so edge effects of the padded signals cannot pick a wrong one.
    let reach = Int(longestOffset / step)
    var peaks: [(lag: Int, value: Double)] = []
    for lag in -reach...reach {
      let value = correlation[(lag + size) % size]
      guard value > correlation[(lag - 1 + size) % size], value >= correlation[(lag + 1 + size) % size]
      else { continue }
      peaks.append((lag, value))
    }
    let candidates = peaks.sorted { $0.value > $1.value }.prefix(8)
    var best: (shift: SubtitleShift, fit: Double)?
    for candidate in candidates {
      let shift = SubtitleShift(offset: Double(candidate.lag) * step, scale: scale)
      let value = score(speech: speech, cues: cues, shift: shift)
      if value > best?.fit ?? -.infinity { best = (shift, value) }
    }
    return best
  }

  /// The exact offset within half a second of `shift`, on the real times.
  private static func refine(speech: [TimeSpan], cues: [TimeSpan], around shift: SubtitleShift)
    -> (shift: SubtitleShift, fit: Double)
  {
    var best = (shift: shift, fit: score(speech: speech, cues: cues, shift: shift))
    for hundredth in -50...50 {
      let candidate = SubtitleShift(
        offset: shift.offset + Double(hundredth) * 0.01, scale: shift.scale)
      let value = score(speech: speech, cues: cues, shift: candidate)
      if value > best.fit + 1e-9 { best = (candidate, value) }
    }
    return best
  }

  /// Share of ten-minute parts of the film whose subtitles still mostly miss the speech.
  static func poorParts(
    speech: [TimeSpan], cues: [TimeSpan], timing: SubtitleTiming
  ) -> Double {
    let parts = parts(cues)
    guard !parts.isEmpty else { return 1 }
    let poor = parts.filter { score(speech: speech, cues: $0, timing: timing) < plausible }.count
    return Double(poor) / Double(parts.count)
  }

  /// 1 where a span covers the time, 0 elsewhere, less its mean over the film, so that pauses
  /// count as much as speech; the padding after the film stays 0.
  private static func mask(_ spans: [TimeSpan], size: Int, content: Int) -> [Float] {
    var values = [Float](repeating: 0, count: size)
    var covered = 0
    for span in spans {
      let from = max(0, Int(span.start / step))
      let to = min(content, Int(span.end / step))
      guard to > from else { continue }
      for index in from..<to where values[index] == 0 {
        values[index] = 1
        covered += 1
      }
    }
    let mean = Float(covered) / Float(max(1, content))
    for index in 0..<min(content, size) { values[index] -= mean }
    return values
  }

  /// corr[k] = Σ a[t + k] · b[t], for every k at once.
  private static func correlate(_ a: [Float], _ b: [Float], size: Int) -> [Double]? {
    let log2n = vDSP_Length(log2(Double(size)))
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
    defer { vDSP_destroy_fftsetup(setup) }
    let half = size / 2
    func transform(_ input: [Float]) -> ([Float], [Float]) {
      var real = [Float](repeating: 0, count: half)
      var imaginary = [Float](repeating: 0, count: half)
      real.withUnsafeMutableBufferPointer { realPointer in
        imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
          var split = DSPSplitComplex(
            realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
          input.withUnsafeBytes { raw in
            vDSP_ctoz(
              raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
          }
          vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        }
      }
      return (real, imaginary)
    }
    let (ar, ai) = transform(a)
    let (br, bi) = transform(b)
    // A · conj(B); index 0 holds the DC and Nyquist parts separately in vDSP's packed form.
    var pr = [Float](repeating: 0, count: half)
    var pi = [Float](repeating: 0, count: half)
    pr[0] = ar[0] * br[0]
    pi[0] = ai[0] * bi[0]
    for index in 1..<half {
      pr[index] = ar[index] * br[index] + ai[index] * bi[index]
      pi[index] = ai[index] * br[index] - ar[index] * bi[index]
    }
    var output = [Float](repeating: 0, count: size)
    pr.withUnsafeMutableBufferPointer { realPointer in
      pi.withUnsafeMutableBufferPointer { imaginaryPointer in
        var split = DSPSplitComplex(
          realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
        output.withUnsafeMutableBytes { raw in
          vDSP_ztoc(
            &split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
        }
      }
    }
    return output.map(Double.init)
  }
}

/// Reads the WebVTT text the server hands out for every subtitle track (embedded, beside the
/// video or downloaded) into cues. Positioning settings and voice tags are left out; italics and
/// bold stay, as SubRip shows them too.
enum SubtitleText {
  static func cues(webVTT text: String) -> [SubtitleCue] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    var cues: [SubtitleCue] = []
    for block in normalized.components(separatedBy: "\n\n") {
      let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
      let parts = lines[timing].components(separatedBy: "-->")
      guard parts.count == 2, let start = seconds(parts[0]),
        let end = seconds(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? ""),
        end > start
      else { continue }
      let text = lines[(timing + 1)...].map(clean).filter { !$0.isEmpty }
      guard !text.isEmpty else { continue }
      cues.append(SubtitleCue(start: start, end: end, lines: text))
    }
    return cues.sorted { $0.start < $1.start }
  }

  /// "01:02:03.450", "02:03.450" or "01:02:03,450".
  static func seconds(_ text: String) -> Double? {
    let value = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    let fields = value.split(separator: ":").map(String.init)
    guard (2...3).contains(fields.count), let last = Double(fields[fields.count - 1]),
      fields.dropLast().allSatisfy({ Int($0) != nil })
    else { return nil }
    let whole = fields.dropLast().reduce(0) { $0 * 60 + Double(Int($1)!) }
    return whole * 60 + last
  }

  /// Keeps `<i>`, `<b>` and `<u>`; drops other tags such as `<v Speaker>` or `<c.yellow>`.
  private static func clean(_ line: String) -> String {
    var output = ""
    var tag: String?
    for character in line {
      if character == "<" {
        tag = ""
      } else if character == ">", let current = tag {
        let name = current.trimmingCharacters(in: .whitespaces).lowercased()
        if ["i", "/i", "b", "/b", "u", "/u"].contains(name) { output += "<\(name)>" }
        tag = nil
      } else if tag != nil {
        tag! += String(character)
      } else {
        output.append(character)
      }
    }
    return output.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
      .trimmingCharacters(in: .whitespaces)
  }
}
