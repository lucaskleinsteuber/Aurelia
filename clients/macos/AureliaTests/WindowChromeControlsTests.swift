import AppKit
import Testing

@testable import Aurelia

/// These windows are never ordered on screen or made key; no native fullscreen
/// transition, app focus, event injection, media or player engine is involved.
@MainActor
struct WindowChromeControlsTests {
  @Test func normalWindowUsesItsNativeButtonsAfterAChromeUpdate() throws {
    let window = makeWindow()
    let controls = AureliaWindowControls()
    defer { controls.detach() }
    for button in try buttons(in: window) { button.isHidden = true }
    controls.attach(to: window)
    #expect(try buttons(in: window).allSatisfy { !$0.isHidden })
    #expect(window.styleMask.contains(.titled))
    #expect(!window.isVisible)
  }

  @Test func fullscreenTransitionsLeaveButtonsToAppKitThenRestoreWindowedChrome() throws {
    let window = makeWindow()
    let controls = AureliaWindowControls()
    defer { controls.detach() }
    controls.attach(to: window)
    NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
    for button in try buttons(in: window) { button.isHidden = true }
    controls.attach(to: window)
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    #expect(try buttons(in: window).allSatisfy(\.isHidden))
    // Finish the simulated native lifecycle without entering fullscreen or showing a window.
    NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
    #expect(try buttons(in: window).allSatisfy { !$0.isHidden })
    #expect(!window.isVisible)
  }

  @Test func endingASheetRestoresButtonsAndDetachedWindowsReceiveNoMoreChanges() throws {
    let window = makeWindow()
    let controls = AureliaWindowControls()
    controls.attach(to: window)
    for button in try buttons(in: window) { button.isHidden = true }
    NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: window)
    #expect(try buttons(in: window).allSatisfy { !$0.isHidden })
    controls.detach()
    for button in try buttons(in: window) { button.isHidden = true }
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    #expect(try buttons(in: window).allSatisfy(\.isHidden))
  }

  @Test func playerRestorationNeverReplaysAStaleFullscreenMask() {
    let windowed: NSWindow.StyleMask = [.titled, .closable, .resizable, .fullSizeContentView]
    let fullscreen = windowed.union(.fullScreen)
    #expect(!AureliaWindowRestorePolicy.shouldExitFullScreen(original: windowed, current: windowed))
    #expect(
      AureliaWindowRestorePolicy.shouldExitFullScreen(original: windowed, current: fullscreen))
    #expect(
      !AureliaWindowRestorePolicy.shouldExitFullScreen(original: fullscreen, current: fullscreen))
    #expect(
      !AureliaWindowRestorePolicy.shouldExitFullScreen(original: fullscreen, current: windowed))
    #expect(
      AureliaWindowRestorePolicy.restoredStyle(original: fullscreen, current: windowed) == windowed)
    #expect(
      AureliaWindowRestorePolicy.restoredStyle(original: windowed, current: fullscreen)
        == fullscreen)
  }

  private func makeWindow() -> NSWindow {
    NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
  }

  private func buttons(in window: NSWindow) throws -> [NSButton] {
    try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map {
      try #require(window.standardWindowButton($0))
    }
  }
}
