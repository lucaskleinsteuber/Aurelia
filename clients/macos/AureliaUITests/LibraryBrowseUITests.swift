import Foundation
import XCTest

final class LibraryBrowseUITests: XCTestCase {
  @MainActor func testEveryOverviewHasSearchAndCommandFUsesItsCurrentScope() throws {
    let app = launch()
    defer { app.terminate() }
    for (destination, query, expectedID) in [
      ("library", "chemistry", "20000000-0000-0000-0000-000000000001"),
      ("movies", "Camino", "10000000-0000-0000-0000-000000000001"),
      ("tvShows", "chemistry", "20000000-0000-0000-0000-000000000001"),
      ("recentlyAdded", "Camino", "10000000-0000-0000-0000-000000000001"),
    ] {
      app.descendants(matching: .any)["sidebar-\(destination)"].click()
      let search = app.textFields["library-search"]
      XCTAssertTrue(search.waitForExistence(timeout: 5))
      XCTAssertTrue(app.descendants(matching: .any)["library-filters"].exists)
      XCTAssertTrue(app.descendants(matching: .any)["library-sort"].exists)
      app.typeKey("f", modifierFlags: .command)
      app.typeText(query)
      XCTAssertEqual(search.value as? String, query)
      XCTAssertTrue(app.buttons["media-\(expectedID)"].waitForExistence(timeout: 5))
      screenshot(app, "1.5.3 - \(destination) Search")
    }
  }

  @MainActor func testCommandFFromHomeAndDetailReturnsToLibraryAndFocusesSearch() throws {
    let app = launch()
    defer { app.terminate() }
    app.typeKey("f", modifierFlags: .command)
    let search = app.textFields["library-search"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    app.typeText("Camino")
    let movie = app.buttons["media-10000000-0000-0000-0000-000000000001"]
    XCTAssertTrue(movie.waitForExistence(timeout: 5))
    movie.click()
    XCTAssertTrue(app.buttons["play-media"].waitForExistence(timeout: 5))
    XCTAssertFalse(search.exists)
    app.typeKey("f", modifierFlags: .command)
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    XCTAssertEqual(search.value as? String, "")
    app.typeText("chemistry")
    XCTAssertEqual(search.value as? String, "chemistry")
    XCTAssertTrue(
      app.buttons["media-20000000-0000-0000-0000-000000000001"]
        .waitForExistence(timeout: 5))
    screenshot(app, "1.5.3 - Find from Detail")
  }

  @MainActor func testFiltersPersistPerPageAndAcrossRelaunchWithoutPersistingSearch() throws {
    let suite = "Aurelia.LibraryBrowse.UI.\(UUID().uuidString)"
    let app = launch(preferenceSuite: suite)
    defer {
      app.terminate()
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
    app.descendants(matching: .any)["sidebar-library"].click()
    XCTAssertTrue(app.textFields["library-search"].waitForExistence(timeout: 5))
    app.descendants(matching: .any)["library-filters"].click()
    app.menuItems["Favorites Only"].click()
    let movie = app.buttons["media-10000000-0000-0000-0000-000000000001"]
    let series = app.buttons["media-20000000-0000-0000-0000-000000000001"]
    XCTAssertTrue(movie.waitForExistence(timeout: 5))
    XCTAssertTrue(series.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["library-active-filters"].exists)
    app.descendants(matching: .any)["sidebar-tvShows"].click()
    XCTAssertTrue(series.waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["library-active-filters"].exists)
    app.descendants(matching: .any)["sidebar-library"].click()
    XCTAssertTrue(series.waitForNonExistence(timeout: 5))
    let search = app.textFields["library-search"]
    search.click()
    search.typeText("Camino")
    XCTAssertTrue(movie.waitForExistence(timeout: 5))
    screenshot(app, "1.5.3 - Favorite Filter and Search")

    app.terminate()
    app.launch()
    app.activate()
    XCTAssertTrue(app.descendants(matching: .any)["home-page"].waitForExistence(timeout: 8))
    app.descendants(matching: .any)["sidebar-library"].click()
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    XCTAssertEqual(search.value as? String, "")
    XCTAssertTrue(movie.waitForExistence(timeout: 5))
    XCTAssertTrue(series.waitForNonExistence(timeout: 5))
    app.buttons["library-clear-filters"].click()
    XCTAssertTrue(app.staticTexts["library-active-filters"].waitForNonExistence(timeout: 5))
    // Clearing restores the Collections rail above the lazy TV Shows grid.
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
      .scroll(byDeltaX: 0, deltaY: -480)
    XCTAssertTrue(series.waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["library-active-filters"].exists)
    screenshot(app, "1.5.3 - Cleared Filters after Relaunch")
  }

  @MainActor private func launch(preferenceSuite: String? = nil) -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "library-admin"
    app.launchEnvironment["AURELIA_LIBRARY_STATE_UI_TESTS"] = "1"
    app.launchEnvironment["AURELIA_BROWSE_PREFERENCES_SUITE"] =
      preferenceSuite ?? "Aurelia.LibraryBrowse.UI.\(UUID().uuidString)"
    app.launch()
    app.activate()
    XCTAssertTrue(app.descendants(matching: .any)["home-page"].waitForExistence(timeout: 8))
    return app
  }

  @MainActor private func screenshot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
