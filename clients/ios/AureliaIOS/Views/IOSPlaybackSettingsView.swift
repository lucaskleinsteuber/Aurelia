import SwiftUI

/// Playback settings of this profile on this device, as a native iOS form.
struct IOSPlaybackSettingsView: View {
  @EnvironmentObject private var model: IOSAppModel
  @State private var value = IOSPlaybackPreferences.defaultValue
  @State private var error: String?
  @State private var loaded = false
  @State private var confirmForget = false

  var body: some View {
    Form {
      Section {
        Toggle("Automatic Resume", isOn: $value.automaticResume)
          .accessibilityIdentifier("settings-resume")
        Toggle("Play Next Episode Automatically", isOn: $value.automaticallyPlayNextEpisode)
          .accessibilityIdentifier("settings-next")
        Picker("Dialogue Boost", selection: $value.dialogueBoost) {
          ForEach(DialogueBoost.allCases, id: \.self) { Text($0.title).tag($0) }
        }.accessibilityIdentifier("settings-dialogue-boost")
        Picker("Volume Leveling", selection: $value.volumeLeveling) {
          ForEach(VolumeLeveling.allCases, id: \.self) { Text($0.title).tag($0) }
        }.accessibilityIdentifier("settings-volume-leveling")
      } footer: {
        Text(
          "Emphasize speech and reduce differences between quiet and loud passages. Sleep applies stronger volume leveling."
        )
      }
      if model.supportsAdaptiveStreaming {
        Section {
          Picker("Streaming Quality", selection: $value.streamingQuality) {
            ForEach(IOSStreamingQuality.allCases) { Text($0.title).tag($0) }
          }.accessibilityIdentifier("settings-streaming-quality")
        } footer: {
          Text(
            "Original plays the file itself. The other choices let the server convert the title while it plays, in the quality your connection carries, which helps away from home."
          )
        }
      }
      Section {
        Picker("Playback Rate", selection: $value.defaultPlaybackRate) {
          ForEach(IOSPlaybackPreferences.supportedRates, id: \.self) { rate in
            Text(rate == 1 ? "Normal" : String(format: "%gx", rate)).tag(rate)
          }
        }.accessibilityIdentifier("settings-rate")
        Picker("Skip Forward and Back", selection: $value.seekInterval) {
          ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) seconds").tag($0) }
        }.accessibilityIdentifier("settings-seek")
        Picker("Hide Controls After", selection: $value.controlsDelay) {
          ForEach([2.0, 4, 6, 8], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
        }.accessibilityIdentifier("settings-delay")
      }
      Section {
        Button("Forget Audio and Subtitle Choices") { confirmForget = true }
          .accessibilityIdentifier("settings-forget-tracks")
        Button("Restore Defaults", role: .destructive) { value = .defaultValue }
          .accessibilityIdentifier("settings-defaults")
      } footer: {
        if let error {
          Text(error).foregroundStyle(.orange)
        } else {
          Text("These settings apply to this profile on this device.")
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle("Playback")
    .confirmationDialog(
      "Forget the sound and subtitle choices Aurelia remembered for each series?",
      isPresented: $confirmForget, titleVisibility: .visible
    ) {
      Button("Forget Choices", role: .destructive) {
        value.preferredAudioTrack = nil
        value.preferredSubtitleTrack = nil
        if let server = model.connection?.serverID, let profile = model.session?.user.id {
          model.environment.preferences.forgetSeriesChoices(serverID: server, profileID: profile)
        }
      }
    }
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
