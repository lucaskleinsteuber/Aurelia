import Foundation
@preconcurrency import UserNotifications

/// Bridges `UNUserNotificationCenterDelegate` callbacks from arbitrary system dispatch queues
/// onto `MainActor` per `docs/SYSTEM_CALLBACKS.md`.
final class WishNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
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

  /// Accepts an activation callback from any background queue and hops to `MainActor`.
  nonisolated func handleNotificationActivation(
    categoryIdentifier: String,
    completion: @escaping @Sendable () -> Void
  ) {
    guard categoryIdentifier == WishNotificationCenter.categoryIdentifier else {
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
protocol WishNotificationDelivering: AnyObject {
  func authorizationStatus() async -> UNAuthorizationStatus
  func requestAuthorization() async -> Bool
  func post(identifier: String, title: String, body: String) async
}

@MainActor
final class SystemWishNotificationDeliverer: WishNotificationDelivering {
  private var delegate: WishNotificationDelegate?

  static var isAvailableInCurrentProcess: Bool {
    let env = ProcessInfo.processInfo.environment
    return Bundle.main.bundleURL.pathExtension == "app"
      && env["XCTestConfigurationFilePath"] == nil
      && env["AURELIA_RUNNING_TESTS"] != "1"
      && env["AURELIA_UI_TEST_MODE"] == nil
  }

  func installDelegate(onOpenWishes: @escaping @MainActor @Sendable () -> Void) {
    guard Self.isAvailableInCurrentProcess else { return }
    let created = WishNotificationDelegate(onOpenWishes: onOpenWishes)
    self.delegate = created
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
    content.categoryIdentifier = WishNotificationCenter.categoryIdentifier
    let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    try? await UNUserNotificationCenter.current().add(request)
  }
}

@MainActor
final class WishNotificationCenter {
  nonisolated static let categoryIdentifier = "aurelia.wishes"
  static let shared = WishNotificationCenter()

  private let defaults: UserDefaults
  private let systemDeliverer = SystemWishNotificationDeliverer()
  private let deliverer: any WishNotificationDelivering

  init(
    defaults: UserDefaults = .standard,
    deliverer: (any WishNotificationDelivering)? = nil
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
      if defaults.object(forKey: GeneralPreferenceKeys.wishNotificationsEnabled) == nil {
        return true
      }
      return defaults.bool(forKey: GeneralPreferenceKeys.wishNotificationsEnabled)
    }
    set {
      defaults.set(newValue, forKey: GeneralPreferenceKeys.wishNotificationsEnabled)
    }
  }

  func installDelegateIfNeeded(onOpenWishes: @escaping @MainActor @Sendable () -> Void) {
    guard deliverer === systemDeliverer else { return }
    systemDeliverer.installDelegate(onOpenWishes: onOpenWishes)
  }

  func requestPermissionOnFirstVisitIfNeeded() async {
    guard isEnabledInSettings else { return }
    guard !defaults.bool(forKey: GeneralPreferenceKeys.wishNotificationsPrompted) else { return }
    defaults.set(true, forKey: GeneralPreferenceKeys.wishNotificationsPrompted)
    let current = await deliverer.authorizationStatus()
    guard current == .notDetermined else { return }
    _ = await deliverer.requestAuthorization()
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    await deliverer.authorizationStatus()
  }

  func notify(_ event: WishNotificationEvent) async {
    guard isEnabledInSettings else { return }
    let id = "aurelia-wish-\(event.kind)-\(UUID().uuidString)"
    await deliverer.post(identifier: id, title: event.title, body: event.body)
  }
}
