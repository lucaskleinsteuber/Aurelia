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

/// A shortcut may be consumed during a native transition without requesting a
/// second transition. Text entry and shortcuts belonging to other windows pass on.
struct PlayerFullScreenShortcutPolicy {
  enum Decision: Equatable { case passThrough, consume, toggle }

  static func decision(
    characters: String?, modifiers: NSEvent.ModifierFlags, isRepeat: Bool,
    activePlayerWindow: Bool, editingText: Bool, blocked: Bool, transitioning: Bool
  ) -> Decision {
    guard characters?.lowercased() == "f",
      modifiers.intersection([.command, .control, .option]).isEmpty,
      activePlayerWindow, !editingText, !blocked
    else { return .passThrough }
    return isRepeat || transitioning ? .consume : .toggle
  }
}

/// The local monitor belongs to the player window, rather than its video view's
/// first responder. Native controls can retain focus without losing the shortcut.
@MainActor
final class PlayerFullScreenKeyboard {
  private weak var window: NSWindow?
  private var monitor: Any?
  private var observers: [NSObjectProtocol] = []
  private var isBlocked: (() -> Bool)?
  private var onToggle: (() -> Void)?
  private(set) var isTransitioning = false
  private(set) var isRetired = false

  isolated deinit { retire() }

  func install(
    on window: NSWindow, isBlocked: @escaping () -> Bool, onToggle: @escaping () -> Void
  ) {
    guard !isRetired else { return }
    self.isBlocked = isBlocked
    self.onToggle = onToggle
    guard self.window !== window else { return }
    removeMonitor()
    self.window = window
    for name in [
      NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
      NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
      NSWindow.willCloseNotification,
    ] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
          [weak self] notification in
          let notificationName = notification.name
          MainActor.assumeIsolated {
            guard let self else { return }
            switch notificationName {
            case NSWindow.willCloseNotification:
              self.retire()
            case NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification:
              self.isTransitioning = true
            default:
              self.isTransitioning = false
            }
          }
        })
    }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let characters = event.charactersIgnoringModifiers
      let modifiers = event.modifierFlags.rawValue
      let isRepeat = event.isARepeat
      let eventWindowNumber = event.windowNumber
      let consumed = MainActor.assumeIsolated {
        guard let self else { return false }
        return self.consumes(
          characters: characters, modifierFlags: modifiers,
          isRepeat: isRepeat, windowNumber: eventWindowNumber)
      }
      return consumed ? nil : event
    }
  }

  /// Both the keyboard and the full-screen button acquire the same transition.
  func beginToggle(on window: NSWindow) -> Bool {
    guard !isRetired, self.window === window, !isTransitioning else { return false }
    isTransitioning = true
    return true
  }

  func retire() {
    isRetired = true
    removeMonitor()
    window = nil
    isBlocked = nil
    onToggle = nil
  }

  private func consumes(
    characters: String?, modifierFlags: UInt, isRepeat: Bool, windowNumber: Int
  ) -> Bool {
    guard let window, !isRetired else { return false }
    let decision = PlayerFullScreenShortcutPolicy.decision(
      characters: characters, modifiers: NSEvent.ModifierFlags(rawValue: modifierFlags),
      isRepeat: isRepeat,
      activePlayerWindow: NSApp.isActive && NSApp.keyWindow === window
        && windowNumber == window.windowNumber,
      editingText: window.firstResponder is NSText || window.firstResponder is NSTextField,
      blocked: window.attachedSheet != nil || NSApp.modalWindow != nil
        || RunLoop.current.currentMode == .eventTracking || isBlocked?() == true,
      transitioning: isTransitioning)
    switch decision {
    case .passThrough: return false
    case .consume: return true
    case .toggle:
      onToggle?()
      return true
    }
  }

  private func removeMonitor() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    isTransitioning = false
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
