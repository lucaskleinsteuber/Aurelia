import AppKit
import XCTest

final class AureliaUITests: XCTestCase {
  @MainActor
  func testImportPreviewExpandsFeaturettesAndEditsSeasonAssignmentsWithoutImporting() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "import-preview"
    app.launch()
    app.activate()
    defer { app.terminate() }

    XCTAssertTrue(app.staticTexts["Import Preview"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["17 files"].exists)
    XCTAssertTrue(app.staticTexts["12 extras · 0 trailers"].exists)
    XCTAssertFalse(app.webViews.firstMatch.exists)
    recordImportScreenshot(app, named: "Import Preview - Collapsed Synthetic Series")

    let firstTriangle = app.windows.firstMatch.disclosureTriangles.element(boundBy: 0)
    XCTAssertTrue(firstTriangle.waitForExistence(timeout: 5), app.debugDescription)
    firstTriangle.click()
    XCTAssertTrue(app.staticTexts["Featurettes"].waitForExistence(timeout: 5))
    let featurettesTriangle = app.windows.firstMatch.disclosureTriangles.element(boundBy: 1)
    XCTAssertTrue(featurettesTriangle.exists, app.debugDescription)
    featurettesTriangle.click()
    XCTAssertTrue(app.staticTexts["Interview with the Director"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Chernobyl/Featurettes/Featurette 1.mkv"].exists)
    recordImportScreenshot(app, named: "Import Preview - Expanded Featurettes")

    app.staticTexts["Interview with the Director"].click()
    let edit = app.buttons["import-edit-assignment"]
    XCTAssertTrue(edit.exists)
    XCTAssertTrue(edit.isEnabled)
    edit.click()
    XCTAssertTrue(app.staticTexts["Edit Import Assignment"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.descendants(matching: .any)["import-assignment-parent"].exists)
    XCTAssertTrue(app.textFields["import-assignment-category"].exists)
    XCTAssertEqual(
      app.textFields["import-assignment-title"].value as? String,
      "Interview with the Director")
    let entireSeries = app.descendants(matching: .any)["import-entire-series"]
    XCTAssertTrue(entireSeries.exists)
    XCTAssertFalse(app.textFields["import-assignment-season"].exists)
    recordImportScreenshot(app, named: "Import Assignment - Entire Series Extra")

    entireSeries.click()
    let season = app.textFields["import-assignment-season"]
    XCTAssertTrue(season.waitForExistence(timeout: 5))
    XCTAssertEqual(season.value as? String, "1")
    XCTAssertTrue(app.descendants(matching: .any)["Choose Existing Season"].exists)
    XCTAssertTrue(app.buttons["Save Assignment"].isEnabled)
    recordImportScreenshot(app, named: "Import Assignment - Season Specific Extra")

    let kind = app.descendants(matching: .any)["import-assignment-kind"]
    kind.click()
    let episode = app.menuItems["Episode"]
    XCTAssertTrue(episode.waitForExistence(timeout: 5))
    episode.click()
    XCTAssertTrue(app.textFields["import-assignment-episode"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.descendants(matching: .any)["import-entire-series"].exists)
    app.buttons["Cancel"].click()
    XCTAssertTrue(app.staticTexts["Edit Import Assignment"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["12 extras · 0 trailers"].exists)
    assertNoUnexpectedDialog(in: app)
  }

  @MainActor
  private func recordImportScreenshot(_ app: XCUIApplication, named name: String) {
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

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
    XCTAssertFalse(app.dialogs.firstMatch.exists, app.dialogs.debugDescription)
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
    XCTAssertFalse(app.buttons["library-review-metadata"].exists)
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
  func testServerSettingsExposeAllEightSectionsWithoutEnablingBackgroundService() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "server-settings"
    app.launch()
    app.activate()
    defer { app.terminate() }
    app.typeKey(",", modifierFlags: .command)
    let serverTab = app.buttons["Server"]
    XCTAssertTrue(serverTab.waitForExistence(timeout: 8))
    serverTab.click()
    XCTAssertTrue(app.staticTexts["Overview"].waitForExistence(timeout: 8))
    for section in [
      "Network", "Hosting", "Users & Access", "Devices & Security", "Library & Jobs", "Backups",
      "Diagnostics",
    ] {
      XCTAssertTrue(app.staticTexts[section].exists, "Missing server settings section: \(section)")
    }
    XCTAssertTrue(app.descendants(matching: .any)["server-hosting-mode"].exists)
    XCTAssertFalse(app.buttons["Try Network Settings (60-second rollback)"].isEnabled)
    XCTAssertFalse(app.buttons["Restart Server"].isEnabled)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Server settings - synthetic owner, no native host"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    XCTAssertFalse(app.staticTexts["The server returned an invalid response."].exists)
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
      ).first(where: {
        $0.bundleURL?.deletingLastPathComponent()
          == Bundle.main.bundleURL.deletingLastPathComponent()
      })?.bundleURL
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
  func testSidebarCanHideAndRestoreWithoutChangingTheLibrary() throws {
    let app = launchLibrary()
    defer { app.terminate() }

    let toggle = app.buttons["toggle-sidebar"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    toggle.click()
    XCTAssertFalse(app.descendants(matching: .any)["sidebar-library"].exists)
    XCTAssertTrue(app.buttons["media-10000000-0000-0000-0000-000000000001"].exists)
    XCTAssertEqual(toggle.label, "Show Sidebar")

    toggle.click()
    XCTAssertTrue(app.descendants(matching: .any)["sidebar-library"].waitForExistence(timeout: 5))
    XCTAssertEqual(toggle.label, "Hide Sidebar")
    XCTAssertTrue(app.buttons["media-10000000-0000-0000-0000-000000000001"].exists)
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
    let reviewQueue = app.buttons["library-review-metadata"]
    XCTAssertTrue(reviewQueue.waitForExistence(timeout: 5))
    reviewQueue.click()
    XCTAssertTrue(app.staticTexts["Review Queue"].waitForExistence(timeout: 5))
    app.buttons["Done"].click()

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
    let title = app.textFields["metadata-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.click()
    title.typeKey("a", modifierFlags: .command)
    title.typeText("Corrected Test Title")
    app.buttons["Cancel"].click()
    let keepEditing = app.windows.firstMatch.buttons["Keep Editing"]
    XCTAssertTrue(keepEditing.waitForExistence(timeout: 5))
    keepEditing.click()
    XCTAssertEqual(title.value as? String, "Corrected Test Title")
    for section in ["Production & Release", "Cast & Crew", "Artwork & File", "General"] {
      app.descendants(matching: .any)[section].firstMatch.click()
    }
    app.buttons["Save"].click()
    XCTAssertTrue(
      app.descendants(matching: .any)["metadata-editor"].waitForNonExistence(timeout: 5))
    actions.click()
    editMetadata.click()
    XCTAssertTrue(app.textFields["metadata-title"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.textFields["metadata-title"].value as? String, "Corrected Test Title")
    app.buttons["Cancel"].click()
  }

  @MainActor
  func testLibraryRightClickKeepsNavigationAndExposesScopedActions() throws {
    let app = XCUIApplication()
    configureTestLaunch(app)
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "library-admin"
    app.launch()
    app.activate()
    defer { app.terminate() }
    app.descendants(matching: .any)["sidebar-library"].click()
    let movie = app.buttons["media-10000000-0000-0000-0000-000000000001"]
    XCTAssertTrue(movie.waitForExistence(timeout: 8))
    movie.rightClick()
    XCTAssertTrue(app.menuItems["Remove from Favorites"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.menuItems["Edit Metadata…"].exists)
    XCTAssertTrue(app.menuItems["Remove from Library…"].exists)
    app.menuItems["Edit Metadata…"].click()
    XCTAssertTrue(app.textFields["metadata-title"].waitForExistence(timeout: 5))
    app.buttons["Cancel"].click()
    movie.click()
    XCTAssertTrue(app.buttons["play-media"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testMovieStartsNativePlayer() throws {
    let app = launchLibrary()
    defer { app.terminate() }

    app.buttons["media-10000000-0000-0000-0000-000000000001"].click()
    let hero = app.descendants(matching: .any)["media-hero"]
    XCTAssertTrue(hero.waitForExistence(timeout: 5))
    let detailScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    detailScreenshot.name = "Movie detail hero transition"
    detailScreenshot.lifetime = .keepAlways
    add(detailScreenshot)

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
    let rateMenu = app.descendants(matching: .any)["player-rate-menu"]
    XCTAssertTrue(rateMenu.exists)
    XCTAssertTrue(app.descendants(matching: .any)["player-audio-menu"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["player-subtitle-menu"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["player-sleep-menu"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["player-timeline"].exists)
    XCTAssertTrue(app.buttons["player-picture-in-picture"].exists)
    XCTAssertTrue(app.buttons["player-fullscreen"].exists)

    let window = app.windows.firstMatch
    let centerPlay = app.buttons["player-play-pause"]
    let title = app.staticTexts["player-title"]
    let timeline = app.descendants(matching: .any)["player-timeline"]
    XCTAssertTrue(title.exists)

    let centerY = window.frame.midY
    XCTAssertLessThan(rateMenu.frame.midY, centerY)
    XCTAssertGreaterThan(
      title.frame.midY, centerY,
      "Player title should be in the lower half. Title: \(title.frame), window: \(window.frame).")
    XCTAssertGreaterThan(timeline.frame.midY, centerY)
    XCTAssertGreaterThan(timeline.frame.minY, title.frame.maxY - 8)
    XCTAssertGreaterThan(abs(timeline.frame.midY - centerY), window.frame.height * 0.25)

    let preparing = app.descendants(matching: .any)["player-preparing"]
    if preparing.exists {
      XCTAssertFalse(centerPlay.exists, "The transport must not sit underneath the loading card.")
      XCTAssertLessThan(abs(preparing.frame.midY - centerY), window.frame.height * 0.12)
    } else {
      XCTAssertTrue(centerPlay.exists)
      XCTAssertLessThan(abs(centerPlay.frame.midY - centerY), window.frame.height * 0.12)
    }

    rateMenu.click()
    XCTAssertTrue(app.menuItems["Standard"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.menuItems["1.5x"].exists)
    app.typeKey(.escape, modifierFlags: [])
  }

  @MainActor
  private func assertNoUnexpectedDialog(in app: XCUIApplication) {
    XCTAssertFalse(app.alerts.firstMatch.exists)
    // macOS also exposes disabled, non-visible auxiliary panels as Dialogs.
    // They do not interrupt the app; visible dialogs, alerts and sheets do.
    XCTAssertFalse(
      app.dialogs.allElementsBoundByIndex.contains { $0.isHittable }, app.dialogs.debugDescription)
    XCTAssertFalse(app.sheets.firstMatch.exists)
  }

}
