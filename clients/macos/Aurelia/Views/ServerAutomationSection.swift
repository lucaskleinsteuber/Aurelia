import AppIntents
import AppKit
import SwiftUI

/// Settings › Smart Home for the owner ("automation-v1"): webhooks for Home Assistant and other
/// receivers, keys for Home Assistant and shortcuts, and turning the server on and off.
struct ServerAutomationSection: View {
  @EnvironmentObject private var model: AppModel
  @State private var overview: AutomationOverview?
  @State private var message: String?
  @State private var working = false
  @State private var editing: WebhookEditorTarget?
  @State private var deliveriesFor: AutomationWebhook?
  @State private var creatingToken = false
  @State private var shownSecret: ShownSecret?
  @State private var shownToken: String?
  @State private var confirmation: Confirmation?
  @State private var siriReady = false

  struct WebhookEditorTarget: Identifiable {
    let id = UUID()
    let webhook: AutomationWebhook?
  }

  struct ShownSecret: Identifiable {
    let id = UUID()
    let secret: String
    let webhook: AutomationWebhook
  }

  struct Confirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: String
    let perform: () -> Void
  }

  private var client: APIClient? { model.profile.map(APIClient.init(profile:)) }

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      AureliaSettingsSection(
        "Smart Home", symbol: "house",
        description:
          "Aurelia tells Home Assistant and other automations the moment a movie starts, pauses or ends, or a new title arrives, so lights and scenes can follow. Home Assistant can also wake the server and turn it off."
      ) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Webhooks").font(.headline)
          Text("Each webhook gets the events you choose, signed so the receiver can check they came from your server.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          if let overview {
            if overview.webhooks.isEmpty {
              Text(
                "No webhooks yet. In Home Assistant create an automation with a Webhook trigger, then add it here with its ID."
              )
              .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(overview.webhooks) { webhookRow($0, overview: overview) }
            Button("Add Webhook…") { editing = WebhookEditorTarget(webhook: nil) }
              .accessibilityIdentifier("automation-add-webhook")
          } else {
            ProgressView().controlSize(.small)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      AureliaSettingsSection(
        "Keys for Home Assistant and Shortcuts", symbol: "key",
        description:
          "For the other direction: Home Assistant reads what plays, or turns the server off, with a key you create here."
      ) {
        VStack(alignment: .leading, spacing: 10) {
          if let overview {
            if overview.tokens.isEmpty {
              Text("No keys yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(overview.tokens) { token in
              HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(token.name)
                  Text(
                    token.scopes.map { scope in AutomationText.scopes.first { $0.id == scope }?.title ?? scope }
                      .joined(separator: ", ") + " · last used " + Self.when(token.lastUsedAt)
                  )
                  .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Remove…", role: .destructive) {
                  confirmation = Confirmation(
                    title: "Remove the key “\(token.name)”?", message: "Whatever uses it stops working at once.",
                    action: "Remove"
                  ) { Task { await run { try await $0.revokeIntegrationToken(id: token.id) } } }
                }
              }
            }
            Button("Create Key…") { creatingToken = true }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      siriSection
      AureliaSettingsSection(
        "Turning the Server On and Off", symbol: "power",
        description:
          "Home Assistant and every Aurelia app start the server with Wake-on-LAN, using the network card's address below."
      ) {
        VStack(alignment: .leading, spacing: 10) {
          if let overview {
            LabeledContent("Network Card") {
              Text(overview.wakeOnLanAddresses.isEmpty ? "Not reported" : overview.wakeOnLanAddresses.joined(separator: ", "))
                .textSelection(.enabled)
            }
            Text(
              overview.wakeOnLanAddresses.isEmpty
                ? "This server doesn't report a network card that can be woken, for example when it runs in an app or a container."
                : "For Home Assistant's Wake on LAN integration (wake_on_lan.send_magic_packet) use this MAC address."
            )
            .font(.caption).foregroundStyle(.secondary)
            if overview.powerActions.isEmpty {
              Text("This server can't turn itself off; it runs as a service that something else starts and stops.")
                .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
              ForEach(overview.powerActions, id: \.self) { action in
                Button(AutomationText.powerTitle(action)) {
                  confirmation = Confirmation(
                    title: "\(AutomationText.powerTitle(action))?", message: AutomationText.powerDetail(action),
                    action: AutomationText.powerTitle(action)
                  ) { Task { await powerNow(action, force: false) } }
                }
                .help(AutomationText.powerDetail(action))
              }
            }
          }
          if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .disabled(working)
    .onAppear { siriReady = model.profile.map { SiriKeyStore().load(server: $0.serverId) != nil } ?? false }
    .task(id: model.administrationGeneration) { await reload() }
    .sheet(item: $editing) { target in
      if let overview, let client {
        AutomationWebhookEditor(client: client, overview: overview, webhook: target.webhook) { created in
          editing = nil
          if let created { shownSecret = ShownSecret(secret: created.secret, webhook: created.webhook) }
          Task { await reload() }
        }
      }
    }
    .sheet(item: $deliveriesFor) { webhook in
      if let client { AutomationDeliveriesSheet(client: client, webhook: webhook) }
    }
    .sheet(isPresented: $creatingToken) {
      if let client {
        IntegrationTokenSheet(client: client) { value in
          creatingToken = false
          shownToken = value
          Task { await reload() }
        }
      }
    }
    .sheet(item: $shownSecret) { shown in AutomationSecretSheet(secret: shown.secret, webhook: shown.webhook) }
    .sheet(isPresented: Binding(get: { shownToken != nil }, set: { if !$0 { shownToken = nil } })) {
      AutomationValueSheet(
        title: "Key Created",
        explanation: "Copy the key now: it is shown only once. Aurelia keeps only a fingerprint of it. Send it as “Authorization: Bearer <key>”.",
        value: shownToken ?? "")
    }
    .alert(
      confirmation?.title ?? "", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
      presenting: confirmation
    ) { item in
      Button(item.action, role: .destructive) { item.perform() }
      Button("Cancel", role: .cancel) {}
    } message: { item in
      Text(item.message)
    }
  }

  private var siriSection: some View {
    AureliaSettingsSection(
      "Siri on This Mac", symbol: "mic",
      description:
        "Siri can turn the server on and off, play a title on the Apple TV and say what plays, even when Aurelia is closed. It uses its own key, kept in this Mac's Keychain."
    ) {
      VStack(alignment: .leading, spacing: 8) {
        if siriReady {
          Label("Siri is set up on this Mac", systemImage: "checkmark.circle.fill")
          ForEach(
            ["Turn on my Aurelia server", "Play in Aurelia", "What's playing in Aurelia", "Turn off my Aurelia server"],
            id: \.self
          ) { phrase in
            Text("“\(phrase)”").font(.callout)
          }
          Text("“Play in Aurelia” asks what to play: say a movie or a show, with a season and episode if you like. Siri understands these phrases in English.")
            .font(.caption).foregroundStyle(.secondary)
          HStack {
            Button("Open Shortcuts") {
              if let url = URL(string: "shortcuts://") { NSWorkspace.shared.open(url) }
            }
            Button("Remove Siri from This Mac", role: .destructive) { Task { await removeSiri() } }
          }
        } else {
          Button("Set Up Siri") { Task { await setUpSiri() } }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func webhookRow(_ webhook: AutomationWebhook, overview: AutomationOverview) -> some View {
    let status = AutomationText.status(webhook)
    let events = webhook.events.map { kind in overview.events.first { $0.kind == kind }?.title ?? kind }
    return VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(webhook.name).font(.body.weight(.medium))
            Text(status.text).font(.caption2.weight(.semibold))
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(Capsule().fill(status.warning ? Color.orange.opacity(0.85) : Color.white.opacity(0.12)))
          }
          Text("\(AutomationText.host(webhook.url)) · \(events.joined(separator: ", "))")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          if let reason = webhook.pausedReason { Text(reason).font(.caption).foregroundStyle(.orange) }
        }
        Spacer()
      }
      HStack {
        Button("Send Test") { Task { await test(webhook) } }
        Button("Deliveries…") { deliveriesFor = webhook }
        Button("Edit…") { editing = WebhookEditorTarget(webhook: webhook) }
        Button("New Secret…") {
          Task {
            if let result = await run({ try await $0.rotateWebhookSecret(id: webhook.id) }) {
              shownSecret = ShownSecret(secret: result.secret, webhook: webhook)
            }
          }
        }
        Spacer()
        Button("Remove…", role: .destructive) {
          confirmation = Confirmation(
            title: "Remove “\(webhook.name)”?", message: "It stops getting events at once. Your automation in Home Assistant stays.",
            action: "Remove"
          ) { Task { await run { try await $0.deleteWebhook(id: webhook.id) } } }
        }
      }
      .controlSize(.small)
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
  }

  private var siriKeyName: String { "Siri on \(Host.current().localizedName ?? "Mac")" }

  private func setUpSiri() async {
    guard let server = model.profile?.serverId else { return }
    let name = siriKeyName
    guard let created = await run({ try await $0.createIntegrationToken(name: name, scopes: ["status", "power", "playback"]) })
    else { return }
    do {
      try SiriKeyStore().save(created.value, server: server)
      siriReady = true
      AureliaShortcuts.updateAppShortcutParameters()
    } catch {
      message = "This Mac couldn't keep the key. Try again."
    }
  }

  private func removeSiri() async {
    guard let server = model.profile?.serverId else { return }
    SiriKeyStore().delete(server: server)
    siriReady = false
    if let token = overview?.tokens.first(where: { $0.name == siriKeyName }) {
      await run { try await $0.revokeIntegrationToken(id: token.id) }
    }
  }

  private func test(_ webhook: AutomationWebhook) async {
    guard let delivery = await run({ try await $0.testWebhook(id: webhook.id) }) else { return }
    message =
      delivery.state == "succeeded"
      ? "“\(webhook.name)”: delivered in \(delivery.durationMilliseconds ?? 0) ms."
      : "“\(webhook.name)”: not delivered. \(delivery.error ?? "No answer.")"
  }

  private func powerNow(_ action: String, force: Bool) async {
    guard let client else { return }
    do {
      message = try await client.powerNow(action: action, force: force).message
    } catch let failure as APIClientError where failure.problemCode == "playback_active" {
      confirmation = Confirmation(
        title: "Someone is watching", message: "Turn it off anyway? Their playback stops.",
        action: AutomationText.powerTitle(action)
      ) { Task { await powerNow(action, force: true) } }
    } catch {
      message = error.localizedDescription
    }
  }

  private func reload() async {
    guard model.libraryCapabilities.contains("automation-v1"), let client else { return }
    do {
      overview = try await client.automationOverview()
    } catch let failure as APIClientError where failure.isManagementLocked {
      if await model.unlockManagementInteractively() { await reload() }
    } catch {
      message = error.localizedDescription
    }
  }

  @discardableResult
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

  static func when(_ text: String?) -> String {
    guard let text, let date = ISO8601DateFormatter.flexibleDate(text) else { return "never" }
    return date.formatted(.relative(presentation: .named))
  }
}

extension ISO8601DateFormatter {
  /// Parses the server's dates with or without fractions of a second.
  static func flexibleDate(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }
}

/// Adds or edits a webhook.
struct AutomationWebhookEditor: View {
  let client: APIClient
  let overview: AutomationOverview
  let webhook: AutomationWebhook?
  let done: (AutomationWebhookCreated?) -> Void
  @State private var name: String
  @State private var preset: String
  @State private var base: String
  @State private var webhookID: String
  @State private var url: String
  @State private var events: Set<String>
  @State private var devices: Set<UUID>
  @State private var profiles: Set<UUID>
  @State private var includeTitles: Bool
  @State private var excludeChildren: Bool
  @State private var enabled: Bool
  @State private var problem: String?
  @State private var saving = false

  init(client: APIClient, overview: AutomationOverview, webhook: AutomationWebhook?, done: @escaping (AutomationWebhookCreated?) -> Void) {
    self.client = client
    self.overview = overview
    self.webhook = webhook
    self.done = done
    let parts = AutomationText.splitHomeAssistantURL(webhook?.url ?? "")
    _name = State(initialValue: webhook?.name ?? "Home Assistant")
    _preset = State(initialValue: webhook?.preset ?? "homeAssistant")
    _base = State(initialValue: parts.base)
    _webhookID = State(initialValue: parts.webhookID)
    _url = State(initialValue: webhook?.url ?? "")
    _events = State(initialValue: Set(webhook?.events ?? [
      "playback.started", "playback.paused", "playback.resumed", "playback.stopped", "playback.finished",
    ]))
    _devices = State(initialValue: Set(webhook?.deviceIds ?? []))
    _profiles = State(initialValue: Set(webhook?.profileIds ?? []))
    _includeTitles = State(initialValue: webhook?.includeTitles ?? true)
    _excludeChildren = State(initialValue: webhook?.excludeChildren ?? false)
    _enabled = State(initialValue: webhook?.enabled ?? true)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Form {
        Section {
          Text("Aurelia sends an event the moment it happens, such as a movie starting on the living room TV, so lights or scenes can follow.")
            .font(.callout).foregroundStyle(.secondary)
          TextField("Name", text: $name)
          Picker("Receiver", selection: $preset) {
            Text("Home Assistant").tag("homeAssistant")
            Text("Other Receiver").tag("generic")
          }
          if preset == "homeAssistant" {
            TextField("Home Assistant Address", text: $base, prompt: Text("homeassistant.local:8123"))
            TextField("Webhook ID", text: $webhookID, prompt: Text("aurelia_movie_lights"))
            Text("The ID of the automation's Webhook trigger in Home Assistant. Letters, digits, - and _.")
              .font(.caption).foregroundStyle(.secondary)
          } else {
            TextField("Address", text: $url, prompt: Text("https://…"))
            Text("Receives a signed JSON POST for each event. Use https:// outside your home network.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        Section("Events") {
          ForEach(overview.events) { event in
            Toggle(isOn: binding(event.kind, in: $events)) {
              VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                Text(event.detail).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
        Section {
          DisclosureGroup("Only Some Devices or Profiles") {
            Text("With none chosen, events come from every device and profile.").font(.caption).foregroundStyle(.secondary)
            ForEach(overview.devices) { device in
              Toggle(device.detail.map { "\(device.name) · \($0)" } ?? device.name, isOn: binding(device.id, in: $devices))
            }
            Divider()
            ForEach(overview.profiles) { profile in
              Toggle(profile.detail.map { "\(profile.name) · \($0)" } ?? profile.name, isOn: binding(profile.id, in: $profiles))
            }
          }
        }
        Section("Privacy") {
          Toggle(isOn: $includeTitles) {
            VStack(alignment: .leading, spacing: 1) {
              Text("Send Titles and Profile Names")
              Text("Off sends only which device played, not what or who.").font(.caption).foregroundStyle(.secondary)
            }
          }
          Toggle(isOn: $excludeChildren) {
            VStack(alignment: .leading, spacing: 1) {
              Text("Leave Out Children's Profiles")
              Text("Nothing is sent while a children's profile watches.").font(.caption).foregroundStyle(.secondary)
            }
          }
          Toggle("On", isOn: $enabled)
        }
        if let problem { Section { Text(problem).foregroundStyle(.orange) } }
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
        Button(webhook == nil ? "Add Webhook" : "Save") { Task { await save() } }
          .keyboardShortcut(.defaultAction).disabled(saving)
      }
      .padding()
    }
    .frame(width: 560, height: 640)
  }

  private func binding<Value: Hashable>(_ value: Value, in set: Binding<Set<Value>>) -> Binding<Bool> {
    Binding(
      get: { set.wrappedValue.contains(value) },
      set: { on in if on { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) } })
  }

  private func save() async {
    let address = preset == "homeAssistant" ? AutomationText.homeAssistantURL(base: base, webhookID: webhookID) : url
    guard let address, !address.trimmingCharacters(in: .whitespaces).isEmpty else {
      problem = preset == "homeAssistant" ? "Enter Home Assistant's address and the webhook ID." : "Enter the address."
      return
    }
    guard !events.isEmpty else {
      problem = "Choose at least one event."
      return
    }
    let request = AutomationWebhookRequest(
      name: name.trimmingCharacters(in: .whitespaces), url: address, preset: preset,
      events: overview.events.map(\.kind).filter(events.contains), deviceIds: Array(devices),
      profileIds: Array(profiles), includeTitles: includeTitles, excludeChildren: excludeChildren, enabled: enabled)
    saving = true
    defer { saving = false }
    do {
      if let webhook {
        try await client.saveWebhook(id: webhook.id, request)
        done(nil)
      } else {
        done(try await client.createWebhook(request))
      }
    } catch {
      problem = error.localizedDescription
    }
  }
}

/// A new secret, shown once, with the example automation for Home Assistant.
struct AutomationSecretSheet: View {
  @Environment(\.dismiss) private var dismiss
  let secret: String
  let webhook: AutomationWebhook

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Webhook Saved").font(.title2.bold())
      Text("Every event carries a signature made with this secret (header X-Aurelia-Signature). Keep it if your receiver checks signatures; it is shown only now.")
        .fixedSize(horizontal: false, vertical: true)
      CopyableText(text: secret)
      if webhook.preset == "homeAssistant" {
        Text("Example Automation").font(.headline)
        Text("In Home Assistant: Settings › Automations › Create Automation › ⋯ › Edit in YAML, paste this and change the lights to yours.")
          .font(.caption).foregroundStyle(.secondary)
        CopyableText(text: AutomationText.homeAssistantExample(webhookID: AutomationText.splitHomeAssistantURL(webhook.url).webhookID))
      }
      HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
    }
    .padding(20)
    .frame(width: 560)
  }
}

struct AutomationValueSheet: View {
  @Environment(\.dismiss) private var dismiss
  let title: String
  let explanation: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.title2.bold())
      Text(explanation).fixedSize(horizontal: false, vertical: true)
      CopyableText(text: value)
      HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
    }
    .padding(20)
    .frame(width: 520)
  }
}

private struct CopyableText: View {
  let text: String
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ScrollView {
        Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 220)
      .padding(8)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
      Button(copied ? "Copied" : "Copy") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
      }
    }
  }
}

struct IntegrationTokenSheet: View {
  @Environment(\.dismiss) private var dismiss
  let client: APIClient
  let created: (String) -> Void
  @State private var name = "Home Assistant"
  @State private var scopes: Set<String> = ["status"]
  @State private var problem: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Create a Key").font(.title2.bold())
      Text("A key lets Home Assistant or a shortcut talk to Aurelia without a profile. It can do only what you allow here, and you can remove it any time.")
        .fixedSize(horizontal: false, vertical: true)
      TextField("Name", text: $name)
      ForEach(AutomationText.scopes, id: \.id) { scope in
        Toggle(isOn: Binding(
          get: { scopes.contains(scope.id) },
          set: { on in if on { scopes.insert(scope.id) } else { scopes.remove(scope.id) } })
        ) {
          VStack(alignment: .leading, spacing: 1) {
            Text(scope.title)
            Text(scope.detail).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      if let problem { Text(problem).foregroundStyle(.orange) }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Create Key") {
          Task {
            do {
              let result = try await client.createIntegrationToken(
                name: name.trimmingCharacters(in: .whitespaces), scopes: AutomationText.scopes.map(\.id).filter(scopes.contains))
              created(result.value)
            } catch {
              problem = error.localizedDescription
            }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || scopes.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 480)
  }
}

struct AutomationDeliveriesSheet: View {
  @Environment(\.dismiss) private var dismiss
  let client: APIClient
  let webhook: AutomationWebhook
  @State private var deliveries: [AutomationDelivery]?
  @State private var problem: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Deliveries of “\(webhook.name)”").font(.title2.bold())
      Text("The last 100 deliveries of the past seven days, with how long the receiver took. The events themselves are not kept.")
        .font(.callout).foregroundStyle(.secondary)
      List {
        if let deliveries, deliveries.isEmpty { Text("Nothing sent yet.").foregroundStyle(.secondary) }
        ForEach(deliveries ?? []) { delivery in
          VStack(alignment: .leading, spacing: 2) {
            Text(delivery.event)
            Text(
              [
                delivery.state == "succeeded" ? "Delivered" : delivery.state == "pending" ? "Trying again" : "Failed",
                delivery.statusCode.map { "HTTP \($0)" }, delivery.durationMilliseconds.map { "\($0) ms" },
                delivery.attempt > 1 ? "attempt \(delivery.attempt)" : nil, delivery.error,
                ServerAutomationSection.when(delivery.at),
              ].compactMap { $0 }.joined(separator: " · ")
            )
            .font(.caption).foregroundStyle(delivery.state == "succeeded" ? Color.secondary : Color.orange)
          }
        }
      }
      .frame(minHeight: 260)
      if let problem { Text(problem).foregroundStyle(.orange) }
      HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
    }
    .padding(20)
    .frame(width: 560, height: 480)
    .task {
      do { deliveries = try await client.webhookDeliveries(id: webhook.id) } catch { problem = error.localizedDescription }
    }
  }
}
