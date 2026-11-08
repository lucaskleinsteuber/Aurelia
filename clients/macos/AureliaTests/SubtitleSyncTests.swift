import Foundation
import Testing

@testable import Aurelia

struct SubtitleSyncTests {
  /// A repeatable invented film: stretches of speech with pauses between them.
  private struct Dice {
    var state: UInt64
    mutating func next(_ range: ClosedRange<Double>) -> Double {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      let unit = Double(state >> 11) / Double(1 << 53)
      return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
  }

  private func film(_ dice: inout Dice, seconds: Double = 5400) -> [TimeSpan] {
    var time = 5.0
    var spans: [TimeSpan] = []
    while time < seconds {
      let length = dice.next(0.6...4.5)
      spans.append(TimeSpan(start: time, end: time + length))
      time += length + dice.next(0.3...9)
    }
    return spans
  }

  /// Subtitles roughly over the speech, a little early or late and missing some lines, made for
  /// times that `truth` turns into the film's.
  private func subtitles(_ dice: inout Dice, for speech: [TimeSpan], truth: SubtitleShift)
    -> [TimeSpan]
  {
    speech.compactMap { span in
      guard dice.next(0...1) > 0.1 else { return nil }
      let start = span.start + dice.next(-0.2...0.15)
      let end = span.end + dice.next(0...0.6)
      return TimeSpan(
        start: (start - truth.offset) / truth.scale, end: (end - truth.offset) / truth.scale)
    }
  }

  @Test(arguments: [
    SubtitleShift(offset: 3.2, scale: 1), SubtitleShift(offset: -45.7, scale: 1),
    SubtitleShift(offset: 1.5, scale: 25 / 23.976), SubtitleShift(offset: -2, scale: 23.976 / 25),
  ])
  func offsetsAndFrameRatesAreFound(truth: SubtitleShift) {
    var dice = Dice(state: 7)
    let speech = film(&dice)
    let result = SubtitleSync.find(speech: speech, cues: subtitles(&dice, for: speech, truth: truth))
    #expect(result.verdict == .shifted)
    #expect(result.timing.segments.count == 1)
    #expect(abs(result.timing.segments[0].offset - truth.offset) < 0.25)
    #expect(abs(result.timing.scale - truth.scale) < 0.0001)
    #expect(result.fitAfter > 0.8 && result.fitAfter > result.fitBefore + 0.3)
  }

  @Test func fittingSubtitlesStayAsTheyAre() {
    var dice = Dice(state: 11)
    let speech = film(&dice)
    let result = SubtitleSync.find(speech: speech, cues: subtitles(&dice, for: speech, truth: .none))
    #expect(result.verdict == .alreadyInSync)
    #expect(result.timing == SubtitleTiming(.none))
  }

  @Test func subtitlesOfAnotherFilmAreRefused() {
    var dice = Dice(state: 13)
    let speech = film(&dice)
    for _ in 0..<8 {
      let other = film(&dice)
      let result = SubtitleSync.find(speech: speech, cues: subtitles(&dice, for: other, truth: .none))
      #expect(result.verdict == .noMatch)
      #expect(result.timing == SubtitleTiming(.none))
    }
  }

  @Test func anotherCutIsSyncedInParts() {
    var dice = Dice(state: 17)
    let speech = film(&dice)
    // From the middle on, the film runs 30 seconds later than the subtitles think.
    let cues = subtitles(&dice, for: speech, truth: .none).map {
      $0.start > 2700 ? TimeSpan(start: $0.start - 30, end: $0.end - 30) : $0
    }
    let result = SubtitleSync.find(speech: speech, cues: cues)
    #expect(result.verdict == .shifted)
    #expect(result.timing.segments.count == 2)
    #expect(abs(result.timing.segments[0].offset) < 0.25)
    #expect(abs(result.timing.segments[1].offset - 30) < 0.25)
    #expect(abs(result.timing.segments[1].from - 2670) < 60)
  }

  @Test func incompleteRecognitionStillFindsTheOffset() {
    var dice = Dice(state: 19)
    let speech = film(&dice)
    let heard = speech.filter { _ in dice.next(0...1) > 0.33 }
    let result = SubtitleSync.find(
      speech: heard, cues: subtitles(&dice, for: speech, truth: SubtitleShift(offset: 7.5, scale: 1)))
    #expect(result.verdict == .shifted)
    #expect(abs(result.timing.segments[0].offset - 7.5) < 0.25)
  }

  @Test func movedPartsNeverOverlap() {
    let timing = SubtitleTiming(
      scale: 1, segments: [SubtitleSegment(from: 0, offset: 0), SubtitleSegment(from: 10, offset: -3)])
    let moved = timing.apply([
      SubtitleCue(start: 8, end: 9.5, lines: ["A"]), SubtitleCue(start: 10, end: 12, lines: ["B"]),
      SubtitleCue(start: 12.5, end: 14, lines: ["C"]),
    ])
    #expect(moved.map(\.lines) == [["A"], ["C"]])
    #expect(zip(moved, moved.dropFirst()).allSatisfy { $0.end < $1.start })
  }

  @Test func speechJoinsCloseWords() {
    let spans = SubtitleSync.speech(from: [
      SpeechWord(text: "a", start: 1, end: 1.3), SpeechWord(text: "b", start: 1.5, end: 1.8),
      SpeechWord(text: "c", start: 3, end: 3.4),
    ])
    #expect(spans == [TimeSpan(start: 1, end: 1.8), TimeSpan(start: 3, end: 3.4)])
  }

  @Test func webVTTFromTheServerBecomesCues() {
    let text = """
      WEBVTT

      NOTE made by the server

      1
      00:00:01.500 --> 00:00:03.250 align:start position:10%
      <v Anna>Hallo &amp; <i>willkommen</i></v>
      zusammen

      02:05.000 --> 02:07.000
      <c.yellow>Zwei</c>

      00:00:09.000 --> 00:00:08.000
      Falsch herum
      """
    let cues = SubtitleText.cues(webVTT: text)
    #expect(cues == [
      SubtitleCue(start: 1.5, end: 3.25, lines: ["Hallo & <i>willkommen</i>", "zusammen"]),
      SubtitleCue(start: 125, end: 127, lines: ["Zwei"]),
    ])
    #expect(SubtitleText.seconds("01:02:03,450") == 3723.45)
  }

  @Test func theSummarySaysWhatChanged() {
    let later = SubtitleSyncResult(
      verdict: .shifted, timing: SubtitleTiming(SubtitleShift(offset: 2.44, scale: 25 / 23.976)),
      fitBefore: 0.31, fitAfter: 0.88, poorParts: 0)
    #expect(
      SpeechSubtitleJobs.summary(later)
        == "Moved 2.4 s later, adjusted for another frame rate. Fits 88 % of the speech (was 31 %).")
    let parts = SubtitleSyncResult(
      verdict: .shifted,
      timing: SubtitleTiming(
        scale: 1, segments: [SubtitleSegment(from: 0, offset: 0), SubtitleSegment(from: 900, offset: 30)]),
      fitBefore: 0.6, fitAfter: 0.88, poorParts: 0)
    #expect(SpeechSubtitleJobs.summary(parts).hasPrefix("Moved in 2 parts, as for another cut"))
  }
}
