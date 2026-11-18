import SwiftUI

/// "Who's watching?" in the Mac app's style: a drifting color wash, round colored avatars with
/// the profile's initial, and a PIN keypad that never hints at how long the PIN is.
struct IOSProfilesView: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    // The glow fills the whole screen as a background. As a sibling in the ZStack it pulled the
    // stack beneath the status bar, and the PIN screen's "Profiles" button sat over the clock.
    ZStack {
      if let profile = model.selectedProfile {
        IOSPINView(profile: profile).id(profile.id)
          .transition(.opacity)
      } else {
        picker.transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background { IOSAmbientBackground() }
    .animation(
      reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.32),
      value: model.selectedProfile?.id)
  }

  private var picker: some View {
    IOSCenteredScrollView {
      VStack(spacing: 32) {
        Text("Who’s watching?").font(.system(.largeTitle, weight: .bold))
          .multilineTextAlignment(.center)
        IOSProfileRows(minimumColumnWidth: dynamicTypeSize.isAccessibilitySize ? 260 : 140) {
          ForEach(model.profiles) { profile in
            Button {
              model.openProfile(profile)
            } label: {
              IOSProfileEntry(profile: profile)
            }
            .buttonStyle(IOSContentButtonStyle())
            // Screen time closes a children's profile until its wake time.
            .disabled(model.isBusy || profile.needsPinSetup || profile.closedUntil != nil)
            .opacity(profile.needsPinSetup || profile.closedUntil != nil ? 0.5 : 1)
            .accessibilityIdentifier("profile-\(profile.id)")
            .accessibilityLabel(profile.name)
            .accessibilityValue(
              IOSScreenTimeText.closedLabel(profile.closedUntil)
                ?? (profile.needsPinSetup
                  ? "PIN setup required"
                  : profile.pinProtectionEnabled ? "PIN protected" : "No PIN"))
          }
        }
        .frame(maxWidth: 560)
        VStack(spacing: 14) {
          if let error = model.error {
            IOSErrorText(message: error)
            Button("Try Again") { Task { await model.refreshProfiles() } }
              .buttonStyle(IOSButtonStyle()).disabled(model.isBusy)
          }
          ProgressView().opacity(model.isBusy ? 1 : 0).accessibilityHidden(!model.isBusy)
        }
      }
      .padding(.horizontal, IOSDesign.margin(for: sizeClass)).padding(.vertical, 40)
    }
  }
}

/// Center each row, including a single profile and the last partially filled row; also the
/// offline mode's "Watch Downloads" chooser, so both pickers look alike.
struct IOSProfileRows: Layout {
  var minimumColumnWidth: CGFloat = 140

  private func dimensions(_ proposal: ProposedViewSize, count: Int) -> (
    width: CGFloat, columns: Int
  ) {
    let width = min(560, max(0, proposal.width ?? 560))
    let columns = max(1, min(count, Int((width + 20) / max(100, minimumColumnWidth))))
    let maxCellWidth: CGFloat = columns == 1 ? width : max(160, minimumColumnWidth)
    return (
      min(maxCellWidth, max(0, (width - CGFloat(columns - 1) * 20) / CGFloat(columns))), columns
    )
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let (width, columns) = dimensions(proposal, count: subviews.count)
    let heights = subviews.map { $0.sizeThatFits(.init(width: width, height: nil)).height }
    let rows = stride(from: 0, to: subviews.count, by: columns).map { start in
      heights[start..<min(start + columns, heights.count)].max() ?? 0
    }
    return CGSize(
      width: min(560, proposal.width ?? CGFloat(columns) * (width + 20) - 20),
      height: rows.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * 28)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let (width, columns) = dimensions(
      .init(width: bounds.width, height: nil), count: subviews.count)
    var y = bounds.minY
    for start in stride(from: 0, to: subviews.count, by: columns) {
      let end = min(start + columns, subviews.count)
      let rowWidth = CGFloat(end - start) * width + CGFloat(end - start - 1) * 20
      let heights = (start..<end).map {
        subviews[$0].sizeThatFits(.init(width: width, height: nil)).height
      }
      for index in start..<end {
        subviews[index].place(
          at: CGPoint(x: bounds.midX - rowWidth / 2 + CGFloat(index - start) * (width + 20), y: y),
          anchor: .topLeading, proposal: .init(width: width, height: heights[index - start]))
      }
      y += (heights.max() ?? 0) + 28
    }
  }
}

/// Avatar with the name below and a small lock beside it, as on the Mac.
private struct IOSProfileEntry: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let profile: IOSWatchingProfile

  var body: some View {
    VStack(spacing: 10) {
      IOSProfilePicture(
        id: profile.id, name: profile.name, size: 96, pictureKey: profile.pictureKey,
        pictureRevision: profile.pictureRevision
      )
      .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
      HStack(spacing: 4) {
        Text(profile.name).font(.subheadline.weight(.semibold))
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
          .multilineTextAlignment(.center)
        if profile.pinProtectionEnabled || profile.needsPinSetup {
          Image(systemName: "lock.fill").font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
      }
      if let asleep = IOSScreenTimeText.closedLabel(profile.closedUntil) {
        Label(asleep, systemImage: "moon.fill").font(.caption).foregroundStyle(.secondary)
      }
      if profile.needsPinSetup {
        Text("Set up a PIN on the server computer").font(.caption2).foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
  }
}

/// A round profile picture: the profile's photo, a built-in picture (a symbol on a gradient), or
/// the initial on a gradient in the same color the Mac app gives that profile.
struct IOSProfilePicture: View {
  let id: UUID?
  let name: String
  var size: CGFloat = 200
  var pictureKey: String? = nil
  var pictureRevision: Int64 = 0
  @ObservedObject private var photos = IOSProfilePhotoCache.shared

  init(
    id: UUID?, name: String, size: CGFloat = 200, pictureKey: String? = nil,
    pictureRevision: Int64 = 0
  ) {
    self.id = id
    self.name = name
    self.size = size
    self.pictureKey = pictureKey
    self.pictureRevision = pictureRevision
  }

  static let palettes: [(Color, Color)] = [
    (Color(red: 0.36, green: 0.62, blue: 1.0), Color(red: 0.13, green: 0.36, blue: 0.86)),
    (Color(red: 0.74, green: 0.49, blue: 1.0), Color(red: 0.44, green: 0.22, blue: 0.82)),
    (Color(red: 1.0, green: 0.55, blue: 0.6), Color(red: 0.84, green: 0.24, blue: 0.4)),
    (Color(red: 1.0, green: 0.72, blue: 0.36), Color(red: 0.9, green: 0.42, blue: 0.14)),
    (Color(red: 0.36, green: 0.84, blue: 0.8), Color(red: 0.1, green: 0.52, blue: 0.56)),
    (Color(red: 0.5, green: 0.86, blue: 0.48), Color(red: 0.18, green: 0.56, blue: 0.3)),
    (Color(red: 0.55, green: 0.6, blue: 1.0), Color(red: 0.28, green: 0.3, blue: 0.8)),
  ]

  /// Built-in pictures' colors: the seven gradients above plus red.
  static func namedPalette(_ name: String) -> (Color, Color) {
    let index = IOSProfilePictures.paletteIndex(named: name)
    if index < palettes.count { return palettes[index] }
    return (Color(red: 1.0, green: 0.48, blue: 0.42), Color(red: 0.79, green: 0.19, blue: 0.17))
  }

  var body: some View {
    let builtin = IOSProfilePictures.parse(pictureKey)
    let colors =
      builtin.map { Self.namedPalette($0.palette) }
      ?? Self.palettes[IOSProfileColor.index(for: id) % Self.palettes.count]
    let photo =
      pictureKey == IOSProfilePictures.photoKey
      ? id.flatMap { photos.image(id: $0, revision: pictureRevision) } : nil
    Circle()
      .fill(LinearGradient(colors: [colors.0, colors.1], startPoint: .top, endPoint: .bottom))
      .overlay {
        if let photo {
          Image(uiImage: photo).resizable().scaledToFill().clipShape(Circle())
        } else if let builtin {
          IOSProfileSymbol(symbol: builtin.symbol, size: size)
        } else {
          Text(IOSProfileColor.initial(of: name))
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
      }
      .overlay { Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1.5) }
      .frame(width: size, height: size)
      .accessibilityHidden(true)
      .task(id: "\(id?.uuidString ?? "")-\(pictureKey ?? "")-\(pictureRevision)") {
        if pictureKey == IOSProfilePictures.photoKey, let id {
          photos.load(id: id, revision: pictureRevision)
        }
      }
  }
}

/// The Mac picker's slowly drifting wash of color, so no profile's titles show before unlock.
struct IOSAmbientBackground: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @State private var drift = false

  var body: some View {
    GeometryReader { geometry in
      let size = max(geometry.size.width, geometry.size.height)
      ZStack {
        IOSDesign.canvas
        if !reduceTransparency {
          glow(Color(red: 0.2, green: 0.26, blue: 0.62), diameter: size * 0.62)
            .offset(
              x: geometry.size.width * (drift ? -0.22 : -0.3),
              y: geometry.size.height * (drift ? -0.24 : -0.16))
          glow(Color(red: 0.05, green: 0.38, blue: 0.44), diameter: size * 0.55)
            .offset(
              x: geometry.size.width * (drift ? 0.3 : 0.22),
              y: geometry.size.height * (drift ? 0.2 : 0.3))
          glow(Color(red: 0.4, green: 0.16, blue: 0.44), diameter: size * 0.48)
            .offset(
              x: geometry.size.width * (drift ? 0.18 : 0.28),
              y: geometry.size.height * (drift ? -0.3 : -0.2))
          RadialGradient(
            colors: [.clear, .black.opacity(0.35)], center: .center,
            startRadius: size * 0.2, endRadius: size * 0.75)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) { drift = true }
    }
    .onChange(of: reduceMotion) { _, reduced in
      if reduced {
        withAnimation(nil) { drift = false }
      } else {
        withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) { drift = true }
      }
    }
  }

  private func glow(_ color: Color, diameter: CGFloat) -> some View {
    Circle()
      .fill(color.opacity(0.5))
      .frame(width: diameter, height: diameter)
      .blur(radius: diameter * 0.22)
  }
}

/// Digits-only PIN entry with an on-screen keypad; the system keyboard never opens.
///
/// It gives nothing away about the PIN: the field shows only the digits typed so far, with no
/// empty placeholders for an expected length, OK can always be pressed, and a PIN of the wrong
/// length is answered exactly like a wrong one.
struct IOSPINView: View {
  @EnvironmentObject private var model: IOSAppModel
  let profile: IOSWatchingProfile
  @State private var pin = ""
  @State private var attempts = 0
  @State private var showingRecovery = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  private static let rows = [
    ["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["delete", "0", "ok"],
  ]
  /// Longer input is not kept; this is the general rule, not this profile's PIN length.
  private static let maximumLength = 8

  var body: some View {
    // Portrait: profile above the keypad, like the iPhone passcode screen. A phone on its side
    // has too little height for that, so the two sit next to each other.
    GeometryReader { geometry in
      let metrics = IOSLayoutMetrics.pinKeyMetrics(
        availableWidth: geometry.size.width, availableHeight: geometry.size.height,
        isCompactHeight: verticalSizeClass == .compact)
      ScrollView {
        Group {
          if verticalSizeClass == .compact {
            HStack(spacing: min(40, max(20, geometry.size.width * 0.05))) {
              identity
              keypad(metrics: metrics)
            }
          } else {
            VStack(spacing: metrics.diameter < 68 ? 18 : 28) {
              identity
              keypad(metrics: metrics)
            }
          }
        }
        .padding(IOSDesign.margin(for: horizontalSizeClass))
        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .background { keyboardKeys }
    // An inset, not an overlay: with large text the button would otherwise cover the avatar.
    .safeAreaInset(edge: .top, spacing: 0) {
      Button {
        model.cancelProfileSelection()
      } label: {
        Label("Profiles", systemImage: "chevron.left").font(.body.weight(.semibold))
          .frame(minHeight: 44)
          .contentShape(Rectangle())
      }
      .tint(.white)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, IOSDesign.margin(for: horizontalSizeClass))
      .accessibilityIdentifier("profile-back")
    }
    .onChange(of: model.pinRejections) { _, _ in
      pin = ""
      withAnimation(reduceMotion ? nil : .linear(duration: 0.4)) { attempts += 1 }
    }
    .iosBackCommand { model.cancelProfileSelection() }
    .alert("Forgot PIN?", isPresented: $showingRecovery) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(
        profile.role == "owner"
          ? "On the computer running your server, open Aurelia and choose Forgot PIN? on the owner profile. You need the Server Password. On a server without a screen, use its owner PIN recovery instructions."
          : "Ask the server owner to set a new PIN for this profile in Settings › Profiles and Devices."
      )
    }
  }

  private var identity: some View {
    VStack(spacing: verticalSizeClass == .compact ? 8 : 12) {
      IOSProfilePicture(
        id: profile.id, name: profile.name, size: verticalSizeClass == .compact ? 56 : 72,
        pictureKey: profile.pictureKey, pictureRevision: profile.pictureRevision
      )
      .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
      VStack(spacing: 2) {
        Text(profile.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
        Text("Enter your PIN").font(.subheadline).foregroundStyle(.secondary)
      }
      pinField.modifier(IOSShakeEffect(travel: reduceMotion ? 0 : CGFloat(attempts)))
      ZStack {
        if model.isBusy {
          ProgressView().accessibilityLabel("Checking PIN")
        } else if let error = model.error {
          IOSErrorText(message: error).accessibilityIdentifier("profile-pin-error")
        }
      }.frame(minHeight: 22)
      Button("Forgot PIN?") { showingRecovery = true }
        .font(.subheadline.weight(.semibold))
        .tint(.white)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityIdentifier("profile-forgot-pin")
    }
    .frame(maxWidth: 300)
  }

  /// An iPad keyboard types the PIN too: digits, Delete and Return, without a text field.
  private var keyboardKeys: some View {
    ZStack {
      ForEach(0..<10, id: \.self) { digit in
        IOSKeyCommand(key: KeyEquivalent(Character(String(digit)))) { press(String(digit)) }
      }
      IOSKeyCommand(key: .delete) { press("delete") }
      IOSKeyCommand(key: .return) { press("ok") }
    }
    .disabled(model.isBusy)
  }

  private func keypad(
    metrics: (diameter: CGFloat, horizontalSpacing: CGFloat, verticalSpacing: CGFloat)
  ) -> some View {
    Grid(horizontalSpacing: metrics.horizontalSpacing, verticalSpacing: metrics.verticalSpacing) {
      ForEach(Self.rows, id: \.self) { row in
        GridRow {
          ForEach(row, id: \.self) { key in keyButton(key, diameter: metrics.diameter) }
        }
      }
    }
  }

  /// A capsule like the Mac's PIN field, with one dot per digit typed.
  private var pinField: some View {
    ZStack {
      if pin.isEmpty {
        Text("PIN").font(.system(.title3, design: .rounded, weight: .medium))
          .foregroundStyle(.secondary)
      } else {
        HStack(spacing: 12) {
          ForEach(0..<pin.count, id: \.self) { _ in
            Circle().fill(.white).frame(width: 12, height: 12)
          }
        }
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 10)
    .frame(minWidth: 200, minHeight: 50)
    .background {
      if reduceTransparency {
        Capsule().fill(IOSDesign.surface)
      } else {
        Capsule().fill(.ultraThinMaterial)
        Capsule().fill(Color.black.opacity(0.25))
      }
    }
    .overlay { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1.5) }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pin.count)
    .accessibilityElement().accessibilityIdentifier("profile-pin")
    .accessibilityLabel("PIN").accessibilityValue("\(pin.count) digits entered")
  }

  private func keyButton(_ key: String, diameter: CGFloat) -> some View {
    Button {
      press(key)
    } label: {
      Group {
        switch key {
        case "delete":
          Image(systemName: "delete.left")
            .font(.system(size: diameter * 0.32, weight: .medium))
        case "ok":
          Text("OK").font(.system(size: diameter * 0.29, weight: .semibold, design: .rounded))
        default:
          Text(key).font(.system(size: diameter * 0.42, weight: .regular, design: .rounded))
        }
      }
    }
    .buttonStyle(IOSPINKeyStyle(diameter: diameter, prominent: key == "ok"))
    .disabled(model.isBusy)
    .accessibilityIdentifier(key == "ok" ? "profile-continue" : "pin-key-\(key)")
    .accessibilityLabel(key == "delete" ? "Delete" : key == "ok" ? "Continue" : key)
  }

  private func press(_ key: String) {
    switch key {
    case "delete": if !pin.isEmpty { pin.removeLast() }
    case "ok":
      if pin.isEmpty {
        withAnimation(reduceMotion ? nil : .linear(duration: 0.4)) { attempts += 1 }
      } else {
        model.openProfile(profile, pin: pin)
      }
    default:
      if pin.count < Self.maximumLength { pin.append(key) }
    }
  }
}

/// Round keys like the iPhone's passcode pad: translucent at rest, light while pressed.
private struct IOSPINKeyStyle: ButtonStyle {
  var diameter: CGFloat = 76
  var prominent = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  func makeBody(configuration: Configuration) -> some View {
    let fill =
      reduceTransparency
      ? (configuration.isPressed ? Color.white.opacity(0.45) : IOSDesign.surface)
      : Color.white.opacity(configuration.isPressed ? 0.45 : prominent ? 0.24 : 0.13)
    configuration.label
      .foregroundStyle(.white)
      .frame(width: diameter, height: diameter)
      .background {
        Circle().fill(fill)
          .overlay {
            if contrast == .increased || reduceTransparency {
              Circle().strokeBorder(.white.opacity(0.32), lineWidth: 1)
            }
          }
      }
      .contentShape(Circle())
      .opacity(enabled ? 1 : 0.4)
      .animation(
        reduceMotion ? nil : .easeOut(duration: configuration.isPressed ? 0.02 : 0.25),
        value: configuration.isPressed)
  }
}

/// Horizontal shake after a rejected PIN.
private struct IOSShakeEffect: GeometryEffect {
  var travel: CGFloat
  var animatableData: CGFloat {
    get { travel }
    set { travel = newValue }
  }
  func effectValue(size: CGSize) -> ProjectionTransform {
    ProjectionTransform(CGAffineTransform(translationX: 12 * sin(travel * .pi * 6), y: 0))
  }
}
