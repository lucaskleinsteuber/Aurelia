import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ServerNetworkEditor: View {
  @EnvironmentObject private var model: AppModel
  let configuration: ServerConfigurationResponse
  let client: APIClient
  let nativeHostAvailable: Bool
  let reload: () -> Void
  @State private var draft: ServerPolicySettings
  @State private var networks: String
  @State private var confirmedDisconnect = false
  @State private var operation: HostOperationStatus?
  @State private var trialProfile: StoredServerProfile?
  @State private var working = false
  @State private var message: String?

  init(
    configuration: ServerConfigurationResponse, client: APIClient, nativeHostAvailable: Bool,
    reload: @escaping () -> Void
  ) {
    self.configuration = configuration
    self.client = client
    self.nativeHostAvailable = nativeHostAvailable
    self.reload = reload
    _draft = State(initialValue: configuration.stored)
    _networks = State(
      initialValue: (configuration.stored.allowedNetworks ?? []).joined(separator: "\n"))
  }
  var body: some View {
    GroupBox("Network") {
      VStack(alignment: .leading, spacing: 12) {
        LabeledContent("Active name", value: configuration.active.serverName)
        LabeledContent("Connected address", value: model.profile?.baseURL.absoluteString ?? "—")
        TextField("Server name", text: $draft.serverName)
        Toggle("Allow HTTPS access from LAN / private VPN", isOn: $draft.lanAccessEnabled)
          .disabled(!model.isLocalHost && configuration.active.lanAccessEnabled)
        Stepper("HTTPS port: \(draft.lanHttpsPort)", value: $draft.lanHttpsPort, in: 1024...65535)
        Toggle("Advertise with Bonjour", isOn: $draft.bonjourEnabled)
        Text("Allowed private networks (one CIDR per line, optional)").font(.caption)
        TextEditor(text: $networks).font(.system(.caption, design: .monospaced)).frame(height: 64)
        Text(
          "Local access is always retained. Public Internet addresses are blocked; no HTTP/TLS bypass is available."
        )
        .font(.caption).foregroundStyle(.secondary)
        if let profile = model.profile {
          Text("Pinned TLS public key: \(profile.publicKeyFingerprint)").font(.caption)
            .textSelection(.enabled)
        }
        if !draft.lanAccessEnabled && configuration.active.lanAccessEnabled {
          Toggle("I understand that remote devices will lose access", isOn: $confirmedDisconnect)
        }
        if let operation, let trialProfile {
          Text(
            "Trial started. Reconnect and confirm before \(operation.confirmBefore ?? "the 60-second deadline"). Otherwise the previous network settings return automatically."
          )
          .font(.caption).foregroundStyle(.orange)
          Button("Verify New Connection & Keep Settings") {
            perform {
              let trial = APIClient(profile: trialProfile)
              let info = try await trial.serverInfo()
              guard info.serverId == trialProfile.serverId else {
                throw APIClientError.invalidResponse
              }
              try await trial.confirmNetwork(id: operation.id)
              try model.acceptConfirmedNetwork(profile: trialProfile)
              self.operation = nil
              self.trialProfile = nil
              message = "Network settings confirmed."
              reload()
            }
          }.disabled(working)
        } else {
          Button("Try Network Settings (60-second rollback)") {
            perform {
              guard let profile = model.profile,
                var parts = URLComponents(url: profile.baseURL, resolvingAgainstBaseURL: false)
              else { throw APIClientError.invalidResponse }
              draft.allowedNetworks = networks.split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: .whitespaces)
              }.filter { !$0.isEmpty }
              let pending = try await client.trialNetwork(
                draft, confirmDisconnect: confirmedDisconnect)
              parts.scheme = draft.lanAccessEnabled ? "https" : "http"
              parts.port = draft.lanHttpsPort
              if !draft.lanAccessEnabled {
                parts.host = "127.0.0.1"
                parts.port = 43110
              }
              guard let address = parts.url else { throw APIClientError.invalidResponse }
              trialProfile = StoredServerProfile(
                serverId: profile.serverId, name: draft.serverName, baseURL: address,
                publicKeyFingerprint: profile.publicKeyFingerprint, token: profile.token,
                sessionId: profile.sessionId, expiresAt: profile.expiresAt, user: profile.user,
                locallyManaged: profile.locallyManaged)
              operation = pending
              message = nil
            }
          }.disabled(
            working || !nativeHostAvailable
              || (!draft.lanAccessEnabled && configuration.active.lanAccessEnabled
                && !confirmedDisconnect)
          )
        }
        if !nativeHostAvailable {
          Text(
            "This server has no native Mac host control channel. Network changes are unavailable here."
          ).font(.caption).foregroundStyle(.secondary)
        }
        if let message { Text(message).font(.caption).textSelection(.enabled) }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }
  }
  private func perform(_ action: @escaping @MainActor () async throws -> Void) {
    working = true
    Task {
      defer { working = false }
      do { try await action() } catch is CancellationError {} catch {
        message = error.localizedDescription
      }
    }
  }
}

struct ServerHostingEditor: View {
  @EnvironmentObject private var model: AppModel
  let client: APIClient
  let available: Bool
  @State private var settings = HostServiceSettings()
  @State private var permission = ""
  @State private var pending: HostServiceRequest?
  @State private var activeHosting: ServerHostingStatus?
  @State private var working = false
  @State private var message: String?
  var body: some View {
    GroupBox("Hosting") {
      VStack(alignment: .leading, spacing: 12) {
        if let activeHosting {
          LabeledContent(
            "Active host",
            value: activeHosting.backgroundEnabled
              ? "Independent background service" : "Tied to the open Aurelia app")
          if activeHosting.state == "awaitingPermission" {
            Text("Awaiting permission on the host Mac.").foregroundStyle(.orange)
          }
        }
        Picker("Operating mode", selection: $settings.backgroundEnabled) {
          Text("Only while Aurelia is running").tag(false)
          Text("Run in background").tag(true)
        }.accessibilityIdentifier("server-hosting-mode")
        Toggle("Start server at Mac login", isOn: $settings.startAtLogin).disabled(
          !settings.backgroundEnabled)
        Toggle("Prevent automatic idle sleep while hosting", isOn: $settings.preventIdleSleep)
        Text(
          "Background hosting is a user service, not a root service. It works after login while this Mac is awake; it cannot serve while the Mac is off or asleep with its lid closed."
        )
        .font(.caption).foregroundStyle(.secondary)
        if model.isLocalHost {
          LabeledContent("macOS permission", value: permission)
          if let pending {
            Label(
              "A trusted owner requested a hosting change.", systemImage: "exclamationmark.triangle"
            )
            Button("Review Requested Mode") { settings = pending.settings }
          }
          Button("Open Login Items Permissions") { BackgroundHostingController.openPermissions() }
        } else {
          Text(
            "Changing the hosting mode remotely creates a request. Open Aurelia on the host Mac to review it and grant any required macOS permission."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Button(model.isLocalHost ? "Apply Hosting Mode" : "Request Hosting Mode") {
            run {
              if !settings.backgroundEnabled { settings.startAtLogin = false }
              if model.isLocalHost {
                try await model.saveHostingSettings(settings)
                permission = BackgroundHostingController.permissionState
                pending = try HostServiceRequest.load()
                message =
                  settings.backgroundEnabled && !BackgroundHostingController.permitted
                  ? "Awaiting permission. The server is still tied to this app."
                  : "Hosting mode applied."
              } else {
                _ = try await client.authorizeHostingChange(settings)
                message =
                  "Request saved. Awaiting approval on the host Mac; the active mode has not changed."
              }
              activeHosting = try await client.serverHosting()
            }
          }
          Button("Restart Server") {
            run {
              _ = try await client.restartServer()
              message = "Restart requested. Reconnect after the host has restarted."
            }
          }
        }.disabled(working || !available)
        if let message { Text(message).font(.caption).textSelection(.enabled) }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }.task {
      if available {
        do {
          let active = try await client.serverHosting()
          activeHosting = active
          settings.backgroundEnabled = active.backgroundRequested
          settings.startAtLogin = active.startAtLogin
          settings.preventIdleSleep = active.preventIdleSleep
        } catch { message = error.localizedDescription }
      }
      if model.isLocalHost {
        settings = (try? HostServiceSettings.load()) ?? HostServiceSettings()
        pending = try? HostServiceRequest.load()
        permission = BackgroundHostingController.permissionState
      }
    }
  }
  private func run(_ action: @escaping @MainActor () async throws -> Void) {
    working = true
    Task {
      defer { working = false }
      do { try await action() } catch is CancellationError {} catch {
        message = error.localizedDescription
      }
    }
  }
}

struct ServerLibraryJobsEditor: View {
  @EnvironmentObject private var model: AppModel
  let configuration: ServerConfigurationResponse
  let client: APIClient
  let saved: (ServerConfigurationResponse) -> Void
  @State private var settings: ServerPolicySettings
  @State private var libraries: [LibrarySummary] = []
  @State private var jobs: ServerJobHistory?
  @State private var working = false
  @State private var message: String?
  init(
    configuration: ServerConfigurationResponse, client: APIClient,
    saved: @escaping (ServerConfigurationResponse) -> Void
  ) {
    self.configuration = configuration
    self.client = client
    self.saved = saved
    _settings = State(initialValue: configuration.stored)
  }
  var body: some View {
    GroupBox("Library & Jobs") {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Monitor storage locations", isOn: $settings.monitoringEnabled)
        Stepper(
          "Reconciliation interval: \(settings.reconciliationMinutes) minutes",
          value: $settings.reconciliationMinutes, in: 15...10080, step: 15)
        HStack {
          Stepper(
            "Maintenance starts: \(settings.maintenanceStartHour):00",
            value: $settings.maintenanceStartHour, in: 0...23)
          Stepper(
            "Ends: \(settings.maintenanceEndHour):00", value: $settings.maintenanceEndHour,
            in: 1...24)
        }
        Stepper(
          "Maximum jobs per queue: \(settings.jobQueueLimit)", value: $settings.jobQueueLimit,
          in: 10...10000, step: 10)
        Text(
          "Maintenance hours use the host's local time. Manual scans remain available. Media is read directly; Aurelia does not transcode or copy videos."
        ).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("Save Job Settings") { run { saved(try await client.saveServerSettings(settings)) } }
          .disabled(working || settings == configuration.stored)
        Divider()
        ForEach(libraries) { library in
          HStack {
            Text(library.name)
            Spacer()
            Button(library.monitoringEnabled == true ? "Disable Monitoring" : "Enable Monitoring") {
              run {
                _ = try await client.updateLibraryMonitoring(
                  id: library.id, enabled: library.monitoringEnabled != true)
                try await refresh()
              }
            }
            Button("Scan") {
              run {
                _ = try await client.startLibraryScan(id: library.id)
                try await refresh()
              }
            }
          }
        }
        Button("Manage Storage Locations…") { model.showMediaManager() }
        if let jobs {
          ForEach(jobs.scans.prefix(12)) { scan in
            HStack {
              Text("Scan · \(scan.state.rawValue) · \(scan.filesDiscovered) files").font(.caption)
              Spacer()
              if [.queued, .running, .waitingForStorage].contains(scan.state) {
                Button("Cancel") {
                  run {
                    try await client.cancelScan(id: scan.id)
                    try await refresh()
                  }
                }
              } else if [.failed, .interrupted, .cancelled].contains(scan.state) {
                Button("Retry") {
                  run {
                    _ = try await client.startLibraryScan(id: scan.libraryId)
                    try await refresh()
                  }
                }
              }
            }
          }
          ForEach(jobs.metadata.prefix(12)) { job in
            HStack {
              Text("Metadata · \(job.state.rawValue) · \(job.itemsProcessed)/\(job.itemsTotal)")
                .font(.caption)
              Spacer()
              if [.queued, .running].contains(job.state) {
                Button("Cancel") {
                  run {
                    try await client.cancelMetadataJob(id: job.id)
                    try await refresh()
                  }
                }
              } else if [.failed, .interrupted, .cancelled].contains(job.state) {
                Button("Retry") {
                  run {
                    try await client.retryMetadataJob(id: job.id)
                    try await refresh()
                  }
                }
              }
            }
          }
        }
        Button("Refresh Queue") { run { try await refresh() } }.disabled(working)
        if let message { Text(message).font(.caption).textSelection(.enabled) }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(10).disabled(working)
    }.task { do { try await refresh() } catch { message = error.localizedDescription } }
  }
  private func refresh() async throws {
    async let roots = client.libraries()
    async let history = client.serverJobs()
    (libraries, jobs) = try await (roots, history)
  }
  private func run(_ action: @escaping @MainActor () async throws -> Void) {
    working = true
    Task {
      defer { working = false }
      do {
        try await action()
        message = nil
      } catch is CancellationError {} catch { message = error.localizedDescription }
    }
  }
}

struct ServerBackupsEditor: View {
  let configuration: ServerConfigurationResponse
  let client: APIClient
  let nativeHostAvailable: Bool
  let saved: (ServerConfigurationResponse) -> Void
  @State private var settings: ServerPolicySettings
  @State private var backups: [ServerBackupSummary] = []
  @State private var passphrase = ""
  @State private var confirmation = ""
  @State private var prepared: PreparedServerRestore?
  @State private var restoreConfirmed = false
  @State private var acceptDifferentIdentity = false
  @State private var working = false
  @State private var message: String?
  init(
    configuration: ServerConfigurationResponse, client: APIClient, nativeHostAvailable: Bool,
    saved: @escaping (ServerConfigurationResponse) -> Void
  ) {
    self.configuration = configuration
    self.client = client
    self.nativeHostAvailable = nativeHostAvailable
    self.saved = saved
    _settings = State(initialValue: configuration.stored)
  }
  var body: some View {
    GroupBox("Backups") {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Automatic database backups", isOn: $settings.automaticBackupsEnabled)
        Stepper(
          "Interval: \(settings.backupIntervalHours) hours", value: $settings.backupIntervalHours,
          in: 1...168)
        Stepper(
          "Keep \(settings.dailyBackupsRetained) daily backups",
          value: $settings.dailyBackupsRetained, in: 1...30)
        Stepper(
          "Keep \(settings.weeklyBackupsRetained) weekly backups",
          value: $settings.weeklyBackupsRetained, in: 1...12)
        Button("Save Backup Settings") {
          run { saved(try await client.saveServerSettings(settings)) }
        }.disabled(settings == configuration.stored)
        HStack {
          Button("Backup Now") {
            run {
              try await client.createDatabaseBackup()
              backups = try await client.serverBackups()
              message = "Database backup created and verified."
            }
          }
          Button("Refresh Backups") { run { backups = try await client.serverBackups() } }
        }
        if let latest = backups.first {
          Text("Last verified backup: \(latest.createdAt)").font(.caption).foregroundStyle(
            .secondary)
        }
        ForEach(backups.prefix(8)) { backup in
          HStack {
            Text(
              "\(backup.kind) · \(backup.createdAt) · \(ByteCountFormatter.string(fromByteCount: backup.bytes, countStyle: .file))"
            ).font(.caption)
            Spacer()
            Button("Verify") {
              run {
                try await client.verifyDatabaseBackup(name: backup.name)
                message = "Backup integrity and schema verified."
              }
            }
          }
        }
        Divider()
        Text("Encrypted Full Server Backup").font(.headline)
        Text(
          "Includes the database, configuration, TLS identity, server secrets, and your imported images and crops. Videos and downloadable artwork are excluded. Keep the passphrase safely; it cannot be recovered."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        SecureField("Backup passphrase (at least 12 characters)", text: $passphrase)
        SecureField("Repeat passphrase for export", text: $confirmation)
        Button("Export Encrypted Backup…") {
          run {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Aurelia-Server.aureliabackup"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let file = panel.url else { return }
            try await client.exportEncryptedServerBackup(passphrase: passphrase, to: file)
            passphrase = ""
            confirmation = ""
            message = "Encrypted backup saved. No media files were copied."
          }
        }.disabled(passphrase.count < 12 || passphrase != confirmation)
        Toggle(
          "Restoring signs out every device; I will sign in and review trust again",
          isOn: $restoreConfirmed)
        Toggle(
          "Allow a backup from another server (changes server identity and trust)",
          isOn: $acceptDifferentIdentity)
        Button("Choose Backup & Verify Restore…") {
          run {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let file = panel.url else { return }
            prepared = try await client.prepareServerRestore(
              from: file, passphrase: passphrase, acceptDifferentIdentity: acceptDifferentIdentity)
            passphrase = ""
            confirmation = ""
            message = "Backup verified in a private staging area. Active data has not changed."
          }
        }.disabled(passphrase.count < 12 || !restoreConfirmed || !nativeHostAvailable)
        if let prepared {
          Button("Restore Verified Backup & Restart", role: .destructive) {
            run {
              try await client.applyServerRestore(id: prepared.id)
              self.prepared = nil
              message = "Restore requested. Reconnect and sign in again after the host restarts."
            }
          }.disabled(!restoreConfirmed)
        }
        if let message { Text(message).font(.caption).textSelection(.enabled) }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(10).disabled(working)
      if working { ProgressView("Working on the server…") }
    }.task {
      do { backups = try await client.serverBackups() } catch {
        message = error.localizedDescription
      }
    }
  }
  private func run(_ action: @escaping @MainActor () async throws -> Void) {
    working = true
    Task {
      defer { working = false }
      do { try await action() } catch is CancellationError {} catch {
        message = error.localizedDescription
      }
    }
  }
}

struct ServerDiagnosticsEditor: View {
  let configuration: ServerConfigurationResponse
  let client: APIClient
  let saved: (ServerConfigurationResponse) -> Void
  @State private var settings: ServerPolicySettings
  @State private var events: [ServerDiagnosticEvent] = []
  @State private var working = false
  @State private var message: String?
  init(
    configuration: ServerConfigurationResponse, client: APIClient,
    saved: @escaping (ServerConfigurationResponse) -> Void
  ) {
    self.configuration = configuration
    self.client = client
    self.saved = saved
    _settings = State(initialValue: configuration.stored)
  }
  var body: some View {
    GroupBox("Diagnostics") {
      VStack(alignment: .leading, spacing: 12) {
        Stepper(
          "Retain events for \(settings.eventRetentionDays) days",
          value: $settings.eventRetentionDays, in: 1...90)
        Stepper(
          "Maximum events: \(settings.maximumEvents)", value: $settings.maximumEvents,
          in: 100...10000, step: 100)
        Button("Save Diagnostic Settings") {
          run { saved(try await client.saveServerSettings(settings)) }
        }.disabled(settings == configuration.stored)
        HStack {
          Button("Refresh Events") { run { events = try await client.serverDiagnostics() } }
          Button("Export Sanitized Diagnostics…") {
            run {
              let data = try await client.serverDiagnosticsExport()
              let panel = NSSavePanel()
              panel.nameFieldStringValue = "Aurelia-Diagnostics.json"
              guard panel.runModal() == .OK, let file = panel.url else { return }
              let access = file.startAccessingSecurityScopedResource()
              defer { if access { file.stopAccessingSecurityScopedResource() } }
              try data.write(to: file, options: .atomic)
              message = "Sanitized diagnostics saved."
            }
          }
        }
        Text(
          "The export contains bounded event codes and non-secret limits, not passwords, tokens, private keys, media paths or request bodies."
        )
        .font(.caption).foregroundStyle(.secondary)
        ForEach(Array(events.prefix(20).enumerated()), id: \.offset) { _, event in
          Text("\(event.at) · \(event.severity) · \(event.code)").font(.caption).textSelection(
            .enabled)
        }
        if let message { Text(message).font(.caption).textSelection(.enabled) }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(10).disabled(working)
    }.task {
      do { events = try await client.serverDiagnostics() } catch {
        message = error.localizedDescription
      }
    }
  }
  private func run(_ action: @escaping @MainActor () async throws -> Void) {
    working = true
    Task {
      defer { working = false }
      do { try await action() } catch is CancellationError {} catch {
        message = error.localizedDescription
      }
    }
  }
}
