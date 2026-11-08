import SwiftUI
import UIKit

/// "Aurelia Test": a separate app (its own bundle identifier, so its own preferences, Keychain
/// items and files) for trying the first run again and again. Only that app shows these tools.
enum IOSTestEdition {
  static var isActive: Bool {
    #if AURELIA_TEST_EDITION
      // A second guard: only an app whose identifier says so may erase anything.
      return Bundle.main.bundleIdentifier?.hasSuffix(".test") == true
    #else
      return false
    #endif
  }

  /// iOS keeps Keychain items when an app is deleted. A freshly installed Aurelia Test has no
  /// preferences yet, so a server connection still in the Keychain is a leftover of an earlier
  /// install: it is removed so the app starts at "Welcome to Aurelia" like a new one.
  @MainActor static func forgetLeftoversAfterReinstall() {
    guard isActive else { return }
    let marker = "AureliaTestEditionInstalled"
    guard !UserDefaults.standard.bool(forKey: marker) else { return }
    try? IOSCredentialStore().delete()
    UserDefaults.standard.set(true, forKey: marker)
  }

  /// Erases this app's own data — the saved server, the profile, preferences, stored artwork —
  /// and closes it, so the next start begins at "Welcome to Aurelia". Media is never touched.
  @MainActor static func resetAppData() {
    guard isActive, let identifier = Bundle.main.bundleIdentifier else { return }
    try? IOSCredentialStore().delete()
    UserDefaults.standard.removePersistentDomain(forName: identifier)
    UserDefaults.standard.synchronize()
    let files = FileManager.default
    for directory in [
      FileManager.SearchPathDirectory.cachesDirectory, .applicationSupportDirectory,
      .documentDirectory,
    ] {
      guard let folder = files.urls(for: directory, in: .userDomainMask).first,
        let items = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      else { continue }
      for item in items { try? files.removeItem(at: item) }
    }
    exit(0)
  }
}

/// Settings › Test Tools, only in Aurelia Test.
struct IOSTestToolsSection: View {
  @EnvironmentObject private var model: IOSAppModel
  @State private var confirmingReset = false

  var body: some View {
    Section {
      Button("Show Introduction") {
        NotificationCenter.default.post(name: .iosShowIntroduction, object: nil)
      }
      Button("Show Tour") { model.setupGuide.requestTour() }
      Button("Reset App Data", role: .destructive) { confirmingReset = true }
        .accessibilityIdentifier("test-reset-app-data")
    } header: {
      Text("Test Tools")
    } footer: {
      Text(
        "Only in Aurelia Test. Reset App Data erases this test app's server, profile and settings and closes it; open it again to start from the beginning. The real Aurelia app and your media stay untouched."
      )
    }
    .confirmationDialog(
      "Erase Aurelia Test's data?", isPresented: $confirmingReset, titleVisibility: .visible
    ) {
      Button("Reset App Data", role: .destructive) { IOSTestEdition.resetAppData() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The app closes afterwards. Open it again to set it up from the beginning.")
    }
  }
}
