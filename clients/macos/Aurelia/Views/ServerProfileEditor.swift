import SwiftUI

struct ServerProfileEditor: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let existing: UserAccessSummary?
  let client: APIClient
  let completed: () -> Void

  @State private var snapshot: ProfileEditorResponse?
  @State private var name: String
  @State private var role: UserRole
  @State private var enabled: Bool
  @State private var pinProtected: Bool
  @State private var pin = ""
  @State private var pinConfirmation = ""
  @State private var accessMode: ProfileAccessMode
  @State private var selectedTitles: Set<UUID> = []
  @State private var query = ""
  @State private var pictureKey: String?
  @State private var photo: Data?
  @State private var ageSnapshot: ProfileAgeLimit?
  @State private var isChild = false
  @State private var ageLimit = 6
  @State private var allowedTitles: Set<UUID> = []
  @State private var hiddenTitles: Set<UUID> = []
  @State private var exceptionQuery = ""
  @State private var screenTime = ScreenTimeRules.default
  @State private var screenTimeSnapshot: ProfileScreenTime?
  @State private var working = false
  @State private var saveTask: Task<Void, Never>?
  @State private var error: String?
  /// The profile being edited. A created profile switches the editor to editing it, so saving
  /// again after a later step failed never creates it twice.
  @State private var editingID: UUID?

  init(existing: UserAccessSummary? = nil, client: APIClient, completed: @escaping () -> Void) {
    self.existing = existing
    self.client = client
    self.completed = completed
    _editingID = State(initialValue: existing?.id)
    _name = State(initialValue: existing?.user.shownName ?? "")
    _pictureKey = State(initialValue: existing?.user.pictureKey)
    _isChild = State(initialValue: existing?.user.ageLimit != nil)
    _ageLimit = State(initialValue: existing?.user.ageLimit ?? 6)
    _role = State(initialValue: existing?.user.role ?? .user)
    _enabled = State(initialValue: existing?.isEnabled ?? true)
    _pinProtected = State(initialValue: existing?.user.pinProtectionEnabled ?? false)
    _accessMode = State(initialValue: existing?.user.accessMode ?? .selectedTitles)
  }

  private var creating: Bool { editingID == nil }
  private var hasExistingPIN: Bool {
    guard let user = snapshot?.user else { return false }
    return user.pinProtectionEnabled && !user.needsPinSetup
  }
  private var hasValidPIN: Bool {
    ProfilePIN.canSave(
      role: role, protectionEnabled: pinProtected, newPIN: pin,
      hasExistingPIN: hasExistingPIN)
      && ((pin.isEmpty && pinConfirmation.isEmpty) || pin == pinConfirmation)
  }
  private var canSave: Bool {
    !working && (creating || snapshot != nil)
      && (1...40).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count)
      && hasValidPIN && (!creating || !childActive || model.supportsAgeLimits)
  }
  /// A children's profile: only for viewing profiles on servers that know age limits.
  private var childActive: Bool { model.supportsAgeLimits && isChild && role == .user }
  private var exceptionTitles: [CatalogItemSummary] {
    model.catalogItems.filter {
      ($0.kind == .movie || $0.kind == .series)
        && (exceptionQuery.isEmpty
          ? allowedTitles.contains($0.id) || hiddenTitles.contains($0.id)
          : $0.title.localizedCaseInsensitiveContains(exceptionQuery))
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }
  private var titles: [CatalogItemSummary] {
    model.catalogItems.filter {
      ($0.kind == .movie || $0.kind == .series)
        && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  var body: some View {
    VStack(spacing: 0) {
      AureliaSheetHeader(
        title: creating ? "Create Profile" : "Edit Profile",
        subtitle: "Choose who can watch and what they can see.",
        symbol: "person.crop.circle.fill")
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if !creating, snapshot == nil, error == nil {
            AureliaDelayedProgress(controlSize: .small)
              .frame(maxWidth: .infinity)
              .accessibilityLabel("Loading profile")
          }
          profileSection.disabled(working || (!creating && snapshot == nil))
          if model.supportsProfilePersonalization {
            pictureSection.disabled(working || (!creating && snapshot == nil))
          }
          protectionSection.disabled(working || (!creating && snapshot == nil))
          if model.supportsAgeLimits && role == .user {
            childSection.disabled(working || (!creating && snapshot == nil))
          }
          if model.supportsScreenTime && role == .user {
            ScreenTimeSection(
              rules: $screenTime, current: screenTimeSnapshot,
              grant: screenTimeGrant
            )
            .disabled(working || (!creating && snapshot == nil))
          }
          if !childActive {
            contentSection.disabled(working || (!creating && snapshot == nil))
          }
          if let error {
            ErrorBanner(
              message: error,
              retry: !creating && snapshot == nil ? { reloadProfile() } : nil,
              retryLabel: "Reload Profile", inline: true
            )
            .accessibilityIdentifier("profile-editor-error")
          }
        }.padding(24)
      }.scrollIndicators(.hidden).aureliaOverlayScrollbars()
      Divider()
      HStack(spacing: 10) {
        if !creating {
          Text("Each change is saved in turn; if one fails, the ones before it stay saved.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        Button("Cancel") {
          clearPIN()
          dismiss()
        }.keyboardShortcut(.cancelAction).disabled(working)
          .accessibilityIdentifier("profile-editor-cancel")
        Button(working ? "Saving…" : (creating ? "Create Profile" : "Save")) { save() }
          .buttonStyle(AureliaPrimaryActionButtonStyle(compact: true))
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave).accessibilityIdentifier("profile-editor-save")
      }.padding(16).accessibilityElement(children: .contain)
    }
    .aureliaSheetFrame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 700)
    .aureliaSettingRows()
    .background(AureliaBackdrop())
    .interactiveDismissDisabled(working)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("profile-editor")
    .task(id: model.administrationGeneration) {
      if snapshot == nil { await load() }
    }
    .onChange(of: role) { _, updated in
      if updated.canManageLibraries { pinProtected = true }
    }
    .onChange(of: pinProtected) { _, protected in
      if !protected { clearPIN() }
    }
    .onChange(of: model.administrationGeneration) { _, _ in clearPIN() }
    .onChange(of: model.profile?.sessionId) { _, _ in
      clearPIN()
      dismiss()
    }
    .onDisappear {
      saveTask?.cancel()
      saveTask = nil
      clearPIN()
    }
  }

  private var profileSection: some View {
    AureliaSettingsSection("Profile", symbol: "person.fill") {
      VStack(alignment: .leading, spacing: 12) {
        if creating || model.supportsProfilePersonalization {
          TextField("Profile name", text: $name).textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("profile-editor-name")
          if !creating {
            Text("The name everyone sees. An owner keeps signing in with the original name.")
              .font(.caption).foregroundStyle(.secondary)
          }
        } else {
          LabeledContent("Name", value: name)
        }
        Picker("Role", selection: $role) {
          Text("User").tag(UserRole.user)
          Text("Administrator").tag(UserRole.admin)
          Text("Owner").tag(UserRole.owner)
        }.accessibilityIdentifier("profile-editor-role")
        Toggle("Profile Enabled", isOn: $enabled)
          .accessibilityIdentifier("profile-editor-enabled")
        Text("Administrators manage their allowed content. Owners manage the whole server.")
          .font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }
  }

  private var pictureSection: some View {
    AureliaSettingsSection("Picture", symbol: "photo") {
      ProfilePicturePicker(
        id: editingID, name: name, pictureRevision: snapshot?.user.pictureRevision ?? 0,
        key: $pictureKey, photo: $photo
      )
      .frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }
  }

  private var childSection: some View {
    AureliaSettingsSection(
      "Children's Profile", symbol: "figure.and.child.holdinghands",
      description: "Limits what this profile may watch, by age rating."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Children's Profile", isOn: $isChild)
          .accessibilityIdentifier("profile-editor-child")
        if isChild {
          Text("A children's profile can watch the whole library, limited by its age.")
            .font(.caption).foregroundStyle(.secondary)
          Picker("Age", selection: $ageLimit) {
            ForEach(ProfileAgeSteps.all, id: \.value) { step in
              Text(step.label).tag(step.value)
            }
          }
          .accessibilityIdentifier("profile-editor-age")
          Text("Titles above this age and titles without a rating are hidden.")
            .font(.caption).foregroundStyle(.secondary)
          Divider()
          Text("Exceptions").font(.headline)
          TextField("Search films and series", text: $exceptionQuery)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("profile-editor-exception-search")
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
              ForEach(exceptionTitles) { item in
                HStack(spacing: 8) {
                  Image(systemName: item.kind == .series ? "tv" : "film")
                    .foregroundStyle(.secondary).frame(width: 18)
                  Text(item.title).lineLimit(1)
                  if let year = item.year {
                    Text(String(year)).foregroundStyle(.secondary)
                  }
                  Spacer()
                  Picker("", selection: exceptionBinding(item.id)) {
                    Text("By Age").tag(0)
                    Text("Allow Anyway").tag(1)
                    Text("Always Hide").tag(2)
                  }
                  .labelsHidden()
                  .frame(width: 140)
                  .accessibilityLabel("Exception \(item.title)")
                  .accessibilityIdentifier("profile-editor-exception-\(item.id.uuidString)")
                }
              }
              if exceptionTitles.isEmpty {
                Text(
                  exceptionQuery.isEmpty
                    ? "No exceptions. Search a title to allow or hide it anyway."
                    : "No matching titles."
                )
                .foregroundStyle(.secondary).padding(.vertical, 6)
              }
            }.padding(12)
          }
          .frame(minHeight: 80, maxHeight: 170)
          .background(
            .quaternary.opacity(0.25),
            in: RoundedRectangle(cornerRadius: AureliaDesign.smallRadius)
          )
          .scrollIndicators(.hidden).aureliaOverlayScrollbars()
        } else {
          Text(
            "Shows only titles approved for the child's age. Titles without a rating are hidden."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }
  }

  private func exceptionBinding(_ id: UUID) -> Binding<Int> {
    Binding(
      get: { allowedTitles.contains(id) ? 1 : hiddenTitles.contains(id) ? 2 : 0 },
      set: { choice in
        allowedTitles.remove(id)
        hiddenTitles.remove(id)
        if choice == 1 { allowedTitles.insert(id) }
        if choice == 2 { hiddenTitles.insert(id) }
      })
  }

  private var protectionSection: some View {
    AureliaSettingsSection(
      "PIN Protection", symbol: "lock.fill",
      description: "A PIN keeps others from opening this profile."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Require a Profile PIN", isOn: $pinProtected)
          .disabled(role.canManageLibraries).accessibilityIdentifier(
            "profile-editor-pin-protection")
        if pinProtected {
          HStack(spacing: 12) {
            SecureField(hasExistingPIN ? "New PIN (optional)" : "PIN (4–8 digits)", text: $pin)
              .accessibilityIdentifier("profile-editor-pin")
            SecureField("Confirm PIN", text: $pinConfirmation)
              .accessibilityIdentifier("profile-editor-pin-confirmation")
          }.textFieldStyle(.roundedBorder)
          PINRequirementNote(pin: pin, confirmation: pinConfirmation)
          if hasExistingPIN {
            Text(
              "Leave both fields empty to keep the current PIN. Changing it locks active sessions."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        } else {
          Text(
            "Anyone on a paired device can open this profile and see its favorites, progress and notes."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        if role.canManageLibraries {
          Text("Owner and administrator profiles always require a PIN.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }
  }

  private var contentSection: some View {
    AureliaSettingsSection(
      "Content Access", symbol: "eye", description: "Which titles this profile can see."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Picker(
          "Can watch",
          selection: Binding(
            get: { role == .owner ? .entireLibrary : accessMode },
            set: { accessMode = $0 })
        ) {
          if snapshot?.access.mode == .legacyLibraries {
            Text("Existing Storage Grants").tag(ProfileAccessMode.legacyLibraries)
          }
          Text("Entire Library").tag(ProfileAccessMode.entireLibrary)
          Text("Selected Titles").tag(ProfileAccessMode.selectedTitles)
        }.disabled(role == .owner).accessibilityIdentifier("profile-editor-access")
        if role == .owner || accessMode == .entireLibrary {
          Text("Includes all existing titles and titles added later.")
            .font(.caption).foregroundStyle(.secondary)
        } else if accessMode == .legacyLibraries {
          Text("Existing storage grants stay unchanged unless you select another access mode.")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          HStack {
            TextField("Search films and series", text: $query).textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("profile-editor-title-search")
            Text("\(selectedTitles.count) selected").font(.caption).foregroundStyle(.secondary)
              .accessibilityIdentifier("profile-editor-selected-count")
          }
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
              ForEach(titles) { item in
                Toggle(
                  isOn: Binding(
                    get: { selectedTitles.contains(item.id) },
                    set: { checked in
                      if checked {
                        selectedTitles.insert(item.id)
                      } else {
                        selectedTitles.remove(item.id)
                      }
                    })
                ) {
                  HStack(spacing: 8) {
                    Image(systemName: item.kind == .series ? "tv" : "film")
                      .foregroundStyle(.secondary).frame(width: 18)
                    Text(item.title).lineLimit(1)
                    Spacer()
                    if let year = item.year { Text(String(year)).foregroundStyle(.secondary) }
                  }
                }.toggleStyle(.checkbox)
                  .accessibilityIdentifier("profile-editor-title-\(item.id.uuidString)")
              }
              if titles.isEmpty {
                Text(query.isEmpty ? "No films or series available." : "No matching titles.")
                  .foregroundStyle(.secondary).padding(.vertical, 8)
              }
            }.padding(12)
          }.frame(minHeight: 100, maxHeight: 190)
            .background(
              .quaternary.opacity(0.25),
              in: RoundedRectangle(cornerRadius: AureliaDesign.smallRadius)
            )
            .scrollIndicators(.hidden).aureliaOverlayScrollbars()
          Text("A series includes all current and future seasons, episodes, extras and trailers.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }
  }

  private func reloadProfile() { Task { await load() } }

  /// Today's extra time only exists for a profile the server already has.
  private var screenTimeGrant: ((ScreenTimeGrant) async -> Void)? {
    guard let id = editingID else { return nil }
    return { grant in await grantScreenTime(id, grant) }
  }

  @MainActor private func load() async {
    guard let id = editingID else { return }
    let generation = model.administrationGeneration
    do {
      let loaded = try await model.currentAdministration {
        guard model.isCurrentAdministration(generation) else { throw CancellationError() }
        return try await client.profileEditor(id: id)
      }
      guard model.isCurrentAdministration(generation), !Task.isCancelled else { return }
      let age: ProfileAgeLimit? =
        model.supportsAgeLimits
        ? try await model.currentAdministration {
          guard model.isCurrentAdministration(generation) else { throw CancellationError() }
          return try await client.ageLimit(user: id)
        } : nil
      guard model.isCurrentAdministration(generation), !Task.isCancelled else { return }
      let screen: ProfileScreenTime? =
        model.supportsScreenTime
        ? try await model.currentAdministration {
          guard model.isCurrentAdministration(generation) else { throw CancellationError() }
          return try await client.screenTime(user: id)
        } : nil
      guard model.isCurrentAdministration(generation), !Task.isCancelled else { return }
      screenTimeSnapshot = screen
      if let screen { screenTime = screen.rules }
      ageSnapshot = age
      if let age {
        isChild = age.ageLimit != nil
        ageLimit = age.ageLimit ?? 6
        allowedTitles = Set(age.allowedTitleIds)
        hiddenTitles = Set(age.hiddenTitleIds)
      }
      snapshot = loaded
      name = loaded.user.shownName
      pictureKey = loaded.user.pictureKey
      role = loaded.user.role
      enabled = loaded.isEnabled
      pinProtected = loaded.user.pinProtectionEnabled
      accessMode = loaded.access.mode
      selectedTitles = Set(loaded.access.titleIds)
      error = nil
    } catch is CancellationError {
    } catch {
      guard model.isCurrentAdministration(generation), !Task.isCancelled else { return }
      if reportManagementFailure(error, generation: generation) { return }
      self.error = error.localizedDescription
    }
  }

  /// Today's exceptions apply at once, without saving the rest of the editor.
  private func grantScreenTime(_ user: UUID, _ grant: ScreenTimeGrant) async {
    let generation = model.administrationGeneration
    do {
      let updated = try await model.currentAdministration {
        guard model.isCurrentAdministration(generation) else { throw CancellationError() }
        return try await client.grantScreenTime(user: user, grant)
      }
      guard model.isCurrentAdministration(generation) else { return }
      screenTimeSnapshot = updated
      error = nil
    } catch is CancellationError {
    } catch {
      guard model.isCurrentAdministration(generation) else { return }
      if reportManagementFailure(error, generation: generation) { return }
      self.error = error.localizedDescription
    }
  }

  private func save() {
    guard canSave else { return }
    let generation = model.administrationGeneration
    let newPIN = pinProtected && !pin.isEmpty ? pin : nil
    let child = childActive
    let mode: ProfileAccessMode = child ? .entireLibrary : accessMode
    let titles = child ? [] : Array(selectedTitles).sorted { $0.uuidString < $1.uuidString }
    let changedAccess =
      creating || mode != snapshot?.access.mode
      || Set(titles) != Set(snapshot?.access.titleIds ?? [])
    let effectiveMode: ProfileAccessMode? = changedAccess ? mode : nil
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let renamed =
      !creating && model.supportsProfilePersonalization
      && trimmedName != snapshot?.user.shownName
    let pictureChanged =
      model.supportsProfilePersonalization
      && (photo != nil || pictureKey != snapshot?.user.pictureKey)
    let upload = pictureKey == ProfilePictureCatalog.photoKey ? photo : nil
    let builtin = pictureKey == ProfilePictureCatalog.photoKey ? nil : pictureKey
    let allowed = Array(allowedTitles).sorted { $0.uuidString < $1.uuidString }
    let hidden = Array(hiddenTitles).sorted { $0.uuidString < $1.uuidString }
    let wasChild = ageSnapshot?.ageLimit != nil
    let ageChanged =
      model.supportsAgeLimits
      && (child != wasChild || (child && ageLimit != ageSnapshot?.ageLimit)
        || (child
          && (Set(allowed) != Set(ageSnapshot?.allowedTitleIds ?? [])
            || Set(hidden) != Set(ageSnapshot?.hiddenTitleIds ?? []))))
    let chosenAge = ageLimit
    let chosenScreenTime = screenTime
    let screenTimeChanged =
      model.supportsScreenTime && role == .user
      && chosenScreenTime != (screenTimeSnapshot?.rules ?? .default)
    if screenTimeChanged, let problem = ScreenTimeText.problem(chosenScreenTime) {
      error = problem
      return
    }
    working = true
    saveTask = Task {
      defer {
        working = false
        saveTask = nil
      }
      do {
        try await model.currentAdministration {
          guard model.isCurrentAdministration(generation) else { throw CancellationError() }
          if let id = editingID, let snapshot {
            // A children's profile ends before its role may change.
            if ageChanged, !child, wasChild {
              let current = try await client.ageLimit(user: id)
              _ = try await client.setAgeLimit(
                user: id,
                ProfileAgeLimit(
                  ageLimit: nil, allowedTitleIds: [], hiddenTitleIds: [],
                  revision: current.revision))
            }
            _ = try await client.updateProfile(
              id: id,
              request: ProfileUpdateRequest(
                revision: snapshot.revision, role: role, isEnabled: enabled,
                pinProtectionEnabled: pinProtected, pin: newPIN, accessMode: effectiveMode,
                titleIds: changedAccess ? titles : nil))
            if ageChanged, child {
              let current = try await client.ageLimit(user: id)
              _ = try await client.setAgeLimit(
                user: id,
                ProfileAgeLimit(
                  ageLimit: chosenAge, allowedTitleIds: allowed, hiddenTitleIds: hidden,
                  revision: current.revision))
            }
            var user: UserSummary?
            if renamed { user = try await client.renameProfile(id: id, name: trimmedName) }
            if pictureChanged {
              if let upload {
                user = try await client.uploadProfilePhoto(id: id, image: upload)
              } else {
                user = try await client.setProfilePicture(id: id, builtin: builtin)
              }
            }
            if let user { model.updateProfileUser(user) }
            if screenTimeChanged {
              let current = try await client.screenTime(user: id)
              _ = try await client.setScreenTime(
                user: id,
                ProfileScreenTimeUpdate(rules: chosenScreenTime, revision: current.revision))
            }
          } else {
            let created = try await client.createProfile(
              request: ProfileCreateRequest(
                username: trimmedName, role: role,
                isEnabled: enabled, pinProtectionEnabled: pinProtected, pin: newPIN,
                accessMode: role == .owner ? .entireLibrary : mode,
                titleIds: role == .owner ? [] : titles,
                pictureKey: model.supportsProfilePersonalization ? builtin : nil,
                ageLimit: child ? chosenAge : nil))
            editingID = created.id
            if let upload, model.supportsProfilePersonalization {
              _ = try await client.uploadProfilePhoto(id: created.id, image: upload)
            }
            if screenTimeChanged {
              _ = try await client.setScreenTime(
                user: created.id, ProfileScreenTimeUpdate(rules: chosenScreenTime, revision: 0))
            }
          }
        }
        clearPIN()
        guard model.isCurrentAdministration(generation), !Task.isCancelled else { return }
        completed()
        dismiss()
      } catch is CancellationError {
      } catch {
        guard model.isCurrentAdministration(generation), !Task.isCancelled else { return }
        if let failure = error as? APIClientError, failure.isManagementLocked {
          guard await model.unlockManagementInteractively() else { return }
          await refreshSnapshots(model.administrationGeneration)
          save()
          return
        }
        if reportManagementFailure(error, generation: generation) { return }
        self.error = error.localizedDescription
        await refreshSnapshots(generation)
      }
    }
  }

  /// After a save stopped part-way, the server's current state becomes the base of the next save
  /// without touching the edits: steps that went through are not sent again, and the next save
  /// uses the new revision.
  @MainActor private func refreshSnapshots(_ generation: UUID) async {
    guard let id = editingID else { return }
    do {
      let loaded = try await model.currentAdministration {
        guard model.isCurrentAdministration(generation) else { throw CancellationError() }
        return try await client.profileEditor(id: id)
      }
      let age: ProfileAgeLimit? =
        model.supportsAgeLimits
        ? try await model.currentAdministration {
          guard model.isCurrentAdministration(generation) else { throw CancellationError() }
          return try await client.ageLimit(user: id)
        } : nil
      let screen: ProfileScreenTime? =
        model.supportsScreenTime
        ? try await model.currentAdministration {
          guard model.isCurrentAdministration(generation) else { throw CancellationError() }
          return try await client.screenTime(user: id)
        } : nil
      guard model.isCurrentAdministration(generation) else { return }
      snapshot = loaded
      ageSnapshot = age
      screenTimeSnapshot = screen
    } catch {}
  }

  private func reportManagementFailure(_ error: Error, generation: UUID) -> Bool {
    guard let failure = error as? APIClientError,
      failure.isManagementLocked || failure == .serverIdentityMismatch
    else { return false }
    model.handleAdministrationFailure(error, generation: generation)
    return true
  }

  private func clearPIN() {
    pin = ""
    pinConfirmation = ""
  }
}
