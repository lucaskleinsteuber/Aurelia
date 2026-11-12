import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The built-in profile pictures every client draws the same way: a symbol on a palette gradient,
/// stored on the server as `symbol:palette`. `photo` means the profile has its own photo.
enum ProfilePictureCatalog {
  static let photoKey = "photo"
  /// The server accepts uploads up to this size; larger photos are scaled down first.
  static let maximumUploadBytes = 8 * 1024 * 1024
  /// Photos are sent at most this wide; the server makes a 512-pixel square of them.
  static let uploadEdge = 1024

  static let symbols = [
    "star", "rocket", "cat", "dog", "heart", "bolt", "leaf", "moon", "music", "gamecontroller",
    "film", "crown",
  ]

  /// In the order of the existing profile gradients (`AureliaProfileAvatar.palettes`), plus red.
  static let palettes = ["blue", "purple", "pink", "orange", "teal", "green", "indigo", "red"]

  static func builtin(symbol: String, palette: String) -> String { "\(symbol):\(palette)" }

  /// The symbol and palette of a built-in picture key; nil for a photo, no picture or an unknown key.
  static func parse(_ key: String?) -> (symbol: String, palette: String)? {
    guard let parts = key?.split(separator: ":", omittingEmptySubsequences: false),
      parts.count == 2
    else { return nil }
    let symbol = String(parts[0])
    let palette = String(parts[1])
    guard symbols.contains(symbol), palettes.contains(palette) else { return nil }
    return (symbol, palette)
  }

  /// The SF Symbol drawn for a built-in symbol name.
  static func systemImage(for symbol: String) -> String {
    switch symbol {
    case "star": "star.fill"
    case "rocket": "airplane.departure"
    case "cat": "cat.fill"
    case "dog": "dog.fill"
    case "heart": "heart.fill"
    case "bolt": "bolt.fill"
    case "leaf": "leaf.fill"
    case "moon": "moon.fill"
    case "music": "music.note"
    case "gamecontroller": "gamecontroller.fill"
    case "film": "film.fill"
    case "crown": "crown.fill"
    default: "person.fill"
    }
  }

  /// The index into `AureliaProfileAvatar.palettes` (0–6), or 7 for red.
  static func paletteIndex(named name: String) -> Int {
    palettes.firstIndex(of: name) ?? 0
  }

  /// The longer side of a chosen photo while it is cropped; enough detail to zoom in, small
  /// enough to keep the crop sheet quick with photos straight from a camera.
  static let cropEdge = 2048

  /// A chosen photo, upright, for the crop sheet. Returns nil for data that is not a picture.
  static func editablePhoto(_ data: Data) -> NSImage? {
    guard let image = uprightImage(data, maximumEdge: cropEdge) else { return nil }
    return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
  }

  /// The square chosen in the crop sheet, ready to upload like `preparedPhoto`.
  @MainActor static func croppedPhoto(_ image: NSImage, crop: ArtworkCrop) -> Data? {
    let square = CropImage.render(image, crop: crop, maximumDimension: uploadEdge)
    guard let cgImage = square.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return nil
    }
    return jpeg(cgImage)
  }

  /// A photo ready to upload: JPEG, at most `uploadEdge` pixels on its longer side, upright.
  /// Returns nil for data that is not a picture ImageIO can read.
  static func preparedPhoto(_ data: Data) -> Data? {
    guard let image = uprightImage(data, maximumEdge: uploadEdge) else { return nil }
    return jpeg(image)
  }

  private static func uprightImage(_ data: Data, maximumEdge: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  private static func jpeg(_ image: CGImage) -> Data? {
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
    guard CGImageDestinationFinalize(destination), output.length <= maximumUploadBytes else {
      return nil
    }
    return output as Data
  }
}

/// The age steps of a children's profile, after the German FSK ratings. Titles above the step and
/// titles without a rating are hidden unless the owner allows them.
enum ProfileAgeSteps {
  static let all: [(value: Int, label: String)] = [
    (0, "Under 6 · FSK 0"),
    (6, "6 to 11 · up to FSK 6"),
    (12, "12 to 15 · up to FSK 12"),
    (16, "16 or 17 · up to FSK 16"),
  ]

  static func label(for limit: Int) -> String {
    all.first { $0.value == limit }?.label ?? "Up to FSK \(limit)"
  }

  /// "Children's profile · up to FSK 6" for lists of profiles.
  static func summary(for limit: Int?) -> String? {
    guard let limit else { return nil }
    return limit == 0 ? "Children's profile · FSK 0" : "Children's profile · up to FSK \(limit)"
  }
}

enum ServerFeatureNames {
  static let profilePersonalization = "profile-personalization-v1"
  static let ageLimits = "age-limits-v1"
  /// Bedtime, a daily limit and "one more episode" for children's profiles.
  static let screenTime = "screen-time-v1"
  /// Trailers of films not watched yet, for cinema mode's pre-show.
  static let cinemaTrailers = "cinema-trailers-v1"
  /// Movie Night: the household swipes one deck until everyone likes a title.
  static let movieNight = "movie-night-v1"
  /// The year as slides with the server's lines.
  static let yearWrapped = "year-wrapped-v1"
  static let monthlyWrapped = "monthly-wrapped-v1"
  /// HLS in several qualities, converted live by the server.
  static let adaptiveStreaming = StreamingQuality.feature
  /// The server finds intros and credits and sends their times with the playback ticket.
  static let mediaSegments = "media-segments-v2"
  /// Subtitles from speech and Sync to Speech written by the server with whisper.cpp.
  static let serverSpeech = "server-speech-v1"
  static let suggestions = "suggestions-v1"
}
