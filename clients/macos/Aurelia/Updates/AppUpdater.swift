import AppKit
import CryptoKit
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

  init(tokens: AppUpdateTokenStore = AppUpdateTokenStore(), bundle: Bundle = .main) {
    self.tokens = tokens
    let configured = bundle.object(forInfoDictionaryKey: "AureliaUpdateRepository") as? String
    repository = configured.flatMap { AppUpdateLogic.isRepository($0) ? $0 : nil }
    currentVersion =
      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    currentBuild = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    hasToken = tokens.load() != nil
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
      var request = URLRequest(
        url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      request.timeoutInterval = 20
      let (data, response) = try await URLSession.shared.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard status == 200 else { throw UpdateError.github(status) }
      UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
      guard let release = AppUpdateLogic.release(fromLatest: data) else {
        throw UpdateError.noDiskImage
      }
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
        (error as? UpdateError)?.message
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
    guard let token = tokens.load() else { return askForToken() }
    state = .downloading
    do {
      let folder = try Self.updatesDirectory()
      let sums = try await download(release.checksumsURL, token: token)
      guard
        let expected = AppUpdateLogic.checksum(
          for: release.diskImageName, in: String(decoding: sums, as: UTF8.self))
      else { throw UpdateError.noChecksum }
      let image = try await download(release.diskImageURL, token: token)
      let actual = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
      guard actual == expected else { throw UpdateError.checksumMismatch }
      let destination = folder.appendingPathComponent(release.diskImageName)
      try? FileManager.default.removeItem(at: destination)
      try image.write(to: destination, options: .atomic)

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
      NSApp.terminate(nil)
    } catch {
      let message =
        (error as? UpdateError)?.message ?? "The update couldn't be downloaded. Try again."
      state = .failed(message)
      alert("Couldn't Install the Update", message)
    }
  }

  private func download(_ url: URL, token: String) async throws -> Data {
    // GitHub's API serves a private release's file as a redirect to storage; the token is sent
    // only to GitHub and dropped on the redirect.
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 120
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw UpdateError.github(status) }
    return data
  }

  /// A folder the helper can read too: the App Group shared with it.
  static func updatesDirectory(fileManager: FileManager = .default) throws -> URL {
    guard
      let container = fileManager.containerURL(
        forSecurityApplicationGroupIdentifier: HostBootstrapLocation.appGroupIdentifier)
    else { throw UpdateError.noFolder }
    let folder = container.appendingPathComponent(
      "Library/Caches/Aurelia/Updates", isDirectory: true)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
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

  enum UpdateError: Error {
    case github(Int)
    case noDiskImage
    case noChecksum
    case checksumMismatch
    case noFolder

    var message: String {
      switch self {
      case .github(401), .github(403):
        "GitHub didn't accept the token. Check it under Settings › App › Updates."
      case .github(404):
        "GitHub has no release here yet, or the token can't read this repository."
      case .github(let status):
        "GitHub answered with an error (\(status)). Try again later."
      case .noDiskImage:
        "The newest release has no Mac disk image."
      case .noChecksum:
        "The newest release has no checksum for its disk image."
      case .checksumMismatch:
        "The downloaded disk image doesn't match its published checksum, so it wasn't installed."
      case .noFolder:
        "Aurelia couldn't prepare a folder for the download."
      }
    }
  }
}
