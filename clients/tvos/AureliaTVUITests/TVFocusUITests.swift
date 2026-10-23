import UIKit
import XCTest

final class TVFocusUITests: XCTestCase {
  private let movieID = "00000000-0000-4000-8000-000000000010"
  private let seriesID = "00000000-0000-4000-8000-000000000020"

  @MainActor
  func testEveryPlayerControlAndCompactFrames() {
    let app = launch()
    defer { app.terminate() }
    openMoviePlayer(app)
    let remote = XCUIRemote.shared
    remote.press(.playPause)
    expectFocus(app.buttons["player-play"])
    for (direction, identifier) in [
      (XCUIRemote.Button.left, "backward"), (.right, "play"), (.right, "forward"),
      (.up, "rate"), (.left, "close"), (.right, "rate"), (.right, "audio"),
      (.right, "subtitles"), (.right, "sleep"),
    ] {
      remote.press(direction)
      let button = app.buttons["player-\(identifier)"]
      expectFocus(button)
      XCTAssertLessThanOrEqual(button.frame.width, 125)
      XCTAssertLessThanOrEqual(button.frame.height, 90)
    }
    shot(app, "Player - Compact Controls and Subtitle Focus")
    remote.press(.menu)
    expectFocus(app.buttons["detail-play"])
  }

  @MainActor
  func testHiddenControlsAndFirstPressOnlyReveals() {
    let app = launch()
    defer { app.terminate() }
    openMoviePlayer(app)
    let play = app.buttons["player-play"]
    XCTAssertTrue(play.waitForNonExistence(timeout: 9))
    assertUncoveredFrame(app)
    shot(app, "Player - Hidden Controls Uncovered Frame")
    XCUIRemote.shared.press(.select)
    expectFocus(play)
    XCTAssertEqual(play.label, "Pause", "Select on the hidden surface must only reveal controls.")
    XCTAssertTrue(play.waitForNonExistence(timeout: 9))
    // Up and down only reveal the controls.
    XCUIRemote.shared.press(.down)
    expectFocus(play)
    XCTAssertEqual(play.label, "Pause")
    let base = seconds(app.buttons["player-timeline"])
    XCTAssertTrue(play.waitForNonExistence(timeout: 9))
    // Left and right on hidden controls skip without revealing them; a slim
    // indicator shows the new position and further presses keep skipping.
    XCUIRemote.shared.press(.right)
    let skip = app.descendants(matching: .any)["player-skip"]
    XCTAssertTrue(skip.waitForExistence(timeout: 3))
    XCTAssertFalse(play.exists, "Skipping must not reveal the controls.")
    XCTAssertGreaterThanOrEqual(seconds(skip), base + 10)
    let afterOne = seconds(skip)
    XCUIRemote.shared.press(.right)
    let skipped = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in skip.exists && self.seconds(skip) >= afterOne + 10 },
      object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [skipped], timeout: 3), .completed)
    shot(app, "Player - Skip From Hidden Controls")
    XCUIRemote.shared.press(.left)
    let back = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in skip.exists && self.seconds(skip) <= afterOne + 3 },
      object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [back], timeout: 3), .completed)
    XCTAssertTrue(skip.waitForNonExistence(timeout: 5), "The indicator fades out by itself.")
    XCTAssertFalse(play.exists)
    XCUIRemote.shared.press(.playPause)
    XCTAssertTrue(play.waitForExistence(timeout: 5))
    XCTAssertEqual(play.label, "Play")
    XCTAssertFalse(play.waitForNonExistence(timeout: 5), "Paused controls must remain visible.")
    shot(app, "Player - Paused Controls")
  }

  @MainActor
  func testGridEntersAtFirstTitleFromTabBar() {
    let app = launch()
    defer { app.terminate() }
    selectTab(app, title: "Movies")
    let first = app.buttons["catalog-\(movieID)"]
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    // Leave the grid from the third column, then come back down from the tab bar.
    for _ in 0..<6 where !first.hasFocus { XCUIRemote.shared.press(.down) }
    expectFocus(first)
    XCUIRemote.shared.press(.right)
    XCUIRemote.shared.press(.right)
    XCTAssertFalse(first.hasFocus)
    XCUIRemote.shared.press(.up)
    expectFocus(app.buttons["Movies"].firstMatch)
    // Give the tab bar its expand animation, as a person would.
    _ = XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: NSPredicate(value: false), object: nil)],
      timeout: 1)
    XCUIRemote.shared.press(.down)
    expectFocus(first)
    shot(app, "Library - Grid Entry")
  }

  @MainActor
  func testTimelineSeeksAndReturnsToTransport() {
    let app = launch()
    defer { app.terminate() }
    openMoviePlayer(app)
    let remote = XCUIRemote.shared
    remote.press(.right)
    expectFocus(app.buttons["player-forward"])
    remote.press(.down)
    let timeline = app.buttons["player-timeline"]
    expectFocus(timeline)
    remote.press(.playPause)
    let before = seconds(timeline)
    remote.press(.right)
    XCTAssertEqual(seconds(timeline), before + 10)
    remote.press(.left)
    XCTAssertEqual(seconds(timeline), before)
    XCTAssertFalse(timeline.waitForNonExistence(timeout: 5))
    shot(app, "Player - Focused Timeline")
    remote.press(.down)
    expectFocus(app.buttons["player-forward"])
  }

  @MainActor
  func testAudioAndSubtitleMenusScrollAndKeepControlsVisible() {
    let app = launch()
    defer { app.terminate() }
    openMoviePlayer(app)
    let remote = XCUIRemote.shared
    remote.press(.up)
    remote.press(.right)
    expectFocus(app.buttons["player-audio"])
    remote.press(.select)
    expectFocus(app.buttons["player-audioTrack(1)"])
    for _ in 1..<14 { remote.press(.down) }
    let lastAudio = app.buttons["player-audioTrack(14)"]
    expectFocus(lastAudio)
    XCTAssertTrue(lastAudio.isHittable)
    XCTAssertFalse(lastAudio.waitForNonExistence(timeout: 5))
    shot(app, "Player - Long Audio Menu")
    remote.press(.select)
    expectFocus(app.buttons["player-audio"])
    remote.press(.right)
    expectFocus(app.buttons["player-subtitles"])
    remote.press(.select)
    expectFocus(app.buttons["player-subtitleTrack(-1)"])
    for _ in 0..<14 { remote.press(.down) }
    expectFocus(app.buttons["player-subtitleTrack(14)"])
    shot(app, "Player - Long Subtitle Menu")
    remote.press(.menu)
    expectFocus(app.buttons["player-subtitles"])
    XCTAssertTrue(
      app.buttons["player-play"].exists, "Menu closes the track menu before the player.")
    remote.press(.menu)
    expectFocus(app.buttons["detail-play"])
  }

  @MainActor
  func testDelayedSeriesResumeAndReturnFocus() {
    let app = launch("delayed")
    defer { app.terminate() }
    openSeries(app)
    let resume = app.buttons["detail-play"]
    expectFocus(resume)
    // Focus stays on Play while the delayed plan arrives; only the label updates.
    let loaded = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "Resume S02 E02"), object: resume)
    XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
    expectFocus(resume)
    XCTAssertTrue(resume.isEnabled)
    XCTAssertLessThanOrEqual(resume.frame.height, 90)
    shot(app, "Series - Resume Focus After Delayed Load")
    XCUIRemote.shared.press(.select)
    expectFocus(app.buttons["player-play"])
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "S02 E02")).firstMatch
        .exists)
    XCUIRemote.shared.press(.menu)
    expectFocus(resume)
  }

  @MainActor
  func testEpisodeSelectionAndSeasonReturnToResume() {
    let app = launch()
    defer { app.terminate() }
    openSeries(app)
    let remote = XCUIRemote.shared
    remote.press(.down)
    // The season bar is entered at the current season.
    let seasonTwo = app.buttons["season-option-2"]
    expectFocus(seasonTwo)
    // The shelf opens at the resume episode, so moving down lands on it.
    remote.press(.down)
    let second = app.buttons["detail-episode-00000000-0000-4000-8000-000000000142"]
    expectFocus(second)
    remote.press(.right)
    let third = app.buttons["detail-episode-00000000-0000-4000-8000-000000000143"]
    expectFocus(third)
    shot(app, "Series - Episode Shelf Focus")
    remote.press(.select)
    expectFocus(app.buttons["player-play"])
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "S02 E03")).firstMatch
        .exists)
    closePlayer(app)
    expectFocus(third)
    remote.press(.left)
    expectFocus(second)
    remote.press(.left)
    let first = app.buttons["detail-episode-00000000-0000-4000-8000-000000000141"]
    expectFocus(first)
    remote.press(.up)
    expectFocus(seasonTwo)
    // Moving across the bar switches the season immediately, without a dialog.
    remote.press(.left)
    let seasonOne = app.buttons["season-option-1"]
    expectFocus(seasonOne)
    XCTAssertTrue(
      app.buttons["detail-episode-00000000-0000-4000-8000-000000000121"].waitForExistence(
        timeout: 2))
    XCTAssertTrue(seasonOne.isSelected)
    shot(app, "Series - Season Bar")
    remote.press(.up)
    expectFocus(app.buttons["detail-play"])
    XCTAssertEqual(app.buttons["detail-play"].label, "Resume S02 E02")
  }

  @MainActor
  func testUnavailableTargetAndDisabledPlayerActions() {
    let app = launch("offline")
    openSeries(app)
    // Unavailable titles keep their place in focus and explain themselves.
    let play = app.buttons["detail-play"]
    expectFocus(play)
    XCTAssertTrue(
      app.staticTexts["Media drive disconnected"].firstMatch.waitForExistence(timeout: 5))
    shot(app, "Series - Offline Target")
    XCUIRemote.shared.press(.select)
    let ok = app.buttons["OK"].firstMatch
    XCTAssertTrue(ok.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Connect the drive"))
        .firstMatch.exists)
    XCTAssertFalse(app.buttons["player-play"].exists)
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(ok.waitForNonExistence(timeout: 5))
    expectFocus(play)
    XCUIRemote.shared.press(.down)
    expectFocus(app.buttons["season-option-2"])
    app.terminate()

    let limited = launch("limitedTracks")
    defer { limited.terminate() }
    openMoviePlayer(limited)
    XCUIRemote.shared.press(.right)
    expectFocus(limited.buttons["player-forward"])
    XCTAssertFalse(limited.buttons["player-audio"].isEnabled)
    XCTAssertFalse(limited.buttons["player-subtitles"].isEnabled)
    XCUIRemote.shared.press(.left)
    expectFocus(limited.buttons["player-play"])
  }

  @MainActor
  func testProfileAndPosterFocusAppearance() {
    let app = launch("profiles")
    let profile = app.buttons["profile-00000000-0000-4000-8000-000000000002"]
    expectFocus(profile)
    shot(app, "Profiles - Avatar Focus")
    let profiles = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "profile-0"))
    XCTAssertEqual(profiles.count, 2)
    let center =
      (profiles.element(boundBy: 0).frame.midX + profiles.element(boundBy: 1).frame.midX) / 2
    XCTAssertEqual(center, app.frame.midX, accuracy: 40, "Profiles must be centered.")
    XCUIRemote.shared.press(.select)
    let one = app.buttons["pin-key-1"]
    expectFocus(one)
    XCTAssertFalse(app.keyboards.firstMatch.exists, "The PIN uses the on-screen keypad.")
    // OK is always available and the field shows no placeholder dots, so neither hints at the
    // PIN's length.
    XCTAssertTrue(app.buttons["profile-continue"].isEnabled)
    XCTAssertEqual(app.otherElements["profile-pin"].value as? String, "0 digits entered")
    shot(app, "Profiles - PIN Keypad")
    // Enter 1-2-3-4 with the remote and continue with OK.
    let remote = XCUIRemote.shared
    remote.press(.select)
    remote.press(.right)
    remote.press(.select)
    remote.press(.right)
    remote.press(.select)
    remote.press(.down)
    remote.press(.left)
    remote.press(.left)
    expectFocus(app.buttons["pin-key-4"])
    remote.press(.select)
    XCTAssertEqual(app.otherElements["profile-pin"].value as? String, "4 digits entered")
    remote.press(.down)
    remote.press(.down)
    remote.press(.right)
    remote.press(.right)
    expectFocus(app.buttons["profile-continue"])
    remote.press(.select)
    XCTAssertTrue(app.buttons["Home"].firstMatch.waitForExistence(timeout: 10))
    app.terminate()

    let library = launch()
    defer { library.terminate() }
    selectTab(library, title: "Movies")
    focusPoster(library, id: movieID)
    shot(library, "Library - Poster Focus")
  }

  @MainActor
  func testHomeCollectionsAndFavoritesAction() {
    let app = launch()
    defer { app.terminate() }
    XCTAssertTrue(app.staticTexts["Continue Watching"].firstMatch.waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["Recently Added"].firstMatch.exists)
    XCTAssertTrue(app.buttons["collection-00000000-0000-4000-8000-000000000030"].exists)
    shot(app, "Home - Library Rows")
    selectTab(app, title: "Movies")
    focusPoster(app, id: movieID)
    XCUIRemote.shared.press(.select)
    expectFocus(app.buttons["detail-play"])
    XCUIRemote.shared.press(.right)
    let favorite = app.buttons["detail-favorite"]
    expectFocus(favorite)
    XCUIRemote.shared.press(.select)
    let favorited = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "Remove from Favorites"), object: favorite)
    XCTAssertEqual(XCTWaiter.wait(for: [favorited], timeout: 8), .completed)
    XCUIRemote.shared.press(.right)
    let more = app.buttons["detail-more"]
    expectFocus(more)
    XCUIRemote.shared.press(.select)
    expectFocus(app.buttons["Mark as Watched"])
    shot(app, "Details - Library Actions")
    XCUIRemote.shared.press(.menu)
    expectFocus(more)
  }

  @MainActor
  func testProgressSurvivesExitAndImmediateReopen() {
    let app = launch()
    defer { app.terminate() }
    openMoviePlayer(app)
    let remote = XCUIRemote.shared
    remote.press(.playPause)
    remote.press(.down)
    let timeline = app.buttons["player-timeline"]
    expectFocus(timeline)
    let initial = seconds(timeline)
    remote.press(.right)
    remote.press(.playPause)
    let advanced = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in self.seconds(timeline) >= initial + 11 }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 6), .completed)
    remote.press(.menu)
    expectFocus(app.buttons["detail-play"])
    remote.press(.select)
    expectFocus(app.buttons["player-play"])
    remote.press(.playPause)
    XCTAssertGreaterThanOrEqual(seconds(app.buttons["player-timeline"]), initial + 10)
    XCTAssertFalse(app.progressIndicators["player-loading"].exists)
    shot(app, "Player - Immediate Resume")
  }

  @MainActor
  func testPlaybackRateAndSleepMenus() {
    let app = launch()
    defer { app.terminate() }
    openMoviePlayer(app)
    let remote = XCUIRemote.shared
    remote.press(.up)
    expectFocus(app.buttons["player-rate"])
    remote.press(.select)
    let standard = app.buttons["player-rateOption(1.0)"]
    expectFocus(standard)
    remote.press(.down)
    expectFocus(app.buttons["player-rateOption(1.25)"])
    remote.press(.select)
    expectFocus(app.buttons["player-rate"])
    for _ in 0..<3 { remote.press(.right) }
    expectFocus(app.buttons["player-sleep"])
    remote.press(.select)
    expectFocus(app.buttons["player-sleepOption(0)"])
    remote.press(.down)
    remote.press(.down)
    expectFocus(app.buttons["player-sleepOption(15)"])
    shot(app, "Player - Sleep Timer Menu")
    remote.press(.menu)
    expectFocus(app.buttons["player-sleep"])
  }

  @MainActor
  private func launch(_ scenario: String = "library") -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--aurelia-ui-testing"]
    app.launchEnvironment["AURELIA_TV_UI_SCENARIO"] = scenario
    app.launchEnvironment["AURELIA_TV_UI_SUITE"] = "Aurelia.TV.UI.Tests.\(UUID().uuidString)"
    app.launch()
    return app
  }

  @MainActor
  private func focusPoster(_ app: XCUIApplication, id: String) {
    let poster = app.buttons["catalog-\(id)"]
    XCTAssertTrue(poster.waitForExistence(timeout: 10))
    for _ in 0..<3 {
      if poster.hasFocus { break }
      let focusedCard = app.buttons.matching(
        NSPredicate(
          format: "identifier BEGINSWITH %@ AND hasFocus == true", "catalog-")
      ).firstMatch
      if !focusedCard.exists { XCUIRemote.shared.press(.down) }
      for _ in 0..<4 { XCUIRemote.shared.press(.left) }
      if poster.hasFocus { break }
      XCUIRemote.shared.press(.up)
      let settled = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "hasFocus == true"), object: poster)
      if XCTWaiter.wait(for: [settled], timeout: 0.7) == .completed { break }
    }
    expectFocus(poster)
  }

  @MainActor
  private func openMoviePlayer(_ app: XCUIApplication) {
    selectTab(app, title: "Movies")
    focusPoster(app, id: movieID)
    XCUIRemote.shared.press(.select)
    expectFocus(app.buttons["detail-play"])
    XCUIRemote.shared.press(.select)
    expectFocus(app.buttons["player-play"])
  }

  @MainActor
  private func openSeries(_ app: XCUIApplication) {
    selectTab(app, title: "TV Shows")
    focusPoster(app, id: seriesID)
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(app.buttons["detail-play"].waitForExistence(timeout: 8))
    if app.buttons["detail-play"].isEnabled { expectFocus(app.buttons["detail-play"]) }
  }

  @MainActor
  private func selectTab(_ app: XCUIApplication, title: String) {
    let titles = ["Home", "Movies", "TV Shows", "Search", "Test Viewer"]
    for _ in 0..<12 {
      if titles.contains(where: { app.buttons[$0].firstMatch.hasFocus }) { break }
      XCUIRemote.shared.press(.up)
    }
    guard let current = titles.firstIndex(where: { app.buttons[$0].firstMatch.hasFocus }),
      let target = titles.firstIndex(of: title)
    else { return XCTFail("Tab bar is not reachable.") }
    if current != target {
      for _ in 0..<abs(current - target) {
        XCUIRemote.shared.press(current > target ? .left : .right)
      }
    }
    expectFocus(app.buttons[title].firstMatch)
    XCUIRemote.shared.press(.select)
  }

  @MainActor
  private func expectFocus(
    _ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line
  ) {
    if !element.exists {
      XCTAssertTrue(
        element.waitForExistence(timeout: 8), "Missing element: \(element)", file: file, line: line)
    }
    if hasNativeFocus(element) { return }
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in self.hasNativeFocus(element) }, object: nil)
    let result = XCTWaiter.wait(for: [expectation], timeout: 6)
    if result != .completed {
      let focused = XCUIApplication().descendants(matching: .any).matching(
        NSPredicate(format: "hasFocus == true")
      ).firstMatch
      print("Focused instead: \(focused.exists ? focused.debugDescription : "nothing")")
    }
    XCTAssertEqual(result, .completed, "Expected focus on \(element).", file: file, line: line)
  }

  /// Menu items are children of the focused row cell rather than focus items.
  @MainActor
  private func hasNativeFocus(_ element: XCUIElement) -> Bool {
    if element.hasFocus
      || element.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true"))
        .firstMatch.exists
    {
      return true
    }
    guard element.exists else { return false }
    let identifier = element.identifier
    let match =
      identifier.isEmpty
      ? NSPredicate(
        format: "elementType == %d AND label == %@", element.elementType.rawValue, element.label)
      : NSPredicate(
        format: "elementType == %d AND identifier == %@", element.elementType.rawValue, identifier)
    return XCUIApplication().cells.matching(NSPredicate(format: "hasFocus == true"))
      .containing(match).firstMatch.exists
  }

  /// Waits until the player has finished presenting before Back is pressed, so the
  /// press is not swallowed by the cover's transition on a cold simulator.
  @MainActor
  private func closePlayer(_ app: XCUIApplication) {
    XCTAssertTrue(app.progressIndicators["player-loading"].waitForNonExistence(timeout: 8))
    let surface = app.descendants(matching: .any)["player-surface"]
    for _ in 0..<3 where surface.exists {
      XCUIRemote.shared.press(.menu)
      if surface.waitForNonExistence(timeout: 3) { break }
    }
    XCTAssertFalse(surface.exists, "Back must close the player.")
  }

  @MainActor
  private func seconds(_ element: XCUIElement) -> Int {
    let time = (element.value as? String ?? "").components(separatedBy: " of ")[0]
    return time.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
  }

  @MainActor
  private func assertUncoveredFrame(_ app: XCUIApplication) {
    guard let image = app.screenshot().image.cgImage else {
      return XCTFail("Missing player screenshot.")
    }
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard
        let context = CGContext(
          data: bytes.baseAddress, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    XCTAssertTrue(rendered)
    // The simulated engine draws a dark solid frame. White wake/focus overlays
    // must be caught automatically as well as in the attached screenshot.
    for y in [2, height / 4, height / 2, height * 3 / 4, height - 3] {
      for x in [2, width / 4, width / 2, width * 3 / 4, width - 3] {
        let offset = (y * width + x) * 4
        XCTAssertLessThan(
          max(pixels[offset], pixels[offset + 1], pixels[offset + 2]), 96,
          "Hidden player controls cover the simulated frame at \(x),\(y).")
      }
    }
  }

  @MainActor
  private func shot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
