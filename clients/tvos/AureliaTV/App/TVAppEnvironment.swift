import Foundation

@MainActor
struct TVAppEnvironment {
  let transport: any TVHTTPTransport
  let outbox: TVProgressOutbox
  let makePlaybackRuntime: @MainActor () -> TVPlaybackRuntime
  let preferences: TVPlaybackPreferencesStore
  let browsePreferences: TVBrowsePreferenceStore
  let allowsDiscovery: Bool
  let allowsPersistentCredentials: Bool

  static func current() -> Self {
    #if DEBUG
      if let scenario = TVUITestScenario.current {
        let suite =
          ProcessInfo.processInfo.environment["AURELIA_TV_UI_SUITE"]
          ?? "Aurelia.TV.UI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return Self(
          transport: TVUITestTransport(scenario: scenario),
          outbox: TVProgressOutbox(journal: TVDefaultsProgressJournal(defaults: defaults)),
          makePlaybackRuntime: { TVUITestEngine.runtime(scenario: scenario) },
          preferences: TVPlaybackPreferencesStore(defaults: defaults),
          browsePreferences: TVBrowsePreferenceStore(defaults: defaults), allowsDiscovery: false,
          allowsPersistentCredentials: false)
      }
    #endif
    return Self(
      transport: TVURLSessionTransport(), outbox: .shared,
      makePlaybackRuntime: { .live() }, preferences: .shared,
      browsePreferences: TVBrowsePreferenceStore(defaults: .standard), allowsDiscovery: true,
      allowsPersistentCredentials: true)
  }
}
