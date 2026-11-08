import Combine
import CoreGraphics
import CoreImage
import Foundation

/// The built-in profile pictures every client draws the same way: a symbol on a palette gradient,
/// stored on the server as `symbol:palette`. `photo` means the profile has its own photo.
enum TVProfilePictures {
  static let photoKey = "photo"

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
}

/// "Children's profile · up to FSK 6" for a profile with an age limit.
enum TVAgeLimit {
  static func summary(for limit: Int?) -> String? {
    guard let limit else { return nil }
    return limit == 0 ? "Children's profile · FSK 0" : "Children's profile · up to FSK \(limit)"
  }
}

/// A QR code for a web address, drawn as sharp square modules.
enum TVQRCode {
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
enum TVSetupStep: String, CaseIterable, Sendable {
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
final class TVSetupGuide: ObservableObject {
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
  static func step(connected: Bool, pairing: Bool, choosingProfile: Bool) -> TVSetupStep {
    if choosingProfile { return .profile }
    if pairing { return .approve }
    return connected ? .done : .connect
  }

  private func markIntroSeen() { set(\.introSeen, true, key: Self.introSeenKey) }

  private func set(
    _ property: ReferenceWritableKeyPath<TVSetupGuide, Bool>, _ value: Bool, key: String
  ) {
    self[keyPath: property] = value
    defaults.set(value, forKey: key)
  }
}
