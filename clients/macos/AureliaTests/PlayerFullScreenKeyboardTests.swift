import AppKit
import Testing

@testable import Aurelia

@MainActor struct PlayerFullScreenKeyboardTests {
  @Test func shortcutUsesTheTypedCharacterAndAllowsShiftAndCapsLock() {
    #expect(decision("f") == .toggle)
    #expect(decision("F", modifiers: .shift) == .toggle)
    #expect(decision("F", modifiers: .capsLock) == .toggle)
    #expect(decision("g") == .passThrough)
    #expect(decision(nil) == .passThrough)
    let forbidden: [NSEvent.ModifierFlags] = [.command, .control, .option, [.command, .control]]
    for modifier in forbidden {
      #expect(decision("f", modifiers: modifier) == .passThrough)
    }
  }

  @Test func textMenusDialogsAndOtherWindowsKeepTheirKeyboardInput() {
    #expect(decision("f", activePlayerWindow: false) == .passThrough)
    #expect(decision("f", editingText: true) == .passThrough)
    #expect(decision("f", blocked: true) == .passThrough)
    // A menu or editor still owns repeated input even during a native transition.
    #expect(decision("f", isRepeat: true, editingText: true, transitioning: true) == .passThrough)
    #expect(decision("f", isRepeat: true, blocked: true, transitioning: true) == .passThrough)
  }

  @Test func heldKeysAndNativeTransitionsConsumeWithoutRetoggling() {
    #expect(decision("f", isRepeat: true) == .consume)
    #expect(decision("f", transitioning: true) == .consume)
    #expect(decision("F", modifiers: .shift, isRepeat: true, transitioning: true) == .consume)
    #expect(decision("m", transitioning: true) == .passThrough)
  }

  @Test func buttonAndShortcutShareTheWindowTransitionAndRetireTogether() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    let otherWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    let keyboard = PlayerFullScreenKeyboard()
    keyboard.install(on: window, isBlocked: { false }, onToggle: {})
    #expect(!keyboard.beginToggle(on: otherWindow))
    #expect(keyboard.beginToggle(on: window))
    #expect(!keyboard.beginToggle(on: window))
    NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
    #expect(!keyboard.isTransitioning)
    #expect(keyboard.beginToggle(on: window))
    NotificationCenter.default.post(
      name: NSWindow.didExitFullScreenNotification, object: otherWindow)
    #expect(keyboard.isTransitioning)
    NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
    #expect(!keyboard.isTransitioning)
    // Native traffic-light transitions use the same guard as shortcut transitions.
    NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
    #expect(!keyboard.beginToggle(on: window))
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
    #expect(keyboard.isRetired)
    #expect(!keyboard.beginToggle(on: window))
    keyboard.install(on: window, isBlocked: { false }, onToggle: {})
    NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
    #expect(!keyboard.isTransitioning, "Retired players must remove their native observers.")
  }

  private func decision(
    _ characters: String?, modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false,
    activePlayerWindow: Bool = true, editingText: Bool = false, blocked: Bool = false,
    transitioning: Bool = false
  ) -> PlayerFullScreenShortcutPolicy.Decision {
    PlayerFullScreenShortcutPolicy.decision(
      characters: characters, modifiers: modifiers, isRepeat: isRepeat,
      activePlayerWindow: activePlayerWindow, editingText: editingText, blocked: blocked,
      transitioning: transitioning)
  }
}
