import AppKit
import SwiftUI

/// The shortcuts belong to the visible library window, including its detail pages.
struct LibraryFindShortcut: NSViewRepresentable {
  let isBlocked: () -> Bool
  var canGoBack: () -> Bool = { false }
  var back: (() -> Void)?
  let find: () -> Void

  func makeNSView(context: Context) -> ShortcutView {
    let view = ShortcutView()
    view.isBlocked = isBlocked
    view.canGoBack = canGoBack
    view.back = back
    view.find = find
    return view
  }

  func updateNSView(_ view: ShortcutView, context: Context) {
    view.isBlocked = isBlocked
    view.canGoBack = canGoBack
    view.back = back
    view.find = find
  }

  static func dismantleNSView(_ view: ShortcutView, coordinator: Void) {
    view.removeMonitor()
    view.isBlocked = nil
    view.canGoBack = nil
    view.back = nil
    view.find = nil
  }

  @MainActor final class ShortcutView: NSView {
    var isBlocked: (() -> Bool)?
    var canGoBack: (() -> Bool)?
    var back: (() -> Void)?
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
          let activeShellWindow =
            NSApp.isActive && NSApp.keyWindow === window
            && eventWindowNumber == window.windowNumber
          let blocked =
            window.attachedSheet != nil || NSApp.modalWindow != nil
            || RunLoop.current.currentMode == .eventTracking || self.isBlocked?() == true
          let modifierFlags = NSEvent.ModifierFlags(rawValue: modifiers)
          if LibraryFindShortcutPolicy.consumes(
            characters: characters, modifiers: modifierFlags,
            isRepeat: isRepeat, activeShellWindow: activeShellWindow, blocked: blocked)
          {
            self.find?()
            return true
          }
          if LibraryFindShortcutPolicy.consumesBack(
            characters: characters, modifiers: modifierFlags,
            isRepeat: isRepeat, activeShellWindow: activeShellWindow, blocked: blocked,
            canGoBack: self.canGoBack?() == true)
          {
            self.back?()
            return true
          }
          return false
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
