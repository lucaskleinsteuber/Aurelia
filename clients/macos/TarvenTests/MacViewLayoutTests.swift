import AppKit
import SwiftUI
import Testing

@testable import Tarven

@Suite("Mac Sheet & Row Layout")
@MainActor
struct MacViewLayoutTests {
  @Test func mediaManagerStorageLocationRowKeepsLabelsUncrushedAtMinimumSheetWidth() throws {
    let model = AppModel(store: InMemoryServerProfileStore(), profileSelectionEnabled: false)
    let library = LibrarySummary(
      id: UUID(),
      name: "Archive Drive",
      path: "/Volumes/Archive Drive/Media/Movies and Classics",
      kind: .movies,
      availability: .unavailable,
      createdAt: "2026-01-01T00:00:00Z",
      lastScanStartedAt: nil,
      lastScanCompletedAt: nil,
      lastError: nil,
      monitoringEnabled: true,
      importPreviewRequired: true)

    let host = NSHostingView(
      rootView: VStack(alignment: .leading, spacing: 16) {
        LibraryLocationRow(library: library, canEdit: true)
      }
      .padding(20)
      .environmentObject(model)
      .frame(width: 560))
    let window = NSWindow(
      contentRect: NSRect(x: -20_000, y: -20_000, width: 560, height: 320),
      styleMask: [.titled, .resizable],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }

    host.frame = NSRect(x: 0, y: 0, width: 560, height: 320)
    host.layoutSubtreeIfNeeded()

    let fitting = host.fittingSize
    #expect(fitting.width <= 620)
    #expect(fitting.height <= 170)

    func checkNoCrushedTallSubviews(_ view: NSView) -> [String] {
      guard !view.isHidden, view.alphaValue > 0.01 else { return [] }
      var problems: [String] = []
      if view.bounds.width > 6, view.bounds.width < 28, view.bounds.height > 44,
        !(view is NSScroller)
      {
        problems.append(
          "\(type(of: view)) width=\(Int(view.bounds.width)) height=\(Int(view.bounds.height))")
      }
      for subview in view.subviews {
        problems.append(contentsOf: checkNoCrushedTallSubviews(subview))
      }
      return problems
    }

    let crushed = checkNoCrushedTallSubviews(host)
    #expect(crushed.isEmpty, "Storage location row crushed text vertically: \(crushed)")
  }

  @Test func checkboxInsideSettingRowsKeepsLeadingCompactHitTarget() {
    var checked = false
    let box = WidthBox()
    let toggle = Toggle(
      isOn: Binding(get: { checked }, set: { checked = $0 })
    ) {
      HStack(spacing: 8) {
        Image(systemName: "tv")
        Text("Breaking Bad").lineLimit(1)
      }
    }
    .toggleStyle(.checkbox)
    .labeledContentStyle(.automatic)
    .background(WidthProbe(box: box))

    let host = NSHostingView(
      rootView: HStack(spacing: 8) {
        toggle
        Spacer()
        Text("2008")
      }
      .tarvenSettingRows()
      .frame(width: 500))
    let window = NSWindow(
      contentRect: NSRect(x: -20_000, y: -20_000, width: 500, height: 40),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    host.frame = NSRect(x: 0, y: 0, width: 500, height: 40)
    host.layoutSubtreeIfNeeded()

    #expect(box.width > 60)
    #expect(
      box.width < 240,
      "Checkbox inside .tarvenSettingRows() must stay compact on the leading side, got \(box.width)"
    )
  }
}

@MainActor
private final class WidthBox {
  var width: CGFloat = 0
}

private struct WidthProbe: NSViewRepresentable {
  let box: WidthBox
  func makeNSView(context: Context) -> ProbeView {
    let view = ProbeView()
    view.box = box
    return view
  }
  func updateNSView(_ nsView: ProbeView, context: Context) {
    nsView.box = box
    box.width = nsView.bounds.width
  }
  final class ProbeView: NSView {
    var box: WidthBox?
    override func layout() {
      super.layout()
      box?.width = bounds.width
    }
  }
}
