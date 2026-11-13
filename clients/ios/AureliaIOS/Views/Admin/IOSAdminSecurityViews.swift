import SwiftUI

/// Settings › Server Administration › Security: Face ID on this device, the devices signed in,
/// the block list and the security log. The owner sees everything; an administrator only sets
/// up Face ID for their own profile.
struct IOSAdminSecurityView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel

  struct Overview: Sendable {
    let settings: IOSSecuritySettings?
    let passkeys: [IOSPasskey]
    let devices: [IOSSecurityDevice]
    let blocked: [IOSBlockedDevice]
  }

  var body: some View {
    let owner = admin.permissions.owner
    IOSAdminLoader { client in
      async let passkeys = client.passkeys()
      async let settings = owner ? try? client.securitySettings() : nil
      async let devices = owner ? (try? client.securityDevices()) ?? [] : []
      async let blocked = owner ? (try? client.blockedDevices()) ?? [] : []
      return Overview(
        settings: await settings, passkeys: try await passkeys, devices: await devices, blocked: await blocked)
    } content: { overview, reload in
      IOSAdminSecurityContent(overview: overview, owner: owner, reload: reload)
    }
    .navigationTitle("Security")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminSecurityContent: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @EnvironmentObject private var model: IOSAppModel
  let overview: IOSAdminSecurityView.Overview
  let owner: Bool
  let reload: () async -> Void
  @State private var confirmation: IOSAdminConfirmation?
  @State private var logDays: Int?
  @State private var settingUp = false

  private var thisDeviceKey: IOSStoredPasskey? { admin.storedPasskey }
  private var biometry: String { IOSSecureEnclaveSigner.biometryName }

  var body: some View {
    Form {
      Section {
        if !IOSSecureEnclaveSigner.isAvailable {
          Text("This \(IOSDesign.deviceName) can't keep a Face ID or Touch ID key.")
            .foregroundStyle(.secondary)
        } else if let key = thisDeviceKey, overview.passkeys.contains(where: { $0.id == key.passkeyId }) {
          Label("\(biometry) is set up on this \(IOSDesign.deviceName)", systemImage: "checkmark.shield")
          Button("Remove from This \(IOSDesign.deviceName)…", role: .destructive) {
            confirmation = IOSAdminConfirmation(
              title: "Remove \(biometry)?",
              message: "This \(IOSDesign.deviceName) asks for the Server Password again.", action: "Remove"
            ) { remove(key.passkeyId) }
          }
        } else {
          Button {
            Task { await setUp() }
          } label: {
            Label("Set Up \(biometry)", systemImage: "faceid")
          }
          .disabled(settingUp)
        }
      } header: {
        Text(biometry)
      } footer: {
        Text(
          "\(biometry) confirms changes on your server instead of the Server Password. The key stays in this \(IOSDesign.deviceName)'s Secure Enclave; the server keeps only its public half. Setting it up asks once for the Server Password."
        )
      }
      if !overview.passkeys.isEmpty {
        Section("Keys") {
          ForEach(overview.passkeys) { passkey in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(passkey.name + (passkey.isThisDevice ? " (This \(IOSDesign.deviceName))" : ""))
                Text(
                  "\(passkey.userName) · added \(IOSAdminFormat.relative(passkey.createdAt))\(passkey.lastUsedAt.map { " · used \(IOSAdminFormat.relative($0))" } ?? "")"
                )
                .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button("Remove", role: .destructive) {
                confirmation = IOSAdminConfirmation(
                  title: "Remove “\(passkey.name)”?", message: "That device asks for the Server Password again.",
                  action: "Remove"
                ) { remove(passkey.id) }
              }
              .buttonStyle(.borderless)
            }
          }
        }
      }
      if owner, let settings = overview.settings {
        Section {
          Toggle(
            "Require Face ID or Touch ID",
            isOn: Binding(
              get: { settings.requirePasskeysForAdministrators },
              set: { value in save(logDays: logDays ?? settings.securityLogDays, require: value) }))
          Stepper(
            value: Binding(get: { logDays ?? settings.securityLogDays }, set: { logDays = $0 }), in: 30...365,
            step: 30
          ) {
            LabeledContent("Keep the Log", value: "\(logDays ?? settings.securityLogDays) days")
          }
          if let days = logDays, days != settings.securityLogDays {
            Button("Save") { save(logDays: days, require: settings.requirePasskeysForAdministrators) }
          }
        } header: {
          Text("Settings")
        } footer: {
          Text(
            "When required, the owner and administrators confirm with a key instead of the Server Password. A device without one asks a device with one; on the server computer itself the password still works, the way back if every key is lost."
          )
        }
        devicesSection
        if !overview.blocked.isEmpty {
          Section {
            ForEach(overview.blocked) { blocked in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(blocked.deviceName)
                  Text(
                    [IOSSecurityText.deviceLine(platform: blocked.platform, ipAddress: blocked.ipAddress), "blocked \(IOSAdminFormat.relative(blocked.blockedAt))"]
                      .filter { !$0.isEmpty }.joined(separator: " · ")
                  )
                  .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Unblock") {
                  let id = blocked.id
                  Task { await admin.perform("Unblocking…") { try await $0.unblockDevice(id: id) } }
                }
                .buttonStyle(.borderless)
              }
            }
          } header: {
            Text("Blocked Devices")
          } footer: {
            Text("A blocked device can't sign in or pair again until you unblock it.")
          }
        }
        Section {
          NavigationLink("Security Log") { IOSAdminSecurityLogView() }
        } footer: {
          Text("Who signed in when and from which device, failed attempts, and changes made by administrators.")
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .refreshable { await reload() }
    .adminConfirmation($confirmation)
  }

  @ViewBuilder private var devicesSection: some View {
    Section("Signed-In Devices") {
      ForEach(overview.devices) { device in
        IOSSecurityDeviceRow(device: device, onBlock: { confirmBlock(device) })
      }
    }
  }

  private func confirmBlock(_ device: IOSSecurityDevice) {
    confirmation = IOSAdminConfirmation(
      title: "Block “\(device.deviceName)”?",
      message: "It is signed out at once and can't sign in or pair again until you unblock it.",
      action: "Block"
    ) {
      let id = device.id
      Task { await admin.perform("Blocking…") { _ = try await $0.blockDevice(id: id) } }
    }
  }

  private func save(logDays: Int, require: Bool) {
    Task {
      if await admin.perform("Saving…", {
        _ = try await $0.saveSecuritySettings(logDays: logDays, requirePasskeys: require)
      }) {
        self.logDays = nil
      }
    }
  }

  private func remove(_ id: UUID) {
    Task {
      if await admin.perform("Removing…", { try await $0.removePasskey(id: id) }),
        thisDeviceKey?.passkeyId == id, let server = model.connection?.serverID,
        let profile = model.session?.user.id
      {
        IOSPasskeyStore.remove(server: server, profile: profile)
      }
    }
  }

  private func setUp() async {
    settingUp = true
    defer { settingUp = false }
    guard let server = model.connection?.serverID, let profile = model.session?.user.id else { return }
    let signer: IOSSecureEnclaveSigner
    do { signer = try IOSSecureEnclaveSigner.create() } catch {
      admin.alert = IOSAdministrationModel.message(error)
      return
    }
    let name = model.deviceName
    if let passkey = await admin.value("Setting up \(biometry)…", {
      try await $0.registerPasskey(name: name, signer: signer)
    }) {
      do {
        try IOSPasskeyStore.save(
          IOSStoredPasskey(passkeyId: passkey.id, keyReference: signer.keyReference, publicKey: signer.publicKey),
          server: server, profile: profile)
      } catch {
        admin.alert = IOSAdministrationModel.message(error)
      }
    }
  }
}

/// A device with its kind, address and when it was last seen, and Block unless it is this one.
struct IOSSecurityDeviceRow: View {
  let device: IOSSecurityDevice
  let onBlock: () -> Void

  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(device.deviceName + (device.isCurrent ? " (This \(IOSDesign.deviceName))" : ""))
          if device.isNew {
            Text("New").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
              .background(Capsule().fill(Color.orange.opacity(0.85)))
          }
        }
        let line = IOSSecurityText.deviceLine(platform: device.platform, ipAddress: device.ipAddress)
        if !line.isEmpty { Text(line).font(.caption).foregroundStyle(.secondary) }
        Text("\(device.userName) · last used \(IOSAdminFormat.relative(device.lastSeenAt))")
          .font(.caption2).foregroundStyle(.secondary)
      }
      Spacer()
      if device.canBlock {
        Button("Block", role: .destructive, action: onBlock).buttonStyle(.borderless)
      }
    }
  }
}

/// The security log, newest first, with a filter and Load More.
private struct IOSAdminSecurityLogView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @State private var filter = "all"
  @State private var events: [IOSSecurityEvent] = []
  @State private var before: String?
  @State private var loading = false

  var body: some View {
    List {
      Section {
        Picker("Show", selection: $filter) {
          Text("All").tag("all")
          Text("Sign-Ins").tag("succeeded")
          Text("Failed").tag("failed")
          Text("Changes").tag("changed")
        }
        .pickerStyle(.segmented)
      }
      Section {
        if events.isEmpty && !loading { Text("Nothing logged").foregroundStyle(.secondary) }
        ForEach(events) { event in
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: IOSSecurityText.symbol(event.outcome))
              .foregroundStyle(event.outcome == "failed" ? Color.orange : .secondary)
              .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
              Text(IOSSecurityText.kind(event.kind) + (event.detail.map { " · \($0)" } ?? ""))
              Text(
                [event.userName, event.deviceName, IOSSecurityText.deviceLine(platform: event.platform, ipAddress: event.ipAddress)]
                  .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
              )
              .font(.caption).foregroundStyle(.secondary)
              Text(IOSAdminFormat.date(event.at)).font(.caption2).foregroundStyle(.secondary)
            }
          }
        }
        if before != nil {
          Button("Load More") { Task { await load(more: true) } }.disabled(loading)
        }
        if loading { ProgressView() }
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle("Security Log")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load(more: false) }
    .task(id: filter) { await load(more: false) }
  }

  private func load(more: Bool) async {
    loading = true
    defer { loading = false }
    let outcome = filter == "all" ? nil : filter
    let cursor = more ? before : nil
    guard let page = await admin.value(nil, { try await $0.securityEvents(outcome: outcome, before: cursor) }) else {
      return
    }
    events = more ? events + page.events : page.events
    before = page.before
  }
}

/// Watches the server for new devices and unlock requests while Aurelia is open, and shows them
/// at the top of the screen: That was me / Block, and Confirm with Face ID / Deny.
@MainActor
final class IOSSecurityAlertCenter: ObservableObject {
  @Published private(set) var newDevices: [IOSSecurityDevice] = []
  @Published private(set) var unlockRequests: [IOSRemoteUnlockRequest] = []
  @Published var message: String?
  private var version: Int64 = 0
  private var task: Task<Void, Never>?
  private var dismissed: Set<UUID> = []

  func start(model: IOSAppModel) {
    task?.cancel()
    version = 0
    guard model.capabilities?.capabilities?.contains("security-v1") == true,
      IOSAdminPermissions(role: model.session?.user.role, accessMode: nil).administrator
    else {
      newDevices = []
      unlockRequests = []
      return
    }
    task = Task { [weak self, weak model] in
      var failures = 0
      while !Task.isCancelled {
        guard let self, let client = model?.client else { return }
        do {
          let alerts = try await client.securityAlerts(version: self.version, waitSeconds: self.version == 0 ? 0 : 25)
          self.version = alerts.version
          self.newDevices = alerts.newDevices.filter { !self.dismissed.contains($0.id) }
          self.unlockRequests = alerts.unlockRequests
          failures = 0
        } catch is CancellationError {
          return
        } catch {
          failures += 1
          try? await Task.sleep(for: .seconds(min(60, 5 * failures)))
        }
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }

  func acknowledge(_ device: IOSSecurityDevice, client: IOSAPIClient?) async {
    dismissed.insert(device.id)
    newDevices.removeAll { $0.id == device.id }
    try? await client?.acknowledgeDevice(id: device.id)
  }

  func block(_ device: IOSSecurityDevice, client: IOSAPIClient?) async {
    dismissed.insert(device.id)
    newDevices.removeAll { $0.id == device.id }
    do {
      _ = try await client?.blockDevice(id: device.id)
      message = "“\(device.deviceName)” is blocked and signed out."
    } catch {
      message = IOSAdministrationModel.message(error)
    }
  }

  func decide(_ request: IOSRemoteUnlockRequest, approve: Bool, model: IOSAppModel) async {
    guard let client = model.client, let server = model.connection?.serverID, let profile = model.session?.user.id
    else { return }
    let stored = IOSPasskeyStore.load(server: server, profile: profile)
    do {
      try await client.decideRemoteUnlock(
        id: request.id, approve: approve, passkeyId: stored?.passkeyId, signer: stored?.signer)
      unlockRequests.removeAll { $0.id == request.id }
      message = approve ? "“\(request.deviceName)” may manage the server for ten minutes." : nil
    } catch {
      message = IOSAdministrationModel.message(error)
    }
  }
}

/// The banner over every screen.
struct IOSSecurityAlertBanner: View {
  @EnvironmentObject private var model: IOSAppModel
  @ObservedObject var center: IOSSecurityAlertCenter

  var body: some View {
    VStack(spacing: 8) {
      ForEach(center.unlockRequests) { request in
        card {
          Label(
            "\(request.deviceName) asks to manage the server as \(request.profileName). It shows the code \(request.code).",
            systemImage: "lock.open")
          HStack {
            Button("Deny") { Task { await center.decide(request, approve: false, model: model) } }
              .buttonStyle(IOSButtonStyle(kind: .secondary))
            Button("Confirm with \(IOSSecureEnclaveSigner.biometryName)") {
              Task { await center.decide(request, approve: true, model: model) }
            }
            .buttonStyle(IOSButtonStyle(kind: .primary))
          }
        }
      }
      ForEach(center.newDevices.prefix(2)) { device in
        card {
          Label(
            "New device signed in: \(device.deviceName)\(IOSSecurityText.deviceLine(platform: device.platform, ipAddress: device.ipAddress).isEmpty ? "" : " · " + IOSSecurityText.deviceLine(platform: device.platform, ipAddress: device.ipAddress)) · \(IOSAdminFormat.date(device.createdAt))",
            systemImage: "exclamationmark.shield")
          HStack {
            Button("Block") { Task { await center.block(device, client: model.client) } }
              .buttonStyle(IOSButtonStyle(kind: .secondary))
            Button("That Was Me") { Task { await center.acknowledge(device, client: model.client) } }
              .buttonStyle(IOSButtonStyle(kind: .primary))
          }
        }
      }
      if let message = center.message {
        card {
          Text(message)
          Button("OK") { center.message = nil }.buttonStyle(IOSButtonStyle(kind: .secondary))
        }
      }
    }
    .padding(.horizontal, IOSDesign.margin)
    .animation(.easeOut(duration: 0.2), value: center.newDevices)
    .animation(.easeOut(duration: 0.2), value: center.unlockRequests)
  }

  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) { content() }
      .font(.subheadline)
      .padding(14)
      .frame(maxWidth: 560, alignment: .leading)
      .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
      .accessibilityElement(children: .contain)
  }
}
