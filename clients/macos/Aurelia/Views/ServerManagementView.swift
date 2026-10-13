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
    Group {
      if model.managementUnlocked {
        VStack(alignment: .leading, spacing: 20) {
          ManagementStatusView()
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
                LabeledContent("Profiles", value: "\(status.users)")
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
                LabeledContent(
                  "Host addresses", value: status.networkAddresses.joined(separator: ", "))
              }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
          }
          if let configuration, let client {
            ServerNetworkEditor(
              configuration: configuration, client: client,
              nativeHostAvailable: capabilities?.nativeHostOperations == true
            ) { Task { await reload() } }
            .id("network-\(configuration.stored.revision)")
            ServerHostingEditor(
              client: client, available: capabilities?.nativeHostOperations == true)
            ServerSecurityEditor(configuration: configuration, client: client) { configuration in
              self.configuration = configuration
            }.id(configuration.stored.revision)
          }
          GroupBox("Users & Access") {
            VStack(alignment: .leading, spacing: 12) {
              ForEach(users) { access in
                HStack(spacing: 12) {
                  Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 34)).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                  VStack(alignment: .leading, spacing: 4) {
                    Text(access.user.username).font(.headline)
                    Text(
                      "\(access.user.role.rawValue.capitalized) · \(access.isEnabled ? "Enabled" : "Disabled")"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                      Label(
                        pinStatus(access.user),
                        systemImage: access.user.pinProtectionEnabled
                          ? "lock" : "person.crop.circle")
                      Text(contentStatus(access.user))
                    }.font(.caption).foregroundStyle(.secondary)
                  }
                  Spacer()
                  Button("Edit Profile…") { editingUser = access }
                    .accessibilityIdentifier("edit-profile-\(access.id.uuidString)")
                }.padding(.vertical, 5)
                Divider()
              }
              Button("Create Profile…") { creatingUser = true }
                .accessibilityIdentifier("create-profile")
              Text(
                "Choose the entire library or individual films and series for each profile. New profiles start without title access. Owners always have full access."
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
      } else {
        ManagementUnlockView()
      }
    }
    .task(id: model.administrationGeneration) {
      if model.managementUnlocked { await reload() }
    }
    .onChange(of: model.administrationGeneration) { _, _ in error = nil }
    .onChange(of: model.profile?.sessionId) { _, _ in
      configuration = nil
      status = nil
      users = []
      capabilities = nil
      editingUser = nil
      creatingUser = false
      error = nil
    }
    .sheet(item: $editingUser) { access in
      if let client {
        ServerProfileEditor(existing: access, client: client) {
          Task { await reload() }
        }
      }
    }
    .sheet(isPresented: $creatingUser) {
      if let client { ServerProfileEditor(client: client) { Task { await reload() } } }
    }
  }

  private func pinStatus(_ user: UserSummary) -> String {
    if user.needsPinSetup { return "PIN setup required" }
    return user.pinProtectionEnabled ? "PIN protected" : "No PIN"
  }

  private func contentStatus(_ user: UserSummary) -> String {
    if user.role == .owner || user.accessMode == .entireLibrary { return "Entire Library" }
    return user.accessMode == .selectedTitles ? "Selected Titles" : "Existing Storage Grants"
  }

  @MainActor private func reload() async {
    guard let client, model.managementUnlocked else { return }
    let generation = model.administrationGeneration
    loading = true
    defer { loading = false }
    do {
      let loaded = try await model.currentAdministration {
        guard model.isCurrentAdministration(generation) else { throw CancellationError() }
        async let config = client.serverSettings()
        async let overview = client.serverStatus()
        async let accounts = client.serverUsers()
        async let abilities = client.serverCapabilities()
        return try await (config, overview, accounts, abilities)
      }
      guard model.isCurrentAdministration(generation), !Task.isCancelled else { return }
      (configuration, status, users, capabilities) = loaded
      error = nil
    } catch is CancellationError {
    } catch {
      guard model.isCurrentAdministration(generation), !Task.isCancelled else { return }
      if let failure = error as? APIClientError,
        failure.isManagementLocked || failure == .serverIdentityMismatch
      {
        model.handleAdministrationFailure(error, generation: generation)
        return
      }
      self.error = error.localizedDescription
    }
  }
}

private struct ServerSecurityEditor: View {
  @EnvironmentObject private var model: AppModel
  let configuration: ServerConfigurationResponse
  let client: APIClient
  let saved: (ServerConfigurationResponse) -> Void
  @State private var settings: ServerPolicySettings
  @State private var saving = false
  @State private var saveTask: Task<Void, Never>?
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
          let generation = model.administrationGeneration
          saving = true
          saveTask = Task {
            defer {
              saving = false
              saveTask = nil
            }
            do {
              let updated = try await model.currentAdministration {
                guard model.isCurrentAdministration(generation) else { throw CancellationError() }
                return try await client.saveServerSettings(settings)
              }
              saved(updated)
              error = nil
            } catch is CancellationError {
            } catch {
              guard model.isCurrentAdministration(generation) else { return }
              if let failure = error as? APIClientError,
                failure.isManagementLocked || failure == .serverIdentityMismatch
              {
                model.handleAdministrationFailure(error, generation: generation)
                return
              }
              self.error = error.localizedDescription
            }
          }
        }.disabled(saving || settings == configuration.stored)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }.onDisappear { saveTask?.cancel() }
  }
}
