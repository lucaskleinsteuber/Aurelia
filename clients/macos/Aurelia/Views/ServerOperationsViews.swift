import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct ServerAdministrationScope {
  let model: AppModel
  let generation: UUID

  func check() throws {
    guard model.isCurrentAdministration(generation) else { throw CancellationError() }
  }

  func request<Value: Sendable>(_ work: @MainActor () async throws -> Value) async throws -> Value {
    try check()
    let result = try await work()
    try check()
    return result
  }

  func message(for error: Error) -> String? {
    guard !(error is CancellationError), model.isCurrentAdministration(generation) else {
      return nil
    }
    if let failure = error as? APIClientError,
      failure.isManagementLocked || failure == .serverIdentityMismatch
    {
      model.handleAdministrationFailure(error, generation: generation)
      return nil
    }
    return error.localizedDescription
  }
}

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
  @State private var actionTask: Task<Void, Never>?
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
          Text(
            "The trial restarts the server and ends its in-memory sessions. Confirm your Profile PIN and Server Password on the new connection to establish a new management window."
          )
          .font(.caption).foregroundStyle(.secondary)
          Button("Verify New Connection & Keep Settings") {
            perform { scope in
              var abandonedProfile: APIClient?
              var adopted = false
              defer {
                if !adopted, let abandonedProfile {
                  Task { try? await abandonedProfile.endProfileSession() }
                }
              }
              let trial = APIClient(profile: trialProfile)
              let info = try await scope.request { try await trial.serverInfo() }
              guard info.serverId == trialProfile.serverId else {
                throw APIClientError.serverIdentityMismatch
              }
              guard let originalDevice = model.deviceConnection, let user = model.profile?.user
              else { throw APIClientError.invalidResponse }
              let paired = originalDevice.changingAddress(
                trialProfile.baseURL, name: trialProfile.name)
              try scope.check()
              let pin = try AdministrationPasswordPrompt.viewingPIN(name: user.username)
              let authentication = try await scope.request {
                try await APIClient(profile: paired).unlockProfile(id: user.id, pin: pin)
              }
              guard authentication.user.id == user.id else { throw APIClientError.invalidResponse }
              let fresh = StoredServerProfile(
                serverId: paired.serverId, name: paired.name, baseURL: paired.baseURL,
                publicKeyFingerprint: paired.publicKeyFingerprint, token: authentication.token,
                sessionId: authentication.sessionId, expiresAt: authentication.expiresAt,
                user: authentication.user,
                locallyManaged: paired.locallyManaged, viewingSession: true)
              abandonedProfile = APIClient(profile: fresh)
              try scope.check()
              let password = try AdministrationPasswordPrompt.confirm(serverName: paired.name)
              let expiry = try await scope.request {
                try await APIClient(profile: fresh).unlockManagement(password: password)
              }
              try await scope.request {
                try await APIClient(profile: fresh).confirmNetwork(id: operation.id)
              }
              try scope.check()
              // Adopting the newly confirmed session intentionally retires the old scope.
              try model.acceptConfirmedNetwork(
                profile: fresh, device: paired, managementExpiry: expiry)
              adopted = true
              self.operation = nil
              self.trialProfile = nil
              message = "Network settings confirmed."
              reload()
            }
          }.disabled(working)
        } else {
          Button("Try Network Settings (60-second rollback)") {
            perform { scope in
              guard let profile = model.profile,
                var parts = URLComponents(url: profile.baseURL, resolvingAgainstBaseURL: false)
              else { throw APIClientError.invalidResponse }
              draft.allowedNetworks = networks.split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: .whitespaces)
              }.filter { !$0.isEmpty }
              let pending = try await scope.request {
                try await client.trialNetwork(draft, confirmDisconnect: confirmedDisconnect)
              }
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
                locallyManaged: profile.locallyManaged, viewingSession: profile.viewingSession)
              operation = pending
              model.beginNetworkConfirmation(until: pending.confirmBefore)
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
    }.onDisappear { actionTask?.cancel() }
  }
  private func perform(
    _ action: @escaping @MainActor (ServerAdministrationScope) async throws -> Void
  ) {
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    working = true
    actionTask = Task {
      defer {
        working = false
        actionTask = nil
      }
      do {
        try await model.currentAdministration {
          try scope.check()
          try await action(scope)
        }
      } catch { if let failure = scope.message(for: error) { message = failure } }
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
  @State private var actionTask: Task<Void, Never>?
  @State private var message: String?
  var body: some View {
    AureliaSettingsSection(
      "When the Server Runs",
      symbol: "power",
      description: "The server can't be reached while this Mac is asleep or turned off."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Picker("Run the server", selection: $settings.backgroundEnabled) {
          Text("Only while the Aurelia app is open").tag(false)
          Text("Also when the Aurelia app is closed").tag(true)
        }
        .pickerStyle(.radioGroup)
        .accessibilityIdentifier("server-hosting-mode")
        Divider()
        ServerSwitchRow("Start automatically when you log in", isOn: $settings.startAtLogin)
          .disabled(!settings.backgroundEnabled)
        ServerSwitchRow(
          "Keep this Mac awake while the server runs", isOn: $settings.preventIdleSleep)
        if let activeHosting, activeHosting.state == "awaitingPermission" {
          Text("Waiting for permission on the server Mac.").foregroundStyle(.orange)
        }
        if model.isLocalHost {
          if settings.backgroundEnabled, !BackgroundHostingController.permitted {
            HStack {
              Label(
                "macOS must allow Aurelia to run in the background (\(permission)).",
                systemImage: "exclamationmark.triangle"
              )
              .font(.caption).foregroundStyle(.orange)
              Spacer()
              Button("Open Login Items Settings") { BackgroundHostingController.openPermissions() }
            }
          }
          if let pending {
            Label(
              "A trusted owner requested a hosting change.", systemImage: "exclamationmark.triangle"
            )
            Button("Review Requested Mode") { settings = pending.settings }
          }
        } else {
          Text(
            "Changes made from another device are sent as a request. Open Aurelia on the server Mac to approve it."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          if let activeHosting {
            Text(
              activeHosting.backgroundEnabled
                ? "Currently runs in the background." : "Currently runs while the app is open."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button(model.isLocalHost ? "Apply" : "Request Change") {
            run { scope in
              if !settings.backgroundEnabled { settings.startAtLogin = false }
              if model.isLocalHost {
                try await scope.request { try await model.saveHostingSettings(settings) }
                permission = BackgroundHostingController.permissionState
                pending = try HostServiceRequest.load()
                message =
                  settings.backgroundEnabled && !BackgroundHostingController.permitted
                  ? "Waiting for macOS permission. Until then the server runs while the app is open."
                  : "Saved."
              } else {
                _ = try await scope.request { try await client.authorizeHostingChange(settings) }
                message =
                  "Request sent. Approve it in Aurelia on the server Mac; nothing has changed yet."
              }
              activeHosting = try await scope.request { try await client.serverHosting() }
            }
          }
          .accessibilityIdentifier("server-hosting-apply")
        }.disabled(working || !available)
        if let message { Text(message).font(.caption).textSelection(.enabled) }
      }
      .toggleStyle(.switch)
      .frame(maxWidth: .infinity, alignment: .leading)
    }.task(id: model.administrationGeneration) {
      let scope = ServerAdministrationScope(
        model: model, generation: model.administrationGeneration)
      if available {
        do {
          let active = try await model.currentAdministration {
            try await scope.request { try await client.serverHosting() }
          }
          activeHosting = active
          settings.backgroundEnabled = active.backgroundRequested
          settings.startAtLogin = active.startAtLogin
          settings.preventIdleSleep = active.preventIdleSleep
        } catch { if let failure = scope.message(for: error) { message = failure } }
      }
      guard model.isCurrentAdministration(scope.generation) else { return }
      if model.isLocalHost {
        settings = (try? HostServiceSettings.load()) ?? HostServiceSettings()
        pending = try? HostServiceRequest.load()
        permission = BackgroundHostingController.permissionState
      }
    }.onDisappear { actionTask?.cancel() }
  }
  private func run(_ action: @escaping @MainActor (ServerAdministrationScope) async throws -> Void)
  {
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    working = true
    actionTask = Task {
      defer {
        working = false
        actionTask = nil
      }
      do {
        try await model.currentAdministration {
          try scope.check()
          try await action(scope)
        }
      } catch { if let failure = scope.message(for: error) { message = failure } }
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
  @State private var actionTask: Task<Void, Never>?
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
    GroupBox("Library Maintenance") {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Notice new and removed files automatically", isOn: $settings.monitoringEnabled)
        Stepper(
          "Full check every \(Self.interval(settings.reconciliationMinutes))",
          value: $settings.reconciliationMinutes, in: 15...10080, step: 15)
        HStack {
          Stepper(
            "Maintenance from \(settings.maintenanceStartHour):00",
            value: $settings.maintenanceStartHour, in: 0...23)
          Stepper(
            "to \(settings.maintenanceEndHour):00", value: $settings.maintenanceEndHour,
            in: 1...24)
        }
        Stepper(
          "Maximum waiting tasks: \(settings.jobQueueLimit)", value: $settings.jobQueueLimit,
          in: 10...10000, step: 10)
        Text(
          "Maintenance hours use the host's local time. Manual scans remain available. Media is read directly; Aurelia does not transcode or copy videos."
        ).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("Save Maintenance Settings") {
          run { scope in
            saved(try await scope.request { try await client.saveServerSettings(settings) })
          }
        }
        .disabled(working || settings == configuration.stored)
        Divider()
        ForEach(libraries) { library in
          HStack {
            Text(library.name)
            Spacer()
            Button(library.monitoringEnabled == true ? "Disable Monitoring" : "Enable Monitoring") {
              run { scope in
                _ = try await scope.request {
                  try await client.updateLibraryMonitoring(
                    id: library.id, enabled: library.monitoringEnabled != true)
                }
                try await refresh(scope)
              }
            }
            Button("Scan") {
              run { scope in
                _ = try await scope.request { try await client.startLibraryScan(id: library.id) }
                try await refresh(scope)
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
                  run { scope in
                    try await scope.request { try await client.cancelScan(id: scan.id) }
                    try await refresh(scope)
                  }
                }
              } else if [.failed, .interrupted, .cancelled].contains(scan.state) {
                Button("Retry") {
                  run { scope in
                    _ = try await scope.request {
                      try await client.startLibraryScan(id: scan.libraryId)
                    }
                    try await refresh(scope)
                  }
                }
              }
            }
          }
          ForEach(jobs.metadata.prefix(12)) { job in
            HStack {
              VStack(alignment: .leading, spacing: 3) {
                Text("Metadata · \(job.state.rawValue) · \(job.itemsProcessed)/\(job.itemsTotal)")
                  .font(.caption)
                if let status = job.waitingStatus() {
                  Text(status).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("metadata-wait-status")
                }
                if let skipped = job.itemsSkipped, skipped > 0 {
                  Text("\(skipped) skipped").font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer()
              if [.queued, .running].contains(job.state) {
                Button("Cancel") {
                  run { scope in
                    try await scope.request { try await client.cancelMetadataJob(id: job.id) }
                    try await refresh(scope)
                  }
                }
              } else if [.failed, .interrupted, .cancelled].contains(job.state) {
                Button("Retry") {
                  run { scope in
                    try await scope.request { try await client.retryMetadataJob(id: job.id) }
                    try await refresh(scope)
                  }
                }
              }
            }
          }
        }
        Button("Refresh Queue") { run { scope in try await refresh(scope) } }.disabled(working)
        if let message { Text(message).font(.caption).textSelection(.enabled) }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(10).disabled(working)
    }.task(id: model.administrationGeneration) {
      let scope = ServerAdministrationScope(
        model: model, generation: model.administrationGeneration)
      do { try await model.currentAdministration { try await refresh(scope) } } catch {
        if let failure = scope.message(for: error) { message = failure }
      }
    }.onDisappear { actionTask?.cancel() }
  }
  static func interval(_ minutes: Int) -> String {
    guard minutes >= 60, minutes % 60 == 0 else { return "\(minutes) minutes" }
    let hours = minutes / 60
    return hours == 1 ? "hour" : "\(hours) hours"
  }

  private func refresh(_ scope: ServerAdministrationScope) async throws {
    try scope.check()
    async let roots = client.libraries()
    async let history = client.serverJobs()
    let loaded = try await (roots, history)
    try scope.check()
    (libraries, jobs) = loaded
  }
  private func run(_ action: @escaping @MainActor (ServerAdministrationScope) async throws -> Void)
  {
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    working = true
    actionTask = Task {
      defer {
        working = false
        actionTask = nil
      }
      do {
        try await model.currentAdministration {
          try scope.check()
          try await action(scope)
        }
        message = nil
      } catch { if let failure = scope.message(for: error) { message = failure } }
    }
  }
}

struct ServerBackupsEditor: View {
  @EnvironmentObject private var model: AppModel
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
  @State private var actionTask: Task<Void, Never>?
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
    GroupBox("Backup Details") {
      VStack(alignment: .leading, spacing: 12) {
        Stepper(
          "Automatic backup every \(settings.backupIntervalHours) hours",
          value: $settings.backupIntervalHours,
          in: 1...168)
        Stepper(
          "Keep \(settings.dailyBackupsRetained) daily backups",
          value: $settings.dailyBackupsRetained, in: 1...30)
        Stepper(
          "Keep \(settings.weeklyBackupsRetained) weekly backups",
          value: $settings.weeklyBackupsRetained, in: 1...12)
        Button("Save Backup Settings") {
          run { scope in
            saved(try await scope.request { try await client.saveServerSettings(settings) })
          }
        }.disabled(settings == configuration.stored)
        Button("Refresh Backups") {
          run { scope in backups = try await scope.request { try await client.serverBackups() } }
        }
        ForEach(backups.prefix(8)) { backup in
          HStack {
            Text(
              "\(backup.kind.capitalized) · \(ServerDateText.display(backup.createdAt)) · \(ByteCountFormatter.string(fromByteCount: backup.bytes, countStyle: .file))"
            ).font(.caption)
            Spacer()
            Button("Verify") {
              run { scope in
                try await scope.request { try await client.verifyDatabaseBackup(name: backup.name) }
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
          run { scope in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Aurelia-Server.aureliabackup"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let file = panel.url else { return }
            try await scope.request {
              try await client.exportEncryptedServerBackup(passphrase: passphrase, to: file)
            }
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
          run { scope in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let file = panel.url else { return }
            prepared = try await scope.request {
              try await client.prepareServerRestore(
                from: file, passphrase: passphrase, acceptDifferentIdentity: acceptDifferentIdentity
              )
            }
            passphrase = ""
            confirmation = ""
            message = "Backup verified in a private staging area. Active data has not changed."
          }
        }.disabled(passphrase.count < 12 || !restoreConfirmed || !nativeHostAvailable)
        if let prepared {
          Button("Restore Verified Backup & Restart", role: .destructive) {
            run { scope in
              try await scope.request { try await client.applyServerRestore(id: prepared.id) }
              self.prepared = nil
              message = "Restore requested. Reconnect and sign in again after the host restarts."
            }
          }.disabled(!restoreConfirmed)
        }
        if let message { Text(message).font(.caption).textSelection(.enabled) }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(10).disabled(working)
      if working { ProgressView("Working on the server…") }
    }.task(id: model.administrationGeneration) {
      let scope = ServerAdministrationScope(
        model: model, generation: model.administrationGeneration)
      do {
        backups = try await model.currentAdministration {
          try await scope.request { try await client.serverBackups() }
        }
      } catch { if let failure = scope.message(for: error) { message = failure } }
    }.onChange(of: model.administrationGeneration) { _, _ in clearSecrets() }
      .onDisappear {
        actionTask?.cancel()
        clearSecrets()
      }
  }
  private func run(_ action: @escaping @MainActor (ServerAdministrationScope) async throws -> Void)
  {
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    working = true
    actionTask = Task {
      defer {
        working = false
        actionTask = nil
      }
      do {
        try await model.currentAdministration {
          try scope.check()
          try await action(scope)
        }
      } catch { if let failure = scope.message(for: error) { message = failure } }
    }
  }
  private func clearSecrets() {
    passphrase = ""
    confirmation = ""
    prepared = nil
    restoreConfirmed = false
    acceptDifferentIdentity = false
  }
}

struct ServerDiagnosticsEditor: View {
  @EnvironmentObject private var model: AppModel
  let configuration: ServerConfigurationResponse
  let client: APIClient
  let saved: (ServerConfigurationResponse) -> Void
  @State private var settings: ServerPolicySettings
  @State private var events: [ServerDiagnosticEvent] = []
  @State private var working = false
  @State private var actionTask: Task<Void, Never>?
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
          run { scope in
            saved(try await scope.request { try await client.saveServerSettings(settings) })
          }
        }.disabled(settings == configuration.stored)
        HStack {
          Button("Refresh Events") {
            run { scope in events = try await scope.request { try await client.serverDiagnostics() }
            }
          }
          Button("Export Sanitized Diagnostics…") {
            run { scope in
              let data = try await scope.request { try await client.serverDiagnosticsExport() }
              let panel = NSSavePanel()
              panel.nameFieldStringValue = "Aurelia-Diagnostics.json"
              guard panel.runModal() == .OK, let file = panel.url else { return }
              try scope.check()
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
    }.task(id: model.administrationGeneration) {
      let scope = ServerAdministrationScope(
        model: model, generation: model.administrationGeneration)
      do {
        events = try await model.currentAdministration {
          try await scope.request { try await client.serverDiagnostics() }
        }
      } catch { if let failure = scope.message(for: error) { message = failure } }
    }.onDisappear { actionTask?.cancel() }
  }
  private func run(_ action: @escaping @MainActor (ServerAdministrationScope) async throws -> Void)
  {
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    working = true
    actionTask = Task {
      defer {
        working = false
        actionTask = nil
      }
      do {
        try await model.currentAdministration {
          try scope.check()
          try await action(scope)
        }
      } catch { if let failure = scope.message(for: error) { message = failure } }
    }
  }
}
