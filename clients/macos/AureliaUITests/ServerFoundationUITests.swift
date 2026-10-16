import XCTest

final class ServerFoundationUITests: XCTestCase {
  @MainActor func testDeviceApprovalReviewsDeviceAndConfirms() throws {
    let app = launch()
    defer { app.terminate() }
    let button = app.buttons["approve-device"]
    XCTAssertTrue(button.waitForExistence(timeout: 8))
    XCTAssertTrue(button.isEnabled)
    button.click()
    let field = app.textFields["device-approval-code"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.click()
    field.typeText("12345678")
    app.buttons["device-approval-lookup"].click()
    XCTAssertTrue(app.staticTexts["Living Room Apple TV"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Synthetic UI Server"].exists)
    XCTAssertTrue(app.staticTexts["12345678"].exists)
    screenshot(app, "Device approval review")
    app.buttons["device-approval-confirm"].click()
    XCTAssertTrue(app.buttons["approve-device"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.textFields["device-approval-code"].exists)
    XCTAssertFalse(app.staticTexts["The server returned an invalid response."].exists)
  }

  @MainActor func testInvalidDeviceCodeStaysInFormAndEscapeClosesIt() throws {
    let app = launch()
    defer { app.terminate() }
    let button = app.buttons["approve-device"]
    XCTAssertTrue(button.waitForExistence(timeout: 8))
    button.click()
    let field = app.textFields["device-approval-code"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.click()
    field.typeText("87654321")
    app.buttons["device-approval-lookup"].click()
    XCTAssertTrue(app.staticTexts["device-approval-error"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["device-approval-confirm"].exists)
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertFalse(app.textFields["device-approval-code"].exists)
  }

  @MainActor func testServerOverviewExplainsReadiness() throws {
    let app = launch()
    defer { app.terminate() }
    app.buttons["Server"].click()
    XCTAssertTrue(app.staticTexts["Overview"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["Degraded"].exists)
    XCTAssertTrue(app.staticTexts["Media drive disconnected"].exists)
    screenshot(app, "Server readiness")
  }

  @MainActor private func launch() -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "server-settings"
    app.launchEnvironment["AURELIA_DEVICE_APPROVAL_UI_TESTS"] = "1"
    app.launch()
    app.activate()
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(app.buttons["General"].waitForExistence(timeout: 8))
    app.buttons["General"].click()
    return app
  }

  @MainActor private func screenshot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
