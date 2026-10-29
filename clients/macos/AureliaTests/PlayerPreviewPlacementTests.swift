import CoreGraphics
import Testing

@testable import Aurelia

struct PlayerPreviewPlacementTests {
  @Test func previewTracksThePointerAndFitsAtBothEdgesIncludingSmallWindows() {
    for timeline in [CGFloat(100), 192, 500, 1600] {
      let width = PlayerPreviewPlacement.width(in: timeline)
      #expect(width <= timeline)
      for position in [-100.0, 0, 250, 500, 750, 1000, 1200] {
        let x = PlayerPreviewPlacement.leading(
          timelineWidth: timeline, position: position, duration: 1000, previewWidth: width)
        #expect(x >= 0)
        #expect(x + width <= timeline)
      }
    }
    #expect(
      PlayerPreviewPlacement.leading(
        timelineWidth: 1000, position: 500, duration: 1000, previewWidth: 192) == 404)
  }

  @Test func entireBubbleClearsTheTitleAndTrailingControlRowAtEveryHeight() {
    for controlHeight in [CGFloat(42), 70, 120] {
      for bubbleHeight in [CGFloat(136), 180, 240] {
        let offset = PlayerPreviewPlacement.topAlignment(
          previewHeight: bubbleHeight, controlsHeight: controlHeight + 9)
        let bubble = CGRect(x: 0, y: -offset, width: 192, height: bubbleHeight)
        let controls = CGRect(x: 0, y: -controlHeight - 9, width: 500, height: controlHeight)
        #expect(!bubble.intersects(controls))
        #expect(bubble.maxY < controls.minY)
        #expect(bubble.maxY < 0)

        let vertical = PlayerPreviewPlacement.verticalOffset(
          previewHeight: bubbleHeight, controlsHeight: controlHeight + 9)
        #expect(vertical == -offset)
        #expect(vertical < 0)
      }
    }
  }

  @Test func invalidCoordinatesDoNotCreateNonfiniteViewPositions() {
    #expect(PlayerPreviewPlacement.width(in: .infinity) == 0)
    #expect(PlayerPreviewPlacement.width(in: -10) == 0)
    #expect(
      PlayerPreviewPlacement.leading(
        timelineWidth: 500, position: .nan, duration: 1000, previewWidth: 192) == 0)
    #expect(
      PlayerPreviewPlacement.leading(
        timelineWidth: 500, position: 10, duration: 0, previewWidth: 192) == 0)
  }
}
