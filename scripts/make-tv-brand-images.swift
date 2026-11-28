#!/usr/bin/swift  // Draws the Apple TV app icon layers (the T and its light echo) and the Top Shelf images (the T
// and the name) from the outline in docs/assets/tarven-icon.svg. No window opens.
//   swift scripts/make-tv-brand-images.swift <brandassets folder>
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
  fputs(
    "Usage: swift scripts/make-tv-brand-images.swift <App Icon & Top Shelf Image.brandassets>\n",
    stderr)
  exit(2)
}
let assets = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

// The T in the icon's 1024-unit square, as in docs/assets/tarven-icon.svg.
let outline =
  "M328 232 L696 232 Q762 232 762 298 L762 306 Q762 372 696 372 L610 372 Q580 372 580 402 L580 724 Q580 792 512 792 Q444 792 444 724 L444 402 Q444 372 414 372 L328 372 Q262 372 262 306 L262 298 Q262 232 328 232 Z"
let echoOffset = CGPoint(x: 34, y: 30)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The outline in image pixels: icon unit (u, v) lands at center + (u - 512, v - 512) * scale.
func letter(center: CGPoint, scale: CGFloat, offset: CGPoint = .zero) -> CGPath {
  let path = CGMutablePath()
  var numbers: [CGFloat] = []
  var command: Character = "M"
  func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: center.x + (x + offset.x - 512) * scale, y: center.y + (y + offset.y - 512) * scale)
  }
  func flush() {
    switch command {
    case "M" where numbers.count >= 2: path.move(to: point(numbers[0], numbers[1]))
    case "L" where numbers.count >= 2: path.addLine(to: point(numbers[0], numbers[1]))
    case "Q" where numbers.count >= 4:
      path.addQuadCurve(to: point(numbers[2], numbers[3]), control: point(numbers[0], numbers[1]))
    default: break
    }
    numbers = []
  }
  for token in outline.split(separator: " ") {
    if let first = token.first, first.isLetter {
      flush()
      command = first
      if first == "Z" { path.closeSubpath() }
      if let value = Double(token.dropFirst()) { numbers.append(CGFloat(value)) }
    } else if let value = Double(token) {
      numbers.append(CGFloat(value))
    }
  }
  flush()
  return path
}

/// Draws into a transparent canvas whose y axis points down, like the SVG, and saves a PNG.
func render(width: Int, height: Int, to url: URL, _ draw: (CGContext) -> Void) {
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.translateBy(x: 0, y: CGFloat(height))
  context.scaleBy(x: 1, y: -1)
  draw(context)
  let image = context.makeImage()!
  let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.path)") }
}

/// Fills a path with a vertical gradient across its own height.
func fill(_ path: CGPath, in context: CGContext, top: CGColor, bottom: CGColor) {
  let box = path.boundingBox
  context.saveGState()
  context.addPath(path)
  context.clip()
  let gradient = CGGradient(
    colorsSpace: nil, colors: [top, bottom] as CFArray, locations: [0, 1])!
  context.drawLinearGradient(
    gradient, start: CGPoint(x: box.midX, y: box.minY), end: CGPoint(x: box.midX, y: box.maxY),
    options: [])
  context.restoreGState()
}

func drawMark(_ context: CGContext, center: CGPoint, scale: CGFloat, front: Bool, echo: Bool) {
  if echo {
    fill(
      letter(center: center, scale: scale, offset: echoOffset), in: context,
      top: color(0x8EC5FF), bottom: color(0x5B4FE0))
  }
  if front {
    fill(
      letter(center: center, scale: scale), in: context, top: color(0xFFFFFF),
      bottom: color(0xE3E8EE))
  }
}

// The app icon layers: the letter (front) and its echo (middle); the back layer stays.
for (stack, base) in [("App Icon - Large", (1280, 768)), ("App Icon - Small", (400, 240))] {
  for (suffix, factor) in stack.hasSuffix("Large") ? [("", 1)] : [("", 1), ("@2x", 2)] {
    let width = base.0 * factor
    let height = base.1 * factor
    let scale = 0.8125 * CGFloat(width) / 1280
    let center = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) * 387.5 / 768)
    for (layer, front) in [("Front", true), ("Middle", false)] {
      let url = assets.appendingPathComponent(
        "\(stack).imagestack/\(layer).imagestacklayer/Content.imageset/Tarven\(suffix).png")
      render(width: width, height: height, to: url) { context in
        drawMark(context, center: center, scale: scale, front: front, echo: !front)
      }
    }
  }
}

// The Top Shelf: the dark canvas with a soft glow, the T with its echo and the name beside it.
for (set, base) in [("Top Shelf Image", (1920, 720)), ("Top Shelf Image Wide", (2320, 720))] {
  for (suffix, factor) in [("", 1), ("@2x", 2)] {
    let width = CGFloat(base.0 * factor)
    let height = CGFloat(base.1 * factor)
    let unit = height / 720
    let name = NSAttributedString(
      string: "Tarven",
      attributes: [
        .font: NSFont.systemFont(ofSize: 150 * unit, weight: .semibold),
        .foregroundColor: NSColor.white,
      ])
    let line = CTLineCreateWithAttributedString(name)
    let nameWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
    let markScale = 0.41 * unit
    let markWidth = (796 - 262) * markScale
    let gap = 70 * unit
    let start = (width - (markWidth + gap + CGFloat(nameWidth))) / 2
    let markCenter = CGPoint(x: start + (512 - 262) * markScale, y: height / 2)
    let url = assets.appendingPathComponent("\(set).imageset/Tarven\(suffix).png")
    render(width: Int(width), height: Int(height), to: url) { context in
      let background = CGGradient(
        colorsSpace: nil, colors: [color(0x2B3036), color(0x121417)] as CFArray, locations: [0, 1])!
      context.drawLinearGradient(
        background, start: .zero, end: CGPoint(x: 0, y: height), options: [])
      let glow = CGGradient(
        colorsSpace: nil, colors: [color(0x5B7CFF, 0.28), color(0x5B7CFF, 0)] as CFArray,
        locations: [0, 1])!
      context.drawRadialGradient(
        glow, startCenter: markCenter, startRadius: 0, endCenter: markCenter,
        endRadius: height * 0.75, options: [])
      drawMark(context, center: markCenter, scale: markScale, front: true, echo: true)
      // Text draws with y up: flip back for the name, baseline on the letter's optical middle.
      context.saveGState()
      context.textMatrix = .identity
      context.translateBy(x: start + markWidth + gap, y: height / 2 + 55 * unit)
      context.scaleBy(x: 1, y: -1)
      CTLineDraw(line, context)
      context.restoreGState()
    }
  }
}
print("Drew the Apple TV icon layers and Top Shelf images.")
