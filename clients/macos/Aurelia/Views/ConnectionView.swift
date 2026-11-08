import SwiftUI

struct ConnectionView: View {
  @EnvironmentObject private var model: AppModel
  @StateObject private var browser = BonjourBrowser()
  @State private var manualAddress = ""
  @State private var fingerprintMatches = false
  @State private var pairingCode = ""
  @State private var showsAdvancedConnection = false

  var body: some View {
    ScrollView {
      VStack(spacing: 28) {
        Spacer(minLength: 30)
        Image(systemName: "house.lodge.fill")
          .font(.system(size: 54, weight: .medium))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.white)

        VStack(spacing: 9) {
          Text("Connect to Aurelia")
            .font(AureliaDesign.pageTitle)
          Text("Find your server, verify it once, and keep your library private.")
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }

        if let inspected = model.inspectedServer {
          verificationCard(inspected)
        } else {
          discoveryCard
        }

        if let error = model.errorMessage {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.callout)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("connection-error")
        }
        Spacer(minLength: 30)
      }
      .frame(maxWidth: 620)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 32)
    }
    .onAppear { browser.start() }
    .onDisappear { browser.stop() }
    .background(AureliaBackdrop())
  }

  private var discoveryCard: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Servers Nearby")
        .font(.headline)

      if browser.servers.isEmpty {
        HStack(spacing: 12) {
          ProgressView()
            .controlSize(.small)
          Text("Looking on your local network…")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
      } else {
        ForEach(browser.servers) { server in
          Button {
            Task { await model.inspect(discovered: server) }
          } label: {
            HStack(spacing: 14) {
              Image(systemName: "externaldrive.connected.to.line.below")
                .font(.title3)
                .frame(width: 28)
              VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                  .font(.headline)
                Text(server.baseURL.host ?? "Local network")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("discovered-server-\(server.id)")
        }
      }

      Divider()

      Button {
        Task { await model.selectHostMode() }
      } label: {
        HStack(spacing: 12) {
          Image(systemName: "macstudio.fill")
            .font(.title3)
            .frame(width: 28)
          VStack(alignment: .leading, spacing: 2) {
            Text("Set Up a Server on This Mac")
              .font(.headline)
            Text("Aurelia will start it automatically whenever the app opens.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Image(systemName: "chevron.right")
            .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .frame(minHeight: AureliaDesign.minimumControlSize)
      .accessibilityIdentifier("connection-set-up-this-mac")

      Divider()

      Button {
        showsAdvancedConnection.toggle()
      } label: {
        HStack {
          Text("Advanced")
          Spacer()
          Image(systemName: "chevron.right")
            .rotationEffect(.degrees(showsAdvancedConnection ? 90 : 0))
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("connection-advanced")

      if showsAdvancedConnection {
        VStack(alignment: .leading, spacing: 8) {
          Text("Manual Address").font(.subheadline.weight(.semibold))
          HStack(spacing: 10) {
            TextField("192.168.1.20 or aurelia.local", text: $manualAddress)
              .textFieldStyle(.roundedBorder)
              .onSubmit { connectManually() }
              .accessibilityIdentifier("manual-server-address")
            Button("Connect") { connectManually() }
              .buttonStyle(AureliaPrimaryActionButtonStyle())
              .disabled(
                manualAddress.trimmingCharacters(in: .whitespaces).isEmpty
                  || model.isWorking
              )
              .accessibilityIdentifier("connect-manually")
          }
        }
        .padding(.top, 8)
      }
    }
    .padding(22)
    .background(
      AureliaDesign.surface,
      in: RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: AureliaDesign.cardRadius)
        .stroke(.white.opacity(0.08), lineWidth: 1)
    }
  }

  private func verificationCard(_ inspected: InspectedServer) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Button {
          fingerprintMatches = false
          pairingCode = ""
          model.cancelInspection()
        } label: {
          Label("Back", systemImage: "chevron.left")
        }
        .buttonStyle(.plain)
        Spacer()
        Label("Encrypted", systemImage: "lock.fill")
          .font(.caption.weight(.medium))
          .foregroundStyle(.green)
      }

      VStack(alignment: .leading, spacing: 5) {
        Text(inspected.info.name)
          .font(.title2.bold())
        Text(inspected.baseURL.absoluteString)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("1. Check the Verification Fingerprint")
          .font(.subheadline.weight(.semibold))
        Text(inspected.displayFingerprint)
          .font(.system(.title2, design: .monospaced, weight: .semibold))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 10)
          .padding(.horizontal, 14)
          .background(
            .white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
          )
          .accessibilityIdentifier("server-fingerprint")
        Text(
          "It must match the server's fingerprint: Aurelia Settings on a Mac server, or aurelia status on a Linux server."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Toggle("The fingerprints match", isOn: $fingerprintMatches)
          .accessibilityIdentifier("fingerprint-matches")
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("2. Enter a Pairing Code")
          .font(.subheadline.weight(.semibold))
        TextField("8-digit pairing code", text: $pairingCode)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("pairing-code")
        Text(
          "The server shows it, you type it here. On the Mac that runs the server, open Settings › Profiles and Devices › Another Mac or Linux Computer and click Create Code; on a Linux server, run aurelia pair."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Button {
        Task { _ = await model.pair(code: pairingCode) }
      } label: {
        if model.isWorking {
          ProgressView()
            .controlSize(.small)
        } else {
          Text("Pair This Mac")
            .frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(AureliaPrimaryActionButtonStyle())
      .disabled(
        !fingerprintMatches || pairingCode.filter(\.isNumber).count != 8
          || model.isWorking
      )
      .accessibilityIdentifier("pair-this-mac")
    }
    .padding(22)
    .background(
      AureliaDesign.surface,
      in: RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous)
        .stroke(AureliaDesign.hairline, lineWidth: 1)
    }
  }

  private func connectManually() {
    Task { await model.inspect(address: manualAddress) }
  }
}
