import AppKit
import SwiftUI

struct StorageLocationDraft: Identifiable, Equatable, Sendable {
  let id = UUID()
  let path: String
  var libraryName: String = ""
  var kind: LibraryKind = .automatic

  var suggestedName: String {
    let value = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
    return value.isEmpty ? URL(fileURLWithPath: path, isDirectory: true).path : value
  }

  var resolvedName: String? {
    let value = libraryName.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}

struct OperatingModeView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(spacing: 24) {
      Spacer()
      Image(systemName: "house.and.flag.fill")
        .font(.system(size: 58, weight: .medium))
        .symbolRenderingMode(.hierarchical)
      VStack(spacing: 8) {
        Text("Welcome to Aurelia").font(.system(size: 34, weight: .bold))
        Text("Your own media server, made simple.").foregroundStyle(.secondary)
      }
      Button {
        Task { await model.selectHostMode() }
      } label: {
        Label("Set Up This Mac", systemImage: "macstudio.fill")
          .font(.title3.bold())
          .frame(maxWidth: 360)
          .padding(.vertical, 8)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .accessibilityIdentifier("choose-host")

      Button("Connect to Another Server") { model.selectClientMode() }
        .buttonStyle(.link)
        .accessibilityIdentifier("choose-client")
      Spacer()
    }
    .padding(40)
  }
}

struct NativeHostSetupView: View {
  @EnvironmentObject private var model: AppModel
  @State private var serverName = "Aurelia on \(Host.current().localizedName ?? "This Mac")"
  @State private var username = NSUserName().count >= 3 ? NSUserName() : "owner"
  @State private var password = ""
  @State private var showsPassword = false
  @State private var showsAdvancedSetup = false
  @State private var lanPort = 43_111

  var body: some View {
    VStack(spacing: 24) {
      Spacer()
      Image(systemName: statusSymbol)
        .font(.system(size: 50, weight: .medium))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(statusColor)
      switch model.hostSnapshot.state {
      case .starting, .restarting:
        ProgressView().controlSize(.large)
        Text(
          model.hostSnapshot.state == .starting
            ? "Starting Your Server" : "Restarting Your Server"
        )
        .font(.title.bold())
      case .setupRequired:
        ownerSetup
      case .running:
        localLogin
      case .failed:
        Text("Server Host Needs Attention").font(.title.bold())
        Text(model.hostSnapshot.message ?? "The server could not start.")
          .foregroundStyle(.secondary).multilineTextAlignment(.center)
        Button("Try Again") { Task { await model.restartNativeHost() } }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("retry-server-start")
      case .stopping, .stopped:
        Text("Server Stopped").font(.title.bold())
        Button("Start Server") { Task { await model.selectHostMode() } }
          .buttonStyle(.borderedProminent)
      }
      if let error = model.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange).multilineTextAlignment(.center)
          .accessibilityIdentifier("host-setup-error")
      }
      if model.hostSnapshot.state != .starting && model.hostSnapshot.state != .restarting {
        Button("Connect to Another Server") {
          Task { await model.switchToClientMode() }
        }
        .buttonStyle(.link)
        .accessibilityIdentifier("switch-to-client")
      }
      Spacer()
    }
    .frame(maxWidth: 520)
    .frame(maxWidth: .infinity)
    .padding(36)
  }

  private var ownerSetup: some View {
    VStack(spacing: 18) {
      VStack(spacing: 6) {
        Text("Set Up This Mac").font(.title.bold())
        Text("Choose a password. Aurelia takes care of the server details.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      HStack {
        Group {
          if showsPassword {
            TextField("At least 12 characters", text: $password)
          } else {
            SecureField("At least 12 characters", text: $password)
          }
        }
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("host-owner-password")
        Button {
          showsPassword.toggle()
        } label: {
          Image(systemName: showsPassword ? "eye.slash" : "eye")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(showsPassword ? "Hide Password" : "Show Password")
      }
      if !password.isEmpty && password.count < 12 {
        Text("Use at least 12 characters.")
          .font(.caption)
          .foregroundStyle(.orange)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      Button {
        showsAdvancedSetup.toggle()
      } label: {
        HStack {
          Text("Advanced")
          Spacer()
          Image(systemName: "chevron.right")
            .rotationEffect(.degrees(showsAdvancedSetup ? 90 : 0))
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("host-advanced")

      if showsAdvancedSetup {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
          GridRow {
            Text("Server Name")
            TextField("Server name", text: $serverName)
              .accessibilityIdentifier("host-server-name")
          }
          GridRow {
            Text("Owner Name")
            TextField("Owner", text: $username)
              .accessibilityIdentifier("host-owner-name")
          }
          GridRow {
            Text("HTTPS Port")
            TextField("43111", value: $lanPort, format: .number)
          }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.top, 10)
      }
      Button("Continue") {
        Task {
          _ = await model.setupLocalOwner(
            serverName: serverName,
            username: username,
            password: password,
            confirmation: password,
            lanPort: lanPort)
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(
        serverName.trimmingCharacters(in: .whitespaces).isEmpty
          || username.trimmingCharacters(in: .whitespaces).count < 3
          || password.count < 12 || model.isWorking
      )
      .accessibilityIdentifier("create-local-server")
    }
  }

  private var localLogin: some View {
    VStack(spacing: 18) {
      Text("Welcome Back").font(.title.bold())
      Text("Sign in to the Aurelia server already stored on this Mac.")
        .foregroundStyle(.secondary).multilineTextAlignment(.center)
      TextField("Owner name", text: $username).textFieldStyle(.roundedBorder)
      SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
      Button("Sign In") {
        Task { _ = await model.loginToLocalServer(username: username, password: password) }
      }
      .buttonStyle(.borderedProminent)
      .disabled(username.isEmpty || password.isEmpty || model.isWorking)
      .accessibilityIdentifier("local-server-sign-in")
    }
  }

  private var statusSymbol: String {
    model.hostSnapshot.state == .failed ? "exclamationmark.triangle.fill" : "server.rack"
  }

  private var statusColor: Color {
    model.hostSnapshot.state == .failed ? .orange : .accentColor
  }
}

struct InitialLibrarySetupView: View {
  @EnvironmentObject private var model: AppModel
  @State private var locations: [StorageLocationDraft] = []

  var body: some View {
    VStack(spacing: 22) {
      Spacer()
      Image(systemName: "externaldrive.fill.badge.plus")
        .font(.system(size: 48)).symbolRenderingMode(.hierarchical)
      Text("Choose Storage Locations").font(.title.bold())
      Text("Select a drive or folder. Aurelia will recognize movies and TV shows for you.")
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      StorageLocationList(locations: $locations).frame(maxWidth: 620)
      Button("Choose Storage Locations…") { chooseStorageLocations(into: &locations) }
        .accessibilityIdentifier("initial-add-media-folder")
      HStack {
        Button("Skip for Now") { model.completeInitialLibrarySetup() }
          .accessibilityIdentifier("skip-library-setup")
        Button("Start Scanning") {
          Task { _ = await model.createStorageLocations(locations) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(locations.isEmpty || model.isWorking)
        .accessibilityIdentifier("start-storage-scan")
      }
      if !model.activeScans.isEmpty { ProgressView("Scanning in the background…") }
      if let error = model.errorMessage {
        Text(error).foregroundStyle(.orange).multilineTextAlignment(.center)
      }
      Spacer()
    }
    .padding(36)
  }
}

struct StorageLocationList: View {
  @Binding var locations: [StorageLocationDraft]

  var body: some View {
    VStack(spacing: 8) {
      ForEach(locations) { location in
        HStack {
          Image(systemName: "externaldrive.fill")
          VStack(alignment: .leading, spacing: 2) {
            Text(location.resolvedName ?? location.suggestedName).font(.headline)
            Text(location.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer()
          Button(role: .destructive) {
            locations.removeAll { $0.id == location.id }
          } label: {
            Image(systemName: "minus.circle.fill")
          }
          .buttonStyle(.plain)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      }
    }
  }
}

@MainActor
func chooseStorageLocations(into locations: inout [StorageLocationDraft]) {
  #if DEBUG
    let environment = ProcessInfo.processInfo.environment
    let injected =
      environment["AURELIA_UI_TEST_FOLDERS"]
      ?? environment["AURELIA_UI_TEST_FOLDER"]
    if let injected {
      let paths = injected.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
      for path in paths where !locations.contains(where: { $0.path == path }) {
        locations.append(StorageLocationDraft(path: path))
      }
      return
    }
  #endif
  let panel = NSOpenPanel()
  panel.canChooseDirectories = true
  panel.canChooseFiles = false
  panel.allowsMultipleSelection = true
  panel.prompt = "Choose Storage Locations"
  guard panel.runModal() == .OK else { return }
  for url in panel.urls where !locations.contains(where: { $0.path == url.path }) {
    locations.append(StorageLocationDraft(path: url.path))
  }
}
