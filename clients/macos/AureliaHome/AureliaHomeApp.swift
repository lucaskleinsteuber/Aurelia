import SwiftUI

@main
struct AureliaHomeApp: App {
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
