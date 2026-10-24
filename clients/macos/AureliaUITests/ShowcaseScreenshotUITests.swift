import XCTest

/// README screenshots of the fictional showcase library from scripts/make-showcase.swift. It runs
/// only when scripts/capture-showcase.sh passes AURELIA_SHOWCASE_DIR to the test runner.
final class ShowcaseScreenshotUITests: XCTestCase {
  @MainActor
  func testShowcaseScreenshots() throws {
    guard let directory = ProcessInfo.processInfo.environment["AURELIA_SHOWCASE_DIR"] else {
      throw XCTSkip("Showcase screenshots are made by scripts/capture-showcase.sh.")
    }
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "library-admin"
    app.launchEnvironment["AURELIA_SHOWCASE_DIR"] = directory
    app.launch()
    app.activate()
    XCTAssertTrue(app.descendants(matching: .any)["home-page"].waitForExistence(timeout: 10))
    settle()
    shot(app, "mac-home")

    let open = app.buttons["home-hero-action"]
    XCTAssertTrue(open.waitForExistence(timeout: 5))
    open.click()
    settle()
    shot(app, "mac-detail")

    let movies = app.descendants(matching: .any)["sidebar-movies"]
    XCTAssertTrue(movies.waitForExistence(timeout: 5))
    movies.click()
    settle()
    shot(app, "mac-movies")
    app.terminate()
  }

  /// Artwork loads and the rise-in animations finish before a picture is taken.
  private func settle() { Thread.sleep(forTimeInterval: 3) }

  @MainActor
  private func shot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
