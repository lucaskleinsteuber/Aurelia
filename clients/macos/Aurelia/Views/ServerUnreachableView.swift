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
        HStack(spacing: 12) {
          if case .waking = status {
            Button("Stop Waiting") { model.stopWaitingForServer() }
          }
          WatchOfflineButton()
        }
      } else if let host = model.currentServerAppHost {
        // A server inside Aurelia on a desktop or laptop: its owner starts it there.
        let computer = host == "linuxApp" ? "Linux PC" : "Mac"
        Image(systemName: host == "linuxApp" ? "desktopcomputer" : "laptopcomputer")
          .font(.system(size: 46, weight: .medium))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.white.opacity(0.86))
        VStack(spacing: 8) {
          Text("Start Aurelia on Your \(computer)")
            .font(.title2.weight(.semibold))
          Text(
            "\(serverName ?? "Your server") runs inside the Aurelia app on a \(computer). Open Aurelia there, or wake the \(computer), and this Mac connects by itself."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
        Button("Try Again") { Task { await model.retryConnection() } }
          .buttonStyle(AureliaPrimaryActionButtonStyle())
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("server-retry")
        if model.canOfferOfflineMode { WatchOfflineButton().padding(.top, 12) }
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
        // Downloads play without the server, in the offline mode.
        if model.canOfferOfflineMode {
          VStack(spacing: 8) {
            WatchOfflineButton()
            Text("Shows only the titles on this Mac, without the server. Progress goes back to it later.")
              .font(.caption).foregroundStyle(.secondary)
          }
          .padding(.top, 12)
          .accessibilityIdentifier("server-unreachable-downloads")
        }
      }
    }
    .accessibilityIdentifier("server-unreachable")
  }

  private var serverName: String? { model.deviceConnection?.name ?? model.profile?.name }
}
