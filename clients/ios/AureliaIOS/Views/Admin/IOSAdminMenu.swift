import SwiftUI

/// Settings › Server Administration: the Mac's categories for the owner and administrators.
struct IOSAdministrationSection: View {
  @EnvironmentObject private var model: IOSAppModel
  @EnvironmentObject private var admin: IOSAdministrationModel
  @State private var powerAvailable = false
  @State private var updatesAvailable = false

  var body: some View {
    let permissions = admin.permissions
    if permissions.administrator {
      Section {
        if permissions.storage {
          NavigationLink {
            IOSAdminLibraryView()
          } label: {
            Label("Library", systemImage: "externaldrive")
          }.accessibilityIdentifier("admin-library")
        }
        NavigationLink {
          IOSAdminMetadataView()
        } label: {
          Label("Metadata", systemImage: "text.badge.star")
        }.accessibilityIdentifier("admin-metadata")
        NavigationLink {
          IOSAdminPeopleView()
        } label: {
          Label("Profiles and Devices", systemImage: "person.2.badge.gearshape")
        }.accessibilityIdentifier("admin-people")
        if permissions.owner {
          NavigationLink {
            IOSAdminServerView()
          } label: {
            Label("Server", systemImage: "server.rack")
          }.accessibilityIdentifier("admin-server")
          if powerAvailable {
            NavigationLink {
              IOSAdminPowerView()
            } label: {
              Label("Power", systemImage: "bolt")
            }.accessibilityIdentifier("admin-power")
          }
          if updatesAvailable {
            NavigationLink {
              IOSAdminUpdatesView()
            } label: {
              Label("Server Updates", systemImage: "arrow.down.circle.dotted")
            }.accessibilityIdentifier("admin-updates")
          }
        }
        if permissions.storage {
          NavigationLink {
            IOSAdminDangerZoneView()
          } label: {
            Label("Danger Zone", systemImage: "exclamationmark.triangle")
          }.accessibilityIdentifier("admin-danger")
        }
        if admin.isUnlocked {
          Button {
            Task { await admin.lock() }
          } label: {
            Label("Lock Server Management", systemImage: "lock")
          }.accessibilityIdentifier("admin-lock")
        }
      } header: {
        Text("Server Administration")
      } footer: {
        Text(
          admin.isUnlocked
            ? "Server management is unlocked for a few minutes on this \(IOSDesign.deviceName)."
            : "Changes that need it ask for the Server Password, which unlocks management for ten minutes."
        )
      }
      .task(id: model.session?.sessionId) {
        guard permissions.owner, let client = admin.client else { return }
        powerAvailable = (try? await client.serverPower())?.available ?? false
        updatesAvailable = (try? await client.serverUpdates())?.available ?? false
      }
    }
  }
}

/// Wake-on-LAN for the saved server, shown in Settings › Server.
struct IOSWakeOnLanRows: View {
  @EnvironmentObject private var model: IOSAppModel

  var body: some View {
    let status = model.wakeOnLanStatus
    LabeledContent("Wake-on-LAN") {
      Text(status.summary).multilineTextAlignment(.trailing)
    }
    .accessibilityIdentifier("settings-wake-status")
    if status.canWake {
      Button {
        model.sendWakeSignal()
      } label: {
        Label("Send Wake Signal", systemImage: "power")
      }
      .accessibilityIdentifier("settings-wake-send")
    }
  }
}
