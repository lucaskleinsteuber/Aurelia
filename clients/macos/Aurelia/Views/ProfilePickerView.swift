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
          "Each profile’s favorites, progress and scene notes are private.\nA viewing PIN does not unlock server management."
        )
        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }.padding(40).frame(maxWidth: 740).frame(maxWidth: .infinity)
    }
    .accessibilityIdentifier("profile-picker")
    .task { await model.reloadWatchingProfiles() }
  }

  private var profiles: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180))], spacing: 24) {
      ForEach(model.watchingProfiles) { profile in
        Button {
          choice = profile
          pin = ""
        } label: {
          VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 66))
              .symbolRenderingMode(.hierarchical)
            Text(profile.name).font(.headline).lineLimit(2)
            Label(
              profile.needsPinSetup ? "PIN setup required" : "PIN protected",
              systemImage: "lock.fill"
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
        "Confirm the existing owner password once. It becomes the shared server management password. Then choose a separate viewing PIN for the owner."
      )
      .font(.callout).foregroundStyle(.secondary)
      SecureField("Existing owner password", text: $password).textFieldStyle(.roundedBorder)
      SecureField("Owner PIN (4–8 digits)", text: $pin).textFieldStyle(.roundedBorder)
      SecureField("Confirm owner PIN", text: $confirmation).textFieldStyle(.roundedBorder)
      Text(
        "Other profiles stay locked until the owner sets their PINs in Users & Access. Your library and paired devices stay unchanged."
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
        "Recovery is available only on the server Mac when there is one active owner. The server password is required; paired devices and library data are not changed."
      )
      .font(.callout).foregroundStyle(.secondary)
      SecureField("Server management password", text: $password)
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
          "Your viewing PIN unlocks only your profile. Enter the shared server password to manage areas allowed by your role for ten minutes."
        )
        .foregroundStyle(.secondary)
        SecureField("Server management password", text: $password).textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("management-password")
        Button("Unlock Management") {
          working = true
          Task {
            defer { working = false }
            if await model.unlockManagement(password: password) { password = "" }
          }
        }.disabled(password.isEmpty || working).accessibilityIdentifier("management-unlock")
        if let error = model.errorMessage { Text(error).foregroundStyle(.orange) }
      }.padding(12)
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
  var body: some View {
    GroupBox("Viewing PIN") {
      VStack(alignment: .leading, spacing: 12) {
        SecureField("Current PIN", text: $current)
        SecureField("New PIN (4–8 digits)", text: $new)
        SecureField("Confirm new PIN", text: $confirmation)
        Button("Change PIN & Lock Profile") {
          guard let profile = model.profile else { return }
          working = true
          Task {
            defer { working = false }
            do {
              try await APIClient(profile: profile).changeProfilePIN(current: current, new: new)
              current = ""
              new = ""
              confirmation = ""
              await model.switchWatchingProfile()
            } catch { self.error = error.localizedDescription }
          }
        }.disabled(
          working || !ProfilePIN.isValid(current) || !ProfilePIN.isValid(new) || new != confirmation
        )
        if let error { Text(error).foregroundStyle(.orange) }
      }.padding(12).textFieldStyle(.roundedBorder)
    }
  }
}
