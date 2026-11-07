import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.aureliaReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      AureliaBackdrop()

      Group {
        if model.isImportPreviewUITest {
          #if DEBUG
            ImportPreviewView.uiTestFixture
          #endif
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
            if case .waking = model.connectionStatus {
              Button("Stop Waiting") { model.stopWaitingForServer() }
                .accessibilityIdentifier("server-stop-waiting")
            }
          }
          .accessibilityIdentifier("startup-progress")
        } else if model.operatingMode == nil {
          OperatingModeView()
        } else if model.operatingMode == .host && model.profile == nil {
          NativeHostSetupView()
        } else if model.isSwitchingProfile {
          ProgressView("Switching Profile…")
            .accessibilityIdentifier("profile-switch-progress")
        } else if model.requiresProfileSelection {
          ProfilePickerView()
        } else if model.needsInitialLibrarySetup, model.canManageStorage {
          InitialLibrarySetupView()
        } else if model.profile == nil {
          ConnectionView()
        } else {
          LibraryShellView()
        }
      }
      .accessibilityHidden(model.playback != nil || model.isSettingsPresented)

      if model.isSettingsPresented {
        AppSettingsView()
          .transition(
            reduceMotion
              ? .opacity : .opacity.combined(with: .scale(scale: 0.985, anchor: .center)))
          .zIndex(5)
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
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.isResting)
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
