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

  static var isRunningHostedUnitTests: Bool {
    #if DEBUG
      return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        && IOSUITestScenario.current == nil
    #else
      return false
    #endif
  }

  #if DEBUG
    static func fixture(scenario: IOSUITestScenario) -> Self {
      let defaults = UserDefaults(suiteName: "Tarven.IOS.Fixture.\(UUID().uuidString)")!
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

  static func current() -> Self {
    #if DEBUG
      if let scenario = IOSUITestScenario.current {
        let suite =
          ProcessInfo.processInfo.environment["TARVEN_IOS_UI_SUITE"]
          ?? "Tarven.IOS.UI.\(UUID().uuidString)"
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
      if isRunningHostedUnitTests {
        return fixture(scenario: .library)
      }
    #endif
    return Self(
      transport: IOSURLSessionTransport(), outbox: .shared,
      makePlaybackRuntime: { .live() }, preferences: .shared,
      browsePreferences: IOSBrowsePreferenceStore(defaults: .standard), allowsDiscovery: true,
      allowsPersistentCredentials: true)
  }
}
