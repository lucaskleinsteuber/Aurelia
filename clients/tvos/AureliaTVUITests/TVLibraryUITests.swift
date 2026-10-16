import XCTest

/// Remote-only coverage of library actions through the production views. Each
/// launch uses an isolated synthetic server and a unique preference domain.
final class TVLibraryUITests: XCTestCase {
  private let movieID = "00000000-0000-4000-8000-000000000010"
  private let seriesID = "00000000-0000-4000-8000-000000000020"
  private let resumeID = "00000000-0000-4000-8000-000000000142"
  @MainActor private var remote: XCUIRemote { .shared }

  @MainActor
  func testContinueWatchingSeeAllUsesServerTargetOnce() {
    let app = launch()
    defer { app.terminate() }
    select(app.buttons["home-all-continueWatching"], in: app)
    let resume = app.buttons["catalog-\(resumeID)"]
    XCTAssertTrue(resume.waitForExistence(timeout: 10))
    XCTAssertEqual(app.buttons.matching(identifier: "catalog-\(resumeID)").count, 1)
    XCTAssertFalse(app.buttons["catalog-\(seriesID)"].exists)
    XCTAssertFalse(app.staticTexts["The server returned an invalid response."].exists)
    capture(app, "Library - Complete Continue Watching")
    select(resume, in: app)
    expectFocus(app.buttons["detail-play"])
    XCTAssertEqual(app.buttons["detail-play"].label, "Resume S02 E02")
    XCTAssertTrue(app.buttons["detail-season"].exists)
  }

  @MainActor
  func testFavoriteAndSingleTitleWatchActionsUpdateMenus() {
    let app = launch()
    defer { app.terminate() }
    openMovie(app)
    openMore(app)
    select(app.buttons["Add to Favorites"], in: app)
    XCTAssertTrue(app.buttons["detail-more"].waitForExistence(timeout: 5))
    openMore(app)
    XCTAssertTrue(app.buttons["Remove from Favorites"].waitForExistence(timeout: 8))
    select(app.buttons["Mark as Watched"], in: app)
    XCTAssertTrue(app.buttons["detail-more"].waitForExistence(timeout: 5))
    openMore(app)
    XCTAssertTrue(app.buttons["Mark as Unwatched"].waitForExistence(timeout: 8))
    capture(app, "Details - Favorite and Watched Actions")
    select(app.buttons["Mark as Unwatched"], in: app)
    openMore(app)
    XCTAssertTrue(app.buttons["Mark as Watched"].waitForExistence(timeout: 8))
    remote.press(.menu)
    selectTab(app, title: "Home")
    XCTAssertTrue(app.staticTexts["Favorites"].firstMatch.waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["home-favorites-\(movieID)"].exists)
  }

  @MainActor
  func testSeriesAndSeasonChangesRequireCountedConfirmation() {
    let app = launch()
    defer { app.terminate() }
    openSeries(app)
    openMore(app)
    select(app.buttons["Mark as Watched"], in: app)
    XCTAssertTrue(dialogText(app, "Mark 16 episodes as watched?").waitForExistence(timeout: 8))
    capture(app, "Series - Confirm Watched Count")
    select(app.buttons["Cancel"].firstMatch, in: app)
    XCTAssertTrue(app.buttons["detail-season-options"].waitForExistence(timeout: 5))
    select(app.buttons["detail-season-options"], in: app)
    select(app.buttons["Mark Season as Unwatched"], in: app)
    XCTAssertTrue(dialogText(app, "Mark 8 episodes as unwatched?").waitForExistence(timeout: 8))
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Playback positions"))
        .firstMatch.exists)
    capture(app, "Season - Confirm Position Reset")
    select(app.buttons["Cancel"].firstMatch, in: app)
    XCTAssertFalse(app.buttons["player-play"].exists)
  }

  @MainActor
  func testCollectionKeepsServerOrderAndHasNoEditingActions() {
    let app = launch()
    defer { app.terminate() }
    select(app.buttons["collection-00000000-0000-4000-8000-000000000030"], in: app)
    XCTAssertTrue(app.staticTexts["Test Collection"].firstMatch.waitForExistence(timeout: 8))
    let movie = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Aurelia Test Movie"))
      .firstMatch
    let series = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "Aurelia Test Series")
    ).firstMatch
    XCTAssertTrue(movie.waitForExistence(timeout: 8))
    XCTAssertTrue(series.exists)
    XCTAssertLessThan(movie.frame.minX, series.frame.minX)
    XCTAssertFalse(app.buttons["Edit Collection"].exists)
    XCTAssertFalse(app.buttons["Delete Collection"].exists)
    capture(app, "Collections - Ordered Read Only Titles")
    select(movie, in: app)
    expectFocus(app.buttons["detail-play"])
    XCTAssertTrue(app.staticTexts["Aurelia Test Movie"].firstMatch.exists)
  }

  @MainActor
  func testSearchTextAndFavoriteFilterCanBeCombinedAndReset() {
    let app = launch()
    defer { app.terminate() }
    selectTab(app, title: "Search")
    let search = app.textFields["library-search"]
    select(search, in: app)
    search.typeText("Aurelia Test Movie\n")
    // The simulator keyboard may ignore a Menu press while it is still settling.
    for _ in 0..<3 where app.keyboards.firstMatch.exists {
      remote.press(.menu)
      if app.keyboards.firstMatch.waitForNonExistence(timeout: 3) { break }
    }
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    let found = app.buttons["catalog-\(movieID)"]
    XCTAssertTrue(found.waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["catalog-\(seriesID)"].waitForNonExistence(timeout: 5))
    select(app.buttons["browse-filters"], in: app)
    let favorite = app.switches["Favorites Only"]
    select(favorite, in: app)
    XCTAssertTrue(isOn(favorite))
    select(app.buttons["filters-done"], in: app)
    XCTAssertTrue(app.staticTexts["No matching titles."].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["Favorites"].firstMatch.exists)
    capture(app, "Search - Combined Favorite Filter")
    select(app.buttons["browse-clear"], in: app)
    XCTAssertTrue(found.waitForExistence(timeout: 8))
    XCTAssertFalse(
      app.buttons["catalog-\(seriesID)"].exists, "Clearing filters must preserve search text.")
    capture(app, "Search - Reset Preserves Query")
  }

  @MainActor
  func testPlaybackPreferencesPersistOnReentry() {
    let app = launch()
    defer { app.terminate() }
    selectTab(app, title: "Test Viewer")
    select(app.buttons["profile-playback-settings"], in: app)
    let resume = app.switches["settings-resume"]
    let next = app.switches["settings-next"]
    XCTAssertTrue(resume.waitForExistence(timeout: 8))
    XCTAssertTrue(isOn(resume))
    XCTAssertTrue(isOn(next))
    select(resume, in: app)
    XCTAssertFalse(isOn(resume))
    select(next, in: app)
    XCTAssertFalse(isOn(next))
    capture(app, "Settings - Playback Preferences")
    remote.press(.menu)
    select(app.buttons["profile-playback-settings"], in: app)
    XCTAssertTrue(resume.waitForExistence(timeout: 8))
    XCTAssertFalse(isOn(resume))
    XCTAssertFalse(isOn(next))
    XCTAssertTrue(app.buttons["Restore Playback Defaults"].exists)
  }

  @MainActor
  func testAutomaticNextEpisodeUsesServerQueueAfterNaturalEnd() {
    let app = launch("nextEpisode")
    defer { app.terminate() }
    openSeries(app)
    select(app.buttons["detail-play"], in: app)
    let nextTitle = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "S02 E03"))
      .firstMatch
    XCTAssertTrue(
      nextTitle.waitForExistence(timeout: 22),
      "Natural episode end must advance to the next server queue item.")
    remote.press(.playPause)
    XCTAssertTrue(app.buttons["player-play"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["player-play"].label, "Play")
    XCTAssertTrue(nextTitle.exists)
    XCTAssertTrue(app.progressIndicators["player-loading"].waitForNonExistence(timeout: 4))
    capture(app, "Player - Automatic Next Server Episode")
    remote.press(.menu)
    expectFocus(app.buttons["detail-play"])
  }

  @MainActor
  private func launch(_ scenario: String = "library") -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--aurelia-ui-testing"]
    app.launchEnvironment["AURELIA_TV_UI_SCENARIO"] = scenario
    app.launchEnvironment["AURELIA_TV_UI_SUITE"] = "Aurelia.TV.Library.UI.Tests.\(UUID())"
    app.launch()
    XCTAssertTrue(app.buttons["Home"].firstMatch.waitForExistence(timeout: 10))
    return app
  }

  @MainActor
  private func openMovie(_ app: XCUIApplication) {
    selectTab(app, title: "Movies")
    select(app.buttons["catalog-\(movieID)"], in: app)
    expectFocus(app.buttons["detail-play"])
  }

  @MainActor
  private func openSeries(_ app: XCUIApplication) {
    selectTab(app, title: "TV Shows")
    select(app.buttons["catalog-\(seriesID)"], in: app)
    expectFocus(app.buttons["detail-play"])
    XCTAssertEqual(app.buttons["detail-play"].label, "Resume S02 E02")
  }

  @MainActor
  private func openMore(_ app: XCUIApplication) {
    select(app.buttons["detail-more"], in: app)
    XCTAssertTrue(app.buttons["Mark as Watched"].exists || app.buttons["Mark as Unwatched"].exists)
  }

  @MainActor
  private func selectTab(_ app: XCUIApplication, title: String) {
    let titles = ["Home", "Movies", "TV Shows", "Search", "Test Viewer"]
    for _ in 0..<14 {
      if titles.contains(where: { app.buttons[$0].firstMatch.hasFocus }) { break }
      remote.press(.up)
    }
    guard let current = titles.firstIndex(where: { app.buttons[$0].firstMatch.hasFocus }),
      let target = titles.firstIndex(of: title)
    else {
      attachHierarchy(app)
      return XCTFail("Native tab bar is not reachable.")
    }
    if current != target {
      for _ in 0..<abs(current - target) { remote.press(current < target ? .right : .left) }
    }
    expectFocus(app.buttons[title].firstMatch)
    remote.press(.select)
  }

  /// Uses focused element geometry only to choose a direction; all navigation
  /// and activation still pass through the native focus engine and XCUIRemote.
  @MainActor
  private func focus(
    _ target: XCUIElement, in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    var previousFocus: String?
    var previousDirection: XCUIRemote.Button?
    for _ in 0..<30 {
      if target.exists && hasNativeFocus(target) { return }
      guard target.exists else {
        remote.press(.down)
        continue
      }
      let current = app.descendants(matching: .any).matching(
        NSPredicate(format: "hasFocus == true")
      ).firstMatch
      guard current.exists else {
        remote.press(.down)
        continue
      }
      // A horizontal move on tvOS's native tab bar changes the active tab
      // immediately. Enter this tab's content before steering toward its UI.
      if app.tabBars.descendants(matching: .any).matching(
        NSPredicate(format: "hasFocus == true")
      ).firstMatch.exists {
        remote.press(.down)
        continue
      }
      // Unrealized form or menu rows report an empty control frame; their row
      // cell still has real geometry for choosing the next direction.
      let row = rowCell(containing: target, in: app)
      let destination = target.frame.isEmpty && row.exists ? row.frame : target.frame
      let source = current.frame
      let dx = destination.midX - source.midX
      let dy = destination.midY - source.midY
      let identity = "\(current.identifier)|\(current.label)|\(source)"
      let horizontal: XCUIRemote.Button = dx > 0 ? .right : .left
      let vertical: XCUIRemote.Button = dy > 0 ? .down : .up
      var direction = abs(dx) > abs(dy) ? horizontal : vertical
      if identity == previousFocus, direction == previousDirection {
        direction = direction == horizontal ? vertical : horizontal
      }
      previousFocus = identity
      previousDirection = direction
      remote.press(direction)
    }
    attachHierarchy(app)
    expectFocus(target, file: file, line: line)
  }

  @MainActor
  private func select(
    _ target: XCUIElement, in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    focus(target, in: app, file: file, line: line)
    remote.press(.select)
  }

  @MainActor
  private func expectFocus(
    _ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(
      element.waitForExistence(timeout: 8), "Missing element \(element).", file: file, line: line)
    let result = XCTWaiter.wait(
      for: [
        XCTNSPredicateExpectation(
          predicate: NSPredicate { _, _ in self.hasNativeFocus(element) }, object: nil)
      ], timeout: 6)
    XCTAssertEqual(
      result, .completed, "Expected native focus on \(element).", file: file, line: line)
  }

  /// tvOS appends punctuation to a dialog title's accessibility label.
  @MainActor
  private func dialogText(_ app: XCUIApplication, _ title: String) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
  }

  @MainActor
  private func isOn(_ element: XCUIElement) -> Bool {
    ["1", "true", "On"].contains(element.value as? String ?? "")
  }

  /// SwiftUI Menu exposes its label as a Button whose private content view is
  /// the native focus item. The focused descendant must belong to this control.
  /// Menu items and form controls are instead children of the focused row cell.
  @MainActor
  private func hasNativeFocus(_ element: XCUIElement) -> Bool {
    element.hasFocus
      || element.descendants(matching: .any).matching(
        NSPredicate(format: "hasFocus == true")
      ).firstMatch.exists
      || rowCell(containing: element, in: XCUIApplication(), focused: true).exists
  }

  @MainActor
  private func rowCell(
    containing element: XCUIElement, in app: XCUIApplication, focused: Bool = false
  ) -> XCUIElement {
    guard element.exists else { return app.cells.matching(NSPredicate(value: false)).firstMatch }
    let identifier = element.identifier
    let match =
      identifier.isEmpty
      ? NSPredicate(
        format: "elementType == %d AND label == %@", element.elementType.rawValue, element.label)
      : NSPredicate(
        format: "elementType == %d AND identifier == %@", element.elementType.rawValue, identifier)
    let cells = focused ? app.cells.matching(NSPredicate(format: "hasFocus == true")) : app.cells
    return cells.containing(match).firstMatch
  }

  @MainActor
  private func capture(_ app: XCUIApplication, _ name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }

  @MainActor
  private func attachHierarchy(_ app: XCUIApplication) {
    let description = app.debugDescription
    print(description)
    let hierarchy = XCTAttachment(string: description)
    hierarchy.name = "Library focus hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
  }
}
