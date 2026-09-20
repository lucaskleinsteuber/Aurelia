import AppKit
import XCTest

final class AureliaUITests: XCTestCase {
  @MainActor
  func testDefaultHostLaunchShowsServerStartingState() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "host-starting"
    app.launch()
    app.activate()
    defer { app.terminate() }

    XCTAssertTrue(app.staticTexts["Starting Your Server"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.buttons["switch-to-client"].exists)
    assertNoUnexpectedDialog(in: app)
  }

  @MainActor
  func testFailedHostLaunchCanRetryFromACompleteNewAttempt() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "host-failed"
    app.launch()
    app.activate()
    defer { app.terminate() }

    let retry = app.buttons["retry-server-start"]
    XCTAssertTrue(retry.waitForExistence(timeout: 8))
    XCTAssertTrue(app.descendants(matching: .any)["switch-to-client"].exists)
    retry.click()
    XCTAssertTrue(app.staticTexts["Set Up This Mac"].waitForExistence(timeout: 5))
    assertNoUnexpectedDialog(in: app)
  }

  @MainActor
  func testFirstRunOffersHostAndClientModes() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "welcome"
    app.launch()
    app.activate()
    defer { app.terminate() }

    XCTAssertTrue(app.staticTexts["Welcome to Aurelia"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["choose-host"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["choose-client"].exists)
    XCTAssertFalse(app.webViews.firstMatch.exists)
    assertNoUnexpectedDialog(in: app)
  }

  @MainActor
  func testNativeHostSetupCollectsOwnerDetailsWithoutSystemDialogs() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "host-setup"
    app.launch()
    app.activate()
    defer { app.terminate() }

    XCTAssertTrue(app.staticTexts["Set Up This Mac"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.secureTextFields["host-owner-password"].exists)
    XCTAssertFalse(app.textFields["host-server-name"].exists)
    XCTAssertFalse(app.secureTextFields["host-owner-confirmation"].exists)
    app.buttons["host-advanced"].click()
    XCTAssertTrue(app.textFields["host-server-name"].exists)
    XCTAssertTrue(app.textFields["host-owner-name"].exists)
    XCTAssertTrue(app.buttons["create-local-server"].exists)
    assertNoUnexpectedDialog(in: app)
  }

  @MainActor
  func testLibraryFolderSelectionUsesInjectedTestFolderWithoutPrivacyDialog() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "library-setup"
    app.launchEnvironment["AURELIA_UI_TEST_FOLDERS"] =
      "/private/tmp/Aurelia/UIFixture\n/private/tmp/Aurelia/SecondFixture"
    app.launch()
    app.activate()
    defer { app.terminate() }

    XCTAssertTrue(app.buttons["initial-add-media-folder"].waitForExistence(timeout: 8))
    app.buttons["initial-add-media-folder"].click()
    XCTAssertTrue(
      app.staticTexts["/private/tmp/Aurelia/UIFixture"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["/private/tmp/Aurelia/SecondFixture"].exists)
    XCTAssertTrue(app.buttons["start-storage-scan"].isEnabled)
    XCTAssertFalse(app.dialogs.firstMatch.exists)
    XCTAssertFalse(app.alerts.firstMatch.exists)
  }

  @MainActor
  func testAddMediaIsAvailableFromHomeLibraryAndMenu() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "media-manager"
    app.launchEnvironment["AURELIA_UI_TEST_FOLDERS"] = "/private/tmp/Aurelia/MovieFixture"
    app.launch()
    app.activate()
    defer { app.terminate() }

    let homeAction = app.buttons["home-add-media"]
    XCTAssertTrue(homeAction.waitForExistence(timeout: 8))
    homeAction.click()
    XCTAssertTrue(app.staticTexts["Manage Media"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.descendants(matching: .any)[
        "library-monitor-30000000-0000-0000-0000-000000000001"
      ].exists)
    XCTAssertTrue(app.staticTexts["Waiting for Storage"].exists)
    XCTAssertTrue(app.staticTexts["Scheduled Check"].exists)
    XCTAssertTrue(app.staticTexts["Attempt 2"].exists)
    XCTAssertTrue(app.buttons["Cancel"].exists)
    let chooser = app.buttons["media-manager-choose-locations"]
    XCTAssertTrue(chooser.exists)
    chooser.click()
    XCTAssertTrue(app.staticTexts["/private/tmp/Aurelia/MovieFixture"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["media-manager-add-and-scan"].isEnabled)
    app.buttons["Done"].click()

    app.descendants(matching: .any)["sidebar-library"].click()
    XCTAssertTrue(app.buttons["library-add-media"].waitForExistence(timeout: 5))
    app.typeKey("o", modifierFlags: .command)
    XCTAssertTrue(app.staticTexts["Manage Media"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testNormalUserCannotManageMedia() throws {
    let app = launchLibrary()
    defer { app.terminate() }
    XCTAssertFalse(app.buttons["library-add-media"].exists)
    XCTAssertFalse(app.menuItems["Add Media…"].isEnabled)
  }

  @MainActor
  func testFreshLaunchShowsNativePairing() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "pairing"
    app.launch()
    app.activate()
    defer { app.terminate() }

    XCTAssertTrue(app.staticTexts["Connect to Aurelia"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.textFields["manual-server-address"].exists)
    XCTAssertTrue(app.buttons["connection-set-up-this-mac"].exists)
    app.buttons["connection-advanced"].click()
    XCTAssertTrue(app.textFields["manual-server-address"].exists)
    XCTAssertTrue(app.buttons["connect-manually"].exists)
    XCTAssertFalse(app.webViews.firstMatch.exists)
    assertNoUnexpectedDialog(in: app)
  }

  @MainActor
  func testAdvancedSettingsExposeOptionalMetadataWithoutASecret() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "metadata-settings"
    app.launch()
    app.activate()
    defer { app.terminate() }

    app.typeKey(",", modifierFlags: .command)
    let metadataTab = app.buttons["Metadata"]
    XCTAssertTrue(metadataTab.waitForExistence(timeout: 8))
    metadataTab.click()
    XCTAssertTrue(app.staticTexts["Movie & TV Information"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["metadata-enrich"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["metadata-remove-token"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.secureTextFields["tmdb-token"].exists)
    assertNoUnexpectedDialog(in: app)
  }

  @MainActor
  func testPlaybackSettingsExposeDurablePlayerPreferences() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "metadata-settings"
    app.launch()
    app.activate()
    defer { app.terminate() }

    app.typeKey(",", modifierFlags: .command)
    let playbackTab = app.buttons["Playback"]
    XCTAssertTrue(playbackTab.waitForExistence(timeout: 8))
    playbackTab.click()
    XCTAssertTrue(app.staticTexts["Playback"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.descendants(matching: .any)["playback-automatic-resume"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["playback-auto-next"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["playback-prevent-sleep"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["playback-default-rate"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["playback-default-volume"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["playback-auto-hide-delay"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["playback-seek-interval"].exists)
    XCTAssertTrue(app.buttons["playback-forget-tracks"].exists)
    XCTAssertTrue(app.buttons["playback-restore-defaults"].exists)
    assertNoUnexpectedDialog(in: app)
  }

  @MainActor
  func testClosingWindowAndReopeningThroughLaunchServicesRestoresIt() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "welcome"
    app.launch()
    app.activate()
    defer { app.terminate() }

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 8))
    window.buttons[XCUIIdentifierCloseWindow].click()
    XCTAssertFalse(window.waitForExistence(timeout: 3))

    guard
      let applicationURL = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.lucas.aurelia.media"
      ).first?.bundleURL
    else {
      XCTFail("The running Aurelia bundle URL was unavailable")
      return
    }

    let reopened = expectation(description: "Launch Services reopened Aurelia")
    NSWorkspace.shared.openApplication(
      at: applicationURL,
      configuration: NSWorkspace.OpenConfiguration()
    ) { _, error in
      XCTAssertNil(error)
      reopened.fulfill()
    }
    wait(for: [reopened], timeout: 8)

    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["Welcome to Aurelia"].exists)
  }

  @MainActor
  func testLibraryShowsMoviesAndTVShows() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "library"
    app.launch()
    app.activate()
    defer { app.terminate() }

    app.descendants(matching: .any)["sidebar-library"].click()
    XCTAssertTrue(
      app.buttons["media-10000000-0000-0000-0000-000000000001"]
        .waitForExistence(timeout: 8))
    app.descendants(matching: .any)["sidebar-tvShows"].click()
    XCTAssertTrue(
      app.buttons["media-20000000-0000-0000-0000-000000000001"]
        .waitForExistence(timeout: 5))
    app.buttons["media-20000000-0000-0000-0000-000000000001"].click()
    XCTAssertTrue(app.descendants(matching: .any)["season-1"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.descendants(matching: .any)["episode-1-1"].exists)
    XCTAssertTrue(
      app.buttons["supplement-20000000-0000-0000-0000-000000000020"].exists)
    XCTAssertFalse(app.webViews.firstMatch.exists)

    app.buttons["episode-1-1"].click()
    XCTAssertTrue(app.descendants(matching: .any)["native-player"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.webViews.firstMatch.exists)
    assertNoUnexpectedDialog(in: app)
  }

  @MainActor
  func testBuildTenHomeShowsHeroRowsCollectionsAndArtworkFallbacks() throws {
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "library"
    app.launch()
    app.activate()
    defer { app.terminate() }

    XCTAssertTrue(app.descendants(matching: .any)["home-page"].waitForExistence(timeout: 8))
    let hero = app.descendants(matching: .any)["home-hero"]
    XCTAssertTrue(hero.exists)
    let window = app.windows.firstMatch
    XCTAssertTrue(window.exists)
    XCTAssertLessThanOrEqual(
      hero.frame.minY,
      window.frame.minY + 2,
      "The Home hero must reach the transparent titlebar; an empty top strip is a release blocker.")
    XCTAssertTrue(app.buttons["home-hero-action"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Continue Watching"].exists)
    XCTAssertTrue(
      app.descendants(matching: .any)["artwork-placeholder"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.webViews.firstMatch.exists)
    assertNoUnexpectedDialog(in: app)
  }

  @MainActor
  func testLibrarySearchUsesPresentationResultsAndMissingMediaStaysVisible() throws {
    let app = launchLibrary()
    defer { app.terminate() }

    let search = app.textFields["library-search"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.click()
    search.typeText("chemistry")
    XCTAssertTrue(
      app.buttons["media-20000000-0000-0000-0000-000000000001"]
        .waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.buttons["media-10000000-0000-0000-0000-000000000001"]
        .waitForNonExistence(timeout: 5))

    search.typeKey("a", modifierFlags: .command)
    search.typeText("Missing")
    let missing = app.buttons["media-10000000-0000-0000-0000-000000000099"]
    XCTAssertTrue(missing.waitForExistence(timeout: 5))
    missing.click()
    let play = app.buttons["play-media"]
    XCTAssertTrue(play.waitForExistence(timeout: 5))
    XCTAssertFalse(play.isEnabled)
    XCTAssertTrue(app.staticTexts["Unavailable"].exists)
  }

  @MainActor
  func testEpisodeSearchShowsContextAndStartsPlayback() throws {
    let app = launchLibrary()
    defer { app.terminate() }

    let search = app.textFields["library-search"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.click()
    search.typeText("Pilot")
    XCTAssertTrue(app.staticTexts["Episodes"].waitForExistence(timeout: 5))
    let episode = app.buttons[
      "search-episode-20000000-0000-0000-0000-000000000010"]
    XCTAssertTrue(episode.waitForExistence(timeout: 5))
    XCTAssertEqual(episode.label, "Pilot, Breaking Bad · Season 1 · Episode 1")
    episode.click()
    let player = app.descendants(matching: .any)["native-player"]
    XCTAssertTrue(player.waitForExistence(timeout: 5))
    XCTAssertEqual(player.label, "Native Player · Pilot")
  }

  @MainActor
  func testAdministratorCanOpenUnifiedMetadataEditor() throws {
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "library-admin"
    app.launch()
    app.activate()
    defer { app.terminate() }

    app.descendants(matching: .any)["sidebar-library"].click()
    let movie = app.buttons["media-10000000-0000-0000-0000-000000000001"]
    XCTAssertTrue(movie.waitForExistence(timeout: 8))
    movie.click()
    let actions = app.descendants(matching: .any)["media-actions"]
    XCTAssertTrue(actions.waitForExistence(timeout: 5))
    actions.click()
    let editMetadata = app.menuItems["Edit Metadata"]
    XCTAssertTrue(editMetadata.waitForExistence(timeout: 5))
    editMetadata.click()
    XCTAssertTrue(app.descendants(matching: .any)["metadata-editor"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Edit Metadata"].exists)
    XCTAssertTrue(app.buttons["Save"].exists)
    XCTAssertTrue(app.buttons["Cancel"].exists)
  }

  @MainActor
  func testMovieStartsNativePlayer() throws {
    let app = launchLibrary()
    defer { app.terminate() }

    app.buttons["media-10000000-0000-0000-0000-000000000001"].click()
    XCTAssertTrue(app.buttons["play-media"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.descendants(matching: .any)["media-actions"].exists)
    app.buttons["play-media"].click()
    assertNativePlayer(in: app)
    assertClassicPlayerControls(in: app)
  }

  @MainActor
  func testTrailerStartsNativePlayer() throws {
    let app = launchLibrary()
    defer { app.terminate() }

    app.buttons["media-10000000-0000-0000-0000-000000000001"].click()
    let trailer = app.buttons["supplement-10000000-0000-0000-0000-000000000010"]
    XCTAssertTrue(trailer.waitForExistence(timeout: 5))
    trailer.click()
    assertNativePlayer(in: app)
  }

  @MainActor
  func testSeriesExtraStartsNativePlayer() throws {
    let app = launchLibrary()
    defer { app.terminate() }

    app.descendants(matching: .any)["sidebar-tvShows"].click()
    app.buttons["media-20000000-0000-0000-0000-000000000001"].click()
    let extra = app.buttons["supplement-20000000-0000-0000-0000-000000000020"]
    XCTAssertTrue(extra.waitForExistence(timeout: 5))
    app.scrollViews["media-detail-scroll"].scroll(byDeltaX: 0, deltaY: -520)
    extra.click()
    assertNativePlayer(in: app)
  }

  @MainActor
  func testPlayerRestoresWindowAfterNativeFullScreen() throws {
    let app = launchLibrary()
    defer { app.terminate() }

    app.buttons["media-10000000-0000-0000-0000-000000000001"].click()
    app.buttons["play-media"].click()
    assertNativePlayer(in: app)

    let window = app.windows.firstMatch
    window.hover()
    let fullScreen = app.buttons["player-fullscreen"]
    XCTAssertTrue(fullScreen.waitForExistence(timeout: 5))
    XCTAssertEqual(fullScreen.label, "Enter Full Screen")
    fullScreen.click()
    let enteredFullScreen = NSPredicate(format: "label == %@", "Exit Full Screen")
    expectation(for: enteredFullScreen, evaluatedWith: fullScreen)
    waitForExpectations(timeout: 8)

    window.hover()
    let back = app.buttons["player-back"]
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.click()
    XCTAssertFalse(app.descendants(matching: .any)["native-player"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.windows.firstMatch.buttons[XCUIIdentifierFullScreenWindow].waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["play-media"].waitForExistence(timeout: 5))
  }

  @MainActor
  private func launchLibrary() -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "library"
    app.launch()
    app.activate()
    XCTAssertTrue(app.descendants(matching: .any)["sidebar-library"].waitForExistence(timeout: 8))
    app.descendants(matching: .any)["sidebar-library"].click()
    XCTAssertTrue(
      app.buttons["media-10000000-0000-0000-0000-000000000001"]
        .waitForExistence(timeout: 8))
    return app
  }

  @MainActor
  private func configureTestLaunch(_ app: XCUIApplication) {
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
  }

  @MainActor
  private func assertNativePlayer(in app: XCUIApplication) {
    XCTAssertTrue(app.descendants(matching: .any)["native-player"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.webViews.firstMatch.exists)
    assertNoUnexpectedDialog(in: app)
  }

  @MainActor
  private func assertClassicPlayerControls(in app: XCUIApplication) {
    app.windows.firstMatch.hover()
    XCTAssertTrue(app.buttons["player-back"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["player-rate-menu"].exists)
    XCTAssertTrue(app.buttons["player-audio-menu"].exists)
    XCTAssertTrue(app.buttons["player-subtitle-menu"].exists)
    XCTAssertTrue(app.buttons["player-sleep-menu"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["player-timeline"].exists)
    XCTAssertTrue(app.buttons["player-picture-in-picture"].exists)
    XCTAssertTrue(app.buttons["player-fullscreen"].exists)

    app.buttons["player-rate-menu"].click()
    XCTAssertTrue(app.staticTexts["Playback Rate"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["1.5x"].exists)
    app.typeKey(.escape, modifierFlags: [])
  }

  @MainActor
  private func assertNoUnexpectedDialog(in app: XCUIApplication) {
    XCTAssertFalse(app.alerts.firstMatch.exists)
    XCTAssertFalse(app.dialogs.firstMatch.exists)
    XCTAssertFalse(app.sheets.firstMatch.exists)
  }

}
