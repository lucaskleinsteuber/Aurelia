import SwiftUI

struct ServerManagementView: View {
  @EnvironmentObject private var model: AppModel
  @State private var configuration: ServerConfigurationResponse?
  @State private var status: ServerStatusSummary?
  @State private var users: [UserAccessSummary] = []
  @State private var editingUser: UserAccessSummary?
  @State private var creatingUser = false
  @State private var error: String?
  @State private var loading = false
  @State private var capabilities: ServerCapabilities?

  private var client: APIClient? { model.profile.map(APIClient.init(profile:)) }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      if loading { ProgressView("Loading server settings…") }
      if let status {
        GroupBox("Overview") {
          VStack(alignment: .leading, spacing: 10) {
            LabeledContent("State", value: status.state.capitalized)
            LabeledContent("Version", value: status.version)
            LabeledContent(
              "Uptime",
              value: Duration.seconds(status.uptimeSeconds).formatted(
                .time(pattern: .hourMinuteSecond)))
            LabeledContent("Active stream requests", value: "\(status.activeStreams)")
            LabeledContent(
              "Database",
              value: ByteCountFormatter.string(
                fromByteCount: status.databaseBytes, countStyle: .file))
            LabeledContent("Libraries", value: "\(status.libraries)")
            LabeledContent("Accounts", value: "\(status.users)")
            if let bytes = status.freeDiskBytes {
              LabeledContent(
                "Available storage",
                value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
              if bytes < 1024 * 1024 * 1024 {
                Label(
                  "Low disk space. Backups and library updates may fail.",
                  systemImage: "exclamationmark.triangle"
                ).foregroundStyle(.orange)
              }
            }
            if let expires = status.certificateExpiresAt {
              LabeledContent("TLS certificate expires", value: expires)
            }
            LabeledContent("Host addresses", value: status.networkAddresses.joined(separator: ", "))
          }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
      }
      if let configuration, let client {
        ServerNetworkEditor(
          configuration: configuration, client: client,
          nativeHostAvailable: capabilities?.nativeHostOperations == true
        ) { Task { await reload() } }
        .id("network-\(configuration.stored.revision)")
        ServerHostingEditor(client: client, available: capabilities?.nativeHostOperations == true)
        ServerSecurityEditor(configuration: configuration, client: client) { configuration in
          self.configuration = configuration
        }.id(configuration.stored.revision)
      }
      GroupBox("Users & Access") {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(users) { access in
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text(access.user.username).font(.headline)
                Text(
                  "\(access.user.role.rawValue.capitalized) · \(access.isEnabled ? "Enabled" : "Disabled") · \(access.user.role == .owner ? "All libraries" : "\(access.libraryIds.count) shared libraries")"
                )
                .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button("Manage…") { editingUser = access }
            }
            Divider()
          }
          Button("Create User…") { creatingUser = true }
          Text(
            "New users have no library access until you explicitly share a library. Owners always have full access."
          )
          .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
      }
      if let configuration, let client {
        ServerLibraryJobsEditor(configuration: configuration, client: client) {
          self.configuration = $0
        }
        .id("jobs-\(configuration.stored.revision)")
        ServerBackupsEditor(
          configuration: configuration, client: client,
          nativeHostAvailable: capabilities?.nativeHostOperations == true
        ) { self.configuration = $0 }
        .id("backups-\(configuration.stored.revision)")
        ServerDiagnosticsEditor(configuration: configuration, client: client) {
          self.configuration = $0
        }
        .id("diagnostics-\(configuration.stored.revision)")
      }
      Button("Refresh Server Status") { Task { await reload() } }.disabled(loading)
    }
    .task { await reload() }
    .sheet(item: $editingUser) { access in
      if let client {
        ServerUserEditor(access: access, libraries: model.libraries, client: client) {
          Task { await reload() }
        }
      }
    }
    .sheet(isPresented: $creatingUser) {
      if let client { ServerUserCreator(client: client) { Task { await reload() } } }
    }
  }

  @MainActor private func reload() async {
    guard let client else { return }
    loading = true
    defer { loading = false }
    do {
      async let config = client.serverSettings()
      async let overview = client.serverStatus()
      async let accounts = client.serverUsers()
      async let abilities = client.serverCapabilities()
      (configuration, status, users, capabilities) = try await (
        config, overview, accounts, abilities
      )
      error = nil
    } catch { self.error = error.localizedDescription }
  }
}

private struct ServerSecurityEditor: View {
  let configuration: ServerConfigurationResponse
  let client: APIClient
  let saved: (ServerConfigurationResponse) -> Void
  @State private var settings: ServerPolicySettings
  @State private var saving = false
  @State private var error: String?

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
    GroupBox("Devices & Security") {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Allow new device pairing", isOn: $settings.pairingEnabled)
        Stepper(
          "New device session lifetime: \(settings.deviceSessionDays) days",
          value: $settings.deviceSessionDays, in: 1...365)
        Stepper(
          "Simultaneous stream requests: \(settings.globalStreamLimit) server-wide",
          value: $settings.globalStreamLimit, in: settings.userStreamLimit...128)
        Stepper(
          "Simultaneous stream requests: \(settings.userStreamLimit) per user",
          value: $settings.userStreamLimit, in: 1...min(16, settings.globalStreamLimit))
        Text(
          "Existing sessions keep their current expiry. New pairing codes expire after five minutes. Device revocation stops affected streams immediately."
        )
        .font(.caption).foregroundStyle(.secondary)
        if let error { Text(error).foregroundStyle(.red) }
        Button(saving ? "Saving…" : "Save Security Settings") {
          saving = true
          Task {
            defer { saving = false }
            do {
              saved(try await client.saveServerSettings(settings))
              error = nil
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
          }
        }.disabled(saving || settings == configuration.stored)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }
  }
}

private struct ServerUserCreator: View {
  let client: APIClient
  let completed: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var username = ""
  @State private var password = ""
  @State private var role: UserRole = .user
  @State private var saving = false
  @State private var error: String?
  var body: some View {
    Form {
      Text("Create User").font(.title2.bold())
      TextField("Username", text: $username)
      SecureField("New password (at least 12 characters)", text: $password)
      Picker("Role", selection: $role) {
        Text("User").tag(UserRole.user)
        Text("Administrator").tag(UserRole.admin)
        Text("Owner").tag(UserRole.owner)
      }
      Text(
        "Users and administrators start without library grants. A new owner has full server access."
      ).font(.caption).foregroundStyle(.secondary)
      if let error { Text(error).foregroundStyle(.red) }
      HStack {
        Button("Cancel") { dismiss() }
        Spacer()
        Button("Create User") {
          saving = true
          Task {
            defer { saving = false }
            do {
              try await client.createUser(username: username, password: password, role: role)
              password = ""
              completed()
              dismiss()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
          }
        }.disabled(saving || username.count < 3 || password.count < 12)
      }
    }.padding(24).frame(width: 500)
  }
}

private struct ServerUserEditor: View {
  let access: UserAccessSummary
  let libraries: [LibrarySummary]
  let client: APIClient
  let completed: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var enabled: Bool
  @State private var role: UserRole
  @State private var selected: Set<UUID>
  @State private var sessions: [DeviceSessionSummary] = []
  @State private var password = ""
  @State private var working = false
  @State private var error: String?

  init(
    access: UserAccessSummary, libraries: [LibrarySummary], client: APIClient,
    completed: @escaping () -> Void
  ) {
    self.access = access
    self.libraries = libraries
    self.client = client
    self.completed = completed
    _enabled = State(initialValue: access.isEnabled)
    _role = State(initialValue: access.user.role)
    _selected = State(initialValue: Set(access.libraryIds))
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text(access.user.username).font(.title2.bold())
        Toggle("Account enabled", isOn: $enabled)
        Picker("Role", selection: $role) {
          Text("User").tag(UserRole.user)
          Text("Administrator").tag(UserRole.admin)
          Text("Owner").tag(UserRole.owner)
        }
        Text("Shared Libraries").font(.headline)
        ForEach(libraries) { library in
          Toggle(
            library.name,
            isOn: Binding(
              get: { selected.contains(library.id) },
              set: { value in
                if value { selected.insert(library.id) } else { selected.remove(library.id) }
              })
          ).disabled(role == .owner)
        }
        Text(
          "Removing a grant or disabling the account stops affected streams. The final active owner is protected."
        )
        .font(.caption).foregroundStyle(.secondary)
        Button("Save Access") {
          run {
            try await client.updateUserAccess(
              id: access.id, enabled: enabled,
              libraries: Array(selected).sorted { $0.uuidString < $1.uuidString })
            if role != access.user.role {
              try await client.changeUserRole(id: access.id, role: role)
            }
            completed()
            dismiss()
          }
        }.disabled(working)
        Divider()
        Text("Devices").font(.headline)
        ForEach(sessions) { session in
          HStack {
            VStack(alignment: .leading) {
              Text(session.deviceName)
              Text("Last used: \(session.lastSeenAt)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if session.revokedAt != nil {
              Text("Revoked").foregroundStyle(.secondary)
            } else {
              Button("Revoke") {
                run {
                  try await client.revokeManagedSession(id: session.id)
                  sessions = try await client.userSessions(access.id)
                }
              }
            }
          }
        }
        Button("Revoke All Sessions", role: .destructive) {
          run {
            try await client.revokeUserSessions(id: access.id)
            sessions = try await client.userSessions(access.id)
          }
        }.disabled(working)
        SecureField("New password (at least 12 characters)", text: $password)
        Button("Reset Password & Revoke Sessions") {
          run {
            try await client.resetUserPassword(id: access.id, password: password)
            password = ""
            sessions = try await client.userSessions(access.id)
          }
        }.disabled(working || password.count < 12)
        if let error { Text(error).foregroundStyle(.red) }
        Button("Done") { dismiss() }
      }.padding(24)
    }.frame(width: 580, height: 600)
      .task {
        do { sessions = try await client.userSessions(access.id) } catch {
          self.error = error.localizedDescription
        }
      }
  }
  private func run(_ action: @escaping @MainActor () async throws -> Void) {
    working = true
    Task {
      defer { working = false }
      do {
        try await action()
        error = nil
      } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
  }
}
