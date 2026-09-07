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
        .frame(width: 480, height: 280)
    }
  }
}

@MainActor
final class AureliaHomeAppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard PlaybackShutdownCoordinator.shared.hasActivePlayback else {
      return .terminateNow
    }
    Task {
      await PlaybackShutdownCoordinator.shared.shutdown()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
