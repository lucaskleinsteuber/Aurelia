import SwiftUI

struct ConnectionView: View {
  @EnvironmentObject private var model: AppModel
  @StateObject private var browser = BonjourBrowser()
  @State private var manualAddress = ""
  @State private var fingerprintMatches = false
  @State private var pairingCode = ""

  var body: some View {
    ScrollView {
      VStack(spacing: 28) {
        Spacer(minLength: 30)
        Image(systemName: "house.lodge.fill")
          .font(.system(size: 54, weight: .medium))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.white)

        VStack(spacing: 9) {
          Text("Connect to Aurelia Home")
            .font(.system(size: 32, weight: .bold))
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

      Text("Manual Address")
        .font(.headline)
      HStack(spacing: 10) {
        TextField("192.168.1.20 or aurelia-home.local", text: $manualAddress)
          .textFieldStyle(.roundedBorder)
          .onSubmit { connectManually() }
          .accessibilityIdentifier("manual-server-address")
        Button("Connect") { connectManually() }
          .buttonStyle(.borderedProminent)
          .disabled(
            manualAddress.trimmingCharacters(in: .whitespaces).isEmpty
              || model.isWorking
          )
          .accessibilityIdentifier("connect-manually")
      }
    }
    .padding(22)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
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
        Text("Verification Fingerprint")
          .font(.subheadline.weight(.semibold))
        Text(inspected.displayFingerprint)
          .font(.system(.title3, design: .monospaced, weight: .semibold))
          .textSelection(.enabled)
          .accessibilityIdentifier("server-fingerprint")
        Text(
          "Compare this with the fingerprint printed by the server. This protects you from connecting to an imitation server."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Toggle("The fingerprints match", isOn: $fingerprintMatches)
        .accessibilityIdentifier("fingerprint-matches")

      TextField("8-digit pairing code", text: $pairingCode)
        .textFieldStyle(.roundedBorder)
        .disabled(!fingerprintMatches)
        .accessibilityIdentifier("pairing-code")

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
      .buttonStyle(.borderedProminent)
      .disabled(
        !fingerprintMatches || pairingCode.filter(\.isNumber).count != 8
          || model.isWorking
      )
      .accessibilityIdentifier("pair-this-mac")
    }
    .padding(22)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
  }

  private func connectManually() {
    Task { await model.inspect(address: manualAddress) }
  }
}
