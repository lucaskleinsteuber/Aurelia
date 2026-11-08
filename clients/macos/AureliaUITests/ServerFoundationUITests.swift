import XCTest

final class ServerFoundationUITests: XCTestCase {
  @MainActor func testServerOverviewExplainsReadiness() throws {
    let app = launch()
    defer { app.terminate() }
    let server = app.buttons["Server"]
    XCTAssertTrue(server.waitForExistence(timeout: 8))
    server.click()
    XCTAssertTrue(app.staticTexts["Your Server"].waitForExistence(timeout: 8))
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
    // Device approval is part of Settings › Profiles and Devices.
    let devices = app.buttons["Profiles and Devices"]
    XCTAssertTrue(devices.waitForExistence(timeout: 8))
    devices.click()
    return app
  }

  @MainActor private func screenshot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
