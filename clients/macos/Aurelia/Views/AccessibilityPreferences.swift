import SwiftUI

extension EnvironmentValues {
  // Native preferences remain authoritative in production. The opt-in DEBUG fixture
  // exercises the same rendering branches without changing macOS preferences.
  private var cinemaAccessibilityFixture: Bool {
    #if DEBUG
      let environment = ProcessInfo.processInfo.environment
      return environment["AURELIA_UI_TEST_MODE"] == "library-admin"
        && environment["AURELIA_CINEMA_UI_TESTS"] == "1"
        && environment["AURELIA_CINEMA_ACCESSIBILITY"] == "1"
    #else
      return false
    #endif
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
