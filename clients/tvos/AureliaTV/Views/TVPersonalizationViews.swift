import SwiftUI
import UIKit

/// Profile photos, loaded once per picture revision with this Apple TV's credential, so the
/// picker shows them before a profile is unlocked. Photos are chosen on other devices.
@MainActor
final class TVProfilePhotoCache: ObservableObject {
  static let shared = TVProfilePhotoCache()

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

  private static func key(_ id: UUID, _ revision: Int64) -> String {
    "\(id.uuidString)-\(revision)"
  }
}

/// A built-in picture's symbol in white.
struct TVProfileSymbol: View {
  let symbol: String
  let size: CGFloat

  var body: some View {
    Group {
      if symbol == "rocket" {
        TVRocketShape().fill(.white, style: FillStyle(eoFill: true))
          .frame(width: size * 0.5, height: size * 0.5)
      } else {
        Image(systemName: TVProfilePictures.systemImage(for: symbol))
          .font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
      }
    }
    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
  }
}

/// The rocket of the built-in pictures, on the same 24-point grid as the other clients.
struct TVRocketShape: Shape {
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

/// About Aurelia on the Apple TV: the version, the source and the legal notes (in the test edition
/// also the introduction and tour again).
struct TVAboutView: View {
  @EnvironmentObject private var model: TVAppModel
  @Environment(\.dismiss) private var dismiss
  static let repository = "github.com/lucaskleinsteuber/Aurelia"

  private var version: String {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    return "Version \(short ?? "") (Build \(build ?? ""))"
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 40) {
        VStack(spacing: 12) {
          Image(systemName: "play.rectangle.fill").font(.system(size: 80))
            .foregroundStyle(.white.opacity(0.85))
          Text("Aurelia for Apple TV").font(.system(size: 44, weight: .bold))
          Text(version).font(.system(size: 26)).foregroundStyle(.secondary)
            .accessibilityIdentifier("about-version")
        }
        // Seeing the introduction and tour again is for trying them out in the test edition; the
        // real app shows them once, at setup.
        if TVTestEdition.isActive {
          VStack(spacing: 18) {
            Text("See again how Aurelia works, or take the short tour.")
              .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 22) {
              Button("Show Introduction") {
                NotificationCenter.default.post(name: .tvShowIntroduction, object: nil)
              }
              Button("Show Tour") {
                model.setupGuide.requestTour()
                dismiss()
              }
            }
            .buttonStyle(TVButtonStyle())
          }
          .focusSection()
        }
        HStack(alignment: .center, spacing: 40) {
          if let image = TVQRCode.image(for: "https://\(Self.repository)") {
            Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
              .frame(width: 180, height: 180).padding(14)
              .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          }
          VStack(alignment: .leading, spacing: 12) {
            Text("Source Code").font(.headline)
            Text("Aurelia is open source. Its code, releases and full change history are at")
              .foregroundStyle(.secondary)
            Text(Self.repository).font(.headline)
          }
          .frame(maxWidth: 760, alignment: .leading)
        }
        VStack(spacing: 18) {
          Text("© 2026 Lucas Kleinsteuber").font(.callout)
          HStack(spacing: 22) {
            NavigationLink("Aurelia License (MIT)") {
              TVLicenseView(title: "Aurelia", resource: "LICENSE", source: nil)
            }
            NavigationLink("TVVLCKit (LGPL 2.1 or later)") {
              TVLicenseView(
                title: "TVVLCKit", resource: "TVVLCKit-COPYING.txt",
                source: "code.videolan.org/videolan/VLCKit")
            }
            NavigationLink("Privacy Policy") {
              TVLicenseView(
                title: "Privacy Policy", resource: "PRIVACY.md",
                source: "github.com/lucaskleinsteuber/Aurelia/blob/main/docs/PRIVACY.md",
                sourceTitle: "Online", prose: true)
            }
          }
          .buttonStyle(TVButtonStyle())
          .accessibilityIdentifier("about-licenses")
          Text(
            "Movie and series details and pictures can come from TMDB when the server's owner turns it on; subtitles can come from OpenSubtitles. This product uses the TMDB API but is not endorsed or certified by TMDB, and Aurelia is not endorsed by OpenSubtitles."
          )
          .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 1200)
        .focusSection()
      }
      .padding(80)
      .frame(maxWidth: .infinity)
    }
    .background(TVDesign.canvas.ignoresSafeArea())
  }
}

/// A license text bundled with the app, in full. Each paragraph can take focus, so the remote
/// scrolls through it; where the license asks for the source, its address and a QR code show.
private struct TVLicenseView: View {
  let title: String
  let resource: String
  let source: String?
  /// What the QR code leads to: the component's source, or the same text online.
  var sourceTitle = "Source Code"
  /// Markdown (the privacy policy) rather than a plain license text.
  var prose = false

  private var paragraphs: [String] {
    guard let url = Bundle.main.url(forResource: resource, withExtension: nil),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return ["The license text is missing from this build."] }
    return text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text(title).font(.system(size: 48, weight: .bold))
        if let source {
          HStack(spacing: 30) {
            if let image = TVQRCode.image(for: "https://\(source)") {
              Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
                .frame(width: 150, height: 150).padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 8) {
              Text(sourceTitle).font(.headline)
              Text(source).font(.callout).foregroundStyle(.secondary)
            }
          }
        }
        ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
          TVLicenseParagraph(text: paragraph, prose: prose)
        }
      }
      .padding(80)
      .frame(maxWidth: 1500, alignment: .leading)
    }
    .background(TVDesign.canvas.ignoresSafeArea())
  }
}

private struct TVLicenseParagraph: View {
  let text: String
  var prose = false
  @FocusState private var focused: Bool

  var body: some View {
    content
      .foregroundStyle(focused ? .primary : .secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .focusable()
      .focused($focused)
  }

  @ViewBuilder private var content: some View {
    if !prose {
      Text(text).font(.system(size: 24, design: .monospaced))
    } else if text.hasPrefix("#") {
      Text(text.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
        .font(.system(size: 32, weight: .semibold))
    } else {
      Text(
        (try? AttributedString(
          markdown: text,
          options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
      ).font(.system(size: 26))
    }
  }
}

extension Notification.Name {
  static let tvShowIntroduction = Notification.Name("AureliaTVShowIntroduction")
}

/// The setup assistant's start on the Apple TV: "Connect to My Server" or "I'm New to Aurelia".
/// New users learn how Aurelia works, then "Do you have an Aurelia server?". Without one, a short
/// guide with a QR code and a way back to that question.
struct TVSetupIntroductionView: View {
  enum Page { case welcome, howItWorks, server, noServer }

  @ObservedObject var guide: TVSetupGuide
  var replay = false
  var closed: (() -> Void)? = nil
  @State private var page: Page = .welcome

  var body: some View {
    VStack(spacing: 44) {
      switch page {
      case .welcome: welcome
      case .howItWorks: howItWorks
      case .server: server
      case .noServer: noServer
      }
    }
    .id(page)
    .padding(80)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TVDesign.canvas.ignoresSafeArea())
    .onAppear { if replay { page = .howItWorks } }
    .onExitCommand {
      switch page {
      case .welcome: break
      case .howItWorks: if replay { closed?() } else { page = .welcome }
      case .server: page = .howItWorks
      case .noServer: page = .server
      }
    }
    .accessibilityIdentifier("setup-introduction")
  }

  private var welcome: some View {
    VStack(spacing: 40) {
      Image(systemName: "play.rectangle.fill").font(.system(size: 96))
        .foregroundStyle(.white.opacity(0.85))
      heading(
        "Welcome to Aurelia",
        "Your movies and shows from your own server, on this Apple TV. New here? A few steps set everything up."
      )
      HStack(spacing: 30) {
        Button("Connect to My Server") { guide.start() }
          .accessibilityIdentifier("setup-connect")
        Button("I'm New to Aurelia") { page = .howItWorks }
          .accessibilityIdentifier("setup-show-me-around")
      }
      .buttonStyle(TVButtonStyle())
    }
  }

  private var howItWorks: some View {
    VStack(spacing: 50) {
      heading(
        "How Aurelia Works", "One computer serves your library. Everything else just watches.")
      HStack(alignment: .top, spacing: 40) {
        station("externaldrive.fill", "Your Files", "Movies and shows stay where they are.")
        station("server.rack", "Aurelia Server", "Runs on a Mac or Linux computer at home.")
        station("appletv.fill", "This Apple TV", "Plays from the server on your home network.")
      }
      Button(replay ? "Done" : "Continue") {
        if replay { closed?() } else { page = .server }
      }
      .buttonStyle(TVButtonStyle())
      .accessibilityIdentifier("setup-continue")
    }
  }

  private var server: some View {
    VStack(spacing: 44) {
      heading(
        "Do You Have an Aurelia Server?",
        "It runs in Aurelia on a Mac, or on a Linux computer at home.")
      HStack(spacing: 30) {
        Button("Yes, Connect to It") { guide.start() }
          .accessibilityIdentifier("setup-has-server")
        Button("Not Yet") { page = .noServer }
          .accessibilityIdentifier("setup-no-server")
      }
      .buttonStyle(TVButtonStyle())
    }
  }

  private var noServer: some View {
    HStack(spacing: 70) {
      if let image = TVQRCode.image(for: TVQRCode.downloadPage.absoluteString, scale: 14) {
        Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
          .frame(width: 320, height: 320).padding(20)
          .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
          .accessibilityLabel("QR code for the Aurelia download page")
      }
      VStack(alignment: .leading, spacing: 30) {
        Text("Set Up a Server First").font(.system(size: 52, weight: .bold))
        Text(
          "Install Aurelia on the Mac or Linux computer whose drives hold your movies and shows, and choose to use it as the server."
        )
        .font(.system(size: 28)).foregroundStyle(.secondary)
        // Apple TV has no browser, so the GitHub page is reached by the code or its address.
        VStack(alignment: .leading, spacing: 8) {
          Text("Scan the code with your iPhone or iPad, or open on the computer:")
            .font(.system(size: 24)).foregroundStyle(.secondary)
          Text(TVAboutView.repository).font(.system(size: 30, weight: .semibold))
            .accessibilityIdentifier("setup-no-server-github")
        }
        Text("When the server runs, go back and choose Yes, Connect to It.")
          .font(.system(size: 24)).foregroundStyle(.secondary)
        Button("Back") { page = .server }
          .buttonStyle(TVButtonStyle())
          .accessibilityIdentifier("setup-no-server-back")
      }
      .frame(maxWidth: 900, alignment: .leading)
    }
  }

  private func heading(_ title: String, _ detail: String) -> some View {
    VStack(spacing: 16) {
      Text(title).font(.system(size: 60, weight: .bold)).multilineTextAlignment(.center)
      Text(detail).font(.system(size: 28)).foregroundStyle(.secondary)
        .multilineTextAlignment(.center).frame(maxWidth: 1200)
    }
  }

  private func station(_ symbol: String, _ title: String, _ detail: String) -> some View {
    VStack(spacing: 18) {
      Image(systemName: symbol).font(.system(size: 52)).frame(width: 130, height: 130)
        .background(TVDesign.surface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
      Text(title).font(.headline)
      Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .frame(width: 380)
    .accessibilityElement(children: .combine)
  }
}

/// The guided connection's progress at the top of each screen.
struct TVSetupStepBar: View {
  let current: TVSetupStep

  var body: some View {
    let steps = TVSetupStep.allCases
    let index = steps.firstIndex(of: current) ?? 0
    HStack(spacing: 18) {
      ForEach(Array(steps.enumerated()), id: \.element) { position, step in
        HStack(spacing: 10) {
          ZStack {
            Circle().fill(position <= index ? Color.accentColor : Color.white.opacity(0.2))
            if position < index {
              Image(systemName: "checkmark").font(.system(size: 16, weight: .bold))
            } else {
              Text("\(position + 1)").font(.system(size: 18, weight: .semibold))
            }
          }
          .foregroundStyle(.white).frame(width: 36, height: 36)
          Text(step.title).font(.system(size: 22, weight: position == index ? .semibold : .regular))
            .opacity(position == index ? 1 : 0.65)
        }
      }
    }
    .padding(.horizontal, 26).padding(.vertical, 12)
    .background(.ultraThinMaterial, in: Capsule())
    .accessibilityIdentifier("setup-step-bar")
  }
}

/// "You're All Set" after the guided connection, then the tour.
struct TVSetupDoneView: View {
  @EnvironmentObject private var model: TVAppModel
  @ObservedObject var guide: TVSetupGuide

  var body: some View {
    VStack(spacing: 44) {
      Image(systemName: "checkmark").font(.system(size: 90, weight: .semibold))
        .foregroundStyle(Color.accentColor)
      Text("You're All Set").font(.system(size: 60, weight: .bold))
      VStack(alignment: .leading, spacing: 18) {
        check("This Apple TV is connected to \(model.connection?.name ?? "your server").")
        if let user = model.session?.user { check("You watch as \(user.shownName).") }
        check("Progress, favorites and your watchlist follow you to every device.")
      }
      .padding(36)
      .background(TVDesign.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
      Button("Start Watching") { guide.finish() }
        .buttonStyle(TVButtonStyle())
        .accessibilityIdentifier("setup-start-watching")
    }
    .padding(80)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TVDesign.canvas.ignoresSafeArea())
    .accessibilityIdentifier("setup-done")
  }

  private func check(_ text: String) -> some View {
    HStack(spacing: 16) {
      Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
      Text(text).font(.system(size: 28))
    }
  }
}

/// The tour after setup: it opens each tab in turn and explains it in a short note.
struct TVLibraryTour: View {
  struct Stop: Equatable {
    let tab: Int
    let title: String
    let text: String
  }

  static let stops: [Stop] = [
    Stop(
      tab: 0, title: "Home",
      text: "Continue Watching, new titles and your favorites. Select a poster to see its details."),
    Stop(
      tab: 1, title: "Movies and TV Shows",
      text: "Your whole library. Press and hold a poster for more actions."),
    Stop(tab: 3, title: "Search", text: "Find titles, people and genres in your library."),
    Stop(
      tab: 4, title: "Your Profile",
      text: "Your name and picture, playback, switching profiles and About Aurelia."),
  ]

  @Binding var tab: Int
  let finished: () -> Void
  @State private var index = 0
  @FocusState private var nextFocused: Bool

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.black.opacity(0.5).ignoresSafeArea()
      VStack(alignment: .leading, spacing: 18) {
        Text(Self.stops[index].title).font(.system(size: 40, weight: .bold))
        Text(Self.stops[index].text).font(.system(size: 28)).foregroundStyle(.secondary)
        HStack(spacing: 24) {
          Text("\(index + 1) of \(Self.stops.count)").font(.system(size: 22))
            .foregroundStyle(.secondary)
          Spacer()
          Button("Skip Tour") { finished() }
            .accessibilityIdentifier("tour-skip")
          Button(index == Self.stops.count - 1 ? "Done" : "Next") { advance() }
            .focused($nextFocused)
            .accessibilityIdentifier("tour-next")
        }
        .buttonStyle(TVButtonStyle())
      }
      .padding(44)
      .frame(width: 1100)
      .background(
        RoundedRectangle(cornerRadius: 30, style: .continuous)
          .fill(Color(red: 0.14, green: 0.15, blue: 0.17).opacity(0.97))
      )
      .padding(.bottom, 80)
      .focusSection()
    }
    .onAppear {
      tab = Self.stops[0].tab
      nextFocused = true
    }
    .onExitCommand { finished() }
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

/// A round choice (a picture or a color) that grows and lifts when focused. The system card style
/// put a gray rounded platter behind each circle, which showed as a gray rim.
