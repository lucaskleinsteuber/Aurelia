import SwiftUI

/// Shown while Aurelia wakes its server again, or when the server stayed silent, in place of a
/// bare connection error.
struct ServerUnreachableView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(spacing: 22) {
      if let status = model.connectionStatus {
        Image(systemName: "power")
          .font(.system(size: 46, weight: .medium))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.white.opacity(0.86))
        ServerConnectionStatusText(status: status, serverName: serverName)
        ProgressView().controlSize(.small)
        if case .waking = status {
          Button("Stop Waiting") { model.stopWaitingForServer() }
        }
      } else {
        Image(systemName: model.canWakeCurrentServer ? "moon.zzz.fill" : "wifi.slash")
          .font(.system(size: 46, weight: .medium))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.white.opacity(0.86))
        VStack(spacing: 8) {
          Text(
            model.canWakeCurrentServer
              ? "\(serverName ?? "Your Server") May Be Asleep"
              : "\(serverName ?? "Your Server") Isn’t Answering"
          )
          .font(.title2.weight(.semibold))
          Text(
            model.canWakeCurrentServer
              ? "The server may be in standby. Aurelia can send a wake packet or keep trying in the background."
              : "Aurelia tried to reach it and keeps trying in the background. Check that the server is switched on and connected to your network."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
        HStack(spacing: 12) {
          if model.canWakeCurrentServer {
            Button("Wake Server") { Task { await model.retryConnection() } }
              .buttonStyle(AureliaPrimaryActionButtonStyle())
              .accessibilityIdentifier("server-wake")
            Button("Try Again") { Task { await model.retryConnection() } }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("server-retry")
          } else {
            Button("Try Again") { Task { await model.retryConnection() } }
              .buttonStyle(AureliaPrimaryActionButtonStyle())
              .keyboardShortcut(.defaultAction)
              .accessibilityIdentifier("server-retry")
          }
        }
      }
    }
    .accessibilityIdentifier("server-unreachable")
  }

  private var serverName: String? { model.deviceConnection?.name ?? model.profile?.name }
}
