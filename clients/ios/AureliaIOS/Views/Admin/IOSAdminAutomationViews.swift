import SwiftUI
import UIKit

/// Settings › Smart Home for the owner ("automation-v1"): webhooks for Home Assistant and other
/// receivers, keys for Home Assistant and shortcuts, and turning the server on and off.
struct IOSAdminAutomationView: View {
  var body: some View {
    IOSAdminLoader { try await $0.automationOverview() } content: { overview, reload in
      IOSAdminAutomationForm(overview: overview, reload: reload)
    }
    .navigationTitle("Smart Home")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminAutomationForm: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let overview: IOSAutomationOverview
  let reload: () async -> Void
  @State private var editing: EditorTarget?
  @State private var deliveriesFor: IOSAutomationWebhook?
  @State private var creatingToken = false
  @State private var shown: ShownValue?
  @State private var confirmation: IOSAdminConfirmation?
  @State private var result: String?

  struct EditorTarget: Identifiable {
    let id = UUID()
    let webhook: IOSAutomationWebhook?
  }

  struct ShownValue: Identifiable {
    let id = UUID()
    let title: String
    let explanation: String
    let value: String
    var example: String?
  }

  var body: some View {
    Form {
      IOSAdminPageHeader(
        page: .smartHome,
        text:
          "Aurelia tells Home Assistant and other automations the moment a movie starts, pauses or ends, or a new title arrives, so lights and scenes can follow. Home Assistant can also wake the server and turn it off.")
      Section {
        if overview.webhooks.isEmpty {
          Text("No webhooks yet. In Home Assistant create an automation with a Webhook trigger, then add it here with its ID.")
            .font(.subheadline).foregroundStyle(.secondary)
        }
        ForEach(overview.webhooks) { webhook in
          Button {
            editing = EditorTarget(webhook: webhook)
          } label: {
            webhookRow(webhook)
          }
          .swipeActions(edge: .trailing) {
            Button(role: .destructive) { confirmRemove(webhook) } label: { Label("Remove", systemImage: "trash") }
            Button { Task { await test(webhook) } } label: { Label("Test", systemImage: "paperplane") }.tint(.indigo)
          }
          .contextMenu {
            Button { Task { await test(webhook) } } label: { Label("Send Test", systemImage: "paperplane") }
            Button { deliveriesFor = webhook } label: { Label("Deliveries", systemImage: "list.bullet.rectangle") }
            Button { editing = EditorTarget(webhook: webhook) } label: { Label("Edit", systemImage: "pencil") }
            Button { Task { await rotate(webhook) } } label: { Label("New Secret", systemImage: "key") }
            Divider()
            Button(role: .destructive) { confirmRemove(webhook) } label: { Label("Remove…", systemImage: "trash") }
          }
        }
        Button {
          editing = EditorTarget(webhook: nil)
        } label: {
          Label("Add Webhook…", systemImage: "plus.circle.fill")
        }
        .accessibilityIdentifier("automation-add-webhook")
        if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
      } header: {
        Text("Webhooks")
      } footer: {
        Text("Each webhook gets the events you choose, signed so the receiver can check they came from your server. Touch and hold one for Test, Deliveries and New Secret.")
      }
      Section {
        if overview.tokens.isEmpty { Text("No keys yet.").foregroundStyle(.secondary) }
        ForEach(overview.tokens) { token in
          VStack(alignment: .leading, spacing: 2) {
            Text(token.name)
            Text(
              token.scopes.map { scope in IOSAutomationText.scopes.first { $0.id == scope }?.title ?? scope }
                .joined(separator: ", ") + " · last used " + IOSAdminFormat.relative(token.lastUsedAt)
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          .swipeActions {
            Button(role: .destructive) {
              confirmation = IOSAdminConfirmation(
                title: "Remove the key “\(token.name)”?", message: "Whatever uses it stops working at once.",
                action: "Remove"
              ) {
                let id = token.id
                Task { await admin.perform { try await $0.revokeIntegrationToken(id: id) } }
              }
            } label: {
              Label("Remove", systemImage: "trash")
            }
          }
        }
        Button {
          creatingToken = true
        } label: {
          Label("Create Key…", systemImage: "key")
        }
      } header: {
        Text("Keys for Home Assistant and Shortcuts")
      } footer: {
        Text("For the other direction: Home Assistant reads what plays, or turns the server off, with a key you create here. Swipe a key to remove it.")
      }
      Section {
        LabeledContent("Network Card") {
          Text(overview.wakeOnLanAddresses.isEmpty ? "Not reported" : overview.wakeOnLanAddresses.joined(separator: ", "))
            .textSelection(.enabled)
        }
        if overview.powerActions.isEmpty {
          Text("This server can't turn itself off; it runs as a service that something else starts and stops.")
            .font(.subheadline).foregroundStyle(.secondary)
        }
        ForEach(overview.powerActions, id: \.self) { action in
          Button(role: action == "stop" ? nil : .destructive) {
            confirmation = IOSAdminConfirmation(
              title: "\(IOSAutomationText.powerTitle(action))?", message: IOSAutomationText.powerDetail(action),
              action: IOSAutomationText.powerTitle(action)
            ) { Task { await powerNow(action, force: false) } }
          } label: {
            IOSAdminToggleLabel(IOSAutomationText.powerTitle(action), IOSAutomationText.powerDetail(action))
          }
        }
      } header: {
        Text("Turning the Server On and Off")
      } footer: {
        Text(
          overview.wakeOnLanAddresses.isEmpty
            ? "This server doesn't report a network card that can be woken, for example when it runs in an app or a container."
            : "Home Assistant's Wake on LAN integration (wake_on_lan.send_magic_packet) starts the server with this MAC address, as every Aurelia app does."
        )
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .refreshable { await reload() }
    .adminConfirmation($confirmation)
    .sheet(item: $editing) { target in
      NavigationStack {
        IOSWebhookEditor(overview: overview, webhook: target.webhook) { created in
          if let created {
            shown = ShownValue(
              title: "Webhook Saved",
              explanation: "Every event carries a signature made with this secret (header X-Aurelia-Signature). Keep it if your receiver checks signatures; it is shown only now.",
              value: created.secret,
              example: created.webhook.preset == "homeAssistant"
                ? IOSAutomationText.homeAssistantExample(
                  webhookID: IOSAutomationText.splitHomeAssistantURL(created.webhook.url).webhookID) : nil)
          }
        }
      }
    }
    .sheet(item: $deliveriesFor) { webhook in NavigationStack { IOSWebhookDeliveriesView(webhook: webhook) } }
    .sheet(isPresented: $creatingToken) {
      NavigationStack {
        IOSIntegrationTokenEditor { value in
          shown = ShownValue(
            title: "Key Created",
            explanation: "Copy the key now: it is shown only once. Aurelia keeps only a fingerprint of it. Send it as “Authorization: Bearer <key>”.",
            value: value)
        }
      }
    }
    .sheet(item: $shown) { value in NavigationStack { IOSShownValueView(value: value) } }
  }

  private func webhookRow(_ webhook: IOSAutomationWebhook) -> some View {
    let status = IOSAutomationText.status(webhook)
    let events = webhook.events.map { kind in overview.events.first { $0.kind == kind }?.title ?? kind }
    return VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(webhook.name).foregroundStyle(Color.primary)
        Text(status.text).font(.caption2.weight(.semibold))
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(Capsule().fill(status.warning ? Color.orange.opacity(0.85) : Color.white.opacity(0.12)))
          .foregroundStyle(Color.primary)
      }
      Text("\(IOSAutomationText.host(webhook.url)) · \(events.joined(separator: ", "))")
        .font(.caption).foregroundStyle(Color.secondary).lineLimit(2)
      if let reason = webhook.pausedReason { Text(reason).font(.caption).foregroundStyle(.orange) }
    }
  }

  private func confirmRemove(_ webhook: IOSAutomationWebhook) {
    confirmation = IOSAdminConfirmation(
      title: "Remove “\(webhook.name)”?", message: "It stops getting events at once. Your automation in Home Assistant stays.",
      action: "Remove"
    ) {
      let id = webhook.id
      Task { await admin.perform { try await $0.deleteWebhook(id: id) } }
    }
  }

  private func test(_ webhook: IOSAutomationWebhook) async {
    let id = webhook.id
    guard let delivery = await admin.value("Sending a test…", { try await $0.testWebhook(id: id) }) else { return }
    result =
      delivery.state == "succeeded"
      ? "“\(webhook.name)”: delivered in \(delivery.durationMilliseconds ?? 0) ms."
      : "“\(webhook.name)”: not delivered. \(delivery.error ?? "No answer.")"
  }

  private func rotate(_ webhook: IOSAutomationWebhook) async {
    let id = webhook.id
    guard let secret = await admin.value("Creating a new secret…", { try await $0.rotateWebhookSecret(id: id) }) else { return }
    shown = ShownValue(
      title: "New Secret", explanation: "The old secret no longer works. Give this one to your receiver if it checks signatures.",
      value: secret.secret)
  }

  private func powerNow(_ action: String, force: Bool) async {
    do {
      let answer = try await admin.run { try await $0.powerNow(action: action, force: force) }
      result = answer.message
    } catch let failure as IOSCoreError where failure.code == "playback_active" {
      confirmation = IOSAdminConfirmation(
        title: "Someone is watching", message: "Turn it off anyway? Their playback stops.",
        action: IOSAutomationText.powerTitle(action)
      ) { Task { await powerNow(action, force: true) } }
    } catch is CancellationError {
    } catch {
      admin.alert = IOSAdministrationModel.message(error)
    }
  }
}

/// Adds or edits a webhook.
private struct IOSWebhookEditor: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @Environment(\.dismiss) private var dismiss
  let overview: IOSAutomationOverview
  let webhook: IOSAutomationWebhook?
  let created: (IOSAutomationWebhookCreated?) -> Void
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

  init(overview: IOSAutomationOverview, webhook: IOSAutomationWebhook?, created: @escaping (IOSAutomationWebhookCreated?) -> Void) {
    self.overview = overview
    self.webhook = webhook
    self.created = created
    let parts = IOSAutomationText.splitHomeAssistantURL(webhook?.url ?? "")
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
    IOSAdminForm(title: webhook == nil ? "Add a Webhook" : "Edit Webhook") {
      Section {
        TextField("Name", text: $name)
        Picker("Receiver", selection: $preset) {
          Text("Home Assistant").tag("homeAssistant")
          Text("Other Receiver").tag("generic")
        }
        if preset == "homeAssistant" {
          TextField("homeassistant.local:8123", text: $base)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
          TextField("Webhook ID", text: $webhookID)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
        } else {
          TextField("https://…", text: $url)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        }
      } footer: {
        Text(
          preset == "homeAssistant"
            ? "Home Assistant's address as you open it in a browser, and the ID of the automation's Webhook trigger (letters, digits, - and _)."
            : "Receives a signed JSON POST for each event. Use https:// outside your home network.")
      }
      Section {
        ForEach(overview.events) { event in
          Toggle(isOn: binding(event.kind, in: $events)) {
            IOSAdminToggleLabel(event.title, event.detail)
          }
        }
      } header: {
        Text("Events")
      }
      Section {
        DisclosureGroup("Only Some Devices or Profiles") {
          ForEach(overview.devices) { device in
            Toggle(device.detail.map { "\(device.name) · \($0)" } ?? device.name, isOn: binding(device.id, in: $devices))
          }
          ForEach(overview.profiles) { profile in
            Toggle(profile.detail.map { "\(profile.name) · \($0)" } ?? profile.name, isOn: binding(profile.id, in: $profiles))
          }
        }
      } footer: {
        Text("With none chosen, events come from every device and profile.")
      }
      Section {
        Toggle(isOn: $includeTitles) {
          IOSAdminToggleLabel("Send Titles and Profile Names", "Off sends only which device played, not what or who.")
        }
        Toggle(isOn: $excludeChildren) {
          IOSAdminToggleLabel("Leave Out Children's Profiles", "Nothing is sent while a children's profile watches.")
        }
        Toggle("On", isOn: $enabled)
      } header: {
        Text("Privacy")
      }
      if let problem { Section { Text(problem).foregroundStyle(.orange) } }
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button(webhook == nil ? "Add" : "Save") { Task { await save() } }
      }
    }
  }

  private func binding<Value: Hashable>(_ value: Value, in set: Binding<Set<Value>>) -> Binding<Bool> {
    Binding(
      get: { set.wrappedValue.contains(value) },
      set: { on in if on { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) } })
  }

  private func save() async {
    let address = preset == "homeAssistant" ? IOSAutomationText.homeAssistantURL(base: base, webhookID: webhookID) : url
    guard let address, !address.trimmingCharacters(in: .whitespaces).isEmpty else {
      problem = preset == "homeAssistant" ? "Enter Home Assistant's address and the webhook ID." : "Enter the address."
      return
    }
    guard !events.isEmpty else {
      problem = "Choose at least one event."
      return
    }
    let request = IOSAutomationWebhookRequest(
      name: name.trimmingCharacters(in: .whitespaces), url: address, preset: preset,
      events: overview.events.map(\.kind).filter(events.contains), deviceIds: Array(devices),
      profileIds: Array(profiles), includeTitles: includeTitles, excludeChildren: excludeChildren, enabled: enabled)
    if let webhook {
      let id = webhook.id
      if await admin.perform("Saving…", { try await $0.saveWebhook(id: id, request) }) {
        created(nil)
        dismiss()
      }
    } else if let result = await admin.value("Adding…", { try await $0.createWebhook(request) }) {
      dismiss()
      created(result)
    }
  }
}

private struct IOSIntegrationTokenEditor: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @Environment(\.dismiss) private var dismiss
  let created: (String) -> Void
  @State private var name = "Home Assistant"
  @State private var scopes: Set<String> = ["status"]

  var body: some View {
    IOSAdminForm(title: "Create a Key") {
      Section {
        TextField("Name", text: $name)
      } footer: {
        Text("A key lets Home Assistant or a shortcut talk to Aurelia without a profile. It can do only what you allow below, and you can remove it any time.")
      }
      Section {
        ForEach(IOSAutomationText.scopes, id: \.id) { scope in
          Toggle(isOn: Binding(
            get: { scopes.contains(scope.id) },
            set: { on in if on { scopes.insert(scope.id) } else { scopes.remove(scope.id) } })
          ) {
            IOSAdminToggleLabel(scope.title, scope.detail)
          }
        }
      } header: {
        Text("What the Key May Do")
      }
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Create") {
          let (title, chosen) = (name.trimmingCharacters(in: .whitespaces), IOSAutomationText.scopes.map(\.id).filter(scopes.contains))
          Task {
            if let result = await admin.value("Creating the key…", { try await $0.createIntegrationToken(name: title, scopes: chosen) }) {
              dismiss()
              created(result.value)
            }
          }
        }
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || scopes.isEmpty)
      }
    }
  }
}

private struct IOSShownValueView: View {
  @Environment(\.dismiss) private var dismiss
  let value: IOSAdminAutomationForm.ShownValue
  @State private var copied = false

  var body: some View {
    IOSAdminForm(title: value.title) {
      Section {
        Text(value.value).font(.callout.monospaced()).textSelection(.enabled)
        Button(copied ? "Copied" : "Copy") {
          UIPasteboard.general.string = value.value
          copied = true
        }
      } footer: {
        Text(value.explanation)
      }
      if let example = value.example {
        Section {
          Text(example).font(.caption.monospaced()).textSelection(.enabled)
          Button("Copy Example") { UIPasteboard.general.string = example }
        } header: {
          Text("Example Automation")
        } footer: {
          Text("In Home Assistant: Settings › Automations › Create Automation › ⋮ › Edit in YAML, paste this and change the lights to yours.")
        }
      }
    }
    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
  }
}

private struct IOSWebhookDeliveriesView: View {
  @Environment(\.dismiss) private var dismiss
  let webhook: IOSAutomationWebhook

  var body: some View {
    IOSAdminLoader { [id = webhook.id] client in try await client.webhookDeliveries(id: id) } content: { deliveries, _ in
      Form {
        Section {
          if deliveries.isEmpty { Text("Nothing sent yet.").foregroundStyle(.secondary) }
          ForEach(deliveries) { delivery in
            VStack(alignment: .leading, spacing: 2) {
              Text(delivery.event)
              Text(
                [
                  delivery.state == "succeeded" ? "Delivered" : delivery.state == "pending" ? "Trying again" : "Failed",
                  delivery.statusCode.map { "HTTP \($0)" }, delivery.durationMilliseconds.map { "\($0) ms" },
                  delivery.attempt > 1 ? "attempt \(delivery.attempt)" : nil, delivery.error,
                  IOSAdminFormat.relative(delivery.at),
                ].compactMap { $0 }.joined(separator: " · ")
              )
              .font(.caption).foregroundStyle(delivery.state == "succeeded" ? Color.secondary : Color.orange)
            }
          }
        } footer: {
          Text("The last 100 deliveries of the past seven days, with how long the receiver took. The events themselves are not kept.")
        }
      }
      .scrollContentBackground(.hidden)
      .background(IOSDesign.canvas.ignoresSafeArea())
    }
    .navigationTitle(webhook.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
  }
}
