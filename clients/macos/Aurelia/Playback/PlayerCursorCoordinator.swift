import AppKit
import Combine

/// Owns exactly one cursor hide claim, scoped to one player lifetime. Focus
/// changes disarm hiding until physical pointer movement inside that player.
@MainActor
final class PlayerCursorCoordinator: ObservableObject {
  private let hideAction: @MainActor @Sendable () -> Void
  private let unhideAction: @MainActor @Sendable () -> Void
  private(set) var ownsHideClaim = false
  private(set) var isRetired = false
  private var active = false
  private var keyWindow = false
  private var pointerInside = false
  private var movedSinceActivation = false

  init(
    hide: @escaping @MainActor @Sendable () -> Void = { NSCursor.hide() },
    unhide: @escaping @MainActor @Sendable () -> Void = { NSCursor.unhide() }
  ) {
    hideAction = hide
    unhideAction = unhide
  }

  isolated deinit { show() }

  func environment(active: Bool, keyWindow: Bool) {
    self.active = active
    self.keyWindow = keyWindow
    if !active || !keyWindow { show(disarm: true) }
  }

  func pointer(inside: Bool, physicallyMoved: Bool) {
    pointerInside = inside
    if !inside {
      show(disarm: true)
    } else if physicallyMoved && active && keyWindow && !isRetired {
      movedSinceActivation = true
    }
  }

  func hideIfPermitted(playing: Bool, blocked: Bool) {
    guard !isRetired, !ownsHideClaim, active, keyWindow, pointerInside,
      movedSinceActivation, playing, !blocked
    else { return }
    hideAction()
    ownsHideClaim = true
  }

  func show(disarm: Bool = false) {
    if disarm { movedSinceActivation = false }
    guard ownsHideClaim else { return }
    ownsHideClaim = false
    unhideAction()
  }

  func retire() {
    isRetired = true
    show(disarm: true)
  }
}
