import AppKit
import SwiftUI

struct LibraryDraft: Identifiable, Equatable, Sendable {
  let id = UUID()
  var name: String
  var path: String
  var kind: LibraryKind
}

struct OperatingModeView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(spacing: 28) {
      Spacer()
      Image(systemName: "house.and.flag.fill")
        .font(.system(size: 58, weight: .medium))
        .symbolRenderingMode(.hierarchical)
      VStack(spacing: 8) {
        Text("Welcome to Aurelia Home").font(.system(size: 34, weight: .bold))
        Text("Host your own media server on this Mac, or connect to one you already have.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      HStack(spacing: 18) {
        modeCard(
          title: "Host on This Mac",
          description: "This Mac runs the server while Aurelia Home is open.",
          symbol: "macstudio.fill",
          identifier: "choose-host") {
            Task { await model.selectHostMode() }
          }
        modeCard(
          title: "Connect to Existing Server",
          description: "Find an Aurelia Home server on your local network.",
          symbol: "network",
          identifier: "choose-client") {
            model.selectClientMode()
          }
      }
      .frame(maxWidth: 760)
      Spacer()
    }
    .padding(40)
  }

  private func modeCard(
    title: String,
    description: String,
    symbol: String,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 16) {
        Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.tint)
        Text(title).font(.title2.bold())
        Text(description).foregroundStyle(.secondary).multilineTextAlignment(.leading)
        Spacer()
        Label("Continue", systemImage: "arrow.right").font(.headline)
      }
      .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
      .padding(24)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
      .contentShape(RoundedRectangle(cornerRadius: 22))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
  }
}

struct NativeHostSetupView: View {
  @EnvironmentObject private var model: AppModel
  @State private var serverName = "Aurelia Home on \(Host.current().localizedName ?? "This Mac")"
  @State private var username = ""
  @State private var password = ""
  @State private var confirmation = ""
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
        Text(model.hostSnapshot.state == .starting ? "Starting Your Server" : "Restarting Your Server")
          .font(.title.bold())
      case .setupRequired:
        ownerSetup
      case .running:
        localLogin
      case .failed:
        Text("Server Host Needs Attention").font(.title.bold())
        Text(model.hostSnapshot.message ?? "The server could not start.")
          .foregroundStyle(.secondary).multilineTextAlignment(.center)
        Button("Restart Server") { Task { await model.restartNativeHost() } }
          .buttonStyle(.borderedProminent)
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
      Spacer()
    }
    .frame(maxWidth: 560)
    .frame(maxWidth: .infinity)
    .padding(36)
  }

  private var ownerSetup: some View {
    VStack(spacing: 18) {
      VStack(spacing: 6) {
        Text("Create Your Aurelia Home Server").font(.title.bold())
        Text("Your media stays on this Mac. Nothing is uploaded or converted.")
          .foregroundStyle(.secondary)
      }
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
        GridRow {
          Text("Server Name")
          TextField("Server name", text: $serverName)
            .accessibilityIdentifier("host-server-name")
        }
        GridRow {
          Text("Owner Username")
          TextField("Username", text: $username)
            .accessibilityIdentifier("host-owner-name")
        }
        GridRow {
          Text("Password")
          SecureField("At least 12 characters", text: $password)
            .accessibilityIdentifier("host-owner-password")
        }
        GridRow {
          Text("Confirm Password")
          SecureField("Repeat password", text: $confirmation)
            .accessibilityIdentifier("host-owner-confirmation")
        }
        GridRow {
          Text("HTTPS Port")
          TextField("43111", value: $lanPort, format: .number).frame(maxWidth: 130)
        }
      }
      .textFieldStyle(.roundedBorder)
      Button("Create Server") {
        Task {
          _ = await model.setupLocalOwner(
            serverName: serverName,
            username: username,
            password: password,
            confirmation: confirmation,
            lanPort: lanPort)
        }
      }
      .buttonStyle(.borderedProminent)
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
      Text("Sign In to This Server").font(.title.bold())
      Text("An existing Aurelia Home library was found and will not be overwritten.")
        .foregroundStyle(.secondary).multilineTextAlignment(.center)
      TextField("Username", text: $username).textFieldStyle(.roundedBorder)
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
  @State private var drafts: [LibraryDraft] = []
  @State private var showingAddLibrary = false

  var body: some View {
    VStack(spacing: 22) {
      Spacer()
      Image(systemName: "externaldrive.fill.badge.plus")
        .font(.system(size: 48)).symbolRenderingMode(.hierarchical)
      Text("Add Your Media Libraries").font(.title.bold())
      Text("Choose only the folders you want Aurelia Home Server to scan.")
        .foregroundStyle(.secondary)
      VStack(spacing: 8) {
        ForEach(drafts) { draft in
          HStack {
            Image(systemName: draft.kind == .movies ? "film" : "tv")
            VStack(alignment: .leading) {
              Text(draft.name).font(.headline)
              Text(draft.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(role: .destructive) { drafts.removeAll { $0.id == draft.id } } label: {
              Image(systemName: "minus.circle.fill")
            }.buttonStyle(.plain)
          }
          .padding(12)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
      }
      .frame(maxWidth: 620)
      Button("Add Media Folder") { showingAddLibrary = true }
        .accessibilityIdentifier("initial-add-media-folder")
      HStack {
        Button("Skip for Now") { model.completeInitialLibrarySetup() }
          .accessibilityIdentifier("skip-library-setup")
        Button("Create Libraries and Start Scan") {
          Task { _ = await model.createLibraries(drafts) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(drafts.isEmpty || model.isWorking)
      }
      if let error = model.errorMessage {
        Text(error).foregroundStyle(.orange).multilineTextAlignment(.center)
      }
      Spacer()
    }
    .padding(36)
    .sheet(isPresented: $showingAddLibrary) {
      AddLibraryView { draft in drafts.append(draft) }
    }
  }
}

struct AddLibraryView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var path = ""
  @State private var kind: LibraryKind = .movies
  let onAdd: (LibraryDraft) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Add Media Folder").font(.title2.bold())
      Picker("Library Type", selection: $kind) {
        ForEach(LibraryKind.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      TextField("Library name", text: $name).textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("library-name")
      HStack {
        TextField("Folder", text: $path).textFieldStyle(.roundedBorder).disabled(true)
          .accessibilityIdentifier("library-path")
        Button("Choose…") { chooseFolder() }
          .accessibilityIdentifier("choose-media-folder")
      }
      Text("Aurelia Home reads media in place and never copies or converts it.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Add") {
          onAdd(LibraryDraft(name: name, path: path, kind: kind))
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || path.isEmpty)
        .accessibilityIdentifier("confirm-add-library")
      }
    }
    .padding(24)
    .frame(width: 540)
  }

  private func chooseFolder() {
    #if DEBUG
      if let injectedPath = ProcessInfo.processInfo.environment["AURELIA_HOME_UI_TEST_FOLDER"],
        injectedPath.hasPrefix("/")
      {
        let url = URL(fileURLWithPath: injectedPath, isDirectory: true)
        path = url.path
        if name.isEmpty { name = url.lastPathComponent }
        return
      }
    #endif
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose Media Folder"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    path = url.path
    if name.isEmpty { name = url.lastPathComponent }
  }
}
