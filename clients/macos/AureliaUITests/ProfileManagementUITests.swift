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
    // Settings shows the signed-in profile's own PIN rule too; check the editor's.
    let editor = app.sheets.firstMatch
    let rule = editor.descendants(matching: .any)["pin-requirement"]
    let problem = editor.descendants(matching: .any)["pin-requirement-error"]
    XCTAssertTrue(rule.exists, "The PIN rule is shown before typing.")
    app.secureTextFields["profile-editor-pin"].click()
    app.secureTextFields["profile-editor-pin"].typeText("12ab")
    XCTAssertTrue(problem.waitForExistence(timeout: 3), "Letters are reported immediately.")
    XCTAssertFalse(rule.exists, "The error replaces the PIN rule; its wording is unit-tested.")
    XCTAssertFalse(app.buttons["profile-editor-save"].isEnabled)
    app.secureTextFields["profile-editor-pin"].typeKey("a", modifierFlags: .command)
    app.secureTextFields["profile-editor-pin"].typeKey(.delete, modifierFlags: [])
    XCTAssertTrue(problem.waitForNonExistence(timeout: 3))
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
  func testEditorPreservesLegacyAccessAndSaveFailureKeepsDraft() {
    let app = launchManagement()
    defer { app.terminate() }
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

  /// Profiles are managed from Settings › Profiles and Devices; an owner signed in with the
  /// profile PIN needs no server password for that.
  @MainActor private func launchManagement() -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "profile-management"
    app.launch()
    app.activate()
    app.typeKey(",", modifierFlags: .command)
    let profiles = app.buttons["Profiles and Devices"]
    XCTAssertTrue(profiles.waitForExistence(timeout: 8))
    profiles.click()
    XCTAssertTrue(app.buttons["create-profile"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.secureTextFields["management-password"].exists)
    return app
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
