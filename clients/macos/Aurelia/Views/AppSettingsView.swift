import AppKit
import SwiftUI

struct AppSettingsView: View {
  private enum SettingsPage: Hashable {
    case general
    case playback
    case library
    case metadata
    case server
  }

  @EnvironmentObject private var model: AppModel
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject private var playbackPreferences = PlaybackPreferencesStore.shared
  @AppStorage(WindowClosePreference.quitsKey) private var quitsWhenWindowCloses = true
  @State private var selectedPage: SettingsPage = .general
  @State private var libraryToRemove: LibrarySummary?
  @State private var showingSwitchConfirmation = false
  @State private var pendingLocations: [StorageLocationDraft] = []
  @State private var showingCombineConfirmation = false
  @State private var isLoadingAdministration = false
  @State private var tmdbToken = ""
  @State private var showingReviewQueue = false
  @State private var showingMediaManager = false
  @State private var showingDeviceApproval = false

  var body: some View {
    TabView(selection: $selectedPage) {
      settingsPage {
        interface
        if model.profile?.isViewingSession == true { ChangeProfilePINView() }
        if model.profile != nil, model.managementUnlocked { devices }
        disconnectedState
      }
      .tabItem { Label("General", systemImage: "gearshape") }
      .tag(SettingsPage.general)

      settingsPage { playback }
        .tabItem { Label("Playback", systemImage: "play.rectangle") }
        .tag(SettingsPage.playback)

      settingsPage {
        if model.profile?.user?.role.canManageLibraries == true, !model.managementUnlocked {
          ManagementUnlockView()
        } else if model.canManageStorage {
          storage
          LibraryMaintenanceView()
        } else if model.profile != nil {
          ContentUnavailableView(
            "Library Management Unavailable",
            systemImage: "person.crop.circle.badge.xmark",
            description: Text("An owner or administrator manages this server's storage."))
        } else {
          disconnectedState
        }
      }
      .tabItem { Label("Library", systemImage: "externaldrive") }
      .tag(SettingsPage.library)

      settingsPage {
        if model.profile?.user?.role.canManageLibraries == true, !model.managementUnlocked {
          ManagementUnlockView()
        } else if model.canManageMedia {
          metadata
        } else if model.profile != nil {
          ContentUnavailableView(
            "Metadata Settings Unavailable",
            systemImage: "person.crop.circle.badge.xmark",
            description: Text("An owner or administrator manages metadata for this server."))
        } else {
          disconnectedState
        }
      }
      .tabItem { Label("Metadata", systemImage: "sparkles.rectangle.stack") }
      .tag(SettingsPage.metadata)

      settingsPage {
        if let profile = model.profile {
          if profile.user?.role == .owner {
            ServerManagementView()
          } else if profile.user?.role.canManageLibraries == true, !model.managementUnlocked {
            ManagementUnlockView()
          } else if model.managementUnlocked, profile.isViewingSession {
            ManagementStatusView()
          }
          advanced(profile)
        } else {
          disconnectedState
        }
      }
      .tabItem { Label("Server", systemImage: "server.rack") }
      .tag(SettingsPage.server)
    }
    .frame(width: 760, height: 640)
    .background(AureliaBackdrop())
    .sheet(isPresented: $showingDeviceApproval) { DeviceApprovalView() }
    .task {
      isLoadingAdministration = true
      await model.reloadAdministration()
      isLoadingAdministration = false
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(5)) } catch { break }
        if scenePhase == .active { await model.reloadDevices() }
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await model.reloadDevices() } }
    }
    .confirmationDialog(
      "Remove \(libraryToRemove?.name ?? "Storage Location")?",
      isPresented: Binding(
        get: { libraryToRemove != nil },
        set: { if !$0 { libraryToRemove = nil } }),
      titleVisibility: .visible
    ) {
      if let library = libraryToRemove {
        Button("Remove from Aurelia", role: .destructive) {
          Task { await model.removeLibrary(id: library.id) }
          libraryToRemove = nil
        }
      }
    } message: {
      Text(
        "Only Aurelia database entries are removed. Your media files are never deleted or changed."
      )
    }
    .confirmationDialog(
      "Stop hosting on this Mac?",
      isPresented: $showingSwitchConfirmation,
      titleVisibility: .visible
    ) {
      Button("Stop Server and Switch", role: .destructive) {
        Task { await model.switchToClientMode() }
      }
    } message: {
      Text("Server data and media files remain untouched.")
    }
    .confirmationDialog(
      "Combine Existing Libraries?",
      isPresented: $showingCombineConfirmation,
      titleVisibility: .visible
    ) {
      Button("Combine Existing Libraries") {
        let locations = pendingLocations
        pendingLocations = []
        Task { _ = await model.addStorageLocations(locations, combineExisting: true) }
      }
      Button("Cancel", role: .cancel) { pendingLocations = [] }
    } message: {
      Text(
        "Movies, IDs, custom titles, and watch progress stay intact. No media files are moved or changed."
      )
    }
    .sheet(isPresented: $showingReviewQueue) {
      MetadataReviewQueueSheet().environmentObject(model)
    }
    .sheet(isPresented: $showingMediaManager) {
      MediaManagerView().environmentObject(model)
    }
  }

  private func settingsPage<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        content()
        if selectedPage != .playback, model.managementUnlocked,
          let error = model.administrationErrorMessage
        {
          Text(error)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let error = model.errorMessage {
          Text(error)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .scrollContentBackground(.hidden)
    .background(AureliaDesign.canvas)
  }

  @ViewBuilder
  private var disconnectedState: some View {
    if model.profile == nil && model.operatingMode != .host {
      ContentUnavailableView(
        "No Server Connected",
        systemImage: "network.slash",
        description: Text("Connect from the main window."))
    }
  }

  private var playback: some View {
    AureliaSettingsSection(
      "Playback",
      symbol: "play.rectangle.fill",
      description: "Choose how Aurelia starts, controls, and finishes playback on this Mac."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        Toggle(
          "Automatic Resume",
          isOn: $playbackPreferences.preferences.automaticResume
        )
        .accessibilityIdentifier("playback-automatic-resume")
        Toggle(
          "Automatically Play Next Episode",
          isOn: $playbackPreferences.preferences.automaticallyPlayNextEpisode
        )
        .accessibilityIdentifier("playback-auto-next")
        Toggle(
          "Prevent Sleep During Playback",
          isOn: $playbackPreferences.preferences.preventSleepDuringPlayback
        )
        .accessibilityIdentifier("playback-prevent-sleep")
        VStack(alignment: .leading, spacing: 2) {
          Toggle("Night Mode", isOn: $playbackPreferences.preferences.nightMode)
            .accessibilityIdentifier("playback-night-mode")
          Text("Softens loud scenes and makes quiet dialogue easier to hear.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Divider()
        LabeledContent("Default Playback Rate") {
          Picker(
            "Default Playback Rate",
            selection: $playbackPreferences.preferences.defaultPlaybackRate
          ) {
            ForEach(PlaybackPreferences.supportedRates, id: \.self) { rate in
              Text(playbackRateLabel(rate)).tag(rate)
            }
          }
          .labelsHidden()
          .frame(width: 120)
          .accessibilityIdentifier("playback-default-rate")
        }
        LabeledContent("Default Volume") {
          HStack(spacing: 10) {
            Slider(value: $playbackPreferences.preferences.defaultVolume, in: 0...1)
              .frame(width: 180)
              .accessibilityLabel("Default Volume")
              .accessibilityIdentifier("playback-default-volume")
            Text("\(Int(playbackPreferences.preferences.defaultVolume * 100))%")
              .monospacedDigit()
              .frame(width: 42, alignment: .trailing)
          }
        }
        LabeledContent("Controls Auto-Hide Delay") {
          Picker(
            "Controls Auto-Hide Delay",
            selection: $playbackPreferences.preferences.controlsAutoHideDelay
          ) {
            ForEach([2.0, 3.0, 5.0, 8.0], id: \.self) { value in
              Text("\(Int(value)) seconds").tag(value)
            }
          }
          .labelsHidden()
          .frame(width: 140)
          .accessibilityIdentifier("playback-auto-hide-delay")
        }
        LabeledContent("Seek Interval") {
          Stepper(
            "\(playbackPreferences.preferences.seekInterval) seconds",
            value: $playbackPreferences.preferences.seekInterval,
            in: 5...60,
            step: 5
          )
          .frame(width: 170, alignment: .trailing)
          .accessibilityIdentifier("playback-seek-interval")
        }
        Divider()
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Audio and Subtitles")
            Text("Aurelia remembers the tracks you choose, separately for each series.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Forget Track Choices") {
            PlaybackTrackPreferenceStore.shared.forgetAll()
          }
          .accessibilityIdentifier("playback-forget-tracks")
        }
        Button("Restore Playback Defaults") { playbackPreferences.restoreDefaults() }
          .accessibilityIdentifier("playback-restore-defaults")
      }
      .toggleStyle(.switch)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var interface: some View {
    AureliaSettingsSection(
      "Interface",
      symbol: "macwindow",
      description: "Choose what closing the window does. Aurelia follows your Mac accessibility settings."
    ) {
      VStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Toggle("Quit When the Window Closes", isOn: $quitsWhenWindowCloses)
            .accessibilityIdentifier("interface-quit-on-close")
          Text(
            model.isLocalHost
              ? "Ends the connection to the server. A server that runs only while Aurelia is open stops too."
              : "Ends the connection to the server, so a server in sleep mode can go to sleep."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        LabeledContent("Appearance", value: "Dark Cinema")
        LabeledContent("Reduced Motion", value: "Follows System Settings")
        LabeledContent("Reduced Transparency", value: "Follows System Settings")
        LabeledContent("Increased Contrast", value: "Follows System Settings")
      }
    }
  }

  private func playbackRateLabel(_ rate: Double) -> String {
    rate == rate.rounded()
      ? "\(Int(rate))x"
      : "\(String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), rate))x"
  }

  private var storage: some View {
    AureliaSettingsSection(
      "Storage",
      symbol: "externaldrive.fill",
      description: "Aurelia recognizes movies and TV shows automatically in each location."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        if model.libraries.isEmpty {
          if isLoadingAdministration {
            ProgressView("Loading storage…")
          } else {
            Text("No storage locations yet.")
              .foregroundStyle(.secondary)
          }
        }

        ForEach(model.libraries) { library in
          HStack {
            Image(systemName: "externaldrive.fill")
            VStack(alignment: .leading, spacing: 2) {
              Text(library.name).font(.headline)
              Text(library.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(library.availability.rawValue.capitalized)
              .font(.caption).foregroundStyle(.secondary)
            Button("Scan") { Task { await model.scanLibrary(id: library.id) } }
              .disabled(library.importPreviewRequired == true)
            Button(role: .destructive) {
              libraryToRemove = library
            } label: {
              Image(systemName: "trash")
            }
          }
          if library.id != model.libraries.last?.id { Divider() }
        }

        if !model.activeScans.isEmpty {
          ProgressView("Scanning in the background…")
        }

        Text("Import Review & Assignments").font(.headline)
        Text(
          "Preview all files, choose Extra or Trailer, assign a target title and season, or change saved folder rules in Manage Media."
        )
        .font(.caption).foregroundStyle(.secondary)

        Button("Manage Media…") { showingMediaManager = true }
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("add-storage-locations")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func containsExistingLibraries(_ locations: [StorageLocationDraft]) -> Bool {
    locations.contains { location in
      let root = URL(fileURLWithPath: location.path, isDirectory: true).standardizedFileURL.path
      return model.libraries.contains { library in
        let path = URL(fileURLWithPath: library.path, isDirectory: true).standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
      }
    }
  }

  private func effectiveKind(_ discovery: LibraryDiscoverySummary) -> LibraryKind? {
    switch discovery.decision {
    case .movie: .movies
    case .tvShows: .tvShows
    case .ignore: nil
    case nil: discovery.suggestedKind
    }
  }

  private func classificationButton(
    _ title: String,
    _ decision: ClassificationDecision,
    _ discovery: LibraryDiscoverySummary
  ) -> some View {
    Button(title) { Task { await model.classifyDiscovery(discovery, as: decision) } }
  }

  private var devices: some View {
    AureliaSettingsSection(
      "Devices",
      symbol: "laptopcomputer.and.iphone",
      description: "Pair trusted devices and revoke sessions you no longer use."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        if let code = model.pairingCode {
          HStack {
            VStack(alignment: .leading) {
              Text(code.code).font(.system(.title2, design: .monospaced, weight: .bold))
              Text("Expires \(code.expiresAt)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(code.code, forType: .string)
            }
          }
        }
        Button("Pair Another Device") { Task { await model.generatePairingCode() } }
          .buttonStyle(AureliaPrimaryActionButtonStyle())
        if model.profile?.user?.role == .owner {
          Button("Approve Device…") { showingDeviceApproval = true }
            .disabled(!model.libraryCapabilities.contains("device-authorization-v1"))
            .help(
              model.libraryCapabilities.contains("device-authorization-v1")
                ? "Enter the code shown on the new device." : "Requires Aurelia Server 1.5.5."
            )
            .accessibilityIdentifier("approve-device")
        }
        ForEach(model.sessions.filter(\.isActive)) { session in
          HStack {
            VStack(alignment: .leading) {
              Text(session.deviceName)
              Text(session.isCurrent ? "This device" : "Last used \(session.lastSeenAt)")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !session.isCurrent && session.revokedAt == nil {
              Button("Revoke", role: .destructive) {
                Task { await model.revokeSession(id: session.id) }
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var metadata: some View {
    AureliaSettingsSection(
      "Movie & TV Information",
      symbol: "sparkles.rectangle.stack",
      description:
        "Use your own TMDB API Read Access Token to download English metadata and artwork. File paths are never sent."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        if model.profile?.user?.role != .owner {
          Text("An owner manages the metadata provider and its credentials.")
            .font(.caption).foregroundStyle(.secondary)
          Button("Enrich Shared Libraries") { Task { await model.enrichLibrary() } }
            .disabled(model.libraries.isEmpty)
          Button("Review Queue") { showingReviewQueue = true }
        } else if model.metadataProvider?.hasToken == true {
          LabeledContent(
            "TMDB", value: model.metadataProvider?.enabled == true ? "Enabled" : "Disabled")
          if let status = model.metadataProvider {
            LabeledContent(
              "Artwork",
              value: ByteCountFormatter.string(
                fromByteCount: status.artworkBytes, countStyle: .file))
            Text(status.attribution).font(.caption2).foregroundStyle(.secondary)
          }
          HStack {
            Button("Enrich Library") { Task { await model.enrichLibrary() } }
              .accessibilityIdentifier("metadata-enrich")
            Button("Review Queue") { showingReviewQueue = true }
            Button("Remove Unused Artwork") { Task { await model.pruneArtwork() } }
            Button("Remove TMDB Token", role: .destructive) {
              Task { await model.disableMetadata() }
            }
            .accessibilityIdentifier("metadata-remove-token")
          }
          if let job = model.metadataJob {
            ProgressView(
              value: Double(job.itemsProcessed), total: Double(max(job.itemsTotal, 1))
            ) {
              Text("Metadata: \(job.itemsProcessed) of \(job.itemsTotal)")
            }
            if let status = job.waitingStatus() {
              Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("metadata-wait-status")
            }
            if let skipped = job.itemsSkipped, skipped > 0 {
              Text("\(skipped) skipped").font(.caption).foregroundStyle(.secondary)
            }
          }
        } else {
          SecureField("TMDB API Read Access Token", text: $tmdbToken)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("tmdb-token")
          Button("Enable TMDB") {
            let token = tmdbToken
            tmdbToken = ""
            Task { await model.configureMetadata(token: token) }
          }
          .disabled(tmdbToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func advanced(_ profile: StoredServerProfile) -> some View {
    AureliaSettingsSection(
      "Connection",
      symbol: "link",
      description: "How this Mac connects to the server."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        LabeledContent("Server", value: profile.name)
        LabeledContent("Address", value: profile.baseURL.absoluteString)
        LabeledContent(
          "Fingerprint", value: FingerprintFormatter.display(profile.publicKeyFingerprint))
        if let user = profile.user {
          LabeledContent(
            model.requiresProfileSelection ? "Paired Device" : "Signed In",
            value: "\(user.username) · \(user.role.rawValue.capitalized)")
        }
        Divider()
        if model.operatingMode == .host {
          if profile.user?.role != .owner || !model.managementUnlocked {
            // Owners with unlocked management restart from the Your Server summary.
            LabeledContent("Status", value: model.hostSnapshot.state.rawValue.capitalized)
            Button("Restart Server") { Task { await model.restartNativeHost() } }
          }
          Button("Switch to Another Server…", role: .destructive) {
            showingSwitchConfirmation = true
          }
        } else {
          if model.canRestoreLocalHosting {
            VStack(alignment: .leading, spacing: 8) {
              Text(
                "This connection points to this Mac. Start its existing server without signing out or resetting your library."
              )
              .font(.caption).foregroundStyle(.secondary)
              Button(model.isRecoveringLocalHost ? "Starting Local Server…" : "Start Local Server")
              {
                Task { await model.restoreLocalHosting() }
              }
              .disabled(model.isRecoveringLocalHost)
              .accessibilityIdentifier("restore-local-host")
            }
          }
          Button("Disconnect This Mac", role: .destructive) {
            Task { await model.disconnect() }
          }
          .accessibilityIdentifier("disconnect-server")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct DiscoveryDecisionCard: View {
  @EnvironmentObject private var model: AppModel
  let discovery: LibraryDiscoverySummary

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(discovery.detectedTitle).font(.headline)
      if !discovery.relativePath.isEmpty {
        Text(discovery.relativePath).font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        decisionButton("Movie", .movie, "film")
        decisionButton("TV Show · Force Import", .tvShows, "tv")
        decisionButton("Ignore", .ignore, "eye.slash")
      }
    }
    .padding(14)
    .background(
      AureliaDesign.raisedSurface,
      in: RoundedRectangle(cornerRadius: AureliaDesign.compactRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: AureliaDesign.compactRadius, style: .continuous)
        .stroke(AureliaDesign.hairline, lineWidth: 1)
    }
    .accessibilityIdentifier("discovery-\(discovery.id.uuidString.lowercased())")
  }

  private func decisionButton(
    _ title: String,
    _ decision: ClassificationDecision,
    _ symbol: String
  ) -> some View {
    Button {
      Task { await model.classifyDiscovery(discovery, as: decision) }
    } label: {
      Label(title, systemImage: symbol)
    }
  }
}
