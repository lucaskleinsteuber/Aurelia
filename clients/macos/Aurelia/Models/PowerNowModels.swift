import Foundation

/// What this server can do now, from `GET /api/v1/server/power/now` ("power-now-v1").
struct PowerNowOptions: Decodable, Equatable, Sendable {
  let actions: [String]
}

/// Servers from 2.16.0 to 2.22 listed the same actions in their Smart Home overview.
struct LegacyPowerNowOptions: Decodable, Equatable, Sendable {
  let powerActions: [String]
}

struct PowerNowResult: Decodable, Sendable {
  let action: String
  let message: String
}

/// The words of Settings › Power › Right Now, the same as in the browser and the Linux app.
enum PowerNowText {
  static let capability = "power-now-v1"
  /// The name older servers (2.16.0 to 2.22) gave the same feature, under Smart Home.
  static let legacyCapability = "automation-v1"

  static func isOffered(by capabilities: Set<String>) -> Bool {
    capabilities.contains(capability) || capabilities.contains(legacyCapability)
  }

  /// The actions in the server's order, without ones this app has no words for.
  static func known(_ actions: [String]) -> [String] {
    actions.filter { ["sleep", "shutdown", "stop"].contains($0) }
  }

  static func title(_ action: String) -> String {
    switch action {
    case "sleep": "Sleep Now"
    case "shutdown": "Turn Off Now"
    default: "Stop Aurelia Now"
    }
  }

  static func detail(_ action: String) -> String {
    switch action {
    case "sleep": "The computer sleeps; Wake-on-LAN wakes it in about 10 to 20 seconds."
    case "shutdown": "The computer turns off; Wake-on-LAN starts it in about 30 to 60 seconds."
    default: "Only Aurelia Server stops."
    }
  }
}
