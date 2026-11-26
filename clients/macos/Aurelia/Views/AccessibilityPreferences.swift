import AppKit
import SwiftUI

enum AureliaAccessibilityFixture {
  static var enabled: Bool {
    #if DEBUG
      let environment = ProcessInfo.processInfo.environment
      return environment["AURELIA_UI_TEST_MODE"] == "library-admin"
        && environment["AURELIA_CINEMA_UI_TESTS"] == "1"
        && environment["AURELIA_CINEMA_ACCESSIBILITY"] == "1"
    #else
      return false
    #endif
  }
}

enum AureliaWindowAppearance {
  static func name(increaseContrast: Bool) -> NSAppearance.Name {
    increaseContrast ? .accessibilityHighContrastDarkAqua : .darkAqua
  }

  static func resolved(increaseContrast: Bool) -> NSAppearance? {
    NSAppearance(named: name(increaseContrast: increaseContrast))
  }
}

extension EnvironmentValues {
  // Native preferences remain authoritative in production. The opt-in DEBUG fixture
  // exercises the same rendering branches without changing macOS preferences.
  private var cinemaAccessibilityFixture: Bool {
    AureliaAccessibilityFixture.enabled
  }

  var aureliaReduceTransparency: Bool {
    accessibilityReduceTransparency || cinemaAccessibilityFixture
  }

  /// The system setting, or Settings › General › Reduce Motion in Aurelia.
  var aureliaReduceMotion: Bool {
    accessibilityReduceMotion || cinemaAccessibilityFixture
      || LibraryDisplayPreferences.reducesMotion()
  }

  var aureliaContrast: ColorSchemeContrast {
    cinemaAccessibilityFixture ? .increased : colorSchemeContrast
  }
}
