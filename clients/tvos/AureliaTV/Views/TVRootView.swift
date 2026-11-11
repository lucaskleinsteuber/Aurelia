import SwiftUI

private enum TVLibraryTab: Hashable { case home, movies, shows, search, profile }

struct TVRootView: View {
  @EnvironmentObject private var model: TVAppModel
  @State private var tab: TVLibraryTab = .home
  @State private var introductionReplay = false

  private var guide: TVSetupGuide { model.setupGuide }
  private var tabIndex: Binding<Int> {
    let order: [TVLibraryTab] = [.home, .movies, .shows, .search, .profile]
    return Binding(
      get: { order.firstIndex(of: tab) ?? 0 },
      set: { tab = order[min(max($0, 0), order.count - 1)] })
  }

  var body: some View {
    Group {
      if introductionReplay {
        TVSetupIntroductionView(guide: guide, replay: true) { introductionReplay = false }
      } else if model.phase == .connection, model.connection == nil, !guide.introSeen {
        TVSetupIntroductionView(guide: guide)
      } else if model.phase == .library, guide.isGuiding {
        TVSetupDoneView(guide: guide).overlay(alignment: .top) { stepBar(.done) }
      } else {
        phaseView
      }
    }
    .background(TVDesign.canvas.ignoresSafeArea())
    .onReceive(NotificationCenter.default.publisher(for: .tvShowIntroduction)) { _ in
      introductionReplay = true
    }
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

  @ViewBuilder
  private func stepBar(_ step: TVSetupStep) -> some View {
    if guide.isGuiding {
      TVSetupStepBar(current: step).padding(.top, 30)
    }
  }

  @ViewBuilder
  private var phaseView: some View {
    Group {
      switch model.phase {
      case .connection:
        TVConnectionView(browser: model.browser).overlay(alignment: .top) { stepBar(.connect) }
      case .trust: TVServerTrustView().overlay(alignment: .top) { stepBar(.approve) }
      case .pairing: TVPairingView().overlay(alignment: .top) { stepBar(.approve) }
      case .profiles: TVProfilesView().overlay(alignment: .top) { stepBar(.profile) }
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
              Label(model.session?.user.shownName ?? "Profile", systemImage: "person.crop.circle")
            }
            .tag(TVLibraryTab.profile)
        }
        .overlay {
          if guide.tourPending, !guide.isGuiding {
            TVLibraryTour(tab: tabIndex) { guide.tourShown() }
          }
        }
      }
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
            Task { await model.reconnect(userInitiated: true) }
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
          Text(model.savedServerAppHost.map { "Start Aurelia on Your \($0)" } ?? "The Server Is Off").font(.system(size: 56, weight: .bold))
          Text(
            model.savedServerAppHost.map {
              "“\(name)” runs inside the Aurelia app on a \($0). Open Aurelia there, or wake the \($0), and this Apple TV connects by itself."
            }
              ?? "“\(name)” isn’t answering. Turn on the computer the server runs on, or open Aurelia on your Mac to wake it."
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
            Button("Try Again") { Task { await model.reconnect(userInitiated: true) } }
              .accessibilityIdentifier("tv-server-retry")
          }
        }.frame(minHeight: 110)
      } else {
        ProgressView().scaleEffect(1.6).frame(height: 90)
        Text("Connecting to \(name)…").font(.system(size: 40, weight: .semibold))
      }
      HStack(spacing: 30) {
        Button("Connect to Another Server", action: chooseOtherServer)
          .accessibilityIdentifier("tv-other-server")
      }.font(.system(size: 24)).padding(.top, 20)
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
      Text("Confirm this fingerprint on your Mac or Linux computer.").font(.title3)
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
  @State private var code = ""

  var body: some View {
    VStack(spacing: 28) {
      Text("Enter the Code").font(.largeTitle.bold())
      Text("Your Mac or Linux computer shows the code; you type it here.").font(.title3)
      VStack(alignment: .leading, spacing: 10) {
        Text("1. On the computer that runs Aurelia, open Settings › Profiles and Devices.")
        Text("2. Choose Create Code. On a Linux server without screen, run aurelia pair.")
        Text("3. Type the 8 digits here. A code works once and for five minutes.")
      }
      .font(.callout).foregroundStyle(.secondary).frame(maxWidth: 1100, alignment: .leading)
      TextField("8-digit code", text: $code)
        .keyboardType(.numberPad)
        .font(.system(size: 48, weight: .semibold, design: .monospaced))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 560)
        .onChange(of: code) { _, value in
          let digits = String(value.filter(\.isNumber).prefix(8))
          if digits != value { code = digits }
        }
        .onSubmit { model.pair(code: code) }
        .accessibilityLabel("Pairing code")
        .accessibilityIdentifier("pairing-code")
      if let error = model.error { TVErrorText(message: error) }
      HStack(spacing: 32) {
        Button("Cancel") { model.cancelPairing() }
        Button {
          model.pair(code: code)
        } label: {
          if model.isBusy { ProgressView() } else { Text("Pair This Apple TV") }
        }
        .buttonStyle(TVButtonStyle(kind: .primary))
        .disabled(code.count != 8 || model.isBusy)
      }
    }.padding(80).frame(maxWidth: .infinity, maxHeight: .infinity)
      .onExitCommand { model.cancelPairing() }
  }
}

struct TVConnectionMenu: View {
  @EnvironmentObject private var model: TVAppModel
  @State private var confirmingDisconnect = false

  var body: some View {
    ScrollView {
      VStack(spacing: 44) {
        VStack(spacing: 18) {
          TVProfilePicture(
            id: model.session?.user.id, name: model.session?.user.shownName ?? "Profile", size: 150,
            pictureKey: model.session?.user.pictureKey,
            pictureRevision: model.session?.user.pictureRevision ?? 0)
          Text(model.session?.user.shownName ?? "Profile").font(.system(size: 48, weight: .bold))
          Text(model.connection?.name ?? "Aurelia Server").font(.system(size: 24))
            .foregroundStyle(.secondary)
        }
        VStack(spacing: 22) {
          if model.supportsProfilePersonalization {
            NavigationLink {
              TVNameAndPictureView()
            } label: {
              Label("Name and Picture", systemImage: "person.crop.circle").frame(width: 560)
            }.accessibilityIdentifier("profile-name-picture")
          }
          NavigationLink {
            TVPlaybackSettingsView()
          } label: {
            Label("Playback Settings", systemImage: "play.rectangle").frame(width: 560)
          }.accessibilityIdentifier("profile-playback-settings")
          NavigationLink {
            TVAboutView()
          } label: {
            Label("About Aurelia", systemImage: "info.circle").frame(width: 560)
          }.accessibilityIdentifier("profile-about")
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
        if TVTestEdition.isActive {
          TVTestToolsSection()
        }
        Text(
          "Aurelia \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))"
        ).font(.system(size: 20)).foregroundStyle(.tertiary)
      }.padding(.vertical, 40).frame(maxWidth: .infinity)
    }
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
