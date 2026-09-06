import XCTest

final class AureliaHomeUITests: XCTestCase {
  @MainActor
  func testFreshLaunchShowsNativePairing() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["AURELIA_HOME_UI_TEST_MODE"] = "pairing"
    app.launch()
    defer { app.terminate() }

    XCTAssertTrue(app.staticTexts["Connect to Aurelia Home"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.textFields["manual-server-address"].exists)
    XCTAssertTrue(app.buttons["connect-manually"].exists)
    XCTAssertFalse(app.webViews.firstMatch.exists)
  }

  @MainActor
  func testLibraryShowsMoviesAndTVShows() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["AURELIA_HOME_UI_TEST_MODE"] = "library"
    app.launch()
    defer { app.terminate() }

    XCTAssertTrue(
      app.buttons["media-10000000-0000-0000-0000-000000000001"]
        .waitForExistence(timeout: 8))
    app.descendants(matching: .any)["sidebar-tvShows"].click()
    XCTAssertTrue(
      app.buttons["media-20000000-0000-0000-0000-000000000001"]
        .waitForExistence(timeout: 5))
    app.buttons["media-20000000-0000-0000-0000-000000000001"].click()
    XCTAssertTrue(app.staticTexts["season-1"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.descendants(matching: .any)["episode-1-1"].exists)
    XCTAssertTrue(app.staticTexts["Behind the Scenes"].exists)
    XCTAssertFalse(app.webViews.firstMatch.exists)
  }
}
