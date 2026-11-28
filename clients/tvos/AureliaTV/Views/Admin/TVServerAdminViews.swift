import SwiftUI

/// Settings › Server on the Apple TV, for owners and administrators: status and restart,
/// performance, background work, power, updates, screen time, matches to review and new devices.
struct TVServerAdminView: View {
  @EnvironmentObject private var model: TVAppModel
  @StateObject private var admin = TVAdministrationModel()

  var body: some View {
    TVSettingsPage(
      symbol: "server.rack", title: "Server",
      subtitle: "Manage \(model.connection?.name ?? "the server") with the remote."
    ) {
      let owner = admin.permissions.owner
      link("Status and Health", "Running time, free space, problems, Restart.", id: "admin-status")
      {
        TVServerStatusPage(admin: admin)
      }
      if model.capabilities?.supportsServerPerformance == true {
        link("Performance", "How fast the server answers.", id: "admin-performance") {
          TVServerPerformancePage(admin: admin)
        }
      }
      if owner {
        link("Background Work", "Previews, intros, speech, conversion and jobs.", id: "admin-work")
        {
          TVBackgroundWorkPage(admin: admin)
        }
        link("Power", "What the server does when unused, and Sleep Now.", id: "admin-power") {
          TVServerPowerPage(admin: admin)
        }
        link("Server Updates", "The installed version and new ones.", id: "admin-updates") {
          TVServerUpdatesPage(admin: admin)
        }
        if model.capabilities?.supportsScreenTime == true {
          link("Screen Time", "Bedtime and daily limits for children.", id: "admin-screen-time") {
            TVScreenTimeProfilesPage(admin: admin)
          }
        }
        if model.capabilities?.supportsSecurity == true {
          link("New Devices", "Devices that signed in, That Was Me or Block.", id: "admin-devices")
          {
            TVNewDevicesPage(admin: admin)
          }
        }
      }
      link("Review Matches", "Titles whose TMDB match needs a look.", id: "admin-matches") {
        TVReviewMatchesPage(admin: admin)
      }
    }
    .tvAdministration(admin)
  }

  private func link<Destination: View>(
    _ title: String, _ detail: String, id: String, @ViewBuilder destination: () -> Destination
  ) -> some View {
    NavigationLink(destination: destination().tvAdministration(admin)) {
      VStack(alignment: .leading, spacing: 6) {
        Text(title)
        Text(detail).font(.system(size: 21)).opacity(0.65)
      }
      .padding(.horizontal, 30).padding(.vertical, 12)
      .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
    }
    .buttonStyle(TVButtonStyle(kind: .row))
    .accessibilityIdentifier(id)
  }
}

// MARK: Status and health

struct TVServerStatusPage: View {
  @ObservedObject var admin: TVAdministrationModel
  @State private var status: TVServerStatus?
  @State private var health: TVServerHealth?
  @State private var confirmRestart = false
  @State private var restarting = false

  var body: some View {
    TVSettingsPage(
      symbol: "heart.text.square", title: "Status and Health",
      subtitle: status.map { "Aurelia Server \($0.version)" } ?? "Loading…"
    ) {
      if let status {
        TVSettingsRow(title: "State", value: status.state.capitalized)
        TVSettingsRow(title: "Running For", value: TVAdminText.uptime(status.uptimeSeconds))
        TVSettingsRow(title: "Playing Now", value: "\(status.activeStreams)")
        TVSettingsRow(title: "Profiles", value: "\(status.users)")
        TVSettingsRow(title: "Storage Locations", value: "\(status.libraries)")
        TVSettingsRow(title: "Free Space", value: TVAdminText.bytes(status.freeDiskBytes))
        TVSettingsRow(title: "Database", value: TVAdminText.bytes(status.databaseBytes))
        ForEach(status.readiness?.components ?? []) { part in
          TVSettingsRow(title: part.title, value: part.state.capitalized)
        }
      }
      if let health {
        TVSettingsHeader(text: "Health")
        TVSettingsRow(title: "Offline Titles", value: "\(health.offlineMediaCount)")
        TVSettingsRow(title: "Converting Now", value: "\(health.activeLiveConversions)")
        if let scan = health.lastScan {
          TVSettingsRow(
            title: "Last Scan",
            value:
              "\(TVAdminText.jobState(scan.state)) · \(scan.addedFiles) added, \(scan.missingFiles) missing"
          )
        }
        if health.recentIssues.isEmpty {
          TVSettingsNote(text: "No problems recently.")
        } else {
          TVSettingsHeader(text: "Recent Problems")
          ForEach(health.recentIssues.prefix(8)) { issue in
            TVSettingsRow(title: TVAdminText.event(issue.code), value: TVAdminFormat.date(issue.at))
          }
        }
      }
      if admin.permissions.owner {
        TVSettingsHeader(text: "")
        TVSettingsRow(
          title: restarting ? "Restarting…" : "Restart Server", id: "admin-restart",
          role: .destructive
        ) { confirmRestart = true }
        .disabled(restarting)
      }
    }
    .task(id: admin.revision) { await load() }
    .confirmationDialog(
      "Restart the server?", isPresented: $confirmRestart, titleVisibility: .visible
    ) {
      Button("Restart", role: .destructive) { Task { await restart() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Everyone watching stops for a moment; the server is back in a few seconds.")
    }
  }

  private func load() async {
    async let loadedStatus = admin.value { try await $0.serverStatus() }
    async let loadedHealth = admin.value { try await $0.serverHealth() }
    status = await loadedStatus
    health = await loadedHealth
  }

  private func restart() async {
    restarting = true
    defer { restarting = false }
    if await admin.perform({ _ = try await $0.restartServer() }) {
      try? await Task.sleep(for: .seconds(8))
      await load()
    }
  }
}

// MARK: Performance

struct TVServerPerformancePage: View {
  @ObservedObject var admin: TVAdministrationModel
  @State private var performance: TVServerPerformance?

  var body: some View {
    TVSettingsPage(
      symbol: "speedometer", title: "Performance",
      subtitle: "Measured since \(TVAdminFormat.date(performance?.since))."
    ) {
      if let performance {
        TVSettingsRow(title: "Requests", value: performance.requests.formatted())
        TVSettingsRow(
          title: "95 % Answered Within",
          value: TVPerformanceText.duration(performance.p95Milliseconds))
        TVSettingsHeader(text: "Slowest")
        ForEach(
          performance.endpoints.sorted { $0.p95Milliseconds > $1.p95Milliseconds }.prefix(8)
        ) { endpoint in
          TVSettingsRow(
            title: "\(endpoint.method) \(TVPerformanceText.route(endpoint.route))",
            value: TVPerformanceText.duration(endpoint.p95Milliseconds))
        }
        if !performance.slowQueries.isEmpty {
          TVSettingsNote(
            text:
              "\(performance.slowQueries.count) database queries took longer than \(performance.slowQueryMilliseconds) ms."
          )
        }
        if admin.permissions.owner {
          TVSettingsHeader(text: "")
          TVSettingsRow(title: "Reset Measurements", id: "performance-reset") {
            Task { await admin.perform { try await $0.resetServerPerformance() } }
          }
        }
      }
    }
    .task(id: admin.revision) {
      performance = await admin.value { try await $0.serverPerformance() }
    }
  }
}

enum TVAdminFormat {
  static func date(_ text: String?) -> String {
    guard let text, let date = TVServerDate.parse(text) else { return "—" }
    return date.formatted(date: .abbreviated, time: .shortened)
  }
}

// MARK: Background work

struct TVBackgroundWorkPage: View {
  @EnvironmentObject private var model: TVAppModel
  @ObservedObject var admin: TVAdministrationModel
  @State private var previews: TVScrubPreviewSettings?
  @State private var segments: TVSegmentSettings?
  @State private var speech: TVServerSpeech?
  @State private var conversion: TVTranscodingStatus?
  @State private var jobs: TVServerJobs?

  var body: some View {
    TVSettingsPage(
      symbol: "gearshape.2", title: "Background Work",
      subtitle: "What the server does by itself. It all pauses while someone watches."
    ) {
      if let previews, previews.available {
        TVSettingsHeader(text: "Timeline Previews")
        TVSettingsRow(
          title: "Previews", value: Self.previewMode(previews.mode), id: "work-previews"
        ) {
          let update = TVUpdateScrubPreviews(
            mode: TVSettingsRow.next(after: previews.mode, in: ["off", "onDemand", "background"]),
            intervalSeconds: previews.intervalSeconds,
            storageCapMegabytes: previews.storageCapMegabytes)
          Task {
            if let saved = await admin.value({ try await $0.saveServerScrubPreviews(update) }) {
              self.previews = saved
            }
          }
        }
        TVSettingsRow(
          title: "Stored",
          value: "\(previews.storedTitleCount) titles · \(TVAdminText.bytes(previews.storedBytes))")
        if previews.pendingCount > 0 {
          TVSettingsRow(
            title: previews.pausedForPlayback ? "Paused While Someone Watches" : "Making Previews",
            value: "\(previews.completedCount) of \(previews.totalScheduledCount)")
        }
      }
      if model.capabilities?.supportsMediaSegments == true, let segments, segments.available {
        TVSettingsHeader(text: "Intros and Credits")
        TVSettingsRow(
          title: "Find Intros and Credits", value: segments.enabled ? "On" : "Off",
          id: "work-segments"
        ) {
          let enabled = !segments.enabled
          Task {
            if let saved = await admin.value({
              try await $0.saveServerSegments(enabled: enabled, usePictures: nil)
            }) {
              self.segments = saved
            }
          }
        }
        TVSettingsRow(
          title: segments.pausedForPlayback
            ? "Paused While Someone Watches"
            : segments.running ? (segments.currentTitle ?? "Examining…") : "Examined",
          value: "\(Int((segments.progress * 100).rounded())) %")
      }
      if model.capabilities?.supportsServerSpeech == true, let speech {
        TVSettingsHeader(text: "Speech Recognition")
        TVSettingsRow(
          title: "Speech Model",
          value: !speech.available
            ? "Not Installed"
            : speech.model.map { "\($0) · \(TVAdminText.bytes(speech.modelBytes))" } ?? "None")
        if let download = speech.downloading {
          TVSettingsRow(
            title: "Downloading \(download.name)",
            value:
              "\(TVAdminText.bytes(download.receivedBytes)) of \(TVAdminText.bytes(download.totalBytes))"
          )
        } else if speech.available, speech.model == nil {
          ForEach(speech.models) { choice in
            TVSettingsRow(
              title: "Download \(choice.label)", value: TVAdminText.bytes(choice.bytes),
              id: "work-speech-\(choice.name)"
            ) {
              Task {
                if let saved = await admin.value({ try await $0.downloadSpeechModel(choice.name) })
                {
                  self.speech = saved
                }
              }
            }
          }
        }
        ForEach(Array(speech.jobs.prefix(5).enumerated()), id: \.offset) { _, job in
          TVSettingsRow(
            title: job.title,
            value: job.pausedForPlayback ? "Paused" : "\(Int((job.progress * 100).rounded())) %")
        }
      }
      if let conversion {
        TVSettingsHeader(text: "Video Conversion")
        TVSettingsRow(title: "Encoder", value: conversion.encoderSummary)
        TVSettingsRow(title: "Converting Now", value: "\(conversion.runningConversions)")
        ForEach(Array(conversion.sessions.prefix(5).enumerated()), id: \.offset) { _, session in
          TVSettingsRow(title: session.title, value: session.quality)
        }
      }
      if let jobs {
        TVSettingsHeader(text: "Jobs")
        if jobs.scans.isEmpty && jobs.metadata.isEmpty {
          TVSettingsNote(text: "Nothing runs right now.")
        }
        ForEach(jobs.scans.prefix(5)) { scan in
          TVSettingsRow(
            title: "Scan",
            value: "\(TVAdminText.jobState(scan.state)) · \(scan.filesProcessed) files")
        }
        ForEach(jobs.metadata.prefix(8)) { job in
          if job.state == "failed" {
            TVSettingsRow(title: "Information Lookup Failed", value: "Try Again") {
              Task { await admin.perform { try await $0.retryMetadataJob(id: job.id) } }
            }
          } else {
            TVSettingsRow(
              title: "Information Lookup",
              value:
                "\(TVAdminText.jobState(job.state)) · \(job.itemsProcessed) of \(job.itemsTotal)")
          }
        }
      }
    }
    .task(id: admin.revision) { await load() }
    .task { await follow() }
  }

  static func previewMode(_ mode: String) -> String {
    switch mode {
    case "background": "Ahead of Time"
    case "onDemand": "While Playing"
    case "off": "Off"
    default: mode.capitalized
    }
  }

  private func load() async {
    let caps = model.capabilities
    async let loadedPreviews = admin.value { try await $0.serverScrubPreviews() }
    async let loadedJobs = admin.value { try await $0.serverJobs() }
    async let loadedConversion = admin.value { try await $0.serverTranscoding() }
    previews = await loadedPreviews
    jobs = await loadedJobs
    conversion = await loadedConversion
    if caps?.supportsMediaSegments == true {
      segments = await admin.value { try await $0.serverSegments() }
    }
    if caps?.supportsServerSpeech == true {
      speech = await admin.value { try await $0.serverSpeech() }
    }
  }

  /// Progress follows every five seconds while the page is open.
  private func follow() async {
    while !Task.isCancelled {
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      guard let client = admin.client else { return }
      if let value = try? await client.serverJobs() { jobs = value }
      if let value = try? await client.serverScrubPreviews() { previews = value }
      if model.capabilities?.supportsMediaSegments == true,
        let value = try? await client.serverSegments()
      {
        segments = value
      }
      if model.capabilities?.supportsServerSpeech == true,
        let value = try? await client.serverSpeech()
      {
        speech = value
      }
    }
  }
}

// MARK: Power

struct TVServerPowerPage: View {
  @EnvironmentObject private var model: TVAppModel
  @ObservedObject var admin: TVAdministrationModel
  @State private var power: TVServerPower?
  @State private var draft: TVServerPower?
  @State private var awakeHours = false
  @State private var actions: [String] = []
  @State private var confirming: String?
  @State private var saved: String?

  private static let times = (0..<48).map { String(format: "%02d:%02d", $0 / 2, $0 % 2 * 30) }

  var body: some View {
    TVSettingsPage(
      symbol: "bolt.circle", title: "Power",
      subtitle: "What the server does when nobody uses it."
    ) {
      if let power, var draft, power.available {
        let modes = TVPowerRules.modes(for: power)
        TVSettingsRow(
          title: "When Unused",
          value: modes.first { $0.id == draft.mode }?.label ?? draft.mode, id: "power-mode"
        ) {
          draft.mode = TVSettingsRow.next(after: draft.mode, in: modes.map(\.id))
          self.draft = draft
        }
        if let explanation = modes.first(where: { $0.id == draft.mode })?.explanation {
          TVSettingsNote(text: explanation)
        }
        if draft.mode != "off" {
          TVSettingsRow(title: "After", value: "\(draft.idleMinutes) minutes", id: "power-idle") {
            draft.idleMinutes = TVSettingsRow.next(
              after: draft.idleMinutes, in: TVPowerRules.idleChoices)
            self.draft = draft
          }
          TVSettingsRow(title: "Awake Hours", value: awakeHours ? "On" : "Off", id: "power-awake") {
            awakeHours.toggle()
            if awakeHours { self.draft = TVPowerRules.withDefaultAwakeHours(draft) }
          }
          if awakeHours {
            TVSettingsRow(title: "Stay Awake From", value: draft.awakeFrom ?? "07:00") {
              draft.awakeFrom = TVSettingsRow.next(
                after: draft.awakeFrom ?? "07:00", in: Self.times)
              self.draft = draft
            }
            TVSettingsRow(title: "Until", value: draft.awakeUntil ?? "23:00") {
              draft.awakeUntil = TVSettingsRow.next(
                after: draft.awakeUntil ?? "23:00", in: Self.times)
              self.draft = draft
            }
          }
        }
        TVSettingsRow(title: "Save", value: saved, id: "power-save") { Task { await save() } }
        if let check = TVPowerRules.wakeCheck(power, mode: draft.mode) {
          TVSettingsHeader(text: "Wake-on-LAN Check")
          ForEach(Array(check.enumerated()), id: \.offset) { _, item in
            VStack(alignment: .leading, spacing: 6) {
              Label(item.title, systemImage: Self.symbol(item.state))
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Self.color(item.state))
              Text(item.detail).font(.system(size: 22)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            .focusable()
          }
          TVSettingsNote(text: TVPowerRules.wakeCheckFooter)
        }
      } else if power != nil {
        TVSettingsNote(text: "This server can't change what it does when unused.")
      }
      if TVPowerNowText.isOffered(by: model.capabilities?.capabilities), !actions.isEmpty {
        TVSettingsHeader(text: "Right Now")
        ForEach(actions, id: \.self) { action in
          TVSettingsRow(
            title: TVPowerNowText.title(action), id: "power-now-\(action)", role: .destructive
          ) { confirming = action }
        }
      }
    }
    .task(id: admin.revision) { await load() }
    .confirmationDialog(
      confirming.map(TVPowerNowText.title) ?? "",
      isPresented: Binding(
        get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
      titleVisibility: .visible
    ) {
      if let action = confirming {
        Button(TVPowerNowText.title(action), role: .destructive) {
          Task { await powerNow(action) }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(confirming.map(TVPowerNowText.detail) ?? "")
    }
  }

  private static func symbol(_ state: TVPowerRules.WakeCheckItem.State) -> String {
    switch state {
    case .ok: "checkmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .problem: "xmark.octagon.fill"
    case .info: "info.circle.fill"
    }
  }

  private static func color(_ state: TVPowerRules.WakeCheckItem.State) -> Color {
    switch state {
    case .ok: .green
    case .warning: .yellow
    case .problem: .orange
    case .info: .secondary
    }
  }

  private func load() async {
    let loaded = await admin.value { try await $0.serverPower() }
    power = loaded
    draft = loaded
    awakeHours = loaded?.awakeFrom != nil && loaded?.awakeUntil != nil
    let capabilities = model.capabilities?.capabilities
    if TVPowerNowText.isOffered(by: capabilities) {
      actions = TVPowerNowText.known(
        (try? await admin.client?.powerNowActions(capabilities: capabilities)) ?? [])
    }
  }

  private func save() async {
    guard let power, let draft else { return }
    do {
      let payload = try TVPowerRules.payload(for: draft, awakeHours: awakeHours, server: power)
      if let stored = await admin.value({ try await $0.saveServerPower(payload) }) {
        self.power = stored
        self.draft = stored
        saved = "Saved"
      }
    } catch {
      admin.alert = TVAdministrationModel.message(error)
    }
  }

  /// After Sleep or Turn Off the server is gone; the app's own reconnect and wake take over.
  private func powerNow(_ action: String) async {
    guard
      let result = await admin.value({ try await $0.powerNow(action: action, force: true) })
    else { return }
    admin.alert = result.message
  }
}

// MARK: Updates

struct TVServerUpdatesPage: View {
  @ObservedObject var admin: TVAdministrationModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var status: TVServerUpdateStatus?
  @State private var confirmInstall = false
  /// The server restarts with the new version and does not answer for a moment.
  @State private var reconnecting = false

  var body: some View {
    TVSettingsPage(
      symbol: "arrow.down.circle", title: "Server Updates",
      subtitle: status.map { "Installed: \($0.installed)" } ?? "Loading…"
    ) {
      if let status {
        if !status.available {
          TVSettingsNote(
            text: status.message
              ?? "This server is updated where it runs, such as the Aurelia app or its package manager."
          )
        } else {
          TVSettingsRow(
            title: "Newest",
            value: status.newest ?? (status.updateAvailable ? "—" : status.installed))
          TVSettingsRow(title: "Checked", value: TVAdminFormat.date(status.checkedAt))
          if status.isBusy || reconnecting {
            TVServerUpdateProgressView(status: status, reconnecting: reconnecting)
          }
          if let message = status.message { TVSettingsNote(text: message) }
          TVSettingsRow(title: "Check Now", id: "updates-check") {
            guard !status.isBusy, !reconnecting else { return }
            Task {
              if let value = await admin.value({ try await $0.checkServerUpdates() }) {
                self.status = value
              }
            }
          }
          if status.updateAvailable, !status.isBusy, !reconnecting {
            TVSettingsRow(
              title: "Install \(status.newest ?? "Update")", id: "updates-install",
              role: .destructive
            ) { confirmInstall = true }
          }
        }
      }
    }
    .task { status = await admin.value { try await $0.serverUpdates() } }
    .task(id: status?.isBusy == true && scenePhase == .active) { await follow() }
    .confirmationDialog(
      "Install the update?", isPresented: $confirmInstall, titleVisibility: .visible
    ) {
      Button("Install", role: .destructive) {
        Task {
          if let value = await admin.value({ try await $0.installServerUpdate() }) {
            status = value
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The server restarts with the new version; whoever is watching stops for a moment.")
    }
  }

  /// Reads the status every 1.5 seconds while the server checks or installs. While it restarts
  /// with the new version it does not answer; that is waiting, not an error.
  private func follow() async {
    guard status?.isBusy == true, scenePhase == .active else { return }
    defer { reconnecting = false }
    while !Task.isCancelled {
      do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
      do {
        let read = try await TVAPIClient.withBackgroundRequests {
          try await admin.run { try await $0.serverUpdates() }
        }
        reconnecting = false
        status = read
        if !read.isBusy { return }
      } catch is CancellationError {
        return
      } catch {
        reconnecting = true
      }
    }
  }
}

/// The bar with the current step and percentage while the server checks or installs.
private struct TVServerUpdateProgressView: View {
  let status: TVServerUpdateStatus
  let reconnecting: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let fraction = TVServerUpdateProgress.fraction(status, reconnecting: reconnecting) {
        ProgressView(value: fraction)
      } else {
        ProgressView().progressViewStyle(.linear)
      }
      HStack(spacing: 20) {
        Text(TVServerUpdateProgress.text(status, reconnecting: reconnecting))
        Spacer(minLength: 20)
        if let percent = TVServerUpdateProgress.percent(status, reconnecting: reconnecting) {
          Text("\(percent)%").monospacedDigit()
        }
      }
      .font(.system(size: 24)).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("server-update-progress")
  }
}
