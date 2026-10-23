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
    shot(app, "Who’s Watching - Protected and Optional Profiles")
    app.buttons["watching-profile-70000000-0000-0000-0000-000000000002"].click()
    let pin = app.secureTextFields["profile-pin"]
    XCTAssertTrue(pin.waitForExistence(timeout: 5))
    assertReducedPINScreen(app)
    pin.typeText("0000\r")
    XCTAssertTrue(app.staticTexts["The PIN is incorrect."].waitForExistence(timeout: 5))
    XCTAssertTrue(picker.exists)
    XCTAssertEqual(pin.value as? String, "")
    pin.typeText("1234\r")
    XCTAssertTrue(app.buttons["switch-watching-profile"].waitForExistence(timeout: 5))
    app.buttons["switch-watching-profile"].click()
    XCTAssertTrue(picker.waitForExistence(timeout: 20))
    XCTAssertFalse(pin.exists)
    shot(app, "Profile Switch - PIN Required Again")
  }

  @MainActor
  func testProfilePINValidationEscapeAndAvatarBack() {
    continueAfterFailure = false
    let app = profileApp(localRecovery: true)
    app.launch()
    defer { app.terminate() }
    let viewer = app.buttons["watching-profile-70000000-0000-0000-0000-000000000002"]
    XCTAssertTrue(viewer.waitForExistence(timeout: 8))
    // Recovery is offered where it helps: on the owner's PIN screen, not on the picker.
    XCTAssertFalse(app.buttons["recover-owner-pin"].exists)
    assertReducedSelection(app)
    let owner = app.buttons["watching-profile-70000000-0000-0000-0000-000000000001"]
    owner.click()
    XCTAssertTrue(app.buttons["recover-owner-pin"].waitForExistence(timeout: 5))
    shot(app, "Profile PIN - Owner With Forgot PIN")
    app.buttons["recover-owner-pin"].click()
    XCTAssertTrue(app.staticTexts["Recover Owner PIN"].waitForExistence(timeout: 5))
    app.buttons["Cancel"].click()
    XCTAssertTrue(viewer.waitForExistence(timeout: 5))
    viewer.click()
    let pin = app.secureTextFields["profile-pin"]
    XCTAssertTrue(pin.waitForExistence(timeout: 5))
    assertReducedPINScreen(app)
    let fieldContainer = app.descendants(matching: .any)["profile-pin-container"]
    XCTAssertTrue(fieldContainer.exists)
    XCTAssertEqual(fieldContainer.frame.width, 280, accuracy: 3)
    XCTAssertEqual(fieldContainer.frame.height, 52, accuracy: 3)
    pin.typeText("12\r")
    XCTAssertTrue(app.staticTexts["The PIN is incorrect."].waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(viewer.waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["The PIN is incorrect."].exists)
    viewer.click()
    XCTAssertTrue(pin.waitForExistence(timeout: 5))
    pin.typeText("123")
    app.buttons["profile-back"].click()
    XCTAssertTrue(viewer.waitForExistence(timeout: 5))
    viewer.click()
    XCTAssertTrue(pin.waitForExistence(timeout: 5))
    XCTAssertEqual(pin.value as? String, "")
    shot(app, "Profile PIN - Avatar, Field and Confirm Arrow")
    // Letters are ignored, and the arrow confirms without pressing Return.
    pin.typeText("12ab345678")
    XCTAssertEqual((pin.value as? String)?.count, 8)
    app.buttons["profile-unlock"].click()
    XCTAssertTrue(app.buttons["switch-watching-profile"].waitForExistence(timeout: 8))
  }

  @MainActor
  func testProfileUnlockCanBeCancelledWhileWaiting() {
    continueAfterFailure = false
    let app = profileApp()
    app.launchEnvironment["AURELIA_PROFILE_UNLOCK_DELAY_UI_TESTS"] = "1"
    app.launch()
    defer { app.terminate() }
    let viewer = app.buttons["watching-profile-70000000-0000-0000-0000-000000000002"]
    XCTAssertTrue(viewer.waitForExistence(timeout: 12))
    viewer.click()
    let pin = app.secureTextFields["profile-pin"]
    XCTAssertTrue(pin.waitForExistence(timeout: 5))
    pin.typeText("1234\r")
    let loading = app.descendants(matching: .any)["profile-unlock-progress"]
    XCTAssertTrue(loading.waitForExistence(timeout: 5))
    XCTAssertFalse(pin.isEnabled)
    app.typeKey(.return, modifierFlags: [])
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(loading.exists)
    XCTAssertFalse(app.buttons["switch-watching-profile"].exists)
    shot(app, "Profile PIN - Loading - Repeated Enter Ignored")
    app.buttons["profile-back"].click()
    XCTAssertTrue(viewer.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["switch-watching-profile"].waitForExistence(timeout: 9))
    XCTAssertFalse(app.staticTexts["profile-pin-error"].exists)
    viewer.click()
    XCTAssertTrue(pin.waitForExistence(timeout: 5))
    XCTAssertEqual(pin.value as? String, "")
    pin.typeText("1234\r")
    XCTAssertTrue(app.buttons["switch-watching-profile"].waitForExistence(timeout: 12))
  }

  @MainActor
  func testCenteredProfileRowsForSinglePairAndWrappedProfiles() {
    continueAfterFailure = false
    for fixture in ["single", "pair", "many"] {
      let app = profileApp()
      app.launchEnvironment["AURELIA_PROFILE_LAYOUT_UI_TESTS"] = fixture
      app.launch()
      let owner = app.buttons["watching-profile-70000000-0000-0000-0000-000000000001"]
      XCTAssertTrue(owner.waitForExistence(timeout: 8))
      assertCenteredProfileRows(app)
      shot(app, "Profiles - \(fixture.capitalized) - Centered Rows")
      if fixture == "many" {
        let window = app.windows.firstMatch
        let original = window.frame
        XCTAssertGreaterThan(original.width, 1_000)
        let origin = window.coordinate(withNormalizedOffset: .zero)
        // Straight native edges avoid the transparent rounded corner and shadow.
        let rightEdge = origin.withOffset(
          CGVector(dx: original.width - 2, dy: original.height * 0.7))
        rightEdge.click(
          forDuration: 0.2,
          thenDragTo: origin.withOffset(CGVector(dx: 818, dy: original.height * 0.7)))
        XCTAssertEqual(window.frame.width, 820, accuracy: 8)
        XCTAssertLessThan(window.frame.width, original.width - 200)
        let bottomEdge = origin.withOffset(
          CGVector(dx: window.frame.width / 2, dy: original.height - 2))
        bottomEdge.click(
          forDuration: 0.2,
          thenDragTo: origin.withOffset(CGVector(dx: window.frame.width / 2, dy: 598)))
        XCTAssertEqual(window.frame.height, 600, accuracy: 8)
        assertCenteredProfileRows(app)
        shot(app, "Profiles - Long Names - Smaller Window")
      }
      app.terminate()
    }
  }

  @MainActor
  private func profileApp(localRecovery: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "profiles"
    if localRecovery { app.launchEnvironment["AURELIA_PROFILE_LOCAL_RECOVERY_UI_TESTS"] = "1" }
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    return app
  }

  @MainActor
  private func assertReducedSelection(_ app: XCUIApplication) {
    XCTAssertFalse(app.buttons["Refresh Profiles"].exists)
    XCTAssertFalse(
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Favorites, progress"))
        .firstMatch.exists)
  }

  @MainActor
  private func assertReducedPINScreen(_ app: XCUIApplication) {
    assertReducedSelection(app)
    XCTAssertFalse(app.staticTexts["Who’s watching?"].exists)
    XCTAssertFalse(app.buttons["Choose Another Profile"].exists)
    XCTAssertFalse(app.buttons["Watch"].exists)
    XCTAssertTrue(app.buttons["profile-unlock"].exists)
    XCTAssertFalse(app.buttons["recover-owner-pin"].exists)
    XCTAssertTrue(app.buttons["profile-back"].exists)
  }

  @MainActor
  private func assertCenteredProfileRows(_ app: XCUIApplication) {
    // Profiles rise in with a short stagger; measure them once they have settled.
    _ = XCTWaiter.wait(for: [XCTestExpectation(description: "Profiles settle")], timeout: 1)
    let profiles = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'watching-profile-'")
    )
    .allElementsBoundByIndex
    XCTAssertFalse(profiles.isEmpty)
    let rows = Dictionary(grouping: profiles) { Int($0.frame.minY.rounded()) }
    for row in rows.values {
      let sorted = row.sorted { $0.frame.minX < $1.frame.minX }
      guard let first = sorted.first, let last = sorted.last else { continue }
      XCTAssertEqual(
        (first.frame.minX + last.frame.maxX) / 2, app.windows.firstMatch.frame.midX, accuracy: 3)
      for item in sorted { XCTAssertEqual(item.frame.width, 140, accuracy: 3) }
      for index in 1..<sorted.count {
        XCTAssertEqual(sorted[index].frame.minX - sorted[index - 1].frame.maxX, 24, accuracy: 3)
      }
    }
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
