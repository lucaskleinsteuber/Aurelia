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
  @State private var failedAttempts = 0
  @FocusState private var pinFocused: Bool
  @Environment(\.aureliaReduceMotion) private var reduceMotion

  private var isSubmitting: Bool { unlockTask != nil || model.isSelectingProfile }

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: 34) {
          if model.connectionStatus != nil
            || (model.serverUnreachable && model.watchingProfiles.isEmpty)
          {
            ServerUnreachableView()
          } else if model.managementSetupRequired {
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
            Text("Who’s watching?")
              .font(.system(size: 40, weight: .bold))
              .tracking(-0.5)
              .aureliaRiseIn(0)
            profiles
            selectionFeedback
          }
        }
        .padding(40)
        .frame(maxWidth: 980)
        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
      }
      .scrollIndicators(.never)
    }
    .background { AureliaAmbientBackground() }
    .animation(
      reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.32), value: choice?.id
    )
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
      ForEach(Array(model.watchingProfiles.enumerated()), id: \.element.id) { index, profile in
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
          let asleep = ScreenTimeText.closedLabel(profile.closedUntil)
          VStack(spacing: 12) {
            ProfileAvatar(profile: profile)
              .opacity(asleep == nil ? 1 : 0.45)
              .saturation(asleep == nil ? 1 : 0.4)
            HStack(spacing: 5) {
              Text(profile.name).font(.headline).lineLimit(2)
                .multilineTextAlignment(.center)
              if profile.pinProtectionEnabled || profile.needsPinSetup {
                Image(systemName: "lock.fill")
                  .font(.system(size: 10, weight: .semibold))
                  .foregroundStyle(.secondary)
              }
            }
            .frame(height: 44, alignment: .top)
            if profile.needsPinSetup {
              Text("Set up PIN").font(.caption).foregroundStyle(.secondary)
            }
            // Screen time closes a children's profile until its wake time.
            if let asleep {
              Label(asleep, systemImage: "moon.fill").font(.caption).foregroundStyle(.secondary)
            }
          }
          .frame(width: CenteredProfileLayout.entryWidth)
          .frame(maxHeight: .infinity, alignment: .top)
          .contentShape(Rectangle())
          .aureliaRiseIn(index + 1)
        }
        .buttonStyle(ProfileAvatarButtonStyle())
        .disabled(profile.needsPinSetup || profile.closedUntil != nil || isSubmitting)
        .accessibilityLabel(profile.name)
        .accessibilityValue(
          ScreenTimeText.closedLabel(profile.closedUntil)
            ?? (profile.needsPinSetup
              ? "PIN setup required" : (profile.pinProtectionEnabled ? "PIN protected" : "No PIN"))
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
    VStack(spacing: 22) {
      Button {
        returnToProfiles()
      } label: {
        ProfileAvatar(profile: choice)
      }
      .buttonStyle(ProfileAvatarButtonStyle())
      .help("Choose another profile")
      .accessibilityLabel("Choose another profile")
      .accessibilityIdentifier("profile-back")
      VStack(spacing: 6) {
        Text(choice.name).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
          .frame(maxWidth: 360)
        Text("Enter your PIN").font(.callout).foregroundStyle(.secondary)
      }
      pinField(choice)
        .modifier(PINShake(attempts: failedAttempts, reduceMotion: reduceMotion))
      ZStack {
        if isSubmitting {
          ProgressView().controlSize(.small).accessibilityLabel("Opening profile")
            .accessibilityIdentifier("profile-unlock-progress")
        } else if let error = validationError ?? model.profileSelectionError {
          Text(error).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
            .frame(maxWidth: 360).accessibilityIdentifier("profile-pin-error")
        }
      }
      .frame(minHeight: 22)
      if choice.role == .owner, model.operatingMode == .host,
        model.deviceConnection?.locallyManaged == true
      {
        Button("Forgot PIN?") {
          model.cancelWatchingProfileSelection()
          validationError = nil
          self.choice = nil
          recoveringOwner = true
          pin = ""
          password = ""
          confirmation = ""
        }
        .buttonStyle(.plain).font(.callout).foregroundStyle(.tint)
        .disabled(isSubmitting)
        .help("Set a new owner PIN with the Server Password on this Mac")
        .accessibilityIdentifier("recover-owner-pin")
      }
    }
    .task(id: choice.id) {
      await Task.yield()
      pinFocused = true
    }
  }

  /// A rounded field with a confirm arrow, like the macOS login window.
  private func pinField(_ choice: WatchingProfile) -> some View {
    HStack(spacing: 8) {
      SecureField("PIN", text: $pin)
        .textFieldStyle(.plain).font(.system(size: 20, weight: .medium, design: .rounded))
        .multilineTextAlignment(.center)
        .focused($pinFocused).disabled(isSubmitting)
        .accessibilityLabel("Profile PIN").accessibilityIdentifier("profile-pin")
        .onSubmit { submit(choice) }
        .onChange(of: pin) { _, value in
          let digits = String(value.filter(\.isNumber).prefix(8))
          if digits != value { pin = digits }
        }
        .padding(.leading, 44)
      Button {
        submit(choice)
      } label: {
        Image(systemName: "arrow.right")
          .font(.system(size: 15, weight: .bold))
          .foregroundStyle(pin.isEmpty ? Color.white.opacity(0.5) : Color.black)
          .frame(width: 36, height: 36)
          .background(Circle().fill(pin.isEmpty ? Color.white.opacity(0.12) : Color.white))
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .disabled(pin.isEmpty || isSubmitting)
      .animation(.smooth(duration: 0.2), value: pin.isEmpty)
      .help("Open Profile")
      .accessibilityLabel("Open Profile")
      .accessibilityIdentifier("profile-unlock")
    }
    .padding(.trailing, 8)
    .frame(width: 280, height: 52)
    .background {
      Capsule().fill(.ultraThinMaterial)
      Capsule().fill(Color.black.opacity(0.25))
    }
    .overlay {
      Capsule().strokeBorder(
        pinFocused ? Color.accentColor : Color.white.opacity(0.16),
        lineWidth: pinFocused ? 2 : 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("profile-pin-container")
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
      PINRequirementNote(pin: pin, confirmation: confirmation)
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
      // A PIN of the wrong length is answered like any wrong PIN.
      validationError = ProfilePIN.incorrect
      pin = ""
      failedAttempts += 1
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
        failedAttempts += 1
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
      PINRequirementNote(pin: pin, confirmation: confirmation)
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
    AureliaProfileAvatar(profile: profile, size: 112)
      .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
      .accessibilityHidden(true)
  }
}

/// Profiles lift with a white ring on hover, like Apple's profile pickers.
private struct ProfileAvatarButtonStyle: ButtonStyle {
  @State private var hovering = false
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.aureliaReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .overlay(alignment: .top) {
        Circle()
          .strokeBorder(.white.opacity(hovering && isEnabled ? 0.9 : 0), lineWidth: 3)
          .frame(width: 124, height: 124)
          .offset(y: -6)
          .allowsHitTesting(false)
      }
      .scaleEffect(
        reduceMotion ? 1 : (configuration.isPressed ? 0.96 : (hovering && isEnabled ? 1.05 : 1))
      )
      .opacity(isEnabled ? 1 : 0.55)
      .animation(
        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.72), value: hovering
      )
      .animation(
        reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.7),
        value: configuration.isPressed
      )
      .onHover { hovering = $0 }
  }
}

/// A short sideways shake after a wrong PIN, as on the macOS login window.
private struct PINShake: ViewModifier {
  let attempts: Int
  let reduceMotion: Bool

  func body(content: Content) -> some View {
    if reduceMotion {
      content
    } else {
      content.keyframeAnimator(initialValue: CGFloat.zero, trigger: attempts) { view, offset in
        view.offset(x: offset)
      } keyframes: { _ in
        KeyframeTrack {
          SpringKeyframe(-12, duration: 0.07)
          SpringKeyframe(10, duration: 0.07)
          SpringKeyframe(-7, duration: 0.07)
          SpringKeyframe(4, duration: 0.07)
          SpringKeyframe(0, duration: 0.12)
        }
      }
    }
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
        if protected, let problem = ProfilePIN.problem(current) {
          PINProblemText(message: problem)
        }
        PINRequirementNote(pin: new, confirmation: confirmation)
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

/// States the PIN rule below PIN fields and replaces it with a live error.
struct PINRequirementNote: View {
  let pin: String
  var confirmation = ""

  var body: some View {
    if let problem = ProfilePIN.problem(pin, confirmation: confirmation) {
      PINProblemText(message: problem)
    } else {
      Text(ProfilePIN.requirement).font(.caption).foregroundStyle(.secondary)
        .accessibilityIdentifier("pin-requirement")
    }
  }
}

struct PINProblemText: View {
  let message: String
  var body: some View {
    Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption)
      .foregroundStyle(.orange).accessibilityIdentifier("pin-requirement-error")
  }
}
