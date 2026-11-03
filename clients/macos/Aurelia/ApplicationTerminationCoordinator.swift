import AppKit

/// Finish asynchronous cleanup before entering AppKit's synchronous termination path.
/// Returning terminateLater from a Swift concurrency task makes AppKit spin a nested
/// run loop while that task still owns the main executor, starving the cleanup task.
@MainActor
final class ApplicationTerminationCoordinator {
  private var isShuttingDown = false
  private var isReadyToTerminate = false

  func request(
    shutdown: @escaping @MainActor () async -> Void,
    terminate: @escaping @MainActor () -> Void
  ) -> NSApplication.TerminateReply {
    if isReadyToTerminate { return .terminateNow }
    guard !isShuttingDown else { return .terminateCancel }
    isShuttingDown = true
    Task { @MainActor in
      await shutdown()
      isReadyToTerminate = true
      terminate()
    }
    // Let the original terminate() call return, releasing the main executor.
    // The second request is accepted only after every cleanup await completes.
    return .terminateCancel
  }
}
