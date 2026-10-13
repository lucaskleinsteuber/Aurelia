import XCTest

final class ProfileManagementUITests: XCTestCase {
  @MainActor
  func testPINlessProfileOpensDirectlyAndSwitchStillShowsPicker() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "profiles"
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    defer { app.terminate() }
    let profile = app.buttons["watching-profile-70000000-0000-0000-0000-000000000004"]
    XCTAssertTrue(profile.waitForExistence(timeout: 8))
    profile.click()
    XCTAssertTrue(app.buttons["switch-watching-profile"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.secureTextFields["profile-pin"].exists)
    app.buttons["switch-watching-profile"].click()
    XCTAssertTrue(app.descendants(matching: .any)["profile-picker"].waitForExistence(timeout: 20))
    shot(app, "Who’s Watching - Optional PIN")
  }

  @MainActor
  func testCreationUsesOneSaveAndNoSecondServerPassword() {
    let app = launchManagement()
    defer { app.terminate() }
    unlock(app)
    let create = app.buttons["create-profile"]
    reveal(create, in: app)
    create.click()
    let name = app.textFields["profile-editor-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 8))
    let protected = app.checkBoxes["profile-editor-pin-protection"].value
    XCTAssertTrue(protected as? Int == 0 || protected as? String == "0")
    XCTAssertFalse(app.secureTextFields["profile-editor-pin"].exists)
    XCTAssertFalse(app.secureTextFields["management-password"].exists)
    name.click()
    name.typeText("New Viewer")
    shot(app, "Create Profile - Optional PIN and Selected Titles")
    app.buttons["profile-editor-save"].click()
    XCTAssertTrue(name.waitForNonExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["New Viewer"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.secureTextFields["management-password"].exists)
    XCTAssertFalse(app.staticTexts["The server returned an invalid response."].exists)
    shot(app, "Profiles - Created without Another Password")
  }

  @MainActor
  func testAdministratorRequiresPINAndCanSelectSearchedTitles() {
    let app = launchManagement()
    defer { app.terminate() }
    unlock(app)
    let create = app.buttons["create-profile"]
    reveal(create, in: app)
    create.click()
    let name = app.textFields["profile-editor-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 8))
    name.click()
    name.typeText("Administrator")
    let role = app.popUpButtons["profile-editor-role"]
    XCTAssertTrue(role.exists)
    role.click()
    app.menuItems["Administrator"].click()
    let protection = app.checkBoxes["profile-editor-pin-protection"]
    XCTAssertFalse(protection.isEnabled)
    XCTAssertTrue(app.secureTextFields["profile-editor-pin"].exists)
    XCTAssertFalse(app.buttons["profile-editor-save"].isEnabled)
    app.secureTextFields["profile-editor-pin"].click()
    app.secureTextFields["profile-editor-pin"].typeText("1234")
    app.secureTextFields["profile-editor-pin-confirmation"].click()
    app.secureTextFields["profile-editor-pin-confirmation"].typeText("1234")
    let search = app.textFields["profile-editor-title-search"]
    reveal(search, in: app)
    search.click()
    search.typeText("Breaking Bad")
    let series = app.checkBoxes["profile-editor-title-20000000-0000-0000-0000-000000000001"]
    XCTAssertTrue(series.waitForExistence(timeout: 5))
    series.click()
    XCTAssertTrue(app.staticTexts["1 selected"].exists)
    XCTAssertTrue(app.buttons["profile-editor-save"].isEnabled)
    shot(app, "Administrator Profile - Mandatory PIN and Selected Series")
    app.buttons["profile-editor-save"].click()
    XCTAssertTrue(name.waitForNonExistence(timeout: 8))
    XCTAssertFalse(app.secureTextFields["management-password"].exists)
  }

  @MainActor
  func testLockKeepsProfileDraftButClearsPINAndAllowsUnlockInsideEditor() {
    let app = launchManagement()
    defer { app.terminate() }
    unlock(app)
    let create = app.buttons["create-profile"]
    reveal(create, in: app)
    create.click()
    let name = app.textFields["profile-editor-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 8))
    name.click()
    name.typeText("Kept Draft")
    let protection = app.checkBoxes["profile-editor-pin-protection"]
    protection.click()
    let pin = app.secureTextFields["profile-editor-pin"]
    XCTAssertTrue(pin.waitForExistence(timeout: 5))
    pin.click()
    pin.typeText("1234")
    app.secureTextFields["profile-editor-pin-confirmation"].click()
    app.secureTextFields["profile-editor-pin-confirmation"].typeText("1234")
    last(app.buttons.matching(identifier: "management-lock")).click()
    XCTAssertTrue(app.secureTextFields["management-password"].waitForExistence(timeout: 8))
    XCTAssertEqual(name.value as? String, "Kept Draft")
    XCTAssertEqual(pin.value as? String, "")
    XCTAssertFalse(app.buttons["profile-editor-save"].isEnabled)
    shot(app, "Profile Draft - Management Locked, PIN Cleared")
    unlock(app)
    XCTAssertEqual(name.value as? String, "Kept Draft")
    XCTAssertEqual(pin.value as? String, "")
    XCTAssertFalse(app.buttons["profile-editor-save"].isEnabled)
    app.buttons["profile-editor-cancel"].click()
    XCTAssertTrue(name.waitForNonExistence(timeout: 8))
  }

  @MainActor
  func testEditorPreservesLegacyAccessAndSaveFailureKeepsDraft() {
    let app = launchManagement()
    defer { app.terminate() }
    unlock(app)
    let edit = app.buttons["edit-profile-71000000-0000-0000-0000-000000000002"]
    reveal(edit, in: app)
    edit.click()
    XCTAssertTrue(
      app.staticTexts[
        "Existing storage grants stay unchanged unless you select another access mode."
      ].waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["profile-editor-save"].isEnabled)
    shot(app, "Edit Profile - Existing Grants Preserved")
    app.buttons["profile-editor-save"].click()
    XCTAssertTrue(app.descendants(matching: .any)["profile-editor"].waitForNonExistence(timeout: 8))
    app.buttons["create-profile"].click()
    let name = app.textFields["profile-editor-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 8))
    name.click()
    name.typeText("Reject Profile")
    app.buttons["profile-editor-save"].click()
    XCTAssertTrue(
      app.staticTexts["The profile could not be saved. Your draft is unchanged."].waitForExistence(
        timeout: 8))
    XCTAssertEqual(name.value as? String, "Reject Profile")
    shot(app, "Create Profile - Failed Save Keeps Draft")
    app.buttons["profile-editor-cancel"].click()
  }

  @MainActor
  func testManagementExpirationKeepsDraftAndClearsPINWithoutGlobalError() {
    let app = launchManagement(expirySeconds: "30")
    defer { app.terminate() }
    unlock(app)
    let create = app.buttons["create-profile"]
    reveal(create, in: app)
    create.click()
    let name = app.textFields["profile-editor-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 8))
    name.click()
    name.typeText("Expiry Draft")
    app.checkBoxes["profile-editor-pin-protection"].click()
    let pin = app.secureTextFields["profile-editor-pin"]
    pin.click()
    pin.typeText("1234")
    XCTAssertTrue(app.secureTextFields["management-password"].waitForExistence(timeout: 40))
    XCTAssertEqual(name.value as? String, "Expiry Draft")
    XCTAssertEqual(pin.value as? String, "")
    XCTAssertFalse(app.buttons["profile-editor-save"].isEnabled)
    XCTAssertFalse(app.staticTexts["The server returned an invalid response."].exists)
    shot(app, "Profile Draft - Timed Management Expiry")
    unlock(app)
    XCTAssertEqual(name.value as? String, "Expiry Draft")
    app.buttons["profile-editor-cancel"].click()
  }

  @MainActor private func launchManagement(expirySeconds: String? = nil) -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "profile-management"
    if let expirySeconds {
      app.launchEnvironment["AURELIA_UI_TEST_MANAGEMENT_SECONDS"] = expirySeconds
    }
    app.launch()
    app.activate()
    app.typeKey(",", modifierFlags: .command)
    let server = app.buttons["Server"]
    XCTAssertTrue(server.waitForExistence(timeout: 8))
    server.click()
    XCTAssertTrue(app.secureTextFields["management-password"].waitForExistence(timeout: 8))
    return app
  }

  @MainActor private func unlock(_ app: XCUIApplication) {
    let password = last(app.secureTextFields.matching(identifier: "management-password"))
    XCTAssertTrue(password.waitForExistence(timeout: 8))
    password.click()
    password.typeText("synthetic-server-password")
    last(app.buttons.matching(identifier: "management-unlock")).click()
    XCTAssertTrue(password.waitForNonExistence(timeout: 8))
  }

  @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    XCTAssertTrue(element.waitForExistence(timeout: 8))
    for _ in 0..<12 {
      if element.isHittable { return }
      let scroll = app.scrollViews.containing(.any, identifier: element.identifier).firstMatch
      XCTAssertTrue(scroll.exists, "The target must belong to its actual scroll view.")
      scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.7))
        .scroll(byDeltaX: 0, deltaY: -300)
    }
    XCTAssertTrue(element.isHittable)
  }

  @MainActor private func last(_ query: XCUIElementQuery) -> XCUIElement {
    query.allElementsBoundByIndex.last ?? query.firstMatch
  }

  @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
