import Foundation
import Testing

@Suite("iOS Scrub Preview Plan Tests")
struct IOSScrubPreviewPlanTests {
  @Test func intervalCalculations() {
    let shortDuration: Int64 = 60_000  // 1 minute
    let intervalShort = IOSScrubPreviewPlan.interval(for: shortDuration)
    #expect(intervalShort >= IOSScrubPreviewPlan.minimumInterval)

    let longDuration: Int64 = 7_200_000  // 2 hours
    let intervalLong = IOSScrubPreviewPlan.interval(for: longDuration)
    #expect(intervalLong >= IOSScrubPreviewPlan.minimumInterval)
    #expect(intervalLong % 1000 == 0)
  }

  @Test func bucketAndSnapshot() {
    let interval: Int64 = 10_000
    let bucket = IOSScrubPreviewPlan.bucket(for: 25_400, interval: interval)
    #expect(bucket == 20_000)

    let duration: Int64 = 100_000
    let snapshot = IOSScrubPreviewPlan.snapshotPosition(
      bucket: 20_000, interval: interval, duration: duration)
    #expect(snapshot == 25_000)  // middle of bucket

    // Near the end: capped before endMargin (3_000)
    let endBucket: Int64 = 95_000
    let endSnapshot = IOSScrubPreviewPlan.snapshotPosition(
      bucket: endBucket, interval: interval, duration: duration)
    #expect(endSnapshot <= duration - IOSScrubPreviewPlan.endMargin)
  }

  @Test func nearestWithStandIn() {
    let interval: Int64 = 10_000
    let preparedBuckets: Set<Int64> = [0, 20_000, 40_000]

    let nearestExact = IOSScrubPreviewPlan.nearest(to: 20_000, interval: interval) {
      preparedBuckets.contains($0)
    }
    #expect(nearestExact == 20_000)

    let nearestStandIn = IOSScrubPreviewPlan.nearest(to: 30_000, interval: interval) {
      preparedBuckets.contains($0)
    }
    #expect(nearestStandIn == 20_000 || nearestStandIn == 40_000)

    let tooFar = IOSScrubPreviewPlan.nearest(to: 100_000, interval: interval) {
      preparedBuckets.contains($0)
    }
    #expect(tooFar == nil)
  }
}
