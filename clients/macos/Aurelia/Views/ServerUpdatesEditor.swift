import SwiftUI

/// The installed and the newest version of a Linux server installed from the package, with one
/// click to look for or install an update. The server's own root-run updater does the work.
struct ServerUpdatesEditor: View {
  @EnvironmentObject private var model: AppModel
  let client: APIClient
  @State private var status: ServerUpdateStatus?
  @State private var loaded = false
  @State private var working = false
  @State private var confirmingInstall = false
  @State private var message: String?

  var body: some View {
    Group {
      if let status, status.available {
        AureliaSettingsSection(
          "Server Updates",
          symbol: "arrow.down.circle",
          description:
            "Aurelia Server looks for a new version once a day. Installing waits for you."
        ) {
          VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Installed", value: status.installed)
            if let newest = status.newest, status.updateAvailable {
              LabeledContent("Available", value: newest)
            }
            Label(summary(status), systemImage: symbol(status))
              .foregroundStyle(status.state == "failed" ? .orange : .secondary)
              .accessibilityIdentifier("server-update-state")
            if status.state == "failed", let failure = status.message {
              Text(failure).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
              Button("Check Now") { run { try await client.checkServerUpdates() } }
                .disabled(busy(status))
                .accessibilityIdentifier("server-update-check")
              if status.updateAvailable {
                Button("Install Update…") { confirmingInstall = true }
                  .buttonStyle(AureliaPrimaryActionButtonStyle())
                  .disabled(busy(status))
                  .accessibilityIdentifier("server-update-install")
              }
              if working || busy(status) { ProgressView().controlSize(.small) }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("server-updates")
        .confirmationDialog(
          "Install Aurelia Server \(status.newest ?? "")?",
          isPresented: $confirmingInstall, titleVisibility: .visible
        ) {
          Button("Install Update") { run { try await client.installServerUpdate() } }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text(
            "The server stops for about a minute while it updates; playback pauses meanwhile. Accounts, library and settings stay."
          )
        }
      } else {
        AureliaSettingsSection("Server Updates", symbol: "arrow.down.circle") {
          Text(
            message
              ?? (status == nil && !loaded
                ? "Checking server update support…"
                : "This server is updated outside this page. A server hosted by this Mac is updated with the Mac app.")
          )
          .foregroundStyle(.secondary)
        }
      }
    }
    .task(id: model.administrationGeneration) { await load() }
    .task(id: busy(status)) {
      // While the server checks or installs, its answer is picked up without another click. An
      // installation restarts the server, so failed reads are simply tried again.
      guard busy(status) else { return }
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        await load(quietly: true)
        if !busy(status) { return }
      }
    }
  }

  private func busy(_ status: ServerUpdateStatus?) -> Bool {
    status?.state == "checking" || status?.state == "installing"
  }

  private func summary(_ status: ServerUpdateStatus) -> String {
    switch status.state {
    case "checking": return "Looking for a new version…"
    case "installing":
      return "Installing \(status.newest ?? "the update")… Aurelia reconnects by itself."
    case "failed": return "The last update did not work."
    default:
      if status.updateAvailable { return "A new version is ready to install." }
      guard let checked = status.checkedDate else { return "Not checked yet." }
      return "Up to date · checked \(checked.formatted(.relative(presentation: .named)))"
    }
  }

  private func symbol(_ status: ServerUpdateStatus) -> String {
    switch status.state {
    case "failed": "exclamationmark.triangle"
    case "checking", "installing": "arrow.triangle.2.circlepath"
    default: status.updateAvailable ? "arrow.down.circle.fill" : "checkmark.circle"
    }
  }

  private func load(quietly: Bool = false) async {
    defer { loaded = true }
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    do {
      status = try await model.currentAdministration {
        try await scope.request { try await client.serverUpdates() }
      }
      message = nil
    } catch let failure as APIClientError where failure.httpStatus == 404 {
      // Servers before 1.8.7 cannot update from the app.
      status = nil
    } catch {
      // While an update restarts the server, it does not answer for a moment.
      if !quietly { message = scope.message(for: error) }
    }
  }

  private func run(_ action: @escaping @MainActor () async throws -> ServerUpdateStatus) {
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    working = true
    message = nil
    Task {
      defer { working = false }
      do {
        status = try await model.currentAdministration { try await scope.request(action) }
      } catch {
        message = scope.message(for: error)
      }
    }
  }
}
