import AppKit
import SwiftUI

enum AureliaDesign {
  static let canvasRGB = (red: UInt8(32), green: UInt8(35), blue: UInt8(38))
  static let pagePadding: CGFloat = 32
  static let homeRailLeadingInset: CGFloat = 32
  // Detail sections line up with the hero title and About/Information (the page padding).
  static let detailRailLeadingInset: CGFloat = pagePadding
  static let sectionSpacing: CGFloat = 30
  static let rowSpacing: CGFloat = 20
  // Corner radii: tiny for tags and thumbnails, small for rows and fields, compact for tiles,
  // card for cards and panels, hero for hero artwork. Literal radii map to the nearest one.
  static let cardRadius: CGFloat = 18
  static let tinyRadius: CGFloat = 5
  static let smallRadius: CGFloat = 8
  static let compactRadius: CGFloat = 12
  static let heroRadius: CGFloat = 24
  static let sidebarWidth: CGFloat = 236
  /// Canvas tint over the sidebar's blur; keeps labels legible above bright artwork.
  static let sidebarTint: Double = 0.66
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

  static let responsiveSpring = AureliaMotion.quick
}

/// Aurelia's motion: a handful of curves for everything that moves, so the whole app moves
/// alike. `press` for a button or card under the pointer, `quick` for hover and small toggles,
/// `standard` for content that changes in place (lists, sections, something that finished
/// loading), `page` for pages and full-window layers, `emphasis` for a moment worth celebrating.
/// With Reduce Motion every one of them becomes the same short fade (`reduced`).
enum AureliaMotion {
  static let press = Animation.spring(response: 0.22, dampingFraction: 0.72)
  static let quick = Animation.spring(response: 0.3, dampingFraction: 1)
  static let standard = Animation.smooth(duration: 0.32)
  static let page = Animation.spring(response: 0.42, dampingFraction: 0.86)
  static let emphasis = Animation.spring(response: 0.5, dampingFraction: 0.72)
  static let reduced = Animation.easeOut(duration: 0.15)

  static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
    reduceMotion ? reduced : animation
  }

  /// Content arriving in place: a fade with a short rise; with Reduce Motion only the fade.
  static func arrival(reduceMotion: Bool) -> AnyTransition {
    reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8))
  }
}

/// Animates changes of `value` with one of Aurelia's curves, honoring Reduce Motion.
struct AureliaAnimated<Value: Equatable>: ViewModifier {
  let animation: Animation
  let value: Value
  @Environment(\.aureliaReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.animation(AureliaMotion.resolved(animation, reduceMotion: reduceMotion), value: value)
  }
}

/// For buttons that draw their own look: they give way a little under the pointer, like cards,
/// instead of doing nothing (the plain style) or dimming.
struct AureliaPressableButtonStyle: ButtonStyle {
  @Environment(\.aureliaReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.8 : 1)
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
      .animation(reduceMotion ? nil : AureliaMotion.press, value: configuration.isPressed)
  }
}

/// A dark, blurred panel like the Apple TV app's sidebar: artwork and rails that pass beneath it
/// stay softly visible. Reduce Transparency falls back to the opaque canvas.
struct AureliaSidebarBackground: View {
  @Environment(\.aureliaReduceTransparency) private var reduceTransparency

  var body: some View {
    if reduceTransparency {
      AureliaDesign.canvas
    } else {
      ZStack {
        Rectangle().fill(.ultraThinMaterial)
        AureliaDesign.canvas.opacity(AureliaDesign.sidebarTint)
        // Bright hero artwork sits at the top, so the tint deepens there.
        LinearGradient(
          stops: [
            .init(color: AureliaDesign.canvas.opacity(0.5), location: 0),
            .init(color: AureliaDesign.canvas.opacity(0.0), location: 0.6),
          ],
          startPoint: .top, endPoint: .bottom)
      }
      .environment(\.colorScheme, .dark)
    }
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
    private let controls = AureliaWindowControls()
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
      controls.attach(to: window)
      window.contentView?.needsLayout = true
      #if DEBUG
        if !configuredFixtureSize, ShowcaseUITestFixture.enabled {
          configuredFixtureSize = true
          window.setContentSize(NSSize(width: 1440, height: 900))
          window.center()
        }
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

/// Settings rows read the same on every page: the label (and its explanation below it) on the
/// left, the switch on the right, as on the server pages. Set once for all of Settings.
struct AureliaSettingToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .center, spacing: 16) {
      configuration.label
        .frame(maxWidth: .infinity, alignment: .leading)
      Toggle("", isOn: configuration.$isOn)
        .labelsHidden()
        .toggleStyle(.switch)
    }
    .accessibilityRepresentation {
      Toggle(isOn: configuration.$isOn) { configuration.label }
        .toggleStyle(.switch)
    }
  }
}

/// A labeled value or menu in Settings: the label on the left, the control on the right.
struct AureliaSettingLabeledContentStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      configuration.label
        .frame(maxWidth: .infinity, alignment: .leading)
      configuration.content
    }
  }
}

extension View {
  /// The shared row layout for Settings and its sheets.
  func aureliaSettingRows() -> some View {
    toggleStyle(AureliaSettingToggleStyle())
      .labeledContentStyle(AureliaSettingLabeledContentStyle())
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

struct AureliaDangerZoneSection<Content: View>: View {
  let title: String
  let description: String?
  let content: Content

  init(
    _ title: String = "Danger Zone",
    description: String? =
      "These actions are destructive and cannot be undone. They require the Server Password.",
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.description = description
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.red)
          .frame(width: 22)
        Text(title)
          .font(AureliaDesign.sectionTitle)
          .foregroundStyle(.red)
      }
      if let description {
        Text(description)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      content
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      AureliaDesign.canvas,
      in: RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous)
        .stroke(Color.red.opacity(0.35), lineWidth: 1)
    )
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
  @Environment(\.isEnabled) private var isEnabled
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
        .opacity(isEnabled ? 1 : 0.45)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

/// A round glass menu button. `.button` with a plain style draws the full circle and keeps the
/// whole 44 pt circle clickable; the borderless style shrinks custom labels to the bare glyph.
struct AureliaIconMenu<Content: View>: View {
  @Environment(\.aureliaReduceTransparency) private var reduceTransparency
  let symbol: String
  let label: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    Menu(content: content) {
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
        .overlay { Circle().stroke(AureliaDesign.hairline, lineWidth: 1) }
        .contentShape(Circle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel(label)
  }
}

/// The one main button of a page, sheet or row: white on the dark canvas. `compact` fits a row of
/// a list (wishes, notes) next to regular buttons.
struct AureliaPrimaryActionButtonStyle: ButtonStyle {
  var compact = false
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.aureliaReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(compact ? .callout.weight(.semibold) : nil)
      .foregroundStyle(.black.opacity(isEnabled ? 0.94 : 0.42))
      .padding(.horizontal, compact ? 12 : 18)
      .frame(minHeight: compact ? 28 : AureliaDesign.minimumControlSize)
      .background(.white.opacity(isEnabled ? 0.96 : 0.38), in: Capsule())
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
      .animation(reduceMotion ? nil : AureliaMotion.press, value: configuration.isPressed)
  }
}

struct AuthenticatedArtwork: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.displayScale) private var displayScale
  @Environment(\.aureliaReduceMotion) private var reduceMotion
  let artwork: ArtworkSummary?
  let symbol: String
  var contentMode: ContentMode = .fill
  var placeholderSymbolSize: CGFloat = 36
  @State private var image: NSImage?

  var body: some View {
    GeometryReader { geometry in
      let width = ArtworkVariantRequest.width(for: geometry.size.width, scale: displayScale)
      // Artwork already in memory is drawn in the first frame, without a placeholder.
      let shown = cachedImage(width: width) ?? image
      ZStack {
        MediaArtworkPlaceholder(symbol: symbol, symbolSize: placeholderSymbolSize)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Artwork placeholder")
          .accessibilityIdentifier("artwork-placeholder")
        if let shown {
          Image(nsImage: shown)
            .resizable()
            .aspectRatio(contentMode: contentMode)
            .transition(.opacity)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .clipped()
      .task(id: taskID(width: width)) {
        if let cached = cachedImage(width: width) {
          image = cached
          return
        }
        image = nil
        guard let artwork, let profile = model.profile else { return }
        do {
          let loaded = try await model.artworkLoader.image(
            for: artwork, profile: profile,
            width: model.libraryCapabilities.contains("artwork-variants-v1") ? width : nil)
          try Task.checkCancellation()
          // Newly loaded artwork fades in; artwork already in memory is drawn at once.
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { image = loaded }
        } catch is CancellationError {
          return
        } catch {
          image = nil
        }
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func cachedImage(width: Int) -> NSImage? {
    guard let artwork, let profile = model.profile else { return nil }
    return model.artworkLoader.cachedImage(
      for: artwork, profile: profile,
      width: model.libraryCapabilities.contains("artwork-variants-v1") ? width : nil)
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

/// Content that fades in when it first appears. It used to glide up on a staggered spring and
/// the hero artwork settled from a zoom for 1.1 s; each frame of that updated the whole window
/// and made opening a page stutter, so a page now arrives with one short fade.
/// `order` is kept for the call sites; it no longer delays anything.
struct AureliaRiseIn: ViewModifier {
  let order: Int
  @State private var shown = false

  func body(content: Content) -> some View {
    content
      .opacity(shown ? 1 : 0)
      .onAppear {
        guard !shown else { return }
        withAnimation(.easeOut(duration: 0.15)) { shown = true }
      }
  }
}

/// Lets a grid or rail move its cards to their new places when the list changes.
struct AureliaListMotion<ID: Equatable>: ViewModifier {
  let ids: ID
  @Environment(\.aureliaReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.animation(reduceMotion ? nil : AureliaMotion.standard, value: ids)
  }
}

extension View {
  func aureliaAnimation<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
    modifier(AureliaAnimated(animation: animation, value: value))
  }
  func aureliaRiseIn(_ order: Int = 0) -> some View { modifier(AureliaRiseIn(order: order)) }
  func aureliaListMotion<ID: Equatable>(_ ids: ID) -> some View {
    modifier(AureliaListMotion(ids: ids))
  }
}

/// A spinner that appears only when loading takes longer than a moment, so fast loads never
/// flash a progress indicator.
struct AureliaDelayedProgress: View {
  var controlSize: ControlSize = .large
  @State private var visible = false

  var body: some View {
    ProgressView()
      .controlSize(controlSize)
      .opacity(visible ? 1 : 0)
      .task {
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.25)) { visible = true }
      }
  }
}

/// Cards stay fully lit when pressed and sink slightly with a spring instead of dimming.
struct AureliaCardButtonStyle: ButtonStyle {
  @Environment(\.aureliaReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
      .brightness(configuration.isPressed ? -0.03 : 0)
      .animation(reduceMotion ? nil : AureliaMotion.press, value: configuration.isPressed)
  }
}

struct MediaPosterCard: View {
  @EnvironmentObject private var model: AppModel
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
        if hasBadges { badges }
      }
      .overlay {
        RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous)
          .stroke(hovering ? .white.opacity(0.35) : AureliaDesign.hairline, lineWidth: 1)
      }
      .shadow(color: .black.opacity(hovering ? 0.42 : 0), radius: 18, y: 10)

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
    .scaleEffect(hovering && !reduceMotion ? 1.035 : 1)
    .offset(y: hovering && !reduceMotion ? -3 : 0)
    .animation(
      reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.78), value: hovering
    )
    .onHover { hovering = $0 }
    .task(id: hovering) {
      // Once the pointer rests on a title, prepare its detail page so it opens complete.
      guard hovering else { return }
      try? await Task.sleep(for: .milliseconds(100))
      guard !Task.isCancelled else { return }
      model.prepareDetail(for: item)
    }
  }

  /// Favorite, unavailable and watched markers; the box is drawn only when one applies.
  private var hasBadges: Bool {
    item.isFavorite || MediaAvailabilityPresentation.message(for: item) != nil
      || MediaWatchPresentation.isWatched(item)
  }

  private var badges: some View {
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

  private var secondaryLine: String {
    if let message = MediaAvailabilityPresentation.message(for: item) { return message }
    if let year = item.year { return String(year) }
    return item.kind.displayName
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
        Text(item.year.map(String.init) ?? item.kind.displayName)
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
  static let offlineDetailNotice = "This file is offline; its details and progress are kept."

  static func isOffline(_ item: CatalogItemSummary) -> Bool {
    item.availability != .available || item.libraryAvailability == .unavailable
  }

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

/// A short question before an action that can't be undone with one click. Modal, so it also works
/// from menus and sheets.
@MainActor
enum AureliaConfirm {
  static func ask(_ title: String, _ message: String, action: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: action).hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }
}

/// Done in a sheet that only shows things: Return and Escape both close it, as every sheet does.
struct AureliaSheetDoneButton: View {
  var title = "Done"
  let action: () -> Void

  var body: some View {
    Button(title, action: action)
      .keyboardShortcut(.defaultAction)
      .background {
        Button("Close", action: action)
          .keyboardShortcut(.cancelAction)
          .opacity(0)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
  }
}

/// The one way Aurelia shows a problem: an orange sign, what went wrong and, where it helps, Try
/// Again. Floating over a page by default; `inline` places it in a settings section or a sheet.
struct ErrorBanner: View {
  let message: String
  var retry: (() -> Void)?
  var retryLabel = "Try Again"
  var retryDisabled = false
  var inline = false

  var body: some View {
    let banner = HStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(message)
        .font(.callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let retry {
        Button(retryLabel, action: retry)
          .disabled(retryDisabled)
      }
    }
    .padding(inline ? 12 : 14)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AureliaDesign.compactRadius))
    .overlay {
      RoundedRectangle(cornerRadius: AureliaDesign.compactRadius)
        .stroke(AureliaDesign.hairline, lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    if inline {
      banner.frame(maxWidth: .infinity, alignment: .leading)
    } else {
      banner
        .frame(maxWidth: 760)
        .shadow(color: .black.opacity(0.25), radius: 14, y: 7)
        .padding(.horizontal, AureliaDesign.pagePadding)
        .padding(.bottom, 18)
    }
  }
}

/// The header every sheet shares: a symbol tile, the title and one sentence saying what it is for.
struct AureliaSheetHeader: View {
  let title: String
  let subtitle: String
  let symbol: String

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: symbol).font(.title2).frame(width: 42, height: 42)
        .background(
          .white.opacity(0.075), in: RoundedRectangle(cornerRadius: AureliaDesign.compactRadius)
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.title2.bold())
          .accessibilityAddTraits(.isHeader)
        Text(subtitle).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(20)
  }
}

/// The main button of a sheet: Return runs it, it shows its busy title while it works.
struct AureliaSheetAction {
  let title: String
  var busyTitle: String?
  var isBusy = false
  var isDisabled = false
  var role: ButtonRole?
  let action: () -> Void
}

/// The frame every sheet shares: a header saying what it is for, the content, an error banner
/// above the footer, and a footer with an optional note or side action, Cancel (Escape) and the
/// main action (Return). Without a main action the footer shows Done, which Escape also closes.
struct AureliaSheet<Content: View, Leading: View>: View {
  let title: String
  let subtitle: String
  let symbol: String
  var errorMessage: String?
  var retry: (() -> Void)?
  var primary: AureliaSheetAction?
  var cancelTitle = "Cancel"
  let onCancel: () -> Void
  @ViewBuilder var leading: () -> Leading
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(spacing: 0) {
      AureliaSheetHeader(title: title, subtitle: subtitle, symbol: symbol)
      Divider()
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      if let errorMessage {
        ErrorBanner(message: errorMessage, retry: retry, inline: true)
          .padding(.horizontal, 20)
          .padding(.vertical, 10)
      }
      Divider()
      HStack(spacing: 10) {
        leading()
        Spacer(minLength: 12)
        if let primary {
          Button(cancelTitle, action: onCancel)
            .keyboardShortcut(.cancelAction)
          Button(role: primary.role, action: primary.action) {
            HStack(spacing: 6) {
              if primary.isBusy { ProgressView().controlSize(.small) }
              Text(primary.isBusy ? (primary.busyTitle ?? primary.title) : primary.title)
            }
          }
          .buttonStyle(AureliaPrimaryActionButtonStyle(compact: true))
          .keyboardShortcut(.defaultAction)
          .disabled(primary.isDisabled || primary.isBusy)
        } else {
          AureliaSheetDoneButton(
            title: cancelTitle == "Cancel" ? "Done" : cancelTitle, action: onCancel)
        }
      }
      .padding(16)
    }
    .background(AureliaBackdrop())
  }
}

extension AureliaSheet where Leading == EmptyView {
  init(
    title: String, subtitle: String, symbol: String, errorMessage: String? = nil,
    retry: (() -> Void)? = nil, primary: AureliaSheetAction? = nil, cancelTitle: String = "Cancel",
    onCancel: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(
      title: title, subtitle: subtitle, symbol: symbol, errorMessage: errorMessage, retry: retry,
      primary: primary, cancelTitle: cancelTitle, onCancel: onCancel, leading: { EmptyView() },
      content: content)
  }
}
