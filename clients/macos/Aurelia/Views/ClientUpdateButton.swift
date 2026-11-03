import SwiftUI

/// Client updates are available before connection, server setup or profile unlock.
struct ClientUpdateButton: View {
  @ObservedObject private var updater = AppUpdater.shared

  var body: some View {
    Button {
      Task { await updater.check(userInitiated: true) }
    } label: {
      Label(title, systemImage: "arrow.down.circle")
        .font(.callout.weight(.medium))
        .padding(8)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .disabled(isBusy)
    .help("Update this Mac app without connecting to a server or unlocking a profile.")
    .accessibilityIdentifier("client-update-check-before-sign-in")
  }

  private var isBusy: Bool {
    updater.state == .checking || updater.state == .downloading || updater.state == .installing
  }

  private var title: String {
    switch updater.state {
    case .checking: "Checking for Updates…"
    case .downloading: "Downloading Update…"
    case .installing: "Installing Update…"
    default: "App Updates"
    }
  }
}
