import AppKit
import XCTest

final class AureliaHomeUITests: XCTestCase {
  @MainActor
  func testFirstRunOffersHostAndClientModes() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_HOME_UI_TEST_MODE"] = "welcome"
    app.launch()
    app.activate()
    defer { app.terminate() }

    XCTAssertTrue(app.staticTexts["Welcome to Aurelia Home"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["choose-host"].exists)
    XCTAssertTrue(app.buttons["choose-client"].exists)
    XCTAssertFalse(app.webViews.firstMatch.exists)
    assertNoUnexpectedDialog(in: app)
  }

  @MainActor
  func testNativeHostSetupCollectsOwnerDetailsWithoutSystemDialogs() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_HOME_UI_TEST_MODE"] = "host-setup"
    app.launch()
    app.activate()
    defer { app.terminate() }

    XCTAssertTrue(app.staticTexts["Create Your Aurelia Home Server"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.textFields["host-server-name"].exists)
    XCTAssertTrue(app.textFields["host-owner-name"].exists)
    XCTAssertTrue(app.secureTextFields["host-owner-password"].exists)
    XCTAssertTrue(app.buttons["create-local-server"].exists)
    assertNoUnexpectedDialog(in: app)
  }

  @MainActor
  func testLibraryFolderSelectionUsesInjectedTestFolderWithoutPrivacyDialog() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_HOME_UI_TEST_MODE"] = "library-setup"
    app.launchEnvironment["AURELIA_HOME_UI_TEST_FOLDER"] = "/private/tmp/AureliaHome/UIFixture"
    app.launch()
    app.activate()
    defer { app.terminate() }

    XCTAssertTrue(app.buttons["initial-add-media-folder"].waitForExistence(timeout: 8))
    app.buttons["initial-add-media-folder"].click()
    XCTAssertTrue(app.buttons["choose-media-folder"].waitForExistence(timeout: 5))
    app.buttons["choose-media-folder"].click()
    XCTAssertEqual(
      app.textFields["library-path"].value as? String,
      "/private/tmp/AureliaHome/UIFixture")
    XCTAssertFalse(app.dialogs.firstMatch.exists)
    XCTAssertFalse(app.alerts.firstMatch.exists)
  }

  @MainActor
  func testFreshLaunchShowsNativePairing() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_HOME_UI_TEST_MODE"] = "pairing"
    app.launch()
    app.activate()
    defer { app.terminate() }

    XCTAssertTrue(app.staticTexts["Connect to Aurelia Home"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.textFields["manual-server-address"].exists)
    XCTAssertTrue(app.buttons["connect-manually"].exists)
    XCTAssertFalse(app.webViews.firstMatch.exists)
    assertNoUnexpectedDialog(in: app)
  }

  @MainActor
  func testClosingWindowAndReopeningThroughLaunchServicesRestoresIt() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_HOME_UI_TEST_MODE"] = "welcome"
    app.launch()
    app.activate()
    defer { app.terminate() }

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 8))
    window.buttons[XCUIIdentifierCloseWindow].click()
    XCTAssertFalse(window.waitForExistence(timeout: 3))

    guard
      let applicationURL = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.lucas.aureliahome"
      ).first?.bundleURL
    else {
      XCTFail("The running Aurelia Home bundle URL was unavailable")
      return
    }

    let reopened = expectation(description: "Launch Services reopened Aurelia Home")
    NSWorkspace.shared.openApplication(
      at: applicationURL,
      configuration: NSWorkspace.OpenConfiguration()
    ) { _, error in
      XCTAssertNil(error)
      reopened.fulfill()
    }
    wait(for: [reopened], timeout: 8)

    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["Welcome to Aurelia Home"].exists)
  }

  @MainActor
  func testLibraryShowsMoviesAndTVShows() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_HOME_UI_TEST_MODE"] = "library"
    app.launch()
    app.activate()
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
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_HOME_UI_TEST_MODE"] = "library"
    app.launch()
    app.activate()
    XCTAssertTrue(
      app.buttons["media-10000000-0000-0000-0000-000000000001"]
        .waitForExistence(timeout: 8))
    return app
  }

  @MainActor
  private func configureTestLaunch(_ app: XCUIApplication) {
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
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
