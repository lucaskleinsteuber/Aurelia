// Makes a fictional library for README screenshots: invented movies and series with posters,
// backdrops and episode stills drawn here, and server-format JSON that the Mac and Apple TV apps
// show in their showcase mode (DEBUG builds only). No real title, name or artwork is used.
//
//   swift scripts/make-showcase.swift <output folder>
import AppKit

struct Palette {
  let skyTop: NSColor
  let skyBottom: NSColor
  let light: NSColor
  let layers: [NSColor]
}

enum Scene { case ridges, aurora, sea, city, space, forest, desert, lighthouse }

struct Title {
  let id: String
  let kind: String
  let name: String
  let year: Int
  let genres: [String]
  let overview: String
  let scene: Scene
  let palette: Palette
  let font: String
  var seasons: [[String]] = []
  var episodeOverviews: [[String]] = []
}

func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A small deterministic generator, so every run draws the same pictures.
struct Random {
  var state: UInt64
  mutating func next() -> Double {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Double(state >> 11) / Double(1 << 53)
  }
  mutating func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * next() }
}

func gradient(_ rect: NSRect, _ top: NSColor, _ bottom: NSColor) {
  NSGradient(starting: bottom, ending: top)!.draw(in: rect, angle: 90)
}

func glow(center: NSPoint, radius: CGFloat, color: NSColor) {
  NSGradient(colors: [color, color.withAlphaComponent(0)])!
    .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}

/// A mountain ridge across the picture, filled down to the bottom edge.
func ridge(_ size: NSSize, base: CGFloat, height: CGFloat, color: NSColor, random: inout Random) {
  let path = NSBezierPath()
  path.move(to: NSPoint(x: 0, y: 0))
  let phases = (0..<3).map { _ in random.range(0, .pi * 2) }
  let frequencies = [random.range(1.2, 2.2), random.range(3, 5), random.range(8, 13)]
  var x: CGFloat = 0
  while x <= size.width + 8 {
    let t = Double(x / size.width)
    var y = 0.0
    for index in 0..<3 {
      y += sin(t * .pi * frequencies[index] + phases[index]) / Double(index * 2 + 1)
    }
    path.line(to: NSPoint(x: x, y: base + height * CGFloat(y)))
    x += 6
  }
  path.line(to: NSPoint(x: size.width, y: 0))
  path.close()
  color.setFill()
  path.fill()
}

func stars(_ size: NSSize, count: Int, random: inout Random, top: CGFloat = 0.35) {
  for _ in 0..<count {
    let x = random.range(0, Double(size.width))
    let y = random.range(Double(size.height * top), Double(size.height))
    let r = random.range(0.6, 2.2) * Double(size.width) / 1920
    NSColor.white.withAlphaComponent(random.range(0.3, 0.95)).setFill()
    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: r * 2, height: r * 2)).fill()
  }
}

func water(_ size: NSSize, level: CGFloat, palette: Palette, random: inout Random) {
  gradient(
    NSRect(x: 0, y: 0, width: size.width, height: level), palette.layers[0],
    palette.layers.last!)
  // Reflection of the light on the water.
  for line in 0..<40 {
    let y = level - CGFloat(line) * level / 40
    let width = size.width * CGFloat(0.06 + Double(line) * 0.004) * CGFloat(random.range(0.6, 1.3))
    palette.light.withAlphaComponent(0.55 - CGFloat(line) * 0.012).setFill()
    NSBezierPath(
      roundedRect: NSRect(
        x: size.width * 0.62 - width / 2 + CGFloat(random.range(-20, 20)), y: y,
        width: width, height: max(2, size.height / 400)), xRadius: 2, yRadius: 2
    ).fill()
  }
}

/// `varied` moves the main subject, so the stills of one series do not all look alike.
func draw(_ scene: Scene, palette: Palette, size: NSSize, seed: UInt64, varied: Bool = false) {
  var random = Random(state: seed)
  var shift = Random(state: seed &+ 99)
  let offset = varied ? CGFloat(shift.range(-0.32, 0.18)) : 0
  let scale = varied ? CGFloat(shift.range(0.6, 1.15)) : 1
  let full = NSRect(origin: .zero, size: size)
  gradient(full, palette.skyTop, palette.skyBottom)
  let light = NSPoint(
    x: size.width * (0.62 + offset), y: size.height * (0.56 + offset * 0.3))
  switch scene {
  case .ridges, .forest, .aurora, .desert:
    if scene == .aurora {
      stars(size, count: 220, random: &random)
      for band in 0..<3 {
        let path = NSBezierPath()
        let base = size.height * CGFloat(0.62 + Double(band) * 0.06)
        path.move(to: NSPoint(x: -20, y: base))
        var x: CGFloat = -20
        while x < size.width + 20 {
          let y = base + size.height * 0.08 * CGFloat(sin(Double(x / size.width) * 5 + Double(band)))
          path.line(to: NSPoint(x: x, y: y))
          x += 10
        }
        path.lineWidth = size.height * 0.07
        path.lineCapStyle = .round
        palette.light.withAlphaComponent(0.22).setStroke()
        path.stroke()
      }
    } else {
      glow(center: light, radius: size.width * 0.5, color: palette.light.withAlphaComponent(0.55))
      let sun = size.width * (scene == .desert ? 0.16 : 0.09)
      palette.light.setFill()
      NSBezierPath(
        ovalIn: NSRect(x: light.x - sun / 2, y: light.y - sun / 2, width: sun, height: sun)
      ).fill()
    }
    for (index, color) in palette.layers.enumerated() {
      let base = size.height * CGFloat(0.5 - Double(index) * 0.11)
      ridge(
        size, base: base, height: size.height * (scene == .desert ? 0.04 : 0.09), color: color,
        random: &random)
      if scene == .forest {
        for _ in 0..<70 {
          let x = CGFloat(random.range(0, Double(size.width)))
          let h = size.height * CGFloat(random.range(0.08, 0.2))
          let w = h * 0.38
          let tree = NSBezierPath()
          tree.move(to: NSPoint(x: x - w / 2, y: base - size.height * 0.05))
          tree.line(to: NSPoint(x: x, y: base - size.height * 0.05 + h))
          tree.line(to: NSPoint(x: x + w / 2, y: base - size.height * 0.05))
          tree.close()
          color.setFill()
          tree.fill()
        }
      }
    }
  case .sea, .lighthouse:
    stars(size, count: 90, random: &random, top: 0.6)
    glow(center: light, radius: size.width * 0.45, color: palette.light.withAlphaComponent(0.5))
    let moon = size.width * 0.08
    palette.light.setFill()
    NSBezierPath(
      ovalIn: NSRect(x: light.x - moon / 2, y: light.y - moon / 2, width: moon, height: moon)
    ).fill()
    water(size, level: size.height * 0.4, palette: palette, random: &random)
    if scene == .lighthouse {
      let rock = NSBezierPath()
      rock.move(to: NSPoint(x: size.width * 0.05, y: size.height * 0.36))
      rock.curve(
        to: NSPoint(x: size.width * 0.38, y: size.height * 0.36),
        controlPoint1: NSPoint(x: size.width * 0.12, y: size.height * 0.5),
        controlPoint2: NSPoint(x: size.width * 0.3, y: size.height * 0.48))
      rock.close()
      palette.layers.last!.blended(withFraction: 0.5, of: .black)!.setFill()
      rock.fill()
      let tower = NSBezierPath()
      let cx = size.width * 0.22
      let bottom = size.height * 0.44
      let top = size.height * 0.74
      tower.move(to: NSPoint(x: cx - size.width * 0.025, y: bottom))
      tower.line(to: NSPoint(x: cx - size.width * 0.016, y: top))
      tower.line(to: NSPoint(x: cx + size.width * 0.016, y: top))
      tower.line(to: NSPoint(x: cx + size.width * 0.025, y: bottom))
      tower.close()
      rgb(0x0E1520).setFill()
      tower.fill()
      let beam = NSBezierPath()
      beam.move(to: NSPoint(x: cx, y: top + size.height * 0.02))
      beam.line(to: NSPoint(x: size.width, y: top + size.height * 0.12))
      beam.line(to: NSPoint(x: size.width, y: top - size.height * 0.06))
      beam.close()
      palette.light.withAlphaComponent(0.18).setFill()
      beam.fill()
      glow(
        center: NSPoint(x: cx, y: top + size.height * 0.02), radius: size.width * 0.05,
        color: palette.light)
    }
  case .city:
    glow(center: light, radius: size.width * 0.5, color: palette.light.withAlphaComponent(0.45))
    for (index, color) in palette.layers.enumerated() {
      var x: CGFloat = -10
      while x < size.width {
        let width = size.width * CGFloat(random.range(0.035, 0.08))
        let height =
          size.height
          * CGFloat(random.range(0.18, 0.55) - Double(index) * 0.08)
        color.setFill()
        NSRect(x: x, y: 0, width: width, height: height).fill()
        if index == palette.layers.count - 1 {
          for row in stride(from: height * 0.08, to: height - 8, by: size.height * 0.022) {
            for column in stride(from: width * 0.15, to: width - 6, by: width * 0.22)
            where random.next() < 0.45 {
              palette.light.withAlphaComponent(random.range(0.45, 0.95)).setFill()
              NSRect(
                x: x + column, y: row, width: width * 0.1, height: size.height * 0.009
              ).fill()
            }
          }
        }
        x += width + size.width * CGFloat(random.range(0.002, 0.012))
      }
    }
  case .space:
    stars(size, count: 420, random: &random, top: 0)
    glow(
      center: NSPoint(x: size.width * 0.3, y: size.height * 0.7), radius: size.width * 0.35,
      color: palette.layers[1].withAlphaComponent(0.35))
    let radius = size.height * 0.34 * scale
    let center = NSPoint(
      x: size.width * (0.66 + offset), y: size.height * (0.42 - offset * 0.4))
    let ring = NSBezierPath(
      ovalIn: NSRect(
        x: center.x - radius * 1.9, y: center.y - radius * 0.32, width: radius * 3.8,
        height: radius * 0.64))
    ring.lineWidth = size.height * 0.012
    palette.light.withAlphaComponent(0.55).setStroke()
    ring.stroke()
    let planet = NSBezierPath(
      ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    NSGradient(colors: [palette.light, palette.layers[0], palette.layers.last!])!
      .draw(in: planet, angle: -55)
    // The near half of the ring passes in front of the planet.
    NSGraphicsContext.saveGraphicsState()
    NSRect(x: 0, y: 0, width: size.width, height: center.y).clip()
    ring.stroke()
    NSGraphicsContext.restoreGraphicsState()
  }
  // Fine grain, like film.
  for _ in 0..<Int(size.width * size.height / 900) {
    NSColor(white: random.next() < 0.5 ? 0 : 1, alpha: 0.035).setFill()
    NSRect(
      x: random.range(0, Double(size.width)), y: random.range(0, Double(size.height)),
      width: 1.4, height: 1.4
    ).fill()
  }
}

func render(_ size: NSSize, _ body: () -> Void) -> Data {
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  body()
  NSGraphicsContext.restoreGraphicsState()
  return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.86])!
}

func poster(_ title: Title, seed: UInt64) -> Data {
  let size = NSSize(width: 800, height: 1200)
  return render(size) {
    draw(title.scene, palette: title.palette, size: size, seed: seed)
    gradient(
      NSRect(x: 0, y: 0, width: size.width, height: size.height * 0.45),
      NSColor.black.withAlphaComponent(0), NSColor.black.withAlphaComponent(0.78))
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineBreakMode = .byWordWrapping
    // The longest word must fit on one line, so no word is ever split.
    var fontSize: CGFloat = 92
    func font(_ size: CGFloat) -> NSFont { NSFont(name: title.font, size: size) ?? .boldSystemFont(ofSize: size) }
    while fontSize > 40,
      title.name.uppercased().split(separator: " ").contains(where: { word in
        (String(word) as NSString).size(withAttributes: [.font: font(fontSize), .kern: 3]).width
          > size.width - 110
      })
    {
      fontSize -= 4
    }
    let font = font(fontSize)
    let name = NSAttributedString(
      string: title.name.uppercased(),
      attributes: [
        .font: font, .foregroundColor: NSColor.white, .paragraphStyle: style, .kern: 3,
      ])
    let box = NSRect(x: 50, y: 150, width: size.width - 100, height: 360)
    let measured = name.boundingRect(with: box.size, options: [.usesLineFragmentOrigin])
    name.draw(
      with: NSRect(x: box.minX, y: 150, width: box.width, height: measured.height),
      options: [.usesLineFragmentOrigin])
    let line = NSAttributedString(
      string: title.kind == "series" ? "A SERIES · \(title.year)" : "IN CINEMAS · \(title.year)",
      attributes: [
        .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.78), .paragraphStyle: style,
        .kern: 6,
      ])
    line.draw(
      with: NSRect(x: 50, y: 82, width: size.width - 100, height: 40),
      options: [.usesLineFragmentOrigin])
  }
}

func picture(_ title: Title, size: NSSize, seed: UInt64, varied: Bool = false) -> Data {
  render(size) {
    draw(title.scene, palette: title.palette, size: size, seed: seed, varied: varied)
  }
}

let titles: [Title] = [
  Title(
    id: "a0000000-0000-4000-8000-000000000001", kind: "series", name: "Cobalt Station",
    year: 2024, genres: ["Science Fiction", "Drama"],
    overview:
      "Six strangers keep a research station alive at the edge of the solar system, until a signal from the dark side of a frozen moon changes what they believe about home.",
    scene: .space,
    palette: Palette(
      skyTop: rgb(0x050816), skyBottom: rgb(0x0B1638), light: rgb(0x9FD3FF),
      layers: [rgb(0x2C6FD6), rgb(0x5B4FE0), rgb(0x0A1A3F)]),
    font: "AvenirNext-Heavy",
    seasons: [
      [
        "Arrival", "The Long Night", "Frost Lines", "Echoes", "Quiet Orbit", "Signal",
        "Thaw", "Homeward",
      ],
      ["Second Light", "Drift", "The Archive", "Glass Moon", "Undertow", "Departure"],
    ],
    episodeOverviews: [
      [
        "The new crew reaches the station a week late and finds the lights still on.",
        "A storm on the moon cuts the station off, and someone keeps opening the airlock.",
        "Ice samples hold a pattern that should not be there.",
        "The radio picks up a voice that sounds like the station's former commander.",
        "With the supply ship delayed, the crew has to choose what to switch off.",
        "The signal answers back, and it knows their names.",
        "A thaw on the far side reveals the shape of something buried.",
        "Half the crew wants to go home; the other half wants to stay and listen.",
      ],
      [
        "A year later, a new team arrives to find the station's logs erased.",
        "The station drifts off its orbit, and nobody remembers changing course.",
        "Hidden files show the signal was heard before, and kept secret.",
        "A second moon appears where none should be.",
        "Deep under the ice, the crew finds a door.",
        "The station has to choose between the people on board and the voice below.",
      ],
    ]),
  Title(
    id: "a0000000-0000-4000-8000-000000000002", kind: "movie", name: "The Quiet Harbor",
    year: 2023, genres: ["Drama"],
    overview:
      "A ferry captain returns to the island she left twenty years ago and has one summer to decide what is worth keeping.",
    scene: .sea,
    palette: Palette(
      skyTop: rgb(0x1E3A5F), skyBottom: rgb(0xF2A97E), light: rgb(0xFFE3B8),
      layers: [rgb(0x3D6E8C), rgb(0x0F2A40)]),
    font: "Georgia-Bold"),
  Title(
    id: "a0000000-0000-4000-8000-000000000003", kind: "movie", name: "Northern Lights",
    year: 2021, genres: ["Adventure", "Drama"],
    overview:
      "Two estranged brothers cross the tundra on foot to bring their father's ashes to the place he always talked about.",
    scene: .aurora,
    palette: Palette(
      skyTop: rgb(0x050B1A), skyBottom: rgb(0x123049), light: rgb(0x6CF2C2),
      layers: [rgb(0x1B2E44), rgb(0x0F1D2E), rgb(0x070F1A)]),
    font: "Futura-Bold"),
  Title(
    id: "a0000000-0000-4000-8000-000000000004", kind: "movie", name: "Glass City",
    year: 2024, genres: ["Thriller"],
    overview:
      "An architect discovers that the tower she designed hides a floor that does not exist in any plan.",
    scene: .city,
    palette: Palette(
      skyTop: rgb(0x0A0F24), skyBottom: rgb(0x3B2A6B), light: rgb(0x7FE7FF),
      layers: [rgb(0x1A1F3D), rgb(0x0D1124)]),
    font: "AvenirNext-Bold"),
  Title(
    id: "a0000000-0000-4000-8000-000000000005", kind: "movie", name: "The Last Orchard",
    year: 2020, genres: ["Drama", "Family"],
    overview:
      "Three generations bring in the final harvest of an apple farm that will be sold when the season ends.",
    scene: .forest,
    palette: Palette(
      skyTop: rgb(0x47305A), skyBottom: rgb(0xF0A35E), light: rgb(0xFFD58A),
      layers: [rgb(0x7A4A3A), rgb(0x4F2E2A), rgb(0x2A1A1C)]),
    font: "Georgia-Bold"),
  Title(
    id: "a0000000-0000-4000-8000-000000000006", kind: "movie", name: "Signal Lost",
    year: 2022, genres: ["Science Fiction", "Thriller"],
    overview:
      "When a deep-space probe starts answering questions nobody asked, a small team has one night to find out who is listening.",
    scene: .space,
    palette: Palette(
      skyTop: rgb(0x0A0410), skyBottom: rgb(0x2A0C2E), light: rgb(0xFFB27A),
      layers: [rgb(0xD9583B), rgb(0x8E2D6B), rgb(0x2B0B24)]),
    font: "Futura-Bold"),
  Title(
    id: "a0000000-0000-4000-8000-000000000007", kind: "movie", name: "Ember Road",
    year: 2025, genres: ["Action", "Adventure"],
    overview:
      "A courier with a stolen engine and a borrowed name races across the desert ahead of a storm and the people who want both back.",
    scene: .desert,
    palette: Palette(
      skyTop: rgb(0x3A1020), skyBottom: rgb(0xF07A3A), light: rgb(0xFFD27A),
      layers: [rgb(0xC0583A), rgb(0x8A3A2C), rgb(0x4A1E1E)]),
    font: "AvenirNext-Heavy"),
  Title(
    id: "a0000000-0000-4000-8000-000000000008", kind: "movie", name: "Paper Moons",
    year: 2019, genres: ["Comedy", "Romance"],
    overview:
      "A puppeteer and a weather forecaster keep meeting at the worst possible moments, until they start planning them.",
    scene: .ridges,
    palette: Palette(
      skyTop: rgb(0x9DB8F0), skyBottom: rgb(0xF7C6D9), light: rgb(0xFFFFFF),
      layers: [rgb(0xB7A3E0), rgb(0x8C7CC9), rgb(0x5E57A6)]),
    font: "Georgia-Bold"),
  Title(
    id: "a0000000-0000-4000-8000-000000000009", kind: "movie", name: "Midnight Atlas",
    year: 2023, genres: ["Mystery"],
    overview:
      "A mapmaker inherits an atlas of places that should not exist and finds the first one on her way home.",
    scene: .sea,
    palette: Palette(
      skyTop: rgb(0x020617), skyBottom: rgb(0x1D2B64), light: rgb(0xE6ECFF),
      layers: [rgb(0x1B2A5C), rgb(0x050B24)]),
    font: "Didot-Bold"),
  Title(
    id: "a0000000-0000-4000-8000-000000000010", kind: "movie", name: "Little Giants",
    year: 2021, genres: ["Family", "Comedy"],
    overview:
      "The smallest team in the valley enters the kite championship with a kite made from a circus tent.",
    scene: .ridges,
    palette: Palette(
      skyTop: rgb(0x58A9F5), skyBottom: rgb(0xCDEBFF), light: rgb(0xFFF4C2),
      layers: [rgb(0x7CC67A), rgb(0x4E9E5A), rgb(0x2E7246)]),
    font: "AvenirNext-Heavy"),
  Title(
    id: "a0000000-0000-4000-8000-000000000011", kind: "series", name: "The Lighthouse Keepers",
    year: 2022, genres: ["Drama", "Mystery"],
    overview:
      "On a remote island, a family takes over a lighthouse whose last keeper vanished without a trace, and the logbook keeps writing itself.",
    scene: .lighthouse,
    palette: Palette(
      skyTop: rgb(0x0B1A2B), skyBottom: rgb(0x3E5A73), light: rgb(0xFFE9A8),
      layers: [rgb(0x2C4A63), rgb(0x0B1724)]),
    font: "Georgia-Bold",
    seasons: [["The Keeper", "Low Tide", "Fog Bell", "The Logbook", "Storm Warning", "First Light"]]),
  Title(
    id: "a0000000-0000-4000-8000-000000000012", kind: "series", name: "Kitchen at Dawn",
    year: 2023, genres: ["Comedy"],
    overview:
      "A night-shift bakery crew keeps a small city fed, one disaster and one perfect croissant at a time.",
    scene: .city,
    palette: Palette(
      skyTop: rgb(0x6B5CA5), skyBottom: rgb(0xFFB38A), light: rgb(0xFFE7A3),
      layers: [rgb(0x7C5A86), rgb(0x3C2A4A)]),
    font: "AvenirNext-Bold",
    seasons: [["Opening Shift", "Sourdough", "The Critic", "Power Cut", "Sunrise Special"]]),
  Title(
    id: "a0000000-0000-4000-8000-000000000013", kind: "series", name: "Deep Field",
    year: 2021, genres: ["Documentary"],
    overview:
      "A journey from our own sky to the oldest light in the universe, told by the people who spend their nights looking up.",
    scene: .space,
    palette: Palette(
      skyTop: rgb(0x020208), skyBottom: rgb(0x14082A), light: rgb(0xFFE0B0),
      layers: [rgb(0xC08A3E), rgb(0x6A3FA0), rgb(0x150A2A)]),
    font: "Futura-Bold",
    seasons: [["First Light", "Neighbours", "The Milky Way", "Galaxies", "The Edge"]]),
]

let people = [
  "Mara Ellison", "Theo Brandt", "Ines Varga", "Jonah Pierce", "Leila Haddad", "Ruben Okafor",
  "Sofia Lindqvist", "Caleb Moreau", "Anika Rao", "Felix Navarro",
]

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write("Usage: swift scripts/make-showcase.swift <output folder>\n".data(using: .utf8)!)
  exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fileManager = FileManager.default
try? fileManager.removeItem(at: output)
for folder in ["artwork", "items"] {
  try fileManager.createDirectory(
    at: output.appendingPathComponent(folder), withIntermediateDirectories: true)
}

var artworkIndex = 0
func artwork(_ kind: String, data: Data) -> [String: Any] {
  artworkIndex += 1
  let id = String(format: "b0000000-0000-4000-8000-%012d", artworkIndex)
  try! data.write(to: output.appendingPathComponent("artwork/\(id).jpg"))
  return [
    "id": id, "kind": kind, "path": "/api/v1/artwork/\(id)", "contentType": "image/jpeg",
    "contentLength": data.count, "revision": 1,
  ]
}

let stamp = "2026-10-20T18:00:00Z"
func progress(_ id: String, _ position: Int, _ duration: Int) -> [String: Any] {
  [
    "mediaId": id, "positionMilliseconds": position, "durationMilliseconds": duration,
    "isCompleted": false, "lastPlayedAt": stamp, "updatedAt": stamp, "revision": 3,
    "lastMutationId": NSNull(),
  ]
}

func item(
  id: String, kind: String, name: String, year: Int, overview: String, genres: [String],
  poster: [String: Any]?, backdrop: [String: Any]?, favorite: Bool = false,
  progress: [String: Any]? = nil, parent: Title? = nil, season: Int? = nil, episode: Int? = nil,
  added: Int = 0
) -> [String: Any] {
  [
    "id": id, "kind": kind, "title": name, "originalTitle": NSNull(), "year": year,
    "overview": overview, "genres": genres, "poster": poster ?? NSNull(),
    "backdrop": backdrop ?? NSNull(), "availability": "available", "isFavorite": favorite,
    "progress": progress ?? NSNull(),
    "addedAt": String(format: "2026-10-%02dT18:00:00Z", 20 - added),
    "parentTitle": parent?.name ?? NSNull(), "seasonNumber": season ?? NSNull(),
    "episodeNumber": episode ?? NSNull(), "parentId": parent?.id ?? NSNull(),
    "watchState": progress == nil ? "unplayed" : "inProgress",
    "libraryAvailability": "available", "continueWatchingHidden": false,
  ]
}

let favorites: Set<String> = [titles[0].id, titles[1].id, titles[6].id]
var summaries: [String: [String: Any]] = [:]
var continueWatching: [[String: Any]] = []
for (index, title) in titles.enumerated() {
  let seed = UInt64(index + 1) * 7919
  let posterArt = artwork("poster", data: poster(title, seed: seed))
  let backdropArt = artwork(
    "backdrop", data: picture(title, size: NSSize(width: 1920, height: 1080), seed: seed))
  let watching = title.id == titles[1].id ? progress(title.id, 3_480_000, 6_420_000) : nil
  let summary = item(
    id: title.id, kind: title.kind, name: title.name, year: title.year,
    overview: title.overview, genres: title.genres, poster: posterArt, backdrop: backdropArt,
    favorite: favorites.contains(title.id), progress: watching, added: index)
  summaries[title.id] = summary
  if watching != nil { continueWatching.append(summary) }

  var seasons: [[String: Any]] = []
  for (seasonIndex, episodes) in title.seasons.enumerated() {
    let number = seasonIndex + 1
    seasons.append([
      "number": number,
      "episodes": episodes.enumerated().map { episodeIndex, name in
        let id = String(
          format: "c%07d-0000-4000-8000-%012d", index + 1, number * 100 + episodeIndex + 1)
        let still = artwork(
          "still",
          data: picture(
            title, size: NSSize(width: 1280, height: 720),
            seed: seed &+ UInt64(number * 100 + episodeIndex + 1) * 104_729, varied: true))
        let overviews = title.episodeOverviews.indices.contains(seasonIndex)
          ? title.episodeOverviews[seasonIndex] : []
        let resume =
          index == 0 && number == 1 && episodeIndex == 4
          ? progress(id, 1_260_000, 2_880_000) : nil
        let episode = item(
          id: id, kind: "episode", name: name, year: title.year,
          overview: overviews.indices.contains(episodeIndex)
            ? overviews[episodeIndex] : "A new chapter of \(title.name).",
          genres: title.genres, poster: nil, backdrop: still, progress: resume, parent: title,
          season: number, episode: episodeIndex + 1)
        if resume != nil { continueWatching.insert(episode, at: 0) }
        return ["item": episode, "seasonNumber": number, "episodeNumber": episodeIndex + 1]
      },
      "supplements": [],
    ])
  }
  let credits: [[String: Any]] =
    (0..<6).map { order in
      [
        "name": people[(index + order) % people.count], "department": "Acting",
        "job": NSNull(), "character": ["Captain", "Engineer", "Doctor", "Pilot", "Navigator", "Cook"][order],
        "order": order, "profile": NSNull(), "id": NSNull(), "personKey": NSNull(),
      ]
    } + [
      [
        "name": people[(index + 7) % people.count], "department": "Directing", "job": "Director",
        "character": NSNull(), "order": 20, "profile": NSNull(), "id": NSNull(),
        "personKey": NSNull(),
      ]
    ]
  let detail: [String: Any] = [
    "item": summary,
    "metadata": [
      "mediaId": title.id, "title": title.name, "originalTitle": NSNull(),
      "overview": title.overview, "releaseDate": "\(title.year)-09-12", "year": title.year,
      "runtimeMinutes": title.kind == "movie" ? 107 : NSNull(), "rating": 8.1,
      "contentRating": NSNull(), "genres": title.genres, "studios": ["Harbor Light Pictures"],
      "countries": ["United States"], "credits": credits, "poster": posterArt,
      "backdrop": backdropArt, "still": NSNull(), "provider": NSNull(),
      "providerMediaId": NSNull(), "reviewState": "matched", "fskAge": 12,
    ],
    "seasons": seasons,
    "supplements": [],
  ]
  let data = try JSONSerialization.data(withJSONObject: detail, options: [.prettyPrinted])
  try data.write(to: output.appendingPathComponent("items/\(title.id).json"))
}

func ids(_ list: [Int]) -> [[String: Any]] { list.map { summaries[titles[$0].id]! } }
let collections: [[String: Any]] = [
  [
    "id": "d0000000-0000-4000-8000-000000000001", "name": "Under the Stars",
    "poster": NSNull(), "items": ids([0, 5, 12, 2]),
  ],
  [
    "id": "d0000000-0000-4000-8000-000000000002", "name": "By the Sea",
    "poster": NSNull(), "items": ids([1, 8, 10]),
  ],
]
let home: [String: Any] = [
  "recommendation": summaries[titles[0].id]!,
  "continueWatching": continueWatching,
  "recentlyAdded": ids([6, 3, 0, 9, 4, 11, 7, 2, 12, 5, 8, 1, 10]),
  "favorites": ids([0, 1, 6]),
  "collections": collections,
  "recommendationChangesAt": "2099-01-01T00:00:00Z",
]
func write(_ value: Any, _ name: String) throws {
  try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted])
    .write(to: output.appendingPathComponent(name))
}
try write(home, "home.json")
try write(collections, "collections.json")
for kind in ["movie", "series"] {
  let list = titles.filter { $0.kind == kind }.map { summaries[$0.id]! }
  try write(
    ["items": list, "offset": 0, "limit": 200, "total": list.count, "revision": "showcase"],
    "catalog-\(kind).json")
}
let all = titles.map { summaries[$0.id]! }
try write(
  ["items": all, "offset": 0, "limit": 200, "total": all.count, "revision": "showcase"],
  "catalog-all.json")
print("Showcase library with \(titles.count) titles and \(artworkIndex) pictures in \(output.path)")
