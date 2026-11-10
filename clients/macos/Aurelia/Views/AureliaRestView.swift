import AppKit
import SwiftUI

/// Covers the window while Aurelia rests. Only Continue (or Return) goes on: that wakes the server
/// and loads what was showing again. Other clicks, such as closing the window, leave it asleep.
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
            Text("Click Continue or press Return to connect again.")
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
    .accessibilityIdentifier("aurelia-rest")
    .onAppear {
      // Keys do not reach the library beneath, and only Return continues. Clicks stay with the
      // window, so closing it or clicking beside Continue does not wake the server.
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard model.isResting else { return event }
        if event.modifierFlags.contains(.command) { return event }
        if AureliaRestView.continueKeys.contains(event.keyCode) { resume() }
        return nil
      }
    }
    .onDisappear {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }

  /// Return and the keypad's Enter.
  static let continueKeys: Set<UInt16> = [36, 76]

  private var serverName: String? { model.deviceConnection?.name ?? model.profile?.name }

  private func resume() {
    guard model.isResting else { return }
    Task { await model.leaveRest() }
  }
}
