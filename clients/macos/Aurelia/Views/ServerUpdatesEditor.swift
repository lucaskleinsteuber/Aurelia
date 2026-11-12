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
  /// A check or an installation this Mac started, followed until it has an answer.
  @State private var operation: ServerUpdateOperation?
  /// The answer, which stays until the next check or installation.
  @State private var result: ServerUpdateResult?

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
            if let operation {
              VStack(alignment: .leading, spacing: 6) {
                ProgressView().progressViewStyle(.linear)
                Text(operation.progressText(status: status, reconnecting: operation.reconnecting))
                  .font(.callout).foregroundStyle(.secondary)
              }
              .frame(maxWidth: 520, alignment: .leading)
              .accessibilityIdentifier("server-update-progress")
            } else if let result {
              Label(result.text, systemImage: result.symbol)
                .foregroundStyle(result.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.green))
                .accessibilityIdentifier("server-update-result")
            } else {
              Label(summary(status), systemImage: symbol(status))
                .foregroundStyle(status.state == "failed" ? .orange : .secondary)
                .accessibilityIdentifier("server-update-state")
            }
            if operation == nil, status.state == "failed", let failure = status.message {
              Text(failure).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
              Button("Check Now") { start(.check) }
                .disabled(operation != nil || busy(status) || working)
                .accessibilityIdentifier("server-update-check")
              if status.updateAvailable {
                Button("Install Update…") { confirmingInstall = true }
                  .buttonStyle(AureliaPrimaryActionButtonStyle())
                  .disabled(operation != nil || busy(status) || working)
                  .accessibilityIdentifier("server-update-install")
              }
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
          Button("Install Update") { start(.install) }
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
    .task(id: model.administrationGeneration) {
      // A check or an installation that is running keeps its own reading below.
      if operation == nil { await load() }
    }
    .task(id: operation?.id) { await follow() }
    .task(id: operation == nil && busy(status)) {
      // A check the server started itself (once a day) is picked up without a click.
      guard operation == nil, busy(status) else { return }
      while !Task.isCancelled, operation == nil, busy(status) {
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        await load(quietly: true)
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
      if !quietly { message = scope.message(for: error) }
    }
  }

  /// Asks the server to check or install, then follows it until there is an answer.
  private func start(_ kind: ServerUpdateOperation.Kind) {
    guard operation == nil, let current = status else { return }
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    working = true
    message = nil
    result = nil
    Task {
      defer { working = false }
      do {
        let answer = try await model.currentAdministration {
          try await scope.request {
            kind == .install ? try await client.installServerUpdate() : try await client.checkServerUpdates()
          }
        }
        status = answer
        operation = ServerUpdateOperation(kind: kind, before: current)
      } catch {
        message = scope.message(for: error)
      }
    }
  }

  /// Reads the status every few seconds until the check or installation has an answer. An
  /// installation restarts the server, so a server out of reach for a while is expected then.
  private func follow() async {
    guard let running = operation else { return }
    var current = running
    while !Task.isCancelled {
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      guard operation?.id == running.id else { return }
      do {
        let read = try await client.serverUpdates()
        status = read
        current.reconnecting = false
        if let answer = current.outcome(of: read) {
          result = answer
          operation = nil
          return
        }
      } catch {
        current.reconnecting = true
        // After the restart, management may need unlocking again; the server's public
        // information still tells which version now runs.
        if current.kind == .install, let info = try? await client.serverInfo(),
          let answer = current.outcome(serverVersion: info.version)
        {
          result = answer
          operation = nil
          await load(quietly: true)
          return
        }
        if current.timedOut {
          result = current.kind == .install
            ? .notFinished : .unanswered
          operation = nil
          return
        }
      }
      operation = current
    }
  }
}

/// A check or an installation of a server update started from this Mac.
struct ServerUpdateOperation: Identifiable, Equatable {
  enum Kind: Equatable { case check, install }
  let id = UUID()
  let kind: Kind
  let installedBefore: String
  let checkedBefore: String?
  let startedAt: Date
  var reconnecting = false
  /// How long an answer may take: installing downloads and restarts the server.
  var limit: TimeInterval { kind == .install ? 600 : 120 }

  init(kind: Kind, before: ServerUpdateStatus, startedAt: Date = Date()) {
    self.kind = kind
    installedBefore = before.installed
    checkedBefore = before.checkedAt
    self.startedAt = startedAt
  }

  func timedOut(at now: Date) -> Bool { now.timeIntervalSince(startedAt) > limit }
  var timedOut: Bool { timedOut(at: Date()) }

  func progressText(status: ServerUpdateStatus, reconnecting: Bool) -> String {
    switch kind {
    case .check: return "Looking for a new version…"
    case .install:
      if reconnecting {
        return "Aurelia Server is restarting with the new version… This takes about a minute."
      }
      return "Downloading and installing \(status.newest ?? "the update")… The server restarts by itself."
    }
  }

  /// An installation that the public server information already shows as done.
  func outcome(serverVersion: String) -> ServerUpdateResult? {
    guard kind == .install else { return nil }
    let before = installedBefore.split(separator: " ").first.map(String.init) ?? installedBefore
    return serverVersion != before ? .installed(serverVersion) : nil
  }

  /// The answer once the server has one, or nil while it still works on it.
  func outcome(of status: ServerUpdateStatus, now: Date = Date()) -> ServerUpdateResult? {
    if status.state == "failed" { return .failed(status.message) }
    switch kind {
    case .install:
      if status.installed != installedBefore { return .installed(status.installed) }
      if status.state == "idle", now.timeIntervalSince(startedAt) > 20 { return .notInstalled(status.installed) }
      return timedOut(at: now) ? .notFinished : nil
    case .check:
      guard status.state == "idle" else { return timedOut(at: now) ? .unanswered : nil }
      if let newest = status.newest, status.updateAvailable { return .available(newest) }
      return .upToDate(status.installed)
    }
  }
}

/// What a check or installation came to, shown until the next one.
enum ServerUpdateResult: Equatable {
  case installed(String)
  case notInstalled(String)
  case notFinished
  case available(String)
  case upToDate(String)
  case unanswered
  case failed(String?)

  var text: String {
    switch self {
    case .installed(let version): "Done. Aurelia Server \(version) is installed and running."
    case .notInstalled(let version): "The update was not installed. Aurelia Server stays on \(version)."
    case .notFinished: "The update did not finish in ten minutes. Check the server, then try again."
    case .available(let version): "Aurelia Server \(version) is ready to install."
    case .upToDate(let version): "No new version found. Aurelia Server \(version) is up to date."
    case .unanswered: "The server did not answer the check. Try again later."
    case .failed(let reason): reason ?? "The update did not work. Aurelia Server keeps its previous version."
    }
  }

  var symbol: String {
    switch self {
    case .installed, .upToDate: "checkmark.circle.fill"
    case .available: "arrow.down.circle.fill"
    default: "exclamationmark.triangle.fill"
    }
  }

  var isProblem: Bool {
    switch self {
    case .installed, .upToDate, .available: false
    default: true
    }
  }
}
