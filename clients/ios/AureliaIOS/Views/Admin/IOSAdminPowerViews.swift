import SwiftUI

/// Settings › Power: what the server does when nobody uses Aurelia.
struct IOSAdminPowerView: View {
  var body: some View {
    IOSAdminLoader { try await $0.serverPower() } content: { power, _ in
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
        text: "What the server computer does when nobody uses Aurelia, and how devices wake it again.")
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
                Text(minutes < 60 ? "\(minutes) minutes" : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes) minutes")
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
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }.disabled(!changed || !power.available)
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
      Task { await admin.perform("Saving…") { _ = try await $0.saveServerPower(payload) } }
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

/// Settings › Server Updates: a Linux server installed from the package updates itself.
struct IOSAdminUpdatesView: View {
  var body: some View {
    IOSAdminLoader { try await $0.serverUpdates() } content: { status, reload in
      IOSAdminUpdatesForm(status: status, reload: reload)
    }
    .navigationTitle("Server Updates")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminUpdatesForm: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let status: IOSServerUpdateStatus
  let reload: () async -> Void
  @State private var confirmation: IOSAdminConfirmation?

  var body: some View {
    Form {
      IOSAdminPageHeader(
        page: .updates,
        text: "Install a newer Aurelia Server. Your library, profiles and settings stay as they are.")
      if !status.available {
        Section {
          Label(IOSUnavailableReason.updates, systemImage: "info.circle").foregroundStyle(.secondary)
        }
      }
      Section {
        LabeledContent("Installed", value: status.installed)
        LabeledContent("Newest", value: status.newest ?? "—")
        LabeledContent("Last Checked", value: IOSAdminFormat.relative(status.checkedAt))
        if status.state == "checking" || status.state == "installing" {
          ProgressView(status.state == "checking" ? "Checking…" : "Installing…")
        }
        if let message = status.message { Text(message).foregroundStyle(.secondary) }
      }
      Section {
        Button("Check for Updates") {
          Task { await admin.perform("Checking…") { _ = try await $0.checkServerUpdates() } }
        }
        .disabled(status.state != "idle" && status.state != "failed")
        if status.updateAvailable {
          Button("Install \(status.newest ?? "Update")…") {
            confirmation = IOSAdminConfirmation(
              title: "Install the update?",
              message: "The server restarts once it is installed. Playback stops for a moment.",
              action: "Install"
            ) {
              Task { await admin.perform("Starting the update…") { _ = try await $0.installServerUpdate() } }
            }
          }
          .disabled(status.state != "idle" && status.state != "failed")
        }
      } footer: {
        Text("Your library, profiles and settings stay as they are.")
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .refreshable { await reload() }
    .adminConfirmation($confirmation)
    .task(id: status.state) {
      guard status.state == "checking" || status.state == "installing" else { return }
      try? await Task.sleep(for: .seconds(3))
      await reload()
    }
  }
}

/// Settings › Danger Zone: resets the library catalog. Media files are never touched.
struct IOSAdminDangerZoneView: View {
  var body: some View {
    IOSAdminLoader { try await $0.libraries() } content: { libraries, _ in
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

  var body: some View {
    Form {
      Section {
        ForEach(libraries) { library in
          Toggle(isOn: Binding(
            get: { selected.contains(library.id) },
            set: { if $0 { selected.insert(library.id) } else { selected.remove(library.id) }; preview = nil }
          )) {
            VStack(alignment: .leading, spacing: 2) {
              Text(library.name)
              Text(library.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
          Task { preview = await admin.value("Counting…") { try await $0.previewReset(libraries: ids) } }
        }
        .disabled(selected.isEmpty)
        if let preview {
          LabeledContent("Titles", value: "\(preview.titles)")
          LabeledContent("Files", value: "\(preview.files)")
          LabeledContent("Pictures", value: "\(preview.artwork)")
          LabeledContent("Storage Locations", value: "\(preview.storageLocations)")
          TextField("Type RESET to confirm", text: $typed)
            .textInputAutocapitalization(.characters).autocorrectionDisabled()
          Button("Reset Library", role: .destructive) {
            let chosen = preview
            Task {
              if var mutation = await admin.value("Resetting…", { try await $0.resetLibrary(chosen) }) {
                // A large reset finishes in the background; follow it until it is done.
                while mutation.state == "queued" || mutation.state == "running" {
                  result = "Removing… \(mutation.removedItems) titles so far."
                  try? await Task.sleep(for: .seconds(2))
                  let id = mutation.id
                  guard let next = try? await admin.run({ try await $0.libraryMutation(id: id) }) else { break }
                  mutation = next
                }
                result =
                  mutation.error.map { "The reset stopped: \($0)" }
                  ?? "Removed \(mutation.removedItems) titles. The video files are unchanged."
                self.preview = nil
                typed = ""
                selected = []
              }
            }
          }
          .disabled(typed != "RESET")
        }
      }
      if let result { Section { Text(result) } }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
  }
}
