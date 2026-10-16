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
      (XCUIRemote.Button.left, "backward"), (.left, "close"),
      (.right, "backward"), (.right, "play"), (.right, "forward"), (.right, "audio"),
      (.right, "subtitles"),
    ] {
      remote.press(direction)
      let button = app.buttons["player-\(identifier)"]
      expectFocus(button)
      XCTAssertLessThanOrEqual(button.frame.width, 90)
      XCTAssertLessThanOrEqual(button.frame.height, 85)
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
    XCUIRemote.shared.press(.right)
    expectFocus(play)
    XCTAssertEqual(play.label, "Pause")
    XCTAssertTrue(play.waitForNonExistence(timeout: 9))
    XCUIRemote.shared.press(.playPause)
    XCTAssertTrue(play.waitForExistence(timeout: 5))
    XCTAssertEqual(play.label, "Play")
    XCTAssertFalse(play.waitForNonExistence(timeout: 5), "Paused controls must remain visible.")
    shot(app, "Player - Paused Controls")
  }

  @MainActor
  func testTimelineSeeksAndReturnsToTransport() {
    let app = launch()
    defer { app.terminate() }
    openMoviePlayer(app)
    let remote = XCUIRemote.shared
    remote.press(.right)
    expectFocus(app.buttons["player-forward"])
    remote.press(.up)
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
    remote.press(.right)
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
    XCTAssertEqual(resume.label, "Resume S02 E02")
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
    expectFocus(app.buttons["detail-season"])
    remote.press(.down)
    let first = app.buttons["detail-episode-00000000-0000-4000-8000-000000000141"]
    expectFocus(first)
    remote.press(.down)
    let second = app.buttons["detail-episode-00000000-0000-4000-8000-000000000142"]
    expectFocus(second)
    remote.press(.down)
    let third = app.buttons["detail-episode-00000000-0000-4000-8000-000000000143"]
    expectFocus(third)
    shot(app, "Series - Long Episode Row Focus")
    remote.press(.select)
    expectFocus(app.buttons["player-play"])
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "S02 E03")).firstMatch
        .exists)
    remote.press(.menu)
    expectFocus(third)
    remote.press(.up)
    expectFocus(second)
    remote.press(.up)
    expectFocus(first)
    remote.press(.up)
    expectFocus(app.buttons["detail-season"])
    remote.press(.select)
    let seasonOne = app.buttons["Season 1"].firstMatch
    XCTAssertTrue(seasonOne.waitForExistence(timeout: 5))
    for _ in 0..<3 {
      if seasonOne.hasFocus { break }
      remote.press(.down)
    }
    expectFocus(seasonOne)
    remote.press(.select)
    expectFocus(app.buttons["detail-season"])
    XCTAssertEqual(app.buttons["detail-season"].label, "Season 1")
    remote.press(.up)
    expectFocus(app.buttons["detail-play"])
    XCTAssertEqual(app.buttons["detail-play"].label, "Resume S02 E02")
  }

  @MainActor
  func testUnavailableTargetAndDisabledPlayerActions() {
    let app = launch("offline")
    openSeries(app)
    XCTAssertFalse(app.buttons["detail-play"].isEnabled)
    expectFocus(app.buttons["detail-season"])
    XCTAssertTrue(app.staticTexts["Media drive disconnected"].firstMatch.exists)
    shot(app, "Series - Offline Target")
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
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(app.secureTextFields["profile-pin"].waitForExistence(timeout: 5))
    shot(app, "Profiles - Native PIN Input")
    app.terminate()

    let library = launch()
    defer { library.terminate() }
    selectTab(library, title: "Movies")
    focusPoster(library, id: movieID)
    shot(library, "Library - Poster Focus")
  }

  @MainActor
  private func launch(_ scenario: String = "library") -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--aurelia-ui-testing"]
    app.launchEnvironment["AURELIA_TV_UI_SCENARIO"] = scenario
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
    let movies = app.buttons["Movies"].firstMatch
    let shows = app.buttons["TV Shows"].firstMatch
    let profile = app.buttons["Test Viewer"].firstMatch
    for _ in 0..<8 {
      if movies.hasFocus || shows.hasFocus || profile.hasFocus { break }
      XCUIRemote.shared.press(.up)
    }
    if title == "Movies" {
      if profile.hasFocus { XCUIRemote.shared.press(.left) }
      if shows.hasFocus { XCUIRemote.shared.press(.left) }
      expectFocus(movies)
    } else {
      if movies.hasFocus { XCUIRemote.shared.press(.right) }
      if profile.hasFocus { XCUIRemote.shared.press(.left) }
      expectFocus(shows)
    }
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
    if element.hasFocus { return }
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hasFocus == true"), object: element)
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: 6), .completed,
      "Expected focus on \(element).", file: file, line: line)
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
