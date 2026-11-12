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
      Section {
        Picker("Intros", selection: $value.introSkipping) {
          ForEach(IOSIntroSkipping.allCases) { Text($0.title).tag($0) }
        }.accessibilityIdentifier("settings-intros")
        Toggle("Offer Next Episode When Credits Begin", isOn: $value.upNextAtCredits)
          .disabled(!value.automaticallyPlayNextEpisode)
          .accessibilityIdentifier("settings-up-next-credits")
      } footer: {
        Text(
          "Your server finds where an episode's intro and credits are. Show Skip Intro offers a button while the intro plays; Skip Automatically jumps past it once per episode, but never when you go back into it yourself. Up Next appears when the credits begin, with Watch Credits."
        )
      }
      if model.capabilities?.supportsCinema == true {
        Section {
          Toggle("Cinema Mode", isOn: $value.cinemaMode)
            .accessibilityIdentifier("settings-cinema")
          if value.cinemaMode {
            Toggle("Ads", isOn: $value.cinemaAds).accessibilityIdentifier("settings-cinema-ads")
            Picker("Trailers", selection: $value.cinemaTrailers) {
              Text("None").tag(0)
              Text("1 Trailer").tag(1)
              Text("2 Trailers").tag(2)
              Text("3 Trailers").tag(3)
            }.accessibilityIdentifier("settings-cinema-trailers")
          }
        } footer: {
          Text(
            "Before a film that starts from the beginning: one of Aurelia's made-up ads (nothing is for sale), trailers of films nobody has watched yet, and the curtain."
          )
        }
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
