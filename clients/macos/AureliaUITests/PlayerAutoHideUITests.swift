import XCTest

final class PlayerAutoHideUITests: XCTestCase {
  @MainActor
  func testStationaryPointerDoesNotRevealControlsAfterTheyHide() {
    let app = launchPlayer()
    defer { app.terminate() }
    let window = app.windows.firstMatch
    let transport = app.buttons["player-play-pause"]
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.35)).hover()
    XCTAssertTrue(transport.waitForNonExistence(timeout: 12))
    assertRemainsHidden(transport, seconds: 8)
    shot(app, "Player - Controls Stay Hidden with Stationary Pointer")

    // A real movement must still reveal controls and start a fresh idle delay.
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.76, dy: 0.35)).hover()
    XCTAssertTrue(transport.waitForExistence(timeout: 5))
    XCTAssertTrue(transport.waitForNonExistence(timeout: 12))
    assertRemainsHidden(transport, seconds: 5)

    // Entering the video from outside the window must also count as real motion.
    window.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: window.frame.width * 0.72, dy: -20)
    ).hover()
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.35)).hover()
    XCTAssertTrue(transport.waitForExistence(timeout: 5))
  }

  @MainActor
  func testHoverAndNativeMenuHoldControlsButTheirCleanupDoesNotRevealThemAgain() {
    let app = launchPlayer()
    defer { app.terminate() }
    let transport = app.buttons["player-play-pause"]
    transport.hover()
    wait(seconds: 3.2)
    XCTAssertTrue(transport.exists)
    shot(app, "Player - Hover Keeps Controls Visible")

    let menu = app.buttons["player-subtitle-menu"]
    menu.hover()
    menu.click()
    let option = app.menuItems["English SDH"]
    XCTAssertTrue(option.waitForExistence(timeout: 5))
    wait(seconds: 3.2)
    XCTAssertTrue(option.exists)
    XCTAssertTrue(transport.exists)
    shot(app, "Player - Native Subtitle Menu Remains Open")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(option.waitForNonExistence(timeout: 5))

    // Move focus and hover back to the video, not another control.
    let video = app.windows.firstMatch.coordinate(
      withNormalizedOffset: CGVector(dx: 0.72, dy: 0.35))
    video.click()
    XCTAssertTrue(transport.waitForNonExistence(timeout: 12))
    assertRemainsHidden(transport, seconds: 8)
    shot(app, "Player - Controls Stay Hidden after Native Menu Closes")
  }

  @MainActor
  private func launchPlayer() -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "library-admin"
    app.launchEnvironment["AURELIA_CINEMA_UI_TESTS"] = "1"
    app.launchEnvironment["AURELIA_AUTO_HIDE_UI_TESTS"] = "1"
    app.launch()
    app.activate()
    XCTAssertTrue(app.descendants(matching: .any)["sidebar-tvShows"].waitForExistence(timeout: 8))
    app.descendants(matching: .any)["sidebar-tvShows"].click()
    app.buttons["media-20000000-0000-0000-0000-000000000001"].click()
    XCTAssertTrue(app.buttons["play-media"].waitForExistence(timeout: 5))
    app.buttons["play-media"].click()
    XCTAssertTrue(app.buttons["player-play-pause"].waitForExistence(timeout: 5))
    return app
  }

  @MainActor
  private func assertRemainsHidden(_ control: XCUIElement, seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      XCTAssertFalse(control.exists, "No input: hidden controls must not reappear by themselves.")
      RunLoop.current.run(until: Date().addingTimeInterval(0.12))
    }
  }

  private func wait(seconds: TimeInterval) {
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTestExpectation(description: "No pointer or keyboard input")],
        timeout: seconds), .timedOut)
  }

  @MainActor
  private func shot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
