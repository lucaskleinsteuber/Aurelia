import SwiftUI
import UserNotifications

/// Settings › Profiles and Devices › Security: Touch ID on this Mac, signed-in devices with Block,
/// the block list, the owner's security settings and the security log ("security-v1").
struct ServerSecuritySection: View {
  @EnvironmentObject private var model: AppModel
  @State private var passkeys: [ServerPasskey] = []
  @State private var settings: ServerSecuritySettings?
  @State private var devices: [ServerSecurityDevice] = []
  @State private var blocked: [ServerBlockedDevice] = []
  @State private var logDays: Int?
  @State private var message: String?
  @State private var working = false
  @State private var showsLog = false

  private var client: APIClient? { model.profile.map(APIClient.init(profile:)) }
  private var owner: Bool { model.profile?.user?.role == .owner }

  var body: some View {
    if model.libraryCapabilities.contains("security-v1"), model.profile?.user?.role.canManageLibraries == true {
      AureliaSettingsSection(
        "Security", symbol: "lock.shield",
        description:
          "Touch ID confirms changes instead of the Server Password. The log shows who signed in when and from which device, failed attempts and changes."
      ) {
        VStack(alignment: .leading, spacing: 16) {
          touchID
          if owner, let settings { settingsRows(settings) }
          if owner { devicesRows }
          if owner && !blocked.isEmpty { blockedRows }
          if owner {
            Button("Show Security Log…") { showsLog = true }
          }
          if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(working)
      }
      .task(id: model.administrationGeneration) { await reload() }
      .sheet(isPresented: $showsLog) {
        if let client { SecurityLogSheet(client: client) }
      }
    }
  }

  @ViewBuilder private var touchID: some View {
    Text("Touch ID").font(.headline)
    if !SecureEnclavePasskeySigner.isAvailable {
      Text("This Mac can't keep a Touch ID key.").font(.callout).foregroundStyle(.secondary)
    } else if let key = model.storedPasskey, passkeys.contains(where: { $0.id == key.passkeyId }) {
      HStack {
        Label("Touch ID is set up on this Mac", systemImage: "checkmark.shield")
        Spacer()
        Button("Remove", role: .destructive) { Task { await remove(key.passkeyId) } }
      }
    } else {
      HStack {
        Text("Confirm changes with Touch ID instead of the Server Password. Setting it up asks once for the password.")
          .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button("Set Up Touch ID") { Task { await setUp() } }
      }
    }
    if passkeys.contains(where: { !$0.isThisDevice }) {
      ForEach(passkeys.filter { !$0.isThisDevice }) { passkey in
        HStack {
          VStack(alignment: .leading) {
            Text(passkey.name)
            Text("\(passkey.userName) · added \(ServerDateText.display(passkey.createdAt))")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Remove", role: .destructive) { Task { await remove(passkey.id) } }
        }
      }
    }
  }

  @ViewBuilder private func settingsRows(_ settings: ServerSecuritySettings) -> some View {
    Divider()
    Toggle(
      "Require Face ID or Touch ID for administrators",
      isOn: Binding(
        get: { settings.requirePasskeysForAdministrators },
        set: { value in Task { await save(logDays: logDays ?? settings.securityLogDays, require: value) } }))
    Text(
      "When required, devices without a key ask one with a key to confirm. On the server computer itself the Server Password still works, the way back if every key is lost."
    )
    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    HStack {
      Stepper(
        "Keep the log for \(logDays ?? settings.securityLogDays) days",
        value: Binding(get: { logDays ?? settings.securityLogDays }, set: { logDays = $0 }), in: 30...365, step: 30)
      if let days = logDays, days != settings.securityLogDays {
        Button("Save") { Task { await save(logDays: days, require: settings.requirePasskeysForAdministrators) } }
      }
    }
  }

  @ViewBuilder private var devicesRows: some View {
    Divider()
    Text("Signed-In Devices").font(.headline)
    ForEach(devices) { device in
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(device.deviceName + (device.isCurrent ? " (This Mac)" : ""))
            if device.isNew {
              Text("New").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.orange.opacity(0.85)))
            }
          }
          let line = SecurityText.deviceLine(platform: device.platform, ipAddress: device.ipAddress)
          if !line.isEmpty { Text(line).font(.caption).foregroundStyle(.secondary) }
          Text("\(device.userName) · last used \(ServerDateText.display(device.lastSeenAt))")
            .font(.caption2).foregroundStyle(.secondary)
        }
        Spacer()
        if device.isNew {
          Button("That Was Me") { Task { await acknowledge(device) } }
        }
        if device.canBlock {
          Button("Block…", role: .destructive) { Task { await block(device) } }
        }
      }
    }
  }

  @ViewBuilder private var blockedRows: some View {
    Divider()
    Text("Blocked Devices").font(.headline)
    ForEach(blocked) { device in
      HStack {
        VStack(alignment: .leading) {
          Text(device.deviceName)
          Text(
            [SecurityText.deviceLine(platform: device.platform, ipAddress: device.ipAddress), "blocked \(ServerDateText.display(device.blockedAt))"]
              .filter { !$0.isEmpty }.joined(separator: " · ")
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Unblock") { Task { await unblock(device) } }
      }
    }
  }

  private func reload() async {
    guard let client else { return }
    passkeys = (try? await client.passkeys()) ?? []
    guard owner else { return }
    settings = try? await client.securitySettings()
    devices = (try? await client.securityDevices()) ?? []
    blocked = (try? await client.blockedDevices()) ?? []
  }

  /// Runs a change; a locked server asks for Touch ID or the Server Password once.
  private func run<T: Sendable>(_ work: @escaping @Sendable (APIClient) async throws -> T) async -> T? {
    guard let client else { return nil }
    working = true
    defer { working = false }
    do {
      let value = try await work(client)
      await reload()
      return value
    } catch let failure as APIClientError where failure.isManagementLocked {
      guard await model.unlockManagementInteractively() else { return nil }
      return await run(work)
    } catch {
      message = error.localizedDescription
      return nil
    }
  }

  private func setUp() async {
    guard let profile = model.profile, let user = profile.user else { return }
    let signer: SecureEnclavePasskeySigner
    do { signer = try SecureEnclavePasskeySigner.create() } catch {
      message = error.localizedDescription
      return
    }
    let name = Host.current().localizedName ?? "Mac"
    if let created = await run({ try await $0.registerPasskey(name: name, signer: signer) }) {
      do {
        try PasskeyStore.save(
          StoredPasskey(passkeyId: created.id, keyReference: signer.keyReference, publicKey: signer.publicKey),
          server: profile.serverId, profile: user.id)
        message = "Touch ID is set up. Aurelia asks for it instead of the Server Password."
      } catch {
        message = error.localizedDescription
      }
      await reload()
    }
  }

  private func remove(_ id: UUID) async {
    let wasThisMac = model.storedPasskey?.passkeyId == id
    if await run({ try await $0.removePasskey(id: id) }) != nil, wasThisMac,
      let profile = model.profile, let user = profile.user
    {
      PasskeyStore.remove(server: profile.serverId, profile: user.id)
      await reload()
    }
  }

  private func save(logDays: Int, require: Bool) async {
    if await run({ try await $0.saveSecuritySettings(logDays: logDays, requirePasskeys: require) }) != nil {
      self.logDays = nil
    }
  }

  private func acknowledge(_ device: ServerSecurityDevice) async {
    _ = await run({ try await $0.acknowledgeDevice(id: device.id) })
  }

  private func block(_ device: ServerSecurityDevice) async {
    let alert = NSAlert()
    alert.messageText = "Block “\(device.deviceName)”?"
    alert.informativeText = "It is signed out at once and can't sign in or pair again until you unblock it."
    alert.addButton(withTitle: "Block")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    _ = await run({ _ = try await $0.blockDevice(id: device.id) })
  }

  private func unblock(_ device: ServerBlockedDevice) async {
    _ = await run({ try await $0.unblockDevice(id: device.id) })
  }
}

/// The security log, newest first, with a filter and Load More.
struct SecurityLogSheet: View {
  let client: APIClient
  @Environment(\.dismiss) private var dismiss
  @State private var filter = "all"
  @State private var events: [ServerSecurityEvent] = []
  @State private var before: String?
  @State private var loading = false
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Security Log").font(.title2.bold())
        Spacer()
        Picker("Show", selection: $filter) {
          Text("All").tag("all")
          Text("Sign-Ins").tag("succeeded")
          Text("Failed").tag("failed")
          Text("Changes").tag("changed")
        }
        .pickerStyle(.segmented)
        .frame(width: 320)
      }
      List {
        ForEach(events) { event in
          HStack(alignment: .top, spacing: 10) {
            Image(
              systemName: event.outcome == "failed"
                ? "exclamationmark.triangle.fill" : event.outcome == "succeeded" ? "person.badge.key" : "slider.horizontal.3"
            )
            .foregroundStyle(event.outcome == "failed" ? Color.orange : .secondary)
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
              Text(SecurityText.kind(event.kind) + (event.detail.map { " · \($0)" } ?? ""))
              Text(
                [event.userName, event.deviceName, SecurityText.deviceLine(platform: event.platform, ipAddress: event.ipAddress)]
                  .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
              )
              .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ServerDateText.display(event.at)).font(.caption).foregroundStyle(.secondary)
          }
        }
        if before != nil {
          Button("Load More") { Task { await load(more: true) } }.disabled(loading)
        }
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 720, minHeight: 520)
    .task(id: filter) { await load(more: false) }
  }

  private func load(more: Bool) async {
    loading = true
    defer { loading = false }
    do {
      let page = try await client.securityEvents(outcome: filter == "all" ? nil : filter, before: more ? before : nil)
      events = more ? events + page.events : page.events
      before = page.before
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// Watches the server for new devices and unlock requests while Aurelia runs, shows them over the
/// window and as a notification: That Was Me / Block, and Confirm with Touch ID / Deny.
@MainActor
final class SecurityAlertCenter: ObservableObject {
  @Published private(set) var newDevices: [ServerSecurityDevice] = []
  @Published private(set) var unlockRequests: [ServerRemoteUnlockRequest] = []
  @Published var message: String?
  private var version: Int64 = 0
  private var task: Task<Void, Never>?
  private var notified: Set<UUID> = []
  private var dismissed: Set<UUID> = []
  private weak var model: AppModel?

  func start(model: AppModel) {
    task?.cancel()
    self.model = model
    version = 0
    newDevices = []
    unlockRequests = []
    guard model.libraryCapabilities.contains("security-v1"), let profile = model.profile, profile.isViewingSession,
      profile.user?.role.canManageLibraries == true
    else { return }
    task = Task { [weak self] in
      var failures = 0
      while !Task.isCancelled {
        guard let self, let profile = self.model?.profile else { return }
        do {
          let alerts = try await APIClient(profile: profile).securityAlerts(
            version: self.version, waitSeconds: self.version == 0 ? 0 : 25)
          self.version = alerts.version
          self.newDevices = alerts.newDevices.filter { !self.dismissed.contains($0.id) }
          self.unlockRequests = alerts.unlockRequests
          await self.notify()
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

  private func notify() async {
    guard SystemWishNotificationDeliverer.isAvailableInCurrentProcess, NSApp?.isActive != true else { return }
    let deliverer = SystemWishNotificationDeliverer()
    let status = await deliverer.authorizationStatus()
    guard status == .authorized || status == .provisional else { return }
    for device in newDevices where notified.insert(device.id).inserted {
      await deliverer.post(
        identifier: "aurelia.security.device.\(device.id.uuidString)", title: "New device signed in",
        body: [device.deviceName, SecurityText.deviceLine(platform: device.platform, ipAddress: device.ipAddress)]
          .filter { !$0.isEmpty }.joined(separator: " · "), category: "aurelia.security")
    }
    for request in unlockRequests where notified.insert(request.id).inserted {
      await deliverer.post(
        identifier: "aurelia.security.unlock.\(request.id.uuidString)", title: "Confirm a server change",
        body: "\(request.deviceName) asks to manage the server. Code \(request.code).", category: "aurelia.security")
    }
  }

  func acknowledge(_ device: ServerSecurityDevice) async {
    dismissed.insert(device.id)
    newDevices.removeAll { $0.id == device.id }
    guard let profile = model?.profile else { return }
    try? await APIClient(profile: profile).acknowledgeDevice(id: device.id)
  }

  func block(_ device: ServerSecurityDevice) async {
    dismissed.insert(device.id)
    newDevices.removeAll { $0.id == device.id }
    guard let profile = model?.profile else { return }
    do {
      _ = try await APIClient(profile: profile).blockDevice(id: device.id)
      message = "“\(device.deviceName)” is blocked and signed out."
    } catch {
      message = error.localizedDescription
    }
  }

  func decide(_ request: ServerRemoteUnlockRequest, approve: Bool) async {
    guard let model, let profile = model.profile else { return }
    let stored = model.storedPasskey
    do {
      try await APIClient(profile: profile).decideRemoteUnlock(
        id: request.id, approve: approve, passkeyId: stored?.passkeyId, signer: stored?.signer)
      unlockRequests.removeAll { $0.id == request.id }
      message = approve ? "“\(request.deviceName)” may manage the server for ten minutes." : nil
    } catch {
      message = error.localizedDescription
    }
  }
}

/// The banner at the top of the window.
struct SecurityAlertBanner: View {
  @ObservedObject var center: SecurityAlertCenter

  var body: some View {
    VStack(spacing: 8) {
      ForEach(center.unlockRequests) { request in
        card {
          Label(
            "\(request.deviceName) asks to manage the server as \(request.profileName). It shows the code \(request.code).",
            systemImage: "lock.open")
          HStack {
            Spacer()
            Button("Deny") { Task { await center.decide(request, approve: false) } }
            Button("Confirm with Touch ID") { Task { await center.decide(request, approve: true) } }
              .keyboardShortcut(.defaultAction)
          }
        }
      }
      ForEach(center.newDevices.prefix(2)) { device in
        card {
          Label(
            "New device signed in: \(device.deviceName)\(SecurityText.deviceLine(platform: device.platform, ipAddress: device.ipAddress).isEmpty ? "" : " · " + SecurityText.deviceLine(platform: device.platform, ipAddress: device.ipAddress)) · \(ServerDateText.display(device.createdAt))",
            systemImage: "exclamationmark.shield")
          HStack {
            Spacer()
            Button("Block…", role: .destructive) {
              let alert = NSAlert()
              alert.messageText = "Block “\(device.deviceName)”?"
              alert.informativeText = "It is signed out at once and can't sign in or pair again until you unblock it."
              alert.addButton(withTitle: "Block")
              alert.addButton(withTitle: "Cancel")
              if alert.runModal() == .alertFirstButtonReturn { Task { await center.block(device) } }
            }
            Button("That Was Me") { Task { await center.acknowledge(device) } }
          }
        }
      }
      if let message = center.message {
        card {
          HStack {
            Text(message)
            Spacer()
            Button("OK") { center.message = nil }
          }
        }
      }
    }
    .frame(maxWidth: 560)
    .padding(.top, 12)
  }

  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) { content() }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
  }
}
