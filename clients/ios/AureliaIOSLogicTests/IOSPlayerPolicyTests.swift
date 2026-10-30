import Foundation
import Testing

@Suite("iOS Player Policy Tests")
struct IOSPlayerPolicyTests {
  @Test func seekPositionCalculations() {
    let duration: Int64 = 100_000

    // Forward seek
    let seekForward = IOSPlayerPolicy.seekPosition(
      current: 20_000, offset: 10_000, duration: duration)
    #expect(seekForward == 30_000)

    // Backward seek
    let seekBackward = IOSPlayerPolicy.seekPosition(
      current: 20_000, offset: -10_000, duration: duration)
    #expect(seekBackward == 10_000)

    // Clamped at 0
    let seekUnderflow = IOSPlayerPolicy.seekPosition(
      current: 5_000, offset: -10_000, duration: duration)
    #expect(seekUnderflow == 0)

    // Clamped at duration - 500
    let seekOverflow = IOSPlayerPolicy.seekPosition(
      current: 95_000, offset: 10_000, duration: duration)
    #expect(seekOverflow == duration - 500)
  }

  @Test func naturalCompletion() {
    let duration: Int64 = 120_000

    // Position close to end, observed playback, no transport failure
    #expect(
      IOSPlayerPolicy.isNaturalCompletion(
        position: 119_000,
        duration: duration,
        observedPlayback: true,
        transportFailed: false
      ))

    // Transport failed -> not natural completion
    #expect(
      !IOSPlayerPolicy.isNaturalCompletion(
        position: 119_000,
        duration: duration,
        observedPlayback: true,
        transportFailed: true
      ))

    // Position too far from end -> not natural completion
    #expect(
      !IOSPlayerPolicy.isNaturalCompletion(
        position: 50_000,
        duration: duration,
        observedPlayback: true,
        transportFailed: false
      ))
  }

  @Test func formatTimeLabels() {
    #expect(IOSPlayerPolicy.formatTime(milliseconds: 65_000) == "1:05")
    #expect(IOSPlayerPolicy.formatTime(milliseconds: 3_665_000) == "1:01:05")
    #expect(IOSPlayerPolicy.formatTime(milliseconds: 0) == "0:00")
  }
}
