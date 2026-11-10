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

  @Published private(set) var state: State = .idle
  /// The release being downloaded or installed, and how far its download is.
  @Published private(set) var installingRelease: AppRelease?
  @Published private(set) var progress: AppUpdateProgress?
  private var installTask: Task<Void, Never>?
  /// "owner/name" baked in by build-macos-release.sh; builds from Xcode have none.
  let repository: String?
  let currentVersion: String
  let currentBuild: Int
  private let client: AppUpdateClient
  private let defaults: UserDefaults

  init(
    bundle: Bundle = .main,
    client: AppUpdateClient = AppUpdateClient(), defaults: UserDefaults = .standard
  ) {
    self.client = client
    self.defaults = defaults
    let configured = bundle.object(forInfoDictionaryKey: "AureliaUpdateRepository") as? String
    // Aurelia Test never updates itself: an update would install the real app.
    repository =
      AppEdition.isTest ? nil : configured.flatMap { AppUpdateLogic.isRepository($0) ? $0 : nil }
    AppUpdateSource.retirePublicTest(in: defaults)
    currentVersion =
      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    currentBuild = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    if let root = MacUpdateInstallRequest.updatesDirectory(),
      let outcome = MacUpdateInstallRequest.status(in: root), outcome.phase == "failed",
      outcome.build > currentBuild
    {
      state = .failed(outcome.message ?? "The previous update could not be completed. Try again.")
    }
  }

  var canCheck: Bool { repository != nil }

  var isBusy: Bool { state == .checking || state == .downloading || state == .installing }

  /// Starts downloading and installing `release` and shows its progress window.
  func startInstall(_ release: AppRelease) {
    guard !isBusy else {
      showProgress()
      return
    }
    installTask = Task { await install(release) }
  }

  /// Stops the download; nothing is installed and the offer stays in Settings.
  func cancelInstall() {
    guard state == .downloading else { return }
    installTask?.cancel()
  }

  /// Brings the "Updating Aurelia" window back while an update downloads or installs.
  func showProgress() {
    guard state == .downloading || state == .installing else { return }
    AppUpdateProgressWindow.shared.show(updater: self)
  }

  /// At launch, at most once a day; it speaks up only when there is news.
  func checkInBackgroundIfDue() {
    guard canCheck, AppUpdatePreferences.backgroundCheckIsDue(in: defaults, repository: repository)
    else { return }
    Task { await check(userInitiated: false) }
  }

  /// Looks for a newer release; a check the user asked for always answers.
  func check(userInitiated: Bool) async {
    // Asking again while an update downloads shows how far it is instead of doing nothing.
    if userInitiated { showProgress() }
    guard !isBusy else { return }
    guard userInitiated || AppUpdatePreferences.checksAutomatically(in: defaults) else { return }
    guard let repository else {
      if userInitiated {
        alert(
          "Updates Need a Release Build",
          "This copy of Aurelia was not built for publishing, so it can't look for updates on GitHub."
        )
      }
      return
    }
    state = .checking
    do {
      let beta = AppUpdatePreferences.betaUpdates(in: defaults)
      let result = try await client.catalog(
        repository: repository,
        cached: AppUpdateCatalogCache.load(repository: repository, beta: beta, defaults: defaults),
        beta: beta)
      let release = result.release
      AppUpdateCatalogCache.save(
        result.cache, repository: repository, beta: beta, defaults: defaults)
      defaults.set(Date(), forKey: AppUpdatePreferences.checkKey(repository))
      if AppUpdateLogic.isNewer(release, version: currentVersion, build: currentBuild) {
        state = .available(release)
        // Re-read choices after the request: Settings may have changed while it was in flight.
        if AppUpdatePreferences.shouldOffer(
          version: release.version, userInitiated: userInitiated, defaults: defaults)
        {
          offer(release)
        }
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
    alert.messageText =
      release.isBeta
      ? "Aurelia \(release.version) Beta Is Available"
      : "Aurelia \(release.version) Is Available"
    alert.informativeText =
      "Aurelia will reopen after installing the update. \(AppUpdateLogic.downloadSizeText(release.downloadBytes))"
    alert.addButton(withTitle: "Install and Restart")
    alert.addButton(withTitle: "Later")
    alert.addButton(withTitle: "Skip This Version")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      startInstall(release)
    case .alertThirdButtonReturn:
      AppUpdatePreferences.skip(version: release.version, in: defaults)
    default:
      break
    }
  }

  /// Downloads and checks the release, then lets the helper replace the app after it quits.
  func install(_ release: AppRelease) async {
    guard !isBusy else { return }
    guard let repository else { return }
    installingRelease = release
    progress = AppUpdateProgress(received: 0, expected: release.downloadBytes)
    state = .downloading
    AppUpdateProgressWindow.shared.show(updater: self)
    var downloadedImage: URL?
    var pendingRequest: MacUpdateInstallRequest?
    do {
      let folder = try Self.updatesDirectory()
      let size = release.downloadBytes
      let destination = try await client.download(
        release, repository: repository, currentBuild: currentBuild, folder: folder,
        progress: { received, expected in
          Task { @MainActor in
            AppUpdater.shared.reportDownload(received: received, expected: expected ?? size)
          }
        })
      downloadedImage = destination
      try Task.checkCancellation()

      state = .installing
      let helper = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/Aurelia Server Host.app")
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      configuration.createsNewApplicationInstance = true
      let request = try MacUpdateInstallRequest.prepare(
        image: destination, build: release.build, appPID: getpid(), root: folder)
      try request.save(in: folder)
      pendingRequest = request
      _ = try await NSWorkspace.shared.openApplication(at: helper, configuration: configuration)
      // NSWorkspace ignores arguments from a sandboxed caller. Do not quit until
      // the same-team helper has acknowledged this exact validated request.
      try await request.waitForAcknowledgement(in: folder)
      Self.logger.notice("Installing Aurelia \(release.version, privacy: .public); quitting.")
      AppModel.active?.isPreparingApplicationUpdate = true
      NSApp.terminate(nil)
    } catch {
      if let pendingRequest, let root = MacUpdateInstallRequest.updatesDirectory() {
        let path = root.appendingPathComponent(MacUpdateInstallRequest.pendingName)
        if let data = try? Data(contentsOf: path),
          let saved = try? JSONDecoder().decode(MacUpdateInstallRequest.self, from: data),
          saved.id == pendingRequest.id
        {
          try? FileManager.default.removeItem(at: path)
        }
      }
      if let downloadedImage {
        try? FileManager.default.removeItem(at: downloadedImage.deletingLastPathComponent())
      }
      AppUpdateProgressWindow.shared.close()
      progress = nil
      installingRelease = nil
      // Cancel was pressed: the download is gone and the update is still on offer.
      if Task.isCancelled || error is CancellationError {
        state = .available(release)
        return
      }
      let message =
        (error as? AppUpdateError)?.message
        ?? "The update installer did not acknowledge the request. Aurelia has stayed open; try again."
      state = .failed(message)
      alert("Couldn't Install the Update", message)
    }
  }

  /// A later report never moves the bar backwards; reports after the download are ignored.
  private func reportDownload(received: Int64, expected: Int64?) {
    guard state == .downloading, received >= progress?.received ?? 0 else { return }
    progress = AppUpdateProgress(received: received, expected: expected)
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

  private func alert(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.runModal()
  }

}
