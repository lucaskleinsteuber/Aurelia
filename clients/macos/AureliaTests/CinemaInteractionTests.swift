import AppKit
import Testing

@testable import Aurelia

@MainActor struct CinemaInteractionTests {
  private func candidate(_ title: String) -> MetadataCandidateSummary {
    MetadataCandidateSummary(
      provider: "Synthetic", providerMediaId: title, mediaType: "tv", title: title,
      originalTitle: nil, year: nil, overview: nil, posterPath: nil, confidence: 1)
  }

  @Test func metadataSearchRejectsLateResponsesAndClearsBlankQueries() async {
    let controller = MetadataSearchController()
    var pending: CheckedContinuation<[MetadataCandidateSummary], Never>?
    let older = Task {
      await controller.search(query: "old", debounce: .zero) { _ in
        await withCheckedContinuation { pending = $0 }
      }
    }
    while pending == nil { await Task.yield() }
    await controller.search(query: "  new  ", debounce: .zero) { query in
      #expect(query == "new")
      return [candidate(query)]
    }
    pending?.resume(returning: [candidate("old")])
    await older.value
    #expect(controller.candidates.map(\.title) == ["new"])
    #expect(!controller.isSearching)
    await controller.search(query: " \n ", debounce: .zero) { _ in
      Issue.record("Blank queries must not contact the provider")
      return []
    }
    #expect(controller.candidates.isEmpty && controller.errorMessage == nil)
    #expect(!controller.isSearching)
  }

  @Test func metadataSearchCancellationAndRetryNeverLeaveStaleResults() async {
    let controller = MetadataSearchController()
    await controller.search(query: "first", debounce: .zero) { _ in
      throw APIClientError.invalidResponse
    }
    #expect(controller.errorMessage != nil && !controller.isSearching)
    await controller.search(query: "retry", debounce: .zero) { _ in [candidate("retry")] }
    #expect(controller.errorMessage == nil && controller.candidates.count == 1)
    let cancelled = Task {
      await controller.search(query: "cancelled", debounce: .seconds(1)) { _ in
        Issue.record("Cancelled debounce must not contact the provider")
        return []
      }
    }
    cancelled.cancel()
    await cancelled.value
    #expect(!controller.isSearching && controller.errorMessage == nil)
    #expect(controller.candidates.isEmpty)
  }

  @Test func railPagesOnlyCompleteCardsAndClampsAtBothEnds() {
    var metrics = RailNavigationMetrics(offset: 0, maximumOffset: 3000, visibleWidth: 1100)
    #expect(!metrics.canGoBack && metrics.canGoForward)
    #expect(metrics.destination(forward: true, cardWidth: 420, spacing: 20, inset: 80) == 880)
    metrics.offset = 1000
    #expect(metrics.destination(forward: false, cardWidth: 420, spacing: 20, inset: 80) == 440)
    metrics.offset = 2640
    #expect(metrics.destination(forward: true, cardWidth: 420, spacing: 20, inset: 80) == 3000)
    metrics.offset = 0
    metrics.maximumOffset = 0
    #expect(!metrics.canGoBack && !metrics.canGoForward)
    metrics.maximumOffset = 800
    metrics.visibleWidth = 200
    #expect(metrics.destination(forward: true, cardWidth: 420, spacing: 20, inset: 80) == 440)
  }

  @Test func overlappingPlayerInteractionsAndStaleTimersNeverHideControls() {
    var policy = PlayerControlsPolicy()
    let old = policy.invalidate()
    policy.hold("menu", active: true)
    policy.hold("hover", active: true)
    #expect(!policy.permitsHide(old, preparing: false, error: false))
    policy.hold("menu", active: false)
    #expect(!policy.permitsHide(policy.generation, preparing: false, error: false))
    policy.hold("hover", active: false)
    #expect(policy.permitsHide(policy.generation, preparing: false, error: false))
    #expect(!policy.permitsHide(policy.generation, preparing: true, error: false))
    #expect(!policy.permitsHide(policy.generation, preparing: false, error: true))
    for reason in ["keyboard", "scrubbing", "volume", "preparation"] {
      policy.hold(reason, active: true)
      #expect(!policy.permitsHide(policy.generation, preparing: false, error: false))
      policy.hold(reason, active: false)
    }
  }

  @Test func idleControlTeardownDoesNotChangeTheScheduledHideGeneration() {
    var policy = PlayerControlsPolicy()
    let scheduled = policy.invalidate()
    // Native menu dismantling reports focus-end even when it never held focus.
    for reason in ["focus-subtitle", "focus-audio", "focus-rate", "back-hover", "keyboard"] {
      policy.hold(reason, active: false)
      #expect(policy.generation == scheduled)
      #expect(policy.permitsHide(scheduled, preparing: false, error: false))
    }
  }

  @Test func duplicateHoldsAndLateEndNotificationsAreNotNewInteractions() {
    var policy = PlayerControlsPolicy()
    let openedMenu = policy.hold("menu", active: true)
    #expect(openedMenu)
    let opened = policy.generation
    let duplicateOpen = policy.hold("menu", active: true)
    #expect(!duplicateOpen)
    #expect(policy.generation == opened)
    let closedMenu = policy.hold("menu", active: false)
    #expect(closedMenu)
    let closed = policy.generation
    let duplicateClose = policy.hold("menu", active: false)
    #expect(!duplicateClose)
    #expect(policy.generation == closed)
    #expect(policy.permitsHide(closed, preparing: false, error: false))
  }

  @Test func unchangedScreenPositionAndInvalidEventsAreNotPointerMovement() {
    var pointer = PlayerPointerActivity(position: CGPoint(x: 720, y: 350))
    for _ in 0..<20 {
      let moved = pointer.moved(to: CGPoint(x: 720, y: 350))
      #expect(!moved)
    }
    let movements = [
      pointer.moved(to: CGPoint(x: CGFloat.nan, y: 350)),
      pointer.moved(to: CGPoint(x: 720, y: CGFloat.infinity)),
      pointer.moved(to: CGPoint(x: 720.5, y: 350)),
      pointer.moved(to: CGPoint(x: 720.5, y: 350)),
      pointer.moved(to: CGPoint(x: -20, y: 350)),
    ]
    #expect(movements == [false, false, true, false, true])
  }

  @Test func tenSecondTransportUsesNumberedSymbols() {
    #expect(PlayerSeekGlyph.numberedSymbol(interval: 10, forward: false) == "gobackward.10")
    #expect(PlayerSeekGlyph.numberedSymbol(interval: 10, forward: true) == "goforward.10")
    #expect(PlayerSeekGlyph.numberedSymbol(interval: 37, forward: true) == nil)
  }

  @Test func cropPixelsMatchServerClockwiseRotationAndTopLeftCoordinates() throws {
    let source = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 400,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
    let green = NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1)
    let blue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
    let yellow = NSColor(deviceRed: 1, green: 1, blue: 0, alpha: 1)
    for y in 0..<400 {
      for x in 0..<600 {
        source.setColor(y < 200 ? (x < 300 ? red : green) : (x < 300 ? blue : yellow), atX: x, y: y)
      }
    }
    let image = NSImage(size: NSSize(width: 600, height: 400))
    image.addRepresentation(source)
    let crop = ArtworkCrop(x: 0, y: 1.0 / 3, width: 1, height: 2.0 / 3, rotation: 90)
    let result = CropImage.render(image, crop: crop)
    let cg = try #require(result.cgImage(forProposedRect: nil, context: nil, hints: nil))
    #expect(cg.width == 400 && cg.height == 400)
    let bitmap = NSBitmapImageRep(cgImage: cg)
    let topLeft = try #require(bitmap.colorAt(x: 80, y: 80)?.usingColorSpace(.deviceRGB))
    let topRight = try #require(bitmap.colorAt(x: 320, y: 80)?.usingColorSpace(.deviceRGB))
    let bottomLeft = try #require(bitmap.colorAt(x: 80, y: 320)?.usingColorSpace(.deviceRGB))
    let bottomRight = try #require(bitmap.colorAt(x: 320, y: 320)?.usingColorSpace(.deviceRGB))
    #expect(topLeft.blueComponent > 0.9 && topLeft.redComponent < 0.1)
    #expect(topRight.redComponent > 0.9 && topRight.greenComponent < 0.1)
    #expect(bottomLeft.redComponent > 0.9 && bottomLeft.greenComponent > 0.9)
    #expect(bottomRight.greenComponent > 0.9 && bottomRight.redComponent < 0.1)
    let thumbnail = CropImage.render(image, crop: crop, maximumDimension: 192)
    #expect(thumbnail.size.width == 192 && thumbnail.size.height == 192)
  }

  private func credit(
    _ name: String = "Actor", key: String? = "tmdb:person:1",
    department: String = "Acting", job: String? = nil, character: String? = nil, order: Int = 0,
    profile: ArtworkSummary? = nil
  ) -> CreditSummary {
    CreditSummary(
      name: name, department: department, job: job, character: character,
      order: order, profile: profile, personKey: key)
  }

  @Test func actorProducerAndMultipleCharactersBecomeOneCardWithoutMutatingCredits() {
    let credits = [
      credit(character: "Walter White"),
      credit(department: "Production", job: "Producer", order: 9),
      credit(character: "Heisenberg", order: 2),
    ]
    let cards = CreditPresentation.people(credits)
    #expect(cards.count == 1)
    #expect(cards[0].subtitle == "Walter White, Heisenberg")
    #expect(cards[0].order == 0)
    #expect(credits.count == 3 && credits[1].job == "Producer")
  }

  @Test func homonymsAndUnidentifiedCreditsAreNotNameMergedAndCrewRolesAreRetained() {
    let credits = [
      credit(key: "tmdb:person:1", character: "One"),
      credit(key: "tmdb:person:2", character: "Two"), credit(key: nil), credit(key: nil),
      credit("Director", key: "tmdb:person:3", department: "Directing", job: "Director", order: 4),
      credit("Director", key: "tmdb:person:3", department: "Writing", job: "Writer", order: 6),
    ]
    let cards = CreditPresentation.people(credits)
    #expect(cards.count == 5)
    #expect(cards.last?.subtitle == "Director, Writer")
    #expect(Set(cards.map(\.id)).count == 5)
  }

  @Test func actorOrderAndAvailableImageBeatEarlierCrewCredit() {
    let photo = ArtworkSummary(
      id: UUID(), kind: .profile, path: "/synthetic", contentType: "image/png", contentLength: 1)
    let cards = CreditPresentation.people([
      credit("Actor", department: "Production", job: "Producer", order: 0, profile: photo),
      credit("Second Actor", key: "tmdb:person:2", character: "Second", order: 1),
      credit(character: "First", order: 2),
    ])
    #expect(cards.map(\.name) == ["Second Actor", "Actor"])
    #expect(cards[1].profile == photo)
  }

  @Test func legacyCreditDocumentsStillDecodeWithoutPersonKeys() throws {
    let data = Data("{\"name\":\"Actor\",\"department\":\"Acting\",\"order\":0}".utf8)
    let value = try JSONDecoder().decode(CreditSummary.self, from: data)
    #expect(value.personKey == nil)
    #expect(CreditPresentation.people([value, value]).count == 2)
  }

  @Test(arguments: [2.0 / 3, 16.0 / 9, 1.0])
  func cropHandlesStayInBoundsAndPreserveAspectRatio(ratio: Double) {
    for handle in CropHandle.allCases {
      var value = ArtworkCropGeometry(size: CGSize(width: 1200, height: 800), ratio: ratio)
      value.resize(
        handle, delta: CGSize(width: -handle.horizontal * 100, height: -handle.vertical * 100))
      #expect(abs(value.rect.width / value.rect.height - ratio) < 0.000001)
      value.move(CGSize(width: 10000, height: -10000))
      #expect(value.crop.x >= 0 && value.crop.y >= 0)
      #expect(value.crop.x + value.crop.width <= 1.00000001)
      #expect(value.crop.y + value.crop.height <= 1.00000001)
      value.resize(
        handle, delta: CGSize(width: handle.horizontal * 10000, height: handle.vertical * 10000))
      #expect(abs(value.rect.width / value.rect.height - ratio) < 0.000001)
      #expect(value.rect.maxX <= value.imageSize.width + 0.00001)
      #expect(value.rect.maxY <= value.imageSize.height + 0.00001)
    }
  }

  @Test func cropRestoresExactCoordinatesAndUndoRedoRotateReset() {
    let saved = ArtworkCrop(x: 0.15, y: 0.2, width: 0.5, height: 0.5, rotation: 90)
    var value = ArtworkCropGeometry(size: CGSize(width: 800, height: 800), ratio: 1, initial: saved)
    #expect(value.crop == saved)
    var history = ArtworkCropHistory()
    let initial = value
    value.move(CGSize(width: 20, height: 40))
    history.record(initial, after: value)
    let moved = value
    history.undo(&value)
    #expect(value == initial)
    history.redo(&value)
    #expect(value == moved)
    let beforeRotation = value
    value.rotate()
    history.record(beforeRotation, after: value)
    #expect(value.crop.rotation == 180)
    history.undo(&value)
    #expect(value == beforeRotation)
    value.reset()
    #expect(value.crop == ArtworkCrop(x: 0, y: 0, width: 1, height: 1, rotation: 0))
  }

  @Test(arguments: [2.0 / 3, 16.0 / 9, 1.0])
  func cropZoomChangesSavedContentAndKeepsTheVisibleSelectionBounded(ratio: Double) {
    var value = ArtworkCropGeometry(size: CGSize(width: 1200, height: 800), ratio: ratio)
    let original = value.rect
    value.zoom(by: 2)
    #expect(abs(value.rect.width * 2 - original.width) < 0.000001)
    #expect(abs(value.rect.midX - original.midX) < 0.000001)
    #expect(abs(value.rect.midY - original.midY) < 0.000001)
    let bounds = original
    value.move(CGSize(width: 10000, height: -10000), within: bounds)
    #expect(bounds.contains(value.rect))
    value.resize(.bottomRight, delta: CGSize(width: 10000, height: 10000), within: bounds)
    #expect(value.rect.maxX <= bounds.maxX + 0.000001)
    #expect(value.rect.maxY <= bounds.maxY + 0.000001)
    #expect(abs(value.rect.width / value.rect.height - ratio) < 0.000001)
    value.zoom(by: 0.1)
    #expect(value.rect.minX >= 0 && value.rect.minY >= 0)
    #expect(value.rect.maxX <= value.imageSize.width + 0.000001)
    #expect(value.rect.maxY <= value.imageSize.height + 0.000001)
  }
}
