import SwiftUI

/// Settings › Power: what the server does when nobody uses Aurelia.
struct IOSAdminPowerView: View {
  var body: some View {
    IOSAdminLoader {
      try await $0.serverPower()
    } content: { power, _ in
      IOSAdminPowerForm(power: power)
    }
    .navigationTitle("Power")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminPowerForm: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let power: IOSServerPower
  @State private var draft: IOSServerPower
  @State private var awakeHours: Bool
  @State private var problem: String?
  @State private var saving = false

  init(power: IOSServerPower) {
    self.power = power
    _draft = State(initialValue: power)
    _awakeHours = State(initialValue: power.awakeFrom != nil && power.awakeUntil != nil)
  }

  private var modes: [IOSPowerMode] { IOSPowerRules.modes(for: power) }
  private var changed: Bool {
    draft != power || awakeHours != (power.awakeFrom != nil && power.awakeUntil != nil)
  }

  var body: some View {
    Form {
      IOSAdminPageHeader(
        page: .power,
        text:
          "What the server computer does when nobody uses Aurelia, and how devices wake it again.")
      if !power.available {
        Section {
          Label(IOSUnavailableReason.power(hosting: power.hosting), systemImage: "info.circle")
            .foregroundStyle(.secondary)
        }
      } else {
        Section {
          Picker("When Nobody Uses Aurelia", selection: $draft.mode) {
            ForEach(modes) { Text($0.label).tag($0.id) }
          }
          .pickerStyle(.inline)
          .labelsHidden()
        } header: {
          Text("When Nobody Uses Aurelia")
        } footer: {
          Text(modes.first { $0.id == draft.mode }?.explanation ?? "")
        }
        if draft.mode != "off" {
          Section {
            Picker("After", selection: $draft.idleMinutes) {
              ForEach(
                Array(Set(IOSPowerRules.idleChoices + [draft.idleMinutes])).sorted(), id: \.self
              ) { minutes in
                Text(
                  minutes < 60
                    ? "\(minutes) minutes"
                    : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes) minutes"
                )
                .tag(minutes)
              }
            }
            Toggle(
              "After a Sleep Timer Ends",
              isOn: Binding(
                get: { draft.afterSleepTimer ?? true }, set: { draft.afterSleepTimer = $0 }))
          } footer: {
            Text("With the sleep timer, the server powers down five minutes after it ended.")
          }
          if !IOSPowerRules.hostedByApp(power.hosting) {
            Section {
              Toggle("Stay Awake at Set Hours", isOn: $awakeHours)
                .onChange(of: awakeHours) { _, enabled in
                  if enabled { draft = IOSPowerRules.withDefaultAwakeHours(draft) }
                }
              if awakeHours {
                timePicker("From", text: $draft.awakeFrom, fallback: "07:00")
                timePicker("Until", text: $draft.awakeUntil, fallback: "23:00")
              }
            } footer: {
              Text("Within these hours the server keeps running even when nobody uses it.")
            }
          }
          if IOSPowerRules.offersWakeOnAccess(power, mode: draft.mode) {
            Section {
              Toggle(
                "Wake When a Device Connects",
                isOn: Binding(
                  get: { draft.wakeOnAccess ?? false }, set: { draft.wakeOnAccess = $0 }))
            } footer: {
              Text(
                "The network card wakes the computer when a device connects to it directly, a browser too. Your router may wake it now and then by mistake."
              )
            }
          }
        }
        if let check = IOSPowerRules.wakeCheck(power, mode: draft.mode) {
          Section {
            ForEach(check, id: \.title) { item in
              HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: Self.symbol(item.state))
                  .foregroundStyle(Self.color(item.state))
                  .accessibilityLabel(Self.label(item.state))
                VStack(alignment: .leading, spacing: 2) {
                  Text(item.title).fontWeight(.semibold)
                  Text(item.detail).font(.footnote).foregroundStyle(.secondary)
                }
              }
              .accessibilityElement(children: .combine)
            }
          } header: {
            Text("Wake-on-LAN Check")
          } footer: {
            Text(IOSPowerRules.wakeCheckFooter)
          }
        }
        if let problem { Section { Text(problem).foregroundStyle(.orange) } }
      }
      IOSAdminPowerNowSection()
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }.disabled(!changed || !power.available || saving)
      }
    }
  }

  static func symbol(_ state: IOSPowerRules.WakeCheckItem.State) -> String {
    switch state {
    case .ok: "checkmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .problem: "xmark.octagon.fill"
    case .info: "info.circle"
    }
  }

  static func color(_ state: IOSPowerRules.WakeCheckItem.State) -> Color {
    switch state {
    case .ok: .green
    case .warning: .orange
    case .problem: .red
    case .info: .secondary
    }
  }

  static func label(_ state: IOSPowerRules.WakeCheckItem.State) -> String {
    switch state {
    case .ok: "Fine"
    case .warning: "Check this"
    case .problem: "Problem"
    case .info: "Note"
    }
  }

  private func timePicker(_ label: String, text: Binding<String?>, fallback: String) -> some View {
    DatePicker(
      label,
      selection: Binding(
        get: { Self.date(text.wrappedValue ?? fallback) },
        set: { text.wrappedValue = Self.time($0) }),
      displayedComponents: .hourAndMinute)
  }

  private func save() {
    do {
      let payload = try IOSPowerRules.payload(for: draft, awakeHours: awakeHours, server: power)
      problem = nil
      guard !saving else { return }
      saving = true
      Task {
        defer { saving = false }
        await admin.perform("Saving…") { _ = try await $0.saveServerPower(payload) }
      }
    } catch {
      problem = error.localizedDescription
    }
  }

  static func date(_ time: String) -> Date {
    let parts = time.split(separator: ":").compactMap { Int($0) }
    var components = DateComponents()
    components.hour = parts.first ?? 0
    components.minute = parts.count > 1 ? parts[1] : 0
    return Calendar.current.date(from: components) ?? Date()
  }

  static func time(_ date: Date) -> String {
    let components = Calendar.current.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
  }
}

/// Settings › Power › Right Now for the owner: Sleep, Turn Off or Stop Now, without waiting for the
/// unused minutes ("power-now-v1").
private struct IOSAdminPowerNowSection: View {
  @EnvironmentObject private var model: IOSAppModel
  @EnvironmentObject private var admin: IOSAdministrationModel
  @State private var actions: [String]?
  @State private var problem: String?
  @State private var result: String?
  @State private var confirmation: IOSAdminConfirmation?

  private var capabilities: [String]? { model.capabilities?.capabilities }

  var body: some View {
    if admin.permissions.owner, IOSPowerNowText.isOffered(by: capabilities) {
      Section {
        if let actions {
          if actions.isEmpty {
            Text(
              "This server can't turn itself off; it runs as a service that something else starts and stops."
            )
            .font(.subheadline).foregroundStyle(.secondary)
          }
          ForEach(actions, id: \.self) { action in
            Button(role: action == "stop" ? nil : .destructive) {
              confirmation = IOSAdminConfirmation(
                title: "\(IOSPowerNowText.title(action))?",
                message: IOSPowerNowText.detail(action),
                action: IOSPowerNowText.title(action)
              ) { Task { await powerNow(action, force: false) } }
            } label: {
              IOSAdminToggleLabel(IOSPowerNowText.title(action), IOSPowerNowText.detail(action))
            }
          }
        } else if let problem {
          Text(problem).foregroundStyle(.orange)
          Button("Try Again") { Task { await load() } }
        } else {
          ProgressView()
        }
        if let result { Text(result).font(.footnote).foregroundStyle(.secondary) }
      } header: {
        Text("Right Now")
      } footer: {
        Text("Without waiting for the unused minutes.")
      }
      .task { await load() }
      .adminConfirmation($confirmation)
    }
  }

  private func load() async {
    let capabilities = capabilities
    do {
      actions = IOSPowerNowText.known(
        try await admin.run { try await $0.powerNowActions(capabilities: capabilities) })
      problem = nil
    } catch is CancellationError {
    } catch {
      problem = IOSAdministrationModel.message(error)
    }
  }

  private func powerNow(_ action: String, force: Bool) async {
    do {
      let answer = try await admin.run { try await $0.powerNow(action: action, force: force) }
      result = answer.message
    } catch let failure as IOSCoreError where failure.code == "playback_active" {
      confirmation = IOSAdminConfirmation(
        title: "Someone Is Watching", message: "Turn it off anyway? Their playback stops.",
        action: IOSPowerNowText.title(action)
      ) { Task { await powerNow(action, force: true) } }
    } catch is CancellationError {
    } catch {
      admin.alert = IOSAdministrationModel.message(error)
    }
  }
}

/// Settings › Server Updates: a Linux server installed from the package updates itself.
struct IOSAdminUpdatesView: View {
  var body: some View {
    IOSAdminLoader {
      try await $0.serverUpdates()
    } content: { status, reload in
      IOSAdminUpdatesForm(status: status, reload: reload)
    }
    .navigationTitle("Server Updates")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminUpdatesForm: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @Environment(\.scenePhase) private var scenePhase
  let status: IOSServerUpdateStatus
  let reload: @MainActor @Sendable () async -> Void
  @State private var confirmation: IOSAdminConfirmation?
  /// The newest status read while the server checks or installs.
  @State private var live: IOSServerUpdateStatus?
  /// The server restarts with the new version and does not answer for a moment.
  @State private var reconnecting = false

  private var shown: IOSServerUpdateStatus { live ?? status }
  private var idle: Bool { shown.state == "idle" || shown.state == "failed" }

  var body: some View {
    Form {
      IOSAdminPageHeader(
        page: .updates,
        text:
          "Install a newer Aurelia Server. Your library, profiles and settings stay as they are.")
      if !status.available {
        Section {
          Label(IOSUnavailableReason.updates, systemImage: "info.circle").foregroundStyle(
            .secondary)
        }
      }
      Section {
        LabeledContent("Installed", value: shown.installed)
        LabeledContent("Newest", value: shown.newest ?? "—")
        LabeledContent("Last Checked", value: IOSAdminFormat.relative(shown.checkedAt))
        if shown.isBusy || reconnecting {
          IOSServerUpdateProgressView(status: shown, reconnecting: reconnecting)
        }
        if let message = shown.message { Text(message).foregroundStyle(.secondary) }
      }
      if status.available {
        Section {
          Button("Check for Updates") {
            Task { await admin.perform("Checking…") { _ = try await $0.checkServerUpdates() } }
          }
          .disabled(!idle)
          if shown.updateAvailable {
            Button("Install \(shown.newest ?? "Update")…") {
              confirmation = IOSAdminConfirmation(
                title: "Install the update?",
                message: "The server restarts once it is installed. Playback stops for a moment.",
                action: "Install",
                isDestructive: false
              ) {
                Task {
                  await admin.perform("Starting the update…") {
                    _ = try await $0.installServerUpdate()
                  }
                }
              }
            }
            .disabled(!idle)
          }
        } footer: {
          Text("Your library, profiles and settings stay as they are.")
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .refreshable { await reload() }
    .adminConfirmation($confirmation)
    .onChange(of: status) { _, _ in live = nil }
    .task(id: status.isBusy && scenePhase == .active) { await follow() }
  }

  /// Reads the status every 1.5 seconds while the server checks or installs. While it restarts
  /// with the new version it does not answer; that is waiting, not an error. Once it is done the
  /// page loads again, now with the installed version.
  private func follow() async {
    guard status.isBusy, scenePhase == .active else { return }
    defer { reconnecting = false }
    while !Task.isCancelled {
      do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
      do {
        let read = try await IOSAPIClient.withBackgroundRequests {
          try await admin.run { try await $0.serverUpdates() }
        }
        reconnecting = false
        live = read
        if !read.isBusy {
          await reload()
          return
        }
      } catch is CancellationError {
        return
      } catch {
        reconnecting = true
      }
    }
  }
}

/// The bar with the current step and percentage while the server checks or installs.
private struct IOSServerUpdateProgressView: View {
  let status: IOSServerUpdateStatus
  let reconnecting: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let fraction = IOSServerUpdateProgress.fraction(status, reconnecting: reconnecting) {
        ProgressView(value: fraction)
      } else {
        ProgressView().progressViewStyle(.linear)
      }
      HStack(spacing: 8) {
        Text(IOSServerUpdateProgress.text(status, reconnecting: reconnecting))
          .font(.subheadline).foregroundStyle(.secondary)
        Spacer(minLength: 8)
        if let percent = IOSServerUpdateProgress.percent(status, reconnecting: reconnecting) {
          Text("\(percent)%").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("server-update-progress")
  }
}

/// Settings › Danger Zone: resets the library catalog. Media files are never touched.
struct IOSAdminDangerZoneView: View {
  var body: some View {
    IOSAdminLoader {
      try await $0.libraries()
    } content: { libraries, _ in
      IOSAdminResetForm(libraries: libraries)
    }
    .navigationTitle("Reset Library")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminResetForm: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let libraries: [IOSLibrarySummary]
  @State private var selected: Set<UUID> = []
  @State private var preview: IOSResetLibraryPreview?
  @State private var typed = ""
  @State private var result: String?
  @State private var resetting = false
  @State private var resetTask: Task<Void, Never>?

  var body: some View {
    Form {
      Section {
        if libraries.isEmpty {
          Text("No storage locations to reset.").foregroundStyle(.secondary)
        }
        ForEach(libraries) { library in
          Toggle(
            isOn: Binding(
              get: { selected.contains(library.id) },
              set: {
                if $0 { selected.insert(library.id) } else { selected.remove(library.id) }
                preview = nil
              }
            )
          ) {
            VStack(alignment: .leading, spacing: 2) {
              Text(library.name)
              Text(library.path).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            }
          }
        }
      } header: {
        Text("Reset Library")
      } footer: {
        Text(
          "Removes the chosen storage locations with their titles, watch history, favorites and artwork from Aurelia. The video files stay untouched where they are."
        )
      }
      Section {
        Button("Show What Would Be Removed") {
          let ids = libraries.map(\.id).filter(selected.contains)
          Task {
            let answer = await admin.value("Counting…") {
              try await $0.previewReset(libraries: ids)
            }
            guard selected == Set(ids), !Task.isCancelled else { return }
            preview = answer
          }
        }
        .disabled(selected.isEmpty)
        if let preview {
          LabeledContent("Titles", value: "\(preview.titles)")
          LabeledContent("Files", value: "\(preview.files)")
          LabeledContent("Pictures", value: "\(preview.artwork)")
          LabeledContent("Storage Locations", value: "\(preview.storageLocations)")
          TextField("Type RESET to confirm", text: $typed)
            .textInputAutocapitalization(.characters).autocorrectionDisabled()
          Button("Reset Library", role: .destructive) { reset(preview) }
            .disabled(typed != "RESET" || resetting)
        }
      }
      if let result { Section { Text(result) } }
    }
    .scrollDismissesKeyboard(.interactively)
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .onDisappear { resetTask?.cancel() }
  }

  private func reset(_ chosen: IOSResetLibraryPreview) {
    guard !resetting else { return }
    resetting = true
    resetTask = Task {
      defer { resetting = false }
      guard
        var mutation = await admin.value(
          "Resetting…", { try await $0.resetLibrary(chosen) })
      else { return }
      do {
        while mutation.state == "queued" || mutation.state == "running" {
          result =
            "Removing… \(IOSLayoutMetrics.countPhrase(mutation.removedItems, singular: "title", plural: "titles")) so far."
          try await Task.sleep(for: .seconds(2))
          let id = mutation.id
          mutation = try await admin.run { try await $0.background.libraryMutation(id: id) }
        }
        try Task.checkCancellation()
        result =
          mutation.error.map { "The reset stopped: \($0)" }
          ?? "Removed \(IOSLayoutMetrics.countPhrase(mutation.removedItems, singular: "title", plural: "titles")). The video files are unchanged."
        preview = nil
        typed = ""
        selected = []
      } catch is CancellationError {
        return
      } catch {
        result =
          "Couldn’t check the reset’s progress. It may still be running on the server. "
          + IOSAdministrationModel.message(error)
      }
    }
  }
}
