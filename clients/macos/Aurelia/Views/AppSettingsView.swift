import AppKit
import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable, Sendable {
  case general = "General"
  case playback = "Playback"
  case library = "Library"
  case metadata = "Metadata"
  case profilesAndDevices = "Profiles and Devices"
  case server = "Server"
  case updates = "Updates"
  case advanced = "Advanced"

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .general: "gearshape.fill"
    case .playback: "play.rectangle.fill"
    case .library: "externaldrive.fill"
    case .metadata: "sparkles.rectangle.stack.fill"
    case .profilesAndDevices: "person.2.fill"
    case .server: "server.rack"
    case .updates: "arrow.down.circle.fill"
    case .advanced: "slider.horizontal.3"
    }
  }
}

struct AppSettingsView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject private var playbackPreferences = PlaybackPreferencesStore.shared
  @ObservedObject private var updater = AppUpdater.shared

  // General & Interface preferences
  @AppStorage(GeneralPreferenceKeys.defaultStartScreen) private var defaultStartScreen = "movies"
  @AppStorage(GeneralPreferenceKeys.posterSize) private var posterSize = "standard"
  @AppStorage(GeneralPreferenceKeys.showWatchedInRows) private var showWatchedInRows = true
  @AppStorage(GeneralPreferenceKeys.reduceHeroMotion) private var reduceHeroMotion = false
  @AppStorage(GeneralPreferenceKeys.showMoviesInSidebar) private var showMoviesInSidebar = true
  @AppStorage(GeneralPreferenceKeys.showSeriesInSidebar) private var showSeriesInSidebar = true
  @AppStorage(GeneralPreferenceKeys.showWatchlistInSidebar) private var showWatchlistInSidebar =
    true
  @AppStorage(GeneralPreferenceKeys.showCollectionsInSidebar) private var showCollectionsInSidebar =
    true
  @AppStorage(GeneralPreferenceKeys.hideOfflineTitles) private var hideOfflineTitles = false
  @AppStorage(GeneralPreferenceKeys.rescanInterval) private var rescanInterval = "manual"

  // Window & System
  @AppStorage(WindowClosePreference.quitsKey) private var quitsWhenWindowCloses = true
  @AppStorage(AureliaRest.enabledKey) private var restsWhenUnused = true
  @AppStorage(AureliaRest.minutesKey) private var restMinutes = AureliaRest.defaultMinutes
  @AppStorage(AppUpdatePreferences.automaticChecksKey) private var automaticUpdateChecks = true

  // Navigation & Search State
  @State private var selectedCategory: SettingsCategory = .general
  @State private var searchText = ""

  // Dialog & Sheet States
  @State private var libraryToRemove: LibrarySummary?
  @State private var showingSwitchConfirmation = false
  @State private var pendingLocations: [StorageLocationDraft] = []
  @State private var showingCombineConfirmation = false
  @State private var isLoadingAdministration = false
  @State private var tmdbToken = ""
  @State private var showingReviewQueue = false
  @State private var showingMediaManager = false
  @State private var showingResetSheet = false

  var body: some View {
    HStack(spacing: 0) {
      sidebar
        .frame(width: 220)
        .background(AureliaDesign.canvas.opacity(0.85))

      Divider()

      detailArea
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AureliaDesign.canvas)
    }
    .frame(minWidth: 840, idealWidth: 880, minHeight: 620, idealHeight: 680)
    .background(AureliaBackdrop())
    .task {
      isLoadingAdministration = true
      await model.reloadAdministration()
      isLoadingAdministration = false
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(5)) } catch { break }
        if scenePhase == .active { await model.reloadDevices() }
      }
    }
    .onChange(of: scenePhase) {
      if scenePhase == .active { Task { await model.reloadDevices() } }
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
        "Only Aurelia database entries are removed. Your media files are never deleted or changed.")
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
    .sheet(isPresented: $showingResetSheet) {
      LibraryResetSheet().environmentObject(model)
    }
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    VStack(spacing: 12) {
      AureliaSearchField(prompt: "Search settings…", text: $searchText)
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .accessibilityIdentifier("settings-search-field")

      List(selection: $selectedCategory) {
        ForEach(SettingsCategory.allCases) { category in
          if shouldShowCategory(category) {
            Button {
              selectedCategory = category
              searchText = ""
            } label: {
              HStack(spacing: 10) {
                Image(systemName: category.symbol)
                  .font(.system(size: 15, weight: .medium))
                  .frame(width: 20)
                  .foregroundStyle(
                    selectedCategory == category && searchText.isEmpty ? .primary : .secondary)
                Text(category.rawValue)
                  .font(
                    .system(
                      size: 13,
                      weight: selectedCategory == category && searchText.isEmpty
                        ? .semibold : .regular))
                Spacer()
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                  selectedCategory == category && searchText.isEmpty
                    ? AureliaDesign.raisedSurface : Color.clear)
            )
            .tag(category)
            .accessibilityIdentifier("settings-tab-\(category.id.lowercased())")
          }
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
    }
  }

  private func shouldShowCategory(_ category: SettingsCategory) -> Bool {
    switch category {
    case .general, .playback, .profilesAndDevices, .updates, .advanced:
      return true
    case .library:
      return model.canManageStorage
    case .metadata, .server:
      return model.canManageMedia
    }
  }

  // MARK: - Detail Area

  @ViewBuilder
  private var detailArea: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        if !searchText.isEmpty {
          searchResultsView
        } else {
          categoryView(selectedCategory)
        }

        if let error = model.administrationErrorMessage {
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
      .padding(26)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .scrollContentBackground(.hidden)
  }

  @ViewBuilder
  private func categoryView(_ category: SettingsCategory) -> some View {
    switch category {
    case .general:
      generalSections
    case .playback:
      playbackSections
    case .library:
      if model.canManageStorage {
        librarySections
      } else {
        unavailableNotice(
          "Library Management Unavailable", "An owner or administrator manages storage locations.")
      }
    case .metadata:
      if model.canManageMedia {
        metadataSections
      } else {
        unavailableNotice(
          "Metadata Settings Unavailable", "An owner or administrator manages metadata.")
      }
    case .profilesAndDevices:
      profilesAndDevicesSections
    case .server:
      if model.canManageMedia {
        serverSections
      } else {
        unavailableNotice(
          "Server Operations Unavailable",
          "The server's owner manages server health and operations.")
      }
    case .updates:
      updatesSections
    case .advanced:
      advancedSections
    }
  }

  private func unavailableNotice(_ title: String, _ description: String) -> some View {
    ContentUnavailableView(
      title,
      systemImage: "person.crop.circle.badge.xmark",
      description: Text(description)
    )
  }

  // MARK: - Search Results

  @ViewBuilder
  private var searchResultsView: some View {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    VStack(alignment: .leading, spacing: 22) {
      Text("Search results for “\(searchText)”")
        .font(.headline)
        .foregroundStyle(.secondary)

      var foundAny = false

      if queryMatches(query, "start screen poster rows hero motion interface display") {
        interfaceDisplaySection
        let _ = { foundAny = true }()
      }
      if queryMatches(query, "sidebar navigation movies series tv shows watchlist collections") {
        sidebarNavigationSection
        let _ = { foundAny = true }()
      }
      if queryMatches(query, "quit window close rest energy sleep power mac") {
        windowSystemSection
        let _ = { foundAny = true }()
      }
      if queryMatches(query, "resume next countdown threshold auto night mode sleep") {
        playbackBehaviorSection
        let _ = { foundAny = true }()
      }
      if queryMatches(query, "rate speed volume delay hide seek controls interval") {
        playerControlsSection
        let _ = { foundAny = true }()
      }
      if queryMatches(query, "audio subtitle language tracks size background forget captions") {
        audioSubtitlesSection
        let _ = { foundAny = true }()
      }
      if model.canManageStorage
        && queryMatches(query, "storage locations folder scan path media manager")
      {
        storageLocationsSection
        let _ = { foundAny = true }()
      }
      if model.canManageStorage
        && queryMatches(query, "rescan interval automated exclusions offline")
      {
        scanningAndAutomationSection
        catalogVisibilitySection
        let _ = { foundAny = true }()
      }
      if model.canManageMedia
        && queryMatches(query, "tmdb token metadata artwork enrich queue review movie info")
      {
        metadataSections
        let _ = { foundAny = true }()
      }
      if queryMatches(query, "profile pin password account avatar current") {
        currentProfileSection
        let _ = { foundAny = true }()
      }
      if model.canManageMedia && queryMatches(query, "user accounts profiles create edit delete") {
        userAccountsSection
        let _ = { foundAny = true }()
      }
      if model.canManageMedia
        && queryMatches(query, "devices streaming pairing authorized sessions revoke")
      {
        streamingDevicesSection
        let _ = { foundAny = true }()
      }
      if model.canManageMedia
        && queryMatches(query, "server status uptime streams health cpu ram memory")
      {
        yourServerSection
        serverHealthSection
        let _ = { foundAny = true }()
      }
      if model.canManageMedia && queryMatches(query, "scrub previews thumbnails strip timeline cap")
      {
        scrubPreviewsSection
        let _ = { foundAny = true }()
      }
      if model.canManageMedia
        && queryMatches(query, "live conversion transcoding remuxing stream limit")
      {
        liveConversionSection
        let _ = { foundAny = true }()
      }
      if model.canManageMedia && queryMatches(query, "backup automatic database restore") {
        automaticBackupsSection
        let _ = { foundAny = true }()
      }
      if model.canManageMedia
        && queryMatches(query, "power sleep idle awake hours lan network port")
      {
        serverPowerSection
        serverNetworkSection
        let _ = { foundAny = true }()
      }
      if queryMatches(
        query,
        "updates check new version mac app server release notes token github pat private"
      ) {
        updatesSections
        let _ = { foundAny = true }()
      }
      if queryMatches(query, "connection address fingerprint disconnect restart host") {
        serverConnectionSection
        let _ = { foundAny = true }()
      }
      if model.canManageMedia && queryMatches(query, "danger reset library factory wipe delete") {
        dangerZoneSection
        let _ = { foundAny = true }()
      }

      if !foundAny {
        ContentUnavailableView.search(text: searchText)
      }
    }
  }

  private func queryMatches(_ query: String, _ keywords: String) -> Bool {
    let tokens = query.split(separator: " ").map(String.init)
    return tokens.allSatisfy { token in keywords.localizedCaseInsensitiveContains(token) }
  }

  // MARK: - 1. General

  @ViewBuilder
  private var generalSections: some View {
    interfaceDisplaySection
    sidebarNavigationSection
    windowSystemSection
  }

  private var interfaceDisplaySection: some View {
    AureliaSettingsSection(
      "Interface & Display",
      symbol: "display",
      description: "Choose your preferred initial section, poster display, and animations."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        LabeledContent("Default Start Screen") {
          Picker("Default Start Screen", selection: $defaultStartScreen) {
            ForEach(StartScreenPreference.allCases) { screen in
              Text(screen.label).tag(screen.rawValue)
            }
          }
          .labelsHidden()
          .frame(width: 170)
          .accessibilityIdentifier("interface-start-screen")
        }

        LabeledContent("Poster Size") {
          Picker("Poster Size", selection: $posterSize) {
            ForEach(PosterSizePreference.allCases) { size in
              Text(size.label).tag(size.rawValue)
            }
          }
          .labelsHidden()
          .frame(width: 170)
          .accessibilityIdentifier("interface-poster-size")
        }

        Divider()

        Toggle("Show Watched Titles in Rows", isOn: $showWatchedInRows)
          .accessibilityIdentifier("interface-show-watched")

        VStack(alignment: .leading, spacing: 2) {
          Toggle("Reduce Motion for Hero Banners", isOn: $reduceHeroMotion)
            .accessibilityIdentifier("interface-hero-motion")
          Text("Minimizes slide and zoom transitions on the featured showcase.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .toggleStyle(.switch)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var sidebarNavigationSection: some View {
    AureliaSettingsSection(
      "Sidebar Navigation",
      symbol: "sidebar.left",
      description: "Choose which media categories appear in the main navigation sidebar."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Movies", isOn: $showMoviesInSidebar)
          .accessibilityIdentifier("interface-sidebar-movies")
        Toggle("TV Shows", isOn: $showSeriesInSidebar)
          .accessibilityIdentifier("interface-sidebar-series")
        Toggle("Watchlist", isOn: $showWatchlistInSidebar)
          .accessibilityIdentifier("interface-sidebar-watchlist")
        Toggle("Collections", isOn: $showCollectionsInSidebar)
          .accessibilityIdentifier("interface-sidebar-collections")
      }
      .toggleStyle(.switch)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var windowSystemSection: some View {
    AureliaSettingsSection(
      "Window & System",
      symbol: "macwindow",
      description: "Window behavior and energy-saving rest rules for Aurelia."
    ) {
      VStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Toggle("Quit When the Window Closes", isOn: $quitsWhenWindowCloses)
            .accessibilityIdentifier("interface-quit-on-close")
          Text(
            model.isLocalHost
              ? "Ends the connection to the server. A local server running only while Aurelia is open stops too."
              : "Ends the connection to the server, allowing remote servers in sleep mode to rest."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        Divider()

        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Toggle("Let the Server Rest When Unused", isOn: $restsWhenUnused)
              .accessibilityIdentifier("interface-rest")
            Spacer()
            Picker("After", selection: $restMinutes) {
              ForEach(AureliaRest.minuteChoices, id: \.self) { minutes in
                Text("\(minutes) minutes").tag(minutes)
              }
            }
            .labelsHidden()
            .frame(width: 130)
            .disabled(!restsWhenUnused)
          }
          Text(
            "With no activity for this duration, Aurelia disconnects so a server that saves power can sleep."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        Divider()

        LabeledContent("Appearance", value: "Dark Cinema")
        LabeledContent("Reduced Motion", value: "Follows System Settings")
        LabeledContent("Reduced Transparency", value: "Follows System Settings")
        LabeledContent("Increased Contrast", value: "Follows System Settings")
      }
      .toggleStyle(.switch)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - 2. Playback

  @ViewBuilder
  private var playbackSections: some View {
    playbackBehaviorSection
    playerControlsSection
    audioSubtitlesSection
  }

  private var playbackBehaviorSection: some View {
    AureliaSettingsSection(
      "Playback Behavior",
      symbol: "play.circle.fill",
      description: "Starting position, auto-play, and audio comfort for media playback on this Mac."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        Toggle("Automatic Resume", isOn: $playbackPreferences.preferences.automaticResume)
          .accessibilityIdentifier("playback-automatic-resume")

        Toggle(
          "Automatically Play Next Episode",
          isOn: $playbackPreferences.preferences.automaticallyPlayNextEpisode
        )
        .accessibilityIdentifier("playback-auto-next")

        LabeledContent("Up Next Countdown Duration") {
          Picker(
            "Up Next Countdown", selection: $playbackPreferences.preferences.upNextCountdownSeconds
          ) {
            ForEach([5, 10, 15, 20], id: \.self) { sec in
              Text("\(sec) seconds").tag(sec)
            }
          }
          .labelsHidden()
          .frame(width: 140)
          .accessibilityIdentifier("playback-upnext-countdown")
        }

        LabeledContent("Restart if Watched Under") {
          Picker(
            "Restart Threshold", selection: $playbackPreferences.preferences.resumeThresholdSeconds
          ) {
            ForEach([5, 10, 30, 60], id: \.self) { sec in
              Text("\(sec) seconds").tag(sec)
            }
          }
          .labelsHidden()
          .frame(width: 140)
          .accessibilityIdentifier("playback-resume-threshold")
        }

        LabeledContent("Mark as Watched Threshold") {
          Picker(
            "Watched Threshold",
            selection: $playbackPreferences.preferences.markWatchedThresholdPercent
          ) {
            ForEach([80, 85, 90, 95], id: \.self) { pct in
              Text("\(pct)% completed").tag(pct)
            }
          }
          .labelsHidden()
          .frame(width: 140)
          .accessibilityIdentifier("playback-watched-threshold")
        }

        Divider()

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
      }
      .toggleStyle(.switch)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var playerControlsSection: some View {
    AureliaSettingsSection(
      "Player Controls",
      symbol: "slider.horizontal.below.rectangle",
      description: "Default playback speed, volume, and seek navigation step size."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        LabeledContent("Default Playback Rate") {
          Picker(
            "Default Playback Rate", selection: $playbackPreferences.preferences.defaultPlaybackRate
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
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var audioSubtitlesSection: some View {
    AureliaSettingsSection(
      "Audio & Subtitles",
      symbol: "captions.bubble.fill",
      description: "Default track selections, subtitle appearance, and remembered choices."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        LabeledContent("Default Audio Language") {
          Picker(
            "Default Audio Language",
            selection: $playbackPreferences.preferences.defaultAudioLanguage
          ) {
            Text("Original").tag("original")
            Text("English").tag("en")
            Text("German").tag("de")
            Text("French").tag("fr")
            Text("Spanish").tag("es")
            Text("Japanese").tag("ja")
          }
          .labelsHidden()
          .frame(width: 160)
          .accessibilityIdentifier("playback-audio-lang")
        }

        LabeledContent("Default Subtitle Language") {
          Picker(
            "Default Subtitle Language",
            selection: $playbackPreferences.preferences.defaultSubtitleLanguage
          ) {
            Text("Off").tag("off")
            Text("English").tag("en")
            Text("German").tag("de")
            Text("French").tag("fr")
            Text("Spanish").tag("es")
            Text("Japanese").tag("ja")
          }
          .labelsHidden()
          .frame(width: 160)
          .accessibilityIdentifier("playback-sub-lang")
        }

        LabeledContent("Subtitle Size") {
          Picker("Subtitle Size", selection: $playbackPreferences.preferences.subtitleSize) {
            ForEach(SubtitleSizePreference.allCases) { size in
              Text(size.label).tag(size.rawValue)
            }
          }
          .labelsHidden()
          .frame(width: 160)
          .accessibilityIdentifier("playback-sub-size")
        }

        LabeledContent("Subtitle Background") {
          Picker(
            "Subtitle Background", selection: $playbackPreferences.preferences.subtitleBackground
          ) {
            ForEach(SubtitleBackgroundPreference.allCases) { bg in
              Text(bg.label).tag(bg.rawValue)
            }
          }
          .labelsHidden()
          .frame(width: 160)
          .accessibilityIdentifier("playback-sub-bg")
        }

        Divider()

        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Remembered Track Choices")
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

        Button("Restore Playback Defaults") {
          playbackPreferences.restoreDefaults()
        }
        .accessibilityIdentifier("playback-restore-defaults")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func playbackRateLabel(_ rate: Double) -> String {
    rate == rate.rounded()
      ? "\(Int(rate))x"
      : "\(String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), rate))x"
  }

  // MARK: - 3. Library

  @ViewBuilder
  private var librarySections: some View {
    storageLocationsSection
    scanningAndAutomationSection
    catalogVisibilitySection
  }

  private var storageLocationsSection: some View {
    AureliaSettingsSection(
      "Storage Locations",
      symbol: "externaldrive.fill",
      description:
        "Aurelia recognizes movies and TV shows automatically in each configured location."
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
              .foregroundStyle(.secondary)
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

        Divider()

        VStack(alignment: .leading, spacing: 6) {
          Text("Manage Media & Assignments").font(.headline)
          Text(
            "Assign target titles, verify seasons, tag extras or trailers, and manage folder import rules."
          )
          .font(.caption).foregroundStyle(.secondary)

          Button("Manage Media…") { showingMediaManager = true }
            .accessibilityIdentifier("add-storage-locations")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var scanningAndAutomationSection: some View {
    AureliaSettingsSection(
      "Scanning & Automation",
      symbol: "arrow.triangle.2.circlepath",
      description: "Scheduled rescan intervals for connected media locations."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        LabeledContent("Automatic Rescan Interval") {
          Picker("Rescan Interval", selection: $rescanInterval) {
            ForEach(LibraryRescanInterval.allCases) { interval in
              Text(interval.label).tag(interval.rawValue)
            }
          }
          .labelsHidden()
          .frame(width: 180)
          .accessibilityIdentifier("library-rescan-interval")
        }

        Text("Aurelia monitors storage roots for file modifications when available.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var catalogVisibilitySection: some View {
    AureliaSettingsSection(
      "Catalog Visibility",
      symbol: "eye",
      description: "Control how offline media sources are surfaced in library browsing."
    ) {
      VStack(alignment: .leading, spacing: 10) {
        Toggle("Hide Offline Titles", isOn: $hideOfflineTitles)
          .accessibilityIdentifier("library-hide-offline")
        Text(
          "Hides movies and episodes whose storage disk or network mount is temporarily disconnected."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .toggleStyle(.switch)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - 4. Metadata

  @ViewBuilder
  private var metadataSections: some View {
    AureliaSettingsSection(
      "Movie & TV Information",
      symbol: "sparkles.rectangle.stack",
      description:
        "Use your own TMDB API Read Access Token to download metadata and artwork. File paths are never sent."
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
            ProgressView(value: Double(job.itemsProcessed), total: Double(max(job.itemsTotal, 1))) {
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

  // MARK: - 5. Profiles and Devices

  @ViewBuilder
  private var profilesAndDevicesSections: some View {
    currentProfileSection
    if model.canManageMedia {
      userAccountsSection
      streamingDevicesSection
    }
  }

  private var currentProfileSection: some View {
    AureliaSettingsSection(
      "Current Profile",
      symbol: "person.crop.circle",
      description: "Manage your signed-in profile and update your PIN."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        if let user = model.profile?.user {
          HStack(spacing: 14) {
            AureliaProfileAvatar(id: user.id, name: user.username, size: 44)
            VStack(alignment: .leading, spacing: 2) {
              Text(user.username).font(.headline)
              Text("Role: \(user.role.rawValue.capitalized)").font(.caption).foregroundStyle(
                .secondary)
            }
            Spacer()
            if model.profile?.isViewingSession == true {
              Button("Switch Profile") { Task { await model.switchWatchingProfile() } }
            }
          }
          Divider()
        }

        if model.profile?.isViewingSession == true {
          ChangeProfilePINView()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var userAccountsSection: some View {
    AureliaSettingsSection(
      "User Accounts",
      symbol: "person.2.fill",
      description: "Manage household user profiles and library access modes."
    ) {
      ServerProfileManagementList()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var streamingDevicesSection: some View {
    AureliaSettingsSection(
      "Streaming Devices",
      symbol: "tv.and.mediabox",
      description: "Authorize new client pairings and review active device sessions."
    ) {
      VStack(alignment: .leading, spacing: 16) {
        DeviceApprovalView()
        ServerDevicesSection()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - 6. Server

  @ViewBuilder
  private var serverSections: some View {
    yourServerSection
    serverHealthSection
    scrubPreviewsSection
    liveConversionSection
    automaticBackupsSection
    serverPowerSection
    serverNetworkSection
  }

  private var yourServerSection: some View {
    AureliaSettingsSection(
      "Your Server",
      symbol: "server.rack",
      description: "Backend server state and active client streams."
    ) {
      VStack(alignment: .leading, spacing: 10) {
        LabeledContent("Name", value: model.profile?.name ?? "Aurelia")
        LabeledContent("Status", value: model.hostSnapshot.state.rawValue.capitalized)
        if let user = model.profile?.user {
          LabeledContent("Access Level", value: user.role.rawValue.capitalized)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var serverHealthSection: some View {
    ServerHealthCardWrapper()
  }

  private var scrubPreviewsSection: some View {
    ServerScrubPreviewsWrapper()
  }

  private var liveConversionSection: some View {
    AureliaSettingsSection(
      "Live Conversion",
      symbol: "play.display",
      description:
        "On-the-fly stream transcoding and live remuxing for browsers and remote clients."
    ) {
      VStack(alignment: .leading, spacing: 8) {
        Text(
          "Hardware video decoding and live stream conversion are performed without saving temporary files to disk."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        LabeledContent("Temporary Transcode Cache", value: "None (Memory Only)")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var automaticBackupsSection: some View {
    ServerBackupsWrapper()
  }

  private var serverPowerSection: some View {
    ServerPowerWrapper()
  }

  private var serverNetworkSection: some View {
    ServerNetworkWrapper()
  }

  // MARK: - 7. Updates

  @ViewBuilder
  private var updatesSections: some View {
    AureliaSettingsSection(
      "Mac App Updates",
      symbol: "macwindow.badge.plus",
      description:
        "Aurelia looks for new versions in its GitHub releases. Your library, settings, and logins remain safe."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        LabeledContent(
          "Installed Version", value: "\(updater.currentVersion) (\(updater.currentBuild))")
        LabeledContent("Status", value: updateStatusText)

        Toggle("Check for updates automatically", isOn: $automaticUpdateChecks)
          .accessibilityIdentifier("updates-automatic")

        Button("Check for Updates…") {
          Task { await updater.check(userInitiated: true) }
        }
        .disabled(
          updater.state == .checking || updater.state == .downloading
            || updater.state == .installing
        )
        .accessibilityIdentifier("updates-check")
      }
      .toggleStyle(.switch)
      .frame(maxWidth: .infinity, alignment: .leading)
    }

    if model.canManageMedia {
      AureliaSettingsSection(
        "Server Updates",
        symbol: "arrow.triangle.2.circlepath.circle",
        description: "Keep your Aurelia Server backend synchronized and updated."
      ) {
        ServerUpdatesWrapper()
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }

    AureliaSettingsSection(
      "Advanced",
      symbol: "key.fill",
      description: "Only needed while the repository is private."
    ) {
      GitHubTokenSettingsView(updater: updater)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var updateStatusText: String {
    switch updater.state {
    case .idle: updater.repository == nil ? "Release builds only" : "Up to date"
    case .checking: "Checking for updates…"
    case .upToDate: "Up to date"
    case .available(let release): "\(release.version) (\(release.build)) is available"
    case .downloading: "Downloading update…"
    case .installing: "Installing update…"
    case .failed(let message): message
    }
  }

  // MARK: - 8. Advanced

  @ViewBuilder
  private var advancedSections: some View {
    serverConnectionSection
    if model.canManageMedia {
      dangerZoneSection
    }
  }

  @ViewBuilder
  private var serverConnectionSection: some View {
    if let profile = model.profile {
      AureliaSettingsSection(
        "Server Connection",
        symbol: "link",
        description: "The connection endpoint this Mac uses to access Aurelia."
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
            if profile.user?.role != .owner {
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
                  "This connection points to this Mac. Start its local server without signing out or resetting your library."
                )
                .font(.caption).foregroundStyle(.secondary)
                Button(
                  model.isRecoveringLocalHost ? "Starting Local Server…" : "Start Local Server"
                ) {
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
    } else {
      ContentUnavailableView(
        "No Server Connected", systemImage: "network.slash",
        description: Text("Connect from the main window."))
    }
  }

  private var dangerZoneSection: some View {
    AureliaDangerZoneSection(
      "Danger Zone",
      description:
        "These administrative operations are destructive and cannot be undone. They require the Server Password."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Reset Media Library").font(.headline)
            Text(
              "Removes all indexed titles, scan history, progress and metadata from Aurelia. Media files on disk are never touched."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Reset Library…", role: .destructive) {
            showingResetSheet = true
          }
          .disabled(model.libraries.isEmpty)
          .accessibilityIdentifier("danger-reset-library")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

// MARK: - Server Component Wrappers

private struct ServerHealthCardWrapper: View {
  @EnvironmentObject private var model: AppModel
  @State private var health: ServerHealthResponse?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let health {
        ServerHealthCard(health: health)
      } else {
        AureliaSettingsSection(
          "Server Health",
          symbol: "waveform.path.ecg",
          description: "System resource consumption and background task workers."
        ) {
          ProgressView("Loading server health…")
        }
      }
    }
    .task {
      guard let profile = model.profile else { return }
      let client = APIClient(profile: profile)
      health = try? await client.serverHealth()
    }
  }
}

private struct ServerScrubPreviewsWrapper: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    if let profile = model.profile {
      ServerScrubPreviewsEditor(client: APIClient(profile: profile))
    }
  }
}

private struct ServerBackupsWrapper: View {
  @EnvironmentObject private var model: AppModel
  @State private var configuration: ServerConfigurationResponse?

  var body: some View {
    if let profile = model.profile {
      let client = APIClient(profile: profile)
      if let configuration {
        ServerBackupsEditor(
          configuration: configuration, client: client,
          nativeHostAvailable: model.isLocalHost
        ) { self.configuration = $0 }
      } else {
        ProgressView("Loading backup configuration…")
          .task {
            configuration = try? await client.serverSettings()
          }
      }
    }
  }
}

private struct ServerPowerWrapper: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    if let profile = model.profile {
      ServerPowerEditor(client: APIClient(profile: profile))
    }
  }
}

private struct ServerNetworkWrapper: View {
  @EnvironmentObject private var model: AppModel
  @State private var configuration: ServerConfigurationResponse?

  var body: some View {
    if let profile = model.profile {
      let client = APIClient(profile: profile)
      if let configuration {
        ServerNetworkEditor(
          configuration: configuration, client: client,
          nativeHostAvailable: model.isLocalHost
        ) {
          Task {
            self.configuration = try? await client.serverSettings()
          }
        }
      } else {
        ProgressView("Loading network settings…")
          .task {
            configuration = try? await client.serverSettings()
          }
      }
    }
  }
}

private struct ServerUpdatesWrapper: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    if let profile = model.profile {
      ServerUpdatesEditor(client: APIClient(profile: profile))
    }
  }
}

private struct ServerProfileManagementList: View {
  @EnvironmentObject private var model: AppModel
  @State private var users: [UserAccessSummary] = []
  @State private var editingUser: UserAccessSummary?
  @State private var creatingUser = false
  @State private var profileToDelete: UserAccessSummary?
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let error { Text(error).foregroundStyle(.red) }

      ForEach(users) { user in
        HStack {
          AureliaProfileAvatar(id: user.id, name: user.user.username, size: 28)
          VStack(alignment: .leading, spacing: 1) {
            Text(user.user.username).font(.headline)
            Text(user.user.role.rawValue.capitalized)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Edit…") { editingUser = user }
          if user.id != model.profile?.user?.id {
            Button(role: .destructive) {
              profileToDelete = user
            } label: {
              Image(systemName: "trash")
            }
          }
        }
        if user.id != users.last?.id { Divider() }
      }

      Button("Add User Profile…") { creatingUser = true }
    }
    .task {
      await reloadUsers()
    }
    .sheet(item: $editingUser) { user in
      if let profile = model.profile {
        ServerProfileEditor(existing: user, client: APIClient(profile: profile)) {
          Task { await reloadUsers() }
        }
      }
    }
    .sheet(isPresented: $creatingUser) {
      if let profile = model.profile {
        ServerProfileEditor(client: APIClient(profile: profile)) {
          Task { await reloadUsers() }
        }
      }
    }
    .confirmationDialog(
      "Delete Profile \(profileToDelete?.user.username ?? "")?",
      isPresented: Binding(
        get: { profileToDelete != nil }, set: { if !$0 { profileToDelete = nil } }),
      titleVisibility: .visible
    ) {
      if let user = profileToDelete {
        Button("Delete Profile", role: .destructive) {
          Task {
            guard let profile = model.profile else { return }
            let client = APIClient(profile: profile)
            do {
              try await client.deleteProfile(id: user.id)
              await reloadUsers()
            } catch {
              self.error = error.localizedDescription
            }
          }
        }
      }
    } message: {
      Text("All progress, scene notes and preferences for this profile will be deleted.")
    }
  }

  private func reloadUsers() async {
    guard let profile = model.profile else { return }
    let client = APIClient(profile: profile)
    if let fetched = try? await client.serverUsers() {
      users = fetched
    }
  }
}

private struct GitHubTokenSettingsView: View {
  @ObservedObject var updater: AppUpdater
  @State private var tokenInput = ""
  @State private var isEditing = false
  @State private var statusMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if updater.hasToken && !isEditing {
        HStack(spacing: 12) {
          Label("GitHub token saved in Keychain", systemImage: "checkmark.shield.fill")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("updates-token-status")

          Spacer()

          Button("Change…") {
            isEditing = true
            tokenInput = ""
            statusMessage = nil
          }
          .accessibilityIdentifier("updates-token-change")

          Button("Remove", role: .destructive) {
            do {
              try updater.deleteToken()
              statusMessage = "Token removed."
            } catch {
              statusMessage = error.localizedDescription
            }
          }
          .accessibilityIdentifier("updates-token-remove")
        }
      } else {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            SecureField("Personal Access Token (ghp_…)", text: $tokenInput)
              .textFieldStyle(.roundedBorder)
              .accessibilityLabel("GitHub Personal Access Token")
              .accessibilityIdentifier("updates-token-input")

            Button("Save Token") {
              do {
                try updater.saveToken(tokenInput)
                isEditing = false
                tokenInput = ""
                statusMessage = "Token saved in Keychain."
              } catch {
                statusMessage = error.localizedDescription
              }
            }
            .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("updates-token-save")

            if isEditing {
              Button("Cancel") {
                isEditing = false
                tokenInput = ""
              }
            }
          }

          Text(
            "Only needed while the Aurelia repository is private. Leave blank for public releases."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      if let statusMessage {
        Text(statusMessage)
          .font(.caption)
          .foregroundStyle(
            statusMessage.contains("failed") || statusMessage.contains("error")
              ? .red : .secondary)
      }
    }
  }
}
