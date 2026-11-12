import AppKit
import SwiftUI

/// A round profile picture: the profile's photo, a built-in picture (a symbol on a gradient), or
/// the profile's initial on a gradient whose color derives from its identifier, like account
/// pictures in Apple's apps.
struct AureliaProfileAvatar: View {
  let id: UUID?
  let name: String
  var size: CGFloat = 96
  var pictureKey: String? = nil
  var pictureRevision: Int64 = 0
  @ObservedObject private var photos = ProfilePhotoCache.shared

  init(
    id: UUID?, name: String, size: CGFloat = 96, pictureKey: String? = nil,
    pictureRevision: Int64 = 0
  ) {
    self.id = id
    self.name = name
    self.size = size
    self.pictureKey = pictureKey
    self.pictureRevision = pictureRevision
  }

  init(user: UserSummary, size: CGFloat = 96) {
    self.init(
      id: user.id, name: user.shownName, size: size, pictureKey: user.pictureKey,
      pictureRevision: user.pictureRevision)
  }

  init(profile: WatchingProfile, size: CGFloat = 96) {
    self.init(
      id: profile.id, name: profile.name, size: size, pictureKey: profile.pictureKey,
      pictureRevision: profile.pictureRevision)
  }

  static let palettes: [(Color, Color)] = [
    (Color(red: 0.36, green: 0.62, blue: 1.0), Color(red: 0.13, green: 0.36, blue: 0.86)),
    (Color(red: 0.74, green: 0.49, blue: 1.0), Color(red: 0.44, green: 0.22, blue: 0.82)),
    (Color(red: 1.0, green: 0.55, blue: 0.6), Color(red: 0.84, green: 0.24, blue: 0.4)),
    (Color(red: 1.0, green: 0.72, blue: 0.36), Color(red: 0.9, green: 0.42, blue: 0.14)),
    (Color(red: 0.36, green: 0.84, blue: 0.8), Color(red: 0.1, green: 0.52, blue: 0.56)),
    (Color(red: 0.5, green: 0.86, blue: 0.48), Color(red: 0.18, green: 0.56, blue: 0.3)),
    (Color(red: 0.55, green: 0.6, blue: 1.0), Color(red: 0.28, green: 0.3, blue: 0.8)),
  ]

  /// Built-in pictures' colors: the seven gradients above plus red.
  static func namedPalette(_ name: String) -> (Color, Color) {
    let index = ProfilePictureCatalog.paletteIndex(named: name)
    if index < palettes.count { return palettes[index] }
    return (Color(red: 1.0, green: 0.48, blue: 0.42), Color(red: 0.79, green: 0.19, blue: 0.17))
  }

  static func paletteIndex(for id: UUID?) -> Int {
    guard let id else { return 0 }
    let sum = withUnsafeBytes(of: id.uuid) { $0.reduce(0) { $0 + Int($1) } }
    return sum % palettes.count
  }

  static func initial(of name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() }
      ?? "?"
  }

  var body: some View {
    let builtin = ProfilePictureCatalog.parse(pictureKey)
    let colors =
      builtin.map { Self.namedPalette($0.palette) } ?? Self.palettes[Self.paletteIndex(for: id)]
    let photo =
      pictureKey == ProfilePictureCatalog.photoKey
      ? id.flatMap { photos.image(id: $0, revision: pictureRevision) } : nil
    let waitsForPhoto = pictureKey == ProfilePictureCatalog.photoKey && id != nil
    Circle()
      // A photo covers the whole circle; the gradient beneath it would show as a colored rim
      // along the photo's edge.
      .fill(
        photo == nil
          ? AnyShapeStyle(
            LinearGradient(colors: [colors.0, colors.1], startPoint: .top, endPoint: .bottom))
          : AnyShapeStyle(Color.clear)
      )
      .overlay {
        if let photo {
          Image(nsImage: photo).resizable().scaledToFill().clipShape(Circle())
            .transition(.opacity)
        } else if waitsForPhoto {
          // While the photo loads, only the plain gradient: no initial or earlier picture that
          // the photo would then replace before everyone's eyes.
          EmptyView()
        } else if let builtin {
          ProfileSymbolView(symbol: builtin.symbol, size: size)
        } else {
          Text(Self.initial(of: name))
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
      }
      .overlay { Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1) }
      .frame(width: size, height: size)
      .animation(.easeOut(duration: 0.2), value: photo != nil)
      .accessibilityHidden(true)
      .task(id: "\(id?.uuidString ?? "")-\(pictureKey ?? "")-\(pictureRevision)") {
        if pictureKey == ProfilePictureCatalog.photoKey, let id {
          photos.load(id: id, revision: pictureRevision)
        }
      }
  }
}

/// A built-in picture's symbol in white, sized for its circle.
struct ProfileSymbolView: View {
  let symbol: String
  let size: CGFloat

  var body: some View {
    Group {
      if symbol == "rocket" {
        // SF Symbols has no rocket; this one matches the other clients' drawing.
        RocketSymbolShape()
          .fill(.white, style: FillStyle(eoFill: true))
          .frame(width: size * 0.5, height: size * 0.5)
      } else {
        Image(systemName: ProfilePictureCatalog.systemImage(for: symbol))
          .font(.system(size: size * 0.42, weight: .semibold))
          .foregroundStyle(.white)
      }
    }
    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
  }
}

/// The rocket of the built-in pictures, drawn on a 24-point grid like the Linux and web clients.
struct RocketSymbolShape: Shape {
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

/// Profile photos, loaded once per picture revision with the paired device's credential (the
/// picker shows them before any profile is unlocked). A new revision loads the new photo.
/// Each photo is also kept in this app's caches folder, so the picker draws it in its first frame
/// after the next launch, and the offline mode shows it without the server.
@MainActor
final class ProfilePhotoCache: ObservableObject {
  static let shared = ProfilePhotoCache()

  @Published private var images: [String: NSImage] = [:]
  private var loading: Set<String> = []
  private let folder: URL?
  /// Set by the app model: fetches a profile's photo (JPEG) from the connected server.
  var loader: (@MainActor (UUID, Int64) async throws -> Data)?

  init(folder: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
    .appendingPathComponent("Aurelia Profile Photos", isDirectory: true))
  {
    self.folder = folder
  }

  func image(id: UUID, revision: Int64) -> NSImage? {
    let key = Self.key(id, revision)
    if let image = images[key] { return image }
    // Read from disk at once, so a saved photo never appears a moment after its circle.
    guard let file = file(key), let data = try? Data(contentsOf: file),
      let image = NSImage(data: data)
    else { return nil }
    Task { @MainActor in self.images[key] = image }
    return image
  }

  func load(id: UUID, revision: Int64) {
    let key = Self.key(id, revision)
    guard image(id: id, revision: revision) == nil, !loading.contains(key), let loader else {
      return
    }
    loading.insert(key)
    Task {
      defer { loading.remove(key) }
      guard let data = try? await loader(id, revision), let image = NSImage(data: data) else {
        return
      }
      images[key] = image
      keep(data, id: id, revision: revision)
    }
  }

  /// Keeps a just-uploaded photo, so it shows at once without loading it back.
  func store(_ image: NSImage, data: Data? = nil, id: UUID, revision: Int64) {
    images[Self.key(id, revision)] = image
    if let data { keep(data, id: id, revision: revision) }
  }

  func removeAll() {
    images.removeAll()
  }

  /// Writes the photo of one revision and removes the profile's earlier ones.
  private func keep(_ data: Data, id: UUID, revision: Int64) {
    guard let folder, let file = file(Self.key(id, revision)) else { return }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? data.write(to: file, options: .atomic)
    let earlier = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    for name in earlier where name.hasPrefix(id.uuidString + "-") && name != file.lastPathComponent {
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
  }

  private func file(_ key: String) -> URL? {
    folder?.appendingPathComponent(key + ".jpg")
  }

  private static func key(_ id: UUID, _ revision: Int64) -> String {
    "\(id.uuidString)-\(revision)"
  }
}

/// A calm, slowly drifting wash of color behind the profile picker, so the first screen of the
/// app feels alive without showing any profile's titles before it is unlocked.
struct AureliaAmbientBackground: View {
  @Environment(\.aureliaReduceMotion) private var reduceMotion
  @State private var drift = false

  var body: some View {
    GeometryReader { geometry in
      let size = max(geometry.size.width, geometry.size.height)
      ZStack {
        AureliaDesign.canvas
        glow(Color(red: 0.2, green: 0.26, blue: 0.62), diameter: size * 0.62)
          .offset(
            x: geometry.size.width * (drift ? -0.22 : -0.3),
            y: geometry.size.height * (drift ? -0.24 : -0.16))
        glow(Color(red: 0.05, green: 0.38, blue: 0.44), diameter: size * 0.55)
          .offset(
            x: geometry.size.width * (drift ? 0.3 : 0.22),
            y: geometry.size.height * (drift ? 0.2 : 0.3))
        glow(Color(red: 0.4, green: 0.16, blue: 0.44), diameter: size * 0.48)
          .offset(
            x: geometry.size.width * (drift ? 0.18 : 0.28),
            y: geometry.size.height * (drift ? -0.3 : -0.2))
        RadialGradient(
          colors: [.clear, .black.opacity(0.35)], center: .center,
          startRadius: size * 0.2, endRadius: size * 0.75)
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) { drift = true }
    }
  }

  private func glow(_ color: Color, diameter: CGFloat) -> some View {
    Circle()
      .fill(color.opacity(0.5))
      .frame(width: diameter, height: diameter)
      .blur(radius: diameter * 0.22)
  }
}

/// A slim bar that fades in at the top of a detail page once its hero has scrolled away,
/// keeping the way back and the title in reach, as in the Apple TV app.
struct AureliaCompactHeader: View {
  let title: String
  let isVisible: Bool
  let onBack: () -> Void
  @Environment(\.aureliaReduceTransparency) private var reduceTransparency

  var body: some View {
    HStack(spacing: 14) {
      AureliaIconControl(symbol: "chevron.left", label: "Back", action: onBack)
      Text(title)
        .font(.headline)
        .lineLimit(1)
        .accessibilityIdentifier("compact-header-title")
      Spacer(minLength: 0)
    }
    .padding(.horizontal, AureliaDesign.pagePadding)
    // Leaves room for the window controls when the sidebar is hidden.
    .padding(.top, 28)
    .padding(.bottom, 12)
    .frame(maxWidth: .infinity)
    .background {
      if reduceTransparency {
        AureliaDesign.canvas
      } else {
        ZStack {
          Rectangle().fill(.ultraThinMaterial)
          AureliaDesign.canvas.opacity(0.55)
        }
      }
    }
    .overlay(alignment: .bottom) { AureliaDesign.hairline.frame(height: 1) }
    .opacity(isVisible ? 1 : 0)
    .allowsHitTesting(isVisible)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("compact-header")
  }
}

extension View {
  /// Shows `AureliaCompactHeader` once the page has scrolled past `threshold`.
  func aureliaCompactHeader(
    title: String, threshold: CGFloat, onBack: @escaping () -> Void
  ) -> some View {
    modifier(CompactHeaderModifier(title: title, threshold: threshold, onBack: onBack))
  }
}

private struct CompactHeaderModifier: ViewModifier {
  let title: String
  let threshold: CGFloat
  let onBack: () -> Void
  @State private var scrolledPast = false
  @Environment(\.aureliaReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.contentOffset.y + geometry.contentInsets.top > threshold
      } action: { _, value in
        scrolledPast = value
      }
      .overlay(alignment: .top) {
        // Only present while needed, so the page never exposes a second, hidden Back button.
        // The animation belongs to the header alone: on the whole page it re-laid every section
        // with motion while scrolling, so the page stuttered and its information flew in.
        ZStack(alignment: .top) {
          if scrolledPast {
            AureliaCompactHeader(title: title, isVisible: true, onBack: onBack)
              .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : -8)))
          }
        }
        .animation(
          reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.28), value: scrolledPast)
      }
  }
}

/// The profile row at the foot of the sidebar: a quiet highlight on hover and press.
struct SidebarFooterButtonStyle: ButtonStyle {
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(.white.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.07 : 0)))
      )
      .onHover { hovering = $0 }
  }
}
