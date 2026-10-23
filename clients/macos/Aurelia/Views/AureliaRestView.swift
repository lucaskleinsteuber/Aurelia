import AppKit
import SwiftUI

/// Covers the window while Aurelia rests. Any click or key continues: the server is woken and
/// what was showing loads again.
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
              "Nothing played and no one used Aurelia for \(AureliaRest.minutes()) minutes, so it let go of \(serverName ?? "your server"). The server can save power now."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Text("Click anywhere or press a key to continue.")
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
    .onAppear {
      // Keys and clicks only wake Aurelia; they do not reach the library beneath.
      monitor = NSEvent.addLocalMonitorForEvents(
        matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
      ) { event in
        guard model.isResting else { return event }
        resume()
        return event.modifierFlags.contains(.command) ? event : nil
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
