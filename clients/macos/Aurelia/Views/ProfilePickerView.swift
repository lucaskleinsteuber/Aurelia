import SwiftUI

struct ProfilePickerView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var choice: WatchingProfile?
  @State private var pin = ""
  @State private var password = ""
  @State private var confirmation = ""
  @State private var recoveringOwner = false
  @State private var validationError: String?
  @State private var unlockTask: Task<Void, Never>?
  @State private var unlockAttempt = UUID()
  @FocusState private var pinFocused: Bool

  private var isSubmitting: Bool { unlockTask != nil || model.isSelectingProfile }

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: 28) {
          if model.managementSetupRequired {
            Text("Set Up Viewing Profiles").font(.largeTitle.weight(.semibold))
            firstSetup
            selectionFeedback
          } else if recoveringOwner {
            Text("Recover Owner PIN").font(.largeTitle.weight(.semibold))
            ownerRecovery
            selectionFeedback
          } else if let choice {
            unlock(choice)
          } else {
            Text("Who’s watching?").font(.largeTitle.weight(.semibold))
            profiles
            selectionFeedback
            if model.operatingMode == .host, model.deviceConnection?.locallyManaged == true {
              Button("Recover Owner PIN on This Mac…") {
                model.cancelWatchingProfileSelection()
                validationError = nil
                recoveringOwner = true
                pin = ""
                password = ""
                confirmation = ""
              }
              .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
              .disabled(model.isSelectingProfile)
              .accessibilityIdentifier("recover-owner-pin")
            }
          }
        }
        .padding(40)
        .frame(maxWidth: 980)
        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
      }
    }
    .accessibilityIdentifier("profile-picker")
    .task { await reloadProfilesIfSafe() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await reloadProfilesIfSafe() } }
    }
    .onExitCommand {
      if choice != nil { returnToProfiles() }
    }
    .onDisappear {
      if model.requiresProfileSelection {
        unlockTask?.cancel()
        model.cancelWatchingProfileSelection()
      }
      pin = ""
      password = ""
      confirmation = ""
    }
  }

  private var profiles: some View {
    CenteredProfileLayout {
      ForEach(model.watchingProfiles) { profile in
        Button {
          model.cancelWatchingProfileSelection()
          validationError = nil
          pin = ""
          if profile.pinProtectionEnabled {
            choice = profile
          } else {
            startUnlock(profile, submittedPIN: "")
          }
        } label: {
          VStack(spacing: 10) {
            ProfileAvatar(profile: profile)
            Text(profile.name).font(.headline).lineLimit(2)
              .multilineTextAlignment(.center).frame(height: 44, alignment: .top)
            if profile.needsPinSetup {
              Text("Set up PIN").font(.caption).foregroundStyle(.secondary)
            }
          }
          .frame(width: CenteredProfileLayout.entryWidth)
          .frame(maxHeight: .infinity, alignment: .top)
          .contentShape(Rectangle())
        }
        .buttonStyle(ProfileAvatarButtonStyle())
        .disabled(profile.needsPinSetup || isSubmitting)
        .accessibilityLabel(profile.name)
        .accessibilityValue(
          profile.needsPinSetup
            ? "PIN setup required" : (profile.pinProtectionEnabled ? "PIN protected" : "No PIN")
        )
        .accessibilityIdentifier("watching-profile-\(profile.id.uuidString)")
      }
    }
  }

  private var selectionFeedback: some View {
    Group {
      if let error = model.profileSelectionError {
        Text(error).foregroundStyle(.orange).frame(maxWidth: 480)
          .multilineTextAlignment(.center)
      }
      if model.isSelectingProfile { ProgressView().controlSize(.small) }
    }
  }

  private func unlock(_ choice: WatchingProfile) -> some View {
    VStack(spacing: 18) {
      Button {
        returnToProfiles()
      } label: {
        ProfileAvatar(profile: choice)
      }
      .buttonStyle(ProfileAvatarButtonStyle())
      .accessibilityLabel("Choose another profile")
      .accessibilityIdentifier("profile-back")
      Text(choice.name).font(.title2.weight(.medium)).multilineTextAlignment(.center)
        .frame(maxWidth: 360)
      ZStack {
        RoundedRectangle(cornerRadius: 12)
          .fill(Color(red: 0.07, green: 0.08, blue: 0.09))
        SecureField("PIN", text: $pin)
          .textFieldStyle(.plain).font(.system(size: 22, weight: .medium, design: .rounded))
          .multilineTextAlignment(.center).padding(.horizontal, 16)
          .focused($pinFocused).disabled(isSubmitting)
          .accessibilityLabel("Profile PIN").accessibilityIdentifier("profile-pin")
          .onSubmit { submit(choice) }
      }
      .frame(width: 280, height: 52)
      .overlay {
        RoundedRectangle(cornerRadius: 12).strokeBorder(
          pinFocused ? Color.accentColor : Color.white.opacity(0.16),
          lineWidth: pinFocused ? 2 : 1)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("profile-pin-container")
      if isSubmitting {
        ProgressView().controlSize(.small).accessibilityLabel("Opening profile")
          .accessibilityIdentifier("profile-unlock-progress")
      }
      if let error = validationError ?? model.profileSelectionError {
        Text(error).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
          .frame(maxWidth: 360).accessibilityIdentifier("profile-pin-error")
      }
    }
    .task(id: choice.id) {
      await Task.yield()
      pinFocused = true
    }
  }

  private var firstSetup: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(
        "Confirm the existing Server Password once, then choose a separate Profile PIN for the owner. Your PIN opens your profile; the Server Password unlocks management."
      )
      .font(.callout).foregroundStyle(.secondary)
      SecureField("Server Password", text: $password).textFieldStyle(.roundedBorder)
      SecureField("Owner PIN (4–8 digits)", text: $pin).textFieldStyle(.roundedBorder)
      SecureField("Confirm owner PIN", text: $confirmation).textFieldStyle(.roundedBorder)
      Text(
        "Other profiles stay locked until the owner sets their PIN protection in Users & Access. Your library and paired devices stay unchanged."
      )
      .font(.caption).foregroundStyle(.secondary)
      Button("Set Up Profiles") {
        Task {
          if await model.initializeWatchingProfiles(password: password, pin: pin) {
            password = ""
            pin = ""
            confirmation = ""
          }
        }
      }.buttonStyle(.borderedProminent).disabled(
        password.isEmpty || !ProfilePIN.isValid(pin) || pin != confirmation
          || model.isSelectingProfile)
    }.frame(maxWidth: 440)
  }

  private func submit(_ choice: WatchingProfile) {
    guard !isSubmitting else { return }
    model.clearProfileSelectionError()
    guard ProfilePIN.isValid(pin) else {
      validationError = "Enter 4–8 digits."
      pinFocused = true
      return
    }
    validationError = nil
    startUnlock(choice, submittedPIN: pin)
  }

  private func startUnlock(_ profile: WatchingProfile, submittedPIN: String) {
    guard !isSubmitting else { return }
    pinFocused = false
    let attempt = UUID()
    unlockAttempt = attempt
    unlockTask = Task {
      let selected = await model.selectWatchingProfile(profile, pin: submittedPIN)
      guard unlockAttempt == attempt, !Task.isCancelled else { return }
      unlockTask = nil
      pin = ""
      if !selected, choice?.id == profile.id {
        await Task.yield()
        pinFocused = true
      }
    }
  }

  private func returnToProfiles() {
    unlockAttempt = UUID()
    unlockTask?.cancel()
    unlockTask = nil
    model.cancelWatchingProfileSelection()
    choice = nil
    pin = ""
    validationError = nil
    pinFocused = false
  }

  private func reloadProfilesIfSafe() async {
    guard choice == nil, !recoveringOwner, !model.managementSetupRequired, !isSubmitting else {
      return
    }
    await model.reloadWatchingProfiles()
  }

  private var ownerRecovery: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(
        "Recovery is available only on the server Mac when there is one active owner. The Server Password is required; paired devices and library data are not changed."
      )
      .font(.callout).foregroundStyle(.secondary)
      SecureField("Server Password", text: $password)
      SecureField("New owner PIN (4–8 digits)", text: $pin)
      SecureField("Confirm new owner PIN", text: $confirmation)
      HStack {
        Button("Cancel") {
          recoveringOwner = false
          model.clearProfileSelectionError()
          password = ""
          pin = ""
          confirmation = ""
        }.disabled(model.isSelectingProfile)
        Button("Recover PIN") {
          Task {
            if await model.recoverOwnerPIN(password: password, pin: pin) {
              recoveringOwner = false
              choice = nil
              password = ""
              pin = ""
              confirmation = ""
            }
          }
        }.disabled(
          password.isEmpty || !ProfilePIN.isValid(pin) || pin != confirmation
            || model.isSelectingProfile)
      }
    }.frame(maxWidth: 440).textFieldStyle(.roundedBorder)
  }
}

private struct ProfileAvatar: View {
  let profile: WatchingProfile

  var body: some View {
    Image(systemName: "person.crop.circle.fill")
      .font(.system(size: 88)).symbolRenderingMode(.hierarchical)
      .foregroundStyle(.white.opacity(0.9)).frame(width: 88, height: 88)
      .overlay(alignment: .bottomTrailing) {
        if profile.pinProtectionEnabled || profile.needsPinSetup {
          Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85)).frame(width: 24, height: 24)
            .background(Color(red: 32 / 255, green: 35 / 255, blue: 38 / 255), in: Circle())
        }
      }
      .accessibilityHidden(true)
  }
}

private struct ProfileAvatarButtonStyle: ButtonStyle {
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.65 : (hovering ? 1 : 0.85))
      .onHover { hovering = $0 }
  }
}

/// Fixed-width entries keep every row centered, including an incomplete last row.
struct CenteredProfileLayout: Layout {
  static let entryWidth: CGFloat = 140
  static let spacing: CGFloat = 24

  static func columns(availableWidth: CGFloat, count: Int) -> Int {
    guard count > 0 else { return 1 }
    guard availableWidth.isFinite else { return count }
    let possible = ((max(0, availableWidth) + spacing) / (entryWidth + spacing)).rounded(.down)
    return possible >= CGFloat(count) ? count : max(1, Int(possible))
  }

  static func rowWidth(count: Int) -> CGFloat {
    guard count > 0 else { return 0 }
    return CGFloat(count) * entryWidth + CGFloat(count - 1) * spacing
  }

  static func measuredWidth(proposed: CGFloat?, count: Int) -> CGFloat {
    guard let proposed, proposed.isFinite else { return rowWidth(count: count) }
    return max(entryWidth, proposed)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard !subviews.isEmpty else { return .zero }
    let width = Self.measuredWidth(proposed: proposal.width, count: subviews.count)
    let columns = Self.columns(availableWidth: width, count: subviews.count)
    let height =
      subviews.map { $0.sizeThatFits(ProposedViewSize(width: Self.entryWidth, height: nil)).height }
      .max() ?? 0
    let rows = (subviews.count + columns - 1) / columns
    return CGSize(width: width, height: CGFloat(rows) * height + CGFloat(rows - 1) * Self.spacing)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let columns = Self.columns(availableWidth: bounds.width, count: subviews.count)
    let height =
      subviews.map { $0.sizeThatFits(ProposedViewSize(width: Self.entryWidth, height: nil)).height }
      .max() ?? 0
    for index in subviews.indices {
      let row = index / columns
      let column = index % columns
      let rowCount = min(columns, subviews.count - row * columns)
      let x =
        bounds.midX - Self.rowWidth(count: rowCount) / 2 + CGFloat(column)
        * (Self.entryWidth + Self.spacing)
      let y = bounds.minY + CGFloat(row) * (height + Self.spacing)
      subviews[index].place(
        at: CGPoint(x: x, y: y), anchor: .topLeading,
        proposal: ProposedViewSize(width: Self.entryWidth, height: height))
    }
  }
}

struct ManagementUnlockView: View {
  @EnvironmentObject private var model: AppModel
  @State private var password = ""
  @State private var working = false
  var body: some View {
    GroupBox("Server Management Locked") {
      VStack(alignment: .leading, spacing: 14) {
        Text(
          "Enter the Server Password to manage the areas allowed by your role for ten minutes. Your Profile PIN only opens your profile."
        )
        .foregroundStyle(.secondary)
        SecureField("Server Password", text: $password).textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("management-password")
          .onSubmit { unlockManagement() }
        Button("Unlock Management") { unlockManagement() }
          .disabled(password.isEmpty || working).accessibilityIdentifier("management-unlock")
        if let error = model.administrationErrorMessage { Text(error).foregroundStyle(.orange) }
      }.padding(12)
    }
    .onDisappear { password = "" }
    .onChange(of: model.administrationGeneration) { _, _ in password = "" }
  }

  private func unlockManagement() {
    guard !working, !password.isEmpty else { return }
    let submittedPassword = password
    password = ""
    working = true
    Task {
      defer { working = false }
      _ = await model.unlockManagement(password: submittedPassword)
    }
  }
}

struct ManagementStatusView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      if model.managementUnlocked {
        HStack(spacing: 12) {
          Label("Management Unlocked", systemImage: "lock.open")
          if let expiry = model.managementExpiresAt {
            let remaining = max(0, Int(ceil(expiry.timeIntervalSince(context.date))))
            Text(String(format: "%d:%02d remaining", remaining / 60, remaining % 60))
              .monospacedDigit().foregroundStyle(.secondary)
          }
          Spacer()
          Button("Lock Management") { Task { await model.lockManagement() } }
            .accessibilityIdentifier("management-lock")
        }.font(.callout)
      }
    }
  }
}

struct ChangeProfilePINView: View {
  @EnvironmentObject private var model: AppModel
  @State private var current = ""
  @State private var new = ""
  @State private var confirmation = ""
  @State private var error: String?
  @State private var working = false
  private var protected: Bool { model.profile?.user?.pinProtectionEnabled ?? true }
  private var mandatory: Bool { model.profile?.user?.role.canManageLibraries == true }

  var body: some View {
    GroupBox("Profile PIN") {
      VStack(alignment: .leading, spacing: 12) {
        if protected { SecureField("Current PIN", text: $current) }
        SecureField("New PIN (4–8 digits)", text: $new)
        SecureField("Confirm new PIN", text: $confirmation)
        Button(protected ? "Change PIN & Lock Profile" : "Enable PIN & Lock Profile") {
          updateProtection(enabled: true)
        }.disabled(
          working || (protected && !ProfilePIN.isValid(current))
            || !ProfilePIN.isValid(new) || new != confirmation)
        if mandatory {
          Text("Owner and administrator profiles always require a PIN.")
            .font(.caption).foregroundStyle(.secondary)
        } else if protected {
          Button("Remove PIN Protection") { updateProtection(enabled: false) }
            .disabled(working || !ProfilePIN.isValid(current))
          Text("Without a PIN, anyone on a paired device can open this profile.")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          Text("This profile has no PIN. Add one to protect it on paired devices.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if let error { Text(error).foregroundStyle(.orange) }
      }.padding(12).textFieldStyle(.roundedBorder)
    }
    .onDisappear { clearSecrets() }
    .onChange(of: model.profile?.sessionId) { _, _ in clearSecrets() }
  }

  private func updateProtection(enabled: Bool) {
    guard let profile = model.profile, !working else { return }
    working = true
    Task {
      defer { working = false }
      do {
        try await APIClient(profile: profile).setOwnPINProtection(
          current: protected ? current : nil, new: enabled ? new : nil, enabled: enabled)
        clearSecrets()
        guard model.profile?.sessionId == profile.sessionId else { return }
        await model.switchWatchingProfile()
      } catch {
        guard model.profile?.sessionId == profile.sessionId else { return }
        self.error = error.localizedDescription
      }
    }
  }

  private func clearSecrets() {
    current = ""
    new = ""
    confirmation = ""
  }
}
