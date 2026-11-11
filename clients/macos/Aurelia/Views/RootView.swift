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
        // Fading and a short slide only: scaling the whole window of text and controls made
        // macOS redraw every frame and stutter.
        AppSettingsView(initialCategory: model.requestedSettingsCategory)
          .transition(
            reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10))
          )
          // Opened while a title plays (⌘, or the menu), Settings cover the player too; Done or
          // Esc returns to it. Below the player they were invisible until it closed.
          .zIndex(model.playback == nil ? 5 : 11)
      }

      // Movie Night and Wrapped take the whole window, over the library and Settings.
      if model.playback == nil, let launch = model.movieNightLaunch, let api = model.profileClient() {
        MovieNightView(api: api, joining: launch.joining)
          .id(launch.id)
          .transition(.opacity)
          .zIndex(8)
      }
      if model.playback == nil, let launch = model.wrappedLaunch {
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
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.isSettingsPresented)
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
    .onReceive(NotificationCenter.default.publisher(for: .aureliaShowIntroduction)) { _ in
      model.isSettingsPresented = false
      introductionReplay = UUID()
    }
    // A server this Mac hosts that stopped for being unused starts again when Aurelia is opened.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
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

/// Says what opening Aurelia is doing: reaching the server, waking it, loading the library.
struct ServerConnectionStatusText: View {
  let status: ServerConnectionStatus?
  let serverName: String?

  var body: some View {
    VStack(spacing: 8) {
      switch status {
      case .waking(let since):
        Text("Waking \(name)…")
          .font(.title2.weight(.semibold))
        Text("It was asleep and usually answers within half a minute.")
          .font(.callout)
          .foregroundStyle(.secondary)
        TimelineView(.periodic(from: since, by: 1)) { context in
          Text("\(max(0, Int(context.date.timeIntervalSince(since)))) s")
            .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
      case .loading:
        Text("Opening Aurelia")
          .font(.title2.weight(.semibold))
        Text("Loading your library from \(name)…")
          .font(.callout)
          .foregroundStyle(.secondary)
      case .connecting:
        Text("Opening Aurelia")
          .font(.title2.weight(.semibold))
        Text("Connecting to \(name)…")
          .font(.callout)
          .foregroundStyle(.secondary)
      case nil:
        Text("Opening Aurelia")
          .font(.title2.weight(.semibold))
        Text("Preparing your private library…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: 420)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("server-connection-status")
  }

  private var name: String { serverName ?? "your server" }
}
