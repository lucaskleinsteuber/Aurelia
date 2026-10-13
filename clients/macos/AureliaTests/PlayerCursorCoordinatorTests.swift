import Testing

@testable import Aurelia

@MainActor
struct PlayerCursorCoordinatorTests {
  @Test func claimsAreBalancedAndDoNotUnhideOtherOwners() {
    let system = CursorProbe()
    let cursor = system.coordinator()
    cursor.show()
    #expect(system.unhides == 0)
    cursor.environment(active: true, keyWindow: true)
    cursor.pointer(inside: true, physicallyMoved: true)
    cursor.hideIfPermitted(playing: true, blocked: false)
    cursor.hideIfPermitted(playing: true, blocked: false)
    #expect(system.hides == 1)
    cursor.show()
    cursor.show()
    #expect(system.unhides == 1)
  }

  @Test func errorsPreparationPauseAndOutsidePointerCannotHide() {
    let system = CursorProbe()
    let cursor = system.coordinator()
    cursor.environment(active: true, keyWindow: true)
    cursor.pointer(inside: true, physicallyMoved: false)
    cursor.hideIfPermitted(playing: true, blocked: false)
    cursor.pointer(inside: true, physicallyMoved: true)
    cursor.hideIfPermitted(playing: false, blocked: false)
    cursor.hideIfPermitted(playing: true, blocked: true)
    cursor.pointer(inside: false, physicallyMoved: true)
    cursor.hideIfPermitted(playing: true, blocked: false)
    #expect(system.hides == 0)
  }

  @Test func focusLossReleasesClaimAndReturnRequiresPhysicalMotion() {
    let system = CursorProbe()
    let cursor = system.coordinator()
    cursor.environment(active: true, keyWindow: true)
    cursor.pointer(inside: true, physicallyMoved: true)
    cursor.hideIfPermitted(playing: true, blocked: false)
    cursor.environment(active: false, keyWindow: false)
    #expect(system.unhides == 1)
    cursor.environment(active: true, keyWindow: true)
    cursor.pointer(inside: true, physicallyMoved: false)
    cursor.hideIfPermitted(playing: true, blocked: false)
    #expect(system.hides == 1)
    cursor.pointer(inside: true, physicallyMoved: true)
    cursor.hideIfPermitted(playing: true, blocked: false)
    #expect(system.hides == 2)
    cursor.retire()
    #expect(system.unhides == 2)
  }

  @Test func closingQuarantinesLateHideAndInteractionCallbacks() {
    let system = CursorProbe()
    let cursor = system.coordinator()
    cursor.environment(active: true, keyWindow: true)
    cursor.pointer(inside: true, physicallyMoved: true)
    cursor.hideIfPermitted(playing: true, blocked: false)
    cursor.retire()
    cursor.environment(active: true, keyWindow: true)
    cursor.pointer(inside: true, physicallyMoved: true)
    cursor.hideIfPermitted(playing: true, blocked: false)
    cursor.retire()
    #expect(system.hides == 1 && system.unhides == 1)
  }

  @Test func destructionReleasesAnOwnedClaim() {
    let system = CursorProbe()
    var cursor: PlayerCursorCoordinator? = system.coordinator()
    cursor?.environment(active: true, keyWindow: true)
    cursor?.pointer(inside: true, physicallyMoved: true)
    cursor?.hideIfPermitted(playing: true, blocked: false)
    cursor = nil
    #expect(system.hides == 1 && system.unhides == 1)
  }
}

@MainActor
private final class CursorProbe {
  var hides = 0
  var unhides = 0
  func coordinator() -> PlayerCursorCoordinator {
    PlayerCursorCoordinator(hide: { self.hides += 1 }, unhide: { self.unhides += 1 })
  }
}
