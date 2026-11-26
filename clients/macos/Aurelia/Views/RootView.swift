import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.aureliaReduceMotion) private var reduceMotion
  @State private var introductionReplay: UUID?

  private var guide: SetupGuide { model.setupGuide }

  /// Which of the screens below is showing; a change fades from one to the next.
  private var phase: String {
    if model.isImportPreviewUITest { return "fixture" }
    if model.offlineMode != nil { return "offline" }
    if model.isStarting { return "starting" }
    if model.operatingMode == nil { return guide.introSeen ? "mode" : "intro" }
    if model.operatingMode == .host && model.profile == nil { return "host-setup" }
    if model.isSwitchingProfile { return "switching" }
    if model.requiresProfileSelection { return "profiles" }
    if model.needsInitialLibrarySetup, model.canManageStorage { return "first-library" }
    if model.profile == nil { return "connect" }
    if guide.isGuiding { return "finish" }
    return "library"
  }

  var body: some View {
    ZStack {
      AureliaBackdrop()

      Group {
        if model.isImportPreviewUITest {
          #if DEBUG
            ImportPreviewView.uiTestFixture
          #endif
        } else if model.offlineMode != nil {
          OfflineModeView()
        } else if model.isStarting {
          VStack(spacing: 22) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
              .font(.system(size: 46, weight: .medium))
              .symbolRenderingMode(.hierarchical)
              .foregroundStyle(.white.opacity(0.86))
            ServerConnectionStatusText(
              status: model.connectionStatus, serverName: model.profile?.name)
            ProgressView()
              .controlSize(.small)
            HStack(spacing: 12) {
              if case .waking = model.connectionStatus {
                Button("Stop Waiting") { model.stopWaitingForServer() }
                  .accessibilityIdentifier("server-stop-waiting")
              }
              WatchOfflineButton()
            }
          }
          .accessibilityIdentifier("startup-progress")
        } else if model.operatingMode == nil {
          if guide.introSeen {
            OperatingModeView()
          } else {
            SetupIntroductionView(guide: guide)
          }
        } else if model.operatingMode == .host && model.profile == nil {
          NativeHostSetupView().setupStep(.secure, guide: guide, hosting: true)
        } else if model.isSwitchingProfile {
          ProgressView("Switching Profile…")
            .accessibilityIdentifier("profile-switch-progress")
        } else if model.requiresProfileSelection {
          ProfilePickerView()
            .setupStep(
              model.isLocalHost ? .pin : .profile, guide: guide, hosting: model.isLocalHost)
        } else if model.needsInitialLibrarySetup, model.canManageStorage {
          InitialLibrarySetupView().setupStep(.media, guide: guide, hosting: true)
        } else if model.profile == nil {
          ConnectionView().setupStep(.connect, guide: guide, hosting: false)
        } else if guide.isGuiding {
          SetupFinishView(
            guide: guide, offersPeople: SetupFinishView.offersPeople(model: model, guide: guide))
        } else {
          LibraryShellView()
        }
      }
      // Moving between starting, choosing a profile and the library fades instead of cutting.
      .id(phase)
      .transition(.opacity)
      // Under Settings the library isn't drawn: its hero and blurred sidebar no longer redraw
      // with every frame of Settings (audit M3). It keeps its state and shows again at once.
      .opacity(
        model.isSettingsPresented && model.playback == nil && model.offlineMode == nil
          && model.movieNightLaunch == nil && model.wrappedLaunch == nil ? 0 : 1
      )
      .accessibilityHidden(
        model.playback != nil || model.isSettingsPresented || model.movieNightLaunch != nil
          || model.wrappedLaunch != nil)

      if let replay = introductionReplay {
        SetupIntroductionView(guide: guide, replay: true) { introductionReplay = nil }
          .id(replay)
          .transition(.opacity)
          .zIndex(6)
      }

      if model.isSettingsPresented, model.offlineMode == nil {
        // Settings appear at once, as System Settings does. Building the whole window of text and
        // controls while it faded and slid made every frame redraw and stutter (audit M3).
        AppSettingsView(initialCategory: model.requestedSettingsCategory)
          .transition(.identity)
          // Opened while a title plays or during Movie Night / Wrapped (⌘, or the menu), Settings
          // cover the full-window overlay too; Done or Esc returns to it.
          .zIndex(
            AppMenuCommandPolicy.settingsCoversFullWindowOverlay(
              isPlaying: model.playback != nil,
              isInMovieNight: model.movieNightLaunch != nil,
              isInWrapped: model.wrappedLaunch != nil) ? 11 : 5)
      }

      // Movie Night and Wrapped take the whole window, over the library and Settings.
      if model.playback == nil, !model.requiresProfileSelection,
        let launch = model.movieNightLaunch, let api = model.profileClient()
      {
        MovieNightView(api: api, joining: launch.joining)
          .id(launch.id)
          .transition(.opacity)
          .zIndex(8)
      }
      if model.playback == nil, !model.requiresProfileSelection, let launch = model.wrappedLaunch {
        WrappedStoryView(launch: launch)
          .id(launch.id)
          .transition(.opacity)
          .zIndex(9)
      }

      if let profile = model.profile, let playback = model.playback {
        PlayerView(profile: profile, presentation: playback)
          // A new title (such as one a Watch Together party moved to) gets a new player.
          .id(playback.id)
          .transition(.opacity)
          .zIndex(10)
      }

      if model.isResting || model.isLeavingRest {
        AureliaRestView()
          .transition(.opacity)
          .zIndex(20)
      }
    }
    .background(AureliaWindowChrome())
    .aureliaFullWindowCanvas()
    .aureliaRemoveEmptyWindowToolbar()
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.playback)
    .animation(nil, value: model.isSettingsPresented)
    .onChange(of: model.isSettingsPresented) { _, presented in
      if !presented, model.playback != nil {
        NotificationCenter.default.post(name: .aureliaPlayerReclaimKeyboard, object: nil)
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.isResting)
    .aureliaAnimation(AureliaMotion.page, value: model.movieNightLaunch)
    .aureliaAnimation(AureliaMotion.page, value: model.wrappedLaunch)
    .aureliaAnimation(AureliaMotion.standard, value: phase)
    .preferredColorScheme(.dark)
    // While playing, the window may shrink to a 16:9 picture-in-picture size; a library minimum
    // combined with the 16:9 ratio would leave macOS no valid size when the edge is dragged.
    .frame(
      minWidth: model.playback == nil ? 760 : 320, minHeight: model.playback == nil ? 560 : 180
    )
    // Switching profile or server from Settings shows that screen instead.
    .onChange(of: model.requiresProfileSelection) { _, selecting in
      if selecting { model.isSettingsPresented = false }
    }
    .onChange(of: model.profile?.serverId) { _, _ in model.isSettingsPresented = false }
    .sheet(isPresented: $model.isMediaManagerPresented) {
      MediaManagerView().environmentObject(model)
    }
    .sheet(isPresented: $model.isKeyboardShortcutsPresented) {
      KeyboardShortcutsSheet()
    }
    .sheet(item: $model.downloadChoice) { choice in
      DownloadQualitySheet(choice: choice).environmentObject(model)
    }
    .onReceive(NotificationCenter.default.publisher(for: .aureliaShowIntroduction)) { _ in
      model.isSettingsPresented = false
      introductionReplay = UUID()
    }
    // A server this Mac hosts that stopped for being unused starts again when Aurelia is opened.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      Task { await model.resumeIdleHost() }
    }
    .task { await model.resumeIdleHost() }
  }
}

/// Watch Downloads Offline: offered while Aurelia looks for, wakes or waits for its server, when
/// this Mac has downloads of it.
struct WatchOfflineButton: View {
  @EnvironmentObject private var model: AppModel
  var prominent = false

  var body: some View {
    if model.canOfferOfflineMode {
      if prominent {
        button.buttonStyle(AureliaPrimaryActionButtonStyle())
      } else {
        button.buttonStyle(.bordered)
      }
    }
  }

  private var button: some View {
    Button {
      model.openOfflineMode()
    } label: {
      Label("Watch Downloads Offline", systemImage: "arrow.down.circle")
    }
    .help("Stop looking for the server and show only the titles downloaded to this Mac")
    .accessibilityIdentifier("open-offline-mode")
  }
}

extension Notification.Name {
  /// Settings › About › Show Introduction.
  static let aureliaShowIntroduction = Notification.Name("AureliaShowIntroduction")
}

extension View {
  /// Puts the guided setup's step bar above a setup screen while the assistant guides.
  func setupStep(_ step: SetupStep, guide: SetupGuide, hosting: Bool) -> some View {
    modifier(SetupStepModifier(step: step, guide: guide, hosting: hosting))
  }
}

private struct SetupStepModifier: ViewModifier {
  let step: SetupStep
  @ObservedObject var guide: SetupGuide
  let hosting: Bool

  func body(content: Content) -> some View {
    content.overlay(alignment: .top) {
      if guide.isGuiding {
        let steps = guide.steps(hosting: hosting)
        SetupStepBar(steps: steps, current: step) {
          guide.skip()
        }
        .padding(.top, 14)
      }
    }
  }
}

/// Readable elapsed time and guidance on the server wake screen.
enum ServerWakeStatusPresentation {
  static func elapsedText(seconds: Int) -> String {
    let clamped = max(0, seconds)
    if clamped < 60 { return "\(clamped) s" }
    let hours = clamped / 3_600
    let minutes = (clamped % 3_600) / 60
    let remainingSeconds = clamped % 60
    if hours > 0 {
      return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h"
    }
    return remainingSeconds > 0 ? "\(minutes) min \(remainingSeconds) s" : "\(minutes) min"
  }

  static func guidance(elapsedSeconds: Int) -> String {
    if elapsedSeconds >= 120 {
      return
        "This is taking longer than usual. Check that the server computer is turned on and Wake-on-LAN is enabled, or choose Stop Waiting."
    }
    return
      "From sleep it usually answers within half a minute. If it was turned off, the computer needs one to two minutes to start."
  }
}

/// Says what opening Aurelia is doing: reaching the server, waking it, loading the library.
struct ServerConnectionStatusText: View {
  @Environment(\.aureliaContrast) private var contrast
  let status: ServerConnectionStatus?
  let serverName: String?

  var body: some View {
    VStack(spacing: 8) {
      switch status {
      case .waking(let since):
        Text("Waking \(name)…")
          .font(.title2.weight(.semibold))
        TimelineView(.periodic(from: since, by: 1)) { context in
          let elapsed = max(0, Int(context.date.timeIntervalSince(since)))
          VStack(spacing: 8) {
            Text(ServerWakeStatusPresentation.guidance(elapsedSeconds: elapsed))
              .font(.callout)
              .foregroundStyle(AureliaDesign.mutedText(for: contrast))
            Text(ServerWakeStatusPresentation.elapsedText(seconds: elapsed))
              .font(.footnote.monospacedDigit())
              .foregroundStyle(AureliaDesign.subtleText(for: contrast))
          }
        }
      case .loading:
        Text("Opening Aurelia")
          .font(.title2.weight(.semibold))
        Text("Loading your library from \(name)…")
          .font(.callout)
          .foregroundStyle(AureliaDesign.mutedText(for: contrast))
      case .connecting:
        Text("Opening Aurelia")
          .font(.title2.weight(.semibold))
        Text("Connecting to \(name)…")
          .font(.callout)
          .foregroundStyle(AureliaDesign.mutedText(for: contrast))
      case nil:
        Text("Opening Aurelia")
          .font(.title2.weight(.semibold))
        Text("Preparing your private library…")
          .font(.callout)
          .foregroundStyle(AureliaDesign.mutedText(for: contrast))
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: 420)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("server-connection-status")
  }

  private var name: String { serverName ?? "your server" }
}
