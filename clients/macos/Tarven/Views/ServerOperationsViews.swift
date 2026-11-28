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

/// The unsaved edits of one settings box. Every box edits a few fields of the same server
/// settings, so saving one box must neither discard another box's edits nor send stale values.
struct ServerSettingsDraft: Equatable {
  /// The server's settings the edits are based on.
  private(set) var base: ServerPolicySettings
  var value: ServerPolicySettings

  init(_ stored: ServerPolicySettings) {
    base = stored
    value = stored
  }

  var isDirty: Bool { value != base }

  /// The latest server settings with only the fields this box changed.
  func merged(onto latest: ServerPolicySettings) -> ServerPolicySettings {
    var result = latest
    func take<Value: Equatable>(_ path: WritableKeyPath<ServerPolicySettings, Value>) {
      if value[keyPath: path] != base[keyPath: path] {
        result[keyPath: path] = value[keyPath: path]
      }
    }
    take(\.serverName)
    take(\.lanAccessEnabled)
    take(\.lanHttpsPort)
    take(\.pairingEnabled)
    take(\.deviceSessionDays)
    take(\.globalStreamLimit)
    take(\.userStreamLimit)
    take(\.bonjourEnabled)
    take(\.allowedNetworks)
    take(\.monitoringEnabled)
    take(\.reconciliationMinutes)
    take(\.maintenanceStartHour)
    take(\.maintenanceEndHour)
    take(\.jobQueueLimit)
    take(\.automaticBackupsEnabled)
    take(\.backupIntervalHours)
    take(\.dailyBackupsRetained)
    take(\.weeklyBackupsRetained)
    take(\.eventRetentionDays)
    take(\.maximumEvents)
    return result
  }

  /// Takes a newer server state as the base and keeps the fields this box changed; an unchanged
  /// box simply shows the server's values.
  mutating func follow(_ latest: ServerPolicySettings) {
    value = merged(onto: latest)
    base = latest
  }
}

struct ServerNetworkEditor: View {
  @EnvironmentObject private var model: AppModel
  let configuration: ServerConfigurationResponse
  let client: APIClient
  let nativeHostAvailable: Bool
  let reload: () -> Void
  @State private var draft: ServerSettingsDraft
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
    _draft = State(initialValue: ServerSettingsDraft(configuration.stored))
    _networks = State(initialValue: Self.networkLines(configuration.stored))
  }

  private static func networkLines(_ settings: ServerPolicySettings) -> String {
    (settings.allowedNetworks ?? []).joined(separator: "\n")
  }

  var body: some View {
    TarvenSettingsSection(
      "Network", symbol: "network",
      description: "Which networks may reach the server and how it shows up in your home network."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        LabeledContent("Active Name", value: configuration.active.serverName)
        LabeledContent("Connected Address", value: model.profile?.baseURL.absoluteString ?? "—")
        TextField("Server Name", text: $draft.value.serverName)
        Toggle("Allow Devices on Your Network or VPN", isOn: $draft.value.lanAccessEnabled)
          .disabled(!model.isLocalHost && configuration.active.lanAccessEnabled)
        caption(
          "Other devices at home, or connected through your own private VPN, reach the server "
            + "over an encrypted HTTPS connection. When this is off, only the server computer "
            + "itself can connect.")
        Stepper(
          "HTTPS port: \(draft.value.lanHttpsPort)", value: $draft.value.lanHttpsPort,
          in: 1024...65535)
        Toggle("Show the Server on Your Network (Bonjour)", isOn: $draft.value.bonjourEnabled)
        caption(
          "Devices on the same network find the server by themselves, without typing its address.")
        Text("Allowed networks (optional)").font(.caption.weight(.semibold))
        TextEditor(text: $networks).font(.system(.caption, design: .monospaced)).frame(height: 64)
        caption(
          "Only devices in these networks may connect. Write one network per line in CIDR form, "
            + "for example 192.168.1.0/24 for the addresses 192.168.1.0 to 192.168.1.255. "
            + "Leave it empty to allow every private network.")
        caption(
          "The server computer itself can always connect. Addresses from the public Internet are "
            + "always blocked, and there is no unencrypted way around that.")
        if let profile = model.profile {
          Text("Server fingerprint (pinned TLS public key): \(profile.publicKeyFingerprint)")
            .font(.caption)
            .textSelection(.enabled)
          caption(
            "Tarven remembers this fingerprint and refuses to connect when a different server "
              + "answers at this address.")
        }
        if !draft.value.lanAccessEnabled && configuration.active.lanAccessEnabled {
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
          caption(
            "Network changes are tried for 60 seconds first: the server restarts with the new "
              + "settings, and you confirm them on the new connection with your Profile PIN and "
              + "Server Password. Without that confirmation the previous settings return by "
              + "themselves.")
          Button("Try Network Settings (60-second rollback)") {
            perform { scope in
              guard let profile = model.profile,
                var parts = URLComponents(url: profile.baseURL, resolvingAgainstBaseURL: false)
              else { throw APIClientError.invalidResponse }
              draft.value.allowedNetworks = networks.split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: .whitespaces)
              }.filter { !$0.isEmpty }
              let trial = draft.merged(onto: configuration.stored)
              let pending = try await scope.request {
                try await client.trialNetwork(trial, confirmDisconnect: confirmedDisconnect)
              }
              parts.scheme = trial.lanAccessEnabled ? "https" : "http"
              parts.port = trial.lanHttpsPort
              if !trial.lanAccessEnabled {
                parts.host = "127.0.0.1"
                parts.port = AppEdition.localPort
              }
              guard let address = parts.url else { throw APIClientError.invalidResponse }
              trialProfile = StoredServerProfile(
                serverId: profile.serverId, name: trial.serverName, baseURL: address,
                publicKeyFingerprint: profile.publicKeyFingerprint, token: profile.token,
                sessionId: profile.sessionId, expiresAt: profile.expiresAt, user: profile.user,
                locallyManaged: profile.locallyManaged, viewingSession: profile.viewingSession)
              operation = pending
              model.beginNetworkConfirmation(until: pending.confirmBefore)
              message = nil
            }
          }.disabled(
            working || !nativeHostAvailable
              || (!draft.value.lanAccessEnabled && configuration.active.lanAccessEnabled
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
    .onChange(of: configuration.stored) { _, latest in
      let networksUnchanged = networks == Self.networkLines(draft.base)
      draft.follow(latest)
      if networksUnchanged { networks = Self.networkLines(latest) }
    }
    .onDisappear { actionTask?.cancel() }
  }
  private func caption(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
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
    TarvenSettingsSection(
      "When the Server Runs",
      symbol: "power",
      description: "The server can't be reached while this Mac is asleep or turned off."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Picker("Run the server", selection: $settings.backgroundEnabled) {
          Text("Only while the Tarven app is open").tag(false)
          Text("Also when the Tarven app is closed").tag(true)
        }
        .pickerStyle(.radioGroup)
        .accessibilityIdentifier("server-hosting-mode")
        Divider()
        ServerSwitchRow(
          "Start Automatically When You Log In",
          detail:
            "Starts the background server automatically when you sign in to this Mac so other devices can connect without opening Tarven.",
          isOn: $settings.startAtLogin
        )
        .disabled(!settings.backgroundEnabled)
        ServerSwitchRow(
          "Keep This Mac Awake While the Server Runs",
          detail:
            "Prevents automatic Mac sleep while the server is running so remote devices stay connected. On battery power this uses more energy.",
          isOn: $settings.preventIdleSleep)
        if let activeHosting, activeHosting.state == "awaitingPermission" {
          Text("Waiting for permission on the server Mac.").foregroundStyle(.orange)
        }
        if model.isLocalHost {
          if settings.backgroundEnabled, !BackgroundHostingController.permitted {
            HStack {
              Label(
                "macOS must allow Tarven to run in the background (\(permission)).",
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
            "Changes made from another device are sent as a request. Open Tarven on the server Mac to approve it."
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
                  "Request sent. Approve it in Tarven on the server Mac; nothing has changed yet."
              }
              activeHosting = try await scope.request { try await client.serverHosting() }
            }
          }
          .accessibilityIdentifier("server-hosting-apply")
        }.disabled(working || !available)
        if !available {
          Text(
            "This server doesn't offer changing how it runs from here. Change it in Tarven on the server Mac."
          )
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        if let message { Text(message).font(.caption).textSelection(.enabled) }
      }
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
  @State private var draft: ServerSettingsDraft
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
    _draft = State(initialValue: ServerSettingsDraft(configuration.stored))
  }
  var body: some View {
    TarvenSettingsSection(
      "Library Maintenance", symbol: "wrench.and.screwdriver",
      description:
        "When the server checks the library and tidies up, and how much work it may queue."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Toggle(
          "Notice New and Removed Files Automatically", isOn: $draft.value.monitoringEnabled)
        Stepper(
          "Full check every \(Self.interval(draft.value.reconciliationMinutes))",
          value: $draft.value.reconciliationMinutes, in: 15...10080, step: 15)
        caption(
          "A full check walks through every storage location to catch changes that were missed, "
            + "for example on a drive that was disconnected.")
        HStack {
          Stepper(
            "Maintenance from \(draft.value.maintenanceStartHour):00",
            value: $draft.value.maintenanceStartHour, in: 0...23)
          Stepper(
            "to \(draft.value.maintenanceEndHour):00", value: $draft.value.maintenanceEndHour,
            in: 1...24)
        }
        caption(
          "Automatic full checks run only in these hours, in the server computer's local time. "
            + "Scans you start yourself run at any time.")
        Stepper(
          "Maximum waiting tasks: \(draft.value.jobQueueLimit)",
          value: $draft.value.jobQueueLimit, in: 10...10000, step: 10)
        caption(
          "How many scans and information lookups may wait in line. When the line is full, new "
            + "ones are turned away until it shrinks.")
        caption("Media is read directly; Tarven never copies or changes videos.")
        Button("Save Maintenance Settings") {
          let settings = draft.merged(onto: configuration.stored)
          run { scope in
            saved(try await scope.request { try await client.saveServerSettings(settings) })
          }
        }
        .disabled(working || !draft.isDirty)
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
              Text(
                "Scan · \(ReadableState.text(scan.state.rawValue)) · \(TarvenCountText.format(scan.filesDiscovered, singular: "file"))"
              ).font(.caption)
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
                Text(
                  "Metadata · \(ReadableState.text(job.state.rawValue)) · \(job.itemsProcessed)/\(job.itemsTotal)"
                )
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
    }
    .onChange(of: configuration.stored) { _, latest in draft.follow(latest) }
    .task(id: model.administrationGeneration) {
      let scope = ServerAdministrationScope(
        model: model, generation: model.administrationGeneration)
      do { try await model.currentAdministration { try await refresh(scope) } } catch {
        if let failure = scope.message(for: error) { message = failure }
      }
    }.onDisappear { actionTask?.cancel() }
  }
  private func caption(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
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
  @State private var draft: ServerSettingsDraft
  @State private var backups: [ServerBackupSummary] = []
  @State private var passphrase = ""
  @State private var confirmation = ""
  @State private var restorePassphrase = ""
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
    _draft = State(initialValue: ServerSettingsDraft(configuration.stored))
  }
  var body: some View {
    TarvenSettingsSection(
      "Backup Details", symbol: "externaldrive",
      description: "Encrypted backups you keep yourself, and restoring from one."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Stepper(
          "Automatic backup every \(draft.value.backupIntervalHours) hours",
          value: $draft.value.backupIntervalHours,
          in: 1...168)
        Stepper(
          "Keep \(draft.value.dailyBackupsRetained) daily backups",
          value: $draft.value.dailyBackupsRetained, in: 1...30)
        Stepper(
          "Keep \(draft.value.weeklyBackupsRetained) weekly backups",
          value: $draft.value.weeklyBackupsRetained, in: 1...12)
        Button("Save Backup Settings") {
          let settings = draft.merged(onto: configuration.stored)
          run { scope in
            saved(try await scope.request { try await client.saveServerSettings(settings) })
          }
        }.disabled(!draft.isDirty)
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
        Text("Export a Backup").font(.subheadline.weight(.semibold))
        SecureField("New backup passphrase (at least 12 characters)", text: $passphrase)
        SecureField("Repeat the new backup passphrase", text: $confirmation)
        if !confirmation.isEmpty, passphrase != confirmation {
          Text("The passphrases don't match.").font(.caption).foregroundStyle(.secondary)
        }
        Button("Export Encrypted Backup…") {
          run { scope in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Tarven-Server.tarvenbackup"
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
        Divider()
        Text("Restore a Backup").font(.subheadline.weight(.semibold))
        SecureField("Passphrase of the backup to restore", text: $restorePassphrase)
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
                from: file, passphrase: restorePassphrase,
                acceptDifferentIdentity: acceptDifferentIdentity)
            }
            restorePassphrase = ""
            message = "Backup verified in a private staging area. Active data has not changed."
          }
        }.disabled(restorePassphrase.count < 12 || !restoreConfirmed || !nativeHostAvailable)
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
      if working {
        HStack(spacing: 8) {
          TarvenDelayedProgress(controlSize: .small)
          Text("Working on the server…").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .onChange(of: configuration.stored) { _, latest in draft.follow(latest) }
    .task(id: model.administrationGeneration) {
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
    restorePassphrase = ""
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
  @State private var draft: ServerSettingsDraft
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
    _draft = State(initialValue: ServerSettingsDraft(configuration.stored))
  }
  var body: some View {
    TarvenSettingsSection(
      "Diagnostics", symbol: "stethoscope",
      description: "A report of the server's state, for when something goes wrong."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Stepper(
          "Retain events for \(draft.value.eventRetentionDays) days",
          value: $draft.value.eventRetentionDays, in: 1...90)
        Stepper(
          "Maximum events: \(draft.value.maximumEvents)", value: $draft.value.maximumEvents,
          in: 100...10000, step: 100)
        Button("Save Diagnostic Settings") {
          let settings = draft.merged(onto: configuration.stored)
          run { scope in
            saved(try await scope.request { try await client.saveServerSettings(settings) })
          }
        }.disabled(!draft.isDirty)
        HStack {
          Button("Refresh Events") {
            run { scope in events = try await scope.request { try await client.serverDiagnostics() }
            }
          }
          Button("Export Sanitized Diagnostics…") {
            run { scope in
              let data = try await scope.request { try await client.serverDiagnosticsExport() }
              let panel = NSSavePanel()
              panel.nameFieldStringValue = "Tarven-Diagnostics.json"
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
          Text(
            "\(ServerDateText.display(event.at)) · \(ReadableState.text(event.severity)) · "
              + ServerIssueText.title(for: event.code)
          )
          .font(.caption).textSelection(.enabled)
          .help(event.code)
        }
        if let message { Text(message).font(.caption).textSelection(.enabled) }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(10).disabled(working)
    }
    .onChange(of: configuration.stored) { _, latest in draft.follow(latest) }
    .task(id: model.administrationGeneration) {
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
