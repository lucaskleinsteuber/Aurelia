import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ZStack {
      AureliaBackdrop()

      Group {
        if model.isStarting {
          VStack(spacing: 16) {
            ProgressView()
              .controlSize(.large)
            Text("Opening Aurelia")
              .font(.headline)
              .foregroundStyle(.secondary)
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
    .animation(.easeInOut(duration: 0.2), value: model.playback)
    .preferredColorScheme(.dark)
    .frame(minWidth: 760, minHeight: 560)
    .sheet(isPresented: $model.isMediaManagerPresented) {
      MediaManagerView().environmentObject(model)
    }
  }
}
