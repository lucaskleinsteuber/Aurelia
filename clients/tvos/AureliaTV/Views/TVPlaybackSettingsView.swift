import SwiftUI

struct TVPlaybackSettingsView: View {
  @EnvironmentObject private var model: TVAppModel
  @State private var value = TVPlaybackPreferences.defaultValue
  @State private var error: String?
  @State private var loaded = false
  var body: some View {
    HStack(alignment: .top, spacing: 90) {
      VStack(spacing: 26) {
        Image(systemName: "play.rectangle.fill").font(.system(size: 150))
          .symbolRenderingMode(.hierarchical).foregroundStyle(.white.opacity(0.85))
        Text("Playback").font(.system(size: 48, weight: .bold))
        Text("These settings apply to this profile on this Apple TV.")
          .font(.system(size: 24)).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }.frame(width: 560).padding(.top, 140)
      // One row style for every setting, like the player menus: Select toggles a
      // switch or moves to the next value. No nested system form styling.
      ScrollView {
        VStack(spacing: 14) {
          row(
            "Automatic Resume", value: value.automaticResume ? "On" : "Off", id: "settings-resume"
          ) { value.automaticResume.toggle() }
          row(
            "Automatically Play Next Episode",
            value: value.automaticallyPlayNextEpisode ? "On" : "Off",
            id: "settings-next"
          ) { value.automaticallyPlayNextEpisode.toggle() }
          row("Intros", value: value.introSkipping.title, id: "settings-intros") {
            value.introSkipping = Self.next(after: value.introSkipping, in: TVIntroSkipping.allCases)
          }
          row(
            "Offer Next Episode When Credits Begin", value: value.upNextAtCredits ? "On" : "Off",
            id: "settings-up-next-credits"
          ) { value.upNextAtCredits.toggle() }
          if model.capabilities?.supportsSuggestions == true {
            row(
              "Play Suggestions Automatically",
              value: value.playSuggestionsAutomatically ? "On" : "Off",
              id: "settings-play-suggestions"
            ) { value.playSuggestionsAutomatically.toggle() }
          }
          if model.capabilities?.supportsCinema == true {
            Spacer().frame(height: 18)
            row("Cinema Mode", value: value.cinemaMode ? "On" : "Off", id: "settings-cinema") {
              value.cinemaMode.toggle()
            }
            if value.cinemaMode {
              row("Ads", value: value.cinemaAds ? "On" : "Off", id: "settings-cinema-ads") {
                value.cinemaAds.toggle()
              }
              row(
                "Trailers",
                value: value.cinemaTrailers == 0
                  ? "None" : value.cinemaTrailers == 1 ? "1 Trailer" : "\(value.cinemaTrailers) Trailers",
                id: "settings-cinema-trailers"
              ) { value.cinemaTrailers = (value.cinemaTrailers + 1) % 4 }
              Text(
                "Before a film that starts from the beginning: one of Aurelia's made-up ads (nothing is for sale), trailers of films nobody has watched yet, and the curtain."
              )
              .font(.system(size: 22)).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            }
          }
          row("Dialogue Boost", value: value.dialogueBoost.title, id: "settings-dialogue-boost") {
            value.dialogueBoost = Self.next(after: value.dialogueBoost, in: DialogueBoost.allCases)
          }
          row("Volume Leveling", value: value.volumeLeveling.title, id: "settings-volume-leveling")
          {
            value.volumeLeveling = Self.next(
              after: value.volumeLeveling, in: VolumeLeveling.allCases)
          }
          if model.supportsAdaptiveStreaming {
            row("Streaming Quality", value: value.streamingQuality.title, id: "settings-streaming-quality") {
              value.streamingQuality = Self.next(after: value.streamingQuality, in: TVStreamingQuality.allCases)
            }
          }
          Spacer().frame(height: 18)
          row(
            "Default Playback Rate", value: String(format: "%gx", value.defaultPlaybackRate),
            id: "settings-rate"
          ) {
            value.defaultPlaybackRate = Self.next(
              after: value.defaultPlaybackRate, in: TVPlaybackPreferences.supportedRates)
          }
          row(
            "Controls Auto-Hide Delay", value: "\(Int(value.controlsDelay)) seconds",
            id: "settings-delay"
          ) { value.controlsDelay = Self.next(after: value.controlsDelay, in: [2.0, 4, 6, 8]) }
          row("Seek Interval", value: "\(value.seekInterval) seconds", id: "settings-seek") {
            value.seekInterval = Self.next(after: value.seekInterval, in: [5, 10, 15, 30, 60])
          }
          Spacer().frame(height: 18)
          row("Forget Audio & Subtitle Preferences", value: nil, id: "settings-forget-tracks") {
            value.preferredAudioTrack = nil
            value.preferredSubtitleTrack = nil
            if let server = model.connection?.serverID, let profile = model.session?.user.id {
              model.environment.preferences.forgetSeriesChoices(
                serverID: server, profileID: profile)
            }
          }
          row("Restore Playback Defaults", value: nil, id: "settings-defaults") {
            value = .defaultValue
          }
          if let error { TVErrorText(message: error).padding(.top, 10) }
        }.padding(.vertical, 30).padding(.horizontal, 20)
      }.frame(maxWidth: .infinity).focusSection()
    }.padding(.horizontal, TVDesign.pagePadding).padding(.top, 20)
      .background(TVDesign.canvas.ignoresSafeArea())
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

  private func row(_ title: String, value: String?, id: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      HStack(spacing: 20) {
        Text(title)
        Spacer(minLength: 20)
        if let value { Text(value).opacity(0.7).monospacedDigit() }
      }.padding(.horizontal, 30).frame(maxWidth: .infinity, minHeight: 72)
    }
    .buttonStyle(TVButtonStyle(kind: .row)).accessibilityIdentifier(id)
    .accessibilityValue(value ?? "")
  }

  private static func next<Value: Equatable>(after current: Value, in values: [Value]) -> Value {
    guard let index = values.firstIndex(of: current) else { return values[0] }
    return values[(index + 1) % values.count]
  }
}
