import Foundation
import Testing

@Suite("iOS Playback State Machine Tests")
struct IOSPlaybackStateTests {
  @Test func initialAndResetState() {
    var sm = IOSPlaybackStateMachine()
    #expect(sm.state.phase == .idle)

    sm.reset(at: 1000)
    #expect(sm.state.phase == .preparing)
    #expect(sm.state.isLoading)
    #expect(!sm.state.isPlaying)
  }

  @Test func playingTransition() {
    var sm = IOSPlaybackStateMachine()
    sm.reset(at: 1000)

    let snapshot = IOSDecoderSnapshot(
      state: .playing,
      positionMilliseconds: 5000,
      durationMilliseconds: 120000,
      isPlaying: true,
      isSeekable: true
    )
    sm.sample(snapshot, at: 1001)

    #expect(sm.state.phase == .playing)
    #expect(sm.state.isPlaying)
    #expect(!sm.state.isLoading)
    #expect(sm.state.positionMilliseconds == 5000)
    #expect(sm.state.durationMilliseconds == 120000)
    #expect(sm.state.isSeekable)
    #expect(sm.state.hasObservedPlayback)
  }

  @Test func pausedTransition() {
    var sm = IOSPlaybackStateMachine()
    sm.reset(at: 1000)

    sm.sample(
      IOSDecoderSnapshot(
        state: .playing, positionMilliseconds: 1000, durationMilliseconds: 50000, isPlaying: true),
      at: 1001)
    sm.sample(
      IOSDecoderSnapshot(
        state: .paused, positionMilliseconds: 1000, durationMilliseconds: 50000, isPlaying: false),
      at: 1002)

    #expect(sm.state.phase == .paused)
    #expect(!sm.state.isPlaying)
  }

  @Test func endedTransition() {
    var sm = IOSPlaybackStateMachine()
    sm.reset(at: 1000)

    sm.sample(
      IOSDecoderSnapshot(
        state: .playing, positionMilliseconds: 49000, durationMilliseconds: 50000, isPlaying: true),
      at: 1001)
    sm.sample(
      IOSDecoderSnapshot(
        state: .ended, positionMilliseconds: 50000, durationMilliseconds: 50000, isPlaying: false),
      at: 1002)

    #expect(sm.state.phase == .ended)
    #expect(!sm.state.isPlaying)
  }
}
