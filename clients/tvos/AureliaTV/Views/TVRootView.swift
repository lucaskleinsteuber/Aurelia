import SwiftUI

private enum TVLibraryTab: Hashable { case movies, shows, profile }

enum TVDesign {
  static let canvas = Color(red: 32 / 255, green: 35 / 255, blue: 38 / 255)
  static let surface = Color(red: 40 / 255, green: 44 / 255, blue: 47 / 255)
}

struct TVRootView: View {
  @EnvironmentObject private var model: TVAppModel
  @State private var tab: TVLibraryTab = .movies

  var body: some View {
    Group {
      switch model.phase {
      case .connection: TVConnectionView(browser: model.browser)
      case .trust: TVServerTrustView()
      case .pairing: TVPairingView()
      case .profiles: TVProfilesView()
      case .library:
        TabView(selection: $tab) {
          NavigationStack { TVLibraryGrid(listing: model.movies, title: "Movies") }
            .tabItem { Label("Movies", systemImage: "film") }.tag(TVLibraryTab.movies)
          NavigationStack { TVLibraryGrid(listing: model.shows, title: "TV Shows") }
            .tabItem { Label("TV Shows", systemImage: "tv") }.tag(TVLibraryTab.shows)
          TVConnectionMenu()
            .tabItem {
              Label(model.session?.user.username ?? "Profile", systemImage: "person.crop.circle")
            }
            .tag(TVLibraryTab.profile)
        }
      }
    }
    .background(TVDesign.canvas.ignoresSafeArea())
    .buttonStyle(TVButtonStyle())
    .onChange(of: model.session?.sessionId) { _, _ in tab = .movies }
  }
}

struct TVConnectionView: View {
  @EnvironmentObject private var model: TVAppModel
  @ObservedObject var browser: TVBonjourBrowser
  @State private var address = ""

  var body: some View {
    ScrollView {
      VStack(spacing: 30) {
        Image(systemName: "play.rectangle.fill").font(.system(size: 64)).foregroundStyle(.secondary)
        Text("Aurelia").font(.system(size: 54, weight: .bold))
        Text("Connect to your server").font(.title2)
        if let error = model.error { TVErrorText(message: error) }
        if model.connection != nil {
          Button("Reconnect") { Task { await model.reconnect() } }.disabled(model.isBusy)
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
        Button("Trust and Continue") { model.beginPairing() }.buttonStyle(TVButtonStyle())
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

struct TVProfilesView: View {
  @EnvironmentObject private var model: TVAppModel
  @FocusState private var focusedProfile: UUID?

  var body: some View {
    Group {
      if let profile = model.selectedProfile {
        TVPINView(profile: profile).id(profile.id)
      } else {
        ScrollView {
          VStack(spacing: 48) {
            Text("Who’s watching?").font(.system(size: 48, weight: .bold))
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 40)], spacing: 40
            ) {
              ForEach(model.profiles) { profile in
                Button {
                  model.openProfile(profile)
                } label: {
                  VStack(spacing: 20) {
                    ZStack(alignment: .bottomTrailing) {
                      Image(systemName: "person.crop.circle.fill").font(.system(size: 110))
                        .foregroundStyle(
                          focusedProfile == profile.id ? .white : .white.opacity(0.65)
                        )
                        .padding(8)
                        .overlay(
                          Circle().stroke(.white, lineWidth: focusedProfile == profile.id ? 3 : 0))
                      if profile.pinProtectionEnabled || profile.needsPinSetup {
                        Image(systemName: "lock.fill").font(.system(size: 20))
                          .padding(9).background(TVDesign.canvas, in: Circle())
                      }
                    }
                    Text(profile.name).font(.system(size: 26, weight: .semibold))
                      .multilineTextAlignment(.center)
                      .lineLimit(2).frame(height: 68, alignment: .top)
                    Text(profile.needsPinSetup ? "Set up on Mac" : "")
                      .font(.caption).foregroundStyle(.secondary).frame(height: 30)
                      .accessibilityHidden(!profile.needsPinSetup)
                  }.frame(width: 220).padding(.vertical, 12)
                }.buttonStyle(TVContentButtonStyle()).focusEffectDisabled().disabled(
                  model.isBusy || profile.needsPinSetup
                )
                .focused($focusedProfile, equals: profile.id)
                .accessibilityIdentifier("profile-\(profile.id)")
                .accessibilityLabel(profile.name)
                .accessibilityValue(
                  profile.needsPinSetup
                    ? "PIN setup required"
                    : profile.pinProtectionEnabled ? "PIN protected" : "No PIN")
              }
            }.frame(maxWidth: 1200)
            if let error = model.error {
              TVErrorText(message: error)
              Button("Try Again") { Task { await model.refreshProfiles() } }.disabled(model.isBusy)
            }
            if model.isBusy { ProgressView() }
          }.padding(80).frame(maxWidth: .infinity, minHeight: 850)
        }
      }
    }
  }
}

struct TVPINView: View {
  @EnvironmentObject private var model: TVAppModel
  let profile: TVWatchingProfile
  @State private var pin = ""
  @FocusState private var pinFocused: Bool
  @FocusState private var avatarFocused: Bool

  var body: some View {
    VStack(spacing: 26) {
      Button {
        model.cancelProfileSelection()
      } label: {
        Image(systemName: "person.crop.circle.fill").font(.system(size: 110)).padding(8)
          .overlay(Circle().stroke(.white, lineWidth: avatarFocused ? 3 : 0))
      }.buttonStyle(TVContentButtonStyle()).focusEffectDisabled().focused($avatarFocused)
        .accessibilityLabel("Choose another profile")
      Text(profile.name).font(.title2.bold())
      SecureField("PIN", text: $pin)
        .keyboardType(.numberPad).textContentType(.password).submitLabel(.go)
        .focused($pinFocused).onSubmit(submit).disabled(model.isBusy)
        .frame(width: 440).accessibilityIdentifier("profile-pin")
      if let error = model.error { TVErrorText(message: error) }
      if model.isBusy { ProgressView() }
      Button("Continue", action: submit).disabled(model.isBusy || pin.isEmpty)
        .accessibilityIdentifier("profile-continue")
    }.padding(80).frame(maxWidth: .infinity, maxHeight: .infinity)
      .onAppear { pinFocused = true }
      .onChange(of: model.error) { _, error in
        if error != nil {
          pin = ""
          pinFocused = true
        }
      }
      .onExitCommand { model.cancelProfileSelection() }
  }

  private func submit() { model.openProfile(profile, pin: pin) }
}

struct TVConnectionMenu: View {
  @EnvironmentObject private var model: TVAppModel
  @State private var confirmingDisconnect = false

  var body: some View {
    VStack(spacing: 30) {
      Image(systemName: "person.crop.circle.fill").font(.system(size: 90)).foregroundStyle(
        .secondary)
      Text(model.session?.user.username ?? "Profile").font(.largeTitle.bold())
      Text(model.connection?.name ?? "Aurelia Server").foregroundStyle(.secondary)
      Button("Switch Profile") { Task { await model.switchProfile() } }
      Button("Disconnect Apple TV", role: .destructive) { confirmingDisconnect = true }
      Text(
        "Aurelia \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))"
      ).font(.caption).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
