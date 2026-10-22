import AppKit
import SwiftUI

/// Pairing new devices and the sessions of this server's devices.
struct ServerDevicesSection: View {
  @EnvironmentObject private var model: AppModel
  @State private var showingDeviceApproval = false

  var body: some View {
    AureliaSettingsSection(
      "Devices",
      symbol: "laptopcomputer.and.iphone",
      description:
        "Connect a Mac or Apple TV to this server, and sign out devices you no longer use."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        if let code = model.pairingCode {
          HStack {
            VStack(alignment: .leading) {
              Text(code.code).font(.system(.title2, design: .monospaced, weight: .bold))
              Text("Expires \(code.expiresAt)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(code.code, forType: .string)
            }
          }
        }
        Button("Pair Another Device") { Task { await model.generatePairingCode() } }
          .buttonStyle(AureliaPrimaryActionButtonStyle())
        if model.profile?.user?.role == .owner {
          Button("Approve Device…") { showingDeviceApproval = true }
            .disabled(!model.libraryCapabilities.contains("device-authorization-v1"))
            .help(
              model.libraryCapabilities.contains("device-authorization-v1")
                ? "Enter the code shown on the new device." : "Requires Aurelia Server 1.5.5."
            )
            .accessibilityIdentifier("approve-device")
        }
        ForEach(model.sessions.filter(\.isActive)) { session in
          HStack {
            VStack(alignment: .leading) {
              Text(session.deviceName)
              Text(session.isCurrent ? "This device" : "Last used \(session.lastSeenAt)")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !session.isCurrent && session.revokedAt == nil {
              Button("Revoke", role: .destructive) {
                Task { await model.revokeSession(id: session.id) }
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .sheet(isPresented: $showingDeviceApproval) { DeviceApprovalView() }
  }
}
