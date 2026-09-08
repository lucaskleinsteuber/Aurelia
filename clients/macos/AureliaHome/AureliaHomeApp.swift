import SwiftUI

@main
struct AureliaHomeApp: App {
  @NSApplicationDelegateAdaptor(AureliaHomeAppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(model)
        .task {
          await model.start()
        }
    }
    .defaultSize(width: 1_120, height: 720)
    .windowToolbarStyle(.unifiedCompact)

    Settings {
      AppSettingsView()
        .environmentObject(model)
    }
  }
}

@MainActor
final class AureliaHomeAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.activate()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      await AppModel.active?.shutdown()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
