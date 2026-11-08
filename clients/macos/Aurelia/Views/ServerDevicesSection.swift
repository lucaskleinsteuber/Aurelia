import AppKit
import SwiftUI

/// Pairing new devices and the sessions of this server's devices.
struct ServerDevicesSection: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    AureliaSettingsSection(
      "Devices",
      symbol: "laptopcomputer.and.iphone",
      description:
        "Let a new device use this server, and sign out devices you no longer use. Every new device asks once for an 8-digit code that this Mac shows."
    ) {
      VStack(alignment: .leading, spacing: 18) {
        macPairing
        Divider()
        browserAccess
        let sessions = model.sessions.filter(\.isActive)
        if !sessions.isEmpty {
          Divider()
          Text("Signed-In Devices").font(.headline)
          Text("Devices that can use this server now. Sign Out ends a device’s access; it then needs a new code.")
            .font(.caption).foregroundStyle(.secondary)
          ForEach(sessions) { session in
            HStack {
              VStack(alignment: .leading) {
                Text(session.deviceName)
                lastUsed(session).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if !session.isCurrent && session.revokedAt == nil {
                Button("Sign Out", role: .destructive) {
                  Task { await model.revokeSession(id: session.id) }
                }
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
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
        if address.thisMacOnly {
          Text(
            "Open this address in a browser on this Mac. To use Aurelia in browsers on other devices, turn on home network access for this server."
          )
          .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
          Text(
            "Open this address in a browser on any device at home. The browser asks for a code; create one above."
          )
          .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
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

  private var serverName: String { model.profile?.name ?? "this server" }

  private var browserAddress: BrowserAddress? {
    guard let serverURL = model.profile?.baseURL else { return nil }
    let local = model.isLocalHost ? model.hostSnapshot.serverInfo : nil
    return BrowserAddress.resolve(
      serverURL: serverURL, lanAccessEnabled: local?.lanAccessEnabled, lanPort: local?.lanHttpsPort)
  }

  /// Every new device asks for a code when it connects, so this Mac makes one: another Mac, a
  /// Linux computer, an iPhone, iPad, Apple TV or a browser.
  private var macPairing: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Add a Device", systemImage: "plus.circle").font(.headline)
      PairingDirection(
        from: ("laptopcomputer", "This Mac shows the code"),
        to: ("appletv", "You type it on the new device"))
      PairingSteps(steps: [
        "Click Create Code below.",
        "Open Aurelia on the new device (Mac, Linux computer, iPhone, iPad, Apple TV or browser) and choose \(serverName).",
        "Type the code there. A code works once and for five minutes.",
      ])
      if let code = model.pairingCode {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          pairingCode(code, now: context.date)
        }
      }
      if model.profile?.user?.role == .owner {
        Button(model.pairingCode == nil ? "Create Code" : "Create a New Code") {
          Task { await model.generatePairingCode() }
        }
        .buttonStyle(AureliaPrimaryActionButtonStyle())
        .accessibilityIdentifier("pair-mac")
      } else {
        Text("Only the owner can add a device.").font(.caption).foregroundStyle(.secondary)
      }
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

/// Which side shows the pairing code and which side it is typed on, so nobody has to guess.
private struct PairingDirection: View {
  let from: (symbol: String, text: String)
  let to: (symbol: String, text: String)

  var body: some View {
    HStack(spacing: 10) {
      side(from)
      Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
      side(to)
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 10)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .combine)
  }

  private func side(_ entry: (symbol: String, text: String)) -> some View {
    Label(entry.text, systemImage: entry.symbol).font(.callout.weight(.medium))
  }
}

/// Numbered steps for pairing one kind of device.
private struct PairingSteps: View {
  let steps: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
          Text(step).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
      }
    }
  }
}
