import SwiftUI

private enum IOSLibraryTab: Hashable { case home, movies, shows, search, profile }

struct IOSRootView: View {
  @EnvironmentObject private var model: IOSAppModel
  @State private var tab: IOSLibraryTab = .home
  @State private var introductionReplay = false
  @StateObject private var securityAlerts = IOSSecurityAlertCenter()

  private var guide: IOSSetupGuide { model.setupGuide }
  private var tabIndex: Binding<Int> {
    let order: [IOSLibraryTab] = [.home, .movies, .shows, .search, .profile]
    return Binding(
      get: { order.firstIndex(of: tab) ?? 0 },
      set: { tab = order[min(max($0, 0), order.count - 1)] })
  }

  var body: some View {
    Group {
      if introductionReplay {
        IOSSetupIntroductionView(guide: guide, replay: true) { introductionReplay = false }
      } else if model.offlineMode != nil {
        IOSOfflineModeView(store: model.offline)
      } else if model.phase == .connection, model.connection == nil, !guide.introSeen {
        IOSSetupIntroductionView(guide: guide)
      } else if model.phase == .library, guide.isGuiding {
        IOSSetupDoneView(guide: guide).overlay(alignment: .top) { stepBar(.done) }
      } else {
        phaseView
      }
    }
    .background(IOSDesign.canvas.ignoresSafeArea())
    .onReceive(NotificationCenter.default.publisher(for: .iosShowIntroduction)) { _ in
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
  private func stepBar(_ step: IOSSetupStep) -> some View {
    if guide.isGuiding {
      IOSSetupStepBar(current: step).padding(.top, 4)
    }
  }

  @ViewBuilder
  private var phaseView: some View {
    Group {
      switch model.phase {
      case .connection:
        IOSConnectionView(browser: model.browser).overlay(alignment: .top) { stepBar(.connect) }
      case .trust: IOSServerTrustView().overlay(alignment: .top) { stepBar(.approve) }
      case .pairing: IOSPairingView().overlay(alignment: .top) { stepBar(.approve) }
      case .profiles: IOSProfilesView().overlay(alignment: .top) { stepBar(.profile) }
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
          IOSSettingsTab()
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .badge(model.supportsWishes ? model.wishBadgeCount : 0)
            .tag(IOSLibraryTab.profile)
        }
        .tint(.white)
        .sheet(isPresented: $model.wishesPresented) {
          NavigationStack {
            IOSWishesView()
              .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                  Button("Done") { model.wishesPresented = false }
                }
              }
          }
        }
        .overlay {
          if guide.tourPending, !guide.isGuiding {
            IOSLibraryTour(tab: tabIndex) { guide.tourShown() }.transition(.opacity)
          }
        }
        .overlay(alignment: .top) { IOSSecurityAlertBanner(center: securityAlerts) }
        .task(id: model.session?.sessionId) { securityAlerts.start(model: model) }
        .onDisappear { securityAlerts.stop() }
        #if DEBUG
          .onAppear {
            switch IOSShowcasePage.current {
            case "movies": tab = .movies
            case "shows": tab = .shows
            default: break
            }
            if IOSUITestScenario.current == .admin { tab = .profile }
          }
        #endif
      }
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
    NavigationStack {
      List {
        Section {
          VStack(spacing: 10) {
            Image(systemName: "play.rectangle.fill").font(.system(size: 48))
              .foregroundStyle(.white.opacity(0.85))
            Text("Aurelia").font(.largeTitle.bold())
            Text("Connect to the Aurelia server on your home network.")
              .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
          }
          .frame(maxWidth: .infinity).padding(.vertical, 12)
          .listRowBackground(Color.clear)
        }
        if let error = model.error {
          Section { IOSErrorText(message: error).frame(maxWidth: .infinity) }
            .listRowBackground(Color.clear)
        }
        if let saved = model.connection {
          Section {
            Button {
              choosingOtherServer = false
              Task { await model.reconnect(userInitiated: true) }
            } label: {
              Label("Reconnect to \(saved.name)", systemImage: "arrow.clockwise")
            }.disabled(model.isBusy)
          }
        }
        Section {
          ForEach(browser.servers) { server in
            Button {
              model.inspect(address: server.baseURL.absoluteString)
            } label: {
              HStack {
                Label(server.name, systemImage: "server.rack").foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                  .foregroundStyle(.tertiary)
              }
            }.disabled(model.isBusy)
          }
          if browser.servers.isEmpty {
            HStack(spacing: 10) {
              if browser.errorMessage == nil { ProgressView() }
              Text(browser.errorMessage ?? "Looking for servers…").foregroundStyle(.secondary)
            }
          }
        } header: {
          Text("On This Network")
        }
        Section {
          TextField("https://192.168.1.20:8443", text: $address)
            .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
            .autocorrectionDisabled().submitLabel(.go)
            .onSubmit { model.inspect(address: address) }
          Button("Connect") { model.inspect(address: address) }
            .disabled(model.isBusy || address.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
          Text("Server Address")
        } footer: {
          if model.isBusy {
            HStack(spacing: 8) {
              ProgressView()
              Text("Connecting…")
            }
          } else {
            Text("The address Aurelia on your Mac shows under Settings › Server.")
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(IOSDesign.canvas.ignoresSafeArea())
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
    VStack(spacing: 20) {
      Spacer()
      if model.savedServerUnreachable {
        Image(systemName: "power").font(.system(size: 44, weight: .medium))
          .foregroundStyle(.secondary)
        VStack(spacing: 10) {
          Text(model.savedServerAppHost.map { "Start Aurelia on Your \($0)" } ?? "The Server Is Off").font(.title.bold())
          Text(
            model.savedServerAppHost.map {
              "“\(name)” runs inside the Aurelia app on a \($0). Open Aurelia there, or wake the \($0), and Aurelia connects by itself."
            }
              ?? "“\(name)” isn’t answering. Turn on the computer the server runs on, or open Aurelia on your Mac to wake it."
          )
          .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
          Text("Aurelia connects by itself as soon as the server is on.")
            .font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 420)
        ZStack {
          if model.isWakingServer {
            ProgressView("Wake signal sent. Waiting for the server…")
          } else if model.isBusy {
            ProgressView("Waiting for the server…")
          } else {
            HStack(spacing: 12) {
              if model.wakeOnLanStatus.canWake {
                Button {
                  Task { await model.wakeServerNow() }
                } label: {
                  Label("Wake Server", systemImage: "power")
                }
                .buttonStyle(IOSButtonStyle(kind: .primary))
                .accessibilityIdentifier("server-wake")
              }
              Button("Try Again") { Task { await model.reconnect(userInitiated: true) } }
                .buttonStyle(
                  IOSButtonStyle(kind: model.wakeOnLanStatus.canWake ? .secondary : .primary))
                .accessibilityIdentifier("tv-server-retry")
            }
          }
        }.frame(minHeight: 56)
      } else {
        ProgressView().controlSize(.large)
        Text("Connecting to \(name)…").font(.title3.weight(.semibold))
          .multilineTextAlignment(.center)
      }
      Spacer()
      if model.canWatchOffline {
        Button {
          model.enterOfflineMode()
        } label: {
          Label("Watch Downloads", systemImage: "arrow.down.circle")
        }
        .buttonStyle(IOSButtonStyle(kind: .secondary))
        .accessibilityIdentifier("server-watch-downloads")
      }
      Button("Connect to Another Server", action: chooseOtherServer)
        .font(.subheadline.weight(.semibold)).tint(.white.opacity(0.75))
        .accessibilityIdentifier("tv-other-server")
    }
    .padding(IOSDesign.margin).padding(.bottom, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    VStack(spacing: 22) {
      Spacer()
      Image(systemName: "lock.shield").font(.system(size: 44)).foregroundStyle(.secondary)
      VStack(spacing: 6) {
        Text(model.inspected?.info.name ?? "Aurelia Server").font(.title.bold())
          .multilineTextAlignment(.center)
        Text(model.inspected?.baseURL.host ?? "").font(.subheadline).foregroundStyle(.secondary)
      }
      VStack(spacing: 10) {
        Text("Check that Aurelia on your Mac or Linux computer shows the same fingerprint.")
          .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        Text(IOSServerIdentity.display(model.inspected?.fingerprint ?? ""))
          .font(.system(.footnote, design: .monospaced, weight: .medium))
          .multilineTextAlignment(.center).textSelection(.enabled)
          .padding(14).frame(maxWidth: .infinity)
          .background(IOSDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
      if let error = model.error { IOSErrorText(message: error) }
      Spacer()
      VStack(spacing: 10) {
        Button("Trust and Continue") { model.beginPairing() }
          .buttonStyle(IOSButtonStyle(kind: .primary, fullWidth: true))
        Button("Back") { model.cancelPairing() }
          .buttonStyle(IOSButtonStyle(kind: .secondary, fullWidth: true))
      }.disabled(model.isBusy)
    }
    .padding(IOSDesign.margin).frame(maxWidth: 520).frame(maxWidth: .infinity)
    .iosBackCommand { model.cancelPairing() }
  }
}

struct IOSPairingView: View {
  @EnvironmentObject private var model: IOSAppModel
  @State private var code = ""
  @FocusState private var focused: Bool

  var body: some View {
    VStack(spacing: 22) {
      Spacer()
      Image(systemName: IOSDesign.isPad ? "ipad.badge.checkmark" : "iphone.badge.checkmark")
        .font(.system(size: 44)).foregroundStyle(.secondary)
      VStack(spacing: 6) {
        Text("Enter the Code").font(.title.bold())
          .multilineTextAlignment(.center)
        Text("Your Mac or Linux computer shows the code; you type it here.")
          .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }
      VStack(alignment: .leading, spacing: 6) {
        IOSPairingStep(number: 1, text: "On the computer that runs Aurelia, open Settings › Profiles and Devices.")
        IOSPairingStep(number: 2, text: "Click Create Code. On a Linux server without screen, run aurelia pair.")
        IOSPairingStep(number: 3, text: "Type the 8 digits below. A code works once and for five minutes.")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      TextField("8-digit code", text: $code)
        .keyboardType(.numberPad).textContentType(.oneTimeCode)
        .font(.system(size: 34, weight: .semibold, design: .monospaced))
        .multilineTextAlignment(.center)
        .padding(.vertical, 12).frame(maxWidth: .infinity)
        .background(IOSDesign.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .focused($focused)
        .onChange(of: code) { _, value in
          let digits = String(value.filter(\.isNumber).prefix(8))
          if digits != value { code = digits }
        }
        .onSubmit { model.pair(code: code) }
        .accessibilityLabel("Pairing code")
        .accessibilityIdentifier("pairing-code")
      if let error = model.error { IOSErrorText(message: error) }
      Spacer()
      VStack(spacing: 10) {
        Button {
          model.pair(code: code)
        } label: {
          if model.isBusy { ProgressView() } else { Text("Pair This \(IOSDesign.deviceName)") }
        }
        .buttonStyle(IOSButtonStyle(kind: .primary, fullWidth: true))
        .disabled(code.count != 8 || model.isBusy)
        Button("Cancel") { model.cancelPairing() }
          .buttonStyle(IOSButtonStyle(kind: .secondary, fullWidth: true))
      }
    }
    .padding(IOSDesign.margin).frame(maxWidth: 520).frame(maxWidth: .infinity)
    .onAppear { focused = true }
    .iosBackCommand { model.cancelPairing() }
  }
}

private struct IOSPairingStep: View {
  let number: Int
  let text: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
      Text(text).fixedSize(horizontal: false, vertical: true)
    }
    .font(.subheadline)
  }
}

struct IOSErrorText: View {
  let message: String
  var body: some View {
    Text(message).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
      .accessibilityAddTraits(.updatesFrequently)
  }
}
