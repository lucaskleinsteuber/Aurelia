import AppKit

/// Finish asynchronous cleanup before entering AppKit's synchronous termination path.
/// Returning terminateLater from a Swift concurrency task makes AppKit spin a nested
/// run loop while that task still owns the main executor, starving the cleanup task.
/// System logout, restart and shutdown arrive directly from loginwindow on the main run
/// loop (never from an in-process Swift Task) and must return terminateLater so macOS
/// does not cancel the user's logout or restart.
@MainActor
final class ApplicationTerminationCoordinator {
  private var isShuttingDown = false
  private var isReadyToTerminate = false
  private var systemPowerOffNotified = false
  private var pendingSystemReply: (@MainActor (Bool) -> Void)?

  // CoreServices/AE FourCharCode constants (avoids pulling in Carbon).
  private static let quitReasonKeyword: AEKeyword = 0x7768_793F  // 'why?' (kAEQuitReason)
  private static let systemQuitReasons: Set<OSType> = [
    0x6C67_6F74,  // 'lgot' (kAELogOut)
    0x726C_676F,  // 'rlgo' (kAEReallyLogOut)
    0x7273_7461,  // 'rsta' (kAERestart)
    0x7368_7574,  // 'shut' (kAEShutDown)
    0x7264_6C67,  // 'rdlg' (kAEShowRestartDialog)
    0x7364_6C67,  // 'sdlg' (kAEShowShutdownDialog)
  ]

  static func isSystemPowerAppleEvent(
    _ event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent
  ) -> Bool {
    guard let reason = event?.attributeDescriptor(forKeyword: quitReasonKeyword) else {
      return false
    }
    return systemQuitReasons.contains(reason.typeCodeValue)
  }

  func markSystemPowerOff() {
    systemPowerOffNotified = true
  }

  func request(
    isSystemPowerEvent: Bool = false,
    shutdown: @escaping @MainActor () async -> Void,
    terminate: @escaping @MainActor () -> Void,
    reply: @escaping @MainActor (Bool) -> Void = {
      NSApplication.shared.reply(toApplicationShouldTerminate: $0)
    }
  ) -> NSApplication.TerminateReply {
    if isReadyToTerminate { return .terminateNow }
    let systemPower =
      isSystemPowerEvent || systemPowerOffNotified || Self.isSystemPowerAppleEvent()
    if isShuttingDown {
      if systemPower {
        pendingSystemReply = reply
        return .terminateLater
      }
      return .terminateCancel
    }
    isShuttingDown = true
    if systemPower {
      pendingSystemReply = reply
    }
    Task { @MainActor in
      await shutdown()
      isReadyToTerminate = true
      if let pending = pendingSystemReply {
        pendingSystemReply = nil
        pending(true)
      } else {
        terminate()
      }
    }
    if systemPower {
      return .terminateLater
    }
    // Let the original terminate() call return, releasing the main executor.
    // The second request is accepted only after every cleanup await completes.
    return .terminateCancel
  }
}
