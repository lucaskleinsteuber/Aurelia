import AppKit
import SwiftUI

enum AureliaDesign {
  static let canvasRGB = (red: UInt8(32), green: UInt8(35), blue: UInt8(38))
  static let pagePadding: CGFloat = 32
  static let homeRailLeadingInset: CGFloat = 32
  static let detailRailLeadingInset: CGFloat = 48
  static let sectionSpacing: CGFloat = 30
  static let rowSpacing: CGFloat = 20
  static let cardRadius: CGFloat = 18
  static let compactRadius: CGFloat = 12
  static let heroRadius: CGFloat = 24
  static let sidebarWidth: CGFloat = 236
  static let minimumControlSize: CGFloat = 44

  static let pageTitle = Font.system(size: 34, weight: .bold, design: .default)
  static let heroTitle = Font.system(size: 44, weight: .bold, design: .default)
  static let sectionTitle = Font.system(size: 20, weight: .semibold, design: .default)

  // The neutral canvas is a measured reference value, not an approximate
  // "cinema blue". Artwork is responsible for all strong color in Aurelia.
  static let canvas = Color(
    red: Double(canvasRGB.red) / 255,
    green: Double(canvasRGB.green) / 255,
    blue: Double(canvasRGB.blue) / 255)
  static let canvasTop = Color(red: 27 / 255, green: 30 / 255, blue: 33 / 255)
  static let surface = Color(red: 40 / 255, green: 44 / 255, blue: 47 / 255)
  static let raisedSurface = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
  static let hairline = Color(nsColor: .separatorColor).opacity(0.72)
  static let hover = Color(nsColor: .labelColor).opacity(0.08)
  static let selection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
  static let subduedText = Color(nsColor: .secondaryLabelColor)

  static let responsiveSpring = Animation.spring(response: 0.3, dampingFraction: 1)
}

struct AureliaSidebarBackground: View {
  let artwork: ArtworkSummary?
  let symbol: String
  let verticalOffset: CGFloat
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    ZStack(alignment: .top) {
      AureliaDesign.canvas
      if !reduceTransparency, let artwork {
        ZStack {
          AuthenticatedArtwork(
            artwork: artwork,
            symbol: symbol,
            contentMode: .fill
          )
          .id(artwork.id)
          LinearGradient(
            stops: [
              .init(color: .clear, location: 0.52),
              .init(color: AureliaDesign.canvas.opacity(0.34), location: 0.78),
              .init(color: AureliaDesign.canvas, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom)
        }
        .frame(height: 540)
        .offset(y: min(verticalOffset, 0))
        .blur(radius: 8)
        .opacity(0.8)
      }
      if reduceTransparency {
        AureliaDesign.canvas
      } else {
        Rectangle().fill(.ultraThinMaterial).opacity(0.28)
        AureliaDesign.canvas.opacity(0.04)
      }
    }
    .clipped()
  }
}

struct AureliaBackdrop: View {
  var body: some View {
    LinearGradient(
      colors: [AureliaDesign.canvasTop, AureliaDesign.canvas, AureliaDesign.canvas],
      startPoint: .top,
      endPoint: .bottom
    )
    .ignoresSafeArea()
  }
}

struct AureliaHorizontalRail<Content: View>: View {
  let spacing: CGFloat
  let alignment: VerticalAlignment
  let leadingInset: CGFloat
  let content: Content

  init(
    spacing: CGFloat = AureliaDesign.rowSpacing,
    alignment: VerticalAlignment = .top,
    leadingInset: CGFloat = 0,
    @ViewBuilder content: () -> Content
  ) {
    self.spacing = spacing
    self.alignment = alignment
    self.leadingInset = leadingInset
    self.content = content()
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(alignment: alignment, spacing: spacing) {
        content
      }
      .scrollTargetLayout()
      .padding(.vertical, 8)
    }
    .contentMargins(.leading, AureliaDesign.pagePadding + leadingInset, for: .scrollContent)
    .contentMargins(.trailing, AureliaDesign.pagePadding, for: .scrollContent)
    .padding(.horizontal, -AureliaDesign.pagePadding)
    .scrollClipDisabled()
    .scrollBounceBehavior(.basedOnSize)
  }
}

enum AureliaSidebarArtworkPosition {
  static func verticalOffset(contentOffset: CGFloat, topInset: CGFloat) -> CGFloat {
    -min(max(contentOffset + topInset, 0), 540)
  }
}

struct AureliaWindowChrome: NSViewRepresentable {
  func makeNSView(context: Context) -> WindowChromeView { WindowChromeView() }
  func updateNSView(_ nsView: WindowChromeView, context: Context) { nsView.apply() }

  final class WindowChromeView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      apply()
    }

    func apply() {
      DispatchQueue.main.async { [weak self] in
        self?.applyAttachedWindow()
      }
    }

    private func applyAttachedWindow() {
      guard let window else { return }
      window.styleMask.insert(.fullSizeContentView)
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.titlebarSeparatorStyle = .none
      window.toolbar?.isVisible = false
      window.isMovableByWindowBackground = true
      window.backgroundColor = NSColor(AureliaDesign.canvas)
      window.standardWindowButton(.closeButton)?.isHidden = false
      window.standardWindowButton(.miniaturizeButton)?.isHidden = false
      window.standardWindowButton(.zoomButton)?.isHidden = false
      window.contentView?.needsLayout = true
    }
  }
}

extension View {
  @ViewBuilder
  func aureliaFullWindowCanvas() -> some View {
    if #available(macOS 15.0, *) {
      containerBackground(for: .window) { AureliaBackdrop() }
    } else {
      self
    }
  }

  @ViewBuilder
  func aureliaRemoveEmptyWindowToolbar() -> some View {
    if #available(macOS 15.0, *) {
      self
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar(removing: .sidebarToggle)
        .toolbar(removing: .title)
    } else {
      self
    }
  }
}

struct AureliaSurface<Content: View>: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  let material: Bool
  let radius: CGFloat
  let padding: CGFloat
  let content: Content

  init(
    material: Bool = false,
    radius: CGFloat = AureliaDesign.cardRadius,
    padding: CGFloat = 20,
    @ViewBuilder content: () -> Content
  ) {
    self.material = material
    self.radius = radius
    self.padding = padding
    self.content = content()
  }

  var body: some View {
    content
      .padding(padding)
      .background {
        if material && !reduceTransparency {
          Rectangle().fill(.regularMaterial)
        } else {
          Rectangle().fill(AureliaDesign.surface.opacity(material ? 0.98 : 1))
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .stroke(AureliaDesign.hairline, lineWidth: 1)
      }
  }
}

// Kept as a compatibility entry point for existing settings and setup views.
struct CinemaMaterialCard<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) { self.content = content() }

  var body: some View {
    AureliaSurface(material: false) { content }
  }
}

struct AureliaSectionHeading: View {
  let title: String
  var count: Int?
  var trailing: AnyView?

  init(title: String, count: Int? = nil) {
    self.title = title
    self.count = count
    trailing = nil
  }

  init<Trailing: View>(title: String, count: Int? = nil, @ViewBuilder trailing: () -> Trailing) {
    self.title = title
    self.count = count
    self.trailing = AnyView(trailing())
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title)
        .font(AureliaDesign.sectionTitle)
      if let count {
        Text(String(count))
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 12)
      trailing
    }
  }
}

struct AureliaSettingsSection<Content: View>: View {
  let title: String
  let symbol: String?
  let description: String?
  let content: Content

  init(
    _ title: String,
    symbol: String? = nil,
    description: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.symbol = symbol
    self.description = description
    self.content = content()
  }

  var body: some View {
    AureliaSurface {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 10) {
          if let symbol {
            Image(systemName: symbol)
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(.secondary)
              .frame(width: 22)
          }
          Text(title)
            .font(AureliaDesign.sectionTitle)
        }
        if let description {
          Text(description)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct AureliaSearchField: View {
  let prompt: String
  @Binding var text: String

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear Search")
      }
    }
    .padding(.horizontal, 12)
    .frame(height: 38)
    .background(AureliaDesign.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(AureliaDesign.hairline, lineWidth: 1)
    }
  }
}

struct AureliaIconControl: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  let symbol: String
  let label: String
  var selected = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .semibold))
        .frame(width: AureliaDesign.minimumControlSize, height: AureliaDesign.minimumControlSize)
        .background {
          if reduceTransparency {
            Circle().fill(AureliaDesign.raisedSurface)
          } else {
            Circle().fill(.ultraThinMaterial)
          }
        }
        .overlay {
          Circle().stroke(selected ? .white.opacity(0.24) : AureliaDesign.hairline, lineWidth: 1)
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

struct AureliaPrimaryActionButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(.black.opacity(isEnabled ? 0.94 : 0.42))
      .padding(.horizontal, 18)
      .frame(minHeight: AureliaDesign.minimumControlSize)
      .background(.white.opacity(isEnabled ? 0.96 : 0.38), in: Capsule())
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

struct AuthenticatedArtwork: View {
  @EnvironmentObject private var model: AppModel
  let artwork: ArtworkSummary?
  let symbol: String
  var contentMode: ContentMode = .fill
  var extendsBlurredEdges = false
  var placeholderSymbolSize: CGFloat = 36
  @State private var image: NSImage?

  var body: some View {
    ZStack {
      MediaArtworkPlaceholder(symbol: symbol, symbolSize: placeholderSymbolSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Artwork placeholder")
        .accessibilityIdentifier("artwork-placeholder")
      if let image {
        if extendsBlurredEdges {
          Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .scaleEffect(1.1)
            .blur(radius: 30, opaque: true)
          Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .transition(.opacity)
        } else {
          Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: contentMode)
            .transition(.opacity)
        }
      }
    }
    .clipped()
    .accessibilityElement(children: .contain)
    .task(id: taskID) {
      image = nil
      guard let artwork, let profile = model.profile else { return }
      do {
        let data = try await model.artworkLoader.data(for: artwork, profile: profile)
        try Task.checkCancellation()
        image = NSImage(data: data)
      } catch is CancellationError {
        return
      } catch {
        image = nil
      }
    }
  }

  private var taskID: String {
    "\(model.profile?.serverId.uuidString ?? "none"):\(artwork?.id.uuidString ?? "none")"
  }
}

struct MediaArtworkPlaceholder: View {
  let symbol: String
  var symbolSize: CGFloat = 36

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          AureliaDesign.surface,
          AureliaDesign.canvasTop,
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)
      Image(systemName: symbol)
        .font(.system(size: symbolSize, weight: .light))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.white.opacity(0.54))
    }
  }
}

struct MediaPosterCard: View {
  let item: CatalogItemSummary
  var width: CGFloat = 154
  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      ZStack(alignment: .bottom) {
        AuthenticatedArtwork(artwork: item.poster, symbol: item.kind == .movie ? "film" : "tv")
        if let progress = item.progressFraction {
          GeometryReader { geometry in
            VStack {
              Spacer()
              Capsule()
                .fill(.black.opacity(0.42))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                  Capsule()
                    .fill(.white)
                    .frame(width: geometry.size.width * progress, height: 4)
                }
                .padding(8)
            }
          }
        }
      }
      .frame(width: width, height: width * 1.5)
      .clipShape(RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous))
      .overlay(alignment: .topTrailing) {
        VStack(spacing: 7) {
          if item.isFavorite {
            Image(systemName: "star.fill")
              .foregroundStyle(.white)
              .accessibilityLabel("Favorite")
          }
          if item.availability == .missing {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
              .accessibilityLabel("Media missing")
          }
        }
        .font(.caption.weight(.bold))
        .padding(9)
        .background(.black.opacity(0.44), in: RoundedRectangle(cornerRadius: 10))
        .padding(9)
      }
      .overlay {
        RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous)
          .stroke(hovering ? .white.opacity(0.25) : AureliaDesign.hairline, lineWidth: 1)
      }
      .shadow(color: .black.opacity(hovering ? 0.34 : 0), radius: 14, y: 8)

      Text(item.title)
        .font(.headline)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .frame(width: width, alignment: .leading)
      Text(secondaryLine)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(width: width, alignment: .leading)
    }
    .contentShape(Rectangle())
    .scaleEffect(hovering && !reduceMotion ? 1.012 : 1)
    .animation(reduceMotion ? nil : AureliaDesign.responsiveSpring, value: hovering)
    .onHover { hovering = $0 }
  }

  private var secondaryLine: String {
    if item.availability == .missing { return "Unavailable" }
    if let year = item.year { return String(year) }
    return item.kind == .movie ? "Movie" : "TV Show"
  }
}

struct LandscapeMediaCard: View {
  let item: CatalogItemSummary
  var width: CGFloat = 320
  var eyebrow: String?
  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      AuthenticatedArtwork(
        artwork: item.backdrop ?? item.poster,
        symbol: item.kind == .movie ? "film" : item.kind == .episode ? "play.rectangle" : "tv")
      LinearGradient(
        colors: [.clear, .black.opacity(0.2), .black.opacity(0.9)],
        startPoint: .top,
        endPoint: .bottom)
      VStack(alignment: .leading, spacing: 3) {
        if let eyebrow {
          Text(eyebrow.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(1)
            .foregroundStyle(.white.opacity(0.7))
        }
        Text(item.title)
          .font(.headline)
          .foregroundStyle(.white)
          .lineLimit(1)
        Text(item.year.map(String.init) ?? (item.kind == .movie ? "Movie" : "TV Show"))
          .font(.caption)
          .foregroundStyle(.white.opacity(0.68))
      }
      .padding(16)
      if item.availability == .missing {
        AvailabilityBadge(availability: item.availability)
          .padding(12)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      }
      if let progress = item.progressFraction {
        GeometryReader { geometry in
          VStack {
            Spacer()
            Capsule()
              .fill(.white.opacity(0.22))
              .frame(height: 4)
              .overlay(alignment: .leading) {
                Capsule().fill(.white).frame(width: geometry.size.width * progress, height: 4)
              }
          }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 7)
      }
    }
    .frame(width: width, height: width * 0.5625)
    .clipShape(RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous)
        .stroke(hovering ? .white.opacity(0.25) : AureliaDesign.hairline, lineWidth: 1)
    }
    .shadow(color: .black.opacity(hovering ? 0.34 : 0), radius: 14, y: 8)
    .scaleEffect(hovering && !reduceMotion ? 1.012 : 1)
    .animation(reduceMotion ? nil : AureliaDesign.responsiveSpring, value: hovering)
    .onHover { hovering = $0 }
  }
}

struct AvailabilityBadge: View {
  let availability: MediaAvailability

  var body: some View {
    if availability == .missing {
      Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
        .font(.caption.weight(.medium))
        .foregroundStyle(.orange)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.black.opacity(0.56), in: Capsule())
        .overlay { Capsule().stroke(.orange.opacity(0.28), lineWidth: 1) }
    }
  }
}

struct ErrorBanner: View {
  let message: String
  var retry: (() -> Void)?

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(message)
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let retry { Button("Try Again", action: retry) }
    }
    .padding(14)
    .frame(maxWidth: 760)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AureliaDesign.compactRadius))
    .overlay {
      RoundedRectangle(cornerRadius: AureliaDesign.compactRadius)
        .stroke(AureliaDesign.hairline, lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.25), radius: 14, y: 7)
    .padding(.horizontal, AureliaDesign.pagePadding)
    .padding(.bottom, 18)
  }
}
