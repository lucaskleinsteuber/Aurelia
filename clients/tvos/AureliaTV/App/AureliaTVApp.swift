import SwiftUI

@main
struct AureliaTVApp: App {
  @StateObject private var model = TVAppModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      TVRootView()
        .environmentObject(model)
        .preferredColorScheme(.dark)
        .task {
          await model.start()
          TVVideoEngine.warmUp()
        }
        .onChange(of: scenePhase) { _, phase in
          if phase == .background { model.enterBackground() }
          if phase == .active { model.enterForeground() }
        }
    }
  }
}
