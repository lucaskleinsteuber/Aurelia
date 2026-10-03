import AppKit
import SwiftUI

@MainActor struct ArtworkCropSheet: View {
  @Environment(\.dismiss) private var dismiss
  let image: NSImage
  let ratio: Double
  let roundPreview: Bool
  let onSave: (ArtworkCrop) -> Void
  @State private var geometry: ArtworkCropGeometry
  @State private var displayedImage: NSImage
  @State private var history = ArtworkCropHistory()
  @State private var dragStart: ArtworkCropGeometry?
  @State private var pan = CGSize.zero
  @State private var panStart: CGSize?
  @State private var zoom = 1.0
  @State private var zoomStart: ArtworkCropGeometry?
  @State private var editing = false

  init(
    image: NSImage, ratio: Double, roundPreview: Bool, initial: ArtworkCrop?,
    onSave: @escaping (ArtworkCrop) -> Void
  ) {
    self.image = image
    self.ratio = ratio
    self.roundPreview = roundPreview
    self.onSave = onSave
    _geometry = State(
      initialValue: ArtworkCropGeometry(size: image.size, ratio: ratio, initial: initial))
    _displayedImage = State(initialValue: CropImage.rotated(image, degrees: initial?.rotation ?? 0))
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Crop Image").font(.title2.bold())
        Spacer()
        Text(roundPreview ? "1:1" : ratio < 1 ? "2:3" : "16:9")
          .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
      }.padding(20)
      Divider()
      HStack(alignment: .top, spacing: 16) {
        canvas
          .frame(minWidth: 390, minHeight: 330)
          .background(.black)
          .clipShape(RoundedRectangle(cornerRadius: 10))
        if roundPreview {
          VStack(spacing: 12) {
            Text("Preview").font(.caption).foregroundStyle(.secondary)
            Image(
              nsImage: CropImage.render(
                displayedImage,
                crop: ArtworkCrop(
                  x: geometry.crop.x, y: geometry.crop.y,
                  width: geometry.crop.width, height: geometry.crop.height), maximumDimension: 192)
            )
            .resizable().scaledToFill().frame(width: 96, height: 96)
            .clipShape(Circle()).overlay { Circle().stroke(AureliaDesign.hairline) }
            .accessibilityLabel("Circular Person Preview")
          }.frame(width: 104)
        }
      }.padding(20)
      Text("Drag the frame or its handles. Drag outside the frame to pan; pinch to zoom.")
        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
      HStack(spacing: 14) {
        Label("Zoom", systemImage: "magnifyingglass")
        Slider(
          value: Binding(get: { zoom }, set: { setZoom($0) }), in: 1...6,
          onEditingChanged: { active in
            if active { beginZoom() } else { finishZoom() }
          }
        )
        .accessibilityLabel("Crop Zoom").accessibilityIdentifier("crop-zoom")
        Button("Rotate 90°", systemImage: "rotate.right") {
          change { $0.rotate() }
          fit()
        }.accessibilityIdentifier("crop-rotate")
        Button("Reset") {
          change { $0.reset() }
          fit()
        }
        .accessibilityIdentifier("crop-reset")
      }.padding(20)
      HStack(spacing: 12) {
        Button {
          history.undo(&geometry)
          fit()
        } label: {
          Image(systemName: "arrow.uturn.backward")
        }
        .disabled(history.undo.isEmpty).accessibilityLabel("Undo Crop")
        .accessibilityIdentifier("crop-undo").keyboardShortcut("z", modifiers: .command)
        Button {
          history.redo(&geometry)
          fit()
        } label: {
          Image(systemName: "arrow.uturn.forward")
        }
        .disabled(history.redo.isEmpty).accessibilityLabel("Redo Crop")
        .accessibilityIdentifier("crop-redo").keyboardShortcut("z", modifiers: [.command, .shift])
        Spacer()
        Text("Original retained").font(.caption).foregroundStyle(.secondary)
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("crop-cancel")
        Button("Use Crop") { onSave(geometry.crop) }
          .buttonStyle(AureliaPrimaryActionButtonStyle()).keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("crop-use")
      }.padding(20)
    }
    .frame(
      minWidth: 600, idealWidth: 780, maxWidth: .infinity,
      minHeight: 560, idealHeight: 660, maxHeight: .infinity
    )
    .background(AureliaDesign.canvas)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("artwork-crop-editor")
    .onChange(of: geometry.crop.rotation) {
      displayedImage = CropImage.rotated(image, degrees: geometry.crop.rotation)
    }
  }

  private var canvas: some View {
    GeometryReader { proxy in
      let size = geometry.imageSize
      let fitScale = min(
        (proxy.size.width - 40) / size.width, (proxy.size.height - 40) / size.height)
      let scale = max(0.001, fitScale * zoom)
      let origin = CGPoint(
        x: (proxy.size.width - size.width * fitScale) / 2 + pan.width * fitScale,
        y: (proxy.size.height - size.height * fitScale) / 2 + pan.height * fitScale)
      let visibleBounds = CGRect(
        x: (20 - origin.x) / scale, y: (20 - origin.y) / scale,
        width: (proxy.size.width - 40) / scale, height: (proxy.size.height - 40) / scale
      ).intersection(CGRect(origin: .zero, size: size))
      let crop = geometry.rect
      let frame = CGRect(
        x: origin.x + crop.minX * scale, y: origin.y + crop.minY * scale,
        width: crop.width * scale, height: crop.height * scale)

      ZStack(alignment: .topLeading) {
        Image(nsImage: displayedImage).resizable()
          .frame(width: size.width * scale, height: size.height * scale)
          .offset(x: origin.x, y: origin.y)
          .allowsHitTesting(false)
        Path { path in
          path.addRect(CGRect(origin: .zero, size: proxy.size))
          path.addRect(frame)
        }.fill(.black.opacity(0.58), style: FillStyle(eoFill: true))
          .allowsHitTesting(false)
        selection(frame: frame)
        ForEach(CropHandle.allCases, id: \.self) { handle in
          cropHandle(handle, frame: frame)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
      .clipped()
      .overlay {
        CropCanvasInput(
          selection: frame,
          onBegin: { mode in
            beginDrag()
            if mode == .pan { panStart = pan }
          },
          onDrag: { mode, translation in
            if var start = dragStart {
              let delta = CGSize(
                width: translation.width / scale, height: translation.height / scale)
              if mode == .pan {
                let before = start.rect
                start.move(CGSize(width: -delta.width, height: -delta.height))
                // Move the image beneath a stationary selection; only the
                // selected source coordinates, not a cosmetic viewport, change.
                pan = CGSize(
                  width: (panStart?.width ?? 0) - (start.rect.midX - before.midX) * zoom,
                  height: (panStart?.height ?? 0) - (start.rect.midY - before.midY) * zoom)
              } else if case .resize(let handle) = mode {
                start.resize(handle, delta: delta, within: visibleBounds)
              } else {
                start.move(delta, within: visibleBounds)
              }
              geometry = start
            }
          },
          onEnd: {
            finishDrag()
            panStart = nil
          },
          onMagnify: { magnification, active in
            if active { beginZoom() }
            setZoom(zoom * (1 + magnification))
            if !active { finishZoom() }
          }
        ).frame(width: proxy.size.width, height: proxy.size.height)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Crop Frame")
  }

  private func selection(frame: CGRect) -> some View {
    ZStack {
      Rectangle().fill(.clear)
      if editing {
        Path { path in
          for part in [1.0 / 3, 2.0 / 3] {
            path.move(to: CGPoint(x: frame.width * part, y: 0))
            path.addLine(to: CGPoint(x: frame.width * part, y: frame.height))
            path.move(to: CGPoint(x: 0, y: frame.height * part))
            path.addLine(to: CGPoint(x: frame.width, y: frame.height * part))
          }
        }.stroke(.white.opacity(0.55), lineWidth: 0.75).allowsHitTesting(false)
      }
    }
    .frame(width: frame.width, height: frame.height)
    .overlay { Rectangle().stroke(.white, lineWidth: 1) }
    .position(x: frame.midX, y: frame.midY)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Move Crop Frame")
    .accessibilityIdentifier("crop-frame")
    .accessibilityAdjustableAction { direction in
      change { $0.move(CGSize(width: direction == .increment ? 2 : -2, height: 0)) }
    }
  }

  private func cropHandle(_ handle: CropHandle, frame: CGRect) -> some View {
    let point = handle.point(in: frame)
    return RoundedRectangle(cornerRadius: 2)
      .fill(.white)
      .frame(width: handle.horizontal == 0 ? 22 : 7, height: handle.vertical == 0 ? 22 : 7)
      .shadow(color: .black.opacity(0.7), radius: 2)
      .frame(width: 44, height: 44).contentShape(Rectangle())
      .position(point)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Resize Crop \(handle.rawValue)")
      .accessibilityIdentifier("crop-handle-\(handle.rawValue)")
      .accessibilityAdjustableAction { direction in
        let delta: CGFloat = direction == .increment ? 2 : -2
        change {
          $0.resize(
            handle, delta: CGSize(width: delta * handle.horizontal, height: delta * handle.vertical)
          )
        }
      }
  }

  private func beginDrag() {
    if dragStart == nil { dragStart = geometry }
    editing = true
  }
  private func finishDrag() {
    if let dragStart { history.record(dragStart, after: geometry) }
    dragStart = nil
    editing = false
  }
  private func change(_ action: (inout ArtworkCropGeometry) -> Void) {
    let before = geometry
    action(&geometry)
    history.record(before, after: geometry)
  }
  private func beginZoom() {
    if zoomStart == nil { zoomStart = geometry }
    editing = true
  }
  private func finishZoom() {
    if let zoomStart { history.record(zoomStart, after: geometry) }
    zoomStart = nil
    editing = false
  }
  private func setZoom(_ proposed: Double) {
    let next = min(6, max(1, proposed))
    guard next != zoom else { return }
    let before = geometry
    let center = CGPoint(x: geometry.rect.midX, y: geometry.rect.midY)
    geometry.zoom(by: next / zoom)
    // Magnify the image around the selected center while keeping the frame
    // and all eight handles in the same visible canvas position.
    pan.width += center.x * (zoom - next)
    pan.height += center.y * (zoom - next)
    zoom = next
    if zoomStart == nil { history.record(before, after: geometry) }
  }
  private func fit() {
    zoom = 1
    pan = .zero
    zoomStart = nil
    editing = false
  }
}

extension CropHandle {
  fileprivate var resizeCursor: NSCursor {
    let position: NSCursor.FrameResizePosition
    switch self {
    case .topLeft: position = .topLeft
    case .top: position = .top
    case .topRight: position = .topRight
    case .right: position = .right
    case .bottomRight: position = .bottomRight
    case .bottom: position = .bottom
    case .bottomLeft: position = .bottomLeft
    case .left: position = .left
    }
    return .frameResize(position: position, directions: .all)
  }

}

/// A canvas owns one pointer gesture from mouse-down to mouse-up. Native capture
/// keeps a moving handle under the pointer even as SwiftUI lays out the new frame.
private struct CropCanvasInput: NSViewRepresentable {
  enum Mode: Equatable {
    case resize(CropHandle)
    case move, pan
  }
  let selection: CGRect
  let onBegin: (Mode) -> Void
  let onDrag: (Mode, CGSize) -> Void
  let onEnd: () -> Void
  let onMagnify: (Double, Bool) -> Void

  func makeNSView(context: Context) -> Probe {
    let view = Probe()
    view.setAccessibilityElement(false)
    view.input = self
    return view
  }
  func updateNSView(_ view: Probe, context: Context) { view.input = self }
  static func dismantleNSView(_ view: Probe, coordinator: ()) { view.endGesture() }

  final class Probe: NSView {
    var input: CropCanvasInput?
    private var gesture: (mode: Mode, start: CGPoint)?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(
        rect: .zero,
        options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self)
      addTrackingArea(area)
      tracking = area
    }
    private func mode(at point: CGPoint) -> Mode {
      guard let frame = input?.selection else { return .pan }
      if let handle = CropHandle.allCases.min(by: {
        let a = $0.point(in: frame)
        let b = $1.point(in: frame)
        return hypot(point.x - a.x, point.y - a.y) < hypot(point.x - b.x, point.y - b.y)
      }),
        CGRect(
          x: handle.point(in: frame).x - 22, y: handle.point(in: frame).y - 22,
          width: 44, height: 44
        ).contains(point)
      {
        return .resize(handle)
      }
      return frame.contains(point) ? .move : .pan
    }
    override func mouseDown(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      let mode = mode(at: point)
      gesture = (mode, point)
      input?.onBegin(mode)
    }
    override func mouseDragged(with event: NSEvent) {
      guard let gesture else { return }
      let point = convert(event.locationInWindow, from: nil)
      input?.onDrag(
        gesture.mode, CGSize(width: point.x - gesture.start.x, height: point.y - gesture.start.y))
    }
    override func mouseUp(with event: NSEvent) { endGesture() }
    func endGesture() {
      guard gesture != nil else { return }
      gesture = nil
      input?.onEnd()
    }
    override func mouseMoved(with event: NSEvent) {
      if case .resize(let handle) = mode(at: convert(event.locationInWindow, from: nil)) {
        handle.resizeCursor.set()
      } else {
        NSCursor.openHand.set()
      }
    }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    override func magnify(with event: NSEvent) {
      input?.onMagnify(
        Double(event.magnification),
        !event.phase.contains(.ended) && !event.phase.contains(.cancelled))
    }
  }
}
