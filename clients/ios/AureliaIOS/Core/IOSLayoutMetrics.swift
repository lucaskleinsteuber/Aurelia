import CoreGraphics
import Foundation

/// Pure layout metrics for iPhone and iPad that adapt to window size class,
/// orientation, container width, and accessibility Dynamic Type sizes instead of
/// assuming every iPad window is full-screen.
enum IOSLayoutMetrics: Sendable {
  /// Side margin of a screen: uses compact margins when an iPad window is in
  /// Slide Over or narrow Split View.
  static func margin(isRegularWidth: Bool) -> CGFloat {
    isRegularWidth ? 28 : 16
  }

  /// Minimum column width for poster grids: avoids collapsing to a single oversized column in
  /// 320 pt Slide Over, and widens columns at accessibility text sizes so titles stay legible.
  static func posterGridMinimum(isRegularWidth: Bool, isAccessibilitySize: Bool) -> CGFloat {
    if isAccessibilitySize {
      return isRegularWidth ? 200 : 150
    }
    return isRegularWidth ? 140 : 100
  }

  /// Minimum column width for people grids.
  static func peopleGridMinimum(isRegularWidth: Bool, isAccessibilitySize: Bool) -> CGFloat {
    if isAccessibilitySize {
      return isRegularWidth ? 180 : 144
    }
    return isRegularWidth ? 120 : 96
  }

  /// Width of a poster card in a horizontal shelf.
  static func posterWidth(isRegularWidth: Bool, isAccessibilitySize: Bool) -> CGFloat {
    if isAccessibilitySize {
      return isRegularWidth ? 190 : 156
    }
    return isRegularWidth ? 150 : 112
  }

  /// Width of a Continue Watching landscape card; capped to fit inside compact / Slide Over widths.
  static func landscapeCardWidth(
    isRegularWidth: Bool, availableWidth: CGFloat? = nil
  ) -> CGFloat {
    let base: CGFloat = isRegularWidth ? 340 : 272
    guard let availableWidth, availableWidth > 0 else { return base }
    let side = margin(isRegularWidth: isRegularWidth)
    return max(200, min(base, availableWidth - side * 2))
  }

  /// Width of a wide episode or supplement card on title detail pages; capped so it never
  /// overflows Slide Over (320 pt) or narrow Split View.
  static func wideCardWidth(
    isRegularWidth: Bool, availableWidth: CGFloat? = nil
  ) -> CGFloat {
    let base: CGFloat = isRegularWidth ? 420 : 300
    guard let availableWidth, availableWidth > 0 else { return base }
    let side = margin(isRegularWidth: isRegularWidth)
    return max(220, min(base, availableWidth - side * 2))
  }

  /// Height of the Home full-bleed hero backdrop, scaled down in landscape so the title and
  /// primary action remain visible above the fold.
  static func heroBackdropHeight(
    isRegularWidth: Bool, isCompactHeight: Bool, isAccessibilitySize: Bool
  ) -> CGFloat {
    if isCompactHeight { return isAccessibilitySize ? 300 : 260 }
    if isAccessibilitySize { return isRegularWidth ? 560 : 500 }
    return isRegularWidth ? 560 : 450
  }

  /// Height of the Title Detail / Collection header backdrop.
  static func detailBackdropHeight(
    isRegularWidth: Bool, isCompactHeight: Bool
  ) -> CGFloat {
    if isCompactHeight { return 210 }
    return isRegularWidth ? 440 : 320
  }

  /// Side length and spacing of the PIN keypad buttons so the 3×4 grid never overflows
  /// 320 pt Slide Over horizontally or clips vertically on iPhone SE / landscape.
  static func pinKeyMetrics(
    availableWidth: CGFloat, availableHeight: CGFloat, isCompactHeight: Bool
  ) -> (diameter: CGFloat, horizontalSpacing: CGFloat, verticalSpacing: CGFloat) {
    if isCompactHeight {
      let maxFromHeight = floor((availableHeight - 72) / 4)
      let diameter = min(68, max(50, maxFromHeight))
      return (diameter, 16, 10)
    }
    let usableWidth = max(220, availableWidth - 32)
    let horizontalSpacing: CGFloat = usableWidth < 300 ? 14 : 24
    let maxFromWidth = floor((usableWidth - horizontalSpacing * 2) / 3)
    let maxFromHeight: CGFloat = availableHeight < 640 ? 64 : 76
    let diameter = min(76, max(54, min(maxFromWidth, maxFromHeight)))
    let verticalSpacing: CGFloat = diameter < 68 ? 10 : 14
    return (diameter, horizontalSpacing, verticalSpacing)
  }

  /// Readable line-length maximum for wide iPad screens.
  static let readableContentMaxWidth: CGFloat = 780

  /// Whether the player top bar should fold secondary controls into an overflow menu.
  static func playerUsesOverflowMenu(availableWidth: CGFloat, trailingItemCount: Int) -> Bool {
    guard trailingItemCount > 3 else { return false }
    // Side margins (32) + Close (44) + gap (12) + Rate (~64) + remaining circles (44 + 8 each).
    let estimated = 32 + 44 + 12 + 64 + CGFloat(max(0, trailingItemCount - 1)) * 52
    return estimated > availableWidth
  }

  /// Maximum safe height for the floating security alert banner so it never exceeds landscape height.
  static func securityBannerMaxHeight(availableHeight: CGFloat) -> CGFloat {
    max(160, min(420, floor(availableHeight * 0.6)))
  }

  /// Format remaining watch time cleanly ("1 h left" instead of "1 h 0 min left").
  static func remainingTimeText(minutes: Int) -> String? {
    guard minutes > 0 else { return nil }
    if minutes < 60 { return "\(minutes) min left" }
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours) h left" : "\(hours) h \(remainder) min left"
  }

  /// Format a screen-time daily limit cleanly ("15 min" instead of "0 h 15 min").
  static func durationLimitText(minutes: Int) -> String {
    guard minutes > 0 else { return "0 min" }
    if minutes < 60 { return "\(minutes) min" }
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) min"
  }

  /// Singular or plural English phrase for counts.
  static func countPhrase(_ count: Int, singular: String, plural: String) -> String {
    count == 1 ? "1 \(singular)" : "\(count) \(plural)"
  }
}
