import AppKit
import SwiftUI

struct AppSettingsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var showingAddLibrary = false
  @State private var libraryToRemove: LibrarySummary?
  @State private var showingSwitchConfirmation = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text("Server").font(.title.bold())
        if model.operatingMode == .host { hostStatus }
        if let profile = model.profile {
          connection(profile)
          if profile.user?.role.canManageLibraries == true { libraryManagement }
          deviceManagement
        } else if model.operatingMode != .host {
          ContentUnavailableView(
            "No Server Connected",
            systemImage: "network.slash",
            description: Text("Connect from the main window."))
        }
      }
      .padding(24)
    }
    .frame(width: 680, height: 680)
    .task { await model.reloadAdministration() }
    .sheet(isPresented: $showingAddLibrary) {
      AddLibraryView { draft in
        Task { _ = await model.addLibrary(name: draft.name, path: draft.path, kind: draft.kind) }
      }
    }
    .confirmationDialog(
      "Remove \(libraryToRemove?.name ?? "Library")?",
      isPresented: Binding(
        get: { libraryToRemove != nil },
        set: { if !$0 { libraryToRemove = nil } }),
      titleVisibility: .visible
    ) {
      if let library = libraryToRemove {
        Button("Remove Database Entries", role: .destructive) {
          Task { await model.removeLibrary(id: library.id) }
          libraryToRemove = nil
        }
      }
    } message: {
      Text("Media files are never deleted or changed.")
    }
    .confirmationDialog(
      "Stop hosting on this Mac?",
      isPresented: $showingSwitchConfirmation,
      titleVisibility: .visible
    ) {
      Button("Stop Server and Switch to Client", role: .destructive) {
        Task { await model.switchToClientMode() }
      }
    } message: {
      Text("Server data and media files remain untouched.")
    }
  }

  private var hostStatus: some View {
    GroupBox("This Mac") {
      VStack(alignment: .leading, spacing: 12) {
        LabeledContent("Status", value: model.hostSnapshot.state.rawValue.capitalized)
        if let info = model.hostSnapshot.serverInfo {
          LabeledContent("LAN Port", value: String(info.lanHttpsPort ?? 43_111))
          if let fingerprint = info.publicKeyFingerprint {
            LabeledContent("Fingerprint", value: FingerprintFormatter.display(fingerprint))
          }
        }
        if let message = model.hostSnapshot.message {
          Text(message).font(.caption).foregroundStyle(.orange)
        }
        HStack {
          Button("Restart Server") { Task { await model.restartNativeHost() } }
          Button("Switch to Client…", role: .destructive) { showingSwitchConfirmation = true }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
    }
  }

  private func connection(_ profile: StoredServerProfile) -> some View {
    GroupBox("Connection") {
      VStack(alignment: .leading, spacing: 10) {
        LabeledContent("Name", value: profile.name)
        LabeledContent("Address", value: profile.baseURL.absoluteString)
        LabeledContent("Fingerprint", value: FingerprintFormatter.display(profile.publicKeyFingerprint))
        if let user = profile.user {
          LabeledContent("Signed In", value: "\(user.username) · \(user.role.rawValue.capitalized)")
        }
        if model.operatingMode != .host {
          Divider()
          Button("Disconnect This Mac", role: .destructive) {
            Task { await model.disconnect() }
          }
          .accessibilityIdentifier("disconnect-server")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
    }
  }

  private var libraryManagement: some View {
    GroupBox("Libraries") {
      VStack(spacing: 10) {
        ForEach(model.libraries) { library in
          HStack {
            Image(systemName: library.kind == .movies ? "film" : "tv")
            VStack(alignment: .leading, spacing: 2) {
              Text(library.name).font(.headline)
              Text(library.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(library.availability.rawValue.capitalized)
              .font(.caption).foregroundStyle(.secondary)
            Button("Scan") { Task { await model.scanLibrary(id: library.id) } }
            Button(role: .destructive) { libraryToRemove = library } label: {
              Image(systemName: "trash")
            }
          }
          if library.id != model.libraries.last?.id { Divider() }
        }
        if !model.activeScans.isEmpty {
          ProgressView("Scanning \(model.activeScans.count) library item(s)…")
        }
        Button("Add Media Folder…") { showingAddLibrary = true }
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(8)
    }
  }

  private var deviceManagement: some View {
    GroupBox("Devices") {
      VStack(alignment: .leading, spacing: 12) {
        if let code = model.pairingCode {
          HStack {
            VStack(alignment: .leading) {
              Text(code.code).font(.system(.title2, design: .monospaced, weight: .bold))
              Text("Expires \(code.expiresAt)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(code.code, forType: .string)
            }
          }
        }
        Button("Pair Another Device") { Task { await model.generatePairingCode() } }
          .buttonStyle(.borderedProminent)
        ForEach(model.sessions) { session in
          HStack {
            VStack(alignment: .leading) {
              Text(session.deviceName)
              Text(session.isCurrent ? "This device" : "Last used \(session.lastSeenAt)")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !session.isCurrent && session.revokedAt == nil {
              Button("Revoke", role: .destructive) {
                Task { await model.revokeSession(id: session.id) }
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
    }
  }
}
