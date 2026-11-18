import SwiftUI

/// Change PIN in the profile menu: the current PIN, the new one twice, all with the TV's keypad.
/// A viewer profile may also turn its PIN off; owners and administrators always keep one.
struct TVChangePINView: View {
  @EnvironmentObject private var model: TVAppModel
  @Environment(\.dismiss) private var dismiss

  private enum Step { case current, new, again }
  @State private var step = Step.current
  @State private var current = ""
  @State private var new = ""
  @State private var entry = ""
  @State private var message: String?
  @State private var working = false
  @State private var done: String?
  @FocusState private var focusedKey: String?
  private static let rows = [
    ["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["delete", "0", "ok"],
  ]

  private var canTurnOff: Bool { model.session?.user.role == "user" }

  var body: some View {
    HStack(spacing: 150) {
      VStack(spacing: 30) {
        Image(systemName: "lock.rotation").font(.system(size: 110)).foregroundStyle(.secondary)
        Text(done ?? prompt).font(.system(size: 36, weight: .bold)).multilineTextAlignment(.center)
        if done == nil {
          field
          Text(message ?? "4 to 8 digits.").font(.system(size: 24))
            .foregroundStyle(message == nil ? Color.secondary : Color.orange)
            .multilineTextAlignment(.center)
          if step == .current, canTurnOff {
            Button("Turn Off PIN") { Task { await turnOff() } }
              .buttonStyle(TVButtonStyle()).disabled(working || entry.isEmpty)
              .accessibilityIdentifier("pin-turn-off")
          }
        } else {
          Button("Done") { dismiss() }.buttonStyle(TVButtonStyle(kind: .primary))
        }
      }
      .frame(width: 600)
      if done == nil {
        Grid(horizontalSpacing: 28, verticalSpacing: 26) {
          ForEach(Self.rows, id: \.self) { row in
            GridRow { ForEach(row, id: \.self) { key in keyButton(key) } }
          }
        }
        .focusSection()
      }
    }
    .padding(80).frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TVDesign.canvas.ignoresSafeArea())
    .defaultFocus($focusedKey, "1")
  }

  private var prompt: String {
    switch step {
    case .current: "Enter Your Current PIN"
    case .new: "Choose a New PIN"
    case .again: "Enter the New PIN Again"
    }
  }

  private var field: some View {
    HStack(spacing: 18) {
      ForEach(0..<max(entry.count, 1), id: \.self) { index in
        Circle().fill(index < entry.count ? Color.white : Color.white.opacity(0.2))
          .frame(width: 20, height: 20)
      }
    }
    .frame(width: 440, height: 84)
    .background(Capsule().fill(.ultraThinMaterial))
    .accessibilityElement().accessibilityIdentifier("change-pin-field")
    .accessibilityValue("\(entry.count) digits entered")
  }

  private func keyButton(_ key: String) -> some View {
    Button {
      press(key)
    } label: {
      Group {
        switch key {
        case "delete": Image(systemName: "delete.left").font(.system(size: 32, weight: .semibold))
        case "ok": Text("OK").font(.system(size: 32, weight: .bold, design: .rounded))
        default: Text(key).font(.system(size: 40, weight: .medium, design: .rounded))
        }
      }
    }
    .buttonStyle(TVPINKeyStyle(prominent: key == "ok"))
    .disabled(working)
    .focused($focusedKey, equals: key)
    .accessibilityIdentifier("change-pin-key-\(key)")
    .accessibilityLabel(key == "delete" ? "Delete" : key == "ok" ? "Continue" : key)
  }

  private func press(_ key: String) {
    switch key {
    case "delete": if !entry.isEmpty { entry.removeLast() }
    case "ok": next()
    default: if entry.count < 8 { entry.append(key) }
    }
  }

  private func next() {
    message = nil
    switch step {
    case .current:
      current = entry
      step = .new
    case .new:
      guard (4...8).contains(entry.count) else {
        message = "Use 4 to 8 digits."
        return
      }
      new = entry
      step = .again
    case .again:
      guard entry == new else {
        message = "The PINs don't match. Choose the new PIN again."
        step = .new
        entry = ""
        return
      }
      Task { await save() }
    }
    entry = ""
  }

  private func save() async {
    guard let client = model.client else { return }
    working = true
    defer { working = false }
    do {
      try await client.changeProfilePIN(current: current.isEmpty ? nil : current, new: new)
      done = "Your PIN Has Changed"
    } catch {
      message = Self.problem(error)
      step = .current
    }
  }

  private func turnOff() async {
    guard let client = model.client else { return }
    working = true
    defer { working = false }
    do {
      try await client.removeProfilePIN(current: entry)
      done = "This Profile Opens Without a PIN"
    } catch {
      message = Self.problem(error)
      entry = ""
    }
  }

  private static func problem(_ error: Error) -> String {
    switch (error as? TVCoreError)?.code {
    case "invalid_profile_pin": "That current PIN isn't right. Try again."
    case "invalid_pin_format": "Use a numeric PIN with 4 to 8 digits."
    case "https_required": "Changing a PIN needs the server's secure connection."
    default: (error as? TVCoreError)?.serverMessage ?? error.localizedDescription
    }
  }
}
