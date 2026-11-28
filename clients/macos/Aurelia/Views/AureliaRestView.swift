import AppKit
import SwiftUI

/// Covers the window while Aurelia rests. Switching back to Aurelia, clicking anywhere, or
/// pressing any key automatically wakes the server and reconnects immediately.
struct AureliaRestView: View {
  @EnvironmentObject private var model: AppModel
  @State private var monitor: Any?

  var body: some View {
    ZStack {
      AureliaBackdrop()
      VStack(spacing: 22) {
        if model.isLeavingRest {
          Image(systemName: "power")
            .font(.system(size: 46, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.white.opacity(0.86))
          ServerConnectionStatusText(status: model.connectionStatus, serverName: serverName)
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "moon.zzz.fill")
            .font(.system(size: 46, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.white.opacity(0.86))
          VStack(spacing: 8) {
            Text("Aurelia Is Resting")
              .font(.title2.weight(.semibold))
            Text(
              "Nothing played and no one used this Mac's Aurelia for \(AureliaRest.minutes()) minutes, so it disconnected from \(serverName.map { "the server “\($0)”" } ?? "your server"). The server can save power now."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Text("Switch to Aurelia, click anywhere, or press any key to connect again.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          .multilineTextAlignment(.center)
          .frame(maxWidth: 460)
          Button("Continue") { resume() }
            .buttonStyle(AureliaPrimaryActionButtonStyle())
            .accessibilityIdentifier("rest-continue")
        }
      }
      .padding(40)
    }
    .contentShape(Rectangle())
    .onTapGesture { resume() }
    .accessibilityIdentifier("aurelia-rest")
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      resume()
    }
    .onAppear {
      monitor = NSEvent.addLocalMonitorForEvents(
        matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
      ) { event in
        guard model.isResting else { return event }
        if event.type == .keyDown, event.modifierFlags.contains(.command) { return event }
        resume()
        return event.type == .keyDown ? nil : event
      }
    }
    .onDisappear {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }

  private var serverName: String? { model.deviceConnection?.name ?? model.profile?.name }

  private func resume() {
    guard model.isResting else { return }
    Task { await model.leaveRest() }
  }
}
