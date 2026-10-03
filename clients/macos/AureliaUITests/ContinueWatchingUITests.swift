import XCTest

final class ContinueWatchingUITests: XCTestCase {
  @MainActor
  func testHomeEpisodeAndMovieResumeDirectlyAtTheirSavedPositions() throws {
    let app = launch(progress: "seeded")
    defer { app.terminate() }
    scrollPage(app, by: -320)
    let episode = app.buttons["continue-20000000-0000-0000-0000-000000000010"]
    XCTAssertTrue(episode.waitForExistence(timeout: 5))
    XCTAssertEqual(episode.label, "Continue Pilot, Breaking Bad · Season 1 · Episode 1")
    shot(app, "Continue Watching - Episode and Movie on Home")
    click(episode, in: app)
    assertPlayer(app, title: "Pilot", elapsed: "0:30")
    XCTAssertEqual(
      text(app.staticTexts["player-subtitle"]), "Breaking Bad · Season 1 · Episode 1")
    shot(app, "Continue Watching - Episode Resumed at 30 Seconds")
    app.buttons["player-play-pause"].click()
    app.buttons["player-back"].click()
    XCTAssertTrue(app.descendants(matching: .any)["native-player"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(episode.waitForExistence(timeout: 5))

    let movie = app.buttons["continue-10000000-0000-0000-0000-000000000001"]
    XCTAssertTrue(movie.waitForExistence(timeout: 5))
    click(movie, in: app)
    assertPlayer(app, title: "El Camino: A Breaking Bad Movie", elapsed: "0:45")
    shot(app, "Continue Watching - Movie Resumed at 45 Seconds")
    XCTAssertFalse(app.staticTexts["Media Unavailable"].exists)
    XCTAssertFalse(app.webViews.firstMatch.exists)
  }

  @MainActor
  func testNewEpisodeProgressAppearsOnHomeAfterPlayerClosesAndCanResumeAgain() throws {
    let app = launch(progress: "empty")
    defer { app.terminate() }
    XCTAssertFalse(app.staticTexts["Continue Watching"].exists)
    app.descendants(matching: .any)["sidebar-tvShows"].click()
    app.buttons["media-20000000-0000-0000-0000-000000000001"].click()
    XCTAssertTrue(app.buttons["play-media"].waitForExistence(timeout: 5))
    scrollPage(app, by: -340)
    let first = app.buttons["episode-1-1"]
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    click(first, in: app)
    assertPlayer(app, title: "Episode 1", elapsed: "0:00")
    app.buttons["player-play-pause"].click()
    app.buttons["Forward 10 Seconds"].click()
    app.buttons["Forward 10 Seconds"].click()
    XCTAssertEqual(text(app.staticTexts["player-elapsed"]), "0:20")
    app.buttons["player-back"].click()
    XCTAssertTrue(app.descendants(matching: .any)["native-player"].waitForNonExistence(timeout: 5))
    app.descendants(matching: .any)["sidebar-home"].click()
    scrollPage(app, by: -320)
    let resumed = app.buttons["continue-20000000-0000-0000-0000-000000000101"]
    XCTAssertTrue(resumed.waitForExistence(timeout: 5), app.debugDescription)
    shot(app, "Continue Watching - Previously Empty Row Updated after Playback")
    click(resumed, in: app)
    assertPlayer(app, title: "Episode 1", elapsed: "0:20")
    shot(app, "Continue Watching - Newly Saved Episode Resumed")
    app.buttons["player-back"].click()
    XCTAssertTrue(app.descendants(matching: .any)["native-player"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(resumed.waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["Media Unavailable"].exists)
  }

  @MainActor
  private func launch(progress: String) -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "library-admin"
    app.launchEnvironment["AURELIA_CINEMA_UI_TESTS"] = "1"
    app.launchEnvironment["AURELIA_CONTINUE_UI_TESTS"] = progress
    app.launch()
    app.activate()
    XCTAssertTrue(app.descendants(matching: .any)["home-page"].waitForExistence(timeout: 8))
    return app
  }

  @MainActor
  private func assertPlayer(_ app: XCUIApplication, title: String, elapsed: String) {
    XCTAssertTrue(app.descendants(matching: .any)["native-player"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["player-play-pause"].waitForExistence(timeout: 5))
    let playerTitle = app.staticTexts["player-title"]
    XCTAssertTrue(playerTitle.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertEqual(text(playerTitle), title, app.debugDescription)
    XCTAssertEqual(text(app.staticTexts["player-elapsed"]), elapsed)
    XCTAssertFalse(app.staticTexts["Media Unavailable"].exists)
  }

  @MainActor
  private func text(_ element: XCUIElement) -> String {
    element.value as? String ?? element.label
  }

  @MainActor
  private func scrollPage(_ app: XCUIApplication, by amount: CGFloat) {
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
      .scroll(byDeltaX: 0, deltaY: amount)
  }

  @MainActor
  private func click(_ element: XCUIElement, in app: XCUIApplication) {
    let window = app.windows.firstMatch
    let frame = element.frame
    XCTAssertTrue(window.frame.contains(CGPoint(x: frame.midX, y: frame.midY)))
    window.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: frame.midX - window.frame.minX, dy: frame.midY - window.frame.minY)
    ).click()
  }

  @MainActor
  private func shot(_ app: XCUIApplication, _ name: String) {
    if app.descendants(matching: .any)["native-player"].exists {
      app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
      XCTAssertTrue(app.buttons["player-play-pause"].waitForExistence(timeout: 5))
    }
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
