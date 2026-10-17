import SwiftUI

/// A round profile picture with the profile's initial on a gradient, like account pictures in
/// Apple's apps. The color is stable for a profile because it derives from its identifier.
struct AureliaProfileAvatar: View {
  let id: UUID?
  let name: String
  var size: CGFloat = 96

  static let palettes: [(Color, Color)] = [
    (Color(red: 0.36, green: 0.62, blue: 1.0), Color(red: 0.13, green: 0.36, blue: 0.86)),
    (Color(red: 0.74, green: 0.49, blue: 1.0), Color(red: 0.44, green: 0.22, blue: 0.82)),
    (Color(red: 1.0, green: 0.55, blue: 0.6), Color(red: 0.84, green: 0.24, blue: 0.4)),
    (Color(red: 1.0, green: 0.72, blue: 0.36), Color(red: 0.9, green: 0.42, blue: 0.14)),
    (Color(red: 0.36, green: 0.84, blue: 0.8), Color(red: 0.1, green: 0.52, blue: 0.56)),
    (Color(red: 0.5, green: 0.86, blue: 0.48), Color(red: 0.18, green: 0.56, blue: 0.3)),
    (Color(red: 0.55, green: 0.6, blue: 1.0), Color(red: 0.28, green: 0.3, blue: 0.8)),
  ]

  static func paletteIndex(for id: UUID?) -> Int {
    guard let id else { return 0 }
    let sum = withUnsafeBytes(of: id.uuid) { $0.reduce(0) { $0 + Int($1) } }
    return sum % palettes.count
  }

  static func initial(of name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() }
      ?? "?"
  }

  var body: some View {
    let colors = Self.palettes[Self.paletteIndex(for: id)]
    Circle()
      .fill(LinearGradient(colors: [colors.0, colors.1], startPoint: .top, endPoint: .bottom))
      .overlay {
        Text(Self.initial(of: name))
          .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
          .foregroundStyle(.white)
          .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
      }
      .overlay { Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1) }
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

/// A calm, slowly drifting wash of color behind the profile picker, so the first screen of the
/// app feels alive without showing any profile's titles before it is unlocked.
struct AureliaAmbientBackground: View {
  @Environment(\.aureliaReduceMotion) private var reduceMotion
  @State private var drift = false

  var body: some View {
    GeometryReader { geometry in
      let size = max(geometry.size.width, geometry.size.height)
      ZStack {
        AureliaDesign.canvas
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

/// A slim bar that fades in at the top of a detail page once its hero has scrolled away,
/// keeping the way back and the title in reach, as in the Apple TV app.
struct AureliaCompactHeader: View {
  let title: String
  let isVisible: Bool
  let onBack: () -> Void
  @Environment(\.aureliaReduceTransparency) private var reduceTransparency

  var body: some View {
    HStack(spacing: 14) {
      AureliaIconControl(symbol: "chevron.left", label: "Back", action: onBack)
      Text(title)
        .font(.headline)
        .lineLimit(1)
        .accessibilityIdentifier("compact-header-title")
      Spacer(minLength: 0)
    }
    .padding(.horizontal, AureliaDesign.pagePadding)
    // Leaves room for the window controls when the sidebar is hidden.
    .padding(.top, 28)
    .padding(.bottom, 12)
    .frame(maxWidth: .infinity)
    .background {
      if reduceTransparency {
        AureliaDesign.canvas
      } else {
        ZStack {
          Rectangle().fill(.ultraThinMaterial)
          AureliaDesign.canvas.opacity(0.55)
        }
      }
    }
    .overlay(alignment: .bottom) { AureliaDesign.hairline.frame(height: 1) }
    .opacity(isVisible ? 1 : 0)
    .allowsHitTesting(isVisible)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("compact-header")
  }
}

extension View {
  /// Shows `AureliaCompactHeader` once the page has scrolled past `threshold`.
  func aureliaCompactHeader(
    title: String, threshold: CGFloat, onBack: @escaping () -> Void
  ) -> some View {
    modifier(CompactHeaderModifier(title: title, threshold: threshold, onBack: onBack))
  }
}

private struct CompactHeaderModifier: ViewModifier {
  let title: String
  let threshold: CGFloat
  let onBack: () -> Void
  @State private var scrolledPast = false
  @Environment(\.aureliaReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.contentOffset.y + geometry.contentInsets.top > threshold
      } action: { _, value in
        scrolledPast = value
      }
      .overlay(alignment: .top) {
        // Only present while needed, so the page never exposes a second, hidden Back button.
        if scrolledPast {
          AureliaCompactHeader(title: title, isVisible: true, onBack: onBack)
            .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : -8)))
        }
      }
      .animation(
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.28), value: scrolledPast)
  }
}

/// The profile row at the foot of the sidebar: a quiet highlight on hover and press.
struct SidebarFooterButtonStyle: ButtonStyle {
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(.white.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.07 : 0)))
      )
      .onHover { hovering = $0 }
  }
}
