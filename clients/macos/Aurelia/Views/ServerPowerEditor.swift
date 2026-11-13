import SwiftUI

/// Settings › Power: what the server does when nobody uses Aurelia. A Linux package server can
/// stop Aurelia, sleep or turn off its computer and wake on the network; a server Aurelia hosts on
/// a Mac or Linux PC can only stop after the unused minutes, because a desktop or laptop is often
/// off or elsewhere. Hidden where the server can't act on it.
struct ServerPowerEditor: View {
  @EnvironmentObject private var model: AppModel
  let client: APIClient
  @State private var stored: ServerPowerSettings?
  @State private var draft: ServerPowerSettings?
  @State private var working = false
  @State private var message: String?
  /// Set after a load that came back without settings (a server before 1.8.4) or failed.
  @State private var loadFailed = false
  @State private var unsupported = false

  static let idleChoices = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240]

  var body: some View {
    Group {
      if let stored, stored.available, let draft {
        AureliaSettingsSection(
          "When Nobody Uses Aurelia",
          symbol: "leaf",
          description: draft.hostedByApp
            ? "Aurelia Server runs inside the Aurelia app on \(draft.hostName). It can stop when nobody uses it, so the computer may sleep."
            : "What the server computer does while nobody watches, browses or changes anything."
        ) {
          VStack(alignment: .leading, spacing: 12) {
            Picker("When Unused", selection: binding(\.mode)) {
              ForEach(Self.modes(hostedByApp: draft.hostedByApp), id: \.self) { mode in
                Text(Self.label(mode: mode, hostedByApp: draft.hostedByApp)).tag(mode)
              }
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("server-power-mode")
            Text(Self.explanation(draft.mode, hostedByApp: draft.hostedByApp, hostName: draft.hostName))
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if draft.mode != "off" {
              Divider()
              Picker("After", selection: binding(\.idleMinutes)) {
                ForEach(idleChoices(including: draft.idleMinutes), id: \.self) { minutes in
                  Text(Self.label(minutes)).tag(minutes)
                }
              }
              .frame(maxWidth: 320)
              Text(
                "Without anyone watching, browsing or changing settings on any device. An app that is only open doesn't count, and nothing happens while a title plays."
              )
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              Toggle("Also After a Sleep Timer Ends", isOn: afterSleepTimer)
                .accessibilityIdentifier("server-power-sleep-timer")
              Text(
                "When a player's sleep timer ends and nothing plays for five more minutes, it happens right away, at any time of day."
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
                Text(Self.awakeHoursNote(draft))
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
              Button("Save") { save() }
                .disabled(draft == stored || !isValid(draft))
              if working { ProgressView().controlSize(.small) }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
          }
          .frame(maxWidth: .infinity, alignment: .leading).disabled(working)
        }
        .accessibilityIdentifier("server-power")
        if let check = draft.wakeCheck {
          ServerWakeCheckSection(items: check)
        }
      } else if stored != nil {
        Text(
          "This server can't save power from Aurelia: it follows its computer's own energy settings."
        )
        .foregroundStyle(.secondary)
      } else if unsupported {
        Text("Power settings need Aurelia Server 1.8.4 or newer. Update the server to use them.")
          .foregroundStyle(.secondary)
      } else if loadFailed {
        // A failed load used to leave the page empty; it now says so and can try again.
        VStack(alignment: .leading, spacing: 8) {
          Text(message ?? "The power settings couldn't be loaded.")
            .foregroundStyle(.orange).textSelection(.enabled)
          Button("Try Again") { Task { await load() } }
        }
      } else {
        ProgressView("Loading power settings…")
      }
    }
    .task(id: model.administrationGeneration) { await load() }
  }

  private func load() async {
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    loadFailed = false
    unsupported = false
    message = nil
    do {
      let settings = try await model.currentAdministration {
        try await scope.request { try await client.serverPower() }
      }
      stored = settings
      draft = settings
    } catch let failure as APIClientError where failure.httpStatus == 404 {
      // Servers before 1.8.4 have no sleep mode settings.
      stored = nil
      unsupported = true
    } catch is CancellationError {
      // A newer load of this page runs instead, unless the page itself went away.
      if !Task.isCancelled { loadFailed = true }
    } catch {
      message = scope.message(for: error) ?? error.localizedDescription
      loadFailed = true
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

  private var afterSleepTimer: Binding<Bool> {
    Binding(get: { draft?.afterSleepTimer ?? true }, set: { draft?.afterSleepTimer = $0 })
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

  /// A server in the Aurelia app can only keep running or stop; a Linux server can do all four.
  static func modes(hostedByApp: Bool) -> [String] {
    hostedByApp ? ["off", "stop"] : ["off", "stop", "sleep", "shutdown"]
  }

  static func label(mode: String, hostedByApp: Bool) -> String {
    switch mode {
    case "stop": hostedByApp ? "Stop Aurelia Server" : "Stop Only Aurelia Server"
    case "sleep": "Put the Computer to Sleep"
    case "shutdown": "Shut Down the Computer"
    default: "Keep Running"
    }
  }

  static func explanation(_ mode: String, hostedByApp: Bool = false, hostName: String = "the server computer")
    -> String
  {
    switch (mode, hostedByApp) {
    case ("stop", true):
      "Aurelia Server stops, and \(hostName) may sleep as usual. Other devices then show “Start Aurelia on \(hostName)”; opening Aurelia there starts it again. Nothing can wake it over the network."
    case ("stop", false):
      "Only Aurelia Server stops; the computer stays on for its other work, such as a NAS. It starts again within seconds when any device connects, a browser too."
    case ("sleep", _):
      "The whole computer sleeps: fans and disks stop, and it uses only a few watts. Aurelia on a Mac wakes it when you open it, and so can a router such as a FRITZ!Box (Wake-on-LAN); an Apple TV can't, so open Aurelia on a Mac first. Waking takes about 10 to 20 seconds. Usually the best choice."
    case ("shutdown", _):
      "The computer turns off and uses almost nothing. Aurelia on a Mac starts it with Wake-on-LAN, which takes 30 to 60 seconds because the whole computer starts up, and only if its BIOS allows Wake-on-LAN while it is off (see the check below)."
    default:
      hostedByApp
        ? "Aurelia Server runs as long as the Aurelia app does. While the computer sleeps or is turned off, other devices show “Start Aurelia on \(hostName)”."
        : "Aurelia Server and the computer keep running: ready at any moment, using the most power."
    }
  }

  static func awakeHoursNote(_ settings: ServerPowerSettings) -> String {
    switch settings.mode {
    case "stop" where settings.hostedByApp: "Aurelia Server never stops during these hours."
    case "stop": "Aurelia Server never stops during these hours."
    default:
      "It never powers down during these hours and wakes itself at their start, so an Apple TV finds it then."
    }
  }

  static func label(_ minutes: Int) -> String {
    if minutes < 60 || minutes % 60 != 0 { return "\(minutes) minutes" }
    return minutes == 60 ? "1 hour" : "\(minutes / 60) hours"
  }
}

/// Settings › Power › Wake-on-LAN Check: what the server knows about being woken in the chosen
/// mode, with what to change and what only a test shows.
struct ServerWakeCheckSection: View {
  let items: [ServerWakeCheckItem]

  var body: some View {
    AureliaSettingsSection(
      "Wake-on-LAN Check",
      symbol: "checkmark.shield",
      description:
        "Aurelia on a Mac, Linux PC, iPhone or iPad wakes the server with a Wake-on-LAN call. What this server knows about it, for the choice above:"
    ) {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(items, id: \.title) { item in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: Self.symbol(item.state))
              .foregroundStyle(Self.color(item.state))
              .accessibilityLabel(Self.label(item.state))
            VStack(alignment: .leading, spacing: 2) {
              Text(item.title).fontWeight(.semibold)
              Text(item.detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .accessibilityElement(children: .combine)
        }
        Text(ServerPowerSettings.wakeCheckFooter)
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier("server-wake-check")
  }

  static func symbol(_ state: ServerWakeCheckItem.State) -> String {
    switch state {
    case .ok: "checkmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .problem: "xmark.octagon.fill"
    case .info: "info.circle"
    }
  }

  static func color(_ state: ServerWakeCheckItem.State) -> Color {
    switch state {
    case .ok: .green
    case .warning: .orange
    case .problem: .red
    case .info: .secondary
    }
  }

  static func label(_ state: ServerWakeCheckItem.State) -> String {
    switch state {
    case .ok: "Fine"
    case .warning: "Check this"
    case .problem: "Problem"
    case .info: "Note"
    }
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
