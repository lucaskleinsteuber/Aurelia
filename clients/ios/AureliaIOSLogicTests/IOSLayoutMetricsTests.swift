import CoreGraphics
import Testing

@Suite("iOS Adaptive Layout Metrics")
struct IOSLayoutMetricsTests {
  private struct Viewport: Sendable {
    let name: String
    let width: CGFloat
    let height: CGFloat
    let isRegularWidth: Bool
    let isCompactHeight: Bool
  }

  private static let viewports: [Viewport] = [
    .init(
      name: "iPhone SE Portrait", width: 375, height: 667, isRegularWidth: false,
      isCompactHeight: false),
    .init(
      name: "iPhone SE Landscape", width: 667, height: 375, isRegularWidth: false,
      isCompactHeight: true),
    .init(
      name: "iPhone 17 Pro Portrait", width: 402, height: 874, isRegularWidth: false,
      isCompactHeight: false),
    .init(
      name: "iPhone 17 Pro Landscape", width: 874, height: 402, isRegularWidth: false,
      isCompactHeight: true),
    .init(
      name: "iPhone 17 Pro Max Portrait", width: 440, height: 956, isRegularWidth: false,
      isCompactHeight: false),
    .init(
      name: "iPad Slide Over", width: 320, height: 744, isRegularWidth: false,
      isCompactHeight: false),
    .init(
      name: "iPad Split View 1/3", width: 375, height: 1024, isRegularWidth: false,
      isCompactHeight: false),
    .init(
      name: "iPad Split View 1/2", width: 507, height: 1024, isRegularWidth: false,
      isCompactHeight: false),
    .init(
      name: "iPad mini Portrait", width: 744, height: 1133, isRegularWidth: true,
      isCompactHeight: false),
    .init(
      name: "iPad Pro 13-inch Portrait", width: 1032, height: 1376, isRegularWidth: true,
      isCompactHeight: false),
    .init(
      name: "iPad Pro 13-inch Landscape", width: 1376, height: 1032, isRegularWidth: true,
      isCompactHeight: false),
  ]

  @Test func compactWidthUsesCompactMarginsAndFitsSlideOver() {
    #expect(IOSLayoutMetrics.margin(isRegularWidth: false) == 16)
    #expect(IOSLayoutMetrics.margin(isRegularWidth: true) == 28)

    let slideOverLandscape = IOSLayoutMetrics.landscapeCardWidth(
      isRegularWidth: false, availableWidth: 320)
    #expect(slideOverLandscape <= 320 - 32)
    #expect(slideOverLandscape >= 200)

    let slideOverWide = IOSLayoutMetrics.wideCardWidth(
      isRegularWidth: false, availableWidth: 320)
    #expect(slideOverWide <= 320 - 32)
    #expect(slideOverWide >= 220)
  }

  @Test func everyDeviceViewportFitsCardsGridsAndPinKeypadWithoutOverflow() {
    for viewport in Self.viewports {
      let sideMargin = IOSLayoutMetrics.margin(isRegularWidth: viewport.isRegularWidth)
      let innerWidth = viewport.width - sideMargin * 2
      #expect(innerWidth >= 288, "\(viewport.name) inner width too narrow: \(innerWidth)")

      let landscapeWidth = IOSLayoutMetrics.landscapeCardWidth(
        isRegularWidth: viewport.isRegularWidth, availableWidth: viewport.width)
      #expect(
        landscapeWidth <= innerWidth,
        "\(viewport.name) Continue Watching card \(landscapeWidth) exceeds inner width \(innerWidth)"
      )

      let wideCard = IOSLayoutMetrics.wideCardWidth(
        isRegularWidth: viewport.isRegularWidth, availableWidth: viewport.width)
      #expect(
        wideCard <= innerWidth,
        "\(viewport.name) wide episode card \(wideCard) exceeds inner width \(innerWidth)")

      for ax in [false, true] {
        let posterMin = IOSLayoutMetrics.posterGridMinimum(
          isRegularWidth: viewport.isRegularWidth, isAccessibilitySize: ax)
        #expect(
          posterMin <= innerWidth,
          "\(viewport.name) poster grid minimum \(posterMin) exceeds inner width \(innerWidth)")

        let peopleMin = IOSLayoutMetrics.peopleGridMinimum(
          isRegularWidth: viewport.isRegularWidth, isAccessibilitySize: ax)
        #expect(
          peopleMin <= innerWidth,
          "\(viewport.name) people grid minimum \(peopleMin) exceeds inner width \(innerWidth)")

        let shelfPoster = IOSLayoutMetrics.posterWidth(
          isRegularWidth: viewport.isRegularWidth, isAccessibilitySize: ax)
        #expect(
          shelfPoster <= innerWidth,
          "\(viewport.name) shelf poster \(shelfPoster) exceeds inner width \(innerWidth)")

        let heroHeight = IOSLayoutMetrics.heroBackdropHeight(
          isRegularWidth: viewport.isRegularWidth,
          isCompactHeight: viewport.isCompactHeight,
          isAccessibilitySize: ax)
        #expect(
          heroHeight <= viewport.height * 0.85,
          "\(viewport.name) hero height \(heroHeight) leaves too little room on \(viewport.height)")
      }

      let keypad = IOSLayoutMetrics.pinKeyMetrics(
        availableWidth: viewport.width, availableHeight: viewport.height,
        isCompactHeight: viewport.isCompactHeight)
      let keypadWidth = keypad.diameter * 3 + keypad.horizontalSpacing * 2
      let keypadHeight = keypad.diameter * 4 + keypad.verticalSpacing * 3
      #expect(keypad.diameter >= 44, "\(viewport.name) PIN button smaller than 44 pt")
      #expect(
        keypadWidth <= viewport.width - 32,
        "\(viewport.name) PIN keypad width \(keypadWidth) overflows \(viewport.width)")
      #expect(
        keypadHeight <= viewport.height - 40,
        "\(viewport.name) PIN keypad height \(keypadHeight) overflows \(viewport.height)")

      let bannerMax = IOSLayoutMetrics.securityBannerMaxHeight(availableHeight: viewport.height)
      #expect(bannerMax <= viewport.height * 0.65)
    }
  }

  @Test func accessibilitySizesWidenGridColumns() {
    let normalPhone = IOSLayoutMetrics.posterGridMinimum(
      isRegularWidth: false, isAccessibilitySize: false)
    let axPhone = IOSLayoutMetrics.posterGridMinimum(
      isRegularWidth: false, isAccessibilitySize: true)
    #expect(axPhone > normalPhone)

    let normalPad = IOSLayoutMetrics.posterGridMinimum(
      isRegularWidth: true, isAccessibilitySize: false)
    let axPad = IOSLayoutMetrics.posterGridMinimum(
      isRegularWidth: true, isAccessibilitySize: true)
    #expect(axPad > normalPad)
  }

  @Test func playerTopBarUsesOverflowOnNarrowWidthsOnly() {
    #expect(IOSLayoutMetrics.playerUsesOverflowMenu(availableWidth: 320, trailingItemCount: 8))
    #expect(IOSLayoutMetrics.playerUsesOverflowMenu(availableWidth: 375, trailingItemCount: 7))
    #expect(!IOSLayoutMetrics.playerUsesOverflowMenu(availableWidth: 1024, trailingItemCount: 8))
    #expect(!IOSLayoutMetrics.playerUsesOverflowMenu(availableWidth: 375, trailingItemCount: 3))
  }

  @Test func heroBackdropCompactsInLandscape() {
    let portrait = IOSLayoutMetrics.heroBackdropHeight(
      isRegularWidth: false, isCompactHeight: false, isAccessibilitySize: false)
    let landscape = IOSLayoutMetrics.heroBackdropHeight(
      isRegularWidth: false, isCompactHeight: true, isAccessibilitySize: false)
    #expect(landscape < portrait)
    #expect(landscape <= 280)
  }

  @Test func securityBannerHeightStaysWithinLandscapeViewport() {
    #expect(IOSLayoutMetrics.securityBannerMaxHeight(availableHeight: 375) <= 240)
    #expect(IOSLayoutMetrics.securityBannerMaxHeight(availableHeight: 1024) == 420)
  }

  @Test func timeAndCountFormattingHandlesZeroAndSingular() {
    #expect(IOSLayoutMetrics.remainingTimeText(minutes: 0) == nil)
    #expect(IOSLayoutMetrics.remainingTimeText(minutes: 45) == "45 min left")
    #expect(IOSLayoutMetrics.remainingTimeText(minutes: 60) == "1 h left")
    #expect(IOSLayoutMetrics.remainingTimeText(minutes: 95) == "1 h 35 min left")

    #expect(IOSLayoutMetrics.durationLimitText(minutes: 15) == "15 min")
    #expect(IOSLayoutMetrics.durationLimitText(minutes: 60) == "1 h")
    #expect(IOSLayoutMetrics.durationLimitText(minutes: 90) == "1 h 30 min")

    #expect(IOSLayoutMetrics.countPhrase(1, singular: "episode", plural: "episodes") == "1 episode")
    #expect(
      IOSLayoutMetrics.countPhrase(2, singular: "episode", plural: "episodes") == "2 episodes")
  }
}
