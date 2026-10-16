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
  var body: some View {
    AureliaDesign.canvas
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
  let cardWidth: CGFloat
  let itemCount: Int
  let title: String
  let arrowHeight: CGFloat?
  let content: Content
  @Environment(\.aureliaSidebarOverlap) private var sidebarOverlap
  @Environment(\.aureliaReduceMotion) private var reduceMotion
  @State private var position = ScrollPosition()
  @State private var metrics = RailNavigationMetrics()
  @State private var hovering = false
  @State private var visibleRowWidth: CGFloat = 0
  @FocusState private var focusedArrow: String?

  init(
    spacing: CGFloat = AureliaDesign.rowSpacing,
    alignment: VerticalAlignment = .top,
    leadingInset: CGFloat = 0,
    cardWidth: CGFloat = 154,
    itemCount: Int,
    title: String = "Items",
    arrowHeight: CGFloat? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.spacing = spacing
    self.alignment = alignment
    self.leadingInset = leadingInset
    self.cardWidth = cardWidth
    self.itemCount = itemCount
    self.title = title
    self.arrowHeight = arrowHeight
    self.content = content()
  }

  var body: some View {
    ScrollView(.horizontal) {
      LazyHStack(alignment: alignment, spacing: spacing) {
        content
      }
      .scrollTargetLayout()
      .padding(.vertical, 8)
      .padding(.trailing, AureliaDesign.pagePadding)
    }
    .contentMargins(
      .leading, sidebarOverlap + AureliaDesign.pagePadding + leadingInset, for: .scrollContent
    )
    .contentMargins(.trailing, AureliaDesign.pagePadding, for: .scrollContent)
    .scrollIndicators(.never, axes: .horizontal)
    .defaultScrollAnchor(.leading)
    .scrollPosition($position)
    .onScrollGeometryChange(for: RailNavigationMetrics.self) { geometry in
      RailNavigationMetrics(
        offset: max(0, geometry.contentOffset.x + geometry.contentInsets.leading),
        maximumOffset: max(
          0,
          CGFloat(itemCount) * cardWidth + CGFloat(max(0, itemCount - 1)) * spacing
            + AureliaDesign.pagePadding - geometry.containerSize.width),
        visibleWidth: max(0, geometry.containerSize.width - sidebarOverlap),
        contentInset: geometry.contentInsets.leading)
    } action: { old, new in
      metrics = new
      if old.maximumOffset > new.maximumOffset, new.offset > new.maximumOffset + 1 {
        position.scrollTo(x: new.maximumOffset)
      }
    }
    .padding(.leading, -sidebarOverlap)
    .padding(.horizontal, -AureliaDesign.pagePadding)
    .scrollClipDisabled()
    .scrollBounceBehavior(.basedOnSize)
    .overlay {
      GeometryReader { geometry in
        HStack {
          if metrics.canGoBack {
            RailArrow(forward: false, title: title) { move(forward: false) }
              .focused($focusedArrow, equals: "previous")
          }
          Spacer(minLength: 0)
          if metrics.canGoForward {
            RailArrow(forward: true, title: title) { move(forward: true) }
              .focused($focusedArrow, equals: "next")
          }
        }
        .padding(.horizontal, 4)
        .frame(height: 60)
        .position(
          x: geometry.size.width / 2,
          y: min(geometry.size.height / 2, (arrowHeight ?? geometry.size.height) / 2 + 8)
        )
        // Keep navigation discoverable to keyboards/VoiceOver without idle chrome.
        .opacity(hovering || focusedArrow != nil ? 1 : 0)
      }
    }
    .background(RailHoverRegion { hovering = $0 }.allowsHitTesting(false))
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      visibleRowWidth = $0
    }
    .onDisappear { hovering = false }
    .focusSection()
    .onKeyPress(.leftArrow) {
      move(forward: false)
      return .handled
    }
    .onKeyPress(.rightArrow) {
      move(forward: true)
      return .handled
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
    .accessibilityIdentifier("rail-scroll-\(title)")
    .accessibilityAction(named: "Next \(title)") { move(forward: true) }
    .accessibilityAction(named: "Previous \(title)") { move(forward: false) }
    .aureliaOverlayScrollbars()
  }

  private func move(forward: Bool) {
    var navigation = metrics
    // This is the unobscured column. Scroll geometry includes the deliberately
    // extended region beneath the sidebar and is not the visible paging width.
    navigation.visibleWidth = visibleRowWidth
    let target = navigation.destination(
      forward: forward, cardWidth: cardWidth, spacing: spacing,
      inset: AureliaDesign.pagePadding + leadingInset)
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
      // ScrollPosition uses an inset-relative offset, unlike contentOffset.
      position.scrollTo(x: target)
    }
  }

}

struct AureliaWindowChrome: NSViewRepresentable {
  func makeNSView(context: Context) -> WindowChromeView { WindowChromeView() }
  func updateNSView(_ nsView: WindowChromeView, context: Context) { nsView.apply() }

  final class WindowChromeView: NSView {
    private var configuredFixtureSize = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
      #if DEBUG
        if !configuredFixtureSize, CinemaUITestFixture.enabled {
          configuredFixtureSize = true
          let minimum = ProcessInfo.processInfo.environment["AURELIA_CINEMA_MINIMUM_WINDOW"] == "1"
          window.setContentSize(NSSize(width: minimum ? 760 : 1470, height: minimum ? 560 : 916))
        }
      #endif
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
  @Environment(\.aureliaReduceTransparency) private var reduceTransparency
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
  @Environment(\.aureliaReduceTransparency) private var reduceTransparency
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
  @Environment(\.aureliaReduceMotion) private var reduceMotion

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
  @Environment(\.displayScale) private var displayScale
  let artwork: ArtworkSummary?
  let symbol: String
  var contentMode: ContentMode = .fill
  var placeholderSymbolSize: CGFloat = 36
  @State private var image: NSImage?

  var body: some View {
    GeometryReader { geometry in
      let width = ArtworkVariantRequest.width(for: geometry.size.width, scale: displayScale)
      ZStack {
        MediaArtworkPlaceholder(symbol: symbol, symbolSize: placeholderSymbolSize)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Artwork placeholder")
          .accessibilityIdentifier("artwork-placeholder")
        if let image {
          Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: contentMode)
            .transition(.opacity)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .clipped()
      .task(id: taskID(width: width)) {
        image = nil
        guard let artwork, let profile = model.profile else { return }
        do {
          let data = try await model.artworkLoader.data(
            for: artwork, profile: profile,
            width: model.libraryCapabilities.contains("artwork-variants-v1") ? width : nil)
          try Task.checkCancellation()
          image = NSImage(data: data)
        } catch is CancellationError {
          return
        } catch {
          image = nil
        }
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func taskID(width: Int) -> String {
    "\(model.profile?.serverId.uuidString ?? "none"):\(model.profile?.sessionId.uuidString ?? "none"):\(artwork?.id.uuidString ?? "none"):r\(artwork?.revision ?? 0):w\(width):variants\(model.libraryCapabilities.contains("artwork-variants-v1"))"
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
  @Environment(\.aureliaReduceMotion) private var reduceMotion

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
          if MediaAvailabilityPresentation.message(for: item) != nil {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
              .accessibilityLabel(
                MediaAvailabilityPresentation.message(for: item) ?? "Media unavailable")
          }
          if MediaWatchPresentation.isWatched(item) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.white)
              .accessibilityLabel("Watched")
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
    if let message = MediaAvailabilityPresentation.message(for: item) { return message }
    if let year = item.year { return String(year) }
    return item.kind == .movie ? "Movie" : "TV Show"
  }
}

struct LandscapeMediaCard: View {
  let item: CatalogItemSummary
  var width: CGFloat = 320
  var eyebrow: String?
  @State private var hovering = false
  @Environment(\.aureliaReduceMotion) private var reduceMotion

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
      VStack(alignment: .trailing, spacing: 6) {
        AvailabilityBadge(
          availability: item.availability, libraryAvailability: item.libraryAvailability)
        if MediaWatchPresentation.isWatched(item) {
          Label("Watched", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.black.opacity(0.56), in: Capsule())
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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
  var libraryAvailability: LibraryAvailability? = nil

  var body: some View {
    if let message = MediaAvailabilityPresentation.message(
      availability: availability, libraryAvailability: libraryAvailability)
    {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.caption.weight(.medium))
        .foregroundStyle(.orange)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.black.opacity(0.56), in: Capsule())
        .overlay { Capsule().stroke(.orange.opacity(0.28), lineWidth: 1) }
    }
  }
}

enum MediaAvailabilityPresentation {
  static func message(for item: CatalogItemSummary) -> String? {
    message(availability: item.availability, libraryAvailability: item.libraryAvailability)
  }

  static func message(
    availability: MediaAvailability, libraryAvailability: LibraryAvailability?
  ) -> String? {
    switch libraryAvailability {
    case .unavailable: return "Media drive disconnected"
    case .error: return "Media access unavailable"
    case .unknown, .available, nil: break
    }
    switch availability {
    case .available: return nil
    case .missing: return "Media file unavailable"
    case .error: return "Media access unavailable"
    }
  }

  static func canPlay(_ item: CatalogItemSummary) -> Bool {
    item.kind != .series && message(for: item) == nil
  }
}

enum MediaWatchPresentation {
  static func isWatched(_ item: CatalogItemSummary) -> Bool {
    if let state = item.watchState { return state == .completed }
    return item.progress?.isCompleted == true
  }
}

struct ErrorBanner: View {
  let message: String
  var retry: (() -> Void)?
  var retryLabel = "Try Again"
  var retryDisabled = false

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(message)
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let retry {
        Button(retryLabel, action: retry)
          .disabled(retryDisabled)
      }
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
