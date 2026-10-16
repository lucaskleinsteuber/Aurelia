import XCTest

/// Separately selected, explicitly opted-in check of the one approved episode.
/// No fixtures, credentials, server calls, screenshots or video are created here.
final class TVDeviceCheckTests: XCTestCase {
  private var playbackBegan: ContinuousClock.Instant?
  private var previousNext: Bool?
  private var previousResume: Bool?

  @MainActor
  func testApprovedEpisodeOnPhysicalAppleTV() throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(
      environment["AURELIA_TV_DEVICE_CHECK"] == "1"
        && environment["AURELIA_TV_DEVICE_MEDIA_CHECKED"] == "1"
        && environment["AURELIA_TV_DEVICE_READY"] == "1",
      "Physical playback requires the explicit device invocation, prior file metadata check and a ready TV."
    )
    #if targetEnvironment(simulator)
      throw XCTSkip("This opt-in check requires the paired physical Apple TV.")
    #else
      guard environment["AURELIA_TV_DEVICE_TITLE"] == "Breaking Bad",
        environment["AURELIA_TV_DEVICE_EPISODE_TITLE"] == "Pilot"
      else { throw XCTSkip("Only the approved Breaking Bad S01 E01 Pilot check is allowed.") }
      executionTimeAllowance = 240
      continueAfterFailure = false
      let app = XCUIApplication(bundleIdentifier: "com.lucas.aurelia.tvos")
      // Activate the existing normal connection, never launch a test environment
      // or clear the user's current profile, connection, preferences or Keychain.
      app.launchArguments = []
      app.launchEnvironment = [:]
      app.activate()
      // XCTest teardown runs after skips and assertion failures as well.
      addTeardownBlock { @MainActor in self.stopAndRestore(app) }
      guard app.buttons["Home"].firstMatch.waitForExistence(timeout: 20) else {
        throw XCTSkip(
          "Unlock a profile directly on Apple TV, then invoke this check again. No PIN was read.")
      }
      try preparePlaybackSettings(app)
      try selectTab(app, index: 3)
      let search = app.textFields["library-search"]
      XCUIRemote.shared.press(.down)
      try focus(search, in: app)
      XCUIRemote.shared.press(.select)
      search.typeText("Breaking Bad")
      XCUIRemote.shared.press(.menu)
      let series: XCUIElement
      if let identifier = environment["AURELIA_TV_DEVICE_SERIES_ID"],
        UUID(uuidString: identifier) != nil
      {
        series =
          app.buttons.matching(NSPredicate(format: "identifier ==[c] %@", "catalog-\(identifier)"))
          .firstMatch
      } else {
        let matches = app.buttons.matching(
          NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH[c] %@", "catalog-",
            "Breaking Bad"))
        guard matches.firstMatch.waitForExistence(timeout: 15), matches.count == 1 else {
          throw XCTSkip(
            "The approved series is not uniquely identifiable; provide its external series ID.")
        }
        series = matches.element(boundBy: 0)
      }
      try focus(series, in: app)
      guard series.label.localizedCaseInsensitiveContains("Breaking Bad") else {
        throw XCTSkip("The selected catalog card does not match the approved series.")
      }
      XCUIRemote.shared.press(.select)
      let season = app.buttons["detail-season"]
      guard season.waitForExistence(timeout: 12) else {
        throw XCTSkip("Approved series details are unavailable.")
      }
      try focus(season, in: app)
      if season.label != "Season 1" {
        XCUIRemote.shared.press(.select)
        let firstSeason = app.buttons["season-option-1"]
        try focus(firstSeason, in: app)
        XCUIRemote.shared.press(.select)
      }
      let episode: XCUIElement
      if let identifier = environment["AURELIA_TV_DEVICE_EPISODE_ID"],
        UUID(uuidString: identifier) != nil
      {
        episode =
          app.buttons.matching(
            NSPredicate(format: "identifier ==[c] %@", "detail-episode-\(identifier)")
          ).firstMatch
      } else {
        episode =
          app.buttons.matching(
            NSPredicate(
              format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND label CONTAINS[c] %@",
              "detail-episode-", "S01 E01", "Pilot")
          ).firstMatch
      }
      try focus(episode, in: app)
      guard episode.label.contains("S01 E01"),
        episode.label.localizedCaseInsensitiveContains("Pilot"), episode.isEnabled
      else {
        throw XCTSkip("The exact approved S01 E01 Pilot episode is not available and playable.")
      }
      playbackBegan = .now
      print("AURELIA_DEVICE_CHECK: approved episode playback begins; no other title may start.")
      XCUIRemote.shared.press(.select)
      try checkPlayer(app)
      print("AURELIA_DEVICE_CHECK: completed bounded control and resume observations.")
    #endif
  }

  @MainActor
  private func preparePlaybackSettings(_ app: XCUIApplication) throws {
    try selectTab(app, index: 4)
    XCUIRemote.shared.press(.down)
    try focus(app.buttons["profile-playback-settings"], in: app)
    XCUIRemote.shared.press(.select)
    let next = app.descendants(matching: .any).matching(identifier: "settings-next").firstMatch
    try focus(next, in: app)
    let nextWasOn = try toggleState(next)
    previousNext = nextWasOn
    if nextWasOn { XCUIRemote.shared.press(.select) }
    guard try !toggleState(next) else {
      throw XCTSkip("Automatic next-episode playback could not be disabled.")
    }
    let resume = app.descendants(matching: .any).matching(identifier: "settings-resume").firstMatch
    try focus(resume, in: app)
    previousResume = try toggleState(resume)
    if previousResume == false { XCUIRemote.shared.press(.select) }
    guard try toggleState(resume) else {
      throw XCTSkip("Automatic Resume could not be enabled for the check.")
    }
    let seek = app.descendants(matching: .any).matching(identifier: "settings-seek").firstMatch
    guard seek.exists, (seek.value as? String ?? seek.label).contains("10") else {
      throw XCTSkip(
        "Set Seek Interval to 10 seconds in normal Playback Settings before this check.")
    }
    guard !app.staticTexts["Preferences could not be saved."].exists else {
      throw XCTSkip("Playback settings could not be saved; no media will be started.")
    }
    print(
      "AURELIA_DEVICE_CHECK: Automatic Next verified Off; Automatic Resume On; 10-second seek verified."
    )
    XCUIRemote.shared.press(.menu)
  }

  @MainActor
  private func stopAndRestore(_ app: XCUIApplication) {
    // A teardown error must not abort the remaining cleanup operations.
    continueAfterFailure = true
    let surface = app.descendants(matching: .any).matching(identifier: "player-surface").firstMatch
    for _ in 0..<4 {
      guard
        surface.exists || app.buttons["player-play"].exists
          || app.buttons["player-tracks-done"].exists
      else { break }
      XCUIRemote.shared.press(.menu)
    }
    let stopped = surface.waitForNonExistence(timeout: 3) && !app.buttons["player-play"].exists
    playbackBegan = nil
    if stopped, previousNext != nil || previousResume != nil {
      do { try restorePlaybackSettings(app) } catch {
        print(
          "AURELIA_DEVICE_CHECK GAP: normal preferences could not be restored through the UI after stopping playback."
        )
        XCTFail(
          "Restore the previous Next and Resume settings manually; automated UI restoration was unavailable."
        )
      }
    } else if !stopped {
      print(
        "AURELIA_DEVICE_CHECK GAP: player did not close through Back; terminating it. Next/Resume preferences require manual restoration."
      )
      XCTFail(
        "The player required forced application termination; check the previous Next/Resume settings manually."
      )
    }
    app.terminate()
  }

  @MainActor
  private func restorePlaybackSettings(_ app: XCUIApplication) throws {
    // All media has stopped before restoring normal user settings.
    try selectTab(app, index: 4)
    XCUIRemote.shared.press(.down)
    try focus(app.buttons["profile-playback-settings"], in: app)
    XCUIRemote.shared.press(.select)
    for (identifier, previous) in [
      ("settings-next", previousNext), ("settings-resume", previousResume),
    ] {
      guard let previous else { continue }
      let toggle = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
      try focus(toggle, in: app)
      if try toggleState(toggle) != previous { XCUIRemote.shared.press(.select) }
      XCTAssertEqual(try toggleState(toggle), previous)
    }
    XCUIRemote.shared.press(.menu)
    print(
      "AURELIA_DEVICE_CHECK: original Next and Resume preferences restored after playback stopped.")
  }

  @MainActor
  private func checkPlayer(_ app: XCUIApplication) throws {
    try withinPlaybackBudget()
    let play = app.buttons["player-play"]
    XCTAssertTrue(play.waitForExistence(timeout: 20), "Player controls did not become available.")
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: play)
    XCTAssertEqual(
      XCTWaiter.wait(for: [ready], timeout: 20), .completed, "The player never became ready.")
    XCTAssertTrue(
      play.waitForNonExistence(timeout: 12), "Controls did not hide during running playback.")
    XCTAssertFalse(
      app.progressIndicators["player-loading"].exists,
      "Loading indicator remained on the running picture.")
    XCUIRemote.shared.press(.playPause)
    XCTAssertTrue(play.waitForExistence(timeout: 4))
    XCTAssertEqual(play.label, "Play", "The hardware Play/Pause button did not pause.")
    XCUIRemote.shared.press(.down)
    let timeline = app.buttons["player-timeline"]
    try focus(timeline, in: app)
    let before = try seconds(timeline)
    XCUIRemote.shared.press(.right)
    try waitForPosition(timeline, minimum: before + 8, maximum: before + 12)
    XCUIRemote.shared.press(.left)
    try waitForPosition(timeline, minimum: max(0, before - 2), maximum: before + 2)
    XCUIRemote.shared.press(.up)
    try checkTrackMenu(app, identifier: "audio", rowPrefix: "player-audioTrack(")
    try checkTrackMenu(app, identifier: "subtitles", rowPrefix: "player-subtitleTrack(")
    try withinPlaybackBudget()
    // Save a position that differs from the initial resume point, then close.
    try focus(play, in: app)
    XCUIRemote.shared.press(.playPause)
    try waitForPosition(timeline, minimum: before + 3, maximum: .max, timeout: 10)
    XCUIRemote.shared.press(.playPause)
    let saved = try seconds(timeline)
    XCUIRemote.shared.press(.menu)
    let approvedEpisode = app.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND label CONTAINS[c] %@",
        "detail-episode-", "S01 E01", "Pilot")
    ).firstMatch
    try focus(approvedEpisode, in: app)
    // Reopening the exact episode cannot follow a series plan to a new title.
    XCUIRemote.shared.press(.select)
    XCTAssertTrue(play.waitForExistence(timeout: 15))
    let resumed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: play)
    XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 20), .completed)
    XCUIRemote.shared.press(.playPause)
    try waitForPosition(timeline, minimum: max(0, saved - 3), maximum: saved + 8, timeout: 8)
    print("AURELIA_DEVICE_CHECK: exit/resume position verified at approximately \(saved) seconds.")
    try withinPlaybackBudget()
    XCUIRemote.shared.press(.menu)
  }

  @MainActor
  private func checkTrackMenu(_ app: XCUIApplication, identifier: String, rowPrefix: String) throws
  {
    try withinPlaybackBudget()
    let button = app.buttons["player-\(identifier)"]
    guard button.exists, button.isEnabled else {
      print("AURELIA_DEVICE_CHECK GAP: no available \(identifier) action on the approved episode.")
      return
    }
    try focus(button, in: app)
    XCUIRemote.shared.press(.select)
    let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", rowPrefix))
    guard rows.firstMatch.waitForExistence(timeout: 6) else {
      XCTFail("Track menu did not become available.")
      return
    }
    let selected = rows.matching(NSPredicate(format: "selected == true")).firstMatch
    let selectedID = selected.exists ? selected.identifier : nil
    let alternate = rows.allElementsBoundByIndex.first {
      $0.identifier != selectedID && $0.isHittable
    }
    if let alternate {
      try focus(alternate, in: app)
      XCUIRemote.shared.press(.select)
      XCTAssertTrue(app.buttons["player-tracks-done"].waitForNonExistence(timeout: 3))
      XCTAssertTrue(
        app.staticTexts["player-track-pending"].waitForNonExistence(timeout: 12),
        "The decoder did not confirm the requested track selection.")
      try focus(button, in: app)
      XCUIRemote.shared.press(.select)
      let chosen = app.buttons[alternate.identifier]
      XCTAssertTrue(chosen.waitForExistence(timeout: 4))
      XCTAssertTrue(
        chosen.isSelected, "The selected decoder track did not match the requested track.")
      XCUIRemote.shared.press(.menu)
      print(
        "AURELIA_DEVICE_CHECK: \(identifier) decoder selection confirmed; audible output and on-screen subtitle rendering still require visual observation."
      )
    } else {
      print("AURELIA_DEVICE_CHECK GAP: no alternative \(identifier) track was available.")
      XCUIRemote.shared.press(.menu)
    }
  }

  @MainActor
  private func selectTab(_ app: XCUIApplication, index: Int) throws {
    for _ in 0..<10 {
      if ["Home", "Movies", "TV Shows", "Search"].contains(where: {
        app.buttons[$0].firstMatch.hasFocus
      }) {
        break
      }
      XCUIRemote.shared.press(.up)
    }
    for _ in 0..<4 { XCUIRemote.shared.press(.left) }
    guard app.buttons["Home"].firstMatch.hasFocus else {
      throw XCTSkip("The native tab bar could not be focused safely.")
    }
    for _ in 0..<index { XCUIRemote.shared.press(.right) }
    XCUIRemote.shared.press(.select)
  }

  @MainActor
  private func focus(_ target: XCUIElement, in app: XCUIApplication) throws {
    guard target.waitForExistence(timeout: 10) else {
      throw XCTSkip("A required normal UI action is unavailable.")
    }
    for _ in 0..<20 {
      try withinPlaybackBudget()
      if target.hasFocus { return }
      let upper = ["player-rate", "player-audio", "player-subtitles", "player-sleep"]
      let upperFocused = upper.contains { app.buttons[$0].hasFocus }
      if upper.contains(target.identifier), !upperFocused {
        XCUIRemote.shared.press(.up)
        continue
      }
      if target.identifier == "player-play", upperFocused {
        XCUIRemote.shared.press(.down)
        continue
      }
      if target.identifier == "player-play", app.buttons["player-timeline"].hasFocus {
        XCUIRemote.shared.press(.up)
        continue
      }
      if target.identifier == "player-timeline" {
        XCUIRemote.shared.press(.down)
        continue
      }
      let current = app.descendants(matching: .any).matching(
        NSPredicate(format: "hasFocus == true")
      ).firstMatch
      guard current.exists else {
        XCUIRemote.shared.press(.down)
        continue
      }
      let dx = target.frame.midX - current.frame.midX
      let dy = target.frame.midY - current.frame.midY
      if abs(dy) > abs(dx) {
        XCUIRemote.shared.press(dy > 0 ? .down : .up)
      } else {
        XCUIRemote.shared.press(dx > 0 ? .right : .left)
      }
    }
    XCTFail("The required action could not be reached with the remote.")
    throw TVDeviceCheckFailure.unreachableAction
  }

  @MainActor
  private func toggleState(_ element: XCUIElement) throws -> Bool {
    switch (element.value as? String ?? "").lowercased() {
    case "1", "on", "true": return true
    case "0", "off", "false": return false
    default: throw XCTSkip("The toggle state could not be verified; no playback is allowed.")
    }
  }

  private func withinPlaybackBudget() throws {
    if let playbackBegan, playbackBegan.duration(to: .now) >= .seconds(210) {
      throw XCTSkip("The bounded device check reached its stop deadline.")
    }
  }

  @MainActor
  private func seconds(_ element: XCUIElement) throws -> Int {
    let time = (element.value as? String ?? "").components(separatedBy: " of ")[0]
    let fields = time.split(separator: ":").compactMap { Int($0) }
    guard !fields.isEmpty else { throw XCTSkip("The actual playback position is unavailable.") }
    return fields.reduce(0) { $0 * 60 + $1 }
  }

  @MainActor
  private func waitForPosition(
    _ element: XCUIElement, minimum: Int, maximum: Int, timeout: TimeInterval = 6
  ) throws {
    try withinPlaybackBudget()
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while ContinuousClock.now < deadline {
      try withinPlaybackBudget()
      if let value = try? seconds(element), value >= minimum, value <= maximum { return }
      // A synchronous expectation keeps XCTest's main run loop moving without
      // sending actor-isolated UI state into an NSPredicate callback.
      let delay = XCTNSPredicateExpectation(predicate: NSPredicate(value: false), object: nil)
      _ = XCTWaiter.wait(for: [delay], timeout: 0.15)
    }
    XCTFail("The actual playback position did not match the requested operation.")
  }
}

private enum TVDeviceCheckFailure: Error { case unreachableAction }
