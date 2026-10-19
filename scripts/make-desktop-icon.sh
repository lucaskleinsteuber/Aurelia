#!/bin/sh
# Makes the desktop app's Windows icon (app, taskbar, notification area and installer) from the
# Aurelia app icon (clients/macos/Aurelia/AureliaAppIcon.icon, shared with the Mac app): the dark rounded square
# without the black around it, with transparent corners, at the sizes Windows asks for. Run it again
# only when that icon changes; the result is committed.
set -eu
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_icon="$repository_root/clients/macos/Aurelia/AureliaAppIcon.icon/Assets/aurelia-mark.png"
output="$repository_root/clients/desktop/Aurelia.Desktop/Assets/aurelia.ico"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/render.swift" <<'SWIFT'
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fatalError("The icon artwork could not be read.") }
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let reader = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
reader.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
// The square is dark gray (#1B1B1B); around it the artwork is black.
func square(_ x: Int, _ y: Int) -> Bool {
  let index = (y * width + x) * 4
  return Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2]) > 3 * 14
}
// The square's edges, from the middle of each side.
var left = 0, right = width - 1, top = 0, bottom = height - 1
while !square(left, height / 2) { left += 1 }
while !square(right, height / 2) { right -= 1 }
while !square(width / 2, top) { top += 1 }
while !square(width / 2, bottom) { bottom -= 1 }
// The corner radius, from where the corner's curve crosses the diagonal.
var step = 0
while !square(left + step, top + step) { step += 1 }
let side = CGFloat(min(right - left, bottom - top) + 1)
let radius = CGFloat(step) / (1 - 1 / 2.squareRoot())
let square = image.cropping(to: CGRect(x: left, y: top, width: Int(side), height: Int(side)))!

for size in [16, 20, 24, 32, 40, 48, 64, 96, 128, 256] {
  let scale = CGFloat(size) / side
  let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.interpolationQuality = .high
  // Slightly inside the drawn edge, so no black from around it shows at small sizes.
  let inset = max(0.35, scale * 2)
  let bounds = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: inset, dy: inset)
  let corner = max(1.5, radius * scale - inset)
  context.addPath(CGPath(roundedRect: bounds, cornerWidth: corner, cornerHeight: corner, transform: nil))
  context.clip()
  context.draw(square, in: CGRect(x: 0, y: 0, width: size, height: size))
  let url = URL(fileURLWithPath: arguments[2]).appendingPathComponent("\(size).png")
  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, context.makeImage()!, nil)
  guard CGImageDestinationFinalize(destination) else { fatalError("\(size).png could not be written.") }
}
SWIFT
swift "$work/render.swift" "$source_icon" "$work"

# An .ico holds each size as PNG data behind a small directory (Windows Vista and later).
python3 -I - "$work" "$output" <<'PYTHON'
import struct, sys, pathlib
work, output = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
images = [(work / f"{size}.png").read_bytes() for size in sizes]
offset = 6 + 16 * len(sizes)
header = struct.pack("<HHH", 0, 1, len(sizes))
entries = b""
for size, data in zip(sizes, images):
    entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset)
    offset += len(data)
output.parent.mkdir(parents=True, exist_ok=True)
output.write_bytes(header + entries + b"".join(images))
PYTHON
echo "Wrote $output"
