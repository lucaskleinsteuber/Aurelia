import SwiftUI
import UIKit

/// Downloads go on in the background; the system wakes Aurelia when a file is complete.
final class IOSAppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    guard identifier == IOSOfflineDownloader.identifier else {
      completionHandler()
      return
    }
    // Touching the store reconnects to the transfers, whose events then arrive.
    IOSOfflineStore.shared.backgroundCompletion = completionHandler
  }
}

@main
struct AureliaIOSApp: App {
  @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var appDelegate
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
          let appModel = model
          IOSWishNotificationCenter.shared.installDelegateIfNeeded { [weak appModel] in
            appModel?.openWishesFromNotification()
          }
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
