import SwiftUI

struct IOSPlaybackSettingsView: View {
  @EnvironmentObject private var model: IOSAppModel
  @State private var value = IOSPlaybackPreferences.defaultValue
  @State private var error: String?
  @State private var loaded = false
  var body: some View {
    HStack(alignment: .top, spacing: IOSDesign.s(90)) {
      VStack(spacing: IOSDesign.s(26)) {
        Image(systemName: "play.rectangle.fill").font(.system(size: IOSDesign.s(150)))
          .symbolRenderingMode(.hierarchical).foregroundStyle(.white.opacity(0.85))
        Text("Playback").font(.system(size: IOSDesign.s(48), weight: .bold))
        Text("These settings apply to this profile on this device.")
          .font(.system(size: IOSDesign.s(24))).foregroundStyle(.secondary).multilineTextAlignment(
            .center)
      }.frame(width: IOSDesign.s(560)).padding(.top, IOSDesign.s(140))
      // One row style for every setting, like the player menus: Select toggles a
      // switch or moves to the next value. No nested system form styling.
      ScrollView {
        VStack(spacing: IOSDesign.s(14)) {
          row(
            "Automatic Resume", value: value.automaticResume ? "On" : "Off", id: "settings-resume"
          ) { value.automaticResume.toggle() }
          row(
            "Automatically Play Next Episode",
            value: value.automaticallyPlayNextEpisode ? "On" : "Off",
            id: "settings-next"
          ) { value.automaticallyPlayNextEpisode.toggle() }
          row("Night Mode", value: value.nightMode ? "On" : "Off", id: "settings-night-mode") {
            value.nightMode.toggle()
          }
          Spacer().frame(height: IOSDesign.s(18))
          row(
            "Default Playback Rate", value: String(format: "%gx", value.defaultPlaybackRate),
            id: "settings-rate"
          ) {
            value.defaultPlaybackRate = Self.next(
              after: value.defaultPlaybackRate, in: IOSPlaybackPreferences.supportedRates)
          }
          row(
            "Controls Auto-Hide Delay", value: "\(Int(value.controlsDelay)) seconds",
            id: "settings-delay"
          ) { value.controlsDelay = Self.next(after: value.controlsDelay, in: [2.0, 4, 6, 8]) }
          row("Seek Interval", value: "\(value.seekInterval) seconds", id: "settings-seek") {
            value.seekInterval = Self.next(after: value.seekInterval, in: [5, 10, 15, 30, 60])
          }
          Spacer().frame(height: IOSDesign.s(18))
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
          if let error { IOSErrorText(message: error).padding(.top, IOSDesign.s(10)) }
        }.padding(.vertical, IOSDesign.s(30)).padding(.horizontal, IOSDesign.s(20))
      }.frame(maxWidth: .infinity)
    }.padding(.horizontal, IOSDesign.pagePadding).padding(.top, IOSDesign.s(20))
      .background(IOSDesign.canvas.ignoresSafeArea())
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
      HStack(spacing: IOSDesign.s(20)) {
        Text(title)
        Spacer(minLength: 20)
        if let value { Text(value).opacity(0.7).monospacedDigit() }
      }.padding(.horizontal, IOSDesign.s(30)).frame(maxWidth: .infinity, minHeight: IOSDesign.s(72))
    }
    .buttonStyle(IOSButtonStyle(kind: .row)).accessibilityIdentifier(id)
    .accessibilityValue(value ?? "")
  }

  private static func next<Value: Equatable>(after current: Value, in values: [Value]) -> Value {
    guard let index = values.firstIndex(of: current) else { return values[0] }
    return values[(index + 1) % values.count]
  }
}
