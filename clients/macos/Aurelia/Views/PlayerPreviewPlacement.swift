import CoreGraphics

/// Positions the complete bubble (including its time label) above the controls,
/// not just above the slider. All coordinates are local to the timeline.
enum PlayerPreviewPlacement {
  static func width(in timelineWidth: CGFloat) -> CGFloat {
    timelineWidth.isFinite ? min(192, max(0, timelineWidth)) : 0
  }

  static func leading(
    timelineWidth: CGFloat, position: Double, duration: Double, previewWidth: CGFloat
  ) -> CGFloat {
    guard timelineWidth.isFinite, previewWidth.isFinite, position.isFinite,
      duration.isFinite, duration > 0
    else { return 0 }
    let center = max(0, timelineWidth) * min(max(position / duration, 0), 1)
    return min(max(center - previewWidth / 2, 0), max(timelineWidth - previewWidth, 0))
  }

  static func topAlignment(previewHeight: CGFloat, controlsHeight: CGFloat) -> CGFloat {
    max(0, previewHeight) + max(0, controlsHeight) + 8
  }
}
