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
    // The library stays alive underneath the detail page, but its search is out of reach.
    XCTAssertFalse(search.isHittable)
    XCTAssertNotEqual(search.value(forKey: "hasKeyboardFocus") as? Bool, true)
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

  @MainActor func testReturningFromDetailKeepsHomeScrollPositionAndHero() throws {
    let app = launch()
    defer { app.terminate() }
    let hero = app.descendants(matching: .any)["home-hero"]
    XCTAssertTrue(hero.waitForExistence(timeout: 5))
    let heroFrame = hero.frame
    app.descendants(matching: .any)["home-page"].scroll(byDeltaX: 0, deltaY: -400)
    XCTAssertNotEqual(hero.frame.minY, heroFrame.minY, "Home did not scroll.")
    let window = app.windows.firstMatch.frame
    let posters = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "media-"))
    let card = try XCTUnwrap(
      posters.allElementsBoundByIndex.first {
        let frame = $0.frame
        return !frame.isEmpty
          && window.insetBy(dx: 260, dy: 120).contains(
            CGPoint(x: frame.midX, y: frame.midY))
      })
    let before = card.frame
    click(card, in: app)
    XCTAssertTrue(app.buttons["play-media"].waitForExistence(timeout: 5))
    app.buttons["Back"].firstMatch.click()
    XCTAssertTrue(card.waitForExistence(timeout: 5))
    XCTAssertEqual(card.frame.minY, before.minY, accuracy: 2)
    XCTAssertEqual(card.frame.minX, before.minX, accuracy: 2)
    // Back at the top, the hero is exactly where it was before opening a title.
    app.descendants(matching: .any)["home-page"].scroll(byDeltaX: 0, deltaY: 2_000)
    XCTAssertEqual(hero.frame.minY, heroFrame.minY, accuracy: 2)
    XCTAssertEqual(hero.frame.height, heroFrame.height, accuracy: 2)
    screenshot(app, "1.6.2 - Home After Returning From Detail")
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
    app.buttons["library-filter-favorites"].click()
    let movie = app.buttons["media-10000000-0000-0000-0000-000000000001"]
    let series = app.buttons["media-20000000-0000-0000-0000-000000000001"]
    XCTAssertTrue(movie.waitForExistence(timeout: 5))
    XCTAssertTrue(series.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.buttons["library-clear-filters"].exists)
    app.descendants(matching: .any)["sidebar-tvShows"].click()
    XCTAssertTrue(series.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["library-clear-filters"].exists)
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
    // Aurelia reopens on the page it was left on, here the Library.
    XCTAssertTrue(search.waitForExistence(timeout: 8))
    XCTAssertEqual(search.value as? String, "")
    XCTAssertTrue(movie.waitForExistence(timeout: 5))
    XCTAssertTrue(series.waitForNonExistence(timeout: 5))
    app.buttons["library-clear-filters"].click()
    XCTAssertTrue(app.buttons["library-clear-filters"].waitForNonExistence(timeout: 5))
    // Clearing restores the Collections rail above the lazy TV Shows grid.
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
      .scroll(byDeltaX: 0, deltaY: -480)
    XCTAssertTrue(series.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["library-clear-filters"].exists)
    screenshot(app, "1.5.3 - Cleared Filters after Relaunch")
  }

  /// Clicks at the element's center through the window, without accessibility auto-scrolling.
  @MainActor private func click(_ element: XCUIElement, in app: XCUIApplication) {
    let window = app.windows.firstMatch
    let frame = element.frame
    window.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: frame.midX - window.frame.minX, dy: frame.midY - window.frame.minY)
    ).click()
  }

  @MainActor func testDownloadsPageAndTheDownloadMenuEntry() throws {
    let app = launch()
    defer { app.terminate() }
    let sidebar = app.descendants(matching: .any)["sidebar-downloads"]
    XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
    sidebar.click()
    XCTAssertTrue(app.descendants(matching: .any)["downloads-page"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Downloads"].exists)
    screenshot(app, "Downloads Page")

    // Movies and episodes offer Download in their menu; nothing is downloaded here.
    app.descendants(matching: .any)["sidebar-movies"].click()
    let movie = app.buttons["media-10000000-0000-0000-0000-000000000001"]
    XCTAssertTrue(movie.waitForExistence(timeout: 5))
    movie.rightClick()
    let download = app.menuItems["Download"]
    let remove = app.menuItems["Remove Download"]
    XCTAssertTrue(download.waitForExistence(timeout: 5) || remove.exists, app.debugDescription)
    screenshot(app, "Download Menu Entry")
    app.typeKey(.escape, modifierFlags: [])
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
