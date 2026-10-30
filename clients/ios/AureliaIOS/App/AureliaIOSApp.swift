import SwiftUI

@main
struct AureliaIOSApp: App {
  @StateObject private var model = IOSAppModel()

  var body: some Scene {
    WindowGroup {
      IOSRootView(model: model)
        .preferredColorScheme(.dark)
    }
  }
}
