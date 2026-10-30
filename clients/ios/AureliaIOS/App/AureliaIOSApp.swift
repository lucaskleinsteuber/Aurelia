import SwiftUI

@main
struct AureliaIOSApp: App {
  @StateObject private var model = IOSAppModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      IOSRootView()
        .environmentObject(model)
        .preferredColorScheme(.dark)
        // The Apple TV screens rely on focus instead of a tint; text stays white here as well.
        .tint(.white)
        .task {
          await model.start()
          IOSVideoEngine.warmUp()
        }
        .onChange(of: scenePhase) { _, phase in
          if phase == .background { model.enterBackground() }
          if phase == .active { model.enterForeground() }
        }
    }
  }
}
