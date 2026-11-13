import SwiftUI

@main
struct AureliaApp: App {
  @NSApplicationDelegateAdaptor(AureliaAppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()
  @Environment(\.scenePhase) private var scenePhase
  @FocusedObject private var player: PlaybackController?

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
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { model.isSettingsPresented = true }
          .keyboardShortcut(",", modifiers: .command)
      }
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") {
          Task { await AppUpdater.shared.check(userInitiated: true) }
        }
      }
      CommandMenu("Playback") {
        Button("Previous Episode") {
          guard EpisodeKeyboardPolicy.allowsMenu else { return }
          _ = player?.playPreviousFromSystemMedia()
        }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
        .disabled(player?.canPlayPrevious != true || !EpisodeKeyboardPolicy.allowsMenu)
        Button("Next Episode") {
          guard EpisodeKeyboardPolicy.allowsMenu else { return }
          _ = player?.playNextFromSystemMedia()
        }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
        .disabled(player?.canPlayNext != true || !EpisodeKeyboardPolicy.allowsMenu)
      }
      CommandGroup(after: .newItem) {
        Button("Add Media…") { model.showMediaManager() }
          .keyboardShortcut("o", modifiers: .command)
          .disabled(model.profile == nil || !model.canManageMedia)
      }
      CommandGroup(replacing: .help) {
        Button("Keyboard Shortcuts") {
          model.isKeyboardShortcutsPresented = true
        }
        .keyboardShortcut("/", modifiers: .command)
      }
    }
  }
}

/// Quitting when the window closes ends the connection, so a sleeping Linux server is not kept
/// awake by an app left running without a window.
enum WindowClosePreference {
  static let quitsKey = "AureliaQuitsWhenWindowCloses"

  static func quits(defaults: UserDefaults = .standard) -> Bool {
    // bool(forKey:) also reads "NO" and "YES" given as launch arguments.
    defaults.object(forKey: quitsKey) == nil ? true : defaults.bool(forKey: quitsKey)
  }
}

@MainActor
final class AureliaAppDelegate: NSObject, NSApplicationDelegate {
  private let termination = ApplicationTerminationCoordinator()

  func applicationDidFinishLaunching(_ notification: Notification) {
    WishNotificationCenter.shared.installDelegateIfNeeded {
      AppModel.active?.openWishes()
    }
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
    termination.request(
      shutdown: { await AppModel.active?.shutdown() },
      terminate: { sender.terminate(nil) })
  }
}
