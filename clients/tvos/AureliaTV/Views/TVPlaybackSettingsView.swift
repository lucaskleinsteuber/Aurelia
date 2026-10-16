import SwiftUI

struct TVPlaybackSettingsView: View {
  @EnvironmentObject private var model: TVAppModel
  @State private var value = TVPlaybackPreferences.defaultValue
  @State private var error: String?
  @State private var loaded = false
  var body: some View {
    Form {
      Toggle("Automatic Resume", isOn: $value.automaticResume).accessibilityIdentifier(
        "settings-resume")
      Toggle("Automatically Play Next Episode", isOn: $value.automaticallyPlayNextEpisode)
        .accessibilityIdentifier("settings-next")
      Picker("Default Playback Rate", selection: $value.defaultPlaybackRate) {
        ForEach(TVPlaybackPreferences.supportedRates, id: \.self) {
          Text(String(format: "%gx", $0)).tag($0)
        }
      }
      Picker("Controls Auto-Hide Delay", selection: $value.controlsDelay) {
        ForEach([2.0, 4, 6, 8], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
      }
      Picker("Seek Interval", selection: $value.seekInterval) {
        ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) seconds").tag($0) }
      }.accessibilityIdentifier("settings-seek")
      Button("Forget Audio & Subtitle Preferences") {
        value.preferredAudioTrack = nil
        value.preferredSubtitleTrack = nil
      }
      Button("Restore Playback Defaults") { value = .defaultValue }
      if let error { TVErrorText(message: error) }
    }.navigationTitle("Playback").background(TVDesign.canvas)
      .onAppear {
        guard let server = model.connection?.serverID, let profile = model.session?.user.id else {
          return
        }
        value = model.environment.preferences.preferences(serverID: server, profileID: profile)
        loaded = true
      }
      .onChange(of: value) { _, value in
        guard loaded, let server = model.connection?.serverID, let profile = model.session?.user.id
        else { return }
        if !model.environment.preferences.save(value, serverID: server, profileID: profile) {
          error = "Preferences could not be saved."
        } else {
          error = nil
          model.scheduleLibraryRefresh()
        }
      }
  }
}
