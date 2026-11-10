import AppKit
import SwiftUI

/// The small "Updating Aurelia" window. It opens as soon as an update is chosen (from the offer,
/// the menu or Settings) and shows the download with its size, then that Aurelia closes and opens
/// again by itself. Closing it only hides it; the update goes on and Settings › Updates and
/// Check for Updates… bring it back.
@MainActor
final class AppUpdateProgressWindow {
  static let shared = AppUpdateProgressWindow()
  private var window: NSWindow?

  func show(updater: AppUpdater) {
    let window =
      self.window
      ?? {
        let window = NSWindow(
          contentViewController: NSHostingController(
            rootView: AppUpdateProgressView(updater: updater)))
        window.title = "Updating Aurelia"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        self.window = window
        return window
      }()
    window.makeKeyAndOrderFront(nil)
  }

  func close() {
    window?.orderOut(nil)
  }
}

/// The window's content: the app's icon, what happens, the bar and Cancel while downloading.
struct AppUpdateProgressView: View {
  @ObservedObject var updater: AppUpdater

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 56, height: 56)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 10) {
        Text(AppUpdateProgressBar.headline(updater))
          .font(.headline)
        AppUpdateProgressBar(updater: updater)
        HStack {
          Spacer()
          if updater.state == .downloading {
            Button("Cancel") { updater.cancelInstall() }
              .keyboardShortcut(.cancelAction)
              .accessibilityIdentifier("update-progress-cancel")
          }
        }
      }
    }
    .padding(20)
    .frame(width: 440)
  }
}

/// The bar and the line under it, the same in the window and in Settings › Updates.
struct AppUpdateProgressBar: View {
  @ObservedObject var updater: AppUpdater

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if updater.state == .downloading, let fraction = updater.progress?.fraction {
        ProgressView(value: fraction)
          .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
      } else {
        ProgressView().progressViewStyle(.linear)
      }
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("update-progress")
  }

  private var detail: String {
    switch updater.state {
    case .downloading:
      guard let progress = updater.progress, progress.received > 0 else {
        return "Connecting to GitHub…"
      }
      if let fraction = progress.fraction {
        return "\(progress.text) (\(Int((fraction * 100).rounded()))%)"
      }
      return progress.text
    case .installing:
      return "Aurelia closes and opens again by itself in a moment. Your library and settings stay."
    default:
      return ""
    }
  }

  static func headline(_ updater: AppUpdater) -> String {
    let name =
      updater.installingRelease.map {
        "Aurelia \($0.version)\($0.isBeta ? " Beta" : "")"
      } ?? "the update"
    return updater.state == .installing ? "Installing \(name)…" : "Downloading \(name)…"
  }
}
