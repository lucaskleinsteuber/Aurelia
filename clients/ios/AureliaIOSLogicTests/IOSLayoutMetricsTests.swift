import CoreGraphics
import Testing

@Suite("iOS Adaptive Layout Metrics")
struct IOSLayoutMetricsTests {
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

  @Test func pinKeypadFitsSlideOverAndLandscapeHeights() {
    let slideOver = IOSLayoutMetrics.pinKeyMetrics(
      availableWidth: 320, availableHeight: 744, isCompactHeight: false)
    let totalWidth = slideOver.diameter * 3 + slideOver.horizontalSpacing * 2
    #expect(totalWidth <= 320 - 32)

    let seLandscape = IOSLayoutMetrics.pinKeyMetrics(
      availableWidth: 667, availableHeight: 375, isCompactHeight: true)
    let totalHeight = seLandscape.diameter * 4 + seLandscape.verticalSpacing * 3
    #expect(totalHeight <= 375 - 40)
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
