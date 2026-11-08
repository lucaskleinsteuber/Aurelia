import AppKit
import SwiftUI

/// Settings › About: the version and what changed in it, the source code and the legal notes
/// (Aurelia Test also offers the introduction and the tour again).
struct AboutAureliaSections: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject private var updater = AppUpdater.shared
  @State private var confirmingReset = false
  @State private var shownLicense: MacLicense?

  static let repository = URL(string: "https://github.com/lucaskleinsteuber/Aurelia")!
  static let releases = URL(string: "https://github.com/lucaskleinsteuber/Aurelia/releases")!

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack(spacing: 16) {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable().frame(width: 64, height: 64)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(AppEdition.isTest ? "Aurelia Test for Mac" : "Aurelia for Mac")
            .font(.title2.weight(.semibold))
          Text("Version \(updater.currentVersion) (Build \(updater.currentBuild))")
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .accessibilityIdentifier("about-version")
        }
      }

      AureliaSettingsSection(
        "What's New in This Version", symbol: "list.bullet.rectangle",
        description: "The changes in version \(updater.currentVersion). Every version is in the release notes on GitHub."
      ) {
        VStack(alignment: .leading, spacing: 8) {
          if ReleaseNotes.current.isEmpty {
            Text("No notes for this version.").foregroundStyle(.secondary)
          }
          ForEach(Array(ReleaseNotes.current.enumerated()), id: \.offset) { _, change in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text("•").foregroundStyle(.secondary)
              Text(change).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }
          }
          Link("All Release Notes on GitHub", destination: Self.releases)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("about-whats-new")
      }

      // Seeing the introduction and tour again is for trying them out in the test edition; the
      // real app shows them once, at setup (as on iPhone, iPad and Apple TV).
      if AppEdition.isTest {
        AureliaSettingsSection(
          "Getting Started", symbol: "sparkles",
          description: "See again how Aurelia works, or take the short tour of the library."
        ) {
          HStack(spacing: 10) {
            Button("Show Introduction") {
              NotificationCenter.default.post(name: .aureliaShowIntroduction, object: nil)
            }
            .accessibilityIdentifier("about-show-introduction")
            Button("Show Tour") {
              model.setupGuide.requestTour()
              model.isSettingsPresented = false
            }
            .disabled(model.profile == nil || model.requiresProfileSelection)
            .accessibilityIdentifier("about-show-tour")
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      if AppEdition.isTest {
        AureliaSettingsSection(
          "Test Tools", symbol: "hammer.fill",
          description:
            "Only in Aurelia Test. Run the setup again and again without touching the real Aurelia app. Aurelia Test does not update itself."
        ) {
          Button("Reset App Data…", role: .destructive) { confirmingReset = true }
            .accessibilityIdentifier("test-reset-app-data")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
          "Erase Aurelia Test's data?", isPresented: $confirmingReset, titleVisibility: .visible
        ) {
          Button("Reset App Data", role: .destructive) {
            Task { await model.resetTestEditionData() }
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text(
            "Aurelia Test forgets its server, profile and settings, stops and erases its own test server, and opens again at the beginning. The real Aurelia app and your media stay untouched."
          )
        }
      }


      AureliaSettingsSection(
        "Source Code", symbol: "chevron.left.forwardslash.chevron.right",
        description:
          "Aurelia is open source. Its code, releases and full change history are on GitHub."
      ) {
        VStack(alignment: .leading, spacing: 8) {
          Text(Self.repository.absoluteString).font(.callout).textSelection(.enabled)
          Link("Open on GitHub", destination: Self.repository)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      AureliaSettingsSection("Legal", symbol: "doc.text") {
        VStack(alignment: .leading, spacing: 8) {
          Text("© 2026 Lucas Kleinsteuber. Released under the MIT License.")
          HStack(spacing: 10) {
            ForEach(MacLicense.all) { license in
              Button(license.title) { shownLicense = license }
            }
            if let others = MacLicense.otherNotices {
              Button("Other Components…") { NSWorkspace.shared.open(others) }
                .help("The licenses and notices of .NET, SQLite, SkiaSharp and the other parts of the server")
            }
          }
          .accessibilityIdentifier("about-licenses")
          Link("Privacy Policy", destination: URL(string: "https://github.com/lucaskleinsteuber/Aurelia/blob/main/docs/PRIVACY.md")!)
          Text(
            "Movie and series details and pictures can come from TMDB when the server's owner turns it on; subtitles can come from OpenSubtitles. This product uses the TMDB API but is not endorsed or certified by TMDB, and Aurelia is not endorsed by OpenSubtitles."
          )
          .font(.callout).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .sheet(item: $shownLicense) { license in MacLicenseSheet(license: license) }
  }
}

/// A license text the app carries, and where the license asks for one, the component's source.
struct MacLicense: Identifiable {
  let title: String
  let file: URL
  let source: URL?
  var id: String { title }

  static var all: [MacLicense] {
    let resources = Bundle.main.resourceURL
    return [
      resources.map { MacLicense(title: "Aurelia (MIT)", file: $0.appendingPathComponent("LICENSE"), source: nil) },
      resources.map {
        MacLicense(
          title: "VLCKit (LGPL)", file: $0.appendingPathComponent("VLCKit-COPYING.txt"),
          source: URL(string: "https://code.videolan.org/videolan/VLCKit"))
      },
      resources.map {
        MacLicense(
          title: "FFmpeg (LGPL)", file: $0.appendingPathComponent("Server/ffmpeg/COPYING.LGPLv2.1"),
          source: URL(string: "https://ffmpeg.org/legal.html"))
      },
    ].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.file.path) }
  }

  /// The notices of .NET, SQLite, SkiaSharp and the server's other packages, one folder each.
  static var otherNotices: URL? {
    guard let folder = Bundle.main.resourceURL?.appendingPathComponent("ThirdPartyNotices"),
      FileManager.default.fileExists(atPath: folder.path)
    else { return nil }
    return folder
  }
}

private struct MacLicenseSheet: View {
  let license: MacLicense
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(license.title).font(.title2.weight(.semibold))
        Spacer()
        if let source = license.source { Link("Source Code", destination: source) }
      }
      ScrollView {
        Text((try? String(contentsOf: license.file, encoding: .utf8)) ?? "The license text is missing from this build.")
          .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(22)
    .frame(width: 720, height: 600)
  }
}

/// Settings › Profiles and Devices: the signed-in profile changes the name everyone sees and its
/// picture. An owner keeps signing in with the original name.
struct OwnProfileEditor: View {
  @EnvironmentObject private var model: AppModel
  let user: UserSummary
  @State private var name: String
  @State private var pictureKey: String?
  @State private var photo: Data?
  @State private var working = false
  @State private var message: String?
  @State private var failed = false

  init(user: UserSummary) {
    self.user = user
    _name = State(initialValue: user.shownName)
    _pictureKey = State(initialValue: user.pictureKey)
  }

  private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var changed: Bool {
    trimmed != user.shownName || pictureKey != user.pictureKey || photo != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Name and Picture").font(.headline)
      TextField("Your Name", text: $name).textFieldStyle(.roundedBorder)
        .frame(maxWidth: 320)
        .accessibilityIdentifier("own-profile-name")
      Text("The name everyone sees on every device.")
        .font(.caption).foregroundStyle(.secondary)
      ProfilePicturePicker(
        id: user.id, name: trimmed, pictureRevision: user.pictureRevision, key: $pictureKey,
        photo: $photo)
      HStack(spacing: 10) {
        Button(working ? "Saving…" : "Save Name and Picture") { save() }
          .disabled(!changed || working || !(1...40).contains(trimmed.count))
          .accessibilityIdentifier("own-profile-save")
        if let message {
          Text(message).font(.caption).foregroundStyle(failed ? .orange : .secondary)
        }
      }
    }
  }

  private func save() {
    guard let profile = model.profile else { return }
    let client = APIClient(profile: profile)
    let rename = trimmed != user.shownName ? trimmed : nil
    let upload = pictureKey == ProfilePictureCatalog.photoKey ? photo : nil
    let pictureChanged = pictureKey != user.pictureKey || photo != nil
    let builtin = pictureKey == ProfilePictureCatalog.photoKey ? nil : pictureKey
    working = true
    message = nil
    Task {
      defer { working = false }
      do {
        var updated: UserSummary?
        if let rename { updated = try await client.renameOwnProfile(rename) }
        if pictureChanged {
          if let upload {
            updated = try await client.uploadOwnPhoto(upload)
            if let updated, let image = NSImage(data: upload) {
              ProfilePhotoCache.shared.store(
                image, data: upload, id: updated.id, revision: updated.pictureRevision)
            }
          } else {
            updated = try await client.setOwnPicture(builtin: builtin)
          }
        }
        if let updated { model.updateProfileUser(updated) }
        photo = nil
        failed = false
        message = "Saved."
      } catch {
        failed = true
        message = error.localizedDescription
      }
    }
  }
}
