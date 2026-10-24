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
        "Connect a Mac, Apple TV or web browser to this server, and sign out devices you no longer use."
    ) {
      VStack(alignment: .leading, spacing: 18) {
        appleTVPairing
        Divider()
        browserAccess
        Divider()
        macPairing
        let sessions = model.sessions.filter(\.isActive)
        if !sessions.isEmpty {
          Divider()
          Text("Signed-In Devices").font(.headline)
          ForEach(sessions) { session in
            HStack {
              VStack(alignment: .leading) {
                Text(session.deviceName)
                lastUsed(session).font(.caption).foregroundStyle(.secondary)
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
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .sheet(isPresented: $showingDeviceApproval) { DeviceApprovalView() }
  }

  /// The Apple TV and a web browser show a code themselves; the owner confirms it here.
  private var appleTVPairing: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Apple TV", systemImage: "appletv").font(.headline)
      Text(
        "Open Aurelia on the Apple TV and choose this server. The TV shows an 8-digit code; enter it here to let the TV in."
      )
      .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if model.profile?.user?.role == .owner {
        Button("Enter Code from Apple TV or Browser…") { showingDeviceApproval = true }
          .disabled(!model.libraryCapabilities.contains("device-authorization-v1"))
          .help(
            model.libraryCapabilities.contains("device-authorization-v1")
              ? "Enter the code shown on the Apple TV or in the browser."
              : "Requires Aurelia Server 1.5.5."
          )
          .accessibilityIdentifier("approve-device")
      } else {
        Text("Only the owner can approve an Apple TV or a browser.").font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// The server serves Aurelia for web browsers itself; a browser signs in with a code too.
  private var browserAccess: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Web Browser", systemImage: "safari").font(.headline)
      if !model.libraryCapabilities.contains("web-app-v1") {
        Text("Using Aurelia in a web browser requires Aurelia Server 1.10.0.")
          .font(.callout).foregroundStyle(.secondary)
      } else if let address = browserAddress {
        Text(
          address.thisMacOnly
            ? "Open this address in a browser on this Mac. To use Aurelia in browsers on other devices, turn on home network access for this server."
            : "Open this address in a browser on any device at home. The browser shows an 8-digit code; enter it with “Enter Code from Apple TV or Browser…”."
        )
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
          Text(address.url.absoluteString).font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .accessibilityIdentifier("browser-address")
          Spacer()
          Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address.url.absoluteString, forType: .string)
          }
          Button("Open") { NSWorkspace.shared.open(address.url) }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        if !address.thisMacOnly {
          Text(
            "The first time, the browser warns that the connection isn’t private, because the server signs its own certificate. Continue to the page to use Aurelia."
          )
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Text("Connect to a server to see its browser address.")
          .font(.callout).foregroundStyle(.secondary)
      }
    }
  }

  private var browserAddress: BrowserAddress? {
    guard let serverURL = model.profile?.baseURL else { return nil }
    let local = model.isLocalHost ? model.hostSnapshot.serverInfo : nil
    return BrowserAddress.resolve(
      serverURL: serverURL, lanAccessEnabled: local?.lanAccessEnabled, lanPort: local?.lanHttpsPort)
  }

  /// Another Mac cannot show a code before it is paired, so this Mac makes one for it.
  private var macPairing: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Another Mac", systemImage: "laptopcomputer").font(.headline)
      Text(
        "Create a code here, then type it into Aurelia on the other Mac when it connects to this server. A code works once and for five minutes."
      )
      .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let code = model.pairingCode {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          pairingCode(code, now: context.date)
        }
      }
      Button(model.pairingCode == nil ? "Pair a Mac" : "Create a New Code") {
        Task { await model.generatePairingCode() }
      }
      .buttonStyle(AureliaPrimaryActionButtonStyle())
      .accessibilityIdentifier("pair-mac")
    }
  }

  private func pairingCode(_ code: PairingCodeResponse, now: Date) -> some View {
    let expiry = code.expiryDate
    let remaining = expiry.map { max(0, Int($0.timeIntervalSince(now).rounded(.up))) } ?? 0
    let expired = expiry == nil || remaining == 0
    return HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(code.code).font(.system(.title2, design: .monospaced, weight: .bold))
          .strikethrough(expired).foregroundStyle(expired ? .secondary : .primary)
          .textSelection(.enabled)
        Group {
          if expired {
            Text("This code has expired. Create a new one.")
          } else if let expiry {
            Text(
              "Valid for \(String(format: "%d:%02d", remaining / 60, remaining % 60)), until \(expiry.formatted(date: .omitted, time: .shortened))"
            )
            .monospacedDigit()
          }
        }
        .font(.caption).foregroundStyle(expired ? .orange : .secondary)
        .accessibilityIdentifier("pairing-code-expiry")
      }
      Spacer()
      Button("Copy") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.code, forType: .string)
      }
      .disabled(expired)
    }
    .padding(12)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
  }

  private func lastUsed(_ session: DeviceSessionSummary) -> Text {
    if session.isCurrent { return Text("This device") }
    guard let date = session.lastSeenDate else { return Text("Last used \(session.lastSeenAt)") }
    return Text("Last used \(date, format: .relative(presentation: .named))")
  }
}
