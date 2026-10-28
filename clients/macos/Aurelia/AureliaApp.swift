import SwiftUI

@main
struct AureliaApp: App {
  @NSApplicationDelegateAdaptor(AureliaAppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(model)
        .task {
          await model.start()
          VLCPlaybackEngine.warmUp()
        }
        .onChange(of: scenePhase) { _, phase in
          Task { await model.setApplicationActive(phase == .active) }
        }
        .onReceive(
          NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
        ) { _ in
          Task { await model.systemWillSleep() }
        }
        .onReceive(
          NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
        ) { _ in
          Task { await model.systemDidWake() }
        }
    }
    .defaultSize(width: 1_470, height: 956)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") {
          Task { await AppUpdater.shared.check(userInitiated: true) }
        }
      }
      CommandGroup(after: .newItem) {
        Button("Add Media…") { model.showMediaManager() }
          .keyboardShortcut("o", modifiers: .command)
          .disabled(model.profile == nil || !model.canManageMedia)
      }
    }

    Settings {
      AppSettingsView()
        .environmentObject(model)
    }
  }
}

/// Quitting when the window closes ends the connection, so a sleeping Linux server is not kept
/// awake by an app left running without a window.
enum WindowClosePreference {
  static let quitsKey = "AureliaQuitsWhenWindowCloses"

  static func quits(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: quitsKey) as? Bool ?? true
  }
}

@MainActor
final class AureliaAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.activate()
    Task {
      await AppModel.active?.start()
    }
    AppUpdater.shared.checkInBackgroundIfDue()
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    guard !flag else { return true }
    sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    sender.activate()
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    WindowClosePreference.quits()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      await AppModel.active?.shutdown()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
