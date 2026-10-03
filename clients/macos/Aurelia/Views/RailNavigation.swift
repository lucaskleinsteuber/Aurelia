import AppKit
import SwiftUI

private struct SidebarOverlapKey: EnvironmentKey {
  static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
  var aureliaSidebarOverlap: CGFloat {
    get { self[SidebarOverlapKey.self] }
    set { self[SidebarOverlapKey.self] = newValue }
  }
}

/// Coordinates are relative to the resting content inset, never the obscured sidebar.
struct RailNavigationMetrics: Equatable {
  var offset: CGFloat = 0
  var maximumOffset: CGFloat = 0
  var visibleWidth: CGFloat = 0
  var contentInset: CGFloat = 0

  var canGoBack: Bool { offset > 1 }
  var canGoForward: Bool { offset < maximumOffset - 1 }

  func destination(forward: Bool, cardWidth: CGFloat, spacing: CGFloat, inset: CGFloat) -> CGFloat {
    let stride = max(1, cardWidth + spacing)
    let available = max(0, visibleWidth - inset - AureliaDesign.pagePadding)
    let count = max(1, Int((available + spacing) / stride))
    // Snap the leading card after trackpad scrolling, rather than accumulating drift.
    let index = forward ? floor((offset + 0.5) / stride) : ceil((offset - 0.5) / stride)
    return min(maximumOffset, max(0, (index + CGFloat(forward ? count : -count)) * stride))
  }
}

struct RailArrow: View {
  let forward: Bool
  let title: String
  let action: () -> Void
  @Environment(\.aureliaReduceTransparency) private var reduceTransparency
  @Environment(\.aureliaContrast) private var contrast

  var body: some View {
    Button(action: action) {
      Image(systemName: forward ? "chevron.right" : "chevron.left")
        .font(.system(size: 20, weight: .medium))
        .frame(width: 28, height: 52)
        .background {
          if reduceTransparency {
            Capsule().fill(AureliaDesign.raisedSurface)
          } else {
            Capsule().fill(.regularMaterial)
          }
        }
        .overlay { Capsule().stroke(.white.opacity(contrast == .increased ? 0.6 : 0.12)) }
        .frame(width: 44, height: 60)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(forward ? "Next" : "Previous") \(title)")
    .accessibilityIdentifier("rail-\(title)-\(forward ? "next" : "previous")")
  }
}

/// One tracking region spans the row, including child cards and its edge buttons.
/// It never consumes a click or relies on an individual card's hover lifecycle.
struct RailHoverRegion: NSViewRepresentable {
  let onHover: (Bool) -> Void
  func makeNSView(context: Context) -> Probe {
    let view = Probe()
    view.onHover = onHover
    return view
  }
  func updateNSView(_ view: Probe, context: Context) { view.onHover = onHover }
  final class Probe: NSView {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(
        rect: .zero,
        options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
        owner: self)
      addTrackingArea(area)
      tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseMoved(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
  }
}

/// App-local native overlay scrollers. No global defaults or private SwiftUI classes.
struct AureliaOverlayScrollbars: NSViewRepresentable {
  func makeNSView(context: Context) -> Probe { Probe() }
  func updateNSView(_ view: Probe, context: Context) { view.apply() }

  final class Probe: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      apply()
    }

    func apply() {
      DispatchQueue.main.async { [weak self] in
        guard let root = self?.window?.contentView else { return }
        Self.configure(root)
      }
    }

    private static func configure(_ view: NSView) {
      if let scroll = view as? NSScrollView {
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller?.controlSize = .small
        scroll.horizontalScroller?.controlSize = .small
      }
      for child in view.subviews { configure(child) }
    }
  }
}

extension View {
  func aureliaOverlayScrollbars() -> some View {
    background(AureliaOverlayScrollbars().allowsHitTesting(false))
  }
}
