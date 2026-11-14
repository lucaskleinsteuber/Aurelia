import Foundation

// Smart Home ("automation-v1"): webhooks for Home Assistant and other receivers, integration keys
// and turning the server off now. Copies of the server's AutomationContracts.cs.

/// What the player tells the server the moment it changes.
enum AutomationPlaybackState {
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

struct AutomationEventDescription: Decodable, Identifiable, Equatable, Sendable {
  let kind: String
  let title: String
  let detail: String
  var id: String { kind }
}

struct AutomationChoice: Decodable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let detail: String?
}

struct AutomationDelivery: Decodable, Identifiable, Equatable, Sendable {
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

struct AutomationWebhook: Decodable, Identifiable, Equatable, Sendable {
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
  let lastDelivery: AutomationDelivery?
  let createdAt: String
}

struct IntegrationToken: Decodable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let scopes: [String]
  let createdAt: String
  let lastUsedAt: String?
}

struct AutomationOverview: Decodable, Equatable, Sendable {
  let webhooks: [AutomationWebhook]
  let tokens: [IntegrationToken]
  let events: [AutomationEventDescription]
  let devices: [AutomationChoice]
  let profiles: [AutomationChoice]
  let wakeOnLanAddresses: [String]
  let powerActions: [String]
}

struct AutomationWebhookRequest: Encodable, Equatable, Sendable {
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

struct AutomationWebhookCreated: Decodable, Sendable {
  let webhook: AutomationWebhook
  let secret: String
}

struct AutomationSecret: Decodable, Sendable { let secret: String }

struct IntegrationTokenCreated: Decodable, Sendable {
  let token: IntegrationToken
  let value: String
}

struct PowerNowResult: Decodable, Sendable {
  let action: String
  let message: String
}

/// The words and rules of Settings › Smart Home, the same as in the browser.
enum AutomationText {
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
  static func status(_ webhook: AutomationWebhook) -> (warning: Bool, text: String) {
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
