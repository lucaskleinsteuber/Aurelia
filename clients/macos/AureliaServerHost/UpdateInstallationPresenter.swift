import AppKit
import Foundation

/// macOS can terminate an invisible installer after its launching app exits.
/// A visible native progress window and menu-bar item explain and retain this work.
@MainActor
final class UpdateInstallationPresenter: NSObject, NSApplicationDelegate {
  private let operation: @Sendable () -> UpdateInstaller.WorkerResult
  private var window: NSWindow?
  private var statusItem: NSStatusItem?
  private var finishing = false

  private init(operation: @escaping @Sendable () -> UpdateInstaller.WorkerResult) {
    self.operation = operation
  }

  static func run(operation: @escaping @Sendable () -> UpdateInstaller.WorkerResult) {
    let app = NSApplication.shared
    let delegate = UpdateInstallationPresenter(operation: operation)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 166))
    let heading = NSTextField(labelWithString: "Updating Aurelia")
    heading.font = .systemFont(ofSize: 19, weight: .semibold)
    heading.alignment = .center
    heading.frame = NSRect(x: 24, y: 114, width: 332, height: 26)
    let detail = NSTextField(
      wrappingLabelWithString: "Aurelia opens again when the update finishes.")
    detail.textColor = .secondaryLabelColor
    detail.alignment = .center
    detail.frame = NSRect(x: 24, y: 58, width: 332, height: 42)
    let progress = NSProgressIndicator(frame: NSRect(x: 24, y: 30, width: 332, height: 12))
    progress.style = .bar
    progress.isIndeterminate = true
    progress.startAnimation(nil)
    for view in [heading, detail, progress] { content.addSubview(view) }
    let window = NSWindow(
      contentRect: content.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Aurelia Update"
    window.isReleasedWhenClosed = false
    window.contentView = content
    window.center()
    self.window = window

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "arrow.down.circle", accessibilityDescription: "Updating Aurelia")
    item.button?.toolTip = "Updating Aurelia"
    let menu = NSMenu()
    let title = NSMenuItem(title: "Updating Aurelia…", action: nil, keyEquivalent: "")
    title.isEnabled = false
    menu.addItem(title)
    let show = NSMenuItem(
      title: "Show Update Progress", action: #selector(showProgress), keyEquivalent: "")
    show.target = self
    menu.addItem(show)
    item.menu = menu
    statusItem = item

    showProgress()
    window.displayIfNeeded()
    // Publish visible UI before the background operation claims/acknowledges
    // its request. The calling app may exit as soon as that acknowledgement lands.
    Self.start(operation: operation) { [self] result in finish(result) }
  }

  @objc private func showProgress() {
    window?.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    finishing ? .terminateNow : .terminateCancel
  }

  private func finish(_ result: UpdateInstaller.WorkerResult) {
    if case .failed(let app, let message) = result {
      UpdateInstaller.presentWorkerFailure(app: app, message: message)
    }
    finishing = true
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    window?.close()
    NSApplication.shared.terminate(nil)
  }

  nonisolated private static func start(
    operation: @escaping @Sendable () -> UpdateInstaller.WorkerResult,
    completion: @escaping @MainActor @Sendable (UpdateInstaller.WorkerResult) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let result = operation()
      Task { @MainActor in completion(result) }
    }
  }
}
