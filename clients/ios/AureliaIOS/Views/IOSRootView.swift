import SwiftUI

private enum IOSLibraryTab: Hashable { case home, movies, shows, search, profile }

struct IOSRootView: View {
  @EnvironmentObject private var model: IOSAppModel
  @State private var tab: IOSLibraryTab = .home

  var body: some View {
    Group {
      switch model.phase {
      case .connection: IOSConnectionView(browser: model.browser)
      case .trust: IOSServerTrustView()
      case .pairing: IOSPairingView()
      case .profiles: IOSProfilesView()
      case .library:
        TabView(selection: $tab) {
          NavigationStack { IOSHomeView() }.tabItem { Label("Home", systemImage: "house.fill") }
            .tag(
              IOSLibraryTab.home)
          NavigationStack { IOSLibraryGrid(listing: model.movies, title: "Movies") }
            .tabItem { Label("Movies", systemImage: "film") }.tag(IOSLibraryTab.movies)
          NavigationStack { IOSLibraryGrid(listing: model.shows, title: "TV Shows") }
            .tabItem { Label("TV Shows", systemImage: "tv.fill") }.tag(IOSLibraryTab.shows)
          NavigationStack { IOSBrowseDestination(section: .search) }.tabItem {
            Label("Search", systemImage: "magnifyingglass")
          }.tag(IOSLibraryTab.search)
          NavigationStack { IOSConnectionMenu() }
            .tabItem {
              Label(model.session?.user.username ?? "Profile", systemImage: "person.crop.circle")
            }
            .tag(IOSLibraryTab.profile)
        }
      }
    }
    .background(IOSDesign.canvas.ignoresSafeArea())
    .onChange(of: model.session?.sessionId) { _, _ in tab = .home }
    .alert(
      "Playback Progress",
      isPresented: Binding(
        get: { model.progressWarning != nil }, set: { if !$0 { model.progressWarning = nil } }
      )
    ) {
      Button("OK") { model.progressWarning = nil }
    } message: {
      Text(model.progressWarning ?? "")
    }
  }
}

struct IOSConnectionView: View {
  @EnvironmentObject private var model: IOSAppModel
  @ObservedObject var browser: IOSBonjourBrowser
  @State private var address = ""
  @State private var choosingOtherServer = false

  /// A saved server that is being reached, or is off, gets its own calm screen instead of the
  /// manual connection form.
  private var showsSavedServer: Bool {
    guard model.connection != nil, !choosingOtherServer else { return false }
    return model.savedServerUnreachable || (model.isBusy && model.error == nil)
  }

  var body: some View {
    Group {
      if showsSavedServer, let saved = model.connection {
        IOSSavedServerView(name: saved.name) {
          model.stopReconnecting()
          choosingOtherServer = true
        }
      } else {
        connectionForm
      }
    }
    .onChange(of: browser.servers.contains { $0.serverID == model.connection?.serverID }) {
      _, found in
      // The saved server announced itself again, so it is awake: connect right away.
      if found, model.savedServerUnreachable, !model.isBusy, !choosingOtherServer {
        Task { await model.reconnect() }
      }
    }
  }

  private var connectionForm: some View {
    ScrollView {
      VStack(spacing: IOSDesign.s(30)) {
        Image(systemName: "play.rectangle.fill").font(.system(size: IOSDesign.s(64)))
          .foregroundStyle(
            .secondary)
        Text("Aurelia").font(.system(size: IOSDesign.s(54), weight: .bold))
        Text("Connect to your server").font(.title2)
        if let error = model.error { IOSErrorText(message: error) }
        if let saved = model.connection {
          Button("Reconnect to \(saved.name)") {
            choosingOtherServer = false
            Task { await model.reconnect(userInitiated: true) }
          }.disabled(model.isBusy)
        }
        ForEach(browser.servers) { server in
          Button {
            model.inspect(address: server.baseURL.absoluteString)
          } label: {
            Label(server.name, systemImage: "desktopcomputer").frame(minWidth: IOSDesign.s(460))
          }.disabled(model.isBusy)
        }
        if browser.servers.isEmpty {
          Text(browser.errorMessage ?? "Looking for Aurelia servers…").foregroundStyle(.secondary)
        }
        VStack(spacing: IOSDesign.s(18)) {
          TextField("HTTPS server address", text: $address)
            .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
            .autocorrectionDisabled().submitLabel(.go)
            .onSubmit { model.inspect(address: address) }
          Button("Connect") { model.inspect(address: address) }
            .disabled(model.isBusy || address.trimmingCharacters(in: .whitespaces).isEmpty)
        }.frame(width: IOSDesign.s(700)).padding(.top, IOSDesign.s(18))
        if model.isBusy { ProgressView("Connecting…") }
      }.padding(IOSDesign.s(70)).frame(maxWidth: .infinity)
    }
  }
}

/// Connecting to the saved server, or telling plainly that it is off. While the hint shows, this
/// Apple TV keeps trying, so turning the server on or opening Aurelia on a Mac is enough.
struct IOSSavedServerView: View {
  @EnvironmentObject private var model: IOSAppModel
  let name: String
  let chooseOtherServer: () -> Void

  var body: some View {
    VStack(spacing: IOSDesign.s(34)) {
      if model.savedServerUnreachable {
        Image(systemName: "power").font(.system(size: IOSDesign.s(72), weight: .medium))
          .foregroundStyle(.secondary)
        VStack(spacing: IOSDesign.s(18)) {
          Text("The Server Is Off").font(.system(size: IOSDesign.s(56), weight: .bold))
          Text(
            "“\(name)” isn’t answering. Turn on the computer the server runs on, or open Aurelia on your Mac to wake it."
          )
          .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
          .frame(maxWidth: IOSDesign.s(1100))
          Text("This Apple TV connects by itself as soon as the server is on.")
            .font(.title3).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        ZStack {
          if model.isBusy {
            ProgressView("Waiting for the server…")
          } else {
            Button("Try Again") { Task { await model.reconnect(userInitiated: true) } }
              .accessibilityIdentifier("tv-server-retry")
          }
        }.frame(minHeight: IOSDesign.s(110))
      } else {
        ProgressView().scaleEffect(1.6).frame(height: IOSDesign.s(90))
        Text("Connecting to \(name)…").font(.system(size: IOSDesign.s(40), weight: .semibold))
      }
      Button("Connect to Another Server", action: chooseOtherServer)
        .font(.system(size: IOSDesign.s(24))).padding(.top, IOSDesign.s(20))
        .accessibilityIdentifier("tv-other-server")
    }
    .padding(IOSDesign.s(80)).frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("tv-server-asleep")
    .task(id: model.savedServerUnreachable) {
      // Tries again every 20 seconds while the hint is shown.
      guard model.savedServerUnreachable else { return }
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(20)) } catch { return }
        if !model.isBusy { await model.reconnect() }
      }
    }
  }
}

struct IOSServerTrustView: View {
  @EnvironmentObject private var model: IOSAppModel

  var body: some View {
    VStack(spacing: IOSDesign.s(30)) {
      Text(model.inspected?.info.name ?? "Aurelia Server").font(.largeTitle.bold())
      Text("Confirm this fingerprint on your Mac.").font(.title3)
      Text(IOSServerIdentity.display(model.inspected?.fingerprint ?? ""))
        .font(.system(size: IOSDesign.s(23), weight: .medium, design: .monospaced))
        .multilineTextAlignment(.center).frame(maxWidth: IOSDesign.s(980))
      Text(model.inspected?.baseURL.host ?? "").foregroundStyle(.secondary)
      if let error = model.error { IOSErrorText(message: error) }
      HStack(spacing: IOSDesign.s(32)) {
        Button("Back") { model.cancelPairing() }
        Button("Trust and Continue") { model.beginPairing() }.buttonStyle(
          IOSButtonStyle(kind: .primary))
      }.disabled(model.isBusy)
    }.padding(IOSDesign.s(80)).frame(maxWidth: .infinity, maxHeight: .infinity)
      .iosBackCommand { model.cancelPairing() }
  }
}

struct IOSPairingView: View {
  @EnvironmentObject private var model: IOSAppModel

  var body: some View {
    VStack(spacing: IOSDesign.s(28)) {
      Text("Approve this device").font(.largeTitle.bold())
      Text("Enter this code in Aurelia on your Mac.").font(.title3)
      if let pairing = model.pairing {
        Text(pairing.code).font(
          .system(size: IOSDesign.s(76), weight: .semibold, design: .monospaced)
        )
        .tracking(10).accessibilityLabel(pairing.code.map(String.init).joined(separator: " "))
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let remaining = max(
            0,
            Int(
              (IOSServerDate.parse(pairing.expiresAt) ?? context.date).timeIntervalSince(
                context.date)))
          Text(
            remaining > 0
              ? "Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))"
              : "Code expired"
          )
          .foregroundStyle(.secondary)
        }
      }
      if let error = model.error {
        IOSErrorText(message: error)
        if model.connection?.pendingAcknowledgement != nil {
          Button("Finish Pairing") { Task { await model.reconnect() } }.disabled(model.isBusy)
        } else {
          Button("New Code") { model.beginPairing() }.disabled(model.isBusy)
        }
      } else {
        ProgressView("Waiting for approval…")
      }
      Button("Cancel") { model.cancelPairing() }
    }.padding(IOSDesign.s(80)).frame(maxWidth: .infinity, maxHeight: .infinity)
      .iosBackCommand { model.cancelPairing() }
  }
}

struct IOSConnectionMenu: View {
  @EnvironmentObject private var model: IOSAppModel
  @State private var confirmingDisconnect = false

  var body: some View {
    VStack(spacing: IOSDesign.s(44)) {
      VStack(spacing: IOSDesign.s(18)) {
        IOSProfilePicture(
          id: model.session?.user.id, name: model.session?.user.username ?? "Profile", size: 150)
        Text(model.session?.user.username ?? "Profile").font(
          .system(size: IOSDesign.s(48), weight: .bold))
        Text(model.connection?.name ?? "Aurelia Server").font(.system(size: IOSDesign.s(24)))
          .foregroundStyle(.secondary)
      }
      VStack(spacing: IOSDesign.s(22)) {
        NavigationLink {
          IOSPlaybackSettingsView()
        } label: {
          Label("Playback Settings", systemImage: "play.rectangle").frame(width: IOSDesign.s(560))
        }.accessibilityIdentifier("profile-playback-settings")
        Button {
          Task { await model.switchProfile() }
        } label: {
          Label("Switch Profile", systemImage: "person.2").frame(width: IOSDesign.s(560))
        }
        Button(role: .destructive) {
          confirmingDisconnect = true
        } label: {
          Label("Disconnect This Device", systemImage: "xmark.circle").frame(
            width: IOSDesign.s(560))
        }
      }.buttonStyle(IOSButtonStyle())
      Text(
        "Aurelia \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))"
      ).font(.system(size: IOSDesign.s(20))).foregroundStyle(.tertiary)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(IOSDesign.canvas.ignoresSafeArea())
      .confirmationDialog(
        "Disconnect from this server?", isPresented: $confirmingDisconnect,
        titleVisibility: .visible
      ) {
        Button("Disconnect", role: .destructive) { Task { await model.disconnect() } }
        Button("Cancel", role: .cancel) {}
      }
  }
}

struct IOSErrorText: View {
  let message: String
  var body: some View {
    Text(message).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
      .frame(maxWidth: IOSDesign.s(1000)).accessibilityAddTraits(.updatesFrequently)
  }
}
