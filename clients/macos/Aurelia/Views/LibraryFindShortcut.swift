import AppKit
import SwiftUI

/// The shortcut belongs to the visible library window, including its detail pages.
struct LibraryFindShortcut: NSViewRepresentable {
  let isBlocked: () -> Bool
  let find: () -> Void

  func makeNSView(context: Context) -> ShortcutView {
    let view = ShortcutView()
    view.isBlocked = isBlocked
    view.find = find
    return view
  }

  func updateNSView(_ view: ShortcutView, context: Context) {
    view.isBlocked = isBlocked
    view.find = find
  }

  static func dismantleNSView(_ view: ShortcutView, coordinator: Void) {
    view.removeMonitor()
    view.isBlocked = nil
    view.find = nil
  }

  @MainActor final class ShortcutView: NSView {
    var isBlocked: (() -> Bool)?
    var find: (() -> Void)?
    private var monitor: Any?

    isolated deinit { removeMonitor() }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      removeMonitor()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let characters = event.charactersIgnoringModifiers
        let modifiers = event.modifierFlags.rawValue
        let isRepeat = event.isARepeat
        let eventWindowNumber = event.windowNumber
        let consumed = MainActor.assumeIsolated {
          guard let self, let window = self.window else { return false }
          let consumes = LibraryFindShortcutPolicy.consumes(
            characters: characters, modifiers: NSEvent.ModifierFlags(rawValue: modifiers),
            isRepeat: isRepeat,
            activeShellWindow: NSApp.isActive && NSApp.keyWindow === window
              && eventWindowNumber == window.windowNumber,
            blocked: window.attachedSheet != nil || NSApp.modalWindow != nil
              || RunLoop.current.currentMode == .eventTracking || self.isBlocked?() == true)
          if consumes { self.find?() }
          return consumes
        }
        return consumed ? nil : event
      }
    }

    func removeMonitor() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}
