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
    #if DEBUG
      if auditRenderReduceTransparency { return true }
    #endif
    return accessibilityReduceTransparency || cinemaAccessibilityFixture
  }

  /// The system setting, or Settings › General › Reduce Motion in Aurelia.
  var aureliaReduceMotion: Bool {
    accessibilityReduceMotion || cinemaAccessibilityFixture
      || LibraryDisplayPreferences.reducesMotion()
  }

  var aureliaContrast: ColorSchemeContrast {
    #if DEBUG
      if auditRenderIncreasedContrast { return .increased }
    #endif
    return cinemaAccessibilityFixture ? .increased : colorSchemeContrast
  }
}

#if DEBUG
  // scripts/audit-render-screens.sh draws screens offscreen with these set on the hosting view's
  // environment only; the Mac's own accessibility settings are never changed.
  private struct AuditRenderReduceTransparencyKey: EnvironmentKey {
    static let defaultValue = false
  }
  private struct AuditRenderIncreasedContrastKey: EnvironmentKey {
    static let defaultValue = false
  }

  extension EnvironmentValues {
    var auditRenderReduceTransparency: Bool {
      get { self[AuditRenderReduceTransparencyKey.self] }
      set { self[AuditRenderReduceTransparencyKey.self] = newValue }
    }
    var auditRenderIncreasedContrast: Bool {
      get { self[AuditRenderIncreasedContrastKey.self] }
      set { self[AuditRenderIncreasedContrastKey.self] = newValue }
    }
  }
#endif
