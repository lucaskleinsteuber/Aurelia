import SwiftUI

struct KeyboardShortcutsSheet: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          section(title: "Playback") {
            shortcutRow("Play or Pause", keys: ["Space", "K"])
            shortcutRow("Seek Back / Forward", keys: ["←", "→"])
            shortcutRow("Previous Episode", keys: ["P", "⇧⌘←"])
            shortcutRow("Next Episode", keys: ["N", "⇧⌘→"])
            shortcutRow("Mute or Unmute", keys: ["M"])
            shortcutRow("Toggle Full Screen", keys: ["F"])
            shortcutRow("Fill Screen or Show Whole Picture", keys: ["Z"])
            shortcutRow("Exit Full Screen or Close", keys: ["Esc"])
          }

          section(title: "Navigation & Commands") {
            shortcutRow("Add Media…", keys: ["⌘O"])
            shortcutRow("Keyboard Shortcuts", keys: ["?", "⌘/"])
            shortcutRow("Dismiss Dialog", keys: ["Esc"])
          }
        }
        .padding(AureliaDesign.pagePadding)
      }
      Divider()
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, AureliaDesign.pagePadding)
      .padding(.vertical, 14)
    }
    .frame(width: 500, height: 460)
    .background(AureliaBackdrop())
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: "keyboard.fill")
        .font(.system(size: 28, weight: .semibold))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.white.opacity(0.88))
      VStack(alignment: .leading, spacing: 2) {
        Text("Keyboard Shortcuts")
          .font(.title2.weight(.bold))
        Text("Controls for playback and navigation")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.horizontal, AureliaDesign.pagePadding)
    .padding(.vertical, 18)
  }

  @ViewBuilder
  private func section<Content: View>(title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.caption.weight(.bold))
        .tracking(1.0)
        .foregroundStyle(.secondary)
      VStack(spacing: 6) {
        content()
      }
      .padding(12)
      .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color.white.opacity(0.08), lineWidth: 1)
      }
    }
  }

  private func shortcutRow(_ label: String, keys: [String]) -> some View {
    HStack {
      Text(label)
        .font(.subheadline)
      Spacer(minLength: 12)
      HStack(spacing: 4) {
        ForEach(keys, id: \.self) { key in
          Text(key)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
              RoundedRectangle(cornerRadius: 5)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            }
        }
      }
    }
    .padding(.vertical, 2)
  }
}
