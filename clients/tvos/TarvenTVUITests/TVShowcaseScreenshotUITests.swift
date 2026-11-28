import XCTest

/// README screenshots of the fictional showcase library from scripts/make-showcase.swift. It runs
/// only when scripts/capture-showcase.sh passes TARVEN_SHOWCASE_DIR to the test runner.
final class TVShowcaseScreenshotUITests: XCTestCase {
  @MainActor
  func testShowcaseScreenshots() throws {
    guard let directory = ProcessInfo.processInfo.environment["TARVEN_SHOWCASE_DIR"] else {
      throw XCTSkip("Showcase screenshots are made by scripts/capture-showcase.sh.")
    }
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--tarven-ui-testing"]
    app.launchEnvironment["TARVEN_TV_UI_SCENARIO"] = "showcase"
    app.launchEnvironment["TARVEN_TV_UI_SUITE"] = "Tarven.TV.Showcase.\(UUID().uuidString)"
    app.launchEnvironment["TARVEN_SHOWCASE_DIR"] = directory
    app.launch()
    XCTAssertTrue(app.buttons["home-hero"].firstMatch.waitForExistence(timeout: 15))
    settle()
    shot(app, "tv-home")

    // Down to Favorites; Continue Watching above it would start playback instead of a detail page.
    let remote = XCUIRemote.shared
    for _ in 0..<3 { remote.press(.down) }
    remote.press(.select)
    settle()
    shot(app, "tv-detail")
    app.terminate()
  }

  /// Artwork loads and focus animations finish before a picture is taken.
  private func settle() { Thread.sleep(forTimeInterval: 3) }

  @MainActor
  private func shot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
