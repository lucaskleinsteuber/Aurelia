import Foundation

@MainActor
struct IOSAppEnvironment {
  let transport: any IOSHTTPTransport
  let outbox: IOSProgressOutbox
  let makePlaybackRuntime: @MainActor () -> IOSPlaybackRuntime
  let preferences: IOSPlaybackPreferencesStore
  let browsePreferences: IOSBrowsePreferenceStore
  let allowsDiscovery: Bool
  let allowsPersistentCredentials: Bool

  static func current() -> Self {
    #if DEBUG
      if let scenario = IOSUITestScenario.current {
        let suite =
          ProcessInfo.processInfo.environment["AURELIA_IOS_UI_SUITE"]
          ?? "Aurelia.IOS.UI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return Self(
          transport: scenario == .showcase
            ? IOSShowcaseTransport() : IOSUITestTransport(scenario: scenario),
          outbox: IOSProgressOutbox(journal: IOSDefaultsProgressJournal(defaults: defaults)),
          makePlaybackRuntime: { IOSUITestEngine.runtime(scenario: scenario) },
          preferences: IOSPlaybackPreferencesStore(defaults: defaults),
          browsePreferences: IOSBrowsePreferenceStore(defaults: defaults), allowsDiscovery: false,
          allowsPersistentCredentials: false)
      }
    #endif
    return Self(
      transport: IOSURLSessionTransport(), outbox: .shared,
      makePlaybackRuntime: { .live() }, preferences: .shared,
      browsePreferences: IOSBrowsePreferenceStore(defaults: .standard), allowsDiscovery: true,
      allowsPersistentCredentials: true)
  }
}
