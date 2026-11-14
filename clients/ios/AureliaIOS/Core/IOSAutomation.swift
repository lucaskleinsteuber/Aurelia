import Foundation

// Smart Home ("automation-v1") on iPhone and iPad: what the player reports, webhooks for Home
// Assistant, integration keys and turning the server off now. Copied from the Mac app, not shared.

/// What the player tells the server the moment it changes.
enum IOSAutomationPlaybackState {
  static func state(wantsPlayback: Bool, isPlaying: Bool, finished: Bool) -> String {
    if finished { return "finished" }
    if !wantsPlayback { return "paused" }
    return isPlaying ? "playing" : "buffering"
  }

  /// Equal states in a row are sent once; after the end only playing again counts.
  static func shouldReport(last: String?, next: String) -> Bool {
    guard next != last else { return false }
    if last == "finished", next != "playing" { return false }
    return true
  }
}

struct IOSAutomationEventDescription: Decodable, Identifiable, Equatable, Sendable {
  let kind: String
  let title: String
  let detail: String
  var id: String { kind }
}

struct IOSAutomationChoice: Decodable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let detail: String?
}

struct IOSAutomationDelivery: Decodable, Identifiable, Equatable, Sendable {
  let id: UUID
  let webhookId: UUID
  let event: String
  let at: String
  let attempt: Int
  let state: String
  let statusCode: Int?
  let durationMilliseconds: Int?
  let error: String?
}

struct IOSAutomationWebhook: Decodable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let url: String
  let preset: String
  let events: [String]
  let deviceIds: [UUID]
  let profileIds: [UUID]
  let includeTitles: Bool
  let excludeChildren: Bool
  let enabled: Bool
  let pausedReason: String?
  let consecutiveFailures: Int
  let lastDelivery: IOSAutomationDelivery?
  let createdAt: String
}

struct IOSIntegrationToken: Decodable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let scopes: [String]
  let createdAt: String
  let lastUsedAt: String?
}

struct IOSAutomationOverview: Decodable, Equatable, Sendable {
  let webhooks: [IOSAutomationWebhook]
  let tokens: [IOSIntegrationToken]
  let events: [IOSAutomationEventDescription]
  let devices: [IOSAutomationChoice]
  let profiles: [IOSAutomationChoice]
  let wakeOnLanAddresses: [String]
  let powerActions: [String]
}

struct IOSAutomationWebhookRequest: Encodable, Equatable, Sendable {
  var name: String
  var url: String
  var preset: String
  var events: [String]
  var deviceIds: [UUID]
  var profileIds: [UUID]
  var includeTitles: Bool
  var excludeChildren: Bool
  var enabled: Bool
}

struct IOSAutomationWebhookCreated: Decodable, Sendable {
  let webhook: IOSAutomationWebhook
  let secret: String
}

struct IOSAutomationSecret: Decodable, Sendable { let secret: String }

struct IOSIntegrationTokenCreated: Decodable, Sendable {
  let token: IOSIntegrationToken
  let value: String
}

struct IOSPowerNowResult: Decodable, Sendable {
  let action: String
  let message: String
}

/// The words and rules of Settings › Smart Home, the same as in the browser.
enum IOSAutomationText {
  static let scopes: [(id: String, title: String, detail: String)] = [
    ("status", "Read What Plays", "What is playing where, and whether the server can turn off."),
    ("power", "Turn the Server Off", "Sleep, turn off or stop the server, for example from a Home Assistant button."),
    ("playback", "Control Players", "Play, pause or stop on your own devices that have Aurelia open."),
  ]

  static func powerTitle(_ action: String) -> String {
    switch action {
    case "sleep": "Sleep Now"
    case "shutdown": "Turn Off Now"
    default: "Stop Aurelia Now"
    }
  }

  static func powerDetail(_ action: String) -> String {
    switch action {
    case "sleep": "The computer sleeps; Wake-on-LAN wakes it in about 10 to 20 seconds."
    case "shutdown": "The computer turns off; Wake-on-LAN starts it in about 30 to 60 seconds."
    default: "Only Aurelia Server stops."
    }
  }

  /// Home Assistant's webhook address from its address and the trigger's ID; nil when invalid.
  static func homeAssistantURL(base: String, webhookID: String) -> String? {
    var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    let id = webhookID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !id.isEmpty,
      id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
    else { return nil }
    let withScheme = trimmed.lowercased().hasPrefix("http") ? trimmed : "http://" + trimmed
    guard var components = URLComponents(string: withScheme), let host = components.host, !host.isEmpty
    else { return nil }
    if components.port == nil, components.scheme == "http" { components.port = 8123 }
    components.path = "/api/webhook/" + id
    components.query = nil
    return components.string
  }

  static func splitHomeAssistantURL(_ url: String) -> (base: String, webhookID: String) {
    guard let range = url.range(of: "/api/webhook/") else { return ("", "") }
    return (String(url[..<range.lowerBound]), String(url[range.upperBound...]))
  }

  static func host(_ url: String) -> String {
    guard let components = URLComponents(string: url), let host = components.host else { return url }
    return components.port.map { "\(host):\($0)" } ?? host
  }

  /// One line about the last delivery.
  static func status(_ webhook: IOSAutomationWebhook) -> (warning: Bool, text: String) {
    if !webhook.enabled { return (false, "Off") }
    if webhook.pausedReason != nil { return (true, "Paused after failed deliveries") }
    guard let last = webhook.lastDelivery else { return (false, "Nothing sent yet") }
    if last.state == "succeeded" { return (false, "Last delivery \(last.durationMilliseconds ?? 0) ms") }
    return (true, last.error ?? "The last delivery failed")
  }

  /// A ready Home Assistant automation for the webhook ID.
  static func homeAssistantExample(webhookID: String) -> String {
    """
    alias: Aurelia – movie lights
    triggers:
      - trigger: webhook
        webhook_id: \(webhookID.isEmpty ? "aurelia" : webhookID)
        allowed_methods: [POST]
        local_only: true
    actions:
      - choose:
          - conditions:
              - condition: template
                value_template: "{{ trigger.json.event in ['playback.started', 'playback.resumed'] }}"
            sequence:
              - action: light.turn_on
                target: { area_id: living_room }
                data: { brightness_pct: 10, transition: 2 }
          - conditions:
              - condition: template
                value_template: "{{ trigger.json.event in ['playback.paused', 'playback.stopped', 'playback.finished'] }}"
            sequence:
              - action: light.turn_on
                target: { area_id: living_room }
                data: { brightness_pct: 70, transition: 2 }

    """
  }
}

extension IOSAPIClient {
  private static func automationID(_ value: UUID) -> String { value.uuidString.lowercased() }

  /// The player's state, the moment it changes (server 2.16.0). Never needed for playback.
  func reportPlaybackState(ticket: UUID, state: String, positionSeconds: Double) async throws {
    struct Body: Encodable {
      let state: String
      let positionSeconds: Double
    }
    _ = try await adminData(
      "/api/v1/playback/\(Self.automationID(ticket))/state", method: "POST",
      body: JSONEncoder().encode(Body(state: state, positionSeconds: positionSeconds)))
  }

  func automationOverview() async throws -> IOSAutomationOverview {
    try Self.decodeAdmin(IOSAutomationOverview.self, data: await adminData("/api/v1/server/automation"))
  }
  func createWebhook(_ request: IOSAutomationWebhookRequest) async throws -> IOSAutomationWebhookCreated {
    try Self.decodeAdmin(
      IOSAutomationWebhookCreated.self,
      data: await adminData("/api/v1/server/automation/webhooks", method: "POST", body: JSONEncoder().encode(request)))
  }
  func saveWebhook(id: UUID, _ request: IOSAutomationWebhookRequest) async throws {
    _ = try await adminData(
      "/api/v1/server/automation/webhooks/\(Self.automationID(id))", method: "PUT", body: JSONEncoder().encode(request))
  }
  func deleteWebhook(id: UUID) async throws {
    _ = try await adminData("/api/v1/server/automation/webhooks/\(Self.automationID(id))", method: "DELETE")
  }
  func testWebhook(id: UUID) async throws -> IOSAutomationDelivery {
    try Self.decodeAdmin(
      IOSAutomationDelivery.self,
      data: await adminData("/api/v1/server/automation/webhooks/\(Self.automationID(id))/test", method: "POST"))
  }
  func webhookDeliveries(id: UUID) async throws -> [IOSAutomationDelivery] {
    try Self.decodeAdmin(
      [IOSAutomationDelivery].self,
      data: await adminData(
        "/api/v1/server/automation/webhooks/\(Self.automationID(id))/deliveries",
        query: [URLQueryItem(name: "limit", value: "50")]))
  }
  func rotateWebhookSecret(id: UUID) async throws -> IOSAutomationSecret {
    try Self.decodeAdmin(
      IOSAutomationSecret.self,
      data: await adminData("/api/v1/server/automation/webhooks/\(Self.automationID(id))/secret", method: "POST"))
  }
  func createIntegrationToken(name: String, scopes: [String]) async throws -> IOSIntegrationTokenCreated {
    struct Payload: Encodable {
      let name: String
      let scopes: [String]
    }
    return try Self.decodeAdmin(
      IOSIntegrationTokenCreated.self,
      data: await adminData(
        "/api/v1/server/automation/tokens", method: "POST", body: JSONEncoder().encode(Payload(name: name, scopes: scopes))))
  }
  func revokeIntegrationToken(id: UUID) async throws {
    _ = try await adminData("/api/v1/server/automation/tokens/\(Self.automationID(id))", method: "DELETE")
  }
  func powerNow(action: String, force: Bool = false) async throws -> IOSPowerNowResult {
    struct Payload: Encodable {
      let action: String
      let force: Bool
    }
    return try Self.decodeAdmin(
      IOSPowerNowResult.self,
      data: await adminData(
        "/api/v1/server/power/now", method: "POST", body: JSONEncoder().encode(Payload(action: action, force: force))))
  }
}
