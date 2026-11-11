import SwiftUI

struct ServerManagementView: View {
  /// Settings shows the server under Server and the people who use it under Profiles and
  /// Devices; both pages share this view's loading, approval and deletion handling.
  enum Part { case server, people }

  @EnvironmentObject private var model: AppModel
  private let part: Part
  @State private var configuration: ServerConfigurationResponse?
  @State private var status: ServerStatusSummary?
  @State private var health: ServerHealthResponse?
  @State private var users: [UserAccessSummary] = []
  @State private var editingUser: UserAccessSummary?
  @State private var creatingUser = false
  @State private var error: String?
  @State private var loading = false
  @State private var capabilities: ServerCapabilities?
  @State private var profileToDelete: UserAccessSummary?
  @State private var deletingProfile: UUID?
  @State private var deletionTask: Task<Void, Never>?
  @State private var deletionRun = UUID()
  @State private var showsAdvanced: Bool

  init(_ part: Part = .server, showsAdvanced: Bool = false) {
    self.part = part
    _showsAdvanced = State(initialValue: showsAdvanced)
  }

  private var client: APIClient? { model.profile.map(APIClient.init(profile:)) }
  private var hosting: ServerHostingKind {
    ServerHostingKind(capabilities: capabilities, isLocalHost: model.isLocalHost)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      if part == .people {
        profiles
        ServerDevicesSection()
      } else {
        serverParts
      }
    }
    .task(id: model.administrationGeneration) {
      await reload()
    }
    .onChange(of: model.administrationGeneration) { _, _ in
      cancelDeletion()
      error = nil
    }
    .onChange(of: model.profile?.sessionId) { _, _ in
      configuration = nil
      status = nil
      health = nil
      users = []
      capabilities = nil
      editingUser = nil
      creatingUser = false
      cancelDeletion()
      error = nil
    }
    .onDisappear { cancelDeletion() }
    .alert(
      "Delete \(profileToDelete?.user.shownName ?? "Profile")?",
      isPresented: Binding(
        get: { profileToDelete != nil },
        set: { if !$0 { profileToDelete = nil } }),
      presenting: profileToDelete
    ) { access in
      Button("Cancel", role: .cancel) {}
      Button("Delete Profile", role: .destructive) { delete(access) }
    } message: { access in
      Text(
        "Favorites, playback progress and scene notes for \(access.user.shownName) will be permanently removed. Active sessions will end. Your media and shared library will stay unchanged."
      )
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

  @ViewBuilder private var serverParts: some View {
    if loading && status == nil { ProgressView("Loading server settings…") }
    if let status {
      ServerSummaryCard(
        status: status, configuration: configuration, client: client,
        nativeHostAvailable: capabilities?.nativeHostOperations == true,
        hosting: hosting,
        refreshing: loading || deletingProfile != nil
      ) { Task { await reload() } }
    }
    if let health {
      ServerHealthCard(health: health)
    }
    // Each kind of server shows only what it can do: hosting inside Aurelia on a Mac, or
    // power saving of the Linux package.
    if let client, capabilities != nil || model.isLocalHost {
      if hosting.hostsOnMac {
        ServerHostingEditor(
          client: client, available: capabilities?.nativeHostOperations == true)
      } else if hosting == .linuxPackage {
        ServerPowerEditor(client: client)
      }
    }
    if let configuration, let client {
      ServerEssentialsEditor(configuration: configuration, client: client) {
        self.configuration = $0
      }
      .id("essentials-\(configuration.stored.revision)")
      ServerScrubPreviewsEditor(client: client)
      ServerMediaSegmentsEditor(client: client)
      ServerVideoConversionCard(client: client)
    }
    ServerAdvancedDisclosure(isExpanded: $showsAdvanced) {
      if let status { ServerDetailsBox(status: status) }
      if let configuration, let client {
        if hosting == .linuxPackage {
          ServerLinuxNetworkBox(configuration: configuration)
        } else {
          ServerNetworkEditor(
            configuration: configuration, client: client,
            nativeHostAvailable: capabilities?.nativeHostOperations == true
          ) { Task { await reload() } }
          .id("network-\(configuration.stored.revision)")
        }
        ServerSecurityEditor(configuration: configuration, client: client) { configuration in
          self.configuration = configuration
        }.id(configuration.stored.revision)
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
    }
  }

  private var profiles: some View {
    AureliaSettingsSection(
      "Profiles",
      symbol: "person.2.fill",
      description:
        "Everyone who watches gets a profile. Choose what each profile can see; owners always see everything."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(users) { access in
          HStack(spacing: 12) {
            AureliaProfileAvatar(user: access.user, size: 36)
            VStack(alignment: .leading, spacing: 4) {
              Text(access.user.shownName).font(.headline)
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
              .disabled(deletingProfile != nil)
              .accessibilityIdentifier("edit-profile-\(access.id.uuidString)")
            if canDelete(access) {
              Button("Delete Profile…", role: .destructive) { profileToDelete = access }
                .disabled(deletingProfile != nil)
                .accessibilityIdentifier("delete-profile-\(access.id.uuidString)")
            }
            if deletingProfile == access.id { ProgressView().controlSize(.small) }
          }.padding(.vertical, 5)
          Divider()
        }
        Button("Create Profile…") { creatingUser = true }
          .disabled(deletingProfile != nil)
          .accessibilityIdentifier("create-profile")
        Text("New profiles start without access to any titles until you choose them.")
          .font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func pinStatus(_ user: UserSummary) -> String {
    if user.needsPinSetup { return "PIN setup required" }
    return user.pinProtectionEnabled ? "PIN protected" : "No PIN"
  }

  private func contentStatus(_ user: UserSummary) -> String {
    if let child = ProfileAgeSteps.summary(for: user.ageLimit) { return child }
    if user.role == .owner || user.accessMode == .entireLibrary { return "Entire Library" }
    return user.accessMode == .selectedTitles ? "Selected Titles" : "Existing Storage Grants"
  }

  private func canDelete(_ access: UserAccessSummary) -> Bool {
    guard model.profile?.user?.role == .owner,
      access.id != model.profile?.user?.id
    else { return false }
    return access.user.role != .owner || !access.isEnabled
      || users.filter { $0.user.role == .owner && $0.isEnabled }.count > 1
  }

  private func cancelDeletion() {
    deletionRun = UUID()
    deletionTask?.cancel()
    deletionTask = nil
    deletingProfile = nil
    profileToDelete = nil
  }

  private func delete(_ access: UserAccessSummary) {
    guard deletingProfile == nil, canDelete(access), let client else { return }
    let generation = model.administrationGeneration
    let run = UUID()
    deletionRun = run
    deletingProfile = access.id
    error = nil
    deletionTask = Task { @MainActor in
      defer {
        if deletionRun == run {
          deletingProfile = nil
          deletionTask = nil
        }
      }
      do {
        try await model.currentAdministration { try await client.deleteProfile(id: access.id) }
        guard deletionRun == run, model.isCurrentAdministration(generation), !Task.isCancelled
        else { return }
        model.didDeleteWatchingProfile(id: access.id)
        await reload()
      } catch is CancellationError {
      } catch {
        guard deletionRun == run, model.isCurrentAdministration(generation), !Task.isCancelled
        else { return }
        if let failure = error as? APIClientError, failure.isManagementLocked {
          do {
            let password = try AdministrationPasswordPrompt.confirm(
              serverName: model.profile?.name ?? "Aurelia")
            _ = await model.unlockManagement(password: password)
            delete(access)
            return
          } catch {
            self.error = error.localizedDescription
            return
          }
        }
        if let failure = error as? APIClientError, failure == .serverIdentityMismatch {
          model.handleAdministrationFailure(error, generation: generation)
        } else {
          self.error = error.localizedDescription
        }
      }
    }
  }

  @MainActor private func reload() async {
    guard let client else { return }
    let generation = model.administrationGeneration
    loading = true
    defer { loading = false }
    do {
      if part == .people {
        let accounts = try await model.currentAdministration { try await client.serverUsers() }
        guard model.isCurrentAdministration(generation), !Task.isCancelled else { return }
        users = accounts
        error = nil
        return
      }
      let loaded = try await model.currentAdministration {
        guard model.isCurrentAdministration(generation) else { throw CancellationError() }
        async let config = client.serverSettings()
        async let overview = client.serverStatus()
        async let accounts = client.serverUsers()
        async let abilities = client.serverCapabilities()
        async let healthOverview = client.serverHealth()
        return try await (config, overview, accounts, abilities, healthOverview)
      }
      guard model.isCurrentAdministration(generation), !Task.isCancelled else { return }
      (configuration, status, users, capabilities, health) = loaded
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
    GroupBox("Sign-In & Streaming Limits") {
      VStack(alignment: .leading, spacing: 12) {
        Stepper(
          "Keep new devices signed in for \(settings.deviceSessionDays) days",
          value: $settings.deviceSessionDays, in: 1...365)
        Stepper(
          "Streams at the same time: \(settings.globalStreamLimit) in total",
          value: $settings.globalStreamLimit, in: settings.userStreamLimit...128)
        Stepper(
          "Streams at the same time: \(settings.userStreamLimit) per profile",
          value: $settings.userStreamLimit, in: 1...min(16, settings.globalStreamLimit))
        Text(
          "Existing sessions keep their current expiry. New pairing codes expire after five minutes. Device revocation stops affected streams immediately."
        )
        .font(.caption).foregroundStyle(.secondary)
        if let error { Text(error).foregroundStyle(.red) }
        Button(saving ? "Saving…" : "Save Limits") {
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

/// Network access of a Linux server is set up there over SSH (`sudo aurelia setup`), not from a Mac.
private struct ServerLinuxNetworkBox: View {
  let configuration: ServerConfigurationResponse

  var body: some View {
    GroupBox("Network") {
      VStack(alignment: .leading, spacing: 10) {
        LabeledContent(
          "Home network access", value: configuration.active.lanAccessEnabled ? "On" : "Off")
        LabeledContent("Port", value: "\(configuration.active.lanHttpsPort)")
        Text(
          "A Linux server's network access is set up on the server itself with `sudo aurelia setup`."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }
  }
}
