import XCTest

/// Remote-only coverage of library actions through the production views. Each
/// launch uses an isolated synthetic server and a unique preference domain.
final class TVLibraryUITests: XCTestCase {
  private let movieID = "00000000-0000-4000-8000-000000000010"
  private let seriesID = "00000000-0000-4000-8000-000000000020"
  private let resumeID = "00000000-0000-4000-8000-000000000142"
  @MainActor private var remote: XCUIRemote { .shared }

  @MainActor
  func testContinueWatchingUsesServerTargetOnceWithoutHeaderButtons() {
    let app = launch()
    defer { app.terminate() }
    let resume = app.buttons["home-continueWatching-\(resumeID)"]
    XCTAssertTrue(resume.waitForExistence(timeout: 10))
    XCTAssertEqual(app.buttons.matching(identifier: "home-continueWatching-\(resumeID)").count, 1)
    XCTAssertFalse(app.buttons["home-continueWatching-\(seriesID)"].exists)
    XCTAssertEqual(
      app.buttons.matching(NSPredicate(format: "label == %@", "See All")).count, 0,
      "Home rows must not carry header buttons.")
    XCTAssertTrue(app.buttons["home-hero"].exists)
    capture(app, "Home - Hero and Continue Watching")
    // Selecting a Continue Watching card resumes playback without the detail page.
    select(resume, in: app)
    expectFocus(app.buttons["player-play"])
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "S02 E02")).firstMatch
        .exists)
    XCTAssertFalse(app.buttons["detail-play"].exists)
    remote.press(.menu)
    expectFocus(resume)
  }

  @MainActor
  func testHomeRowsMoveFreelyWithoutSnappingBack() {
    let app = launch()
    defer { app.terminate() }
    let hero = app.buttons["home-hero"]
    XCTAssertTrue(hero.waitForExistence(timeout: 10))
    for _ in 0..<3 where !hasNativeFocus(hero) { remote.press(.down) }
    expectFocus(hero)
    let resume = app.buttons["home-continueWatching-\(resumeID)"]
    // Genre shelves come from the preloaded catalog, after Continue Watching as on the Mac.
    let genre = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "home-genre-Drama-")
    ).firstMatch
    XCTAssertTrue(genre.waitForExistence(timeout: 10))
    let collection = app.buttons["collection-00000000-0000-4000-8000-000000000030"]
    let recent = app.buttons["home-recentlyAdded-\(movieID)"]
    for target in [resume, genre, collection, recent] {
      remote.press(.down)
      expectFocus(target)
    }
    capture(app, "Home - Recently Added Row Focus")
    for target in [collection, genre, resume, hero] {
      remote.press(.up)
      expectFocus(target)
    }
  }

  @MainActor
  func testTabBarKeepsFocusWhileSwitchingTabs() {
    let app = launch()
    defer { app.terminate() }
    for _ in 0..<6 where !app.buttons["Home"].firstMatch.hasFocus { remote.press(.up) }
    expectFocus(app.buttons["Home"].firstMatch)
    remote.press(.right)
    expectFocus(app.buttons["Movies"].firstMatch)
    remote.press(.left)
    expectFocus(app.buttons["Home"].firstMatch)
    remote.press(.right)
    remote.press(.select)
    select(app.buttons["catalog-\(movieID)"], in: app)
    expectFocus(app.buttons["detail-play"])
    remote.press(.up)
    expectFocus(app.buttons["Movies"].firstMatch)
    remote.press(.left)
    expectFocus(app.buttons["Home"].firstMatch)
  }

  @MainActor
  func testOfflineContinueWatchingStaysReachableAndExplains() {
    let app = launch("offline")
    defer { app.terminate() }
    let card = app.buttons["home-continueWatching-\(resumeID)"]
    XCTAssertTrue(card.waitForExistence(timeout: 10))
    select(card, in: app)
    let ok = app.buttons["OK"].firstMatch
    XCTAssertTrue(ok.waitForExistence(timeout: 5), "Selecting an offline title explains it.")
    XCTAssertFalse(app.buttons["player-play"].exists)
    capture(app, "Home - Offline Continue Watching")
    select(app.buttons["Show Details"].firstMatch, in: app)
    expectFocus(app.buttons["detail-play"])
    XCTAssertTrue(
      app.staticTexts["Media drive disconnected"].firstMatch.waitForExistence(timeout: 5))
  }

  @MainActor
  func testFavoriteAndSingleTitleWatchActionsUpdateMenus() {
    let app = launch()
    defer { app.terminate() }
    openMovie(app)
    let favorite = app.buttons["detail-favorite"]
    XCTAssertEqual(favorite.label, "Add to Favorites")
    select(favorite, in: app)
    let favorited = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "Remove from Favorites"), object: favorite)
    XCTAssertEqual(XCTWaiter.wait(for: [favorited], timeout: 8), .completed)
    openMore(app)
    XCTAssertFalse(app.buttons["Add to Favorites"].exists, "Favorite has its own button.")
    select(app.buttons["Mark as Watched"], in: app)
    XCTAssertTrue(app.buttons["detail-more"].waitForExistence(timeout: 5))
    openMore(app)
    XCTAssertTrue(app.buttons["Mark as Unwatched"].waitForExistence(timeout: 8))
    capture(app, "Details - Favorite and Watched Actions")
    select(app.buttons["Mark as Unwatched"], in: app)
    openMore(app)
    XCTAssertTrue(app.buttons["Mark as Watched"].waitForExistence(timeout: 8))
    remote.press(.menu)
    XCTAssertTrue(app.buttons["Mark as Watched"].waitForNonExistence(timeout: 5))
    expectFocus(app.buttons["detail-more"])
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
    XCTAssertTrue(app.buttons["detail-more"].waitForExistence(timeout: 5))
    openMore(app)
    select(app.buttons["Mark Season 2 as Unwatched"], in: app)
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
    let resume = app.buttons["settings-resume"]
    let next = app.buttons["settings-next"]
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
    let rate = app.buttons["settings-rate"]
    XCTAssertEqual(rate.value as? String, "1x")
    select(rate, in: app)
    let faster = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "1.25x"), object: rate)
    XCTAssertEqual(XCTWaiter.wait(for: [faster], timeout: 3), .completed)
    select(app.buttons["settings-defaults"], in: app)
    XCTAssertTrue(isOn(resume))
    XCTAssertEqual(rate.value as? String, "1x")
  }

  @MainActor
  func testMovieTrailersExtrasCastAndAbout() {
    let app = launch()
    defer { app.terminate() }
    openMovie(app)
    let trailer = app.buttons["supplement-00000000-0000-4000-8000-000000000060"]
    let extra = app.buttons["supplement-00000000-0000-4000-8000-000000000061"]
    XCTAssertTrue(trailer.waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["Trailers"].firstMatch.exists)
    remote.press(.down)
    expectFocus(trailer)
    capture(app, "Details - Trailers and Extras")
    // A trailer plays in the normal player and Back returns to it.
    remote.press(.select)
    expectFocus(app.buttons["player-play"])
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Official Trailer"))
        .firstMatch.exists)
    XCTAssertTrue(app.progressIndicators["player-loading"].waitForNonExistence(timeout: 8))
    let surface = app.descendants(matching: .any)["player-surface"]
    for _ in 0..<3 where surface.exists {
      remote.press(.menu)
      if surface.waitForNonExistence(timeout: 3) { break }
    }
    expectFocus(trailer)
    remote.press(.down)
    expectFocus(extra)
    remote.press(.down)
    let lead = app.buttons["person-lead"]
    expectFocus(lead)
    XCTAssertTrue(lead.label.contains("Main Character"), "Credits of one person are merged.")
    capture(app, "Details - Cast and Crew")
    // Re-entering a shelf starts at its first card, not under the previous focus.
    remote.press(.right)
    expectFocus(app.buttons["person-support"])
    remote.press(.up)
    expectFocus(extra)
    remote.press(.down)
    expectFocus(lead)
    remote.press(.down)
    let about = app.buttons["detail-about"]
    expectFocus(about)
    remote.press(.select)
    XCTAssertTrue(app.staticTexts["FSK 12"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Synthetic Studio"].exists)
    XCTAssertTrue(app.staticTexts["US"].exists)
    capture(app, "Details - About Sheet")
    remote.press(.menu)
    XCTAssertTrue(app.staticTexts["FSK 12"].waitForNonExistence(timeout: 5))
    expectFocus(about)
  }

  @MainActor
  func testStartOverPlaysFromTheBeginning() {
    let app = launch()
    defer { app.terminate() }
    openSeries(app)
    openMore(app)
    // Start Over is the first, initially focused entry of the "…" menu.
    let startOver = app.buttons.matching(NSPredicate(format: "label == %@", "Start Over"))
      .firstMatch
    XCTAssertTrue(startOver.waitForExistence(timeout: 5))
    remote.press(.up)
    expectFocus(startOver)
    remote.press(.select)
    expectFocus(app.buttons["player-play"])
    XCTAssertTrue(app.progressIndicators["player-loading"].waitForNonExistence(timeout: 8))
    remote.press(.playPause)
    let timeline = app.buttons["player-timeline"]
    XCTAssertTrue(timeline.waitForExistence(timeout: 5))
    let time = (timeline.value as? String ?? "").components(separatedBy: " of ")[0]
    let seconds = time.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
    XCTAssertLessThan(seconds, 30, "Start Over ignores the saved 1:30 position.")
  }

  @MainActor
  func testSeasonExtrasFollowTheSelectedSeason() {
    let app = launch()
    defer { app.terminate() }
    openSeries(app)
    let seasonExtra = app.buttons["supplement-00000000-0000-4000-8000-000000000062"]
    XCTAssertTrue(seasonExtra.waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["Season 2 Extras"].firstMatch.exists)
    remote.press(.down)
    expectFocus(app.buttons["season-option-2"])
    remote.press(.left)
    expectFocus(app.buttons["season-option-1"])
    XCTAssertTrue(seasonExtra.waitForNonExistence(timeout: 3), "Season extras follow the season.")
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
    let resume = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "Resume S02 E02"),
      object: app.buttons["detail-play"])
    XCTAssertEqual(XCTWaiter.wait(for: [resume], timeout: 8), .completed)
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
    if result != .completed {
      let focused = XCUIApplication().descendants(matching: .any).matching(
        NSPredicate(format: "hasFocus == true")
      ).firstMatch
      print("Focused instead: \(focused.exists ? focused.debugDescription : "nothing")")
    }
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
    // Menu rows may carry a symbol name as identifier; their text label is stable.
    let identifier = element.identifier
    let label = element.label
    let match: NSPredicate
    switch (identifier.isEmpty, label.isEmpty) {
    case (false, false):
      match = NSPredicate(
        format: "elementType == %d AND (identifier == %@ OR label == %@)",
        element.elementType.rawValue, identifier, label)
    case (true, _):
      match = NSPredicate(
        format: "elementType == %d AND label == %@", element.elementType.rawValue, label)
    case (false, true):
      match = NSPredicate(
        format: "elementType == %d AND identifier == %@", element.elementType.rawValue, identifier)
    }
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
