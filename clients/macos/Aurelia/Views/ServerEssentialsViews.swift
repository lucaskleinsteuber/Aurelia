import SwiftUI

// Everyday server settings shown above the collapsed advanced settings.

struct ServerSummaryCard: View {
  @EnvironmentObject private var model: AppModel
  let status: ServerStatusSummary
  let configuration: ServerConfigurationResponse?
  let client: APIClient?
  let nativeHostAvailable: Bool
  var hosting: ServerHostingKind = .other
  let refreshing: Bool
  let refresh: () -> Void
  @State private var restarting = false
  @State private var restartTask: Task<Void, Never>?
  @State private var message: String?

  private var state: String { status.readiness?.state ?? status.state }
  private var isHealthy: Bool { ["ready", "running"].contains(state.lowercased()) }
  private var problems: [ServerComponentStatus] {
    status.readiness?.components.filter { $0.state != "ready" } ?? []
  }
  private var canRestart: Bool {
    model.isLocalHost || ((nativeHostAvailable || hosting == .linuxPackage) && client != nil)
  }

  var body: some View {
    AureliaSurface {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Image(systemName: "server.rack")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 22)
          VStack(alignment: .leading, spacing: 4) {
            Text("Your Server").font(AureliaDesign.sectionTitle)
            Text(
              [
                configuration?.active.serverName ?? model.profile?.name ?? "Aurelia Server",
                hosting.location,
              ].compactMap { $0 }.joined(separator: " · ")
            )
            .font(.callout).foregroundStyle(.secondary)
          }
          Spacer()
          HStack(spacing: 6) {
            Circle().fill(isHealthy ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(state.capitalized).font(.callout.weight(.semibold))
          }
        }
        ForEach(problems) { component in
          Label(component.detail, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
        if let configuration {
          Label(
            configuration.active.lanAccessEnabled
              ? "Devices on your home network can connect."
              : model.isLocalHost
                ? "Only this Mac can connect." : "Only the server computer itself can connect.",
            systemImage: configuration.active.lanAccessEnabled ? "wifi" : "laptopcomputer"
          )
          .foregroundStyle(.secondary)
        }
        HStack(spacing: 12) {
          fact("Profiles", "\(status.users)")
          fact("Libraries", "\(status.libraries)")
          if let bytes = status.freeDiskBytes {
            fact("Free Space", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
          }
          fact("Playing Now", "\(status.activeStreams)")
        }
        if let bytes = status.freeDiskBytes, bytes < 1024 * 1024 * 1024 {
          Label(
            "The server's disk is almost full. Backups and library updates may fail.",
            systemImage: "exclamationmark.triangle"
          ).foregroundStyle(.orange)
        }
        HStack {
          Text("Version \(status.version) · Running for \(uptime)")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Refresh") { refresh() }.disabled(refreshing)
          Button(restarting ? "Restarting…" : "Restart Server") { restart() }
            .disabled(restarting || !canRestart)
            .accessibilityIdentifier("server-restart")
        }
        if let message {
          Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onDisappear { restartTask?.cancel() }
  }

  private var uptime: String {
    Duration.seconds(max(60, status.uptimeSeconds)).formatted(
      .units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2))
  }

  private func fact(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(value).font(.title3.weight(.semibold)).monospacedDigit()
      Text(title).font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 10)
    .padding(.horizontal, 12)
    .background(
      AureliaDesign.raisedSurface,
      in: RoundedRectangle(cornerRadius: AureliaDesign.compactRadius, style: .continuous))
  }

  private func restart() {
    restarting = true
    message = nil
    restartTask = Task {
      defer {
        restarting = false
        restartTask = nil
      }
      if model.isLocalHost {
        await model.restartNativeHost()
        return
      }
      guard let client else { return }
      let scope = ServerAdministrationScope(
        model: model, generation: model.administrationGeneration)
      do {
        try await model.currentAdministration {
          _ = try await scope.request { try await client.restartServer() }
        }
        message =
          hosting == .linuxPackage
          ? "Restarting. Aurelia reconnects by itself in a few seconds."
          : "Restart requested. Reconnect after the server has restarted."
      } catch { if let failure = scope.message(for: error) { message = failure } }
    }
  }
}

struct ServerEssentialsEditor: View {
  @EnvironmentObject private var model: AppModel
  let configuration: ServerConfigurationResponse
  let client: APIClient
  let saved: (ServerConfigurationResponse) -> Void
  @State private var pairingEnabled: Bool
  @State private var automaticBackups: Bool
  @State private var lastBackup: ServerBackupSummary?
  @State private var working = false
  @State private var actionTask: Task<Void, Never>?
  @State private var message: String?

  init(
    configuration: ServerConfigurationResponse, client: APIClient,
    saved: @escaping (ServerConfigurationResponse) -> Void
  ) {
    self.configuration = configuration
    self.client = client
    self.saved = saved
    _pairingEnabled = State(initialValue: configuration.stored.pairingEnabled)
    _automaticBackups = State(initialValue: configuration.stored.automaticBackupsEnabled)
  }

  var body: some View {
    AureliaSettingsSection("Devices & Backups", symbol: "externaldrive.badge.checkmark") {
      VStack(alignment: .leading, spacing: 14) {
        ServerSwitchRow(
          "Allow new devices to connect",
          detail:
            "Turn this off once your TVs, Macs and other devices are set up. Devices that are already connected keep working.",
          isOn: $pairingEnabled, identifier: "server-pairing-enabled")
        Divider()
        ServerSwitchRow(
          "Back up automatically",
          detail:
            "Aurelia regularly saves a checked copy of its library database. Your videos are never copied.",
          isOn: $automaticBackups, identifier: "server-automatic-backups")
        HStack {
          Text(lastBackupText).font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Back Up Now") {
            run { scope in
              try await scope.request { try await client.createDatabaseBackup() }
              lastBackup = try await scope.request { try await client.serverBackups() }.first
              message = "Backup created and checked."
            }
          }
          .accessibilityIdentifier("server-backup-now")
        }
        if let message {
          Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
      .toggleStyle(.switch)
      .disabled(working)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onChange(of: pairingEnabled) { _, value in save { $0.pairingEnabled = value } }
    .onChange(of: automaticBackups) { _, value in save { $0.automaticBackupsEnabled = value } }
    .task(id: model.administrationGeneration) {
      let scope = ServerAdministrationScope(
        model: model, generation: model.administrationGeneration)
      do {
        lastBackup = try await model.currentAdministration {
          try await scope.request { try await client.serverBackups() }
        }.first
      } catch { if let failure = scope.message(for: error) { message = failure } }
    }
    .onDisappear { actionTask?.cancel() }
  }

  private var lastBackupText: String {
    guard let lastBackup else { return "No backup yet." }
    return "Last backup: \(ServerDateText.display(lastBackup.createdAt))"
  }

  private func save(_ change: (inout ServerPolicySettings) -> Void) {
    var settings = configuration.stored
    change(&settings)
    guard settings != configuration.stored, !working else { return }
    run { scope in
      do {
        saved(try await scope.request { try await client.saveServerSettings(settings) })
      } catch {
        pairingEnabled = configuration.stored.pairingEnabled
        automaticBackups = configuration.stored.automaticBackupsEnabled
        throw error
      }
    }
  }

  private func run(_ action: @escaping @MainActor (ServerAdministrationScope) async throws -> Void)
  {
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    working = true
    message = nil
    actionTask = Task {
      defer {
        working = false
        actionTask = nil
      }
      do {
        try await model.currentAdministration {
          try scope.check()
          try await action(scope)
        }
      } catch { if let failure = scope.message(for: error) { message = failure } }
    }
  }
}

/// A settings row with its switch aligned to the trailing edge, as in System Settings.
struct ServerSwitchRow: View {
  let title: String
  let detail: String?
  @Binding var isOn: Bool
  let identifier: String

  init(_ title: String, detail: String? = nil, isOn: Binding<Bool>, identifier: String = "") {
    self.title = title
    self.detail = detail
    _isOn = isOn
    self.identifier = identifier
  }

  var body: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
        if let detail {
          Text(detail).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 12)
      Toggle(title, isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .accessibilityIdentifier(identifier)
    }
  }
}

struct ServerAdvancedDisclosure<Content: View>: View {
  @Binding var isExpanded: Bool
  let content: Content

  init(isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
    _isExpanded = isExpanded
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Button {
        withAnimation(AureliaDesign.responsiveSpring) { isExpanded.toggle() }
      } label: {
        HStack(spacing: 12) {
          Image(systemName: "slider.horizontal.3")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 22)
          VStack(alignment: .leading, spacing: 3) {
            Text("Advanced Settings").font(AureliaDesign.sectionTitle)
            Text(
              "Network, limits, maintenance, backup details and diagnostics. Most people never need to change these."
            )
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(20)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .background(
        AureliaDesign.surface,
        in: RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous)
          .stroke(AureliaDesign.hairline, lineWidth: 1)
      }
      .accessibilityLabel("Advanced Settings")
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      .accessibilityIdentifier("server-advanced-settings")
      if isExpanded { content }
    }
  }
}

struct ServerDetailsBox: View {
  let status: ServerStatusSummary

  var body: some View {
    GroupBox("Server Details") {
      VStack(alignment: .leading, spacing: 10) {
        LabeledContent("State", value: (status.readiness?.state ?? status.state).capitalized)
        if let readiness = status.readiness {
          ForEach(readiness.components) { component in
            LabeledContent(component.title, value: component.detail)
              .foregroundStyle(component.state == "ready" ? .primary : .secondary)
          }
        }
        LabeledContent("Version", value: status.version)
        LabeledContent(
          "Uptime",
          value: Duration.seconds(status.uptimeSeconds).formatted(
            .time(pattern: .hourMinuteSecond)))
        LabeledContent("Active stream requests", value: "\(status.activeStreams)")
        LabeledContent(
          "Database",
          value: ByteCountFormatter.string(fromByteCount: status.databaseBytes, countStyle: .file))
        if let expires = status.certificateExpiresAt {
          LabeledContent("TLS certificate expires", value: ServerDateText.display(expires))
        }
        LabeledContent("Host addresses", value: status.networkAddresses.joined(separator: ", "))
      }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }
  }
}

enum ServerDateText {
  static func display(_ value: String) -> String {
    ServerDate.parse(value)?.formatted(date: .abbreviated, time: .shortened) ?? value
  }
}

struct ServerHealthCard: View {
  let health: ServerHealthResponse

  var body: some View {
    AureliaSurface {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("Server Health", systemImage: "heart.text.square")
            .font(AureliaDesign.sectionTitle)
          Spacer()
        }
        HStack(spacing: 12) {
          metric("Uptime", uptime)
          metric(
            "Free Disk Space",
            health.freeDiskBytes.map {
              ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "—")
          metric(
            "Database",
            ByteCountFormatter.string(fromByteCount: health.databaseBytes, countStyle: .file))
          metric(
            "Playing / Converting", "\(health.activeStreams) / \(health.activeLiveConversions)")
        }
        HStack(spacing: 12) {
          metric("Scrub Previews", scrubPreviewSummary)
          metric("Last Scan", scanSummary)
          metric("Database Backups", backupSummary)
          metric("Background Jobs", backgroundJobsSummary)
        }
        if !health.recentIssues.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("Recent Warnings & Errors").font(.caption.weight(.semibold)).foregroundStyle(
              .secondary)
            ForEach(health.recentIssues.prefix(5)) { issue in
              HStack(spacing: 8) {
                Image(
                  systemName: issue.severity == "error"
                    ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(issue.severity == "error" ? .red : .orange)
                .font(.caption)
                Text(issue.code)
                  .font(.caption.monospaced())
                Spacer()
                Text(ServerDateText.display(issue.at))
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var uptime: String {
    Duration.seconds(max(60, health.uptimeSeconds)).formatted(
      .units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2))
  }

  private var scrubPreviewSummary: String {
    if health.scrubPreviewTitleCount == 0 { return "None" }
    let bytes = ByteCountFormatter.string(
      fromByteCount: health.scrubPreviewBytes, countStyle: .file)
    return "\(health.scrubPreviewTitleCount) titles (\(bytes))"
  }

  private var scanSummary: String {
    guard let scan = health.lastScan else { return "None" }
    return "\(scan.state.capitalized) (+\(scan.addedFiles), -\(scan.missingFiles))"
  }

  private var backgroundJobsSummary: String {
    let active =
      health.backgroundJobs.activeScans + health.backgroundJobs.activeMetadataJobs
      + health.backgroundJobs.activeScrubPreviewJobs
    return active == 0 ? "Idle" : "\(active) active"
  }

  private var backupSummary: String {
    guard let backup = health.backup else { return "None" }
    if backup.lastAttemptFailed { return "Last Failed" }
    if backup.totalBackups == 0 { return backup.enabled ? "Scheduled" : "Disabled" }
    let bytes = ByteCountFormatter.string(
      fromByteCount: backup.totalBackupBytes, countStyle: .file)
    return "\(backup.totalBackups) backups (\(bytes))"
  }

  private func metric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(value).font(.callout.weight(.semibold)).monospacedDigit()
      Text(title).font(.caption2).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .background(
      AureliaDesign.raisedSurface,
      in: RoundedRectangle(cornerRadius: AureliaDesign.compactRadius, style: .continuous))
  }
}
