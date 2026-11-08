import Combine
import Foundation

/// Who will watch, answered in the setup assistant.
enum SetupAudience: String, Sendable {
  case justMe
  case severalPeople
}

/// Which other devices will watch, answered in the setup assistant. The last page explains how to
/// connect each one.
struct SetupDevices: OptionSet, Sendable, Hashable {
  let rawValue: Int
  static let appleTV = SetupDevices(rawValue: 1)
  static let phoneOrTablet = SetupDevices(rawValue: 2)
  static let computer = SetupDevices(rawValue: 4)
  static let webBrowser = SetupDevices(rawValue: 8)

  static let ordered: [(device: SetupDevices, label: String)] = [
    (.appleTV, "Apple TV"),
    (.phoneOrTablet, "iPhone or iPad"),
    (.computer, "Another Computer"),
    (.webBrowser, "Web Browser"),
  ]
}

/// A step of the guided setup, shown in the step bar above each setup screen.
enum SetupStep: String, Sendable, CaseIterable {
  case choose, secure, pin, media, people, connect, profile, done

  var title: String {
    switch self {
    case .choose: "Choose"
    case .secure: "Secure"
    case .pin: "Your PIN"
    case .media: "Your Media"
    case .people: "People"
    case .connect: "Connect"
    case .profile: "Profile"
    case .done: "Done"
    }
  }
}

/// The setup assistant's state: whether the introduction was seen, whether the guided setup is
/// running, the answers to its questions, and whether the library tour is still to come. Kept in
/// the app's preferences so a restart continues where it stopped. A Mac that was already set up
/// never sees the assistant.
@MainActor
final class SetupGuide: ObservableObject {
  static let introSeenKey = "AureliaSetupGuide.introSeen"
  static let guidingKey = "AureliaSetupGuide.guiding"
  static let audienceKey = "AureliaSetupGuide.audience"
  static let devicesKey = "AureliaSetupGuide.devices"
  static let tourPendingKey = "AureliaSetupGuide.tourPending"

  private let defaults: UserDefaults

  @Published private(set) var introSeen: Bool
  @Published private(set) var isGuiding: Bool
  @Published private(set) var tourPending: Bool
  @Published var audience: SetupAudience {
    didSet { defaults.set(audience.rawValue, forKey: Self.audienceKey) }
  }
  @Published var devices: SetupDevices {
    didSet { defaults.set(devices.rawValue, forKey: Self.devicesKey) }
  }

  init(defaults: UserDefaults = .standard, alreadySetUp: Bool) {
    self.defaults = defaults
    if alreadySetUp, defaults.object(forKey: Self.introSeenKey) == nil {
      defaults.set(true, forKey: Self.introSeenKey)
    }
    introSeen = defaults.bool(forKey: Self.introSeenKey)
    isGuiding = defaults.bool(forKey: Self.guidingKey)
    tourPending = defaults.bool(forKey: Self.tourPendingKey)
    audience =
      defaults.string(forKey: Self.audienceKey).flatMap(SetupAudience.init(rawValue:)) ?? .justMe
    devices = SetupDevices(rawValue: defaults.integer(forKey: Self.devicesKey))
  }

  /// "I Know Aurelia": the plain welcome choice follows, without guidance or tour.
  func skipIntroduction() {
    markIntroSeen()
  }

  /// The introduction's answers are in; the real setup screens follow under the step bar.
  func start() {
    markIntroSeen()
    isGuiding = true
    defaults.set(true, forKey: Self.guidingKey)
  }

  /// "Skip Assistant": the setup screens stay, the guidance and the tour go.
  func skip() {
    markIntroSeen()
    isGuiding = false
    defaults.set(false, forKey: Self.guidingKey)
  }

  /// "Start Watching" on the last page: the guidance ends and the library tour follows.
  func finish() {
    isGuiding = false
    defaults.set(false, forKey: Self.guidingKey)
    requestTour()
  }

  /// Settings › About › Show Tour.
  func requestTour() {
    tourPending = true
    defaults.set(true, forKey: Self.tourPendingKey)
  }

  func tourShown() {
    tourPending = false
    defaults.set(false, forKey: Self.tourPendingKey)
  }

  /// The guided steps for where the server runs: this Mac hosts it, or it connects to another.
  func steps(hosting: Bool) -> [SetupStep] {
    if hosting {
      return audience == .severalPeople
        ? [.choose, .secure, .pin, .media, .people, .done]
        : [.choose, .secure, .pin, .media, .done]
    }
    return [.choose, .connect, .profile, .done]
  }

  /// The UI fixture of the assistant always starts at its first page.
  func resetForFixture() {
    introSeen = false
    isGuiding = false
    tourPending = false
    for key in [Self.introSeenKey, Self.guidingKey, Self.tourPendingKey] {
      defaults.removeObject(forKey: key)
    }
  }

  private func markIntroSeen() {
    introSeen = true
    defaults.set(true, forKey: Self.introSeenKey)
  }
}
