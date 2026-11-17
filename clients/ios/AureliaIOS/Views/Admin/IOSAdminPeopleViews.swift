import SwiftUI

/// Settings › Profiles and Devices: profiles of the household and the devices signed in.
struct IOSAdminPeopleView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel

  struct Overview: Sendable {
    let users: [IOSUserAccessSummary]
    let devices: [IOSDeviceSession]
    let configuration: IOSServerConfiguration?
  }

  var body: some View {
    let owner = admin.permissions.owner
    IOSAdminLoader { client in
      async let users = owner ? client.serverUsers() : []
      async let devices = client.ownDevices()
      async let configuration = owner ? client.serverSettings() : nil
      return Overview(
        users: try await users, devices: try await devices, configuration: try await configuration)
    } content: { overview, reload in
      IOSAdminPeopleContent(overview: overview, owner: owner, reload: reload)
    }
    .navigationTitle("Profiles and Devices")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminPeopleContent: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @EnvironmentObject private var model: IOSAppModel
  let overview: IOSAdminPeopleView.Overview
  let owner: Bool
  let reload: @MainActor @Sendable () async -> Void
  @State private var code: IOSPairingCode?
  @State private var enteringCode = false
  @State private var creating = false
  @State private var confirmation: IOSAdminConfirmation?

  var body: some View {
    Form {
      IOSAdminPageHeader(
        page: .people,
        text: owner
          ? "Everyone in your household has a profile with their own progress and favorites. Here you add people, set up children’s profiles and let new devices in."
          : "The devices signed in with your profile.")
      if owner {
        Section {
          ForEach(overview.users) { access in
            NavigationLink {
              IOSAdminProfileEditor(userID: access.user.id)
            } label: {
              HStack(spacing: 12) {
                IOSProfilePicture(
                  id: access.user.id, name: access.user.shownName, size: 36,
                  pictureKey: access.user.pictureKey,
                  pictureRevision: access.user.pictureRevision ?? 0)
                VStack(alignment: .leading, spacing: 2) {
                  Text(access.user.shownName)
                  Text(Self.detail(access)).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
          }
          Button {
            creating = true
          } label: {
            Label("Create Profile…", systemImage: "person.badge.plus")
          }
          .accessibilityIdentifier("admin-create-profile")
        } header: {
          Text("Profiles")
        } footer: {
          Text(
            "Tap a profile to change its name, PIN, age limit, screen time or what it may watch.")
        }
        Section {
          if let configuration = overview.configuration {
            IOSPolicyToggle(
              configuration: configuration, key: "pairingEnabled", label: "Allow New Devices",
              detail: "When off, no new device can connect, even with a code.")
          }
          Button {
            Task {
              code = await admin.value("Creating a code…") { try await $0.createPairingCode() }
            }
          } label: {
            Label("Create Code for a New Device", systemImage: "number")
          }
          if let code {
            IOSPairingCodeRow(code: code)
          }
          Button {
            enteringCode = true
          } label: {
            Label("Enter Code from a Device…", systemImage: "keyboard")
          }
        } header: {
          Text("Add a Device")
        } footer: {
          Text(
            "On the new device, choose this server and enter the code, or enter the code that device shows here. Codes last five minutes."
          )
        }
      }
      Section {
        NavigationLink {
          IOSAdminDevicesView()
        } label: {
          LabeledContent {
            Text("\(overview.devices.filter { $0.isActive() }.count)")
          } label: {
            IOSAdminToggleLabel(
              owner ? "Signed-In Devices" : "Your Devices",
              owner
                ? "Every device signed in, with Sign Out and Block."
                : "Sign out a device you no longer use.")
          }
        }
        .accessibilityIdentifier("admin-devices")
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .refreshable { await reload() }
    .adminConfirmation($confirmation)
    .sheet(isPresented: $enteringCode) { IOSDeviceApprovalSheet() }
    .sheet(isPresented: $creating) {
      NavigationStack { IOSAdminCreateProfileView() }
    }
  }

  static func detail(_ access: IOSUserAccessSummary) -> String {
    var parts = [access.user.roleTitle]
    if let limit = access.user.ageLimit { parts.append("FSK \(limit)") }
    parts.append(access.user.pinProtectionEnabled == false ? "No PIN" : "PIN")
    if access.user.accessMode == "selectedTitles" { parts.append("Chosen titles") }
    if !access.isEnabled { parts.append("Turned off") }
    return parts.joined(separator: " · ")
  }
}

/// A device in a list, with Sign Out unless it is this one.
private struct IOSDeviceRow: View {
  let device: IOSDeviceSession
  let signOut: () -> Void

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(device.deviceName + (device.isCurrent ? " (This \(IOSDesign.deviceName))" : ""))
        Text("Last used \(IOSAdminFormat.relative(device.lastSeenAt))")
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if !device.isCurrent {
        Button("Sign Out", role: .destructive, action: signOut).buttonStyle(.borderless)
      }
    }
  }
}

/// The 8-digit code with how long it stays valid.
private struct IOSPairingCodeRow: View {
  let code: IOSPairingCode

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let remaining = max(0, Int((code.expiryDate ?? .now).timeIntervalSince(context.date)))
      VStack(alignment: .leading, spacing: 4) {
        Text(Self.spaced(code.code)).font(.largeTitle.monospacedDigit().weight(.semibold))
          .textSelection(.enabled)
          .accessibilityLabel(code.code.map(String.init).joined(separator: " "))
        Text(
          remaining > 0
            ? "Valid for \(remaining / 60):\(String(format: "%02d", remaining % 60))" : "Expired"
        )
        .font(.caption).foregroundStyle(remaining > 0 ? .secondary : Color.orange)
      }
    }
  }

  static func spaced(_ code: String) -> String {
    code.count == 8 ? code.prefix(4) + " " + code.suffix(4) : code
  }
}

/// Enter the code another device shows, check which device it is, then allow or deny it.
private struct IOSDeviceApprovalSheet: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @Environment(\.dismiss) private var dismiss
  @StateObject private var approval = IOSDeviceApprovalModel()
  @State private var requestTask: Task<Void, Never>?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField(
            "8-digit code",
            text: Binding(
              get: { approval.code },
              set: { value in
                requestTask?.cancel()
                approval.code = value
              })
          )
          .keyboardType(.numberPad)
          .font(.title2.monospacedDigit())
          .disabled(approval.phase == .deciding)
          Button(action: lookUp) {
            HStack {
              Text(approval.phase == .lookingUp ? "Looking Up…" : "Look Up")
              if approval.phase == .lookingUp {
                Spacer()
                ProgressView()
              }
            }
          }
          .disabled(!approval.canLookUp)
          if let error = approval.error {
            Text(IOSAdministrationModel.message(error))
              .font(.footnote).foregroundStyle(.orange)
            if approval.preview == nil {
              Button("Try Again", action: lookUp).disabled(!approval.canLookUp)
            }
          }
        } footer: {
          Text("The device shows this code when you choose “Connect with a Code”.")
        }
        if let preview = approval.preview, approval.done == nil {
          Section("Device") {
            LabeledContent("Name", value: preview.deviceName)
            LabeledContent("Server", value: preview.serverName)
            Button("Allow “\(preview.deviceName)”") { decide(approve: true) }
              .disabled(approval.isWorking)
            Button("Deny", role: .destructive) { decide(approve: false) }
              .disabled(approval.isWorking)
            if approval.phase == .deciding { ProgressView("Confirming…") }
          }
        }
        if let done = approval.done { Section { Text(done) } }
      }
      .scrollContentBackground(.hidden)
      .background(IOSDesign.canvas.ignoresSafeArea())
      .navigationTitle("Enter Code")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
      }
    }
    .onDisappear {
      requestTask?.cancel()
      approval.invalidate()
    }
  }

  private func lookUp() {
    guard approval.canLookUp else { return }
    requestTask?.cancel()
    requestTask = Task {
      await approval.lookUp { typed in
        try await admin.run { try await $0.lookupDevicePairing(code: typed) }
      }
    }
  }

  private func decide(approve: Bool) {
    guard !approval.isWorking, approval.preview != nil, approval.done == nil else { return }
    requestTask?.cancel()
    requestTask = Task {
      await approval.decide(approve: approve) { id, approved in
        try await admin.runChange {
          _ = try await $0.decideDevicePairing(id: id, approve: approved)
        }
      }
    }
  }
}

/// A new profile: name, role, PIN, and whether it is a children's profile.
private struct IOSAdminCreateProfileView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var role = "user"
  @State private var protection = true
  @State private var pin = ""
  @State private var ageLimit: Int?
  @State private var picture: String?
  @State private var saving = false

  private var canSave: Bool {
    IOSProfileRules.isValidName(name)
      && IOSProfileRules.canSave(role: role, protection: protection, newPIN: pin, hasPIN: false)
  }

  var body: some View {
    IOSAdminForm(title: "New Profile") {
      Section {
        IOSAdminProfileIdentity(name: name, role: role, picture: picture)
        IOSAdminProfileNameField(name: $name)
        Picker("Role", selection: $role) {
          Text("Viewer").tag("user")
          Text("Administrator").tag("admin")
        }
        .onChange(of: role) { _, value in
          if value == "admin" {
            protection = true
            ageLimit = nil
          }
        }
      } footer: {
        Text("Administrators manage the library and metadata. Only you manage the server.")
      }
      Section("Picture") { IOSAdminPicturePicker(selection: $picture, name: name) }
      Section {
        Toggle("Protect with a PIN", isOn: $protection).disabled(role == "admin")
        if protection {
          SecureField("PIN (4 to 8 digits)", text: $pin).keyboardType(.numberPad)
          if let problem = IOSProfilePIN.problem(pin) {
            Text(problem).font(.caption).foregroundStyle(.orange)
          }
        }
      }
      if role == "user" {
        Section {
          Picker("Children’s Profile", selection: $ageLimit) {
            ForEach(IOSProfileRules.ageLimits, id: \.self) {
              Text(IOSProfileRules.ageTitle($0)).tag($0)
            }
          }
        } footer: {
          Text(
            "A children’s profile shows only titles rated up to this age. Set screen time after creating it."
          )
        }
      }
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Create") {
          guard !saving else { return }
          saving = true
          let request = IOSProfileCreateRequest(
            username: name.trimmingCharacters(in: .whitespacesAndNewlines), role: role,
            isEnabled: true, pinProtectionEnabled: protection, pin: protection ? pin : nil,
            accessMode: "entireLibrary", titleIds: nil, displayName: nil, pictureKey: picture,
            ageLimit: role == "user" ? ageLimit : nil)
          Task {
            defer { saving = false }
            if await admin.perform(
              "Creating the profile…", { _ = try await $0.createProfile(request) })
            {
              dismiss()
            }
          }
        }
        .disabled(!canSave || saving)
      }
    }
  }
}

/// Editing a profile, as the Mac's profile editor.
struct IOSAdminProfileEditor: View {
  let userID: UUID

  struct Loaded: Sendable {
    let editor: IOSProfileEditor
    let ageLimit: IOSProfileAgeLimit
    let devices: [IOSDeviceSession]
  }

  var body: some View {
    IOSAdminLoader { client in
      async let editor = client.profileEditor(id: userID)
      async let age = client.ageLimit(user: userID)
      async let devices = client.userDevices(user: userID)
      return Loaded(editor: try await editor, ageLimit: try await age, devices: try await devices)
    } content: { loaded, reload in
      IOSAdminProfileForm(loaded: loaded, reload: reload)
        .id(loaded.editor.revision)
    }
    .navigationTitle("Profile")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminProfileForm: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.dismiss) private var dismiss
  let loaded: IOSAdminProfileEditor.Loaded
  let reload: @MainActor @Sendable () async -> Void
  @State private var name: String
  @State private var picture: String?
  @State private var role: String
  @State private var enabled: Bool
  @State private var protection: Bool
  @State private var pin = ""
  @State private var accessMode: String
  @State private var titleIds: [UUID]
  @State private var ageLimit: Int?
  @State private var confirmation: IOSAdminConfirmation?
  @State private var saving = false

  init(
    loaded: IOSAdminProfileEditor.Loaded, reload: @escaping @MainActor @Sendable () async -> Void
  ) {
    self.loaded = loaded
    self.reload = reload
    let user = loaded.editor.user
    _name = State(initialValue: user.shownName)
    _picture = State(initialValue: user.pictureKey)
    _role = State(initialValue: user.role)
    _enabled = State(initialValue: loaded.editor.isEnabled)
    _protection = State(initialValue: user.pinProtectionEnabled ?? true)
    let mode = loaded.editor.access.mode == "selectedTitles" ? "selectedTitles" : "entireLibrary"
    _accessMode = State(initialValue: mode)
    _titleIds = State(initialValue: loaded.editor.access.titleIds)
    _ageLimit = State(initialValue: loaded.ageLimit.ageLimit)
  }

  private var user: IOSAdminUser { loaded.editor.user }
  private var isOwner: Bool { user.role == "owner" }
  private var isSelf: Bool { user.id == model.session?.user.id }
  private var hasPhoto: Bool { user.pictureKey == IOSProfilePictures.photoKey }

  private var profileChanged: Bool {
    role != user.role || enabled != loaded.editor.isEnabled
      || protection != (user.pinProtectionEnabled ?? true) || !pin.isEmpty
      || accessMode
        != (loaded.editor.access.mode == "selectedTitles" ? "selectedTitles" : "entireLibrary")
      || (accessMode == "selectedTitles" && titleIds != loaded.editor.access.titleIds)
  }
  private var changed: Bool {
    profileChanged || name.trimmingCharacters(in: .whitespacesAndNewlines) != user.shownName
      || picture != user.pictureKey
      || ageLimit != (loaded.ageLimit.ageLimit)
  }
  private var canSave: Bool {
    IOSProfileRules.isValidName(name)
      && IOSProfileRules.canSave(
        role: role, protection: protection, newPIN: pin,
        hasPIN: (user.pinProtectionEnabled ?? true) && user.needsPinSetup != true)
  }

  var body: some View {
    Form {
      Section {
        IOSAdminProfileIdentity(
          name: name, role: role, picture: picture, id: user.id,
          pictureRevision: user.pictureRevision ?? 0)
        IOSAdminProfileNameField(name: $name)
        if !isOwner {
          Picker("Role", selection: $role) {
            Text("Viewer").tag("user")
            Text("Administrator").tag("admin")
          }
          .onChange(of: role) { _, value in
            if value == "admin" {
              protection = true
              ageLimit = nil
            }
          }
          Toggle("Profile Turned On", isOn: $enabled).disabled(isSelf)
        } else {
          LabeledContent("Role", value: "Owner")
        }
      }
      Section {
        IOSAdminPicturePicker(selection: $picture, name: name)
      } header: {
        Text("Picture")
      } footer: {
        if hasPhoto && picture == IOSProfilePictures.photoKey {
          Text("Choosing a color, symbol or initial replaces this profile’s photo.")
        }
      }
      Section {
        Toggle("Protect with a PIN", isOn: $protection).disabled(role != "user")
        if protection {
          SecureField(
            (user.pinProtectionEnabled ?? true)
              ? "New PIN (leave empty to keep)" : "PIN (4 to 8 digits)",
            text: $pin
          )
          .keyboardType(.numberPad)
          if let problem = IOSProfilePIN.problem(pin) {
            Text(problem).font(.caption).foregroundStyle(.orange)
          }
        }
      } header: {
        Text("PIN")
      } footer: {
        Text("Administrators always need a PIN. A forgotten PIN is replaced here.")
      }
      if role == "user" {
        Section {
          Picker("Children’s Profile", selection: $ageLimit) {
            ForEach(IOSProfileRules.ageLimits, id: \.self) {
              Text(IOSProfileRules.ageTitle($0)).tag($0)
            }
          }
          .onChange(of: ageLimit) { _, value in
            if value != nil { accessMode = "entireLibrary" }
          }
          if ageLimit != nil {
            NavigationLink("Screen Time") { IOSAdminScreenTimeView(userID: user.id, name: name) }
          }
        } header: {
          Text("Children’s Profile")
        } footer: {
          Text(
            "Shows only titles rated up to this age, with bedtimes and a daily limit under Screen Time."
          )
        }
      }
      if !isOwner {
        Section {
          Picker("Can Watch", selection: $accessMode) {
            Text("The Whole Library").tag("entireLibrary")
            Text("Chosen Titles").tag("selectedTitles")
          }
          .onChange(of: accessMode) { _, value in
            if value == "selectedTitles" { ageLimit = nil }
          }
          if accessMode == "selectedTitles" {
            NavigationLink {
              IOSAdminTitleChooser(selection: $titleIds)
            } label: {
              LabeledContent("Titles", value: "\(titleIds.count)")
            }
          }
        } header: {
          Text("Content Access")
        }
      }
      if !loaded.devices.isEmpty {
        Section {
          ForEach(loaded.devices.filter { $0.isActive() }) { device in
            IOSDeviceRow(device: device) {
              let id = device.id
              Task { await admin.perform { try await $0.revokeDevice(id: id) } }
            }
          }
          Button("Sign Out Everywhere", role: .destructive) {
            let id = user.id
            confirmation = IOSAdminConfirmation(
              title: "Sign out every device of \(name)?",
              message: "Each device needs a new code to connect again.", action: "Sign Out"
            ) {
              Task { await admin.perform { try await $0.revokeAllDevices(user: id) } }
            }
          }
        } header: {
          Text("Devices")
        }
      }
      if !isOwner && !isSelf {
        Section {
          Button("Delete Profile…", role: .destructive) {
            confirmation = IOSAdminConfirmation(
              title: "Delete “\(name)”?",
              message:
                "Its watch history, favorites and collections are removed. Videos stay untouched.",
              action: "Delete"
            ) {
              let id = user.id
              Task {
                if await admin.perform("Deleting…", { try await $0.deleteProfile(id: id) }) {
                  dismiss()
                }
              }
            }
          }
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .adminConfirmation($confirmation)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }.disabled(!changed || !canSave || saving)
      }
    }
  }

  private func save() {
    guard !saving else { return }
    saving = true
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let renamed = trimmed != user.shownName ? trimmed : nil
    let newPicture: String?? = picture != user.pictureKey ? .some(picture) : nil
    let accessChanged =
      accessMode != loaded.editor.access.mode
      || (accessMode == "selectedTitles" && titleIds != loaded.editor.access.titleIds)
    let update: IOSProfileUpdateRequest? =
      profileChanged
      ? IOSProfileUpdateRequest(
        revision: loaded.editor.revision, role: isOwner ? "owner" : role, isEnabled: enabled,
        pinProtectionEnabled: protection, pin: protection && !pin.isEmpty ? pin : nil,
        accessMode: !isOwner && accessChanged ? accessMode : nil,
        titleIds: !isOwner && accessChanged && accessMode == "selectedTitles" ? titleIds : nil)
      : nil
    let plan = IOSProfileSavePlan(
      editor: loaded.editor, age: loaded.ageLimit, name: renamed, picture: newPicture,
      update: update, ageLimit: role == "user" ? ageLimit : nil)
    Task {
      defer { saving = false }
      if await admin.perform("Saving…", { try await plan.save(using: $0) }) {
        pin = ""
      }
    }
  }

}

/// Chooses the movies and series a profile may watch.
private struct IOSAdminTitleChooser: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @Binding var selection: [UUID]
  @State private var titles: [IOSCatalogItem] = []
  @State private var search = ""
  @State private var loading = true
  @State private var error: String?

  private var shown: [IOSCatalogItem] {
    let query = search.trimmingCharacters(in: .whitespaces)
    return query.isEmpty
      ? titles : titles.filter { $0.title.localizedCaseInsensitiveContains(query) }
  }

  var body: some View {
    List {
      if loading { ProgressView() }
      if let error {
        IOSAdminSectionProblem(message: error, retry: load)
      } else if !loading && shown.isEmpty {
        ContentUnavailableView(
          search.isEmpty ? "No Titles" : "No Results",
          systemImage: search.isEmpty ? "film.stack" : "magnifyingglass",
          description: Text(
            search.isEmpty ? "Add movies or shows to the library first." : "Try another title."))
      }
      ForEach(shown) { item in
        Button {
          if let index = selection.firstIndex(of: item.id) {
            selection.remove(at: index)
          } else {
            selection.append(item.id)
          }
        } label: {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(item.title).foregroundStyle(.primary)
              Text(
                [item.kind == .series ? "TV Show" : "Movie", item.year.map(String.init)].compactMap
                { $0 }
                .joined(separator: " · ")
              )
              .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if selection.contains(item.id) {
              Image(systemName: "checkmark").foregroundStyle(.tint)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .searchable(text: $search)
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle("\(selection.count) \(selection.count == 1 ? "Title" : "Titles")")
    .navigationBarTitleDisplayMode(.inline)
    .task { await load() }
  }

  private func load() async {
    loading = true
    error = nil
    defer { loading = false }
    do {
      guard let client = admin.client else { throw IOSCoreError.profileRequired }
      var all: [IOSCatalogItem] = []
      for kind in [IOSMediaKind.movie, .series] {
        var offset = 0
        while true {
          try Task.checkCancellation()
          let page = try await client.catalogPage(kind: kind, offset: offset, limit: 200)
          all += page.items
          offset += page.items.count
          if page.items.isEmpty || offset >= page.total { break }
        }
      }
      try Task.checkCancellation()
      titles = all.sorted {
        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
    } catch is CancellationError {
      return
    } catch {
      self.error = IOSAdministrationModel.message(error)
    }
  }
}

/// Screen time of a children's profile: bedtimes, a daily limit and today's extra time.
private struct IOSAdminScreenTimeView: View {
  let userID: UUID
  let name: String

  var body: some View {
    IOSAdminLoader {
      try await $0.screenTime(user: userID)
    } content: { value, _ in
      IOSAdminScreenTimeForm(userID: userID, value: value)
        .id(value.revision)
    }
    .navigationTitle("Screen Time")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminScreenTimeForm: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let userID: UUID
  let value: IOSProfileScreenTime
  @State private var rules: IOSScreenTimeRules

  init(userID: UUID, value: IOSProfileScreenTime) {
    self.userID = userID
    self.value = value
    _rules = State(initialValue: value.rules)
  }

  var body: some View {
    Form {
      Section {
        Toggle("Screen Time", isOn: $rules.enabled)
      } footer: {
        Text(
          "Bedtimes and a daily limit for this children’s profile. When time is up it says good night."
        )
      }
      if rules.enabled {
        day("School Nights · Sunday to Thursday", rule: $rules.schoolNight)
        day("Weekend · Friday and Saturday", rule: $rules.weekend)
        Section {
          Picker("When Time Is Up", selection: $rules.ending) {
            Text("Let the Title Finish").tag("finishTitle")
            Text("Stop Right Away").tag("stopNow")
          }
          if rules.ending == "finishTitle" {
            Stepper(value: $rules.maxOvertimeMinutes, in: 0...180, step: 15) {
              LabeledContent("At Most", value: "\(rules.maxOvertimeMinutes) minutes longer")
            }
          }
          Picker("Then Close", selection: $rules.lockScope) {
            Text("Playback Only").tag("playbackOnly")
            Text("The Whole Profile").tag("wholeProfile")
          }
        }
      }
      Section {
        if let status = value.status {
          LabeledContent("Watched Today", value: "\(status.watchedMinutesToday) minutes")
        }
        Button("15 Minutes More Today") { grant(.init(addMinutes: 15)) }
        Button("30 Minutes More Today") { grant(.init(addMinutes: 30)) }
        Button("No Bedtime Tonight") { grant(.init(liftBedtime: true)) }
          .disabled(value.today.bedtimeLifted)
        Button("One More Title") { grant(.init(oneMoreTitle: true)) }
          .disabled(value.today.oneMoreTitle)
      } header: {
        Text("Today")
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          let update = IOSProfileScreenTimeUpdate(rules: rules, revision: value.revision)
          let id = userID
          Task {
            await admin.perform("Saving…") { _ = try await $0.setScreenTime(user: id, update) }
          }
        }
        .disabled(rules == value.rules)
      }
    }
  }

  private func day(_ title: String, rule: Binding<IOSScreenTimeDayRule>) -> some View {
    Section(title) {
      Toggle(
        "Bedtime",
        isOn: Binding(
          get: { rule.wrappedValue.bedtime != nil },
          set: { rule.wrappedValue.bedtime = $0 ? "19:30" : nil }))
      if let bedtime = rule.wrappedValue.bedtime {
        DatePicker(
          "Bedtime",
          selection: Binding(
            get: { Self.date(bedtime) }, set: { rule.wrappedValue.bedtime = Self.time($0) }),
          displayedComponents: .hourAndMinute)
      }
      DatePicker(
        "Morning From",
        selection: Binding(
          get: { Self.date(rule.wrappedValue.wakeTime) },
          set: { rule.wrappedValue.wakeTime = Self.time($0) }),
        displayedComponents: .hourAndMinute)
      Toggle(
        "Daily Limit",
        isOn: Binding(
          get: { rule.wrappedValue.dailyLimitMinutes != nil },
          set: { rule.wrappedValue.dailyLimitMinutes = $0 ? 90 : nil }))
      if let limit = rule.wrappedValue.dailyLimitMinutes {
        Stepper(
          value: Binding(get: { limit }, set: { rule.wrappedValue.dailyLimitMinutes = $0 }),
          in: 15...600, step: 15
        ) {
          LabeledContent(
            "Up To",
            value: limit % 60 == 0 ? "\(limit / 60) h" : "\(limit / 60) h \(limit % 60) min")
        }
      }
    }
  }

  private func grant(_ grant: IOSScreenTimeGrant) {
    let id = userID
    Task { await admin.perform("Allowing…") { _ = try await $0.grantScreenTime(user: id, grant) } }
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

/// Every device signed in (the owner, with Block and That Was Me) or your own devices.
struct IOSAdminDevicesView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @EnvironmentObject private var model: IOSAppModel

  enum Loaded: Sendable {
    case all([IOSSecurityDevice])
    case own([IOSDeviceSession])
  }

  var body: some View {
    let everyone =
      admin.permissions.owner && model.capabilities?.capabilities?.contains("security-v1") == true
    IOSAdminLoader { client in
      everyone
        ? Loaded.all(try await client.securityDevices()) : Loaded.own(try await client.ownDevices())
    } content: { loaded, reload in
      IOSAdminDevicesForm(loaded: loaded, reload: reload)
    }
    .navigationTitle(everyone ? "Signed-In Devices" : "Your Devices")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminDevicesForm: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let loaded: IOSAdminDevicesView.Loaded
  let reload: @MainActor @Sendable () async -> Void
  @State private var confirmation: IOSAdminConfirmation?

  var body: some View {
    Form {
      switch loaded {
      case .all(let devices):
        let fresh = devices.filter(\.isNew)
        if !fresh.isEmpty {
          Section {
            ForEach(fresh) { device in deviceRow(device) }
          } header: {
            Text("New")
          } footer: {
            Text("Signed in for the first time. Tap That Was Me if you know it, or Block it.")
          }
        }
        Section {
          ForEach(devices.filter { !$0.isNew }) { device in deviceRow(device) }
        } header: {
          Text("Known")
        } footer: {
          Text(
            "Sign Out ends a device’s sign-in; it can connect again with a new code. Block also keeps it from connecting again until you unblock it under Security."
          )
        }
      case .own(let devices):
        Section {
          ForEach(devices.filter { $0.isActive() }) { device in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(
                  device.deviceName + (device.isCurrent ? " (This \(IOSDesign.deviceName))" : ""))
                Text("Last used \(IOSAdminFormat.relative(device.lastSeenAt))")
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if !device.isCurrent {
                Button("Sign Out", role: .destructive) {
                  confirmation = IOSAdminConfirmation(
                    title: "Sign out “\(device.deviceName)”?",
                    message: "It needs a new code to connect again.", action: "Sign Out"
                  ) {
                    let id = device.id
                    Task { await admin.perform { try await $0.revokeOwnDevice(id: id) } }
                  }
                }
                .buttonStyle(.borderless)
              }
            }
          }
        } footer: {
          Text("A signed-out device needs a new code from the owner to connect again.")
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .refreshable { await reload() }
    .adminConfirmation($confirmation)
  }

  private func deviceRow(_ device: IOSSecurityDevice) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      IOSSecurityDeviceRow(device: device, onBlock: { confirmBlock(device) })
      if !device.isCurrent {
        HStack(spacing: 18) {
          if device.isNew {
            Button("That Was Me") {
              let id = device.id
              Task { await admin.perform { try await $0.acknowledgeDevice(id: id) } }
            }
          }
          Button("Sign Out", role: .destructive) {
            confirmation = IOSAdminConfirmation(
              title: "Sign out “\(device.deviceName)”?",
              message: "It needs a new code to connect again.", action: "Sign Out"
            ) {
              let id = device.id
              Task { await admin.perform { try await $0.revokeDevice(id: id) } }
            }
          }
        }
        .buttonStyle(.borderless)
        .font(.callout)
      }
    }
  }

  private func confirmBlock(_ device: IOSSecurityDevice) {
    confirmation = IOSAdminConfirmation(
      title: "Block “\(device.deviceName)”?",
      message: "It is signed out at once and can’t sign in or pair again until you unblock it.",
      action: "Block"
    ) {
      let id = device.id
      Task { await admin.perform("Blocking…") { _ = try await $0.blockDevice(id: id) } }
    }
  }
}
