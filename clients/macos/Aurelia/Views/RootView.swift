import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      AureliaBackdrop()

      Group {
        if model.isStarting {
          VStack(spacing: 22) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
              .font(.system(size: 46, weight: .medium))
              .symbolRenderingMode(.hierarchical)
              .foregroundStyle(.white.opacity(0.86))
            VStack(spacing: 8) {
              Text("Opening Aurelia")
                .font(.title2.weight(.semibold))
              Text("Preparing your private library…")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            ProgressView()
              .controlSize(.small)
          }
          .accessibilityIdentifier("startup-progress")
        } else if model.operatingMode == nil {
          OperatingModeView()
        } else if model.operatingMode == .host && model.profile == nil {
          NativeHostSetupView()
        } else if model.needsInitialLibrarySetup {
          InitialLibrarySetupView()
        } else if model.profile == nil {
          ConnectionView()
        } else {
          LibraryShellView()
        }
      }
      .accessibilityHidden(model.playback != nil)

      if let profile = model.profile, let playback = model.playback {
        PlayerView(profile: profile, presentation: playback)
          .transition(.opacity)
          .zIndex(10)
      }
    }
    .background(AureliaWindowChrome())
    .aureliaFullWindowCanvas()
    .aureliaRemoveEmptyWindowToolbar()
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.playback)
    .preferredColorScheme(.dark)
    .frame(minWidth: 760, minHeight: 560)
    .sheet(isPresented: $model.isMediaManagerPresented) {
      MediaManagerView().environmentObject(model)
    }
  }
}
