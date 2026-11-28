import AppKit
import Foundation

/// Aurelia's new name is Tarven. Tarven is a new app with its own identifier, so the updater can't
/// install it in Aurelia's place: the person installs it once from its release page. This version
/// prepares that move.
/// - It keeps a copy of its settings in its App Group, which Tarven reads once on its first start.
///   Sign-ins come along through the shared Keychain group, and the Mac's own server folder is
///   moved by Tarven's server helper.
/// - Once Tarven has a Mac release, the update check says so instead of looking for Aurelia updates.
enum TarvenHandover {
  static let repository = "lucaskleinsteuber/Tarven"
  /// Only the real app's feed asks for Tarven; builds and tests with another feed never do.
  static let previousRepository = "lucaskleinsteuber/Aurelia"
  static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
  static let releasesURL = URL(
    string: "https://api.github.com/repos/\(repository)/releases?per_page=20")!

  /// Where Tarven looks for the settings, inside Aurelia's App Group.
  static func folder(groupContainer: URL) -> URL {
    groupContainer.appendingPathComponent(
      "Library/Application Support/Tarven Handover", isDirectory: true)
  }

  static let preferencesFileName = "preferences.plist"

  /// Writes this app's own settings (its persistent defaults domain) for Tarven. Nothing is
  /// written by the test edition, and nothing when the settings did not change.
  @discardableResult
  static func exportPreferences(
    defaults: UserDefaults = .standard,
    domain: String = AppEdition.bundleIdentifier,
    groupContainer: URL? = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: AppEdition.appGroup),
    isTest: Bool = AppEdition.isTest
  ) -> URL? {
    guard !isTest, let groupContainer,
      let settings = defaults.persistentDomain(forName: domain), !settings.isEmpty,
      let data = try? PropertyListSerialization.data(
        fromPropertyList: settings, format: .binary, options: 0)
    else { return nil }
    let directory = folder(groupContainer: groupContainer)
    let file = directory.appendingPathComponent(preferencesFileName)
    if (try? Data(contentsOf: file)) == data { return file }
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try data.write(to: file, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      return file
    } catch {
      return nil
    }
  }

  /// The page of the newest Tarven release that has a Mac disk image, or nil.
  static func macReleasePage(fromList data: Data) -> URL? {
    guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return nil }
    for release in releases {
      guard release["draft"] as? Bool != true,
        let page = (release["html_url"] as? String).flatMap(URL.init(string:)),
        page.scheme == "https", page.host == "github.com",
        page.path.hasPrefix("/\(repository)/releases/"),
        let assets = release["assets"] as? [[String: Any]],
        assets.contains(where: { isMacDiskImage($0["name"] as? String) })
      else { continue }
      return page
    }
    return nil
  }

  static func isMacDiskImage(_ name: String?) -> Bool {
    guard let name else { return false }
    return name.range(
      of: #"\ATarven-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-macOS-(arm64|x64)\.dmg\z"#,
      options: .regularExpression) != nil
  }

  /// Asks GitHub anonymously whether Tarven has a Mac release; nil before the first one.
  static func releasePage(session: URLSession = .shared) async -> URL? {
    var request = URLRequest(url: releasesURL, timeoutInterval: 20)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    guard let (data, response) = try? await session.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200,
      response.url?.host == "api.github.com"
    else { return nil }
    return macReleasePage(fromList: data)
  }

  static let noticeTitle = "Aurelia Is Now Tarven"
  static let noticeMessage =
    "Aurelia has a new name. Download Tarven, quit Aurelia and open Tarven from Applications: it takes over your server connection, your settings and this Mac's server. Afterwards move Aurelia to the Trash. Aurelia itself gets no more updates."

  @MainActor
  static func announce(_ page: URL) {
    let alert = NSAlert()
    alert.messageText = noticeTitle
    alert.informativeText = noticeMessage
    alert.addButton(withTitle: "Download Tarven")
    alert.addButton(withTitle: "Later")
    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
  }
}
