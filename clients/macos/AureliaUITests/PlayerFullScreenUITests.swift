import XCTest

final class PlayerFullScreenUITests: XCTestCase {
  @MainActor
  func testFWorksAfterControlClicksAndSharesTheFullScreenButton() {
    let app = launchPlayer()
    defer { app.terminate() }
    let window = app.windows.firstMatch
    let originalFrame = window.frame
    let fullScreen = app.buttons["player-fullscreen"]

    // The transport button, rather than the video, owns keyboard focus now.
    app.buttons["player-play-pause"].click()
    app.typeKey("f", modifierFlags: [])
    assertFullScreenLabel(app, "Exit Full Screen")
    shot(app, "Player - F Enters Native Full Screen after a Control Click")
    XCTAssertGreaterThan(window.frame.height, originalFrame.height)

    fullScreen.click()
    assertFullScreenLabel(app, "Enter Full Screen")
    app.typeKey("f", modifierFlags: .shift)
    assertFullScreenLabel(app, "Exit Full Screen")
    app.typeKey("f", modifierFlags: [])
    assertFullScreenLabel(app, "Enter Full Screen")
    XCTAssertEqual(window.frame.width, originalFrame.width, accuracy: 4)
    XCTAssertEqual(window.frame.height, originalFrame.height, accuracy: 4)

    // Returning to the library retires the player's monitor immediately.
    app.buttons["player-back"].click()
    XCTAssertTrue(app.descendants(matching: .any)["native-player"].waitForNonExistence(timeout: 8))
    let libraryFrame = window.frame
    app.typeKey("f", modifierFlags: [])
    XCTAssertEqual(window.frame, libraryFrame)
  }

  @MainActor
  func testFTogglesWithHiddenControlsAndBackRestoresTheLibraryWindow() {
    let app = launchPlayer()
    defer { app.terminate() }
    let window = app.windows.firstMatch
    let originalFrame = window.frame
    let transport = app.buttons["player-play-pause"]
    let video = window.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.35))
    video.click()
    XCTAssertTrue(transport.waitForNonExistence(timeout: 12))
    app.typeKey("f", modifierFlags: [])
    assertFullScreenLabel(app, "Exit Full Screen")
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.35)).click()
    XCTAssertTrue(transport.waitForNonExistence(timeout: 12))
    app.typeKey("f", modifierFlags: [])
    assertFullScreenLabel(app, "Enter Full Screen")
    shot(app, "Player - F Returns to Window from Hidden Controls")

    app.typeKey("f", modifierFlags: [])
    assertFullScreenLabel(app, "Exit Full Screen")
    app.buttons["player-back"].click()
    XCTAssertTrue(app.descendants(matching: .any)["native-player"].waitForNonExistence(timeout: 8))
    let restored = NSPredicate { _, _ in
      abs(window.frame.width - originalFrame.width) < 4
        && abs(window.frame.height - originalFrame.height) < 4
    }
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: restored, object: nil)], timeout: 8),
      .completed)
  }

  @MainActor
  func testFIsAvailableToNoteEditingNativeMenusAndOtherWindows() {
    let app = launchPlayer()
    defer { app.terminate() }
    let playerWindow = app.windows.containing(.any, identifier: "native-player").firstMatch
    let originalFrame = playerWindow.frame
    app.buttons["player-notes"].click()
    let note = app.textFields["scene-note-text"]
    XCTAssertTrue(note.waitForExistence(timeout: 5))
    note.click()
    note.typeText("f F a film")
    XCTAssertEqual(note.value as? String, "f F a film")
    XCTAssertEqual(playerWindow.frame, originalFrame)
    shot(app, "Player - F Types into a Scene Note")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(note.waitForNonExistence(timeout: 5))

    app.buttons["player-subtitle-menu"].click()
    let subtitle = app.menuItems["English SDH"]
    XCTAssertTrue(subtitle.waitForExistence(timeout: 5))
    app.typeKey("f", modifierFlags: [])
    XCTAssertEqual(playerWindow.frame, originalFrame)
    XCTAssertTrue(subtitle.exists)
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(subtitle.waitForNonExistence(timeout: 5))

    // Settings open inside the window, over the player; F does not switch to full screen there,
    // and Esc returns to the player.
    app.typeKey(",", modifierFlags: .command)
    let settingsTab = app.buttons["settings-tab-general"]
    XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
    XCTAssertTrue(settingsTab.isHittable, "Settings must cover the player, not open behind it.")
    app.typeKey("f", modifierFlags: [])
    XCTAssertEqual(playerWindow.frame.origin, originalFrame.origin)
    XCTAssertLessThan(abs(playerWindow.frame.height - originalFrame.height), 12)
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(settingsTab.waitForNonExistence(timeout: 5))
    playerWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.35)).click()
    app.typeKey("f", modifierFlags: [])
    assertFullScreenLabel(app, "Exit Full Screen")
  }

  @MainActor
  private func launchPlayer() -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "library-admin"
    app.launchEnvironment["AURELIA_CINEMA_UI_TESTS"] = "1"
    app.launchEnvironment["AURELIA_AUTO_HIDE_UI_TESTS"] = "1"
    app.launch()
    app.activate()
    XCTAssertTrue(app.descendants(matching: .any)["sidebar-tvShows"].waitForExistence(timeout: 8))
    app.descendants(matching: .any)["sidebar-tvShows"].click()
    app.buttons["media-20000000-0000-0000-0000-000000000001"].click()
    XCTAssertTrue(app.buttons["play-media"].waitForExistence(timeout: 5))
    app.buttons["play-media"].click()
    XCTAssertTrue(app.buttons["player-play-pause"].waitForExistence(timeout: 8))
    return app
  }

  @MainActor
  private func assertFullScreenLabel(_ app: XCUIApplication, _ label: String) {
    // The fixture hides controls after 1.2 seconds. Real pointer movement into
    // the bottom controls holds them visible throughout the native transition.
    let window = app.windows.containing(.any, identifier: "native-player").firstMatch
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.76, dy: 0.35)).hover()
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.91)).hover()
    let button = app.buttons["player-fullscreen"]
    XCTAssertTrue(button.waitForExistence(timeout: 8))
    button.hover()
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true AND label == %@", label), object: button)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed)
  }

  @MainActor
  private func shot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
