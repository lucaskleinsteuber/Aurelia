import SwiftUI

/// The setup assistant's start: "New to Aurelia?", how Aurelia works in one picture, then three
/// quick questions that set up the rest: where the media lives, who watches, and which other
/// devices follow. "I Know Aurelia" leads to the plain welcome choice instead.
struct SetupIntroductionView: View {
  enum Page: Int, CaseIterable {
    case welcome, howItWorks, mediaLocation, audience, devices
  }

  @EnvironmentObject private var model: AppModel
  @ObservedObject var guide: SetupGuide
  /// Settings › About › Show Introduction: only the explanation, then `closed`.
  var replay = false
  var closed: (() -> Void)? = nil
  /// The first page shown; renders of the assistant start further in.
  var startPage: Page = .welcome
  @State private var page: Page = .welcome
  @State private var devices: SetupDevices = []
  @State private var showsHelp = false
  @Environment(\.aureliaReduceMotion) private var reduceMotion

  var body: some View {
    ScrollView {
      VStack(spacing: 28) {
        Group {
          switch page {
          case .welcome: welcome
          case .howItWorks: howItWorks
          case .mediaLocation: mediaLocation
          case .audience: audience
          case .devices: devicePicker
          }
        }
        .id(page)
        .transition(
          reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 12)))
        if page != .welcome && !replay { dots }
      }
      .frame(maxWidth: 620)
      .padding(.horizontal, 40)
      .padding(.vertical, 60)
      .frame(maxWidth: .infinity, minHeight: 560)
    }
    .scrollIndicators(.hidden)
    .background(AureliaBackdrop())
    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: page)
    .accessibilityIdentifier("setup-introduction")
    .onAppear {
      devices = guide.devices
      page = replay ? .howItWorks : startPage
    }
  }

  private var welcome: some View {
    VStack(spacing: 26) {
      Image(systemName: "play.rectangle.on.rectangle.fill")
        .font(.system(size: 58, weight: .medium))
        .symbolRenderingMode(.hierarchical)
      heading(
        "Welcome to Aurelia",
        "Your movies and shows, on every screen at home. New here? A few steps set everything up with you."
      )
      VStack(spacing: 12) {
        primary("Show Me Around") { page = .howItWorks }
          .accessibilityIdentifier("setup-show-me-around")
        Button("I Know Aurelia") { guide.skipIntroduction() }
          .buttonStyle(.link)
          .accessibilityIdentifier("setup-i-know-aurelia")
      }
    }
  }

  private var howItWorks: some View {
    VStack(spacing: 26) {
      heading(
        "How Aurelia Works", "One computer serves your library. Everything else just watches.")
      HStack(alignment: .top, spacing: 6) {
        station(
          "externaldrive.fill", "Your Files",
          "Movies and shows stay where they are. Aurelia never changes them.")
        arrow
        station(
          "server.rack", "Aurelia Server",
          "Runs on one computer, sorts everything and finds posters.")
        arrow
        station(
          "tv.and.mediabox", "Every Screen",
          "Apple TV, iPhone, iPad, computers and the browser play from it.")
      }
      primary(replay ? "Done" : "Continue") {
        if replay { closed?() } else { page = .mediaLocation }
      }
      .accessibilityIdentifier("setup-continue")
      if !replay { back(.welcome) }
    }
  }

  private var mediaLocation: some View {
    VStack(spacing: 22) {
      heading("Where Are Your Movies and Shows?", "Aurelia runs where your files are.")
      VStack(spacing: 14) {
        choice(
          "On This Mac",
          "This Mac becomes your server. Recommended when the files are on its drives.",
          symbol: "macstudio.fill", primary: true
        ) { page = .audience }
        .accessibilityIdentifier("setup-media-here")
        choice(
          "On Another Computer", "An Aurelia Server already runs there. This Mac connects to it.",
          symbol: "network", primary: false
        ) {
          guide.start()
          model.selectClientMode()
        }
        .accessibilityIdentifier("setup-media-elsewhere")
      }
      VStack(spacing: 8) {
        Button("Not Sure?") { showsHelp.toggle() }.buttonStyle(.link)
        if showsHelp {
          Text(
            "Choose the computer whose drives hold the movies and shows. It should be on when you watch. You can change this later in Settings."
          )
          .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
      }
      back(.howItWorks)
    }
  }

  private var audience: some View {
    VStack(spacing: 22) {
      heading("Who Watches?", "Each person keeps their own progress, favorites and watchlist.")
      VStack(spacing: 14) {
        choice(
          "Just Me", "One profile, protected with your PIN.", symbol: "person.fill",
          primary: guide.audience == .justMe
        ) {
          guide.audience = .justMe
          page = .devices
        }
        .accessibilityIdentifier("setup-just-me")
        choice(
          "Several People",
          "Everyone gets a profile. Children's profiles show only what suits their age.",
          symbol: "person.2.fill", primary: guide.audience == .severalPeople
        ) {
          guide.audience = .severalPeople
          page = .devices
        }
        .accessibilityIdentifier("setup-several-people")
      }
      back(.mediaLocation)
    }
  }

  private var devicePicker: some View {
    VStack(spacing: 26) {
      heading(
        "Which Other Devices Will You Use?",
        "Pick any. At the end, Aurelia shows how to connect each one.")
      HStack(spacing: 10) {
        ForEach(SetupDevices.ordered, id: \.label) { entry in
          let selected = devices.contains(entry.device)
          Button {
            if selected { devices.remove(entry.device) } else { devices.insert(entry.device) }
          } label: {
            Text(entry.label)
              .font(.callout.weight(.medium))
              .padding(.horizontal, 16).padding(.vertical, 9)
              .foregroundStyle(selected ? Color.black : .primary)
              .background(
                selected ? Color.white.opacity(0.94) : AureliaDesign.raisedSurface, in: Capsule()
              )
              .contentShape(Capsule())
          }
          .buttonStyle(AureliaPressableButtonStyle())
          .accessibilityAddTraits(selected ? .isSelected : [])
          .accessibilityIdentifier("setup-device-\(entry.device.rawValue)")
        }
      }
      primary("Set Up This Mac") {
        guide.devices = devices
        guide.start()
        Task { await model.selectHostMode() }
      }
      .accessibilityIdentifier("setup-host")
      back(.audience)
    }
  }

  private var dots: some View {
    HStack(spacing: 8) {
      ForEach([Page.howItWorks, .mediaLocation, .audience, .devices], id: \.self) { each in
        Capsule()
          .fill(each == page ? Color.accentColor : Color.white.opacity(0.28))
          .frame(width: each == page ? 22 : 8, height: 8)
      }
    }
    .accessibilityHidden(true)
  }

  private func heading(_ title: String, _ detail: String) -> some View {
    VStack(spacing: 8) {
      Text(title).font(.system(size: 32, weight: .bold)).multilineTextAlignment(.center)
      Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
  }

  private func primary(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).frame(minWidth: 170)
    }
    .buttonStyle(AureliaPrimaryActionButtonStyle())
    .keyboardShortcut(.defaultAction)
  }

  private func back(_ target: Page) -> some View {
    Button("Back") { page = target }.buttonStyle(.link)
  }

  private var arrow: some View {
    Image(systemName: "chevron.right")
      .font(.callout.weight(.semibold))
      .foregroundStyle(.tertiary)
      .padding(.top, 26)
      .accessibilityHidden(true)
  }

  private func station(_ symbol: String, _ title: String, _ detail: String) -> some View {
    VStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 28, weight: .medium))
        .symbolRenderingMode(.hierarchical)
        .frame(width: 64, height: 64)
        .background(AureliaDesign.raisedSurface, in: RoundedRectangle(cornerRadius: 18))
      Text(title).font(.headline)
      Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }

  private func choice(
    _ title: String, _ detail: String, symbol: String, primary: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 16) {
        Image(systemName: symbol)
          .font(.system(size: 23, weight: .semibold))
          .symbolRenderingMode(.hierarchical)
          .frame(width: 44, height: 44)
          .background(
            primary ? Color.white.opacity(0.94) : AureliaDesign.raisedSurface,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
          )
          .foregroundStyle(primary ? Color.black : Color.primary)
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.headline)
          Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
        }
        Spacer(minLength: 12)
        Image(systemName: "chevron.right").font(.callout.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(18)
      .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
      .background(
        primary ? AureliaDesign.raisedSurface : AureliaDesign.surface,
        in: RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous)
          .stroke(primary ? Color.white.opacity(0.18) : AureliaDesign.hairline, lineWidth: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(AureliaPressableButtonStyle())
  }
}

/// The guided setup's progress above each setup screen: finished steps get a check, the current
/// one is highlighted. "Skip Assistant" keeps the setup screens but drops the guidance and tour.
struct SetupStepBar: View {
  let steps: [SetupStep]
  let current: SetupStep
  let skip: () -> Void

  var body: some View {
    let index = steps.firstIndex(of: current) ?? 0
    HStack(spacing: 10) {
      ForEach(Array(steps.enumerated()), id: \.element) { position, step in
        if position > 0 {
          Rectangle().fill(.white.opacity(0.25)).frame(width: 18, height: 1)
        }
        HStack(spacing: 6) {
          ZStack {
            Circle().fill(
              position <= index ? Color.accentColor : Color.white.opacity(0.2))
            if position < index {
              Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            } else {
              Text("\(position + 1)").font(.system(size: 11, weight: .semibold))
            }
          }
          .foregroundStyle(.white)
          .frame(width: 20, height: 20)
          Text(step.title)
            .font(.system(size: 12, weight: position == index ? .semibold : .regular))
            .opacity(position == index ? 1 : 0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          "\(step.title), step \(position + 1) of \(steps.count)\(position < index ? ", done" : "")"
        )
      }
      Button("Skip Assistant", action: skip)
        .buttonStyle(.link)
        .font(.system(size: 12))
        .padding(.leading, 8)
        .accessibilityIdentifier("setup-skip-assistant")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1) }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("setup-step-bar")
  }
}

/// The end of the guided setup: profiles for everyone else at home (when several people watch),
/// then "You're All Set" with what was done and how to connect each chosen device.
struct SetupFinishView: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject var guide: SetupGuide
  @State private var showsPeople: Bool
  @State private var added: [UserSummary] = []
  @State private var name = ""
  @State private var pictureKey: String?
  @State private var photo: Data?
  @State private var pin = ""
  @State private var isChild = false
  @State private var age = 6
  @State private var canManage = false
  @State private var working = false
  @State private var problem: String?

  init(guide: SetupGuide, offersPeople: Bool) {
    self.guide = guide
    _showsPeople = State(initialValue: offersPeople)
  }

  static func offersPeople(model: AppModel, guide: SetupGuide) -> Bool {
    model.isLocalHost && guide.audience == .severalPeople && model.profile?.user?.role == .owner
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        if showsPeople { people } else { allSet }
      }
      .frame(maxWidth: 640)
      .padding(.horizontal, 40)
      .padding(.top, 70)
      .padding(.bottom, 40)
      .frame(maxWidth: .infinity)
    }
    .scrollIndicators(.hidden)
    .background(AureliaBackdrop())
    .overlay(alignment: .top) {
      if guide.isGuiding {
        SetupStepBar(
          steps: guide.steps(hosting: model.isLocalHost), current: showsPeople ? .people : .done
        ) { guide.skip() }
        .padding(.top, 14)
      }
    }
    .accessibilityIdentifier("setup-finish")
  }

  private var serverName: String { model.profile?.name ?? "your server" }

  // MARK: People

  private var people: some View {
    VStack(spacing: 22) {
      Image(systemName: "person.2.fill").font(.system(size: 44)).symbolRenderingMode(.hierarchical)
      VStack(spacing: 8) {
        Text("Who Else Watches?").font(.system(size: 32, weight: .bold))
        Text("Add a profile for everyone at home. They pick it in “Who's watching?” on any device.")
          .foregroundStyle(.secondary).multilineTextAlignment(.center)
      }
      if !added.isEmpty {
        VStack(spacing: 8) {
          ForEach(added, id: \.id) { person in
            HStack(spacing: 12) {
              AureliaProfileAvatar(user: person, size: 34)
              VStack(alignment: .leading, spacing: 2) {
                Text(person.shownName).font(.headline)
                Text(personSummary(person)).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .padding(12)
            .background(AureliaDesign.surface, in: RoundedRectangle(cornerRadius: 12))
          }
        }
      }
      VStack(alignment: .leading, spacing: 14) {
        TextField("Name", text: $name).textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("setup-person-name")
        ProfilePicturePicker(id: nil, name: name, key: $pictureKey, photo: $photo)
        SecureField("PIN (optional, 4–8 digits)", text: $pin).textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("setup-person-pin")
        switchRow(
          "Children's Profile",
          model.supportsAgeLimits
            ? "Only what is approved for their age."
            : "Update the server to use children's profiles.", isOn: $isChild
        )
        .disabled(!model.supportsAgeLimits)
        .accessibilityIdentifier("setup-person-child")
        if isChild {
          Picker("Age", selection: $age) {
            ForEach(ProfileAgeSteps.all, id: \.value) { step in
              Text(step.label).tag(step.value)
            }
          }
          .accessibilityIdentifier("setup-person-age")
          Text("Titles above this age and titles without a rating are hidden.")
            .font(.caption).foregroundStyle(.secondary)
        }
        switchRow(
          "Can Manage the Server",
          "Adds storage, edits details and approves devices. Needs a PIN.", isOn: $canManage
        )
        .accessibilityIdentifier("setup-person-admin")
        if let problem {
          Text(problem).font(.callout).foregroundStyle(.orange)
            .accessibilityIdentifier("setup-person-problem")
        }
        Button(working ? "Adding…" : "Add Person") { add() }
          .disabled(working)
          .accessibilityIdentifier("setup-add-person")
      }
      .toggleStyle(.switch)
      .padding(20)
      .background(
        AureliaDesign.surface, in: RoundedRectangle(cornerRadius: AureliaDesign.cardRadius)
      )
      .onChange(of: isChild) { _, child in if child { canManage = false } }
      .onChange(of: canManage) { _, manage in if manage { isChild = false } }
      VStack(spacing: 10) {
        Button {
          showsPeople = false
        } label: {
          Text("Continue").frame(minWidth: 170)
        }
        .buttonStyle(AureliaPrimaryActionButtonStyle())
        .accessibilityIdentifier("setup-people-continue")
        if added.isEmpty {
          Button("Skip for Now") { showsPeople = false }.buttonStyle(.link)
        }
      }
    }
  }

  /// A label with a detail line on the left and its switch at the right edge.
  private func switchRow(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)
      Toggle(title, isOn: isOn).labelsHidden()
    }
  }

  private func personSummary(_ person: UserSummary) -> String {
    if let summary = ProfileAgeSteps.summary(for: person.ageLimit) { return summary }
    return person.role.canManageLibraries ? "Can manage the server" : "Watches the whole library"
  }

  private func add() {
    let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let code = pin.isEmpty ? nil : pin
    if wanted.isEmpty {
      problem = "Enter the person's name."
      return
    }
    if let code, !ProfilePIN.isValid(code) {
      problem = "Use a PIN with four to eight digits, or leave it empty."
      return
    }
    if canManage && code == nil {
      problem = "Someone who manages the server needs a PIN."
      return
    }
    guard let profile = model.profile else { return }
    let client = APIClient(profile: profile)
    let child = model.supportsAgeLimits && isChild
    let builtin = pictureKey == ProfilePictureCatalog.photoKey ? nil : pictureKey
    let upload = pictureKey == ProfilePictureCatalog.photoKey ? photo : nil
    let request = ProfileCreateRequest(
      username: wanted, role: canManage ? .admin : .user, isEnabled: true,
      pinProtectionEnabled: code != nil, pin: code, accessMode: .entireLibrary, titleIds: [],
      displayName: nil, pictureKey: builtin, ageLimit: child ? age : nil)
    working = true
    problem = nil
    Task {
      defer { working = false }
      do {
        var created = try await createWithUnlock {
          try await client.createProfile(request: request)
        }
        if let upload {
          created = try await createWithUnlock {
            try await client.uploadProfilePhoto(id: created.id, image: upload)
          }
        }
        added.append(created)
        name = ""
        pin = ""
        pictureKey = nil
        photo = nil
        isChild = false
        canManage = false
      } catch is CancellationError {
      } catch {
        problem = error.localizedDescription
      }
    }
  }

  /// Runs an owner change, asking for the Server Password once when management is locked.
  private func createWithUnlock<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T)
    async throws -> T
  {
    do {
      return try await operation()
    } catch let failure as APIClientError where failure.isManagementLocked {
      let password = try AdministrationPasswordPrompt.confirm(serverName: serverName)
      guard await model.unlockManagement(password: password) else { throw failure }
      return try await operation()
    }
  }

  // MARK: All set

  private var allSet: some View {
    VStack(spacing: 22) {
      Image(systemName: "checkmark").font(.system(size: 44, weight: .semibold))
        .foregroundStyle(Color.accentColor)
      VStack(spacing: 8) {
        Text("You're All Set").font(.system(size: 32, weight: .bold))
        Text("Here is what Aurelia set up with you.").foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 10) {
        check(
          model.isLocalHost
            ? "This Mac runs your server, \(serverName)."
            : "This Mac is connected to \(serverName).")
        if let user = model.profile?.user {
          check("Your profile, \(user.shownName), is protected with your PIN.")
        }
        let titles = model.catalogItems.filter { $0.kind == .movie || $0.kind == .series }.count
        if titles > 0 {
          check(
            titles == 1 ? "One title is in your library." : "\(titles) titles are in your library.")
        } else if model.isLocalHost {
          check(
            "Your media is still being added, or you skipped it. Add drives and folders anytime in Settings › Library.",
            done: false)
        }
        if !added.isEmpty {
          check(
            added.count == 1
              ? "One more person can watch." : "\(added.count) more people can watch.")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(18)
      .background(
        AureliaDesign.surface, in: RoundedRectangle(cornerRadius: AureliaDesign.cardRadius))
      if !guide.devices.isEmpty {
        Text("CONNECT YOUR OTHER DEVICES")
          .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        VStack(spacing: 12) {
          if guide.devices.contains(.appleTV) {
            deviceCard(
              "appletv.fill", "Apple TV", "Open Aurelia on the Apple TV.", "Choose \(serverName).",
              "It shows a code: enter it here in Settings › Profiles and Devices.")
          }
          if guide.devices.contains(.phoneOrTablet) {
            deviceCard(
              "iphone", "iPhone or iPad", "Open Aurelia on the iPhone or iPad.",
              "Choose \(serverName).",
              "It shows a code: enter it here in Settings › Profiles and Devices.")
          }
          if guide.devices.contains(.computer) {
            deviceCard(
              "desktopcomputer", "Another Computer",
              "Install Aurelia on it and choose Connect to an Existing Server.",
              "Pick \(serverName).",
              "Create its pairing code here in Settings › Profiles and Devices › Pair a Mac.")
          }
          if guide.devices.contains(.webBrowser) {
            deviceCard(
              "safari.fill", "Web Browser",
              "Open \(browserAddress) in a browser at home.",
              "Accept the security notice once: it is your own server.",
              "Enter the code it shows here in Settings › Profiles and Devices.")
          }
        }
      }
      VStack(spacing: 10) {
        Button {
          guide.finish()
        } label: {
          Text("Start Watching").frame(minWidth: 170)
        }
        .buttonStyle(AureliaPrimaryActionButtonStyle())
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("setup-start-watching")
        if !guide.devices.isEmpty {
          Button("Open Profiles and Devices") {
            guide.finish()
            model.openSettings(.profilesAndDevices)
          }
          .accessibilityIdentifier("setup-open-devices")
        }
      }
    }
  }

  private var browserAddress: String {
    guard let serverURL = model.profile?.baseURL else { return "your server's address" }
    let local = model.isLocalHost ? model.hostSnapshot.serverInfo : nil
    return BrowserAddress.resolve(
      serverURL: serverURL, lanAccessEnabled: local?.lanAccessEnabled,
      lanPort: local?.lanHttpsPort)?.url.absoluteString ?? "your server's address"
  }

  private func check(_ text: String, done: Bool = true) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
        .foregroundStyle(done ? Color.accentColor : .secondary)
      Text(text).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func deviceCard(_ symbol: String, _ title: String, _ steps: String...) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: symbol).font(.headline)
      ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
        HStack(alignment: .top, spacing: 10) {
          Text("\(index + 1)")
            .font(.caption.weight(.semibold))
            .frame(width: 20, height: 20)
            .background(.white.opacity(0.14), in: Circle())
          Text(step).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(AureliaDesign.surface, in: RoundedRectangle(cornerRadius: AureliaDesign.cardRadius))
    .accessibilityElement(children: .combine)
  }
}
