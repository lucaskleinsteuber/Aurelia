import Foundation
import Testing

@testable import Aurelia

struct SpeechSubtitleTests {
  private func words(_ text: String, from start: Double, step: Double = 0.3) -> [SpeechWord] {
    text.split(separator: " ").enumerated().map { index, word in
      SpeechWord(
        text: " " + word, start: start + Double(index) * step,
        end: start + Double(index) * step + step * 0.8)
    }
  }

  @Test func sentencesAndPausesStartNewSubtitles() {
    let spoken =
      words("Guten Abend.", from: 0.2) + words("Heute schauen wir einen Film", from: 1.5)
      + words("und danach gehen wir schlafen.", from: 4.5)
    let cues = SubtitleCueBuilder.cues(from: spoken)
    #expect(cues.map { $0.lines.joined(separator: " ") } == [
      "Guten Abend.", "Heute schauen wir einen Film", "und danach gehen wir schlafen.",
    ])
    // Never over the next one, and long enough to read.
    for (cue, next) in zip(cues, cues.dropFirst()) { #expect(cue.end < next.start) }
    #expect(cues.allSatisfy { $0.end - $0.start >= 0.79 })
  }

  @Test func longSpeechSplitsIntoTwoLinesAndShortSubtitles() {
    let text =
      "Wir fahren morgen sehr früh mit dem Zug nach Berlin, weil dort die ganze Familie auf uns wartet und alle schon gespannt sind"
    let cues = SubtitleCueBuilder.cues(from: words(text, from: 0, step: 0.25))
    #expect(cues.count >= 2)
    for cue in cues {
      #expect(cue.lines.count <= 2)
      #expect(cue.lines.allSatisfy { $0.count <= SubtitleCueBuilder.lineLength + 12 })
      #expect(cue.end - cue.start <= SubtitleCueBuilder.longestCue + SubtitleCueBuilder.lingering)
    }
    #expect(cues.flatMap(\.lines).joined(separator: " ") == text)
  }

  @Test func linesBreakNearTheMiddlePreferringAfterACommaAndEmptyWordsVanish() {
    #expect(SubtitleCueBuilder.lines("Kurz.") == ["Kurz."])
    let lines = SubtitleCueBuilder.lines("Wenn du morgen kommst, bringen wir den Kuchen mit nach Hause")
    #expect(lines == ["Wenn du morgen kommst,", "bringen wir den Kuchen mit nach Hause"])
    let cues = SubtitleCueBuilder.cues(from: [
      SpeechWord(text: "  ", start: 0, end: 0.2), SpeechWord(text: "Hallo", start: 1, end: 1.4),
    ])
    #expect(cues == [SubtitleCue(start: 1, end: 2, lines: ["Hallo"])])
  }

  @Test func subRipHasNumberedCuesWithMilliseconds() {
    let text = SubtitleCueBuilder.subRip([
      SubtitleCue(start: 1.5, end: 3.25, lines: ["Eins", "Zwei"]),
      SubtitleCue(start: 3_725.004, end: 3_727, lines: ["Drei"]),
    ])
    #expect(
      text
        == "1\n00:00:01,500 --> 00:00:03,250\nEins\nZwei\n\n2\n01:02:05,004 --> 01:02:07,000\nDrei\n")
  }

  @Test func soundTrackLanguagesMapToSpeechLocales() {
    #expect(SpeechLanguages.code(forTrack: "ger") == "de")
    #expect(SpeechLanguages.code(forTrack: "deu") == "de")
    #expect(SpeechLanguages.code(forTrack: "eng") == "en")
    #expect(SpeechLanguages.code(forTrack: "und") == nil)
    #expect(SpeechLanguages.code(forTrack: nil) == nil)
    let supported = ["en-GB", "en-US", "de-AT", "de-DE", "fr-FR"].map(Locale.init(identifier:))
    #expect(SpeechLanguages.locale(for: "de", among: supported, region: "AT")?.identifier(.bcp47) == "de-AT")
    #expect(SpeechLanguages.locale(for: "de", among: supported, region: "CH")?.identifier(.bcp47) == "de-DE")
    #expect(SpeechLanguages.locale(for: "en", among: supported, region: nil)?.identifier(.bcp47) == "en-US")
    #expect(SpeechLanguages.locale(for: "ja", among: supported) == nil)
    #expect(SpeechLanguages.choices(supported) == ["en", "fr", "de"])
  }

  @Test func soundTracksDescribeThemselves() {
    let track = SpeechAudioTrack(
      index: 2, codec: "eac3", channels: 6, language: "ger", title: "Kommentar", isDefault: false)
    #expect(track.label == "German · 5.1 · Kommentar")
  }
}
