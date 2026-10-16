import SwiftUI

struct TVContentButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.82 : 1)
  }
}

struct TVButtonStyle: ButtonStyle {
  enum Kind { case action, icon, row }
  var kind: Kind = .action
  @Environment(\.isFocused) private var focused
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 24, weight: .semibold))
      .padding(.horizontal, kind == .action ? 24 : 0)
      .frame(width: kind == .icon ? 64 : nil, height: kind == .icon ? 56 : nil)
      .frame(minHeight: kind == .action ? 56 : nil)
      .foregroundStyle(.white.opacity(enabled ? 1 : 0.35))
      .background(
        focused ? Color(white: 0.25) : TVDesign.surface, in: RoundedRectangle(cornerRadius: 12)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(focused ? 0.9 : 0), lineWidth: 2)
      )
      .scaleEffect(configuration.isPressed ? 0.98 : focused ? 1.025 : 1)
      .animation(.easeOut(duration: 0.12), value: focused)
  }
}
