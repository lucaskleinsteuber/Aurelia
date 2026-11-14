import Foundation
import XCTest

@testable import Aurelia

/// Smart Home on the Mac ("automation-v1"): what the player reports and the settings' words.
final class AutomationTests: XCTestCase {
  func testThePlayerReportsRealStatesOnce() {
    XCTAssertEqual(AutomationPlaybackState.state(wantsPlayback: true, isPlaying: true, finished: false), "playing")
    XCTAssertEqual(AutomationPlaybackState.state(wantsPlayback: true, isPlaying: false, finished: false), "buffering")
    XCTAssertEqual(AutomationPlaybackState.state(wantsPlayback: false, isPlaying: false, finished: false), "paused")
    XCTAssertEqual(AutomationPlaybackState.state(wantsPlayback: true, isPlaying: true, finished: true), "finished")
    XCTAssertTrue(AutomationPlaybackState.shouldReport(last: nil, next: "playing"))
    XCTAssertFalse(AutomationPlaybackState.shouldReport(last: "playing", next: "playing"))
    XCTAssertFalse(AutomationPlaybackState.shouldReport(last: "finished", next: "paused"))
    XCTAssertTrue(AutomationPlaybackState.shouldReport(last: "finished", next: "playing"))
  }

  func testHomeAssistantsWebhookAddressIsBuiltAndSplit() {
    XCTAssertEqual(
      AutomationText.homeAssistantURL(base: "homeassistant.local", webhookID: "aurelia_lights"),
      "http://homeassistant.local:8123/api/webhook/aurelia_lights")
    XCTAssertEqual(
      AutomationText.homeAssistantURL(base: "https://ha.example.com/", webhookID: "abc"),
      "https://ha.example.com/api/webhook/abc")
    XCTAssertNil(AutomationText.homeAssistantURL(base: "homeassistant.local", webhookID: "bad id!"))
    XCTAssertNil(AutomationText.homeAssistantURL(base: "", webhookID: "abc"))
    let parts = AutomationText.splitHomeAssistantURL("http://homeassistant.local:8123/api/webhook/aurelia_lights")
    XCTAssertEqual(parts.base, "http://homeassistant.local:8123")
    XCTAssertEqual(parts.webhookID, "aurelia_lights")
    XCTAssertEqual(AutomationText.host("http://homeassistant.local:8123/api/webhook/secret"), "homeassistant.local:8123")
    XCTAssertTrue(AutomationText.homeAssistantExample(webhookID: "aurelia_lights").contains("webhook_id: aurelia_lights"))
  }

  func testTheOverviewDecodesAndSaysHowDeliveriesWent() throws {
    let json = """
      {"webhooks":[{"id":"00000000-0000-4000-8000-0000000000a1","name":"Lights","url":"http://homeassistant.local:8123/api/webhook/x",
      "preset":"homeAssistant","events":["playback.started"],"deviceIds":[],"profileIds":[],"includeTitles":true,
      "excludeChildren":false,"enabled":true,"pausedReason":null,"consecutiveFailures":0,
      "lastDelivery":{"id":"00000000-0000-4000-8000-0000000000b1","webhookId":"00000000-0000-4000-8000-0000000000a1",
      "event":"playback.started","at":"2026-11-14T10:00:00Z","attempt":1,"state":"succeeded","statusCode":200,
      "durationMilliseconds":18,"error":null},"createdAt":"2026-11-14T09:00:00Z"}],
      "tokens":[],"events":[{"kind":"playback.started","title":"Playback Starts","detail":"A title starts."}],
      "devices":[],"profiles":[],"wakeOnLanAddresses":["30:85:A9:00:00:01"],"powerActions":["sleep","shutdown","stop"],
      "somethingNew":true}
      """
    let overview = try JSONDecoder().decode(AutomationOverview.self, from: Data(json.utf8))
    XCTAssertEqual(AutomationText.status(overview.webhooks[0]).text, "Last delivery 18 ms")
    XCTAssertEqual(overview.powerActions.map(AutomationText.powerTitle), ["Sleep Now", "Turn Off Now", "Stop Aurelia Now"])
  }
}
