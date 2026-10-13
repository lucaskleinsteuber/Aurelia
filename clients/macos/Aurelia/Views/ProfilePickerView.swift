import SwiftUI

struct ProfilePickerView: View {
  @EnvironmentObject private var model: AppModel
  @State private var choice: WatchingProfile?
  @State private var pin = ""
  @State private var password = ""
  @State private var confirmation = ""
  @State private var recoveringOwner = false

  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 44))
          .foregroundStyle(.secondary)
        Text(model.managementSetupRequired ? "Set Up Viewing Profiles" : "Who’s watching?")
          .font(.largeTitle.weight(.semibold))
        if model.managementSetupRequired {
          firstSetup
        } else if recoveringOwner {
          ownerRecovery
        } else if let choice {
          unlock(choice)
        } else {
          profiles
        }
        if let error = model.profileSelectionError {
          Text(error).foregroundStyle(.orange).frame(maxWidth: 480).multilineTextAlignment(.center)
        }
        if model.isSelectingProfile { ProgressView().controlSize(.small) }
        Button("Refresh Profiles") { Task { await model.reloadWatchingProfiles() } }.disabled(
          model.isSelectingProfile)
        if !model.managementSetupRequired, model.operatingMode == .host,
          model.deviceConnection?.locallyManaged == true
        {
          Button("Recover Owner PIN on This Mac…") {
            recoveringOwner = true
            pin = ""
            password = ""
          }
        }
        Text(
          "Favorites, progress and scene notes stay separate for each profile.\nProfiles without a PIN can be opened by anyone on a paired device."
        )
        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }.padding(40).frame(maxWidth: 740).frame(maxWidth: .infinity)
    }
    .accessibilityIdentifier("profile-picker")
    .task { await model.reloadWatchingProfiles() }
    .onDisappear {
      pin = ""
      password = ""
      confirmation = ""
    }
  }

  private var profiles: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180))], spacing: 24) {
      ForEach(model.watchingProfiles) { profile in
        Button {
          pin = ""
          if profile.pinProtectionEnabled {
            choice = profile
          } else {
            Task { _ = await model.selectWatchingProfile(profile, pin: "") }
          }
        } label: {
          VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 66))
              .symbolRenderingMode(.hierarchical)
            Text(profile.name).font(.headline).lineLimit(2)
            Label(
              profile.needsPinSetup
                ? "PIN setup required"
                : (profile.pinProtectionEnabled ? "PIN protected" : "No PIN"),
              systemImage: profile.pinProtectionEnabled ? "lock.fill" : "person.crop.circle"
            )
            .font(.caption).foregroundStyle(.secondary)
          }.padding(18).frame(maxWidth: .infinity, minHeight: 156)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).disabled(profile.needsPinSetup || model.isSelectingProfile)
          .accessibilityIdentifier("watching-profile-\(profile.id.uuidString)")
      }
    }
  }

  private func unlock(_ choice: WatchingProfile) -> some View {
    VStack(spacing: 14) {
      Text(choice.name).font(.title2.weight(.medium))
      SecureField("4–8 digit PIN", text: $pin).textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("profile-pin").onSubmit { submit(choice) }
      HStack {
        Button("Choose Another Profile") {
          self.choice = nil
          pin = ""
        }
        Button("Watch") { submit(choice) }.buttonStyle(.borderedProminent)
          .disabled(!ProfilePIN.isValid(pin) || model.isSelectingProfile).accessibilityIdentifier(
            "profile-unlock")
      }
    }.frame(width: 340).disabled(model.isSelectingProfile)
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
    guard ProfilePIN.isValid(pin), !model.isSelectingProfile else { return }
    Task { if await model.selectWatchingProfile(choice, pin: pin) { pin = "" } }
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
          password = ""
          pin = ""
          confirmation = ""
        }
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
