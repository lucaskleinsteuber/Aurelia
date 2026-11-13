import Foundation
@preconcurrency import UserNotifications

/// Bridges `UNUserNotificationCenterDelegate` callbacks from arbitrary system dispatch queues
/// onto `MainActor` per `docs/SYSTEM_CALLBACKS.md`.
final class IOSWishNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
  private let onOpenWishes: @MainActor @Sendable () -> Void

  nonisolated init(onOpenWishes: @escaping @MainActor @Sendable () -> Void) {
    self.onOpenWishes = onOpenWishes
    super.init()
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let category = response.notification.request.content.categoryIdentifier
    handleNotificationActivation(categoryIdentifier: category) {}
    completionHandler()
  }

  nonisolated func handleNotificationActivation(
    categoryIdentifier: String,
    completion: @escaping @Sendable () -> Void
  ) {
    guard categoryIdentifier == IOSWishNotificationCenter.categoryIdentifier else {
      completion()
      return
    }
    let open = onOpenWishes
    Task { @MainActor in
      open()
      completion()
    }
  }
}

@MainActor
protocol IOSWishNotificationDelivering: AnyObject {
  func authorizationStatus() async -> UNAuthorizationStatus
  func requestAuthorization() async -> Bool
  func post(identifier: String, title: String, body: String) async
}

@MainActor
final class SystemIOSWishNotificationDeliverer: IOSWishNotificationDelivering {
  private var delegate: IOSWishNotificationDelegate?

  static var isAvailableInCurrentProcess: Bool {
    let env = ProcessInfo.processInfo.environment
    return Bundle.main.bundleURL.pathExtension == "app"
      && env["XCTestConfigurationFilePath"] == nil
      && env["AURELIA_RUNNING_TESTS"] != "1"
      && !ProcessInfo.processInfo.arguments.contains("--aurelia-ui-testing")
  }

  func installDelegate(onOpenWishes: @escaping @MainActor @Sendable () -> Void) {
    guard Self.isAvailableInCurrentProcess else { return }
    let created = IOSWishNotificationDelegate(onOpenWishes: onOpenWishes)
    delegate = created
    UNUserNotificationCenter.current().delegate = created
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    guard Self.isAvailableInCurrentProcess else { return .notDetermined }
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    return settings.authorizationStatus
  }

  func requestAuthorization() async -> Bool {
    guard Self.isAvailableInCurrentProcess else { return false }
    do {
      return try await UNUserNotificationCenter.current().requestAuthorization(options: [
        .alert, .sound,
      ])
    } catch {
      return false
    }
  }

  func post(identifier: String, title: String, body: String) async {
    guard Self.isAvailableInCurrentProcess else { return }
    let status = await authorizationStatus()
    guard status == .authorized || status == .provisional else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.categoryIdentifier = IOSWishNotificationCenter.categoryIdentifier
    let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    try? await UNUserNotificationCenter.current().add(request)
  }
}

@MainActor
final class IOSWishNotificationCenter {
  nonisolated static let categoryIdentifier = "aurelia.ios.wishes"
  static let shared = IOSWishNotificationCenter()

  private let defaults: UserDefaults
  private let systemDeliverer = SystemIOSWishNotificationDeliverer()
  private let deliverer: any IOSWishNotificationDelivering

  init(
    defaults: UserDefaults = .standard,
    deliverer: (any IOSWishNotificationDelivering)? = nil
  ) {
    self.defaults = defaults
    if let deliverer {
      self.deliverer = deliverer
    } else {
      self.deliverer = systemDeliverer
    }
  }

  var isEnabledInSettings: Bool {
    get {
      if defaults.object(forKey: IOSWishPreferenceKeys.wishNotificationsEnabled) == nil {
        return true
      }
      return defaults.bool(forKey: IOSWishPreferenceKeys.wishNotificationsEnabled)
    }
    set {
      defaults.set(newValue, forKey: IOSWishPreferenceKeys.wishNotificationsEnabled)
    }
  }

  func installDelegateIfNeeded(onOpenWishes: @escaping @MainActor @Sendable () -> Void) {
    guard deliverer === systemDeliverer else { return }
    systemDeliverer.installDelegate(onOpenWishes: onOpenWishes)
  }

  func requestPermissionOnFirstVisitIfNeeded() async {
    guard isEnabledInSettings else { return }
    guard !defaults.bool(forKey: IOSWishPreferenceKeys.wishNotificationsPrompted) else { return }
    defaults.set(true, forKey: IOSWishPreferenceKeys.wishNotificationsPrompted)
    let current = await deliverer.authorizationStatus()
    guard current == .notDetermined else { return }
    _ = await deliverer.requestAuthorization()
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    await deliverer.authorizationStatus()
  }

  func notify(_ event: IOSWishNotificationEvent) async {
    guard isEnabledInSettings else { return }
    let id = "aurelia-wish-\(event.kind)-\(UUID().uuidString)"
    await deliverer.post(identifier: id, title: event.title, body: event.body)
  }
}
