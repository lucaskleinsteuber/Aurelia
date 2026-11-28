#if DEBUG
  import AppKit
  import Combine
  import SwiftUI

  /// Lets an offscreen render reach page state that only clicks or typing change otherwise.
  @MainActor enum AuditRenderSignals {
    static let search = PassthroughSubject<String, Never>()
    static let openCollection = PassthroughSubject<UUID, Never>()
    static let chooseProfile = PassthroughSubject<WatchingProfile, Never>()
  }

  @MainActor private final class AuditRenderEnvironment: ObservableObject {
    @Published var contrast = false
    @Published var reduceTransparency = false
  }

  private struct AuditRenderHost: View {
    @ObservedObject var environment: AuditRenderEnvironment
    let content: AnyView

    var body: some View {
      content
        .environment(\.auditRenderIncreasedContrast, environment.contrast)
        .environment(\.auditRenderReduceTransparency, environment.reduceTransparency)
    }
  }

  /// scripts/audit-render-screens.sh: draws Mac app screens with AuditRenderFixture's invented
  /// library into windows that are never shown, and writes each picture as a PNG frame to the
  /// standard output Launch Services opened for the script. No system setting, no network, no
  /// playback (the player uses the simulated engine of every UI test mode).
  @MainActor enum AuditScreenRenderer {
    struct Screen {
      let name: String
      let scenario: AuditRenderScenario
      /// Drawn at its own size, like a sheet, instead of at window sizes.
      var sheet = false
      /// Also drawn 1280 points wide and 3000 tall (dark only), for pages that scroll.
      var tall = false
      /// Built again for every picture, for screens that change by themselves (player controls
      /// hide after a few seconds).
      var rebuildsForEachPicture = false
      var empty = false
      var failing = false
      var content: @MainActor (AppModel) -> AnyView = {
        AnyView(RootView().environmentObject($0))
      }
      var prepare: @MainActor (AppModel) async -> Void = { _ in }
    }

    struct Variant {
      let name: String
      let appearance: NSAppearance.Name
      let contrast: Bool
      let reduceTransparency: Bool
    }

    static let allVariants = [
      Variant(name: "light", appearance: .aqua, contrast: false, reduceTransparency: false),
      Variant(name: "dark", appearance: .darkAqua, contrast: false, reduceTransparency: false),
      Variant(
        name: "dark-contrast", appearance: .accessibilityHighContrastDarkAqua, contrast: true,
        reduceTransparency: false),
      Variant(
        name: "dark-reducedtransparency", appearance: .darkAqua, contrast: false,
        reduceTransparency: true),
      Variant(
        name: "light-contrast", appearance: .accessibilityHighContrastAqua, contrast: true,
        reduceTransparency: false),
      Variant(
        name: "light-reducedtransparency", appearance: .aqua, contrast: false,
        reduceTransparency: true),
    ]

    private static var hiddenWindowTask: Task<Void, Never>?
    private static var manifest: [[String: String]] = []

    static func launch() {
      Task { @MainActor in await run() }
    }

    private static func setting(_ name: String) -> String? {
      ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func run() async {
      // The app's own window is never shown: every render uses a window that is never ordered in.
      NSApp.setActivationPolicy(.accessory)
      hiddenWindowTask = Task { @MainActor in
        while !Task.isCancelled {
          for window in NSApp.windows where window.isVisible {
            window.alphaValue = 0
            window.orderOut(nil)
          }
          try? await Task.sleep(for: .milliseconds(50))
        }
      }
      let sizes: [(String, NSSize)] =
        (setting("AURELIA_AUDIT_RENDER_SIZES")
        ?? "1280x800,760x560,1920x1080").split(separator: ",").compactMap { label in
          let parts = label.split(separator: "x").compactMap { Double($0) }
          return parts.count == 2 ? (String(label), NSSize(width: parts[0], height: parts[1])) : nil
        }
      let variantNames =
        (setting("AURELIA_AUDIT_RENDER_VARIANTS")
        ?? "light,dark,dark-contrast,dark-reducedtransparency").split(separator: ",").map(
          String.init)
      let variants = variantNames.compactMap { name in allVariants.first { $0.name == name } }
      let only = setting("AURELIA_AUDIT_RENDER_ONLY").map {
        Set($0.split(separator: ",").map(String.init))
      }
      let scale = Double(setting("AURELIA_AUDIT_RENDER_SCALE") ?? "1") ?? 1
      let list = screens.filter { only?.contains($0.name) ?? true }
      emit(kind: "log", name: "start", Data("\(list.count) screens".utf8))
      for screen in list {
        await render(screen, sizes: sizes, variants: variants, scale: scale)
      }
      let json =
        (try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]))
        ?? Data()
      emit(kind: "json", name: "manifest", json)
      hiddenWindowTask?.cancel()
      exit(0)
    }

    private struct Stage {
      let model: AppModel
      let environment: AuditRenderEnvironment
      let host: NSView
      let window: NSWindow
    }

    private static func stage(_ screen: Screen, size: NSSize, variant: Variant?) async -> Stage {
      AuditRenderFixture.emptyData = screen.empty
      AuditRenderFixture.failing = false
      let model = AppModel.auditRenderModel(screen.scenario)
      AuditRenderFixture.failing = screen.failing
      let environment = AuditRenderEnvironment()
      environment.contrast = variant?.contrast ?? false
      environment.reduceTransparency = variant?.reduceTransparency ?? false
      let host = NSHostingView(
        rootView: AuditRenderHost(environment: environment, content: screen.content(model)))
      let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      window.appearance = NSAppearance(named: variant?.appearance ?? .darkAqua)
      window.contentView = host
      host.frame = NSRect(origin: .zero, size: size)
      try? await Task.sleep(for: .milliseconds(screen.rebuildsForEachPicture ? 300 : 1200))
      await screen.prepare(model)
      try? await Task.sleep(for: .milliseconds(screen.rebuildsForEachPicture ? 500 : 1300))
      return Stage(model: model, environment: environment, host: host, window: window)
    }

    private static func dismantle(_ stage: Stage, _ screen: Screen) {
      stage.window.contentView = nil
      stage.window.close()
      AuditRenderFixture.failing = false
      AuditRenderFixture.emptyData = false
      if case .setupFinish = screen.scenario { stage.model.setupGuide.skip() }
    }

    private static func render(
      _ screen: Screen, sizes: [(String, NSSize)], variants: [Variant], scale: Double
    ) async {
      let first = sizes.first?.1 ?? NSSize(width: 1280, height: 800)
      var jobs: [(String, NSSize?, Variant)] = []
      if screen.sheet {
        jobs = variants.map { ("sheet", nil, $0) }
      } else {
        for size in sizes { for variant in variants { jobs.append((size.0, size.1, variant)) } }
        if screen.tall, let dark = variants.first(where: { $0.name == "dark" }) {
          jobs.append(("1280x3000-tall", NSSize(width: 1280, height: 3000), dark))
        }
      }
      var shared: Stage?
      for (label, fixedSize, variant) in jobs {
        let current: Stage
        if screen.rebuildsForEachPicture {
          current = await stage(screen, size: fixedSize ?? first, variant: variant)
        } else if let shared {
          current = shared
        } else {
          current = await stage(screen, size: first, variant: variant)
          shared = current
        }
        let host = current.host
        current.window.appearance = NSAppearance(named: variant.appearance)
        current.environment.contrast = variant.contrast
        current.environment.reduceTransparency = variant.reduceTransparency
        var size = fixedSize ?? first
        if fixedSize == nil {
          host.frame = NSRect(origin: .zero, size: NSSize(width: 1200, height: 900))
          host.layoutSubtreeIfNeeded()
          let fitting = host.fittingSize
          size = NSSize(
            width: min(max(fitting.width, 320), 1920), height: min(max(fitting.height, 200), 1400))
        }
        current.window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(450))
        host.layoutSubtreeIfNeeded()
        let name = "\(screen.name)__\(label)__\(variant.name)"
        if let png = snapshot(host, scale: scale) {
          emit(kind: "png", name: name, png.data)
          manifest.append([
            "file": "\(name).png", "screen": screen.name, "size": label,
            "points": "\(Int(size.width))x\(Int(size.height))", "appearance": variant.name,
            "uniform": png.uniform ? "yes" : "no",
          ])
        } else {
          manifest.append(["file": "", "screen": screen.name, "error": "snapshot failed: \(name)"])
        }
        if screen.rebuildsForEachPicture { dismantle(current, screen) }
      }
      if let shared { dismantle(shared, screen) }
      for request in AuditRenderFixture.takeUnanswered() {
        manifest.append(["file": "", "screen": screen.name, "unanswered": request])
      }
    }

    private static func snapshot(_ view: NSView, scale: Double) -> (data: Data, uniform: Bool)? {
      let bounds = view.bounds
      guard bounds.width >= 1, bounds.height >= 1,
        let bitmap = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale),
          pixelsHigh: Int(bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
          bitsPerPixel: 0)
      else { return nil }
      bitmap.size = bounds.size
      view.cacheDisplay(in: bounds, to: bitmap)
      var colors = Set<UInt32>()
      let stepX = max(1, bitmap.pixelsWide / 24)
      let stepY = max(1, bitmap.pixelsHigh / 24)
      for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
          var pixel = [Int](repeating: 0, count: 4)
          bitmap.getPixel(&pixel, atX: x, y: y)
          colors.insert(
            UInt32(pixel[0] & 0xF8) << 24 | UInt32(pixel[1] & 0xF8) << 16
              | UInt32(pixel[2] & 0xF8) << 8 | UInt32(pixel[3] & 0xF8))
        }
      }
      guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
      return (data, colors.count <= 2)
    }

    /// One frame on the standard output: a header line, then exactly `length` bytes.
    private static func emit(kind: String, name: String, _ data: Data) {
      var frame = Data("\nAURELIA-AUDIT-FRAME \(kind) \(name) \(data.count)\n".utf8)
      frame.append(data)
      try? FileHandle.standardOutput.write(contentsOf: frame)
    }

    // MARK: Screens

    private static func library(
      _ name: String, _ destination: LibraryDestination, empty: Bool = false,
      failing: Bool = false, tall: Bool = false
    ) -> Screen {
      Screen(
        name: name, scenario: empty ? .emptyLibrary : .library, tall: tall, empty: empty,
        failing: failing,
        prepare: { model in
          model.requestedDestination = destination == .home ? .library : .home
          try? await Task.sleep(for: .milliseconds(300))
          model.requestedDestination = destination
        })
    }

    private static func settings(_ category: SettingsCategory, failing: Bool = false) -> Screen {
      Screen(
        name: "settings-"
          + category.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
          + (failing ? "-error" : ""),
        scenario: .library, tall: true, failing: failing,
        content: { model in
          model.requestedSettingsCategory = category
          model.isSettingsPresented = true
          return AnyView(RootView().environmentObject(model))
        })
    }

    private static func sheet(
      _ name: String, _ make: @escaping @MainActor (AppModel) -> AnyView
    ) -> Screen {
      // Sheets open from the root view, which asks for dark, so they are drawn in dark too.
      Screen(
        name: name, scenario: .library, sheet: true,
        content: { model in
          AnyView(
            make(model).environmentObject(model).background(AureliaDesign.canvas)
              .environment(\.colorScheme, .dark))
        })
    }

    static var screens: [Screen] {
      var list: [Screen] = [
        library("home", .home, tall: true),
        library("library", .library),
        library("movies", .movies),
        library("shows", .tvShows),
        library("recently-added", .recentlyAdded),
        library("collections", .collections),
        library("watchlist", .watchlist),
        library("people", .people),
        library("wishes", .wishes, tall: true),
        library("history", .history),
        library("statistics", .statistics, tall: true),
        library("downloads", .downloads),
        Screen(
          name: "movie-detail-unicode", scenario: .library, tall: true,
          prepare: { $0.requestedMediaDetail = AuditRenderFixture.unicodeMovieID }),
        Screen(
          name: "movie-detail-long-title", scenario: .library, tall: true,
          prepare: { $0.requestedMediaDetail = AuditRenderFixture.longMovieID }),
        Screen(
          name: "movie-detail-offline", scenario: .library,
          prepare: { $0.requestedMediaDetail = AuditRenderFixture.missingMovieID }),
        Screen(
          name: "show-detail", scenario: .library, tall: true,
          prepare: { $0.requestedMediaDetail = AuditRenderFixture.seriesID }),
        Screen(
          name: "person-detail", scenario: .library, tall: true,
          prepare: { $0.requestedPersonDetail = AuditRenderFixture.person }),
        Screen(
          name: "collection-detail", scenario: .library, tall: true,
          prepare: { model in
            model.requestedDestination = .collections
            try? await Task.sleep(for: .milliseconds(500))
            if let first = model.collections.first {
              AuditRenderSignals.openCollection.send(first.id)
            }
          }),
        Screen(
          name: "search-results", scenario: .library,
          prepare: { model in
            model.requestedDestination = .library
            try? await Task.sleep(for: .milliseconds(600))
            AuditRenderSignals.search.send("Ö")
          }),
        Screen(
          name: "search-no-results", scenario: .library,
          prepare: { model in
            model.requestedDestination = .library
            try? await Task.sleep(for: .milliseconds(600))
            AuditRenderSignals.search.send("zzqxj Ünbekannt")
          }),
        Screen(
          name: "wrapped", scenario: .library,
          prepare: { $0.wrappedLaunch = WrappedLaunch(year: 2025) }),
        Screen(name: "player-controls", scenario: .player, rebuildsForEachPicture: true),
        // Empty and error states.
        library("home-empty", .home, empty: true),
        library("movies-empty", .movies, empty: true),
        library("wishes-empty", .wishes, empty: true),
        library("people-empty", .people, empty: true),
        library("collections-empty", .collections, empty: true),
        library("history-empty", .history, empty: true),
        library("movies-error", .movies, failing: true),
        library("wishes-error", .wishes, failing: true),
        Screen(
          name: "movie-detail-error", scenario: .library, failing: true,
          prepare: { $0.requestedMediaDetail = AuditRenderFixture.unicodeMovieID }),
        Screen(
          name: "home-server-unreachable", scenario: .unreachable,
          prepare: { $0.requestedDestination = .home }),
        Screen(name: "starting", scenario: .starting(nil)),
        Screen(name: "starting-connecting", scenario: .starting(.connecting)),
        Screen(name: "starting-waking", scenario: .starting(.waking(since: Date()))),
        Screen(name: "starting-loading", scenario: .starting(.loading)),
        // Profiles.
        Screen(name: "profile-picker", scenario: .profiles),
        Screen(
          name: "profile-pin-entry", scenario: .profiles,
          prepare: { model in
            if let owner = model.watchingProfiles.first {
              AuditRenderSignals.chooseProfile.send(owner)
            }
          }),
        Screen(name: "profile-picker-unreachable", scenario: .profilesUnreachable),
        // Setup.
        Screen(name: "setup-operating-mode", scenario: .operatingMode),
        Screen(name: "setup-connect", scenario: .connect),
        Screen(name: "setup-host", scenario: .hostSetup),
        Screen(name: "setup-host-starting", scenario: .hostStarting),
        Screen(name: "setup-host-failed", scenario: .hostFailed),
        Screen(name: "setup-first-library", scenario: .firstLibrary),
        Screen(name: "setup-finish", scenario: .setupFinish),
      ]
      for page in SetupIntroductionView.Page.allCases {
        list.append(
          Screen(
            name: "setup-intro-\(page)", scenario: .operatingMode,
            content: { model in
              AnyView(
                SetupIntroductionView(guide: model.setupGuide, startPage: page)
                  .environmentObject(model).preferredColorScheme(.dark))
            }))
      }
      list += SettingsCategory.allCases.map { settings($0) }
      list += [
        settings(.server, failing: true),
        settings(.profilesAndDevices, failing: true),
        sheet("sheet-keyboard-shortcuts") { _ in AnyView(KeyboardShortcutsSheet()) },
        sheet("sheet-media-manager") { _ in AnyView(MediaManagerView()) },
        sheet("sheet-collection-new") { _ in AnyView(CollectionEditorSheet(collection: nil)) },
        sheet("sheet-collection-edit") { _ in
          AnyView(CollectionEditorSheet(collection: AuditRenderFixture.collections.first))
        },
        sheet("sheet-metadata-editor") { _ in
          if let detail = AuditRenderFixture.detail(AuditRenderFixture.unicodeMovieID) {
            return AnyView(MetadataEditorSheet(metadata: detail.metadata) {})
          }
          return AnyView(EmptyView())
        },
        sheet("sheet-metadata-match") { _ in
          if let detail = AuditRenderFixture.detail(AuditRenderFixture.longMovieID) {
            return AnyView(MetadataMatchSheet(metadata: detail.metadata) {})
          }
          return AnyView(EmptyView())
        },
        sheet("sheet-profile-new") { model in
          guard let profile = model.profile else { return AnyView(EmptyView()) }
          return AnyView(ServerProfileEditor(client: APIClient(profile: profile)) {})
        },
        sheet("sheet-profile-edit") { model in
          guard let profile = model.profile else { return AnyView(EmptyView()) }
          return AnyView(
            ServerProfileEditor(
              existing: UserAccessSummary(
                user: AuditRenderFixture.memberUser, isEnabled: true, libraryIds: []),
              client: APIClient(profile: profile)
            ) {})
        },
        sheet("sheet-change-pin") { _ in AnyView(ChangeProfilePINView().padding(24)) },
      ]
      return list
    }
  }
#endif
