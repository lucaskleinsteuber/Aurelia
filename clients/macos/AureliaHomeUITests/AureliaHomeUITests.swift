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
    assertNoUnexpectedDialog(in: app)
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
    XCTAssertTrue(
      app.buttons["supplement-20000000-0000-0000-0000-000000000020"].exists)
    XCTAssertFalse(app.webViews.firstMatch.exists)

    app.buttons["episode-1-1"].click()
    XCTAssertTrue(app.descendants(matching: .any)["native-player"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.webViews.firstMatch.exists)
    assertNoUnexpectedDialog(in: app)
  }

  @MainActor
  func testMovieStartsNativePlayer() throws {
    let app = launchLibrary()
    defer { app.terminate() }

    app.buttons["media-10000000-0000-0000-0000-000000000001"].click()
    XCTAssertTrue(app.buttons["play-media"].waitForExistence(timeout: 5))
    app.buttons["play-media"].click()
    assertNativePlayer(in: app)
  }

  @MainActor
  func testTrailerStartsNativePlayer() throws {
    let app = launchLibrary()
    defer { app.terminate() }

    app.buttons["media-10000000-0000-0000-0000-000000000001"].click()
    let trailer = app.buttons["supplement-10000000-0000-0000-0000-000000000010"]
    XCTAssertTrue(trailer.waitForExistence(timeout: 5))
    trailer.click()
    assertNativePlayer(in: app)
  }

  @MainActor
  func testSeriesExtraStartsNativePlayer() throws {
    let app = launchLibrary()
    defer { app.terminate() }

    app.descendants(matching: .any)["sidebar-tvShows"].click()
    app.buttons["media-20000000-0000-0000-0000-000000000001"].click()
    let extra = app.buttons["supplement-20000000-0000-0000-0000-000000000020"]
    XCTAssertTrue(extra.waitForExistence(timeout: 5))
    extra.click()
    assertNativePlayer(in: app)
  }

  @MainActor
  func testPlayerRestoresWindowAfterNativeFullScreen() throws {
    let app = launchLibrary()
    defer { app.terminate() }

    app.buttons["media-10000000-0000-0000-0000-000000000001"].click()
    app.buttons["play-media"].click()
    assertNativePlayer(in: app)

    let window = app.windows.firstMatch
    let originalFrame = window.frame
    window.hover()
    let fullScreen = app.buttons["player-fullscreen"]
    XCTAssertTrue(fullScreen.waitForExistence(timeout: 5))
    fullScreen.click()

    let enteredFullScreen = NSPredicate { _, _ in
      window.frame.width > originalFrame.width + 100
        || window.frame.height > originalFrame.height + 100
    }
    expectation(for: enteredFullScreen, evaluatedWith: window)
    waitForExpectations(timeout: 8)

    window.hover()
    let back = app.buttons["player-back"]
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.click()
    XCTAssertFalse(app.descendants(matching: .any)["native-player"].waitForExistence(timeout: 5))

    let restoredFrame = window.frame
    XCTAssertEqual(restoredFrame.width, originalFrame.width, accuracy: 4)
    XCTAssertEqual(restoredFrame.height, originalFrame.height, accuracy: 4)
  }

  @MainActor
  private func launchLibrary() -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["AURELIA_HOME_UI_TEST_MODE"] = "library"
    app.launch()
    XCTAssertTrue(
      app.buttons["media-10000000-0000-0000-0000-000000000001"]
        .waitForExistence(timeout: 8))
    return app
  }

  @MainActor
  private func assertNativePlayer(in app: XCUIApplication) {
    XCTAssertTrue(app.descendants(matching: .any)["native-player"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.webViews.firstMatch.exists)
    assertNoUnexpectedDialog(in: app)
  }

  @MainActor
  private func assertNoUnexpectedDialog(in app: XCUIApplication) {
    XCTAssertFalse(app.alerts.firstMatch.exists)
    XCTAssertFalse(app.dialogs.firstMatch.exists)
    XCTAssertFalse(app.sheets.firstMatch.exists)
  }
}
