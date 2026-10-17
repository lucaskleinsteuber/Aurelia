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

struct TVProfilesView: View {
  @EnvironmentObject private var model: TVAppModel

  var body: some View {
    Group {
      if let profile = model.selectedProfile {
        TVPINView(profile: profile).id(profile.id)
      } else {
        ScrollView {
          VStack(spacing: 70) {
            Text("Who’s watching?").font(.system(size: 56, weight: .bold))
            TVCenteredFlowLayout(spacing: 64, rowSpacing: 56) {
              ForEach(model.profiles) { profile in
                Button {
                  model.openProfile(profile)
                } label: {
                  TVProfileAvatar(profile: profile)
                }.buttonStyle(TVAvatarButtonStyle()).disabled(model.isBusy || profile.needsPinSetup)
                  .accessibilityIdentifier("profile-\(profile.id)")
                  .accessibilityLabel(profile.name)
                  .accessibilityValue(
                    profile.needsPinSetup
                      ? "PIN setup required"
                      : profile.pinProtectionEnabled ? "PIN protected" : "No PIN")
              }
            }.frame(maxWidth: 1500).focusSection()
            if let error = model.error {
              TVErrorText(message: error)
              Button("Try Again") { Task { await model.refreshProfiles() } }.buttonStyle(
                TVButtonStyle()
              ).disabled(model.isBusy)
            }
            if model.isBusy { ProgressView() }
          }.padding(80).frame(maxWidth: .infinity, minHeight: 960)
        }
      }
    }
  }
}

/// Mac-style avatar with the native tvOS lift on focus and a lock for PIN profiles.
private struct TVProfileAvatar: View {
  let profile: TVWatchingProfile
  var body: some View {
    VStack(spacing: 22) {
      ZStack(alignment: .bottomTrailing) {
        Image(systemName: "person.crop.circle.fill").font(.system(size: 150))
          .symbolRenderingMode(.hierarchical).foregroundStyle(.white.opacity(0.9))
          .frame(width: 190, height: 190)
          .background(TVDesign.surface, in: Circle())

        if profile.pinProtectionEnabled || profile.needsPinSetup {
          Image(systemName: "lock.fill").font(.system(size: 22, weight: .semibold))
            .padding(12).background(TVDesign.canvas, in: Circle())
        }
      }
      Text(profile.name).font(.system(size: 28, weight: .semibold)).multilineTextAlignment(.center)
        .lineLimit(2).frame(width: 230)
      if profile.needsPinSetup {
        Text("Set up on Mac").font(.system(size: 20)).foregroundStyle(.secondary)
      }
    }.frame(width: 230)
  }
}

/// Round avatars grow with a soft shadow on focus instead of a rectangular platter.
private struct TVAvatarButtonStyle: ButtonStyle {
  @Environment(\.isFocused) private var focused
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(enabled ? (focused ? 1 : 0.72) : 0.4)
      .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 24, y: 14)
      .scaleEffect(configuration.isPressed ? 1.04 : focused ? 1.12 : 1)
      .animation(.easeOut(duration: 0.16), value: focused)
  }
}

/// Centers every row, including a single profile or an incomplete last row.
private struct TVCenteredFlowLayout: Layout {
  var spacing: CGFloat
  var rowSpacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
    let height =
      rows.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(0, rows.count - 1))
    return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for row in rows(width: bounds.width, subviews: subviews) {
      var x = bounds.midX - row.width / 2
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + rowSpacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      if !current.indices.isEmpty, needed > width {
        rows.append(current)
        current = Row()
      }
      current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      current.height = max(current.height, size.height)
      current.indices.append(index)
    }
    if !current.indices.isEmpty { rows.append(current) }
    return rows
  }
}

/// Digits-only PIN entry with an on-screen keypad; the system keyboard never opens.
struct TVPINView: View {
  @EnvironmentObject private var model: TVAppModel
  let profile: TVWatchingProfile
  @State private var pin = ""
  @State private var attempts = 0
  @FocusState private var focusedKey: String?
  private static let rows = [
    ["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["delete", "0", "ok"],
  ]
  private static let maximumLength = 8

  var body: some View {
    VStack(spacing: 30) {
      Button {
        model.cancelProfileSelection()
      } label: {
        Image(systemName: "person.crop.circle.fill").font(.system(size: 104))
          .symbolRenderingMode(.hierarchical).foregroundStyle(.white.opacity(0.9))
          .frame(width: 132, height: 132).background(TVDesign.surface, in: Circle())

      }.buttonStyle(TVAvatarButtonStyle()).accessibilityLabel("Choose another profile")
      VStack(spacing: 10) {
        Text(profile.name).font(.system(size: 36, weight: .bold))
        Text("Enter your PIN").font(.system(size: 24)).foregroundStyle(.secondary)
      }
      HStack(spacing: 22) {
        ForEach(0..<max(4, pin.count), id: \.self) { index in
          Circle().fill(index < pin.count ? Color.white : Color.clear)
            .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 2)).frame(
              width: 24, height: 24)
        }
      }.frame(height: 30).modifier(TVShakeEffect(travel: CGFloat(attempts)))
        .accessibilityElement().accessibilityIdentifier("profile-pin")
        .accessibilityLabel("PIN").accessibilityValue("\(pin.count) digits entered")
      if let error = model.error { TVErrorText(message: error) }
      Grid(horizontalSpacing: 22, verticalSpacing: 22) {
        ForEach(Self.rows, id: \.self) { row in
          GridRow {
            ForEach(row, id: \.self) { key in keyButton(key) }
          }
        }
      }.focusSection()
      ProgressView().opacity(model.isBusy ? 1 : 0)
    }.padding(60).frame(maxWidth: .infinity, maxHeight: .infinity)
      .defaultFocus($focusedKey, "1")
      .onChange(of: model.error) { _, error in
        guard error != nil else { return }
        pin = ""
        withAnimation(.linear(duration: 0.4)) { attempts += 1 }
      }
      .onExitCommand { model.cancelProfileSelection() }
  }

  private func keyButton(_ key: String) -> some View {
    Button {
      press(key)
    } label: {
      Group {
        switch key {
        case "delete": Image(systemName: "delete.left")
        case "ok": Text("OK")
        default: Text(key)
        }
      }.font(.system(size: 34, weight: .semibold, design: .rounded)).frame(width: 128, height: 88)
    }
    .buttonStyle(TVButtonStyle(kind: .row))
    .disabled(
      model.isBusy || (key == "ok" && !TVProfilePIN.isValid(pin))
        || (key == "delete" && pin.isEmpty)
    )
    .focused($focusedKey, equals: key)
    .accessibilityIdentifier(key == "ok" ? "profile-continue" : "pin-key-\(key)")
    .accessibilityLabel(key == "delete" ? "Delete" : key == "ok" ? "Continue" : key)
  }

  private func press(_ key: String) {
    switch key {
    case "delete": if !pin.isEmpty { pin.removeLast() }
    case "ok": if TVProfilePIN.isValid(pin) { model.openProfile(profile, pin: pin) }
    default:
      if pin.count < Self.maximumLength { pin.append(key) }
    }
  }
}

/// Horizontal shake after a rejected PIN.
private struct TVShakeEffect: GeometryEffect {
  var travel: CGFloat
  var animatableData: CGFloat {
    get { travel }
    set { travel = newValue }
  }
  func effectValue(size: CGSize) -> ProjectionTransform {
    ProjectionTransform(CGAffineTransform(translationX: 12 * sin(travel * .pi * 6), y: 0))
  }
}

struct TVConnectionMenu: View {
  @EnvironmentObject private var model: TVAppModel
  @State private var confirmingDisconnect = false

  var body: some View {
    VStack(spacing: 44) {
      VStack(spacing: 18) {
        Image(systemName: "person.crop.circle.fill").font(.system(size: 130))
          .symbolRenderingMode(.hierarchical).foregroundStyle(.white.opacity(0.9))
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
