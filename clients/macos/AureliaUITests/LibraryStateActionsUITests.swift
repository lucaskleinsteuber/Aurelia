import Foundation
import XCTest

final class LibraryStateActionsUITests: XCTestCase {
  @MainActor func testUnavailableDriveDisablesTheActualResumeTargetButRetainsWatchActions() throws {
    let app = launch(driveUnavailable: true)
    defer { app.terminate() }
    app.descendants(matching: .any)["sidebar-tvShows"].click()
    let series = app.buttons["media-20000000-0000-0000-0000-000000000001"]
    XCTAssertTrue(series.waitForExistence(timeout: 5))
    series.click()
    let play = app.buttons["play-media"]
    XCTAssertTrue(play.waitForExistence(timeout: 5))
    wait(for: "label == 'Resume S01 E02'", on: play)
    XCTAssertFalse(play.isEnabled)
    XCTAssertTrue(app.staticTexts["Media drive disconnected"].firstMatch.exists)
    screenshot(app, "1.5.3 - Unavailable Resume Drive")
    scroll(app, by: -340)
    let target = app.buttons["episode-1-2"]
    XCTAssertTrue(target.waitForExistence(timeout: 5))
    XCTAssertFalse(target.isEnabled)
    pointer(target, in: app).rightClick()
    let watched = app.menuItems["Mark as Watched"]
    XCTAssertTrue(watched.waitForExistence(timeout: 5))
    XCTAssertTrue(watched.isEnabled)
    app.typeKey(.escape, modifierFlags: [])
    screenshot(app, "1.5.3 - Offline Episode Retains Watch Actions")
  }

  @MainActor func testMovieContextWatchActionsUpdateTheVisibleStatus() throws {
    let app = launch()
    defer { app.terminate() }
    app.descendants(matching: .any)["sidebar-movies"].click()
    let movie = app.buttons["media-10000000-0000-0000-0000-000000000001"]
    XCTAssertTrue(movie.waitForExistence(timeout: 5))
    pointer(movie, in: app).rightClick()
    app.menuItems["Mark as Watched"].click()
    wait(for: "label CONTAINS 'Watched'", on: movie)
    screenshot(app, "1.5.3 - Movie Marked Watched")
    pointer(movie, in: app).rightClick()
    app.menuItems["Mark as Unwatched"].click()
    wait(for: "NOT (label CONTAINS 'Watched')", on: movie)
    movie.click()
    let play = app.buttons["play-media"]
    XCTAssertTrue(play.waitForExistence(timeout: 5))
    wait(for: "label == 'Play'", on: play)
    screenshot(app, "1.5.3 - Movie Marked Unwatched")
  }

  @MainActor func testContinueWatchingHideAndShowRetainTheResumePosition() throws {
    let app = launch()
    defer { app.terminate() }
    scroll(app, by: -320)
    let movie = app.buttons["continue-10000000-0000-0000-0000-000000000001"]
    XCTAssertTrue(movie.waitForExistence(timeout: 5))
    pointer(movie, in: app).rightClick()
    app.menuItems["Remove from Continue Watching"].click()
    XCTAssertTrue(movie.waitForNonExistence(timeout: 5))
    app.descendants(matching: .any)["sidebar-movies"].click()
    let poster = app.buttons["media-10000000-0000-0000-0000-000000000001"]
    XCTAssertTrue(poster.waitForExistence(timeout: 5))
    poster.click()
    let play = app.buttons["play-media"]
    XCTAssertTrue(play.waitForExistence(timeout: 5))
    wait(for: "label == 'Resume'", on: play)
    app.descendants(matching: .any)["media-actions"].click()
    let show = app.menuItems["Show in Continue Watching"]
    XCTAssertTrue(show.waitForExistence(timeout: 5))
    show.click()
    app.descendants(matching: .any)["sidebar-home"].click()
    scroll(app, by: -320)
    XCTAssertTrue(movie.waitForExistence(timeout: 5))
    screenshot(app, "1.5.3 - Continue Watching Restored")
  }

  @MainActor func testSeriesAndSeasonConfirmationRespectResumeAndDoNotAllowFindToEscapeTheDialog()
    throws
  {
    let app = launch()
    defer { app.terminate() }
    app.descendants(matching: .any)["sidebar-tvShows"].click()
    let series = app.buttons["media-20000000-0000-0000-0000-000000000001"]
    XCTAssertTrue(series.waitForExistence(timeout: 5))
    series.click()
    let play = app.buttons["play-media"]
    XCTAssertTrue(play.waitForExistence(timeout: 5))
    wait(for: "label == 'Resume S01 E02'", on: play)
    scroll(app, by: -340)
    let season = app.descendants(matching: .any)["season-1"]
    XCTAssertTrue(season.waitForExistence(timeout: 5))
    season.click()
    app.menuItems["Mark Season as Watched"].click()
    let confirm = app.sheets.firstMatch.buttons["Mark as Watched"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Mark 12 episodes as watched?"].exists)
    app.typeKey("f", modifierFlags: .command)
    XCTAssertTrue(confirm.exists)
    XCTAssertFalse(app.textFields["library-search"].exists)
    confirm.click()
    XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
    scroll(app, by: 600)
    wait(for: "label == 'Play S02 E01'", on: play)
    app.descendants(matching: .any)["media-actions"].click()
    app.menuItems["Mark Series as Watched"].click()
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Mark 14 episodes as watched?"].exists)
    screenshot(app, "1.5.3 - Series Watch Confirmation")
    confirm.click()
    XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
    wait(for: "label == 'Play Again S01 E01'", on: play)
    app.descendants(matching: .any)["media-actions"].click()
    app.menuItems["Mark Series as Unwatched"].click()
    let unwatched = app.sheets.firstMatch.buttons["Mark as Unwatched"]
    XCTAssertTrue(unwatched.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts["This resets playback positions for the selected episodes."].exists)
    unwatched.click()
    XCTAssertTrue(unwatched.waitForNonExistence(timeout: 5))
    wait(for: "label == 'Play S01 E02'", on: play)
    screenshot(app, "1.5.3 - Series Unwatched Retains Last Played Episode")
  }

  @MainActor private func launch(driveUnavailable: Bool = false) -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "library-admin"
    app.launchEnvironment["AURELIA_LIBRARY_STATE_UI_TESTS"] = "1"
    if driveUnavailable { app.launchEnvironment["AURELIA_LIBRARY_STATE_DRIVE_UI_TESTS"] = "1" }
    app.launchEnvironment["AURELIA_BROWSE_PREFERENCES_SUITE"] =
      "Aurelia.LibraryBrowse.UI.\(UUID().uuidString)"
    app.launch()
    app.activate()
    XCTAssertTrue(app.descendants(matching: .any)["home-page"].waitForExistence(timeout: 8))
    return app
  }

  @MainActor private func wait(for predicate: String, on element: XCUIElement) {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: predicate), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
  }

  @MainActor private func scroll(_ app: XCUIApplication, by delta: CGFloat) {
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
      .scroll(byDeltaX: 0, deltaY: delta)
  }

  @MainActor private func pointer(_ element: XCUIElement, in app: XCUIApplication)
    -> XCUICoordinate
  {
    let window = app.windows.firstMatch
    let frame = element.frame
    let point = CGPoint(x: frame.midX, y: frame.midY)
    XCTAssertTrue(frame.minX.isFinite && frame.minY.isFinite)
    XCTAssertTrue(window.frame.contains(point), "The tested card must be visible in the window.")
    return window.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: point.x - window.frame.minX, dy: point.y - window.frame.minY))
  }

  @MainActor private func screenshot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
