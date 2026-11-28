import SwiftUI

/// Single source of truth for the Keyboard Shortcuts sheet so documented shortcuts match the
/// commands wired into the app.
enum TarvenKeyboardShortcuts {
  struct Entry: Identifiable, Equatable, Sendable {
    let label: String
    let keys: [String]
    var id: String { "\(label)-\(keys.joined(separator: "+"))" }
  }

  struct Section: Identifiable, Equatable, Sendable {
    let title: String
    let entries: [Entry]
    var id: String { title }
  }

  static let sections: [Section] = [
    Section(
      title: "Playback",
      entries: [
        Entry(label: "Play or Pause", keys: ["Space", "K"]),
        Entry(label: "Seek Back / Forward", keys: ["←", "→"]),
        Entry(label: "Previous Episode", keys: ["P", "⇧⌘←"]),
        Entry(label: "Next Episode", keys: ["N", "⇧⌘→"]),
        Entry(label: "Skip Intro", keys: ["S", "Return"]),
        Entry(label: "Mute or Unmute", keys: ["M"]),
        Entry(label: "Toggle Full Screen", keys: ["F"]),
        Entry(label: "Fill Screen or Show Whole Picture", keys: ["Z"]),
        Entry(label: "Exit Full Screen or Close", keys: ["Esc"]),
      ]),
    Section(
      title: "Navigation & Commands",
      entries: [
        Entry(label: "Search Library", keys: ["⌘F"]),
        Entry(label: "Go Back", keys: ["⌘["]),
        Entry(label: "Show or Hide Sidebar", keys: ["⌃⌘S"]),
        Entry(label: "Settings…", keys: ["⌘,"]),
        Entry(label: "Add Media…", keys: ["⌘O"]),
        Entry(label: "Keyboard Shortcuts", keys: ["?", "⌘/"]),
        Entry(label: "Dismiss Dialog", keys: ["Esc"]),
      ]),
    Section(
      title: "Editors & Stories",
      entries: [
        Entry(label: "Save Power Settings", keys: ["⌘S"]),
        Entry(label: "Undo / Redo Artwork Crop", keys: ["⌘Z", "⇧⌘Z"]),
        Entry(label: "Previous / Next in Wrapped", keys: ["←", "→"]),
        Entry(label: "Pause or Resume Wrapped", keys: ["Space"]),
      ]),
  ]
}

struct KeyboardShortcutsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.tarvenContrast) private var contrast

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          ForEach(TarvenKeyboardShortcuts.sections) { group in
            section(title: group.title) {
              ForEach(group.entries) { entry in
                shortcutRow(entry.label, keys: entry.keys)
              }
            }
          }
        }
        .padding(TarvenDesign.pagePadding)
      }
      Divider()
      HStack {
        Spacer()
        TarvenSheetDoneButton { dismiss() }
      }
      .padding(.horizontal, TarvenDesign.pagePadding)
      .padding(.vertical, 14)
    }
    .tarvenSheetFrame(minWidth: 460, idealWidth: 520, minHeight: 400, idealHeight: 560)
    .background(TarvenBackdrop())
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
        Text("Controls for playback, navigation, editors, and stories")
          .font(.subheadline)
          .foregroundStyle(TarvenDesign.mutedText(for: contrast))
      }
      Spacer()
    }
    .padding(.horizontal, TarvenDesign.pagePadding)
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
        .foregroundStyle(TarvenDesign.mutedText(for: contrast))
      VStack(spacing: 6) {
        content()
      }
      .padding(12)
      .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(
            TarvenDesign.hairline(for: contrast),
            lineWidth: TarvenDesign.strokeWidth(for: contrast))
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
            .background(
              Color.white.opacity(contrast == .increased ? 0.22 : 0.12),
              in: RoundedRectangle(cornerRadius: 5)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 5)
                .strokeBorder(
                  Color.white.opacity(contrast == .increased ? 0.65 : 0.15),
                  lineWidth: contrast == .increased ? 1 : 0.5)
            }
        }
      }
    }
    .padding(.vertical, 2)
  }
}
