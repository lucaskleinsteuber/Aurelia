import AppKit
import Foundation

/// A real, windowless AppKit event loop: no application data, server, player or UI.
@main
@MainActor
final class ApplicationTerminationTests: NSObject, NSApplicationDelegate {
  private let coordinator = ApplicationTerminationCoordinator()
  private var cleanupCount = 0
  private var cleanupFinished = false
  private var replies: [String] = []
  private let mode = CommandLine.arguments[1]
  private let receipt = URL(fileURLWithPath: CommandLine.arguments[2])

  static func main() {
    let app = NSApplication.shared
    let delegate = ApplicationTerminationTests()
    app.delegate = delegate
    app.setActivationPolicy(.prohibited)
    app.run()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if mode == "main-queue" {
      DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    } else {
      // The actual updater calls terminate from an executing MainActor Task.
      Task { @MainActor in
        await Task.yield()
        NSApplication.shared.terminate(nil)
      }
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let reply = coordinator.request(
      shutdown: { [self] in
        cleanupCount += 1
        if mode != "immediate" {
          // Quit again while cleanup is suspended: no duplicate cleanup or early exit.
          sender.terminate(nil)
          try? await Task.sleep(for: .milliseconds(30))
          await Task.yield()
        }
        cleanupFinished = true
      },
      terminate: { sender.terminate(nil) })
    replies.append(reply == .terminateNow ? "now" : reply == .terminateCancel ? "cancel" : "later")
    return reply
  }

  func applicationWillTerminate(_ notification: Notification) {
    let expected = mode == "immediate" ? ["cancel", "now"] : ["cancel", "cancel", "now"]
    guard cleanupCount == 1, cleanupFinished, replies == expected else { exit(2) }
    let result: [String: Any] = [
      "mode": mode, "cleanupCount": cleanupCount, "cleanupFinished": cleanupFinished,
      "replies": replies, "windows": NSApplication.shared.windows.count,
    ]
    do {
      try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: receipt)
    } catch { exit(3) }
  }
}
