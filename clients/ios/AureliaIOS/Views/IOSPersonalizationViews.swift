import PhotosUI
import SwiftUI
import UIKit

/// Profile photos, loaded once per picture revision with this device's credential, so the
/// picker shows them before a profile is unlocked.
@MainActor
final class IOSProfilePhotoCache: ObservableObject {
  static let shared = IOSProfilePhotoCache()

  @Published private var images: [String: UIImage] = [:]
  private var loading: Set<String> = []
  var loader: (@MainActor (UUID, Int64) async throws -> Data)?

  func image(id: UUID, revision: Int64) -> UIImage? { images[Self.key(id, revision)] }

  func load(id: UUID, revision: Int64) {
    let key = Self.key(id, revision)
    guard images[key] == nil, !loading.contains(key), let loader else { return }
    loading.insert(key)
    Task {
      defer { loading.remove(key) }
      guard let data = try? await loader(id, revision), let image = UIImage(data: data) else {
        return
      }
      images[key] = image
    }
  }

  func store(_ image: UIImage, id: UUID, revision: Int64) { images[Self.key(id, revision)] = image }

  private static func key(_ id: UUID, _ revision: Int64) -> String {
    "\(id.uuidString)-\(revision)"
  }
}

/// A built-in picture's symbol in white.
struct IOSProfileSymbol: View {
  let symbol: String
  let size: CGFloat

  var body: some View {
    Group {
      if symbol == "rocket" {
        IOSRocketShape().fill(.white, style: FillStyle(eoFill: true))
          .frame(width: size * 0.5, height: size * 0.5)
      } else {
        Image(systemName: IOSProfilePictures.systemImage(for: symbol))
          .font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
      }
    }
    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
  }
}

/// The rocket of the built-in pictures, on the same 24-point grid as the other clients.
struct IOSRocketShape: Shape {
  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / 24
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
    }
    var path = Path()
    path.move(to: point(12, 2))
    path.addCurve(to: point(16.5, 13), control1: point(15.5, 4.5), control2: point(17, 8.5))
    path.addLine(to: point(18.5, 16))
    path.addLine(to: point(16.5, 19))
    path.addLine(to: point(15, 16.5))
    path.addLine(to: point(9, 16.5))
    path.addLine(to: point(7.5, 19))
    path.addLine(to: point(5.5, 16))
    path.addLine(to: point(7.5, 13))
    path.addCurve(to: point(12, 2), control1: point(7, 8.5), control2: point(8.5, 4.5))
    path.closeSubpath()
    path.addEllipse(
      in: CGRect(origin: point(10.2, 7.2), size: CGSize(width: 3.6 * scale, height: 3.6 * scale)))
    path.move(to: point(10, 17.6))
    path.addLine(to: point(14, 17.6))
    path.addLine(to: point(12, 22))
    path.closeSubpath()
    return path
  }
}

/// Settings › Name and Picture: the name everyone sees and the profile's picture, a built-in one
/// or a photo. An owner keeps signing in with the original name.
struct IOSNameAndPictureView: View {
  @EnvironmentObject private var model: IOSAppModel
  @State private var name = ""
  @State private var pictureKey: String?
  @State private var palette = "blue"
  @State private var photo: Data?
  @State private var preview: UIImage?
  @State private var photoItem: PhotosPickerItem?
  @State private var cropping: IOSCroppingPhoto?
  @State private var working = false
  @State private var message: String?
  @State private var failed = false

  private var user: IOSUser? { model.session?.user }
  private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var selectedBuiltin: (symbol: String, palette: String)? {
    IOSProfilePictures.parse(pictureKey)
  }
  private var changed: Bool {
    guard let user else { return false }
    return trimmed != user.shownName || pictureKey != user.pictureKey || photo != nil
  }

  var body: some View {
    List {
      Section {
        HStack {
          Spacer()
          Group {
            if let preview {
              Image(uiImage: preview).resizable().scaledToFill()
                .frame(width: 110, height: 110).clipShape(Circle())
            } else {
              IOSProfilePicture(
                id: user?.id, name: trimmed.isEmpty ? "?" : trimmed, size: 110,
                pictureKey: pictureKey, pictureRevision: user?.pictureRevision ?? 0)
            }
          }
          Spacer()
        }
        .listRowBackground(Color.clear)
      }
      Section {
        TextField("Your Name", text: $name)
          .textInputAutocapitalization(.words)
          .submitLabel(.done)
          .accessibilityIdentifier("own-profile-name")
      } header: {
        Text("Name")
      } footer: {
        Text("The name everyone sees on every device.")
      }
      Section("Picture") {
        Text("Symbol").font(.caption).foregroundStyle(.secondary)
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 44, maximum: 52), spacing: 8)],
          alignment: .leading, spacing: 8
        ) {
          ForEach(IOSProfilePictures.symbols, id: \.self) { symbol in
            let candidate = IOSProfilePictures.builtin(symbol: symbol, palette: palette)
            let selected = selectedBuiltin?.symbol == symbol
            let spokenPalette = selected ? (selectedBuiltin?.palette ?? palette) : palette
            Button {
              pictureKey = candidate
              photo = nil
              preview = nil
            } label: {
              let colors = IOSProfilePicture.namedPalette(palette)
              Circle()
                .fill(
                  LinearGradient(colors: [colors.0, colors.1], startPoint: .top, endPoint: .bottom)
                )
                .overlay { IOSProfileSymbol(symbol: symbol, size: 40) }
                .overlay {
                  Circle().strokeBorder(
                    selected ? Color.white : .clear, lineWidth: 2)
                }
                .frame(width: 40, height: 40)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(symbol.capitalized) picture")
            .accessibilityValue("\(spokenPalette.capitalized) color")
            .accessibilityAddTraits(selected ? .isSelected : [])
          }
        }
        .padding(.vertical, 6)
        Text("Color").font(.caption).foregroundStyle(.secondary)
        if let builtin = selectedBuiltin {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 44, maximum: 52), spacing: 8)],
            alignment: .leading, spacing: 8
          ) {
            ForEach(IOSProfilePictures.palettes, id: \.self) { candidate in
              let selected = builtin.palette == candidate
              Button {
                guard let actual = selectedBuiltin else { return }
                palette = candidate
                pictureKey = IOSProfilePictures.builtin(symbol: actual.symbol, palette: candidate)
              } label: {
                let colors = IOSProfilePicture.namedPalette(candidate)
                Circle()
                  .fill(
                    LinearGradient(
                      colors: [colors.0, colors.1], startPoint: .top, endPoint: .bottom)
                  )
                  .overlay {
                    Circle().strokeBorder(selected ? Color.white : .clear, lineWidth: 2)
                  }
                  .frame(width: 28, height: 28)
                  .frame(maxWidth: .infinity, minHeight: 44)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityLabel("\(candidate.capitalized) color")
              .accessibilityValue("\(builtin.symbol.capitalized) picture")
              .accessibilityAddTraits(selected ? .isSelected : [])
            }
          }
          .padding(.vertical, 4)
        } else {
          Text("Choose a symbol to use a color.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        PhotosPicker(selection: $photoItem, matching: .images) {
          Label("Choose Photo", systemImage: "photo")
        }
        Button("Use Initial") {
          pictureKey = nil
          photo = nil
          preview = nil
        }
        .accessibilityAddTraits(pictureKey == nil ? .isSelected : [])
      }
      Section {
        Button(working ? "Saving…" : "Save") { save() }
          .disabled(!changed || working || !(1...40).contains(trimmed.count))
          .accessibilityIdentifier("own-profile-save")
      } footer: {
        if let message {
          Text(message).foregroundStyle(failed ? .orange : .secondary)
        }
      }
    }
    .scrollDismissesKeyboard(.interactively)
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle("Name and Picture")
    .onAppear {
      guard let user else { return }
      name = user.shownName
      pictureKey = user.pictureKey
      if let builtin = IOSProfilePictures.parse(user.pictureKey) { palette = builtin.palette }
    }
    .onChange(of: photoItem) { _, item in
      guard let item else { return }
      photoItem = nil
      Task {
        guard let data = try? await item.loadTransferable(type: Data.self),
          let image = IOSPhotoCrop.uprightImage(data)
        else {
          failed = true
          message = "This photo could not be read."
          return
        }
        // The photo is cropped to a square before anything is uploaded.
        cropping = IOSCroppingPhoto(image: image)
      }
    }
    .sheet(item: $cropping) { candidate in
      IOSPhotoCropSheet(image: candidate.image) { prepared in
        cropping = nil
        guard let prepared, let image = UIImage(data: prepared) else { return }
        photo = prepared
        preview = image
        pictureKey = IOSProfilePictures.photoKey
        message = nil
      }
    }
  }

  private func save() {
    guard let client = model.client, let user else { return }
    let rename = trimmed != user.shownName ? trimmed : nil
    let upload = pictureKey == IOSProfilePictures.photoKey ? photo : nil
    let pictureChanged = pictureKey != user.pictureKey || photo != nil
    let builtin = pictureKey == IOSProfilePictures.photoKey ? nil : pictureKey
    working = true
    message = nil
    Task {
      defer { working = false }
      do {
        var updated: IOSUser?
        if let rename { updated = try await client.renameProfile(rename) }
        if pictureChanged {
          if let upload {
            updated = try await client.uploadPhoto(upload)
            if let updated, let image = UIImage(data: upload) {
              IOSProfilePhotoCache.shared.store(
                image, id: updated.id, revision: updated.pictureRevision ?? 0)
            }
          } else {
            updated = try await client.setPicture(builtin: builtin)
          }
        }
        if let updated { model.updateProfileUser(updated) }
        photo = nil
        preview = nil
        failed = false
        message = "Saved."
      } catch {
        failed = true
        message = error.localizedDescription
      }
    }
  }
}

/// Settings › About Aurelia: the version, the source and the legal notes (in the test edition also
/// the introduction and tour again).
struct IOSAboutView: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.dismiss) private var dismiss
  static let repository = URL(string: "https://github.com/lucaskleinsteuber/Aurelia")!

  private var version: String {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    return "Version \(short ?? "") (Build \(build ?? ""))"
  }

  var body: some View {
    List {
      Section {
        VStack(spacing: 8) {
          Image(systemName: "play.rectangle.fill").font(.system(size: 44))
            .foregroundStyle(.white.opacity(0.85))
          Text("Aurelia for iPhone and iPad").font(.headline)
          Text(version).font(.subheadline).foregroundStyle(.secondary)
            .accessibilityIdentifier("about-version")
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .listRowBackground(Color.clear)
      }
      // Seeing the introduction and tour again is for trying them out in the test edition; the
      // real app shows them once, at setup.
      if IOSTestEdition.isActive {
        Section {
          Button("Show Introduction") {
            NotificationCenter.default.post(name: .iosShowIntroduction, object: nil)
          }
          Button("Show Tour") {
            model.setupGuide.requestTour()
            dismiss()
          }
        } header: {
          Text("Getting Started")
        } footer: {
          Text("See again how Aurelia works, or take the short tour of the app.")
        }
      }
      Section {
        Link("Open on GitHub", destination: Self.repository)
      } header: {
        Text("Source Code")
      } footer: {
        Text("Aurelia is open source. Its code, releases and full change history are on GitHub.")
      }
      Section {
        Text("© 2026 Lucas Kleinsteuber")
        NavigationLink("Aurelia License (MIT)") {
          IOSLicenseView(title: "Aurelia", resource: "LICENSE", source: nil)
        }
        NavigationLink("MobileVLCKit (LGPL 2.1 or later)") {
          IOSLicenseView(
            title: "MobileVLCKit", resource: "MobileVLCKit-COPYING.txt",
            source: URL(string: "https://code.videolan.org/videolan/VLCKit"))
        }
        Link(
          "Privacy Policy",
          destination: URL(
            string: "https://github.com/lucaskleinsteuber/Aurelia/blob/main/docs/PRIVACY.md")!)
      } header: {
        Text("Legal")
      } footer: {
        Text(
          "Movie and series details and pictures can come from TMDB when the server's owner turns it on; subtitles can come from OpenSubtitles. This product uses the TMDB API but is not endorsed or certified by TMDB, and Aurelia is not endorsed by OpenSubtitles."
        )
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle("About Aurelia")
  }
}

/// A license text bundled with the app, in full, with a link to the source where the license asks for one.
private struct IOSLicenseView: View {
  let title: String
  let resource: String
  let source: URL?

  private var text: String {
    guard let url = Bundle.main.url(forResource: resource, withExtension: nil),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return "The license text is missing from this build." }
    return text
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let source {
          Link(destination: source) {
            Label("Source Code of \(title)", systemImage: "arrow.up.right.square")
          }
        }
        Text(text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
      }
      .padding(IOSDesign.margin)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
  }
}

extension Notification.Name {
  static let iosShowIntroduction = Notification.Name("AureliaIOSShowIntroduction")
}

/// The setup assistant's start: "Connect to My Server" or "I'm New to Aurelia". New users learn how
/// Aurelia works, then "Do you have an Aurelia server?". Without one, a short guide with a QR code
/// to the download page and a way back to that question.
struct IOSSetupIntroductionView: View {
  enum Page { case welcome, howItWorks, server, noServer }

  @EnvironmentObject private var model: IOSAppModel
  @ObservedObject var guide: IOSSetupGuide
  var replay = false
  var closed: (() -> Void)? = nil
  @State private var page: Page = .welcome
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    IOSCenteredScrollView {
      VStack(spacing: 26) {
        switch page {
        case .welcome: welcome
        case .howItWorks: howItWorks
        case .server: server
        case .noServer: noServer
        }
      }
      .id(page)
      .transition(.opacity)
      .padding(.horizontal, IOSDesign.margin).padding(.vertical, 40)
      .frame(maxWidth: 560)
    }
    .background(IOSDesign.canvas.ignoresSafeArea())
    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: page)
    .onAppear { if replay { page = .howItWorks } }
    .accessibilityIdentifier("setup-introduction")
  }

  private var welcome: some View {
    VStack(spacing: 24) {
      Image(systemName: "play.rectangle.fill").font(.system(size: 56))
        .foregroundStyle(.white.opacity(0.85))
        .accessibilityHidden(true)
      heading(
        "Welcome to Aurelia",
        "Your movies and shows from your own server, on this iPhone or iPad. New here? A few steps set everything up."
      )
      VStack(spacing: 12) {
        Button("Connect to My Server") { guide.start() }
          .buttonStyle(IOSButtonStyle(kind: .primary, fullWidth: true))
          .accessibilityIdentifier("setup-connect")
        Button("I'm New to Aurelia") { page = .howItWorks }
          .buttonStyle(IOSButtonStyle(kind: .secondary, fullWidth: true))
          .accessibilityIdentifier("setup-show-me-around")
      }
    }
  }

  private var howItWorks: some View {
    VStack(spacing: 24) {
      heading(
        "How Aurelia Works", "One computer serves your library. Everything else just watches.")
      VStack(spacing: 14) {
        station("externaldrive.fill", "Your Files", "Movies and shows stay where they are.")
        station("server.rack", "Aurelia Server", "Runs on a Mac or Linux computer at home.")
        station(
          IOSDesign.isPad ? "ipad" : "iphone", "This Device",
          "Plays from the server on your home network.")
      }
      Button(replay ? "Done" : "Continue") {
        if replay { closed?() } else { page = .server }
      }
      .buttonStyle(IOSButtonStyle(kind: .primary, fullWidth: true))
      .accessibilityIdentifier("setup-continue")
      if !replay {
        Button("Back") { page = .welcome }
          .tint(.white.opacity(0.8))
          .frame(minHeight: 44)
          .contentShape(Rectangle())
      }
    }
  }

  private var server: some View {
    VStack(spacing: 24) {
      heading(
        "Do You Have an Aurelia Server?",
        "It runs in Aurelia on a Mac, or on a Linux computer at home.")
      VStack(spacing: 12) {
        Button("Yes, Connect to It") { guide.start() }
          .buttonStyle(IOSButtonStyle(kind: .primary, fullWidth: true))
          .accessibilityIdentifier("setup-has-server")
        Button("Not Yet") { page = .noServer }
          .buttonStyle(IOSButtonStyle(kind: .secondary, fullWidth: true))
          .accessibilityIdentifier("setup-no-server")
      }
      Button("Back") { page = .howItWorks }
        .tint(.white.opacity(0.8))
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
  }

  private var noServer: some View {
    VStack(spacing: 22) {
      heading(
        "Set Up a Server First",
        "Install Aurelia on the Mac or Linux computer whose drives hold your movies and shows, and choose to use it as the server."
      )
      if let image = IOSQRCode.image(for: IOSQRCode.downloadPage.absoluteString) {
        Image(image, scale: 1, label: Text("QR code for the Aurelia download page"))
          .interpolation(.none).resizable().scaledToFit()
          .frame(width: 180, height: 180)
          .padding(14)
          .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      }
      Text("Scan this with the computer's camera, or open the download page on GitHub.")
        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
      Link(destination: IOSAboutView.repository) {
        Label("Open Aurelia on GitHub", systemImage: "arrow.up.right.square")
      }
      .buttonStyle(IOSButtonStyle(kind: .primary, fullWidth: true))
      .accessibilityIdentifier("setup-no-server-github")
      Text("When the server runs, go back and choose Yes, Connect to It.")
        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
      Button("Back") { page = .server }
        .tint(.white.opacity(0.8))
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityIdentifier("setup-no-server-back")
    }
  }

  private func heading(_ title: String, _ detail: String) -> some View {
    VStack(spacing: 8) {
      Text(title).font(.title.bold()).multilineTextAlignment(.center)
      Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
  }

  private func station(_ symbol: String, _ title: String, _ detail: String) -> some View {
    HStack(spacing: 14) {
      Image(systemName: symbol).font(.title2)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(width: 52, height: 52)
        .background(IOSDesign.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline)
        Text(detail).font(.subheadline).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

/// The guided connection's progress at the top of each screen.
struct IOSSetupStepBar: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let current: IOSSetupStep

  var body: some View {
    let steps = IOSSetupStep.allCases
    let index = steps.firstIndex(of: current) ?? 0
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        Text("Step \(index + 1) of \(steps.count): \(current.title)")
          .font(.footnote.weight(.semibold))
          .multilineTextAlignment(.center)
      } else {
        HStack(spacing: 8) {
          ForEach(Array(steps.enumerated()), id: \.element) { position, step in
            HStack(spacing: 4) {
              ZStack {
                Circle().fill(position <= index ? Color.accentColor : Color.white.opacity(0.2))
                if position < index {
                  Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                } else {
                  Text("\(position + 1)").font(.system(size: 10, weight: .semibold))
                }
              }
              .foregroundStyle(.white).frame(width: 18, height: 18)
              if position == index {
                Text(step.title).font(.caption.weight(.semibold))
              }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(step.title), step \(position + 1) of \(steps.count)")
          }
        }
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 7)
    .background {
      if reduceTransparency {
        Capsule().fill(IOSDesign.surface)
      } else {
        Capsule().fill(.ultraThinMaterial)
      }
    }
    .padding(.horizontal, 16)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("setup-step-bar")
  }
}

/// "You're All Set" after the guided connection, then the tour.
struct IOSSetupDoneView: View {
  @EnvironmentObject private var model: IOSAppModel
  @ObservedObject var guide: IOSSetupGuide

  var body: some View {
    IOSSetupScrollView {
      VStack(spacing: 24) {
        Spacer()
        Image(systemName: "checkmark").font(.system(size: 48, weight: .semibold))
          .foregroundStyle(Color.accentColor)
        VStack(spacing: 8) {
          Text("You're All Set").font(.largeTitle.bold())
          Text("Here is what Aurelia set up with you.").font(.subheadline).foregroundStyle(
            .secondary)
        }
        VStack(alignment: .leading, spacing: 12) {
          check("This device is connected to \(model.connection?.name ?? "your server").")
          if let user = model.session?.user {
            check("You watch as \(user.shownName).")
          }
          check("Progress, favorites and your watchlist follow you to every device.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(IOSDesign.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        Spacer()
        Button("Start Watching") { guide.finish() }
          .buttonStyle(IOSButtonStyle(kind: .primary, fullWidth: true))
          .accessibilityIdentifier("setup-start-watching")
      }
    }
    .background(IOSDesign.canvas.ignoresSafeArea())
    .accessibilityIdentifier("setup-done")
  }

  private func check(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
      Text(text).fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// The tour after setup: it opens each tab in turn and explains it in a short note.
struct IOSLibraryTour: View {
  struct Stop: Equatable {
    let tab: Int
    let title: String
    let text: String
  }

  static let stops: [Stop] = [
    Stop(
      tab: 0, title: "Home",
      text: "Continue Watching, new titles and your favorites. Tap a poster to see its details."),
    Stop(
      tab: 1, title: "Movies and TV Shows",
      text: "Your whole library, sorted and filterable. Hold a poster for more actions."),
    Stop(tab: 3, title: "Search", text: "Find titles, people and genres in your library."),
    Stop(
      tab: 4, title: "Settings",
      text: "Your name and picture, playback, switching profiles and About Aurelia."),
  ]

  @Binding var tab: Int
  let finished: () -> Void
  @State private var index = 0
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.black.opacity(0.45).ignoresSafeArea()
        .onTapGesture {}
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text(Self.stops[index].title).font(.headline)
          Text(Self.stops[index].text).font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
              Text("\(index + 1) of \(Self.stops.count)").font(.caption).foregroundStyle(.secondary)
              Button(index == Self.stops.count - 1 ? "Done" : "Next") { advance() }
                .buttonStyle(IOSButtonStyle(kind: .primary, fullWidth: true))
                .accessibilityIdentifier("tour-next")
              Button("Skip Tour") { finished() }
                .buttonStyle(IOSButtonStyle(kind: .secondary, fullWidth: true))
                .accessibilityIdentifier("tour-skip")
            }
          } else {
            HStack(spacing: 12) {
              Text("\(index + 1) of \(Self.stops.count)").font(.caption).foregroundStyle(.secondary)
              Spacer()
              Button("Skip Tour") { finished() }
                .font(.subheadline.weight(.semibold))
                .tint(.white.opacity(0.8))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("tour-skip")
              Button(index == Self.stops.count - 1 ? "Done" : "Next") { advance() }
                .buttonStyle(IOSButtonStyle(kind: .primary))
                .accessibilityIdentifier("tour-next")
            }
          }
        }
        .padding(18)
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxHeight: 340)
      .fixedSize(horizontal: false, vertical: true)
      .background(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(Color(red: 0.14, green: 0.15, blue: 0.17).opacity(0.97))
          .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
      )
      .padding(.horizontal, IOSDesign.margin(for: sizeClass))
      .padding(.bottom, sizeClass == .regular ? 24 : 76)
      .frame(maxWidth: 520)
    }
    .accessibilityAddTraits(.isModal)
    .onAppear { tab = Self.stops[0].tab }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("library-tour")
  }

  private func advance() {
    if index + 1 >= Self.stops.count {
      finished()
    } else {
      index += 1
      tab = Self.stops[index].tab
    }
  }
}

/// A chosen photo waiting to be cropped.
struct IOSCroppingPhoto: Identifiable {
  let id = UUID()
  let image: CGImage
}

/// Moves and zooms a photo inside a circle; Use Photo returns the square JPEG, Cancel nil.
struct IOSPhotoCropSheet: View {
  let image: CGImage
  let done: (Data?) -> Void
  @State private var zoom: CGFloat = 1
  @State private var offset: CGSize = .zero
  @GestureState private var dragging: CGSize = .zero
  @GestureState private var pinching: CGFloat = 1

  private var imageSize: CGSize { CGSize(width: image.width, height: image.height) }

  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        let side = max(120, min(geometry.size.width, geometry.size.height) - 48)
        let liveZoom = min(max(zoom * pinching, 1), IOSPhotoCrop.maximumZoom)
        let live = IOSPhotoCrop.clamped(
          offset: CGSize(
            width: offset.width + dragging.width, height: offset.height + dragging.height),
          imageSize: imageSize, side: side, zoom: liveZoom)
        let scale = side / min(imageSize.width, imageSize.height) * liveZoom
        ZStack {
          Color.black.ignoresSafeArea()
          Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: imageSize.width * scale, height: imageSize.height * scale)
            .offset(live)
          Rectangle().fill(.black.opacity(0.55))
            .ignoresSafeArea()
            .mask {
              Rectangle().ignoresSafeArea().overlay {
                Circle().frame(width: side, height: side).blendMode(.destinationOut)
              }
              .compositingGroup()
            }
            .allowsHitTesting(false)
          Circle().strokeBorder(.white, lineWidth: 2).frame(width: side, height: side)
            .allowsHitTesting(false)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .onChange(of: geometry.size) { _, newSize in
          let newSide = max(120, min(newSize.width, newSize.height) - 48)
          offset = IOSPhotoCrop.clamped(
            offset: offset, imageSize: imageSize, side: newSide, zoom: zoom)
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(
          DragGesture()
            .updating($dragging) { value, state, _ in state = value.translation }
            .onEnded { value in
              offset = IOSPhotoCrop.clamped(
                offset: CGSize(
                  width: offset.width + value.translation.width,
                  height: offset.height + value.translation.height),
                imageSize: imageSize, side: side, zoom: zoom)
            }
            .simultaneously(
              with: MagnifyGesture()
                .updating($pinching) { value, state, _ in state = value.magnification }
                .onEnded { value in
                  zoom = min(max(zoom * value.magnification, 1), IOSPhotoCrop.maximumZoom)
                  offset = IOSPhotoCrop.clamped(
                    offset: offset, imageSize: imageSize, side: side, zoom: zoom)
                })
        )
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(nil) } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Use Photo") {
              let rect = IOSPhotoCrop.rect(
                imageSize: imageSize, side: side, zoom: zoom, offset: offset)
              done(IOSPhotoCrop.croppedJPEG(image, rect: rect))
            }
            .accessibilityIdentifier("photo-crop-use")
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Photo to crop")
        .accessibilityHint("Drag to move the photo, pinch to zoom.")
      }
      .navigationTitle("Move and Scale")
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}
