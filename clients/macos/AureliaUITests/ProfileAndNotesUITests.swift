import XCTest

final class ProfileAndNotesUITests: XCTestCase {
  @MainActor
  func testProfilePickerRequiresPinAndSwitchDoesNotReuseUnlockedProfile() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "profiles"
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    defer { app.terminate() }
    let picker = app.descendants(matching: .any)["profile-picker"]
    XCTAssertTrue(picker.waitForExistence(timeout: 8))
    XCTAssertFalse(app.descendants(matching: .any)["primary-sidebar"].exists)
    XCTAssertFalse(app.buttons["watching-profile-70000000-0000-0000-0000-000000000003"].isEnabled)
    shot(app, "Who’s Watching - All Profiles Locked")
    app.buttons["watching-profile-70000000-0000-0000-0000-000000000002"].click()
    let pin = app.secureTextFields["profile-pin"]
    XCTAssertTrue(pin.waitForExistence(timeout: 5))
    pin.click()
    pin.typeText("0000")
    app.buttons["profile-unlock"].click()
    XCTAssertTrue(app.staticTexts["The PIN is incorrect."].waitForExistence(timeout: 5))
    XCTAssertTrue(picker.exists)
    pin.click()
    pin.typeKey("a", modifierFlags: .command)
    pin.typeText("1234")
    app.buttons["profile-unlock"].click()
    XCTAssertTrue(app.buttons["switch-watching-profile"].waitForExistence(timeout: 5))
    app.buttons["switch-watching-profile"].click()
    XCTAssertTrue(picker.waitForExistence(timeout: 20))
    XCTAssertFalse(pin.exists)
    shot(app, "Profile Switch - PIN Required Again")
  }

  @MainActor
  func testCompactPlayerNoteDraftSurvivesPopoverDismissalAndSavesWithoutPausing() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "library-admin"
    app.launchEnvironment["AURELIA_CINEMA_UI_TESTS"] = "1"
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.descendants(matching: .any)["sidebar-tvShows"].waitForExistence(timeout: 8))
    app.descendants(matching: .any)["sidebar-tvShows"].click()
    app.buttons["media-20000000-0000-0000-0000-000000000001"].click()
    XCTAssertTrue(app.buttons["play-media"].waitForExistence(timeout: 5))
    app.buttons["play-media"].click()
    let notesButton = app.buttons["player-notes"]
    XCTAssertTrue(notesButton.waitForExistence(timeout: 8))
    let subtitle = app.buttons["player-subtitle-menu"]
    XCTAssertLessThanOrEqual(subtitle.frame.width, 38)
    XCTAssertFalse(app.buttons["player-export-diagnostics"].exists)
    notesButton.click()
    let text = app.textFields["scene-note-text"]
    XCTAssertTrue(text.waitForExistence(timeout: 5))
    XCTAssertLessThanOrEqual(
      app.descendants(matching: .any)["scene-notes-popover"].frame.width, 365)
    text.click()
    text.typeText("A synthetic scene note")
    shot(app, "Compact Player - Private Scene Note Draft")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(text.waitForNonExistence(timeout: 5))
    notesButton.click()
    XCTAssertTrue(text.waitForExistence(timeout: 5))
    XCTAssertEqual(text.value as? String, "A synthetic scene note")
    app.buttons["scene-note-save"].click()
    XCTAssertTrue(text.waitForNonExistence(timeout: 5))
    let savedNote = app.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH 'scene-note-' AND label CONTAINS %@",
        "A synthetic scene note")
    ).firstMatch
    XCTAssertTrue(savedNote.waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["player-play-pause"].label, "Pause")
    shot(app, "Compact Player - Saved Note without Pausing")
  }

  @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  func testSceneNoteHintAppearsAndExpiresWithoutRevealingHiddenControls() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "library-admin"
    app.launchEnvironment["AURELIA_CINEMA_UI_TESTS"] = "1"
    app.launchEnvironment["AURELIA_AUTO_HIDE_UI_TESTS"] = "1"
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.descendants(matching: .any)["sidebar-tvShows"].waitForExistence(timeout: 8))
    app.descendants(matching: .any)["sidebar-tvShows"].click()
    app.buttons["media-20000000-0000-0000-0000-000000000001"].click()
    XCTAssertTrue(app.buttons["play-media"].waitForExistence(timeout: 5))
    app.buttons["play-media"].click()
    let transport = app.buttons["player-play-pause"]
    let notesButton = app.buttons["player-notes"]
    XCTAssertTrue(notesButton.waitForExistence(timeout: 8))
    notesButton.click()
    let start = app.textFields["scene-note-start"]
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    start.click()
    start.typeKey("a", modifierFlags: .command)
    start.typeText("0:35")
    app.textFields["scene-note-text"].click()
    app.textFields["scene-note-text"].typeText("A quiet synthetic scene hint")
    app.buttons["scene-note-save"].click()
    XCTAssertTrue(app.textFields["scene-note-text"].waitForNonExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)).click()
    XCTAssertTrue(transport.waitForNonExistence(timeout: 12))
    let hint = app.descendants(matching: .any)["scene-note-hint"].firstMatch
    XCTAssertTrue(hint.waitForExistence(timeout: 40))
    XCTAssertFalse(transport.exists, "A note must not reveal the player controls.")
    shot(app, "Private Scene Hint - Controls Stay Hidden")
    XCTAssertTrue(hint.waitForNonExistence(timeout: 8))
    XCTAssertFalse(transport.exists, "Expiring a note must not reveal controls either.")
  }
}
