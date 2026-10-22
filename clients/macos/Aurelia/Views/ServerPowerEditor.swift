import SwiftUI

/// What a Linux server installed from the package does when unused; hidden for other servers.
struct ServerPowerEditor: View {
  @EnvironmentObject private var model: AppModel
  let client: APIClient
  @State private var stored: ServerPowerSettings?
  @State private var draft: ServerPowerSettings?
  @State private var working = false
  @State private var message: String?

  static let idleChoices = [10, 15, 20, 30, 45, 60, 90, 120, 180]

  var body: some View {
    Group {
      if let stored, stored.available, let draft {
        AureliaSettingsSection(
          "Power Saving",
          symbol: "leaf",
          description: "What the server computer does while nobody watches."
        ) {
          VStack(alignment: .leading, spacing: 12) {
            Picker("When Unused", selection: binding(\.mode)) {
              Text("Keep Running").tag("off")
              Text("Stop Aurelia Server").tag("stop")
              Text("Put the Computer to Sleep").tag("sleep")
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("server-power-mode")
            Text(Self.explanation(draft.mode))
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if draft.mode != "off" {
              Picker("After", selection: binding(\.idleMinutes)) {
                ForEach(idleChoices(including: draft.idleMinutes), id: \.self) { minutes in
                  Text(Self.label(minutes)).tag(minutes)
                }
              }
              .frame(maxWidth: 320)
              Text(
                "without a device using it. When a player's sleep timer ends, this happens after five minutes."
              )
              .font(.caption).foregroundStyle(.secondary)
              Toggle("Keep Running at Set Hours", isOn: awakeHoursEnabled)
                .accessibilityIdentifier("server-power-awake-hours")
              if draft.awakeFrom != nil {
                HStack(spacing: 12) {
                  DatePicker(
                    "From", selection: time(\.awakeFrom), displayedComponents: .hourAndMinute)
                  DatePicker(
                    "Until", selection: time(\.awakeUntil), displayedComponents: .hourAndMinute)
                }
                .fixedSize()
                Text(
                  draft.mode == "sleep"
                    ? "It never sleeps during these hours and wakes itself at their start, so an Apple TV finds it then."
                    : "Aurelia Server never stops during these hours."
                )
                .font(.caption).foregroundStyle(.secondary)
              }
            }
            HStack {
              Button("Save Power Settings") { save() }
                .disabled(draft == stored || !isValid(draft))
              if working { ProgressView().controlSize(.small) }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
          }
          .frame(maxWidth: .infinity, alignment: .leading).disabled(working)
        }
        .accessibilityIdentifier("server-power")
      }
    }
    .task(id: model.administrationGeneration) { await load() }
  }

  private func load() async {
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    guard model.managementUnlocked else { return }
    do {
      let settings = try await model.currentAdministration {
        try await scope.request { try await client.serverPower() }
      }
      stored = settings
      draft = settings
    } catch let failure as APIClientError where failure.httpStatus == 404 {
      // Servers before 1.8.4 have no sleep mode settings.
      stored = nil
    } catch {
      message = scope.message(for: error)
    }
  }

  private func save() {
    guard let draft else { return }
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    working = true
    message = nil
    Task {
      defer { working = false }
      do {
        let saved = try await model.currentAdministration {
          try await scope.request { try await client.saveServerPower(draft) }
        }
        stored = saved
        self.draft = saved
      } catch {
        message = scope.message(for: error)
      }
    }
  }

  private func binding<Value>(_ keyPath: WritableKeyPath<ServerPowerSettings, Value>) -> Binding<
    Value
  > {
    Binding(
      get: { draft![keyPath: keyPath] },
      set: { draft?[keyPath: keyPath] = $0 })
  }

  private var awakeHoursEnabled: Binding<Bool> {
    Binding(
      get: { draft?.awakeFrom != nil },
      set: { enabled in
        draft?.awakeFrom = enabled ? "17:00" : nil
        draft?.awakeUntil = enabled ? "23:30" : nil
      })
  }

  /// "HH:MM" on the server; a time of today for the picker.
  private func time(_ keyPath: WritableKeyPath<ServerPowerSettings, String?>) -> Binding<Date> {
    Binding(
      get: {
        let parts = (draft?[keyPath: keyPath] ?? "00:00").split(separator: ":").compactMap {
          Int($0)
        }
        return Calendar.current.date(
          bySettingHour: parts.first ?? 0, minute: parts.last ?? 0, second: 0, of: Date())
          ?? Date()
      },
      set: { date in
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        draft?[keyPath: keyPath] = String(
          format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
      })
  }

  private func isValid(_ settings: ServerPowerSettings) -> Bool {
    (settings.awakeFrom == nil) == (settings.awakeUntil == nil)
      && (settings.awakeFrom == nil || settings.awakeFrom != settings.awakeUntil)
  }

  private func idleChoices(including current: Int) -> [Int] {
    Self.idleChoices.contains(current) ? Self.idleChoices : (Self.idleChoices + [current]).sorted()
  }

  static func explanation(_ mode: String) -> String {
    switch mode {
    case "stop":
      "Only Aurelia Server stops; the computer stays on for its other work, such as a NAS. It starts again within seconds when a Mac or Apple TV connects."
    case "sleep":
      "The whole computer sleeps and uses only a few watts. Aurelia on a Mac wakes it when you open it; an Apple TV cannot, so open Aurelia on a Mac first."
    default:
      "Aurelia Server keeps running all the time."
    }
  }

  static func label(_ minutes: Int) -> String {
    if minutes < 60 || minutes % 60 != 0 { return "\(minutes) minutes" }
    return minutes == 60 ? "1 hour" : "\(minutes / 60) hours"
  }
}
