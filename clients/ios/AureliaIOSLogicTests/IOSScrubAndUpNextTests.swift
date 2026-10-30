import Foundation
import Testing

@Suite("iOS scrub previews, resume and Up Next")
struct IOSScrubAndUpNextTests {
  @Test func previewStepsCoverTheTimelineCoarseFirstAndOnlyOnce() {
    #expect(IOSScrubPreviewPlan.interval(for: 45 * 60_000) == 10_000)
    #expect(IOSScrubPreviewPlan.interval(for: 3 * 3_600_000) == 15_000)
    let order = IOSScrubPreviewPlan.order(duration: 265_000, interval: 10_000)
    #expect(order.count == 27)
    #expect(Set(order) == Set((0..<27).map { Int64($0) * 10_000 }))
    #expect(Array(order.prefix(4)) == [0, 80_000, 160_000, 240_000])
    #expect(IOSScrubPreviewPlan.order(duration: 0, interval: 10_000).isEmpty)
  }

  @Test func framesAreTakenMidStepButNotAtTheVeryEnd() {
    #expect(
      IOSScrubPreviewPlan.snapshotPosition(bucket: 20_000, interval: 10_000, duration: 60_000)
        == 25_000)
    #expect(
      IOSScrubPreviewPlan.snapshotPosition(
        bucket: 3_610_000, interval: 10_000, duration: 3_611_480) == 3_608_480)
  }

  @Test func aNearbyPreparedFrameStandsInUntilTheExactOneArrives() {
    let prepared: Set<Int64> = [0, 80_000]
    #expect(
      IOSScrubPreviewPlan.nearest(to: 80_000, interval: 10_000) { prepared.contains($0) } == 80_000)
    #expect(
      IOSScrubPreviewPlan.nearest(to: 50_000, interval: 10_000) { prepared.contains($0) } == 80_000)
    #expect(
      IOSScrubPreviewPlan.nearest(to: 200_000, interval: 10_000) { prepared.contains($0) } == nil)
  }

  @Test func severalDecodersOnlyWhereTheServerKeepsPreviewsApart() {
    #expect(IOSScrubPreviewPlan.workers(parallel: false, cores: 6) == 1)
    #expect(IOSScrubPreviewPlan.workers(parallel: true, cores: 6) == 4)
    #expect(IOSScrubPreviewPlan.workers(parallel: true, cores: 2) == 2)
    // With the scrub position's own decoder this stays within the server's 8 per device.
    #expect(IOSScrubPreviewPlan.workers(parallel: true, cores: 64) + 1 <= 8)
  }

  @Test func scrubStepsGrowWhilePressesFollowQuickly() {
    #expect(IOSPlayerPolicy.scrubStep(base: 10_000, repeats: 0) == 10_000)
    #expect(IOSPlayerPolicy.scrubStep(base: 10_000, repeats: 5) == 30_000)
    #expect(IOSPlayerPolicy.scrubStep(base: 10_000, repeats: 12) == 60_000)
  }

  @Test func resumeIsKeptWhenTheDecoderOpensThere() {
    #expect(IOSPlayerPolicy.openedAtResume(clock: 600_305, resume: 600_000))
    // A container that ignores the start position starts near zero and still seeks.
    #expect(!(IOSPlayerPolicy.openedAtResume(clock: 400, resume: 600_000)))
  }

  @Test func upNextAppearsInTheLastSecondsOnlyWhenTheNextEpisodeWouldStart() {
    func shows(
      position: Int64, duration: Int64 = 2_700_000, hasNext: Bool = true, autoplay: Bool = true,
      stopsAtEnd: Bool = false, dismissed: Bool = false
    ) -> Bool {
      IOSPlayerPolicy.showsUpNext(
        position: position, duration: duration, hasNext: hasNext, autoplay: autoplay,
        stopsAtEnd: stopsAtEnd, dismissed: dismissed)
    }
    #expect(!(shows(position: 2_670_000)))
    #expect(shows(position: 2_685_000))
    #expect(!(shows(position: 2_685_000, hasNext: false)))
    #expect(!(shows(position: 2_685_000, autoplay: false)))
    #expect(!(shows(position: 2_685_000, stopsAtEnd: true)))
    #expect(!(shows(position: 2_685_000, dismissed: true)))
    // Trailers and extras are too short for a card.
    #expect(!(shows(position: 100_000, duration: 110_000)))
    #expect(IOSPlayerPolicy.upNextSeconds(position: 2_685_000, duration: 2_700_000) == 15)
    #expect(IOSPlayerPolicy.upNextSeconds(position: 2_699_500, duration: 2_700_000) == 1)
  }
}
