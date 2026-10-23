import SwiftUI

private enum TVLibraryTab: Hashable { case home, movies, shows, search, profile }

struct TVRootView: View {
  @EnvironmentObject private var model: TVAppModel
  @State private var tab: TVLibraryTab = .home

  var body: some View {
    Group {
      switch model.phase {
      case .connection: TVConnectionView(browser: model.browser)
      case .trust: TVServerTrustView()
      case .pairing: TVPairingView()
      case .profiles: TVProfilesView()
      case .library:
        TabView(selection: $tab) {
          NavigationStack { TVHomeView() }.tabItem { Label("Home", systemImage: "house.fill") }.tag(
            TVLibraryTab.home)
          NavigationStack { TVLibraryGrid(listing: model.movies, title: "Movies") }
            .tabItem { Label("Movies", systemImage: "film") }.tag(TVLibraryTab.movies)
          NavigationStack { TVLibraryGrid(listing: model.shows, title: "TV Shows") }
            .tabItem { Label("TV Shows", systemImage: "tv.fill") }.tag(TVLibraryTab.shows)
          NavigationStack { TVBrowseDestination(section: .search) }.tabItem {
            Label("Search", systemImage: "magnifyingglass")
          }.tag(TVLibraryTab.search)
          NavigationStack { TVConnectionMenu() }
            .tabItem {
              Label(model.session?.user.username ?? "Profile", systemImage: "person.crop.circle")
            }
            .tag(TVLibraryTab.profile)
        }
      }
    }
    .background(TVDesign.canvas.ignoresSafeArea())
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

struct TVConnectionView: View {
  @EnvironmentObject private var model: TVAppModel
  @ObservedObject var browser: TVBonjourBrowser
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
        TVSavedServerView(name: saved.name) {
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
      VStack(spacing: 30) {
        Image(systemName: "play.rectangle.fill").font(.system(size: 64)).foregroundStyle(
          .secondary)
        Text("Aurelia").font(.system(size: 54, weight: .bold))
        Text("Connect to your server").font(.title2)
        if let error = model.error { TVErrorText(message: error) }
        if let saved = model.connection {
          Button("Reconnect to \(saved.name)") {
            choosingOtherServer = false
            Task { await model.reconnect() }
          }.disabled(model.isBusy)
        }
        ForEach(browser.servers) { server in
          Button {
            model.inspect(address: server.baseURL.absoluteString)
          } label: {
            Label(server.name, systemImage: "desktopcomputer").frame(minWidth: 460)
          }.disabled(model.isBusy)
        }
        if browser.servers.isEmpty {
          Text(browser.errorMessage ?? "Looking for Aurelia servers…").foregroundStyle(.secondary)
        }
        VStack(spacing: 18) {
          TextField("HTTPS server address", text: $address)
            .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
            .autocorrectionDisabled().submitLabel(.go)
            .onSubmit { model.inspect(address: address) }
          Button("Connect") { model.inspect(address: address) }
            .disabled(model.isBusy || address.trimmingCharacters(in: .whitespaces).isEmpty)
        }.frame(width: 700).padding(.top, 18)
        if model.isBusy { ProgressView("Connecting…") }
      }.padding(70).frame(maxWidth: .infinity)
    }
  }
}

/// Connecting to the saved server, or telling plainly that it is off. While the hint shows, this
/// Apple TV keeps trying, so turning the server on or opening Aurelia on a Mac is enough.
struct TVSavedServerView: View {
  @EnvironmentObject private var model: TVAppModel
  let name: String
  let chooseOtherServer: () -> Void

  var body: some View {
    VStack(spacing: 34) {
      if model.savedServerUnreachable {
        Image(systemName: "power").font(.system(size: 72, weight: .medium))
          .foregroundStyle(.secondary)
        VStack(spacing: 18) {
          Text("The Server Is Off").font(.system(size: 56, weight: .bold))
          Text(
            "“\(name)” isn’t answering. Turn on the computer the server runs on, or open Aurelia on your Mac to wake it."
          )
          .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
          .frame(maxWidth: 1100)
          Text("This Apple TV connects by itself as soon as the server is on.")
            .font(.title3).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        ZStack {
          if model.isBusy {
            ProgressView("Waiting for the server…")
          } else {
            Button("Try Again") { Task { await model.reconnect() } }
              .accessibilityIdentifier("tv-server-retry")
          }
        }.frame(minHeight: 110)
      } else {
        ProgressView().scaleEffect(1.6).frame(height: 90)
        Text("Connecting to \(name)…").font(.system(size: 40, weight: .semibold))
      }
      Button("Connect to Another Server", action: chooseOtherServer)
        .font(.system(size: 24)).padding(.top, 20)
        .accessibilityIdentifier("tv-other-server")
    }
    .padding(80).frame(maxWidth: .infinity, maxHeight: .infinity)
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

struct TVServerTrustView: View {
  @EnvironmentObject private var model: TVAppModel

  var body: some View {
    VStack(spacing: 30) {
      Text(model.inspected?.info.name ?? "Aurelia Server").font(.largeTitle.bold())
      Text("Confirm this fingerprint on your Mac.").font(.title3)
      Text(TVServerIdentity.display(model.inspected?.fingerprint ?? ""))
        .font(.system(size: 23, weight: .medium, design: .monospaced))
        .multilineTextAlignment(.center).frame(maxWidth: 980)
      Text(model.inspected?.baseURL.host ?? "").foregroundStyle(.secondary)
      if let error = model.error { TVErrorText(message: error) }
      HStack(spacing: 32) {
        Button("Back") { model.cancelPairing() }
        Button("Trust and Continue") { model.beginPairing() }.buttonStyle(
          TVButtonStyle(kind: .primary))
      }.disabled(model.isBusy)
    }.padding(80).frame(maxWidth: .infinity, maxHeight: .infinity)
      .onExitCommand { model.cancelPairing() }
  }
}

struct TVPairingView: View {
  @EnvironmentObject private var model: TVAppModel

  var body: some View {
    VStack(spacing: 28) {
      Text("Approve this Apple TV").font(.largeTitle.bold())
      Text("Enter this code in Aurelia on your Mac.").font(.title3)
      if let pairing = model.pairing {
        Text(pairing.code).font(.system(size: 76, weight: .semibold, design: .monospaced))
          .tracking(10).accessibilityLabel(pairing.code.map(String.init).joined(separator: " "))
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let remaining = max(
            0,
            Int(
              (TVServerDate.parse(pairing.expiresAt) ?? context.date).timeIntervalSince(
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
        TVErrorText(message: error)
        if model.connection?.pendingAcknowledgement != nil {
          Button("Finish Pairing") { Task { await model.reconnect() } }.disabled(model.isBusy)
        } else {
          Button("New Code") { model.beginPairing() }.disabled(model.isBusy)
        }
      } else {
        ProgressView("Waiting for approval…")
      }
      Button("Cancel") { model.cancelPairing() }
    }.padding(80).frame(maxWidth: .infinity, maxHeight: .infinity)
      .onExitCommand { model.cancelPairing() }
  }
}

struct TVConnectionMenu: View {
  @EnvironmentObject private var model: TVAppModel
  @State private var confirmingDisconnect = false

  var body: some View {
    VStack(spacing: 44) {
      VStack(spacing: 18) {
        TVProfilePicture(
          id: model.session?.user.id, name: model.session?.user.username ?? "Profile", size: 150)
        Text(model.session?.user.username ?? "Profile").font(.system(size: 48, weight: .bold))
        Text(model.connection?.name ?? "Aurelia Server").font(.system(size: 24))
          .foregroundStyle(.secondary)
      }
      VStack(spacing: 22) {
        NavigationLink {
          TVPlaybackSettingsView()
        } label: {
          Label("Playback Settings", systemImage: "play.rectangle").frame(width: 560)
        }.accessibilityIdentifier("profile-playback-settings")
        Button {
          Task { await model.switchProfile() }
        } label: {
          Label("Switch Profile", systemImage: "person.2").frame(width: 560)
        }
        Button(role: .destructive) {
          confirmingDisconnect = true
        } label: {
          Label("Disconnect Apple TV", systemImage: "xmark.circle").frame(width: 560)
        }
      }.buttonStyle(TVButtonStyle()).focusSection()
      Text(
        "Aurelia \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))"
      ).font(.system(size: 20)).foregroundStyle(.tertiary)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(TVDesign.canvas.ignoresSafeArea())
      .confirmationDialog(
        "Disconnect from this server?", isPresented: $confirmingDisconnect,
        titleVisibility: .visible
      ) {
        Button("Disconnect", role: .destructive) { Task { await model.disconnect() } }
        Button("Cancel", role: .cancel) {}
      }
  }
}

struct TVErrorText: View {
  let message: String
  var body: some View {
    Text(message).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
      .frame(maxWidth: 1000).accessibilityAddTraits(.updatesFrequently)
  }
}
