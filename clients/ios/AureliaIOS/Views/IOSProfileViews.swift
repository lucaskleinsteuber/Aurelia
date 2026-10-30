import SwiftUI

/// "Who's watching?" in the Mac app's style: a drifting color wash, round colored avatars with
/// the profile's initial, and a PIN keypad that never hints at how long the PIN is.
struct IOSProfilesView: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      IOSAmbientBackground()
      if let profile = model.selectedProfile {
        IOSPINView(profile: profile).id(profile.id)
          .transition(.opacity)
      } else {
        picker.transition(.opacity)
      }
    }
    .animation(
      reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.32),
      value: model.selectedProfile?.id)
  }

  private var picker: some View {
    VStack(spacing: IOSDesign.s(76)) {
      Text("Who’s watching?").font(.system(size: IOSDesign.s(64), weight: .bold)).tracking(-0.5)
      IOSCenteredFlowLayout(spacing: IOSDesign.s(72), rowSpacing: 56) {
        ForEach(model.profiles) { profile in
          Button {
            model.openProfile(profile)
          } label: {
            IOSProfileEntry(profile: profile)
          }
          .buttonStyle(IOSAvatarButtonStyle(ringDiameter: IOSProfileEntry.avatarSize + 20))
          .disabled(model.isBusy || profile.needsPinSetup)
          .accessibilityIdentifier("profile-\(profile.id)")
          .accessibilityLabel(profile.name)
          .accessibilityValue(
            profile.needsPinSetup
              ? "PIN setup required"
              : profile.pinProtectionEnabled ? "PIN protected" : "No PIN")
        }
      }.frame(maxWidth: IOSDesign.s(1500))
      VStack(spacing: IOSDesign.s(26)) {
        if let error = model.error {
          IOSErrorText(message: error)
          Button("Try Again") { Task { await model.refreshProfiles() } }
            .buttonStyle(IOSButtonStyle()).disabled(model.isBusy)
        }
        ProgressView().opacity(model.isBusy ? 1 : 0)
      }
    }
    .padding(IOSDesign.s(80)).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Avatar with the name below and a small lock beside it, as on the Mac.
private struct IOSProfileEntry: View {
  static let avatarSize: CGFloat = 200
  let profile: IOSWatchingProfile

  var body: some View {
    VStack(spacing: IOSDesign.s(24)) {
      IOSProfilePicture(id: profile.id, name: profile.name, size: Self.avatarSize)
        .shadow(color: .black.opacity(0.3), radius: 22, y: 12)
      HStack(spacing: IOSDesign.s(10)) {
        Text(profile.name).font(.system(size: IOSDesign.s(30), weight: .semibold)).lineLimit(2)
          .multilineTextAlignment(.center)
        if profile.pinProtectionEnabled || profile.needsPinSetup {
          Image(systemName: "lock.fill").font(.system(size: IOSDesign.s(18), weight: .semibold))
            .foregroundStyle(.secondary)
        }
      }
      if profile.needsPinSetup {
        Text("Set up a PIN on the Mac").font(.system(size: IOSDesign.s(20))).foregroundStyle(
          .secondary)
      }
    }
    .frame(width: IOSDesign.s(260))
  }
}

/// A round profile picture with the profile's initial on a gradient, in the same color the Mac
/// app gives that profile.
struct IOSProfilePicture: View {
  let id: UUID?
  let name: String
  var size: CGFloat = 200

  static let palettes: [(Color, Color)] = [
    (Color(red: 0.36, green: 0.62, blue: 1.0), Color(red: 0.13, green: 0.36, blue: 0.86)),
    (Color(red: 0.74, green: 0.49, blue: 1.0), Color(red: 0.44, green: 0.22, blue: 0.82)),
    (Color(red: 1.0, green: 0.55, blue: 0.6), Color(red: 0.84, green: 0.24, blue: 0.4)),
    (Color(red: 1.0, green: 0.72, blue: 0.36), Color(red: 0.9, green: 0.42, blue: 0.14)),
    (Color(red: 0.36, green: 0.84, blue: 0.8), Color(red: 0.1, green: 0.52, blue: 0.56)),
    (Color(red: 0.5, green: 0.86, blue: 0.48), Color(red: 0.18, green: 0.56, blue: 0.3)),
    (Color(red: 0.55, green: 0.6, blue: 1.0), Color(red: 0.28, green: 0.3, blue: 0.8)),
  ]

  var body: some View {
    let colors = Self.palettes[IOSProfileColor.index(for: id) % Self.palettes.count]
    Circle()
      .fill(LinearGradient(colors: [colors.0, colors.1], startPoint: .top, endPoint: .bottom))
      .overlay {
        Text(IOSProfileColor.initial(of: name))
          .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
          .foregroundStyle(.white)
          .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
      }
      .overlay { Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1.5) }
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

/// The Mac picker's slowly drifting wash of color, so no profile's titles show before unlock.
struct IOSAmbientBackground: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var drift = false

  var body: some View {
    GeometryReader { geometry in
      let size = max(geometry.size.width, geometry.size.height)
      ZStack {
        IOSDesign.canvas
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
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) { drift = true }
    }
  }

  private func glow(_ color: Color, diameter: CGFloat) -> some View {
    Circle()
      .fill(color.opacity(0.5))
      .frame(width: diameter, height: diameter)
      .blur(radius: diameter * 0.22)
  }
}

/// The focused profile lifts with a white ring around its avatar, like the Mac's hover ring.
private struct IOSAvatarButtonStyle: ButtonStyle {
  let ringDiameter: CGFloat
  @Environment(\.isFocused) private var focused
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .overlay(alignment: .top) {
        Circle()
          .strokeBorder(.white.opacity(focused && enabled ? 0.95 : 0), lineWidth: 5)
          .frame(width: ringDiameter, height: ringDiameter)
          .offset(y: -10)
          .allowsHitTesting(false)
      }
      .opacity(enabled ? (focused ? 1 : 0.8) : 0.45)
      .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.97 : focused ? 1.08 : 1)
      .animation(
        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.72), value: focused)
  }
}

/// Centers every row, including a single profile or an incomplete last row.
private struct IOSCenteredFlowLayout: Layout {
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
///
/// It gives nothing away about the PIN: the field shows only the digits typed so far, with no
/// empty placeholders for an expected length, OK can always be pressed, and a PIN of the wrong
/// length is answered exactly like a wrong one.
struct IOSPINView: View {
  @EnvironmentObject private var model: IOSAppModel
  let profile: IOSWatchingProfile
  @State private var pin = ""
  @State private var attempts = 0
  @FocusState private var focusedKey: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private static let rows = [
    ["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["delete", "0", "ok"],
  ]
  /// Longer input is not kept; this is the general rule, not this profile's PIN length.
  private static let maximumLength = 8

  var body: some View {
    HStack(spacing: IOSDesign.s(150)) {
      VStack(spacing: IOSDesign.s(30)) {
        Button {
          model.cancelProfileSelection()
        } label: {
          IOSProfilePicture(id: profile.id, name: profile.name, size: 170)
            .shadow(color: .black.opacity(0.3), radius: 22, y: 12)
        }
        .buttonStyle(IOSAvatarButtonStyle(ringDiameter: 190))
        .accessibilityLabel("Choose another profile")
        .accessibilityIdentifier("profile-back")
        VStack(spacing: IOSDesign.s(10)) {
          Text(profile.name).font(.system(size: IOSDesign.s(40), weight: .bold))
            .multilineTextAlignment(.center).lineLimit(2)
          Text("Enter your PIN").font(.system(size: IOSDesign.s(26))).foregroundStyle(.secondary)
        }
        pinField.modifier(IOSShakeEffect(travel: reduceMotion ? 0 : CGFloat(attempts)))
        ZStack {
          if model.isBusy {
            ProgressView()
          } else if let error = model.error {
            IOSErrorText(message: error).accessibilityIdentifier("profile-pin-error")
          }
        }.frame(height: IOSDesign.s(44))
      }
      .frame(width: IOSDesign.s(560))
      Grid(horizontalSpacing: 28, verticalSpacing: 26) {
        ForEach(Self.rows, id: \.self) { row in
          GridRow {
            ForEach(row, id: \.self) { key in keyButton(key) }
          }
        }
      }
    }
    .padding(IOSDesign.s(80)).frame(maxWidth: .infinity, maxHeight: .infinity)
    .defaultFocus($focusedKey, "1")
    .onChange(of: model.pinRejections) { _, _ in
      pin = ""
      withAnimation(.linear(duration: 0.4)) { attempts += 1 }
    }
    .iosBackCommand { model.cancelProfileSelection() }
  }

  /// A capsule like the Mac's PIN field, with one dot per digit typed.
  private var pinField: some View {
    ZStack {
      if pin.isEmpty {
        Text("PIN").font(.system(size: IOSDesign.s(28), weight: .medium, design: .rounded))
          .foregroundStyle(.tertiary)
      } else {
        HStack(spacing: IOSDesign.s(18)) {
          ForEach(0..<pin.count, id: \.self) { _ in
            Circle().fill(.white).frame(width: IOSDesign.s(20), height: IOSDesign.s(20))
          }
        }
      }
    }
    .frame(width: IOSDesign.s(440), height: IOSDesign.s(84))
    .background {
      Capsule().fill(.ultraThinMaterial)
      Capsule().fill(Color.black.opacity(0.25))
    }
    .overlay { Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1.5) }
    .animation(.easeOut(duration: 0.12), value: pin.count)
    .accessibilityElement().accessibilityIdentifier("profile-pin")
    .accessibilityLabel("PIN").accessibilityValue("\(pin.count) digits entered")
  }

  private func keyButton(_ key: String) -> some View {
    Button {
      press(key)
    } label: {
      Group {
        switch key {
        case "delete":
          Image(systemName: "delete.left").font(.system(size: IOSDesign.s(32), weight: .semibold))
        case "ok": Text("OK").font(.system(size: IOSDesign.s(32), weight: .bold, design: .rounded))
        default: Text(key).font(.system(size: IOSDesign.s(40), weight: .medium, design: .rounded))
        }
      }
    }
    .buttonStyle(IOSPINKeyStyle(prominent: key == "ok"))
    .disabled(model.isBusy)
    .focused($focusedKey, equals: key)
    .accessibilityIdentifier(key == "ok" ? "profile-continue" : "pin-key-\(key)")
    .accessibilityLabel(key == "delete" ? "Delete" : key == "ok" ? "Continue" : key)
  }

  private func press(_ key: String) {
    switch key {
    case "delete": if !pin.isEmpty { pin.removeLast() }
    case "ok":
      if pin.isEmpty {
        withAnimation(.linear(duration: 0.4)) { attempts += 1 }
      } else {
        model.openProfile(profile, pin: pin)
      }
    default:
      if pin.count < Self.maximumLength { pin.append(key) }
    }
  }
}

/// Round keys like the passcode pads in Apple's apps: glassy at rest, white when focused.
private struct IOSPINKeyStyle: ButtonStyle {
  var prominent = false
  @Environment(\.isFocused) private var focused
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(focused ? Color.black : Color.white)
      .frame(width: IOSDesign.s(112), height: IOSDesign.s(112))
      .background {
        if focused {
          Circle().fill(.white)
        } else {
          Circle().fill(.white.opacity(prominent ? 0.24 : 0.12))
        }
      }
      .opacity(enabled ? 1 : 0.4)
      .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 18, y: 10)
      .scaleEffect(configuration.isPressed ? 0.94 : focused ? 1.1 : 1)
      .animation(.easeOut(duration: 0.14), value: focused)
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
