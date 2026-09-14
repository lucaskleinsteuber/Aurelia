import SwiftUI

@main
struct AureliaApp: App {
  @NSApplicationDelegateAdaptor(AureliaAppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(model)
        .task {
          await model.start()
        }
    }
    .defaultSize(width: 1_470, height: 956)
    .windowStyle(.hiddenTitleBar)
    .commands {
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

@MainActor
final class AureliaAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.activate()
    Task {
      await AppModel.active?.start()
    }
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

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      await AppModel.active?.shutdown()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
