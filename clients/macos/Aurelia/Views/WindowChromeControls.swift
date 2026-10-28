import AppKit

/// Restores AppKit's own controls after native title-bar transitions. Fullscreen
/// title bars remain under system control, including their reveal-on-hover behavior.
@MainActor
final class AureliaWindowControls {
  private weak var window: NSWindow?
  private var observers: [NSObjectProtocol] = []
  private var isTransitioning = false

  isolated deinit { detach() }

  func attach(to window: NSWindow) {
    if self.window !== window {
      detach()
      self.window = window
      for name in [
        NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
        NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
        NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification,
        NSWindow.didEndSheetNotification,
      ] {
        observers.append(
          NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
            @Sendable [weak self] notification in
            let name = notification.name
            MainActor.assumeIsolated { self?.windowChanged(name) }
          })
      }
    }
    revealIfWindowed()
  }

  func detach() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    window = nil
    isTransitioning = false
  }

  private func windowChanged(_ name: Notification.Name) {
    switch name {
    case NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification:
      isTransitioning = true
    case NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification:
      isTransitioning = false
    default:
      break
    }
    revealIfWindowed()
  }

  private func revealIfWindowed() {
    guard let window, !isTransitioning, !window.styleMask.contains(.fullScreen) else { return }
    Self.revealIfWindowed(window)
  }

  static func revealIfWindowed(_ window: NSWindow) {
    guard !window.styleMask.contains(.fullScreen) else { return }
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      window.standardWindowButton(kind)?.isHidden = false
    }
  }
}

/// AppKit owns the fullscreen bit and frame. A snapshot taken inside fullscreen
/// must never reintroduce that bit after a later native exit.
enum AureliaWindowRestorePolicy {
  static func shouldExitFullScreen(
    original: NSWindow.StyleMask?, current: NSWindow.StyleMask
  ) -> Bool {
    current.contains(.fullScreen) && original?.contains(.fullScreen) != true
  }

  static func restoredStyle(
    original: NSWindow.StyleMask, current: NSWindow.StyleMask
  ) -> NSWindow.StyleMask {
    original.subtracting(.fullScreen).union(current.intersection(.fullScreen))
  }
}
