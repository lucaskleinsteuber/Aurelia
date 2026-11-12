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
    ScrollView {
      VStack(spacing: 32) {
        Text("Who’s watching?").font(.system(.largeTitle, weight: .bold))
          .multilineTextAlignment(.center)
        IOSProfileRows {
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
          ProgressView().opacity(model.isBusy ? 1 : 0)
        }
      }
      .padding(.horizontal, IOSDesign.margin).padding(.vertical, 40)
      .frame(maxWidth: .infinity)
      .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length }
    }
    .scrollBounceBehavior(.basedOnSize)
  }
}

/// Center each row, including a single profile and the last partially filled row.
private struct IOSProfileRows: Layout {
  private func dimensions(_ proposal: ProposedViewSize, count: Int) -> (
    width: CGFloat, columns: Int
  ) {
    let width = min(560, max(0, proposal.width ?? 560))
    let columns = max(1, min(count, Int((width + 20) / 140)))
    return (min(160, max(0, (width - CGFloat(columns - 1) * 20) / CGFloat(columns))), columns)
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
  let profile: IOSWatchingProfile

  var body: some View {
    VStack(spacing: 10) {
      IOSProfilePicture(
        id: profile.id, name: profile.name, size: 96, pictureKey: profile.pictureKey,
        pictureRevision: profile.pictureRevision
      )
      .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
      HStack(spacing: 4) {
        Text(profile.name).font(.subheadline.weight(.semibold)).lineLimit(2)
          .multilineTextAlignment(.center)
        if profile.pinProtectionEnabled || profile.needsPinSetup {
          Image(systemName: "lock.fill").font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  private static let rows = [
    ["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["delete", "0", "ok"],
  ]
  /// Longer input is not kept; this is the general rule, not this profile's PIN length.
  private static let maximumLength = 8

  var body: some View {
    // Portrait: profile above the keypad, like the iPhone passcode screen. A phone on its side
    // has too little height for that, so the two sit next to each other.
    Group {
      if verticalSizeClass == .compact {
        HStack(spacing: 48) {
          identity
          keypad
        }
      } else {
        VStack(spacing: 28) {
          identity
          keypad
        }
      }
    }
    .padding(IOSDesign.margin)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .topLeading) {
      Button {
        model.cancelProfileSelection()
      } label: {
        Label("Profiles", systemImage: "chevron.left").font(.body.weight(.semibold))
      }
      .tint(.white)
      .padding(.horizontal, IOSDesign.margin).padding(.top, 8)
      .accessibilityIdentifier("profile-back")
    }
    .onChange(of: model.pinRejections) { _, _ in
      pin = ""
      withAnimation(.linear(duration: 0.4)) { attempts += 1 }
    }
    .iosBackCommand { model.cancelProfileSelection() }
  }

  private var identity: some View {
    VStack(spacing: 12) {
      IOSProfilePicture(
        id: profile.id, name: profile.name, size: 72, pictureKey: profile.pictureKey,
        pictureRevision: profile.pictureRevision
      )
      .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
      VStack(spacing: 2) {
        Text(profile.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
          .lineLimit(2)
        Text("Enter your PIN").font(.subheadline).foregroundStyle(.secondary)
      }
      pinField.modifier(IOSShakeEffect(travel: reduceMotion ? 0 : CGFloat(attempts)))
      ZStack {
        if model.isBusy {
          ProgressView()
        } else if let error = model.error {
          IOSErrorText(message: error).accessibilityIdentifier("profile-pin-error")
        }
      }.frame(minHeight: 22)
    }
    .frame(maxWidth: 300)
  }

  private var keypad: some View {
    Grid(horizontalSpacing: 24, verticalSpacing: 14) {
      ForEach(Self.rows, id: \.self) { row in
        GridRow {
          ForEach(row, id: \.self) { key in keyButton(key) }
        }
      }
    }
  }

  /// A capsule like the Mac's PIN field, with one dot per digit typed.
  private var pinField: some View {
    ZStack {
      if pin.isEmpty {
        Text("PIN").font(.system(.title3, design: .rounded, weight: .medium))
          .foregroundStyle(.tertiary)
      } else {
        HStack(spacing: 12) {
          ForEach(0..<pin.count, id: \.self) { _ in
            Circle().fill(.white).frame(width: 12, height: 12)
          }
        }
      }
    }
    .frame(width: 220, height: 50)
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
          Image(systemName: "delete.left").font(.system(size: 24, weight: .medium))
        case "ok": Text("OK").font(.system(size: 22, weight: .semibold, design: .rounded))
        default: Text(key).font(.system(size: 32, weight: .regular, design: .rounded))
        }
      }
    }
    .buttonStyle(IOSPINKeyStyle(prominent: key == "ok"))
    .disabled(model.isBusy)
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

/// Round keys like the iPhone's passcode pad: translucent at rest, light while pressed.
private struct IOSPINKeyStyle: ButtonStyle {
  var prominent = false
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(.white)
      .frame(width: 76, height: 76)
      .background {
        Circle().fill(.white.opacity(configuration.isPressed ? 0.45 : prominent ? 0.24 : 0.13))
      }
      .contentShape(Circle())
      .opacity(enabled ? 1 : 0.4)
      .animation(
        .easeOut(duration: configuration.isPressed ? 0.02 : 0.25), value: configuration.isPressed)
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
