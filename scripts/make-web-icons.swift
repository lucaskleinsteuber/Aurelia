#!/usr/bin/swift  // Generates the browser home-screen icons from Aurelia's existing vector icon. No window opens.
import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
  fputs("Usage: swift scripts/make-web-icons.swift <icon.svg> <output-directory>\n", stderr)
  exit(2)
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let image = NSImage(contentsOf: source), image.isValid else {
  fputs("The source icon could not be decoded.\n", stderr)
  exit(1)
}
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [180, 192, 512] {
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
  else { fatalError("The icon canvas could not be created.") }
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  context.imageInterpolation = .high
  NSColor(srgbRed: 32 / 255.0, green: 35 / 255.0, blue: 38 / 255.0, alpha: 1).setFill()
  let bounds = NSRect(x: 0, y: 0, width: size, height: size)
  bounds.fill()
  image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
  NSGraphicsContext.restoreGraphicsState()
  guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("The home-screen icon could not be encoded.")
  }
  try png.write(to: destination.appendingPathComponent("icon-\(size).png"), options: .atomic)
}
