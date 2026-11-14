import Foundation
import Testing

struct TVAutomationTests {
  @Test func theTVReportsRealStatesOnce() {
    #expect(TVAutomationPlaybackState.state(wantsPlayback: true, isPlaying: true, finished: false) == "playing")
    #expect(TVAutomationPlaybackState.state(wantsPlayback: true, isPlaying: false, finished: false) == "buffering")
    #expect(TVAutomationPlaybackState.state(wantsPlayback: false, isPlaying: false, finished: false) == "paused")
    #expect(TVAutomationPlaybackState.state(wantsPlayback: true, isPlaying: false, finished: true) == "finished")
    #expect(TVAutomationPlaybackState.shouldReport(last: nil, next: "buffering"))
    #expect(!TVAutomationPlaybackState.shouldReport(last: "playing", next: "playing"))
    #expect(!TVAutomationPlaybackState.shouldReport(last: "finished", next: "paused"))
    #expect(TVAutomationPlaybackState.shouldReport(last: "finished", next: "playing"))
  }
}
