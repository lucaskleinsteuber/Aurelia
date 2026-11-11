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
              Text("Shut Down the Computer").tag("shutdown")
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
                  draft.mode == "stop"
                    ? "Aurelia Server never stops during these hours."
                    : "It never powers down during these hours and wakes itself at their start, so an Apple TV finds it then."
                )
                .font(.caption).foregroundStyle(.secondary)
              }
              if draft.offersWakeOnAccess {
                Toggle("Wake When a Device Connects", isOn: wakeOnAccess)
                  .accessibilityIdentifier("server-power-wake-on-access")
                Text(
                  "Opening Aurelia in a browser wakes the server too, from a device that reached it within the last minutes. Other devices still use Wake-on-LAN. Stray network traffic can wake it now and then; it powers down again after five unused minutes."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

  private var wakeOnAccess: Binding<Bool> {
    Binding(get: { draft?.wakeOnAccess ?? false }, set: { draft?.wakeOnAccess = $0 })
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
    case "shutdown":
      "The computer turns off and uses almost nothing. Aurelia on a Mac starts it with Wake-on-LAN, which takes about a minute, and only if the computer's BIOS allows Wake-on-LAN while it is off."
    default:
      "Aurelia Server keeps running all the time."
    }
  }

  static func label(_ minutes: Int) -> String {
    if minutes < 60 || minutes % 60 != 0 { return "\(minutes) minutes" }
    return minutes == 60 ? "1 hour" : "\(minutes / 60) hours"
  }
}

/// Optional server-prepared scrub preview strips stored in the server data directory.
struct ServerScrubPreviewsEditor: View {
  @EnvironmentObject private var model: AppModel
  let client: APIClient
  @State private var stored: ScrubPreviewSettings?
  @State private var draft: UpdateScrubPreviewSettingsRequest?
  @State private var working = false
  @State private var message: String?

  static let intervalChoices = [10, 15, 20, 30, 60]
  static let capChoices = [100, 250, 500, 1_000, 2_000, 5_000]

  var body: some View {
    Group {
      if let stored, let draft {
        AureliaSettingsSection(
          "Scrub Previews",
          symbol: "film.stack",
          description:
            "Small timeline preview images prepared by the server so scrubbing shows a frame right away."
        ) {
          VStack(alignment: .leading, spacing: 12) {
            if !stored.available {
              Text(
                "FFmpeg is not installed on this server, so timeline previews are decoded on each device instead."
              )
              .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Generate Previews", selection: binding(\.mode)) {
              Text("Off").tag("off")
              Text("When a Title Is Opened or Played").tag("onOpenOrPlay")
              Text("After Import").tag("afterImport")
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("server-scrub-previews-mode")
            Text(Self.explanation(draft.mode))
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if draft.mode != "off" {
              Picker("Frame Interval", selection: binding(\.intervalSeconds)) {
                ForEach(choices(Self.intervalChoices, including: draft.intervalSeconds), id: \.self)
                { seconds in
                  Text("Every \(seconds) seconds").tag(seconds)
                }
              }
              .frame(maxWidth: 320)
              Picker("Storage Limit", selection: binding(\.storageCapMegabytes)) {
                ForEach(choices(Self.capChoices, including: draft.storageCapMegabytes), id: \.self)
                { megabytes in
                  Text(Self.formatCap(megabytes)).tag(megabytes)
                }
              }
              .frame(maxWidth: 320)
            }
            Text(Self.usageSummary(stored: stored, capMegabytes: draft.storageCapMegabytes))
              .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
              .accessibilityIdentifier("server-scrub-previews-usage")
            if let progress = Self.progressSummary(stored: stored) {
              Text(progress)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityIdentifier("server-scrub-previews-progress")
            }
            HStack(spacing: 10) {
              Button("Save Scrub Preview Settings") { save() }
                .disabled(!hasChanges(draft: draft, stored: stored))
                .accessibilityIdentifier("server-scrub-previews-save")
              Button("Delete All Previews", role: .destructive) { deleteAll() }
                .disabled(stored.storedTitleCount == 0 && stored.storedBytes == 0)
                .accessibilityIdentifier("server-scrub-previews-delete")
              if working { ProgressView().controlSize(.small) }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
          }
          .frame(maxWidth: .infinity, alignment: .leading).disabled(working)
        }
        .accessibilityIdentifier("server-scrub-previews")
      }
    }
    .task(id: model.administrationGeneration) { await load() }
  }

  private func load() async {
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    do {
      let settings = try await model.currentAdministration {
        try await scope.request { try await client.serverScrubPreviews() }
      }
      apply(settings)
    } catch let failure as APIClientError where failure.httpStatus == 404 {
      stored = nil
    } catch {
      message = scope.message(for: error)
    }
  }

  private func apply(_ settings: ScrubPreviewSettings) {
    stored = settings
    draft = UpdateScrubPreviewSettingsRequest(
      mode: settings.mode,
      intervalSeconds: settings.intervalSeconds,
      storageCapMegabytes: settings.storageCapMegabytes)
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
          try await scope.request { try await client.saveServerScrubPreviews(draft) }
        }
        apply(saved)
      } catch {
        message = scope.message(for: error)
      }
    }
  }

  private func deleteAll() {
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    working = true
    message = nil
    Task {
      defer { working = false }
      do {
        let updated = try await model.currentAdministration {
          try await scope.request { try await client.deleteServerScrubPreviews() }
        }
        apply(updated)
      } catch {
        message = scope.message(for: error)
      }
    }
  }

  private func hasChanges(
    draft: UpdateScrubPreviewSettingsRequest, stored: ScrubPreviewSettings
  ) -> Bool {
    draft.mode != stored.mode
      || draft.intervalSeconds != stored.intervalSeconds
      || draft.storageCapMegabytes != stored.storageCapMegabytes
  }

  private func binding<Value>(
    _ keyPath: WritableKeyPath<UpdateScrubPreviewSettingsRequest, Value>
  ) -> Binding<Value> {
    Binding(
      get: { draft![keyPath: keyPath] },
      set: { draft?[keyPath: keyPath] = $0 })
  }

  private func choices(_ standard: [Int], including current: Int) -> [Int] {
    standard.contains(current) ? standard : (standard + [current]).sorted()
  }

  static func explanation(_ mode: String) -> String {
    switch mode {
    case "onOpenOrPlay":
      "Prepares a compact preview strip in the server data folder when a title is opened or played. Converted video is never stored."
    case "afterImport":
      "Prepares preview strips in the background after library scans, starting with the largest files, and pauses automatically while anyone is watching."
    default:
      "No preview strips are stored on disk. Timeline previews stay in memory only while scrubbing."
    }
  }

  static func formatCap(_ megabytes: Int) -> String {
    megabytes >= 1_000 && megabytes % 1_000 == 0
      ? "\(megabytes / 1_000) GB" : "\(megabytes) MB"
  }

  static func formatBytes(_ bytes: Int64) -> String {
    let megabytes = Double(max(0, bytes)) / (1_024 * 1_024)
    if megabytes == 0 { return "0 MB" }
    if megabytes < 1 { return "< 1 MB" }
    return "\(Int(megabytes.rounded())) MB"
  }

  static func usageSummary(stored: ScrubPreviewSettings, capMegabytes: Int) -> String {
    let noun = stored.storedTitleCount == 1 ? "title" : "titles"
    return
      "\(stored.storedTitleCount) \(noun) · \(formatBytes(stored.storedBytes)) of \(formatCap(capMegabytes))"
  }

  static func progressSummary(stored: ScrubPreviewSettings) -> String? {
    guard stored.activeCount > 0 || stored.pendingCount > 0 else { return nil }
    let total = max(
      stored.totalScheduledCount,
      stored.completedCount + stored.pendingCount + stored.activeCount)
    if stored.pausedForPlayback {
      return "Paused while playback is active (\(stored.completedCount) of \(total) prepared)"
    }
    return "Preparing previews… (\(stored.completedCount) of \(total))"
  }
}

/// The owner's view of video conversion: the encoder, a hint when a video chip could help but
/// isn't usable, and what converts now. Older servers without the status show nothing.
struct ServerVideoConversionCard: View {
  @EnvironmentObject private var model: AppModel
  let client: APIClient
  @State private var status: TranscodingStatus?
  @State private var message: String?

  var body: some View {
    Group {
      if let status {
        AureliaSettingsSection(
          "Video Conversion",
          symbol: "cpu",
          description:
            "Converts titles for web browsers and for apps set to a streaming quality, in memory only."
        ) {
          VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Encoder", value: status.encoderSummary)
            if let hint = status.hint {
              Label(hint, systemImage: "lightbulb")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent(
              "Converting Now",
              value: status.runningConversions == 0
                ? "None" : "\(status.runningConversions) of \(status.videoLimit) at once")
            ForEach(Array(status.sessions.enumerated()), id: \.offset) { _, session in
              LabeledContent(session.title, value: TranscodingStatus.sessionSummary(session))
                .font(.caption)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .task(id: model.administrationGeneration) { await load() }
  }

  private func load() async {
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    do {
      status = try await model.currentAdministration {
        try await scope.request { try await client.serverTranscoding() }
      }
    } catch let failure as APIClientError where failure.httpStatus == 404 {
      status = nil
    } catch {
      message = scope.message(for: error)
    }
  }
}
