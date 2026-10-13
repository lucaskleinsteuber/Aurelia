import Foundation
import Testing

@testable import Aurelia

struct SceneNoteTests {
  @Test func timesRoundTripWithoutLosingSavedMilliseconds() {
    for value: Int64 in [0, 530, 60007, 330000, 3_661_009, 360_000_000] {
      #expect(SceneNoteTime.parse(SceneNoteTime.format(value)) == value)
    }
    #expect(SceneNoteTime.parse("5:30") == 330000)
    #expect(SceneNoteTime.parse("1:02:03.004") == 3_723_004)
  }

  @Test func invalidTimesAndOverflowAreRejected() {
    for text in [
      "", "-1", "1:60", "1:99:02", "1:2:", "1:00.1234", "NaN", "1e9", "1:00.",
      "999999999999999999999:00", "1: 20", "١٢",
    ] {
      #expect(SceneNoteTime.parse(text) == nil)
    }
  }

  @Test func continuousCrossingCuesOnceAndPauseDoesNotTrigger() {
    let point = note(1000)
    var policy = SceneNoteCuePolicy()
    #expect(policy.advance(to: 0, playing: true, preparing: false, notes: [point]).isEmpty)
    #expect(policy.advance(to: 1200, playing: false, preparing: false, notes: [point]).isEmpty)
    #expect(policy.advance(to: 1200, playing: true, preparing: false, notes: [point]) == [point])
    #expect(policy.advance(to: 1500, playing: true, preparing: false, notes: [point]).isEmpty)
  }

  @Test func forwardSeekSkipsNotesAndBackwardSeekRearmsThem() {
    let point = note(1000)
    var policy = SceneNoteCuePolicy()
    _ = policy.advance(to: 0, playing: true, preparing: false, notes: [point])
    policy.seek()
    #expect(policy.advance(to: 1500, playing: true, preparing: false, notes: [point]).isEmpty)
    policy.seek()
    _ = policy.advance(to: 500, playing: true, preparing: false, notes: [point])
    #expect(policy.advance(to: 1100, playing: true, preparing: false, notes: [point]) == [point])
  }

  @Test func resumeInsideRangeShowsOnceAndPreparationIsSilent() {
    let range = note(1000, end: 6000)
    var policy = SceneNoteCuePolicy()
    #expect(policy.advance(to: 4000, playing: true, preparing: true, notes: [range]).isEmpty)
    #expect(policy.advance(to: 4000, playing: true, preparing: false, notes: [range]) == [range])
    #expect(policy.advance(to: 4500, playing: true, preparing: false, notes: [range]).isEmpty)
    policy.reset()
    #expect(policy.advance(to: 6000, playing: true, preparing: false, notes: [range]).isEmpty)
  }

  @Test func simultaneousNotesAreSortedAndResetClearsOldCues() {
    let first = note(1000)
    let second = note(1200)
    var policy = SceneNoteCuePolicy()
    _ = policy.advance(to: 0, playing: true, preparing: false, notes: [second, first])
    #expect(
      policy.advance(to: 1400, playing: true, preparing: false, notes: [second, first]) == [
        first, second,
      ])
    policy.reset()
    #expect(policy.advance(to: 0, playing: true, preparing: false, notes: [first, second]).isEmpty)
  }

  private func note(_ start: Int64, end: Int64? = nil) -> SceneNote {
    SceneNote(
      id: UUID(), mediaId: UUID(), startMilliseconds: start, endMilliseconds: end,
      text: "Synthetic note", revision: 1)
  }
}
