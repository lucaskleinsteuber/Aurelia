import SwiftUI

struct AppSettingsView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Server")
        .font(.title2.bold())

      if let profile = model.profile {
        LabeledContent("Name", value: profile.name)
        LabeledContent("Address", value: profile.baseURL.absoluteString)
        LabeledContent(
          "Fingerprint",
          value: FingerprintFormatter.display(profile.publicKeyFingerprint))
        Divider()
        Button("Disconnect This Mac", role: .destructive) {
          Task { await model.disconnect() }
        }
        .accessibilityIdentifier("disconnect-server")
      } else {
        ContentUnavailableView(
          "No Server Connected",
          systemImage: "network.slash",
          description: Text("Pair this Mac from the main window."))
      }
      Spacer()
    }
    .padding(24)
  }
}
