import Foundation

@MainActor
struct TVAppEnvironment {
  let transport: any TVHTTPTransport
  let outbox: TVProgressOutbox
  let makePlaybackRuntime: @MainActor () -> TVPlaybackRuntime
  let allowsDiscovery: Bool
  let allowsPersistentCredentials: Bool

  static func current() -> Self {
    #if DEBUG
      if let scenario = TVUITestScenario.current {
        return Self(
          transport: TVUITestTransport(scenario: scenario), outbox: TVProgressOutbox(),
          makePlaybackRuntime: { TVUITestEngine.runtime(scenario: scenario) },
          allowsDiscovery: false, allowsPersistentCredentials: false)
      }
    #endif
    return Self(
      transport: TVURLSessionTransport(), outbox: .shared,
      makePlaybackRuntime: { .live() }, allowsDiscovery: true, allowsPersistentCredentials: true)
  }
}
