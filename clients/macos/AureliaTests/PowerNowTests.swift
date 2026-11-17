import XCTest

@testable import Aurelia

/// Settings › Power › Right Now: what the server can do now, its words, and older servers.
final class PowerNowTests: XCTestCase {
  func testNewAndOlderServersOfferIt() {
    XCTAssertTrue(PowerNowText.isOffered(by: ["power-now-v1"]))
    XCTAssertTrue(PowerNowText.isOffered(by: ["automation-v1"]))
    XCTAssertFalse(PowerNowText.isOffered(by: ["people-v1"]))
  }

  func testTheOptionsDecodeFromNewAndOlderServers() throws {
    let options = try JSONDecoder().decode(
      PowerNowOptions.self, from: Data(#"{"actions":["sleep","shutdown","stop"]}"#.utf8))
    XCTAssertEqual(
      PowerNowText.known(options.actions).map(PowerNowText.title),
      ["Sleep Now", "Turn Off Now", "Stop Aurelia Now"])
    let legacy = try JSONDecoder().decode(
      LegacyPowerNowOptions.self,
      from: Data(#"{"webhooks":[],"tokens":[],"powerActions":["stop"],"somethingNew":true}"#.utf8))
    XCTAssertEqual(legacy.powerActions, ["stop"])
    XCTAssertEqual(PowerNowText.known(["reboot", "stop"]), ["stop"])
  }
}
