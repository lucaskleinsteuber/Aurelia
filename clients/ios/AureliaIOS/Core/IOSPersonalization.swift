import Combine
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The built-in profile pictures every client draws the same way: a symbol on a palette gradient,
/// stored on the server as `symbol:palette`. `photo` means the profile has its own photo.
enum IOSProfilePictures {
  static let photoKey = "photo"
  static let maximumUploadBytes = 8 * 1024 * 1024
  /// Photos are sent at most this wide; the server keeps a 512-pixel square of them.
  static let uploadEdge = 1024

  static let symbols = [
    "star", "rocket", "cat", "dog", "heart", "bolt", "leaf", "moon", "music", "gamecontroller",
    "film", "crown",
  ]
  /// In the order of the existing profile gradients, plus red.
  static let palettes = ["blue", "purple", "pink", "orange", "teal", "green", "indigo", "red"]

  static func builtin(symbol: String, palette: String) -> String { "\(symbol):\(palette)" }

  static func parse(_ key: String?) -> (symbol: String, palette: String)? {
    guard let parts = key?.split(separator: ":", omittingEmptySubsequences: false),
      parts.count == 2
    else { return nil }
    let symbol = String(parts[0])
    let palette = String(parts[1])
    guard symbols.contains(symbol), palettes.contains(palette) else { return nil }
    return (symbol, palette)
  }

  /// The SF Symbol for a built-in symbol; the rocket has its own drawing (SF Symbols has none).
  static func systemImage(for symbol: String) -> String {
    switch symbol {
    case "star": "star.fill"
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

  static func paletteIndex(named name: String) -> Int { palettes.firstIndex(of: name) ?? 0 }

  /// A photo ready to upload: an upright JPEG at most `uploadEdge` pixels on its longer side.
  /// HEIC photos from the camera become JPEG here. Nil for data that is not a picture.
  static func preparedPhoto(_ data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: uploadEdge,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }
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

/// Cropping an own photo to the square the profile shows: the photo fills a square frame `side`
/// points wide at `zoom` (1 fills the shorter side) and is moved by `offset` points.
enum IOSPhotoCrop {
  static let maximumZoom: CGFloat = 4

  /// How far the photo may move at `zoom` so it still covers the frame.
  static func clamped(offset: CGSize, imageSize: CGSize, side: CGFloat, zoom: CGFloat) -> CGSize {
    guard imageSize.width > 0, imageSize.height > 0, side > 0 else { return .zero }
    let scale = side / min(imageSize.width, imageSize.height) * min(max(zoom, 1), maximumZoom)
    let spareX = max(0, (imageSize.width * scale - side) / 2)
    let spareY = max(0, (imageSize.height * scale - side) / 2)
    return CGSize(
      width: min(max(offset.width, -spareX), spareX),
      height: min(max(offset.height, -spareY), spareY))
  }

  /// The square of the photo, in its pixels, that the frame shows.
  static func rect(imageSize: CGSize, side: CGFloat, zoom: CGFloat, offset: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, side > 0 else { return .zero }
    let zoom = min(max(zoom, 1), maximumZoom)
    let scale = side / min(imageSize.width, imageSize.height) * zoom
    let offset = clamped(offset: offset, imageSize: imageSize, side: side, zoom: zoom)
    let length = side / scale
    let x = imageSize.width / 2 - offset.width / scale - length / 2
    let y = imageSize.height / 2 - offset.height / scale - length / 2
    return CGRect(
      x: min(max(x, 0), imageSize.width - length), y: min(max(y, 0), imageSize.height - length),
      width: length, height: length)
  }

  /// The photo upright, at most 3000 pixels on its longer side, for showing and cropping.
  static func uprightImage(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 3_000,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  /// The cropped square as a JPEG of at most `IOSProfilePictures.uploadEdge` pixels.
  static func croppedJPEG(_ image: CGImage, rect: CGRect) -> Data? {
    guard let cropped = image.cropping(to: rect.integral) else { return nil }
    let edge = min(IOSProfilePictures.uploadEdge, cropped.width)
    guard edge > 0,
      let context = CGContext(
        data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: edge, height: edge))
    guard let scaled = context.makeImage() else { return nil }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
    guard CGImageDestinationFinalize(destination),
      output.length <= IOSProfilePictures.maximumUploadBytes
    else { return nil }
    return output as Data
  }
}

/// Cropping an image to a rectangular aspect ratio (`2:3` poster or `16:9` backdrop) with
/// normalized server crop coordinates `[0, 1]`.
enum IOSRectCrop {
  static let maximumZoom: CGFloat = 4
  static let maximumArtworkUploadBytes = 24 * 1024 * 1024

  static func clamped(
    offset: CGSize, imageSize: CGSize, frameSize: CGSize, zoom: CGFloat
  ) -> CGSize {
    guard imageSize.width > 0, imageSize.height > 0, frameSize.width > 0, frameSize.height > 0
    else { return .zero }
    let baseScale = max(frameSize.width / imageSize.width, frameSize.height / imageSize.height)
    let scale = baseScale * min(max(zoom, 1), maximumZoom)
    let spareX = max(0, (imageSize.width * scale - frameSize.width) / 2)
    let spareY = max(0, (imageSize.height * scale - frameSize.height) / 2)
    return CGSize(
      width: min(max(offset.width, -spareX), spareX),
      height: min(max(offset.height, -spareY), spareY))
  }

  static func normalizedCrop(
    imageSize: CGSize, frameSize: CGSize, zoom: CGFloat, offset: CGSize
  ) -> IOSArtworkCrop {
    guard imageSize.width > 0, imageSize.height > 0, frameSize.width > 0, frameSize.height > 0
    else { return IOSArtworkCrop(x: 0, y: 0, width: 1, height: 1) }
    let clampedZoom = min(max(zoom, 1), maximumZoom)
    let baseScale = max(frameSize.width / imageSize.width, frameSize.height / imageSize.height)
    let scale = baseScale * clampedZoom
    let clampedOffset = clamped(
      offset: offset, imageSize: imageSize, frameSize: frameSize, zoom: clampedZoom)
    let cropWidthPx = min(imageSize.width, frameSize.width / scale)
    let cropHeightPx = min(imageSize.height, frameSize.height / scale)
    let xPx = min(
      max(imageSize.width / 2 - clampedOffset.width / scale - cropWidthPx / 2, 0),
      imageSize.width - cropWidthPx)
    let yPx = min(
      max(imageSize.height / 2 - clampedOffset.height / scale - cropHeightPx / 2, 0),
      imageSize.height - cropHeightPx)
    return IOSArtworkCrop(
      x: Double(xPx / imageSize.width),
      y: Double(yPx / imageSize.height),
      width: Double(cropWidthPx / imageSize.width),
      height: Double(cropHeightPx / imageSize.height))
  }

  /// Encodes `image` cleanly as JPEG for `/api/v1/collections/{id}/editor/uploads`.
  static func jpegUploadData(_ image: CGImage) -> Data? {
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination),
      output.length > 0,
      output.length <= maximumArtworkUploadBytes
    else { return nil }
    return output as Data
  }
}

/// "Children's profile · up to FSK 6" for a profile with an age limit.
enum IOSAgeLimit {
  static func summary(for limit: Int?) -> String? {
    guard let limit else { return nil }
    return limit == 0 ? "Children's profile · FSK 0" : "Children's profile · up to FSK \(limit)"
  }
}

/// A QR code for a web address, drawn as sharp square modules.
enum IOSQRCode {
  /// The download page the "Not Yet" guide points to.
  static let downloadPage = URL(string: "https://github.com/lucaskleinsteuber/Aurelia#readme")!

  /// A QR code image whose modules are `scale` pixels wide, or nil when the text is too long.
  static func image(for text: String, scale: CGFloat = 10) -> CGImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(
      scaled, from: scaled.extent)
  }
}

/// A step of the guided setup, shown in the step bar while the assistant guides.
enum IOSSetupStep: String, CaseIterable, Sendable {
  case connect, approve, profile, done

  var title: String {
    switch self {
    case .connect: "Connect"
    case .approve: "Approve"
    case .profile: "Choose Profile"
    case .done: "Done"
    }
  }
}

/// The setup assistant's state, kept in this app's preferences so a restart continues where it
/// stopped. An app that is already connected never sees it.
@MainActor
final class IOSSetupGuide: ObservableObject {
  static let introSeenKey = "AureliaSetupGuide.introSeen"
  static let guidingKey = "AureliaSetupGuide.guiding"
  static let tourPendingKey = "AureliaSetupGuide.tourPending"

  private let defaults: UserDefaults
  @Published private(set) var introSeen: Bool
  @Published private(set) var isGuiding: Bool
  @Published private(set) var tourPending: Bool

  init(defaults: UserDefaults, alreadySetUp: Bool) {
    self.defaults = defaults
    if alreadySetUp, defaults.object(forKey: Self.introSeenKey) == nil {
      defaults.set(true, forKey: Self.introSeenKey)
    }
    introSeen = defaults.bool(forKey: Self.introSeenKey)
    isGuiding = defaults.bool(forKey: Self.guidingKey)
    tourPending = defaults.bool(forKey: Self.tourPendingKey)
  }

  /// The plain connection screen follows, without guidance or tour.
  func skipIntroduction() { markIntroSeen() }

  /// The introduction is done; connecting, approving and choosing a profile follow, guided.
  func start() {
    markIntroSeen()
    set(\.isGuiding, true, key: Self.guidingKey)
  }

  /// "Skip": the screens stay, the guidance and the tour go.
  func skip() {
    markIntroSeen()
    set(\.isGuiding, false, key: Self.guidingKey)
  }

  /// "Start Watching": the guidance ends and the tour follows.
  func finish() {
    set(\.isGuiding, false, key: Self.guidingKey)
    requestTour()
  }

  func requestTour() { set(\.tourPending, true, key: Self.tourPendingKey) }
  func tourShown() { set(\.tourPending, false, key: Self.tourPendingKey) }

  /// The step a screen of the connection flow belongs to.
  static func step(connected: Bool, pairing: Bool, choosingProfile: Bool) -> IOSSetupStep {
    if choosingProfile { return .profile }
    if pairing { return .approve }
    return connected ? .done : .connect
  }

  private func markIntroSeen() { set(\.introSeen, true, key: Self.introSeenKey) }

  private func set(
    _ property: ReferenceWritableKeyPath<IOSSetupGuide, Bool>, _ value: Bool, key: String
  ) {
    self[keyPath: property] = value
    defaults.set(value, forKey: key)
  }
}
