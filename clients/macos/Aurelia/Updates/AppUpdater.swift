import AppKit
import Foundation
import OSLog

/// "Check for Updates…": asks GitHub for the newest release of the repository this app was
/// built from, downloads its disk image, checks it against the release's SHA256SUMS and hands
/// it to the server host helper, which (outside the sandbox) replaces only the app bundle
/// after this app quits and opens the new version. Library, settings and sign-ins stay.
@MainActor
final class AppUpdater: ObservableObject {
  enum State: Equatable {
    case idle
    case checking
    case upToDate
    case available(AppRelease)
    case downloading
    case installing
    case failed(String)
  }

  static let shared = AppUpdater()
  private static let logger = Logger(subsystem: "com.lucas.aurelia.media", category: "updates")
  private static let lastCheckKey = "AureliaLastUpdateCheck"

  @Published private(set) var state: State = .idle
  @Published private(set) var hasToken: Bool
  let tokens: AppUpdateTokenStore
  /// "owner/name" baked in by build-macos-release.sh; builds from Xcode have none.
  let repository: String?
  let currentVersion: String
  let currentBuild: Int
  private let client: AppUpdateClient

  init(
    tokens: AppUpdateTokenStore = AppUpdateTokenStore(), bundle: Bundle = .main,
    client: AppUpdateClient = AppUpdateClient()
  ) {
    self.tokens = tokens
    self.client = client
    let configured = bundle.object(forInfoDictionaryKey: "AureliaUpdateRepository") as? String
    repository = configured.flatMap { AppUpdateLogic.isRepository($0) ? $0 : nil }
    currentVersion =
      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    currentBuild = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    // Unit/preflight hosts must never read the installed user's update credential.
    hasToken = !AppModel.isTestProcess && tokens.load() != nil
  }

  var canCheck: Bool { repository != nil && hasToken }

  func saveToken(_ token: String) throws {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      try tokens.delete()
    } else {
      try tokens.save(trimmed)
    }
    hasToken = tokens.load() != nil
    if case .failed = state { state = .idle }
  }

  /// At launch, at most once a day and only with a token; it speaks up only when there is news.
  func checkInBackgroundIfDue(defaults: UserDefaults = .standard) {
    guard canCheck else { return }
    let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
    guard Date().timeIntervalSince(last) > 20 * 3_600 else { return }
    Task { await check(userInitiated: false) }
  }

  /// Looks for a newer release; a check the user asked for always answers.
  func check(userInitiated: Bool) async {
    guard state != .checking, state != .downloading, state != .installing else { return }
    guard let repository else {
      if userInitiated {
        alert(
          "Updates Need a Release Build",
          "This copy of Aurelia was not built for publishing, so it can't look for updates on GitHub."
        )
      }
      return
    }
    guard let token = tokens.load() else {
      if userInitiated { askForToken() }
      return
    }
    state = .checking
    do {
      let release = try await client.latest(repository: repository, token: token)
      UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
      if AppUpdateLogic.isNewer(build: release.build, than: currentBuild) {
        state = .available(release)
        offer(release)
      } else {
        state = .upToDate
        if userInitiated {
          alert(
            "Aurelia Is Up to Date",
            "You have the newest version, \(currentVersion) (\(currentBuild)).")
        }
      }
    } catch {
      let message =
        (error as? AppUpdateError)?.message
        ?? "GitHub couldn't be reached. Check the internet connection, then try again."
      state = .failed(message)
      Self.logger.error("Update check failed: \(message, privacy: .public)")
      if userInitiated { alert("Couldn't Check for Updates", message) }
    }
  }

  private func offer(_ release: AppRelease) {
    let alert = NSAlert()
    alert.messageText = "Aurelia \(release.version) Is Available"
    alert.informativeText =
      "You have \(currentVersion) (\(currentBuild)). Install \(release.version) (\(release.build)) now? Aurelia quits, updates and opens again; your library, settings and sign-ins stay."
    alert.addButton(withTitle: "Install and Restart")
    alert.addButton(withTitle: "Later")
    if release.pageURL != nil { alert.addButton(withTitle: "Release Notes") }
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      Task { await install(release) }
    case .alertThirdButtonReturn:
      if let page = release.pageURL { NSWorkspace.shared.open(page) }
    default:
      break
    }
  }

  /// Downloads and checks the release, then lets the helper replace the app after it quits.
  func install(_ release: AppRelease) async {
    guard state != .checking, state != .downloading, state != .installing else { return }
    guard let repository else { return }
    guard let token = tokens.load() else { return askForToken() }
    state = .downloading
    var downloadedImage: URL?
    do {
      let folder = try Self.updatesDirectory()
      let destination = try await client.download(
        release, repository: repository, token: token, currentBuild: currentBuild, folder: folder)
      downloadedImage = destination

      state = .installing
      let helper = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/Aurelia Server Host.app")
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = false
      configuration.createsNewApplicationInstance = true
      configuration.arguments = [
        "--install-update", destination.path, String(release.build), String(getpid()),
      ]
      _ = try await NSWorkspace.shared.openApplication(at: helper, configuration: configuration)
      Self.logger.notice("Installing Aurelia \(release.version, privacy: .public); quitting.")
      AppModel.active?.isPreparingApplicationUpdate = true
      NSApp.terminate(nil)
    } catch {
      if let downloadedImage {
        try? FileManager.default.removeItem(at: downloadedImage.deletingLastPathComponent())
      }
      let message =
        (error as? AppUpdateError)?.message
        ?? "The update installer couldn't be started. Try again."
      state = .failed(message)
      alert("Couldn't Install the Update", message)
    }
  }

  /// A folder the helper can read too: the App Group shared with it.
  static func updatesDirectory(fileManager: FileManager = .default) throws -> URL {
    guard
      let container = fileManager.containerURL(
        forSecurityApplicationGroupIdentifier: HostBootstrapLocation.appGroupIdentifier)
    else { throw AppUpdateError.noFolder }
    let folder = container.appendingPathComponent(
      "Library/Caches/Aurelia/Updates", isDirectory: true)
    do {
      try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    } catch { throw AppUpdateError.classify(error) }
    return folder
  }

  private func askForToken() {
    let alert = NSAlert()
    alert.messageText = "Add a GitHub Token"
    alert.informativeText =
      "Aurelia's releases are in a private GitHub repository. Add a read-only token under Settings › App › Updates, then check again."
    alert.addButton(withTitle: "Open Settings")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn {
      NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
  }

  private func alert(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.runModal()
  }

}
