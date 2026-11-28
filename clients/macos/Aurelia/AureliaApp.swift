import SwiftUI

@main
struct AureliaApp: App {
  @NSApplicationDelegateAdaptor(AureliaAppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()
  @StateObject private var securityAlerts = SecurityAlertCenter()
  @Environment(\.scenePhase) private var scenePhase
  @FocusedObject private var player: PlaybackController?

  /// Restarts the security watch when the server, profile or its features change.
  private var securityAlertKey: String {
    [
      model.profile?.serverId.uuidString, model.profile?.user?.id.uuidString,
      model.profile?.isViewingSession == true ? "viewing" : "device",
      model.libraryCapabilities.contains("security-v1") ? "security" : "",
    ].compactMap { $0 }.joined(separator: "|")
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(model)
        .overlay(alignment: .top) { SecurityAlertBanner(center: securityAlerts) }
        .task(id: securityAlertKey) { securityAlerts.start(model: model) }
        .task {
          await model.start()
          #if DEBUG
            if AuditRenderFixture.enabled { return }
          #endif
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
          AppUpdater.shared.checkInBackgroundIfDue()
        }
    }
    .defaultSize(width: 1_470, height: 956)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { model.isSettingsPresented = true }
          .keyboardShortcut(",", modifiers: .command)
          .disabled(!AppMenuCommandPolicy.canOpenSettings(isOfflineMode: model.offlineMode != nil))
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
          .disabled(
            !AppMenuCommandPolicy.canAddMedia(
              hasProfile: model.profile != nil,
              canManageMedia: model.canManageMedia,
              isPlaying: model.playback != nil,
              isInWrapped: model.wrappedLaunch != nil,
              isOfflineMode: model.offlineMode != nil))
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

/// Menu bar command gating so shortcuts either act visibly or stay disabled.
enum AppMenuCommandPolicy {
  static func canOpenSettings(isOfflineMode: Bool) -> Bool {
    !isOfflineMode
  }

  static func canAddMedia(
    hasProfile: Bool,
    canManageMedia: Bool,
    isPlaying: Bool,
    isInWrapped: Bool,
    isOfflineMode: Bool
  ) -> Bool {
    hasProfile && canManageMedia && !isPlaying && !isInWrapped && !isOfflineMode
  }

  static func settingsCoversFullWindowOverlay(
    isPlaying: Bool,
    isInWrapped: Bool
  ) -> Bool {
    isPlaying || isInWrapped
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
  private var powerOffObserver: NSObjectProtocol?
  private var updateCheckTimer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    #if DEBUG
      // Offscreen screen renders stay in the background: no activation, window or update check.
      if AuditRenderFixture.enabled {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { await AppModel.active?.start() }
        return
      }
    #endif
    powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willPowerOffNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.termination.markSystemPowerOff() }
    }
    WishNotificationCenter.shared.installDelegateIfNeeded {
      AppModel.active?.openWishes()
    }
    NSApplication.shared.activate()
    // Kept current for Tarven, Aurelia's new name, which takes the settings over once.
    TarvenHandover.exportPreferences()
    AppUpdater.shared.checkInBackgroundIfDue()
    let timer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { _ in
      Task { @MainActor in
        TarvenHandover.exportPreferences()
        AppUpdater.shared.checkInBackgroundIfDue()
      }
    }
    timer.tolerance = 300
    updateCheckTimer = timer
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
    #if DEBUG
      // The renderer hides every window it does not draw into; it ends the process itself.
      if AuditRenderFixture.enabled { return false }
    #endif
    return WindowClosePreference.quits()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    #if DEBUG
      if AuditRenderFixture.enabled { return .terminateCancel }
    #endif
    return termination.request(
      shutdown: { await AppModel.active?.shutdown() },
      terminate: { sender.terminate(nil) },
      reply: { sender.reply(toApplicationShouldTerminate: $0) })
  }
}
