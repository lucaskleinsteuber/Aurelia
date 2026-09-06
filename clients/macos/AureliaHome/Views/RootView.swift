import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ZStack {
      AureliaHomeBackdrop()

      if model.isStarting {
        VStack(spacing: 16) {
          ProgressView()
            .controlSize(.large)
          Text("Opening Aurelia Home")
            .font(.headline)
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("startup-progress")
      } else if model.profile == nil {
        ConnectionView()
      } else {
        LibraryShellView()
      }
    }
    .preferredColorScheme(.dark)
    .frame(minWidth: 760, minHeight: 560)
  }
}
