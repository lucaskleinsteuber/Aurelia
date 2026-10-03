import AppKit
import SwiftUI

/// A generation token makes already queued timers harmless after any new interaction.
struct PlayerControlsPolicy {
  private(set) var holds: Set<String> = []
  private(set) var generation: UInt64 = 0

  @discardableResult mutating func hold(_ reason: String, active: Bool) -> Bool {
    let changed = active ? holds.insert(reason).inserted : holds.remove(reason) != nil
    guard changed else { return false }
    invalidate()
    return true
  }

  @discardableResult mutating func invalidate() -> UInt64 {
    generation &+= 1
    return generation
  }

  func permitsHide(_ token: UInt64, preparing: Bool, error: Bool) -> Bool {
    token == generation && holds.isEmpty && !preparing && !error
  }
}

/// Tracking-area/layout updates are not physical pointer movement.
struct PlayerPointerActivity {
  private var position: CGPoint

  init(position: CGPoint) { self.position = position }

  mutating func moved(to position: CGPoint) -> Bool {
    guard position.x.isFinite, position.y.isFinite, position != self.position else { return false }
    self.position = position
    return true
  }
}

struct PlayerMenuOption {
  let title: String
  var selected = false
  var enabled = true
  var separator = false
  var action: () -> Void = {}
  static var divider: Self { Self(title: "", separator: true) }
}

/// Native NSMenu lifecycle, including Escape/outside clicks, not an inferred button click.
struct TrackedPlayerMenu<Label: View>: View {
  let title: String
  let identifier: String
  let options: [PlayerMenuOption]
  let onOpen: (Bool) -> Void
  let onFocus: (Bool) -> Void
  @ViewBuilder let label: () -> Label

  var body: some View {
    label()
      .overlay {
        MenuButton(
          title: title, identifier: identifier, options: options,
          onOpen: onOpen, onFocus: onFocus)
      }
  }

  private struct MenuButton: NSViewRepresentable {
    let title: String
    let identifier: String
    let options: [PlayerMenuOption]
    let onOpen: (Bool) -> Void
    let onFocus: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Button {
      let button = Button()
      button.title = ""
      button.isBordered = false
      button.focusRingType = .none
      button.setAccessibilityLabel(title)
      button.setAccessibilityIdentifier(identifier)
      button.target = context.coordinator
      button.action = #selector(Coordinator.open(_:))
      context.coordinator.button = button
      return button
    }

    func updateNSView(_ button: Button, context: Context) {
      context.coordinator.options = options
      context.coordinator.onOpen = onOpen
      button.onFocus = onFocus
    }

    static func dismantleNSView(_ view: Button, coordinator: Coordinator) {
      coordinator.menu?.cancelTracking()
      coordinator.finish()
      view.onFocus?(false)
    }

    final class Button: NSButton {
      var onFocus: ((Bool) -> Void)?
      override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocus?(true) }
        return result
      }
      override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocus?(false) }
        return result
      }
    }

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
      weak var button: Button?
      var options: [PlayerMenuOption] = []
      var onOpen: ((Bool) -> Void)?
      var menu: NSMenu?
      private var opened = false
      private var observers: [NSObjectProtocol] = []

      @objc func open(_ sender: NSButton) {
        let menu = NSMenu(title: sender.accessibilityLabel() ?? "Playback")
        menu.autoenablesItems = false
        menu.delegate = self
        for (index, option) in options.enumerated() {
          if option.separator {
            menu.addItem(.separator())
            continue
          }
          let item = NSMenuItem(
            title: option.title, action: #selector(select(_:)), keyEquivalent: "")
          item.target = self
          item.tag = index
          item.isEnabled = option.enabled
          item.state = option.selected ? .on : .off
          menu.addItem(item)
        }
        self.menu = menu
        for name in [
          NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
          NSWindow.willCloseNotification,
        ] {
          observers.append(
            NotificationCenter.default.addObserver(
              forName: name, object: sender.window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.menu?.cancelTracking() } })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        finish()
      }

      @objc private func select(_ item: NSMenuItem) {
        guard options.indices.contains(item.tag) else { return }
        options[item.tag].action()
      }

      func menuWillOpen(_ menu: NSMenu) {
        opened = true
        onOpen?(true)
      }

      func menuDidClose(_ menu: NSMenu) { finish() }

      func finish() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        menu = nil
        if opened {
          opened = false
          onOpen?(false)
        }
      }
    }
  }
}

struct PlayerSeekGlyph: View {
  let interval: Int
  let forward: Bool

  static func numberedSymbol(interval: Int, forward: Bool) -> String? {
    let name = "\(forward ? "goforward" : "gobackward").\(interval)"
    return NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? nil : name
  }

  var body: some View {
    if let name = Self.numberedSymbol(interval: interval, forward: forward) {
      Image(systemName: name).font(.system(size: 21, weight: .semibold))
    } else {
      ZStack {
        Image(systemName: forward ? "goforward" : "gobackward")
          .font(.system(size: 21, weight: .semibold))
        Text(String(interval))
          .font(.system(size: 8, weight: .bold, design: .rounded))
          .offset(y: 2)  // Ring center excludes the arrowhead above it.
      }
    }
  }
}
