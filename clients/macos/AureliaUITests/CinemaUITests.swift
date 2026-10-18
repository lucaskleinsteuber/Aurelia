import AppKit
import XCTest

final class CinemaUITests: XCTestCase {
  @MainActor func testSidebarStaysDarkAndLegibleAcrossArtworkAndWindowStates() throws {
    let app = launch(heroEdges: true)
    defer { app.terminate() }

    // The sidebar is a blurred panel like the Apple TV app's, so artwork beneath it may tint it.
    // It must stay a dark, even backdrop for its labels, with no black strip at the top.
    func checkCanvas(_ state: String) throws {
      let window = app.windows.firstMatch
      let sidebar = app.descendants(matching: .any)["primary-sidebar"]
      XCTAssertTrue(sidebar.exists)
      let captured = try XCTUnwrap(NSBitmapImageRep(data: window.screenshot().pngRepresentation))
      let image = try XCTUnwrap(captured.converting(to: .sRGB, renderingIntent: .default))
      let scaleX = CGFloat(image.pixelsWide) / window.frame.width
      let scaleY = CGFloat(image.pixelsHigh) / window.frame.height
      for fraction in [0.02, 0.70, 0.82, 0.94] {
        let x = Int((sidebar.frame.minX - window.frame.minX + 18) * scaleX)
        let y = Int(
          (sidebar.frame.minY - window.frame.minY + sidebar.frame.height * fraction) * scaleY)
        let color = try XCTUnwrap(image.colorAt(x: x, y: y))
        let luminance =
          0.2126 * color.redComponent + 0.7152 * color.greenComponent
          + 0.0722 * color.blueComponent
        XCTAssertLessThan(luminance, 0.3, "\(state) at \(fraction)")
        XCTAssertGreaterThan(luminance, 0.04, "\(state) at \(fraction)")
      }
      shot(app, "Sidebar - \(state)")
    }

    try checkCanvas("Series Artwork")
    app.descendants(matching: .any)["sidebar-home"].click()
    XCTAssertTrue(app.buttons["home-hero-action"].waitForExistence(timeout: 5))
    try checkCanvas("Home Artwork")
    XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
    try checkCanvas("Inactive Window")
    app.activate()
    app.windows.firstMatch.buttons[XCUIIdentifierFullScreenWindow].click()
    _ = XCTWaiter.wait(
      for: [XCTestExpectation(description: "Native fullscreen transition")], timeout: 2)
    try checkCanvas("Full Screen")
    app.buttons["toggle-sidebar"].click()
    XCTAssertFalse(app.descendants(matching: .any)["primary-sidebar"].exists)
    app.buttons["toggle-sidebar"].click()
    try checkCanvas("Restored Sidebar")
    app.typeKey("f", modifierFlags: [.control, .command])
  }

  @MainActor func testScrolledDetailShowsCompactHeaderWithTitleAndBack() throws {
    let app = launch()
    defer { app.terminate() }
    let hero = app.descendants(matching: .any)["media-hero"]
    XCTAssertTrue(hero.waitForExistence(timeout: 8))
    let header = app.descendants(matching: .any)["compact-header"]
    XCTAssertFalse(header.exists)
    XCTAssertEqual(app.buttons.matching(identifier: "Back").count, 1)
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
      .scroll(byDeltaX: 0, deltaY: -900)
    XCTAssertTrue(header.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["compact-header-title"].exists)
    shot(app, "Detail - Compact Header After Scrolling")
    header.buttons.firstMatch.click()
    XCTAssertTrue(hero.waitForNonExistence(timeout: 5))
    XCTAssertFalse(header.exists)
  }

  @MainActor func testFullscreenSidebarHeaderDoesNotOverlapNavigation() throws {
    let app = launch()
    defer { app.terminate() }
    app.windows.firstMatch.buttons[XCUIIdentifierFullScreenWindow].click()
    let transition = XCTWaiter.wait(
      for: [XCTestExpectation(description: "Fullscreen transition")], timeout: 2)
    XCTAssertEqual(transition, .timedOut)
    let toggle = app.buttons["toggle-sidebar"]
    let home = app.descendants(matching: .any)["sidebar-home"]
    XCTAssertTrue(toggle.exists && home.exists)
    XCTAssertLessThanOrEqual(toggle.frame.maxY, home.frame.minY)
    shot(app, "Cinema - Fullscreen - Sidebar Header and Hero")
    toggle.click()
    XCTAssertTrue(app.buttons["toggle-sidebar"].exists)
    XCTAssertLessThan(app.buttons["toggle-sidebar"].frame.minX, 30)
    shot(app, "Cinema - Fullscreen - Sidebar Hidden and Hero")
    app.buttons["toggle-sidebar"].click()
    XCTAssertTrue(home.waitForExistence(timeout: 5))
    home.click()
    XCTAssertTrue(app.buttons["home-hero-action"].waitForExistence(timeout: 5))
    shot(app, "Cinema - Fullscreen - Home Hero")
    app.typeKey("f", modifierFlags: [.control, .command])
  }

  @MainActor func testMetadataSearchAsYouTypeClearsStaleResultsAndHandlesErrors() throws {
    let app = launch()
    defer { app.terminate() }
    app.descendants(matching: .any)["media-actions"].click()
    app.menuItems["Find Metadata Match"].click()
    let query = app.textFields["metadata-match-query"]
    XCTAssertTrue(query.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Match: Breaking Bad"].waitForExistence(timeout: 5))
    func type(_ value: String) {
      query.click()
      app.typeKey("a", modifierFlags: .command)
      query.typeText(value.isEmpty ? XCUIKeyboardKey.delete.rawValue : value)
    }
    type("Slow match")
    let debounce = XCTWaiter.wait(
      for: [XCTestExpectation(description: "Older slow request starts")], timeout: 0.5)
    XCTAssertEqual(debounce, .timedOut)
    type("New match")
    XCTAssertTrue(app.staticTexts["Match: New match"].waitForExistence(timeout: 5))
    let staleWait = XCTWaiter.wait(
      for: [XCTestExpectation(description: "Late older response")], timeout: 1.2)
    XCTAssertEqual(staleWait, .timedOut)
    XCTAssertFalse(app.staticTexts["Match: Slow match"].exists)
    shot(app, "1.3 - Metadata - Live Search Without Search Button")
    type("")
    XCTAssertTrue(app.staticTexts["Match: New match"].waitForNonExistence(timeout: 5))
    type("Fail match")
    XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 5))
    shot(app, "1.3 - Metadata - Search Error Keeps Draft")
    type("Recovered")
    XCTAssertTrue(app.staticTexts["Match: Recovered"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Try Again"].exists)
    app.buttons["Done"].click()
    XCTAssertTrue(query.waitForNonExistence(timeout: 5))
  }

  @MainActor func testDetailHeroHasRealImageDetailAtBothVisibleEdges() throws {
    let app = launch(heroEdges: true)
    defer { app.terminate() }
    func checkEdges(_ label: String) throws {
      let window = app.windows.firstMatch
      let hero = app.descendants(matching: .any)["media-hero"]
      XCTAssertTrue(hero.exists)
      // Background extension exposes a larger AX frame including the sidebar.
      // Measure only the visible detail area, excluding the opaque navigation.
      let visibleLeft = max(hero.frame.minX, app.buttons["Back"].frame.minX - 32)
      let visibleRight = min(hero.frame.maxX, window.frame.maxX)
      let visibleWidth = visibleRight - visibleLeft
      XCTAssertGreaterThan(visibleWidth, 400)
      shot(app, "Cinema - Continuous Hero Edges - \(label)")
      let image = try XCTUnwrap(NSBitmapImageRep(data: window.screenshot().pngRepresentation))
      let scaleX = CGFloat(image.pixelsWide) / window.frame.width
      let scaleY = CGFloat(image.pixelsHigh) / window.frame.height
      let y = Int((hero.frame.minY - window.frame.minY + hero.frame.height * 0.25) * scaleY)
      for range in [0.04...0.12, 0.88...0.96] {
        let values = try (0..<64).map { sample -> CGFloat in
          let fraction =
            range.lowerBound + (range.upperBound - range.lowerBound)
            * Double(sample) / 63
          let x = Int((visibleLeft - window.frame.minX + visibleWidth * fraction) * scaleX)
          let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
          return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        XCTAssertGreaterThan(
          try XCTUnwrap(values.max()) - XCTUnwrap(values.min()), 0.20,
          "\(label): the actual image must reach the edge, not a blurred side strip")
      }
    }
    // Allow the asynchronous artwork loader to finish, then check rendered pixels.
    let loading = XCTWaiter.wait(
      for: [XCTestExpectation(description: "Synthetic artwork load")], timeout: 1)
    XCTAssertEqual(loading, .timedOut)
    try checkEdges("Window")
    app.windows.firstMatch.buttons[XCUIIdentifierFullScreenWindow].click()
    let transition = XCTWaiter.wait(
      for: [XCTestExpectation(description: "Fullscreen transition")], timeout: 2)
    XCTAssertEqual(transition, .timedOut)
    try checkEdges("Fullscreen")
    app.buttons["toggle-sidebar"].click()
    try checkEdges("Fullscreen Without Sidebar")
    app.typeKey("f", modifierFlags: [.control, .command])
  }

  @MainActor func testHomeAndCollectionHeroesHaveContinuousImageDetail() throws {
    var app = launch(heroEdges: true)
    defer { app.terminate() }
    app.descendants(matching: .any)["sidebar-home"].click()
    XCTAssertTrue(app.buttons["home-hero-action"].waitForExistence(timeout: 5))

    func checkEdges(_ identifier: String, anchor: String, label: String) throws {
      let window = app.windows.firstMatch
      let hero = app.descendants(matching: .any)[identifier]
      XCTAssertTrue(hero.exists)
      // Resolve AX coordinates after the sidebar/fullscreen layout transition,
      // not in the caller while the anchor still has its transient infinite frame.
      let loading = XCTWaiter.wait(
        for: [XCTestExpectation(description: "Synthetic hero artwork and layout")], timeout: 1)
      XCTAssertEqual(loading, .timedOut)
      let visibleLeft = max(window.frame.minX, app.buttons[anchor].frame.minX - 32)
      let visibleRight = min(hero.frame.maxX, window.frame.maxX)
      let width = visibleRight - visibleLeft
      XCTAssertTrue(width.isFinite)
      XCTAssertGreaterThan(width, 400)
      shot(app, "Cinema - Continuous \(label) Hero Edges")
      let image = try XCTUnwrap(NSBitmapImageRep(data: window.screenshot().pngRepresentation))
      let scaleX = CGFloat(image.pixelsWide) / window.frame.width
      let scaleY = CGFloat(image.pixelsHigh) / window.frame.height
      // Both pages open at the top. Sample the upper artwork below the native
      // header; background-extension AX bounds can include offscreen content.
      let y = Int(min(150, window.frame.height * 0.25) * scaleY)
      for range in [0.04...0.16, 0.84...0.96] {
        let values = try (0..<96).map { sample -> CGFloat in
          let fraction =
            range.lowerBound + (range.upperBound - range.lowerBound) * Double(sample) / 95
          let x = Int((visibleLeft - window.frame.minX + width * fraction) * scaleX)
          XCTAssertTrue(
            x >= 0 && x < image.pixelsWide && y >= 0 && y < image.pixelsHigh,
            "\(label): sample (\(x), \(y)) outside \(image.pixelsWide)x\(image.pixelsHigh); window \(window.frame), hero \(hero.frame), leading edge \(visibleLeft)"
          )
          let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
          return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        // Home/collection gradients intentionally darken the leading edge. Look
        // for repeated fine detail, not raw brightness or a single boundary.
        let transitions = zip(values, values.dropFirst()).filter { abs($0 - $1) > 0.025 }.count
        XCTAssertGreaterThanOrEqual(
          transitions, 5, "\(label): fine image detail must reach both visible edges")
      }
    }
    func homeEdges(_ label: String) throws {
      try checkEdges(
        "home-hero", anchor: "home-hero-action", label: label)
    }
    try homeEdges("Home Window")
    app.windows.firstMatch.buttons[XCUIIdentifierFullScreenWindow].click()
    let transition = XCTWaiter.wait(
      for: [XCTestExpectation(description: "Fullscreen transition")], timeout: 2)
    XCTAssertEqual(transition, .timedOut)
    try homeEdges("Home Fullscreen")
    app.buttons["toggle-sidebar"].click()
    try homeEdges("Home Fullscreen Without Sidebar")
    // Start the collection checks in a fresh native window. A fullscreen
    // Space transition must not leak state into the independent window case.
    app.terminate()
    app = launch(heroEdges: true)
    app.descendants(matching: .any)["sidebar-home"].click()
    XCTAssertTrue(app.buttons["home-hero-action"].waitForExistence(timeout: 5))
    let collection = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'collection-'")
    ).firstMatch
    // The Home collection row sits below other rails. Reveal it without letting
    // AX scroll a horizontal rail or alter unrelated view state.
    for _ in 0..<12 {
      if collection.exists,
        app.windows.firstMatch.frame.insetBy(dx: 80, dy: 120).contains(
          CGPoint(x: collection.frame.midX, y: collection.frame.midY))
      {
        break
      }
      detailScroll(app).scroll(byDeltaX: 0, deltaY: -200)
    }
    XCTAssertTrue(collection.exists)
    pointer(collection, in: app).click()
    XCTAssertTrue(app.descendants(matching: .any)["collection-hero"].waitForExistence(timeout: 5))
    try checkEdges(
      "collection-hero", anchor: "Back",
      label: "Collection Window")
    app.windows.firstMatch.buttons[XCUIIdentifierFullScreenWindow].click()
    let collectionTransition = XCTWaiter.wait(
      for: [XCTestExpectation(description: "Collection fullscreen transition")], timeout: 2)
    XCTAssertEqual(collectionTransition, .timedOut)
    try checkEdges(
      "collection-hero", anchor: "Back",
      label: "Collection Fullscreen")
    app.buttons["toggle-sidebar"].click()
    try checkEdges(
      "collection-hero", anchor: "Back",
      label: "Collection Fullscreen Without Sidebar")
    app.typeKey("f", modifierFlags: [.control, .command])
  }

  @MainActor private func launch(
    accessibility: Bool = false, minimum: Bool = false, heroEdges: Bool = false,
    advancingPlayback: Bool = false
  )
    -> XCUIApplication
  {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment["AURELIA_UI_TEST_MODE"] = "library-admin"
    app.launchEnvironment["AURELIA_CINEMA_UI_TESTS"] = "1"
    if advancingPlayback { app.launchEnvironment["AURELIA_AUTO_HIDE_UI_TESTS"] = "1" }
    if heroEdges { app.launchEnvironment["AURELIA_HERO_EDGE_UI_TESTS"] = "1" }
    if accessibility { app.launchEnvironment["AURELIA_CINEMA_ACCESSIBILITY"] = "1" }
    if minimum { app.launchEnvironment["AURELIA_CINEMA_MINIMUM_WINDOW"] = "1" }
    app.launch()
    app.activate()
    XCTAssertTrue(app.descendants(matching: .any)["sidebar-tvShows"].waitForExistence(timeout: 8))
    app.descendants(matching: .any)["sidebar-tvShows"].click()
    let series = app.buttons["media-20000000-0000-0000-0000-000000000001"]
    XCTAssertTrue(series.waitForExistence(timeout: 5))
    series.click()
    XCTAssertTrue(app.buttons["play-media"].waitForExistence(timeout: 5))
    return app
  }

  @MainActor func testMinimumWindowInactiveWindowNativeFullScreenAndAccessibility() throws {
    let app = launch(minimum: true)
    let window = app.windows.firstMatch
    XCTAssertLessThanOrEqual(window.frame.width, 780)
    XCTAssertTrue(app.buttons["play-media"].exists)
    shot(app, "Cinema - Minimum Window - Hero")
    let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
    finder.activate()
    shot(app, "Cinema - Inactive Window")
    app.activate()
    window.buttons[XCUIIdentifierFullScreenWindow].click()
    let wait = XCTWaiter.wait(
      for: [XCTestExpectation(description: "Native fullscreen transition")], timeout: 2)
    XCTAssertEqual(wait, .timedOut)
    shot(app, "Cinema - Native Fullscreen - Hero")
    app.typeKey("f", modifierFlags: [.control, .command])
    app.terminate()

    let accessible = launch(accessibility: true)
    defer { accessible.terminate() }
    shot(accessible, "Cinema - Reduce Transparency Motion and Increase Contrast")
    let scroll = detailScroll(accessible)
    scroll.scroll(byDeltaX: 0, deltaY: -400)
    accessible.buttons["episode-1-1"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .hover()
    let next = accessible.buttons["rail-Episodes-next"]
    XCTAssertTrue(next.waitForExistence(timeout: 5))
    pointer(next, in: accessible).click()
    shot(accessible, "Cinema - Accessible Episode Arrows")
  }

  @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor private func detailScroll(_ app: XCUIApplication) -> XCUICoordinate {
    // Scroll at a known point in the visible main column. Nested horizontal
    // scroll views must not be mistaken for the outer vertical scroll view.
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
  }

  @MainActor private func pointer(_ element: XCUIElement, in app: XCUIApplication) -> XCUICoordinate
  {
    let window = app.windows.firstMatch
    let frame = element.frame
    XCTAssertFalse(frame.isInfinite)
    XCTAssertFalse(frame.isEmpty)
    // Anchor physical input to the window. AX auto-scrolling an element inside
    // an extended rail or nested sheet can scroll its unrelated ancestor instead.
    return window.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: frame.midX - window.frame.minX, dy: frame.midY - window.frame.minY))
  }

  @MainActor private func selectEditorSection(_ name: String, in app: XCUIApplication) {
    let editor = app.descendants(matching: .any)["metadata-editor"].firstMatch.frame
    // Native segmented controls may expose the picker's identifier on each
    // segment. Select the visible segment, never a title behind the sheet.
    let matches = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@ OR identifier == %@", name, name))
    let segment = matches.allElementsBoundByIndex.first {
      let frame = $0.frame
      return frame.minY >= editor.minY && frame.maxY < editor.minY + 130
        && frame.width > 0 && frame.height < 50
    }
    XCTAssertNotNil(segment, "Editor segment \(name) must be visible")
    if let segment { pointer(segment, in: app).click() }
  }

  @MainActor func testRailArrowsAndLocalizedSidebarUseTheActualScrollableCards() throws {
    let app = launch()
    defer { app.terminate() }
    shot(app, "Cinema - Hero - Reference Size")
    let scroll = detailScroll(app)
    // Scroll the page from above the rails: synthesized wheel events have no gesture phase, so
    // their tail would otherwise land on the episode rail that just moved under the pointer.
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.15))
      .scroll(byDeltaX: 0, deltaY: -340)
    let first = app.buttons["episode-1-1"]
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    let next = app.buttons["rail-Episodes-next"]
    XCTAssertTrue(next.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["rail-Episodes-previous"].exists)
    let initialX = first.frame.minX
    let pageAnchor = app.buttons["episode-1-3"]
    let initialPageX = pageAnchor.frame.minX
    shot(app, "Cinema - Episodes - Hover Before Paging")
    pointer(next, in: app).click()
    let previous = app.buttons["rail-Episodes-previous"]
    XCTAssertTrue(previous.waitForExistence(timeout: 5))
    shot(app, "Cinema - Episodes - Cards Behind Sidebar")
    XCTAssertLessThan(pageAnchor.frame.minX, initialPageX - 400)
    XCTAssertEqual(pageAnchor.frame.minX, initialX, accuracy: 3)
    pointer(previous, in: app).click()
    XCTAssertTrue(previous.waitForNonExistence(timeout: 5))
    // All detail rail types share the same component, but each owns its offset.
    for name in ["Trailers", "Extras", "Cast & Crew"] {
      let visibleCard =
        name == "Cast & Crew"
        ? app.staticTexts["Person 2"]
        : app.buttons[
          name == "Trailers"
            ? "supplement-50000000-0000-0000-0000-000000000011"
            : "supplement-50000000-0000-0000-0000-000000000001"]
      // Fixed scroll deltas can leave a lazy row outside the visible window.
      // Reveal the target before hovering; never send pointer input offscreen.
      let viewport = app.windows.firstMatch.frame.insetBy(dx: 80, dy: 120)
      for _ in 0..<10 {
        if visibleCard.exists
          && viewport.contains(CGPoint(x: visibleCard.frame.midX, y: visibleCard.frame.midY))
        {
          break
        }
        let above = visibleCard.exists && visibleCard.frame.midY < viewport.minY
        scroll.scroll(byDeltaX: 0, deltaY: above ? 180 : -180)
      }
      XCTAssertTrue(visibleCard.exists, "\(name) must have a visible card")
      XCTAssertTrue(
        viewport.contains(CGPoint(x: visibleCard.frame.midX, y: visibleCard.frame.midY)),
        "\(name) must be onscreen")
      pointer(visibleCard, in: app).hover()
      let arrow = app.buttons.matching(
        NSPredicate(format: "identifier CONTAINS %@ AND identifier ENDSWITH %@", name, "next")
      ).firstMatch
      shot(app, "Cinema - \(name) - Hover Before Arrow")
      XCTAssertTrue(arrow.waitForExistence(timeout: 5), "Missing \(name) next arrow")
      pointer(arrow, in: app).hover()
      pointer(arrow, in: app).click()
      shot(app, "Cinema - \(name) - Arrow Page")
    }
    XCTAssertEqual(app.staticTexts.matching(identifier: "Bryan Cranston").count, 1)
    XCTAssertFalse(app.staticTexts["Acting"].exists)
    let sidebar = app.descendants(matching: .any)["sidebar-library"]
    sidebar.click()
    XCTAssertTrue(app.textFields["library-search"].waitForExistence(timeout: 5))
  }

  @MainActor func testMetadataEditorDescriptionPhotoLayoutAndRealCropHandles() throws {
    let app = launch()
    defer { app.terminate() }
    let actions = app.descendants(matching: .any)["media-actions"]
    XCTAssertTrue(
      app.windows.firstMatch.frame.contains(CGPoint(x: actions.frame.midX, y: actions.frame.midY)))
    pointer(actions, in: app).click()
    app.menuItems["Edit Metadata"].click()
    XCTAssertTrue(app.textFields["metadata-title"].waitForExistence(timeout: 5))
    let description = app.textViews["metadata-description"]
    XCTAssertTrue(description.exists)
    description.click()
    description.typeKey("a", modifierFlags: .command)
    description.typeText("A multiline\nsynthetic description.")
    description.typeKey("z", modifierFlags: .command)
    shot(app, "Cinema - Editor - General")
    selectEditorSection("Cast & Crew", in: app)
    XCTAssertTrue(app.buttons["Add Person"].waitForExistence(timeout: 5))
    shot(app, "Cinema - Editor - Circular Photos and Separate Actions")
    selectEditorSection("Artwork & File", in: app)
    shot(app, "Cinema - Editor - Artwork")
    let crop = app.buttons["metadata-crop-backdrop"]
    XCTAssertTrue(crop.waitForExistence(timeout: 5))
    XCTAssertTrue(crop.isEnabled)
    if !crop.isHittable {
      app.scrollViews["metadata-editor-scroll"].scroll(byDeltaX: 0, deltaY: -300)
    }
    XCTAssertTrue(crop.isHittable)
    crop.click()
    shot(app, "Cinema - Crop - Immediately After Opening")
    let opened = app.buttons["crop-use"].waitForExistence(timeout: 8)
    shot(app, "Cinema - Crop - Finished Loading")
    XCTAssertTrue(
      opened,
      app.buttons.allElementsBoundByIndex.map { "\($0.identifier): \($0.label)" }.joined(
        separator: "\n"))
    let handle = app.descendants(matching: .any)["crop-handle-bottomRight"]
    XCTAssertTrue(handle.exists)
    let start = pointer(handle, in: app)
    let selection = app.descendants(matching: .any)["crop-frame"]
    let originalFrame = selection.frame
    start.click(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -80, dy: -45)))
    let undo = app.buttons["crop-undo"]
    shot(app, "Cinema - Crop - Resized Selection")
    XCTAssertTrue(undo.isEnabled)
    XCTAssertLessThan(selection.frame.width, originalFrame.width - 30)
    undo.click()
    XCTAssertEqual(selection.frame.width, originalFrame.width, accuracy: 2)
    XCTAssertTrue(app.buttons["crop-redo"].isEnabled)
    app.buttons["crop-redo"].click()
    app.buttons["crop-rotate"].click()
    shot(app, "Cinema - Crop - Clockwise Rotation")
    app.buttons["crop-reset"].click()
    let finalHandle = pointer(app.descendants(matching: .any)["crop-handle-bottomRight"], in: app)
    finalHandle.click(
      forDuration: 0.1, thenDragTo: finalHandle.withOffset(CGVector(dx: -100, dy: -60)))
    let move = pointer(selection, in: app)
    move.click(forDuration: 0.1, thenDragTo: move.withOffset(CGVector(dx: 20, dy: 15)))
    let savedFrame = selection.frame
    shot(app, "Cinema - Crop - Off Center Before Save")
    app.buttons["crop-use"].click()
    XCTAssertTrue(app.buttons["crop-use"].waitForNonExistence(timeout: 5))
    app.buttons["Save"].click()
    XCTAssertTrue(app.textFields["metadata-title"].waitForNonExistence(timeout: 5))
    pointer(actions, in: app).click()
    app.menuItems["Edit Metadata"].click()
    XCTAssertTrue(app.textFields["metadata-title"].waitForExistence(timeout: 5))
    selectEditorSection("Artwork & File", in: app)
    app.buttons["metadata-crop-backdrop"].click()
    XCTAssertTrue(app.buttons["crop-use"].waitForExistence(timeout: 5))
    XCTAssertEqual(selection.frame.width, savedFrame.width, accuracy: 2)
    XCTAssertEqual(selection.frame.minX, savedFrame.minX, accuracy: 2)
    XCTAssertEqual(selection.frame.minY, savedFrame.minY, accuracy: 2)
    shot(app, "Cinema - Crop - Reopened Saved Selection")
    app.buttons["crop-cancel"].click()
    selectEditorSection("Cast & Crew", in: app)
    XCTAssertTrue(app.buttons["Add Person"].waitForExistence(timeout: 5))
    app.menuButtons["Photo"].firstMatch.click()
    app.menuItems["Crop…"].click()
    XCTAssertTrue(app.buttons["crop-use"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["1:1"].exists)
    let personFrame = app.descendants(matching: .any)["crop-frame"].frame
    XCTAssertEqual(personFrame.width, personFrame.height, accuracy: 1)
    let zoom = app.sliders["crop-zoom"]
    zoom.adjust(toNormalizedSliderPosition: 0.2)
    shot(app, "Cinema - Person Crop - Zoom and Circular Preview")
    let zoomedFrame = app.descendants(matching: .any)["crop-frame"].frame
    XCTAssertEqual(zoomedFrame.width, personFrame.width, accuracy: 2)
    XCTAssertEqual(zoomedFrame.minX, personFrame.minX, accuracy: 2)
    XCTAssertEqual(zoomedFrame.minY, personFrame.minY, accuracy: 2)
    XCTAssertTrue(app.buttons["crop-undo"].isEnabled)
    let zoomedHandle = app.descendants(matching: .any)["crop-handle-bottomRight"]
    XCTAssertTrue(zoomedHandle.isHittable)
    let imagePan = pointer(selection, in: app).withOffset(
      CGVector(dx: -zoomedFrame.width / 2 - 35, dy: 0))
    imagePan.click(forDuration: 0.1, thenDragTo: imagePan.withOffset(CGVector(dx: 30, dy: 10)))
    XCTAssertEqual(selection.frame.minX, zoomedFrame.minX, accuracy: 2)
    XCTAssertEqual(selection.frame.minY, zoomedFrame.minY, accuracy: 2)
    shot(app, "Cinema - Person Crop - Image Panned Under Visible Frame")
    app.buttons["crop-undo"].click()
    XCTAssertTrue(app.buttons["crop-redo"].isEnabled)
    app.buttons["crop-redo"].click()
    app.buttons["crop-cancel"].click()
    // Cancelling a crop must leave the person's original selection untouched.
    app.menuButtons["Photo"].firstMatch.click()
    app.menuItems["Crop…"].click()
    XCTAssertTrue(app.buttons["crop-use"].waitForExistence(timeout: 5))
    XCTAssertEqual(
      app.descendants(matching: .any)["crop-frame"].frame.width, personFrame.width, accuracy: 1)
    app.sliders["crop-zoom"].adjust(toNormalizedSliderPosition: 0.2)
    app.buttons["crop-use"].click()
    app.buttons["Save"].click()
    XCTAssertTrue(app.textFields["metadata-title"].waitForNonExistence(timeout: 5))
    actions.click()
    app.menuItems["Edit Metadata"].click()
    XCTAssertTrue(app.textFields["metadata-title"].waitForExistence(timeout: 5))
    selectEditorSection("Cast & Crew", in: app)
    app.menuButtons["Photo"].firstMatch.click()
    app.menuItems["Crop…"].click()
    XCTAssertTrue(app.buttons["crop-use"].waitForExistence(timeout: 5))
    XCTAssertLessThan(selection.frame.width, personFrame.width * 0.7)
    shot(app, "Cinema - Person Crop - Zoom Persisted After Editor Save")
    app.buttons["crop-cancel"].click()
  }

  @MainActor func testRailEndsShortSeasonAndHomeUseTheSameNavigation() throws {
    let app = launch()
    defer { app.terminate() }
    detailScroll(app).scroll(byDeltaX: 0, deltaY: -340)
    pointer(app.buttons["episode-1-1"], in: app).hover()
    let next = app.buttons["rail-Episodes-next"]
    var pages = 0
    while next.exists, pages < 8 {
      pointer(next, in: app).hover()
      pointer(next, in: app).click()
      pages += 1
      let settled = XCTWaiter.wait(
        for: [XCTestExpectation(description: "Page animation settles")], timeout: 0.4)
      XCTAssertEqual(settled, .timedOut)
    }
    shot(app, "Cinema - Episode Rail - End Before Assertions")
    XCTAssertGreaterThan(pages, 1)
    XCTAssertFalse(next.exists)
    XCTAssertTrue(app.buttons["rail-Episodes-previous"].exists)
    let last = app.buttons["episode-1-12"]
    XCTAssertTrue(last.exists)
    // AX frames round independently to backing pixels at the window edge.
    XCTAssertLessThanOrEqual(last.frame.maxX, app.windows.firstMatch.frame.maxX + 1)
    shot(app, "Cinema - Episode Rail - End")
    app.descendants(matching: .any)["season-1"].click()
    app.menuItems["Season 2"].click()
    XCTAssertTrue(app.buttons["episode-2-1"].waitForExistence(timeout: 5))
    XCTAssertFalse(next.exists)
    XCTAssertFalse(app.buttons["rail-Episodes-previous"].exists)
    shot(app, "Cinema - Short Season - No Arrows")
    app.descendants(matching: .any)["sidebar-home"].click()
    detailScroll(app).scroll(byDeltaX: 0, deltaY: -2500)
    pointer(app.buttons["media-60000000-0000-0000-0000-000000000001"], in: app).hover()
    shot(app, "Cinema - Home - Hover Before Arrow")
    let homeNext = app.buttons["rail-Recently Added-next"]
    XCTAssertTrue(homeNext.waitForExistence(timeout: 5))
    pointer(homeNext, in: app).hover()
    pointer(homeNext, in: app).click()
    XCTAssertTrue(app.buttons["rail-Recently Added-previous"].waitForExistence(timeout: 5))
    shot(app, "Cinema - Home - Shared Arrow Navigation")
  }

  @MainActor func testPlayerNativeMenusSurviveTheAutoHideDelayAndCleanUpOnEscape() throws {
    // Menus are tested during healthy playback, not an intentional decoder
    // stall. Keep the production stall watchdog enabled and advance the fixture.
    let app = launch(advancingPlayback: true)
    defer { app.terminate() }
    app.buttons["play-media"].click()
    XCTAssertTrue(app.buttons["player-play-pause"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["Playback Unavailable"].exists)
    for (identifier, option) in [
      ("player-subtitle-menu", "English SDH"), ("player-audio-menu", "German"),
      ("player-rate-menu", "Standard"), ("player-sleep-menu", "15 minutes"),
      ("player-chapter-menu", "Introduction  0:00"),
    ] {
      app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.35))
        .hover()
      let menu = app.buttons[identifier]
      XCTAssertTrue(menu.waitForExistence(timeout: 5))
      menu.hover()
      menu.click()
      let popup = app.menuItems[option]
      XCTAssertTrue(popup.waitForExistence(timeout: 5))
      let wait = XCTWaiter.wait(
        for: [XCTestExpectation(description: "Menu remains open past auto-hide")], timeout: 3.2)
      XCTAssertEqual(wait, .timedOut)
      XCTAssertTrue(popup.exists)
      XCTAssertTrue(app.buttons["player-play-pause"].exists)
      shot(app, "Cinema - Player - \(identifier) Remains Open")
      app.typeKey(.escape, modifierFlags: [])
      XCTAssertTrue(popup.waitForNonExistence(timeout: 5))
      XCTAssertTrue(app.buttons["player-play-pause"].exists)
    }
    app.buttons["player-play-pause"].hover()
    shot(app, "Cinema - Player - Centered Transport Symbols")
    app.buttons["player-back"].click()
    XCTAssertTrue(app.buttons["play-media"].waitForExistence(timeout: 5))
  }
}
