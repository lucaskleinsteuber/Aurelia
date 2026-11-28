import Foundation

enum CropHandle: String, CaseIterable {
  case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
  var horizontal: CGFloat {
    switch self {
    case .topLeft, .left, .bottomLeft: -1
    case .topRight, .right, .bottomRight: 1
    default: 0
    }
  }
  var vertical: CGFloat {
    switch self {
    case .topLeft, .top, .topRight: -1
    case .bottomLeft, .bottom, .bottomRight: 1
    default: 0
    }
  }
  func point(in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.midX + horizontal * rect.width / 2, y: rect.midY + vertical * rect.height / 2)
  }
}

/// One top-left, rotated-image coordinate system shared by handles and the API contract.
struct ArtworkCropGeometry: Equatable {
  let originalSize: CGSize
  let ratio: CGFloat
  private(set) var crop: ArtworkCrop

  init(size: CGSize, ratio: Double, initial: ArtworkCrop? = nil) {
    originalSize = size
    self.ratio = CGFloat(ratio)
    crop = initial ?? ArtworkCrop(x: 0, y: 0, width: 1, height: 1)
    if initial == nil { reset() }
  }

  var imageSize: CGSize {
    crop.rotation % 180 == 0
      ? originalSize : CGSize(width: originalSize.height, height: originalSize.width)
  }
  var rect: CGRect {
    CGRect(
      x: crop.x * imageSize.width, y: crop.y * imageSize.height,
      width: crop.width * imageSize.width, height: crop.height * imageSize.height)
  }

  mutating func reset() {
    crop.rotation = 0
    setCenteredRect(
      center: CGPoint(x: imageSize.width / 2, y: imageSize.height / 2),
      width: min(imageSize.width, imageSize.height * ratio))
  }

  mutating func move(_ delta: CGSize, within visibleBounds: CGRect? = nil) {
    let start = rect
    let bounds = visibleBounds ?? CGRect(origin: .zero, size: imageSize)
    setRect(
      CGRect(
        x: min(max(bounds.minX, start.minX + delta.width), bounds.maxX - start.width),
        y: min(max(bounds.minY, start.minY + delta.height), bounds.maxY - start.height),
        width: start.width, height: start.height))
  }

  mutating func zoom(by factor: Double) {
    guard factor.isFinite && factor > 0 else { return }
    let start = rect
    let maximum = min(
      2 * min(start.midX, imageSize.width - start.midX),
      2 * min(start.midY, imageSize.height - start.midY) * ratio)
    setCenteredRect(
      center: CGPoint(x: start.midX, y: start.midY),
      width: min(maximum, max(2, start.width / factor)))
  }

  mutating func resize(_ handle: CropHandle, delta: CGSize, within visibleBounds: CGRect? = nil) {
    let start = rect
    let bounds = visibleBounds ?? CGRect(origin: .zero, size: imageSize)
    let sx = handle.horizontal
    let sy = handle.vertical
    let anchor = CGPoint(
      x: start.midX - sx * start.width / 2,
      y: start.midY - sy * start.height / 2)
    let minimum = min(2, start.width)
    if sx != 0 && sy != 0 {
      let desired =
        start.width + (sx * delta.width + sy * delta.height / ratio) / (1 + 1 / (ratio * ratio))
      let maxX = sx > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
      let maxY = sy > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
      let width = max(minimum, min(desired, maxX, maxY * ratio))
      setRect(
        CGRect(
          x: sx > 0 ? anchor.x : anchor.x - width,
          y: sy > 0 ? anchor.y : anchor.y - width / ratio, width: width, height: width / ratio))
    } else if sx != 0 {
      let maxX = sx > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
      let width = max(
        minimum,
        min(
          start.width + sx * delta.width, maxX,
          2 * min(anchor.y - bounds.minY, bounds.maxY - anchor.y) * ratio))
      setRect(
        CGRect(
          x: sx > 0 ? anchor.x : anchor.x - width,
          y: anchor.y - width / ratio / 2, width: width, height: width / ratio))
    } else {
      let maxY = sy > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
      let height = max(
        minimum / ratio,
        min(
          start.height + sy * delta.height, maxY,
          2 * min(anchor.x - bounds.minX, bounds.maxX - anchor.x) / ratio))
      setRect(
        CGRect(
          x: anchor.x - height * ratio / 2,
          y: sy > 0 ? anchor.y : anchor.y - height, width: height * ratio, height: height))
    }
  }

  mutating func rotate() {
    let previous = rect
    let oldSize = imageSize
    crop.rotation = (crop.rotation + 90) % 360
    let center = CGPoint(x: oldSize.height - previous.midY, y: previous.midX)
    setCenteredRect(center: center, width: min(previous.height, previous.width * ratio))
  }

  private mutating func setCenteredRect(center: CGPoint, width: CGFloat) {
    let width = min(width, imageSize.width, imageSize.height * ratio)
    let height = width / ratio
    setRect(
      CGRect(
        x: min(max(0, center.x - width / 2), imageSize.width - width),
        y: min(max(0, center.y - height / 2), imageSize.height - height), width: width,
        height: height))
  }

  private mutating func setRect(_ rect: CGRect) {
    crop.x = max(0, rect.minX / imageSize.width)
    crop.y = max(0, rect.minY / imageSize.height)
    crop.width = min(1 - crop.x, rect.width / imageSize.width)
    crop.height = min(1 - crop.y, rect.height / imageSize.height)
  }
}

struct ArtworkCropHistory {
  private(set) var undo: [ArtworkCropGeometry] = []
  private(set) var redo: [ArtworkCropGeometry] = []
  mutating func record(_ before: ArtworkCropGeometry, after: ArtworkCropGeometry) {
    guard before != after else { return }
    undo.append(before)
    if undo.count > 100 { undo.removeFirst() }
    redo.removeAll()
  }
  mutating func undo(_ current: inout ArtworkCropGeometry) {
    guard let previous = undo.popLast() else { return }
    redo.append(current)
    current = previous
  }
  mutating func redo(_ current: inout ArtworkCropGeometry) {
    guard let next = redo.popLast() else { return }
    undo.append(current)
    current = next
  }
}
