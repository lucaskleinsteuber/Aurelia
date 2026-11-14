import SwiftUI

/// The Settings tab. On iPhone a list whose rows open each page; on iPad the Mac's layout, with
/// the pages in a sidebar and the chosen one beside it in its own navigation stack, so links
/// inside a page (a storage location, a profile, Library Health) open and go back as expected.
struct IOSSettingsTab: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.horizontalSizeClass) private var sizeClass
  @StateObject private var admin = IOSAdministrationModel()
  @State private var selection: IOSSettingsPage?
  @State private var phonePath: [IOSSettingsPage] = []

  var body: some View {
    Group {
      if sizeClass == .regular {
        NavigationSplitView {
          IOSSettingsRoot(selection: $selection)
            .navigationSplitViewColumnWidth(min: 300, ideal: 340)
        } detail: {
          NavigationStack {
            if let selection {
              IOSSettingsDestination(page: selection)
            } else {
              ContentUnavailableView(
                "Settings", systemImage: "gearshape",
                description: Text("Choose a page on the left."))
            }
          }
          // A new page starts at its top level instead of inside the previous page.
          .id(selection)
        }
        .navigationSplitViewStyle(.balanced)
      } else {
        NavigationStack(path: $phonePath) {
          IOSSettingsRoot(selection: nil)
            .navigationDestination(for: IOSSettingsPage.self) { IOSSettingsDestination(page: $0) }
        }
      }
    }
    // The library tabs tint everything white; in Settings buttons and switches need a color
    // that shows they can be tapped and whether they are on.
    .tint(.blue)
    .environmentObject(admin)
    .onAppear {
      admin.attach(model)
      #if DEBUG
        // Simulator screenshots open a page directly; tests and normal use never set this.
        if IOSUITestScenario.current != nil,
          let raw = ProcessInfo.processInfo.environment["AURELIA_IOS_SETTINGS_PAGE"]
        {
          let path = raw.split(separator: "/").compactMap { IOSSettingsPage(rawValue: String($0)) }
          if sizeClass == .regular { selection = path.first } else { phonePath = path }
          return
        }
      #endif
      if sizeClass == .regular, selection == nil {
        selection = admin.permissions.storage ? .library : .playback
      }
    }
    .onChange(of: model.session?.sessionId) { _, _ in
      admin.attach(model)
      phonePath = []
    }
    .sheet(isPresented: $admin.unlockRequested, onDismiss: { admin.cancelUnlock() }) {
      IOSManagementUnlockSheet(admin: admin, serverName: model.connection?.name ?? "Aurelia")
    }
    .alert(
      "Server Administration",
      isPresented: Binding(get: { admin.alert != nil }, set: { if !$0 { admin.alert = nil } })
    ) {
      Button("OK") { admin.alert = nil }
    } message: {
      Text(admin.alert ?? "")
    }
    .overlay(alignment: .bottom) {
      if let activity = admin.activity {
        HStack(spacing: 10) {
          ProgressView()
          Text(activity).font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
      }
    }
    .animation(.easeOut(duration: 0.2), value: admin.activity)
  }
}

/// The list of pages: your profile, the server (for its owner and administrators), this device
/// and the connection. The same list is the iPhone's first screen and the iPad's sidebar.
struct IOSSettingsRoot: View {
  @EnvironmentObject private var model: IOSAppModel
  @EnvironmentObject private var admin: IOSAdministrationModel
  /// Bound on iPad, where rows choose the page beside the list.
  var selection: Binding<IOSSettingsPage?>?

  private var visibility: IOSSettingsPage.Visibility {
    IOSSettingsPage.Visibility(
      permissions: admin.permissions, supportsWishes: model.supportsWishes,
      supportsPersonalization: model.supportsProfilePersonalization,
      supportsSecurity: model.capabilities?.capabilities?.contains("security-v1") == true,
      supportsAutomation: model.capabilities?.capabilities?.contains("automation-v1") == true)
  }

  var body: some View {
    let visibility = visibility
    list {
      Section {
        HStack(spacing: 14) {
          IOSProfilePicture(
            id: model.session?.user.id, name: model.session?.user.shownName ?? "Profile",
            size: 52, pictureKey: model.session?.user.pictureKey,
            pictureRevision: model.session?.user.pictureRevision ?? 0)
          VStack(alignment: .leading, spacing: 2) {
            Text(model.session?.user.shownName ?? "Profile").font(.headline)
            Text(Self.roleLine(model.session?.user.role, server: model.connection?.name))
              .font(.subheadline).foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 4)
        Button {
          Task { await model.switchProfile() }
        } label: {
          Label("Switch Profile", systemImage: "person.2.circle")
        }
        .accessibilityIdentifier("settings-switch-profile")
      }
      if visibility.permissions.administrator {
        Section {
          ForEach(visibility.pages(in: .server)) { row($0) }
          if admin.isUnlocked {
            Button {
              Task { await admin.lock() }
            } label: {
              Label("Lock Server Management", systemImage: "lock")
            }
            .accessibilityIdentifier("admin-lock")
          }
        } header: {
          Text("Server")
        } footer: {
          Text(
            admin.isUnlocked
              ? "Server management is unlocked on this \(IOSDesign.deviceName) for a few minutes."
              : "Changes ask once for the Server Password (or Face ID), which unlocks management for ten minutes."
          )
        }
      }
      Section("You") {
        ForEach(visibility.pages(in: .you)) { row($0) }
      }
      Section("This \(IOSDesign.deviceName)") {
        ForEach(visibility.pages(in: .device)) { row($0) }
      }
      if IOSTestEdition.isActive { IOSTestToolsSection() }
      Section {
        row(.connection)
      } footer: {
        Text(
          "Aurelia \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))"
        )
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle("Settings")
  }

  @ViewBuilder
  private func list<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    if let selection {
      List(selection: selection) { content() }
    } else {
      List { content() }
    }
  }

  private func row(_ page: IOSSettingsPage) -> some View {
    NavigationLink(value: page) {
      IOSSettingsRowLabel(page: page)
    }
    // On iPad the chosen page stays marked in the sidebar, as on the Mac.
    .listRowBackground(
      selection?.wrappedValue == page
        ? RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.14))
          .padding(.horizontal, 8)
        : nil)
    .badge(page == .wishes ? model.wishBadgeCount : 0)
    .accessibilityIdentifier("settings-\(page.rawValue)")
  }

  static func roleLine(_ role: String?, server: String?) -> String {
    let name = server ?? "Aurelia Server"
    switch role {
    case "owner": return "Owner of \(name)"
    case "admin": return "Administrator on \(name)"
    default: return name
    }
  }
}

/// A row with a colored icon, the page's name and one line about what it does.
struct IOSSettingsRowLabel: View {
  let page: IOSSettingsPage

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: page.systemImage)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 30, height: 30)
        .background(Self.tint(page.group), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(page.title)
        Text(page.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
    }
    .padding(.vertical, 2)
  }

  static func tint(_ group: IOSSettingsPage.Group) -> Color {
    switch group {
    case .you: .blue
    case .server: .indigo
    case .device: .gray
    case .connection: .teal
    }
  }
}

/// The page shown for a row.
struct IOSSettingsDestination: View {
  @EnvironmentObject private var model: IOSAppModel
  let page: IOSSettingsPage

  var body: some View {
    switch page {
    case .nameAndPicture: IOSNameAndPictureView()
    case .playback: IOSPlaybackSettingsView()
    case .profilePIN: IOSProfilePINView()
    case .history: IOSWatchHistoryView()
    case .statistics: IOSStatisticsView()
    case .wishes: IOSWishesView()
    case .downloads: IOSDownloadsView(store: model.offline)
    case .library: IOSAdminLibraryView()
    case .metadata: IOSAdminMetadataView()
    case .people: IOSAdminPeopleView()
    case .security: IOSAdminSecurityView()
    case .server: IOSAdminServerView()
    case .power: IOSAdminPowerView()
    case .smartHome: IOSAdminAutomationView()
    case .updates: IOSAdminUpdatesView()
    case .device: IOSDeviceSettingsView()
    case .about: IOSAboutView()
    case .connection: IOSConnectionSettingsView()
    }
  }
}

/// Notifications and the artwork kept on this device.
struct IOSDeviceSettingsView: View {
  @EnvironmentObject private var model: IOSAppModel
  @State private var artworkBytes: Int?

  var body: some View {
    IOSAdminForm(title: "Notifications and Storage") {
      IOSAdminPageHeader(
        page: .device,
        text: "What this \(IOSDesign.deviceName) tells you, and what it keeps so Aurelia opens quickly.")
      if model.supportsWishes {
        Section {
          Toggle(isOn: Binding(
            get: { model.wishNotificationsEnabled },
            set: { enabled in Task { await model.setWishNotificationsEnabled(enabled) } }
          )) {
            IOSAdminToggleLabel(
              "Family Wish Notifications",
              "Tells you when a wish arrives in the library or someone adds “Me Too”.")
          }
          .accessibilityIdentifier("settings-wish-notifications")
        } header: {
          Text("Notifications")
        } footer: {
          Text("Alerts arrive while Aurelia is open or briefly in the background.")
        }
      }
      Section {
        LabeledContent {
          Text(artworkBytes.map { $0.formatted(.byteCount(style: .file)) } ?? "…")
        } label: {
          Label("Stored Artwork", systemImage: "photo.stack")
        }
        Button("Clear Stored Artwork") {
          Task {
            await model.artwork.removeStored()
            artworkBytes = await model.artwork.storedBytes()
          }
        }
        .disabled((artworkBytes ?? 0) == 0)
        .accessibilityIdentifier("settings-clear-artwork")
      } header: {
        Text("Storage")
      } footer: {
        Text(
          "Posters and backdrops are kept on this \(IOSDesign.deviceName) so they appear at once; clearing them only means they load again. Videos are stored only when you download them."
        )
      }
    }
    .task { artworkBytes = await model.artwork.storedBytes() }
  }
}

/// The server this device uses: its name and version, waking it, and disconnecting.
struct IOSConnectionSettingsView: View {
  @EnvironmentObject private var model: IOSAppModel
  @State private var serverVersion: String?
  @State private var confirmingDisconnect = false

  var body: some View {
    IOSAdminForm(title: "Connection") {
      IOSAdminPageHeader(
        page: .connection,
        text: "The server this \(IOSDesign.deviceName) uses. Everyone on it shares the library; each profile keeps its own progress.")
      Section("Server") {
        LabeledContent("Name", value: model.connection?.name ?? "Aurelia Server")
        LabeledContent("Version", value: serverVersion ?? "…")
      }
      Section {
        IOSWakeOnLanRows()
      } header: {
        Text("Wake-on-LAN")
      } footer: {
        Text(
          "When the server sleeps or is turned off, this \(IOSDesign.deviceName) can wake it over the home network. It only works on the same network and when the server computer allows waking."
        )
      }
      Section {
        Button(role: .destructive) {
          confirmingDisconnect = true
        } label: {
          Label("Disconnect This \(IOSDesign.deviceName)", systemImage: "xmark.circle")
        }
        .accessibilityIdentifier("settings-disconnect")
      } footer: {
        Text("Signs this \(IOSDesign.deviceName) out of the server. Connecting again needs a code from the owner.")
      }
    }
    .task { serverVersion = (try? await model.client?.serverInfo())?.version ?? "—" }
    .confirmationDialog(
      "Disconnect from this server?", isPresented: $confirmingDisconnect,
      titleVisibility: .visible
    ) {
      Button("Disconnect", role: .destructive) { Task { await model.disconnect() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      if model.canWatchOffline {
        Text("Downloads from this server are removed from this \(IOSDesign.deviceName) too.")
      }
    }
  }
}
