import SwiftUI
import UIKit

/// "Aurelia Test": a separate app (its own bundle identifier, so its own preferences, Keychain
/// items and files) for trying the first run again and again. Only that app shows these tools.
enum TVTestEdition {
  static var isActive: Bool {
    #if AURELIA_TEST_EDITION
      // A second guard: only an app whose identifier says so may erase anything.
      return Bundle.main.bundleIdentifier?.hasSuffix(".test") == true
    #else
      return false
    #endif
  }

  /// The Keychain can keep items when an app is deleted. A freshly installed Aurelia Test has no
  /// preferences yet, so a server connection still in the Keychain is a leftover of an earlier
  /// install: it is removed so the app starts at "Welcome to Aurelia" like a new one.
  @MainActor static func forgetLeftoversAfterReinstall() {
    guard isActive else { return }
    let marker = "AureliaTestEditionInstalled"
    guard !UserDefaults.standard.bool(forKey: marker) else { return }
    try? TVCredentialStore().delete()
    UserDefaults.standard.set(true, forKey: marker)
  }

  /// Erases this app's own data — the saved server, the profile, preferences, stored artwork —
  /// and closes it, so the next start begins at "Welcome to Aurelia". Media is never touched.
  @MainActor static func resetAppData() {
    guard isActive, let identifier = Bundle.main.bundleIdentifier else { return }
    try? TVCredentialStore().delete()
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

/// Profile › Test Tools, only in Aurelia Test.
struct TVTestToolsSection: View {
  @EnvironmentObject private var model: TVAppModel
  @State private var confirmingReset = false

  var body: some View {
    VStack(spacing: 22) {
      Text("Test Tools").font(.headline).foregroundStyle(.orange)
      Button {
        NotificationCenter.default.post(name: .tvShowIntroduction, object: nil)
      } label: {
        Label("Show Introduction", systemImage: "sparkles").frame(width: 560)
      }
      Button {
        model.setupGuide.requestTour()
      } label: {
        Label("Show Tour", systemImage: "hand.point.up.left").frame(width: 560)
      }
      Button(role: .destructive) {
        confirmingReset = true
      } label: {
        Label("Reset App Data", systemImage: "trash").frame(width: 560)
      }
      .accessibilityIdentifier("test-reset-app-data")
      Text("Only in Aurelia Test. The real Aurelia app and your media stay untouched.")
        .font(.system(size: 20)).foregroundStyle(.secondary)
    }
    .buttonStyle(TVButtonStyle())
    .focusSection()
    .confirmationDialog(
      "Erase Aurelia Test's data?", isPresented: $confirmingReset, titleVisibility: .visible
    ) {
      Button("Reset App Data", role: .destructive) { TVTestEdition.resetAppData() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The app closes afterwards. Open it again to set it up from the beginning.")
    }
  }
}
