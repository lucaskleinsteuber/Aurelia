import AppKit
import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable, Sendable {
  case general = "General"
  case sidebar = "Sidebar"
  case activity = "Activity"
  case playback = "Playback"
  case library = "Library"
  case metadata = "Metadata"
  case profilesAndDevices = "Profiles and Devices"
  case server = "Server"
  case power = "Power"
  case updates = "Updates"
  case advanced = "Advanced"
  case about = "About"

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .general: "gearshape.fill"
    case .sidebar: "sidebar.left"
    case .activity: "chart.bar.xaxis"
    case .playback: "play.rectangle.fill"
    case .library: "externaldrive.fill"
    case .metadata: "sparkles.rectangle.stack.fill"
    case .profilesAndDevices: "person.2.fill"
    case .server: "server.rack"
    case .power: "bolt.fill"
    case .updates: "arrow.down.circle.fill"
    case .advanced: "slider.horizontal.3"
    case .about: "info.circle.fill"
    }
  }
}

struct AppSettingsView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject private var playbackPreferences = PlaybackPreferencesStore.shared
  @ObservedObject private var updater = AppUpdater.shared

  // General & Interface preferences
  @AppStorage(GeneralPreferenceKeys.defaultStartScreen) private var defaultStartScreen =
    StartScreenPreference.lastScreen.rawValue
  @AppStorage(GeneralPreferenceKeys.posterSize) private var posterSize = "standard"
  @AppStorage(GeneralPreferenceKeys.showWatchedInRows) private var showWatchedInRows = true
  @AppStorage(GeneralPreferenceKeys.reduceHeroMotion) private var reduceHeroMotion = false
  @AppStorage(GeneralPreferenceKeys.hideOfflineTitles) private var hideOfflineTitles = false
  @AppStorage(GeneralPreferenceKeys.wishNotificationsEnabled) private var wishNotificationsEnabled =
    true

  // Window & System
  @AppStorage(WindowClosePreference.quitsKey) private var quitsWhenWindowCloses = true
  @AppStorage(AureliaRest.enabledKey) private var restsWhenUnused = true
  @AppStorage(AureliaRest.minutesKey) private var restMinutes = AureliaRest.defaultMinutes
  @AppStorage(AppUpdatePreferences.automaticChecksKey) private var automaticUpdateChecks = true
  @AppStorage(AppUpdatePreferences.betaUpdatesKey) private var betaUpdates = true
  @AppStorage(DownloadQualityPreference.key) private var downloadQuality = DownloadQualityPreference
    .ask

  // Navigation & Search State
  @State private var selectedCategory: SettingsCategory
  @State private var searchText = ""
  @State private var hasSettled = false

  // Dialog & Sheet States
  @State private var libraryToRemove: LibrarySummary?
  @State private var libraryToRelocate: LibrarySummary?
  @State private var showingSwitchConfirmation = false
  @State private var showingDisconnectConfirmation = false
  @State private var pendingLocations: [StorageLocationDraft] = []
  @State private var showingCombineConfirmation = false
  @State private var isLoadingAdministration = false
  @State private var tmdbToken = ""
  @State private var showingReviewQueue = false
  @State private var showingMediaManager = false
  @State private var showingResetSheet = false
  @State private var showingLibraryHealth = false

  /// The category asked for (such as Updates from the menu) is shown from the first frame, so the
  /// page does not switch while it fades in.
  init(initialCategory: SettingsCategory? = nil) {
    _selectedCategory = State(initialValue: initialCategory ?? .general)
  }

  @State private var savingToken = false

  /// A metadata job already queued or running: Enrich would only start another.
  private var metadataJobRunning: Bool {
    model.metadataJob?.state == .queued || model.metadataJob?.state == .running
  }

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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AureliaBackdrop())
    .overlay(alignment: .topLeading) {
      // Settings cover the library inside the window; Done or Esc returns to it.
      Button("Done") { model.isSettingsPresented = false }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .keyboardShortcut(.cancelAction)
        .help("Back to the library (Esc)")
        .accessibilityIdentifier("settings-done")
        .padding(.top, 12)
        .padding(.leading, 220 - 76)
    }
    .onAppear { takeRequestedCategory() }
    .onChange(of: model.requestedSettingsCategory) { _, _ in takeRequestedCategory() }
    .task(id: selectedCategory) {
      guard needsServerAdministration, !model.requiresProfileSelection, !model.isStarting else {
        isLoadingAdministration = false
        return
      }
      // Loading changes the whole model; waiting until Settings has faded in keeps that smooth.
      if !hasSettled {
        try? await Task.sleep(for: .milliseconds(240))
        hasSettled = true
        if Task.isCancelled { return }
      }
      isLoadingAdministration = true
      await model.reloadAdministration()
      isLoadingAdministration = false
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(5)) } catch { break }
        if scenePhase == .active { await model.reloadDevices() }
      }
    }
    .onChange(of: scenePhase) {
      if scenePhase == .active, needsServerAdministration, !model.requiresProfileSelection,
        !model.isStarting
      {
        Task { await model.reloadDevices() }
      }
    }
    .sheet(item: $libraryToRelocate) { StorageLocationMovedSheet(library: $0) }
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
        "Its titles leave the library, with their favorites, progress and history for every profile. Your media files are never deleted or changed."
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
      "Disconnect This Mac?",
      isPresented: $showingDisconnectConfirmation,
      titleVisibility: .visible
    ) {
      Button("Disconnect This Mac", role: .destructive) {
        Task { await model.disconnect() }
      }
    } message: {
      Text(
        "To connect to this server again, you will need a new pairing code. Offline downloads stored on this Mac can no longer be opened without the server."
      )
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
    .sheet(isPresented: $showingLibraryHealth) {
      LibraryHealthView().environmentObject(model)
    }
  }

  private func takeRequestedCategory() {
    guard let requested = model.requestedSettingsCategory else { return }
    selectedCategory = requested
    searchText = ""
    model.requestedSettingsCategory = nil
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    VStack(spacing: 12) {
      AureliaSearchField(
        prompt: "Search settings…", text: $searchText, identifier: "settings-search-field",
        compact: true
      )
      .padding(.horizontal, 12)
      // Below the window buttons and Done.
      .padding(.top, 52)

      ScrollView {
        VStack(spacing: 2) {
          ForEach(SettingsCategory.allCases) { category in
            if shouldShowCategory(category) {
              settingsSidebarButton(category)
            }
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
      }
      .scrollContentBackground(.hidden)
    }
  }

  private func settingsSidebarButton(_ category: SettingsCategory) -> some View {
    let isSelected = selectedCategory == category && searchText.isEmpty
    return Button {
      selectedCategory = category
      searchText = ""
    } label: {
      HStack(spacing: 10) {
        Image(systemName: category.symbol)
          .font(.system(size: 14, weight: .medium))
          .frame(width: 20)
          .foregroundStyle(isSelected ? Color.white : .secondary)
        Text(category.rawValue)
          .font(
            .system(
              size: 13,
              weight: isSelected ? .semibold : .regular)
          )
          .foregroundStyle(isSelected ? Color.white : .primary)
        Spacer()
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 10)
      .background(
        RoundedRectangle(cornerRadius: AureliaDesign.tinyRadius, style: .continuous)
          .fill(isSelected ? Color.accentColor : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable(false)
    .accessibilityIdentifier("settings-tab-\(category.id.lowercased())")
  }

  private func shouldShowCategory(_ category: SettingsCategory) -> Bool {
    switch category {
    case .general, .sidebar, .activity, .playback, .profilesAndDevices, .updates, .advanced,
      .about:
      return true
    case .library:
      return model.canManageStorage
    case .metadata, .server:
      return model.canManageMedia
    case .power:
      return model.profile?.user?.role == .owner
    }
  }

  private var needsServerAdministration: Bool {
    switch selectedCategory {
    case .library, .metadata, .profilesAndDevices, .server, .power: true
    default: false
    }
  }

  // MARK: - Detail Area

  @ViewBuilder
  private var detailArea: some View {
    let topError = SettingsErrorBannerPolicy.topError(
      category: selectedCategory,
      administrationError: model.administrationErrorMessage,
      modelError: model.errorMessage)
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          Color.clear
            .frame(height: 0)
            .id("settings-top")

          if let topError {
            ErrorBanner(
              message: topError,
              retry: {
                Task {
                  if model.canRestoreLocalHosting {
                    await model.restoreLocalHosting()
                  } else if model.serverUnreachable {
                    await model.retryConnection()
                    await model.reloadAdministration()
                  } else {
                    await model.reloadAdministration()
                  }
                }
              },
              retryLabel: model.canRestoreLocalHosting ? "Start Local Server" : "Try Again",
              retryDisabled: model.isRecoveringLocalHost || isLoadingAdministration,
              inline: true)
          }

          if !searchText.isEmpty {
            searchResultsView
          } else {
            categoryView(selectedCategory)
          }
        }
        .padding(26)
        .frame(maxWidth: AureliaDesign.settingsMaxContentWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        .aureliaSettingRows()
      }
      .id(selectedCategory)
      // Another category shows at once; it no longer springs in (audit M3).
      .transition(.identity)
      .scrollContentBackground(.hidden)
      .aureliaOverlayScrollbars()
      .onChange(of: selectedCategory) {
        proxy.scrollTo("settings-top", anchor: .top)
      }
    }
    .aureliaAnimation(AureliaMotion.standard, value: searchText.isEmpty)
  }

  @ViewBuilder
  private func categoryView(_ category: SettingsCategory) -> some View {
    switch category {
    case .general:
      generalSections
    case .sidebar:
      sidebarSections
    case .activity:
      activitySections
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
    case .power:
      ServerManagementView(.power)
      ServerPowerNowSection()
    case .updates:
      updatesSections
    case .advanced:
      advancedSections
    case .about:
      AboutAureliaSections()
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

      if queryMatches(
        query, "start screen poster rows hero motion interface display wish wishes notifications")
      {
        interfaceDisplaySection
        let _ = { foundAny = true }()
      }
      if queryMatches(
        query,
        "sidebar navigation modular items order hide show movies series tv shows watchlist collections home"
      ) {
        sidebarSections
        let _ = { foundAny = true }()
      }
      if queryMatches(
        query, "activity statistics watch time hours streak stats genres habits history")
      {
        activitySections
        let _ = { foundAny = true }()
      }
      if queryMatches(query, "quit window close rest energy sleep power mac") {
        windowSystemSection
        let _ = { foundAny = true }()
      }
      if model.profile?.user?.role == .owner
        && queryMatches(
          query, "power sleep shut down turn off wake lan unused idle energy awake hours server")
      {
        ServerManagementView(.power)
        ServerPowerNowSection()
        let _ = { foundAny = true }()
      }
      if queryMatches(
        query,
        "resume next countdown threshold auto night mode sleep good night timer skip intro credits")
      {
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
        && queryMatches(query, "offline hidden titles health duplicates")
      {
        catalogVisibilitySection
        let _ = { foundAny = true }()
      }
      if model.canManageMedia
        && queryMatches(query, "tmdb token metadata artwork enrich queue review movie info")
      {
        metadataSections
        let _ = { foundAny = true }()
      }
      if queryMatches(query, "profile pin password account avatar current name picture photo") {
        currentProfileSection
        let _ = { foundAny = true }()
      }
      if model.canManageMedia
        && queryMatches(
          query,
          "user accounts profiles create edit delete devices streaming pairing authorized sessions revoke"
        )
      {
        userAccountsSection
        let _ = { foundAny = true }()
      }
      if model.canManageMedia
        && queryMatches(
          query,
          "server status uptime health hosting background scrub previews thumbnails backup restore power sleep network port diagnostics jobs limits"
        )
      {
        ServerManagementView()
        let _ = { foundAny = true }()
      }
      if queryMatches(
        query,
        "updates check new version mac app server release notes token github pat private beta test pre-release"
      ) {
        updatesSections
        let _ = { foundAny = true }()
      }
      if queryMatches(query, "connection address fingerprint disconnect restart host") {
        serverConnectionSection
        let _ = { foundAny = true }()
      }
      if queryMatches(
        query, "about version build introduction tour getting started github source legal license"
      ) {
        AboutAureliaSections()
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
          AureliaSettingPicker("Default Start Screen", selection: $defaultStartScreen) {
            ForEach(StartScreenPreference.allCases) { screen in
              Text(screen.label).tag(screen.rawValue)
            }
          }
          .accessibilityIdentifier("interface-start-screen")
        }

        LabeledContent("Poster Size") {
          AureliaSettingPicker("Poster Size", selection: $posterSize) {
            ForEach(PosterSizePreference.allCases) { size in
              Text(size.label).tag(size.rawValue)
            }
          }
          .accessibilityIdentifier("interface-poster-size")
        }

        Divider()

        VStack(alignment: .leading, spacing: 2) {
          Toggle("Show Watched Titles in Rows", isOn: $showWatchedInRows)
            .accessibilityIdentifier("interface-show-watched")
          Text("Keeps finished titles in Favorites, genre rows and Recently Added on Home.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .aureliaSettingsDescriptionWidth()
        }

        VStack(alignment: .leading, spacing: 2) {
          Toggle("Reduce Motion", isOn: $reduceHeroMotion)
            .accessibilityIdentifier("interface-hero-motion")
          Text("Turns off sliding and zooming animations in Aurelia, as the system setting does.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .aureliaSettingsDescriptionWidth()
        }

        if model.supportsWishes {
          Divider()
          VStack(alignment: .leading, spacing: 2) {
            Toggle("Family Wish Notifications", isOn: $wishNotificationsEnabled)
              .accessibilityIdentifier("interface-wish-notifications")
            Text(
              "Shows a macOS notification when someone adds a family wish or when your wish enters the library while Aurelia is open."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .aureliaSettingsDescriptionWidth()
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var sidebarNavigationSection: some View {
    AureliaSettingsSection(
      "Sidebar Navigation",
      symbol: "sidebar.left",
      description: "Choose which pages the sidebar shows and in which order."
    ) {
      HStack {
        Spacer()
        Button("Customize Sidebar…") {
          selectedCategory = .sidebar
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("interface-configure-sidebar-button")
      }
    }
  }

  // MARK: - Sidebar & Activity

  @ViewBuilder
  private var sidebarSections: some View {
    SidebarCustomizerView()
  }

  @ViewBuilder
  private var activitySections: some View {
    SettingsActivityView()
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
          Toggle("Let the Server Rest When Unused", isOn: $restsWhenUnused)
            .accessibilityIdentifier("interface-rest")
          LabeledContent("After") {
            AureliaSettingPicker("After", selection: $restMinutes) {
              ForEach(AureliaRest.minuteChoices, id: \.self) { minutes in
                Text("\(minutes) minutes").tag(minutes)
              }
            }
          }
          .padding(.top, 6)
          .disabled(!restsWhenUnused)
          Text(
            "When Aurelia is not used for this long, it disconnects so a server that saves power can sleep. Working in other apps does not count as using Aurelia."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .aureliaSettingsDescriptionWidth()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - 2. Playback

  @ViewBuilder
  private var playbackSections: some View {
    playbackBehaviorSection
    cinemaModeSection
    playerControlsSection
    audioSubtitlesSection
    HStack {
      Spacer()
      Button("Restore Playback Defaults") {
        playbackPreferences.restoreDefaults()
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("playback-restore-defaults")
    }
  }

  private var cinemaModeSection: some View {
    AureliaSettingsSection(
      "Cinema Mode",
      symbol: "popcorn.fill",
      description: "A pre-show before a film, as at the cinema."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 2) {
          Toggle("Cinema Mode", isOn: $playbackPreferences.preferences.cinemaMode)
            .accessibilityIdentifier("playback-cinema-mode")
          Text(
            "When a film starts from the beginning, an ad and trailers of films in your library you haven't watched yet come first. Return starts the film at any time."
          )
          .font(.caption).foregroundStyle(.secondary)
          .aureliaSettingsDescriptionWidth()
        }

        Group {
          VStack(alignment: .leading, spacing: 2) {
            Toggle("Cinema Bumper", isOn: $playbackPreferences.preferences.cinemaAds)
              .accessibilityIdentifier("playback-cinema-ads")
            Text("Plays a short built-in Aurelia cinema opener before the trailers.")
              .font(.caption).foregroundStyle(.secondary)
              .aureliaSettingsDescriptionWidth()
          }

          VStack(alignment: .leading, spacing: 2) {
            LabeledContent("Trailers") {
              AureliaSettingPicker(
                "Trailers", selection: $playbackPreferences.preferences.cinemaTrailers
              ) {
                Text("None").tag(0)
                Text("1").tag(1)
                Text("2").tag(2)
                Text("3").tag(3)
              }
              .accessibilityIdentifier("playback-cinema-trailers")
            }
            Text(
              "How many trailers for unwatched movies in your library play before the feature film."
            )
            .font(.caption).foregroundStyle(.secondary)
            .aureliaSettingsDescriptionWidth()
          }
        }
        .disabled(!playbackPreferences.preferences.cinemaMode)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var playbackBehaviorSection: some View {
    AureliaSettingsSection(
      "Playback Behavior",
      symbol: "play.circle.fill",
      description: "Starting position, auto-play, and audio comfort for media playback on this Mac."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 2) {
          Toggle("Automatic Resume", isOn: $playbackPreferences.preferences.automaticResume)
            .accessibilityIdentifier("playback-automatic-resume")
          Text("Play continues where you stopped instead of asking whether to start over.")
            .font(.caption).foregroundStyle(.secondary)
            .aureliaSettingsDescriptionWidth()
        }

        if model.supportsAdaptiveStreaming {
          VStack(alignment: .leading, spacing: 2) {
            LabeledContent("Streaming Quality") {
              AureliaSettingPicker(
                "Streaming Quality", selection: $playbackPreferences.preferences.streamingQuality
              ) {
                ForEach(StreamingQuality.allCases) { quality in Text(quality.title).tag(quality) }
              }
              .accessibilityIdentifier("playback-streaming-quality")
            }
            Text(
              "Original plays the file itself. The other choices let the server convert the title while it plays, in the quality your connection carries, which helps away from home."
            )
            .font(.caption).foregroundStyle(.secondary)
            .aureliaSettingsDescriptionWidth()
          }
        }

        if model.libraryCapabilities.contains(ServerFeatureNames.convertedDownloads) {
          VStack(alignment: .leading, spacing: 2) {
            LabeledContent("Download Quality") {
              AureliaSettingPicker("Download Quality", selection: $downloadQuality) {
                ForEach(DownloadQualityPreference.choices, id: \.id) { choice in
                  Text(choice.title).tag(choice.id)
                }
              }
              .accessibilityIdentifier("playback-download-quality")
            }
            Text(
              "Original keeps the file itself. A smaller quality has the server convert a copy while it downloads, which saves space on this Mac; a title that is already small keeps its original."
            )
            .font(.caption).foregroundStyle(.secondary)
            .aureliaSettingsDescriptionWidth()
          }
        }

        VStack(alignment: .leading, spacing: 2) {
          Toggle(
            "Automatically Play Next Episode",
            isOn: $playbackPreferences.preferences.automaticallyPlayNextEpisode
          )
          .accessibilityIdentifier("playback-auto-next")
          Text("When an episode ends, the next one starts after the countdown below.")
            .font(.caption).foregroundStyle(.secondary)
            .aureliaSettingsDescriptionWidth()
        }

        LabeledContent("Up Next Countdown Duration") {
          AureliaSettingPicker(
            "Up Next Countdown",
            selection: $playbackPreferences.preferences.upNextCountdownSeconds
          ) {
            ForEach([5, 10, 15, 20, 30], id: \.self) { sec in
              Text("\(sec) seconds").tag(sec)
            }
          }
          .accessibilityIdentifier("playback-upnext-countdown")
        }
        .disabled(!playbackPreferences.preferences.automaticallyPlayNextEpisode)

        if model.supportsMediaSegments {
          VStack(alignment: .leading, spacing: 2) {
            LabeledContent("Intros") {
              AureliaSettingPicker(
                "Intros", selection: $playbackPreferences.preferences.introSkipping
              ) {
                ForEach(IntroSkipping.allCases) { choice in Text(choice.title).tag(choice) }
              }
              .accessibilityIdentifier("playback-skip-intros")
            }
            Text(
              "Your server finds where an episode's intro is. Show Skip Intro offers a button while it plays (Return or S); Skip Automatically jumps past it once per episode, but never when you go back into it yourself."
            )
            .font(.caption).foregroundStyle(.secondary)
            .aureliaSettingsDescriptionWidth()
          }
          VStack(alignment: .leading, spacing: 2) {
            Toggle(
              "Offer Next Episode When Credits Begin",
              isOn: $playbackPreferences.preferences.upNextAtCredits
            )
            .disabled(!playbackPreferences.preferences.automaticallyPlayNextEpisode)
            .accessibilityIdentifier("playback-up-next-credits")
            Text(
              "Up Next appears when the credits begin, with the countdown above and Watch Credits. Turned off, or for episodes without known credits, it appears in the last seconds."
            )
            .font(.caption).foregroundStyle(.secondary)
            .aureliaSettingsDescriptionWidth()
          }
          VStack(alignment: .leading, spacing: 2) {
            Toggle(
              "Play Suggestions Automatically",
              isOn: $playbackPreferences.preferences.playSuggestionsAutomatically
            )
            .accessibilityIdentifier("playback-play-suggestions")
            Text(
              "When a movie or a series' last episode reaches its credits, your server suggests what to watch next, with Watch Now, Watch Credits and Done. Turned on, the suggestion starts by itself when the title ends; otherwise an end screen shows it with two more."
            )
            .font(.caption).foregroundStyle(.secondary)
            .aureliaSettingsDescriptionWidth()
          }
        }

        VStack(alignment: .leading, spacing: 2) {
          LabeledContent("Start Over If Barely Started") {
            AureliaSettingPicker(
              "Start Over Threshold",
              selection: $playbackPreferences.preferences.resumeThresholdSeconds
            ) {
              Text("Never").tag(0)
              Text("Under 30 seconds").tag(30)
              Text("Under 1 minute").tag(60)
              Text("Under 2 minutes").tag(120)
            }
            .accessibilityIdentifier("playback-resume-threshold")
          }
          Text("A title stopped within this time starts from the beginning next time.")
            .font(.caption).foregroundStyle(.secondary)
            .aureliaSettingsDescriptionWidth()
        }

        Divider()

        VStack(alignment: .leading, spacing: 2) {
          Toggle(
            "Prevent Sleep During Playback",
            isOn: $playbackPreferences.preferences.preventSleepDuringPlayback
          )
          .accessibilityIdentifier("playback-prevent-sleep")
          Text("Keeps this Mac and its display awake while a title plays.")
            .font(.caption).foregroundStyle(.secondary)
            .aureliaSettingsDescriptionWidth()
        }

        VStack(alignment: .leading, spacing: 2) {
          Toggle(
            "Show Good Night When the Sleep Timer Ends",
            isOn: $playbackPreferences.preferences.showGoodNightOnSleepTimer
          )
          .accessibilityIdentifier("playback-sleep-good-night")
          Text(
            "Shows a quiet Good-Night screen for 5 minutes when the sleep timer finishes instead of closing right away."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .aureliaSettingsDescriptionWidth()
        }

        VStack(alignment: .leading, spacing: 2) {
          Toggle(
            "Fill the Screen, Without Black Bars",
            isOn: $playbackPreferences.preferences.fillsScreen
          )
          .accessibilityIdentifier("playback-fill-screen")
          Text(
            "Cuts off the edges of pictures that are wider or narrower than the window. Z switches it in the player."
          )
          .font(.caption).foregroundStyle(.secondary)
          .aureliaSettingsDescriptionWidth()
        }

        VStack(alignment: .leading, spacing: 8) {
          LabeledContent("Dialogue Boost") {
            AureliaSettingPicker(
              "Dialogue Boost", selection: $playbackPreferences.preferences.dialogueBoost
            ) {
              ForEach(DialogueBoost.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("playback-dialogue-boost")
          }
          LabeledContent("Volume Leveling") {
            AureliaSettingPicker(
              "Volume Leveling", selection: $playbackPreferences.preferences.volumeLeveling
            ) {
              ForEach(VolumeLeveling.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("playback-volume-leveling")
          }
          Text(
            "Dialogue Boost makes speech clearer; Volume Leveling evens out quiet and loud passages, and Sleep evens them out more for late nights."
          )
          .font(.caption).foregroundStyle(.secondary)
          .aureliaSettingsDescriptionWidth()
        }
      }
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
          AureliaSettingPicker(
            "Default Playback Rate",
            selection: $playbackPreferences.preferences.defaultPlaybackRate
          ) {
            ForEach(PlaybackPreferences.supportedRates, id: \.self) { rate in
              Text(playbackRateLabel(rate)).tag(rate)
            }
          }
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
          AureliaSettingPicker(
            "Controls Auto-Hide Delay",
            selection: Binding(
              get: {
                SettingsChoiceNormalization.autoHideDelay(
                  playbackPreferences.preferences.controlsAutoHideDelay)
              },
              set: { playbackPreferences.preferences.controlsAutoHideDelay = $0 }
            )
          ) {
            ForEach(SettingsChoiceNormalization.autoHideDelayChoices, id: \.self) { value in
              Text("\(Int(value)) seconds").tag(value)
            }
          }
          .accessibilityIdentifier("playback-auto-hide-delay")
        }

        LabeledContent("Seek Interval") {
          AureliaSettingPicker(
            "Seek Interval",
            selection: Binding(
              get: {
                SettingsChoiceNormalization.seekInterval(
                  playbackPreferences.preferences.seekInterval)
              },
              set: { playbackPreferences.preferences.seekInterval = $0 }
            )
          ) {
            ForEach(SettingsChoiceNormalization.seekIntervalChoices, id: \.self) { value in
              Text("\(value) seconds").tag(value)
            }
          }
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
      description:
        "Default languages until you choose tracks for a series, and the remembered choices."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        LabeledContent("Default Audio Language") {
          AureliaSettingPicker(
            "Default Audio Language",
            selection: $playbackPreferences.preferences.defaultAudioLanguage
          ) {
            Text("Original").tag("original")
            Text("English").tag("en")
            Text("German").tag("de")
            Text("French").tag("fr")
            Text("Spanish").tag("es")
            Text("Italian").tag("it")
            Text("Japanese").tag("ja")
          }
          .accessibilityIdentifier("playback-audio-lang")
        }

        LabeledContent("Default Subtitle Language") {
          AureliaSettingPicker(
            "Default Subtitle Language",
            selection: $playbackPreferences.preferences.defaultSubtitleLanguage
          ) {
            Text("File Default").tag("off")
            Text("English").tag("en")
            Text("German").tag("de")
            Text("French").tag("fr")
            Text("Spanish").tag("es")
            Text("Italian").tag("it")
            Text("Japanese").tag("ja")
          }
          .accessibilityIdentifier("playback-sub-lang")
        }

        LabeledContent("Subtitle Size") {
          AureliaSettingPicker(
            "Subtitle Size", selection: $playbackPreferences.preferences.subtitleSize
          ) {
            ForEach(SubtitleSize.allCases) { Text($0.title).tag($0) }
          }
          .accessibilityIdentifier("playback-subtitle-size")
        }

        LabeledContent("Subtitle Background") {
          AureliaSettingPicker(
            "Subtitle Background", selection: $playbackPreferences.preferences.subtitleBackground
          ) {
            ForEach(SubtitleBackground.allCases) { Text($0.title).tag($0) }
          }
          .accessibilityIdentifier("playback-subtitle-background")
        }
        Text("Subtitle size and background apply from the next title you open.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .aureliaSettingsDescriptionWidth()

        Divider()

        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Remembered Track Choices")
            Text("Aurelia remembers the tracks you choose, separately for each series.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .aureliaSettingsDescriptionWidth()
          }
          Spacer()
          Button("Forget Track Choices") {
            PlaybackTrackPreferenceStore.shared.forgetAll()
          }
          .accessibilityIdentifier("playback-forget-tracks")
        }
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
    libraryHealthSection
    catalogVisibilitySection
  }

  private var libraryHealthSection: some View {
    AureliaSettingsSection(
      "Library Health & Maintenance",
      symbol: "stethoscope",
      description:
        "Inspect duplicate titles, manage missing or offline files, and resolve unmatched metadata."
    ) {
      HStack {
        Spacer()
        Button("Open Library Health…") {
          showingLibraryHealth = true
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("open-library-health")
      }
    }
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
            AureliaDelayedProgress(controlSize: .small)
              .accessibilityLabel("Loading storage")
          } else {
            Text("No storage locations yet.")
              .foregroundStyle(.secondary)
          }
        }

        ForEach(model.libraries) { library in
          HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
              .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(library.name).font(.headline).lineLimit(1)
              Text(library.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Text(AureliaStateLabels.libraryAvailability(library.availability))
              .font(.caption).foregroundStyle(.secondary).fixedSize()
            Button("Scan") { Task { await model.scanLibrary(id: library.id) } }
              .fixedSize()
              .disabled(library.importPreviewRequired == true)
            Button("Moved…") { libraryToRelocate = library }
              .fixedSize()
              .help("Storage Location Moved: point it at the folder where its files are now")
              .accessibilityLabel("Storage Location Moved for \(library.name)")
            Button(role: .destructive) {
              libraryToRemove = library
            } label: {
              Image(systemName: "trash")
            }
            .help("Remove This Storage Location…")
            .accessibilityLabel("Remove \(library.name)")
          }
          if library.id != model.libraries.last?.id { Divider() }
        }

        if !model.activeScans.isEmpty {
          ProgressView("Scanning in the background…")
        }

        Divider()

        HStack(alignment: .center, spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Manage Media & Assignments").font(.headline)
            Text(
              "Assign target titles, verify seasons, tag extras or trailers, and manage folder import rules."
            )
            .font(.caption).foregroundStyle(.secondary)
            .aureliaSettingsDescriptionWidth()
          }
          Spacer()
          Button("Manage Media…") { showingMediaManager = true }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("add-storage-locations")
        }
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
          "On this Mac, hides titles whose file or drive is unavailable. Their details and progress stay. Watch for Changes on a storage location rescans automatically."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
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
          Button(metadataJobRunning ? "Enriching…" : "Enrich Shared Libraries") {
            Task { await model.enrichLibrary() }
          }
          .disabled(model.libraries.isEmpty || metadataJobRunning)
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
            Button(metadataJobRunning ? "Enriching…" : "Enrich Library") {
              Task { await model.enrichLibrary() }
            }
            .disabled(metadataJobRunning)
            .accessibilityIdentifier("metadata-enrich")
            Button("Review Queue") { showingReviewQueue = true }
            Button("Remove Unused Artwork") { Task { await model.pruneArtwork() } }
            Button("Remove TMDB Token…", role: .destructive) {
              guard
                AureliaConfirm.ask(
                  "Remove the TMDB Token?",
                  "New titles get no posters or descriptions until you add a token again. What's already there stays.",
                  action: "Remove Token")
              else { return }
              Task { await model.disableMetadata() }
            }
            .accessibilityIdentifier("metadata-remove-token")
          }
          if let job = model.metadataJob, let summary = job.finishedSummary {
            // A finished job says so plainly instead of leaving a full progress bar behind.
            Label(
              summary,
              systemImage: job.state == .completed
                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(job.state == .completed ? Color.green : Color.orange)
            .accessibilityIdentifier("metadata-job-finished")
          } else if let job = model.metadataJob {
            ProgressView(value: Double(job.itemsProcessed), total: Double(max(job.itemsTotal, 1))) {
              Text("Finding metadata: \(job.itemsProcessed) of \(job.itemsTotal)")
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
          Button(savingToken ? "Enabling…" : "Enable TMDB") {
            // The token stays in the field until the server took it, so a failure needs no retyping.
            let token = tmdbToken
            savingToken = true
            Task {
              await model.configureMetadata(token: token)
              if model.metadataProvider?.hasToken == true { tmdbToken = "" }
              savingToken = false
            }
          }
          .disabled(
            savingToken || tmdbToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    if model.canManageMedia {
      SubtitleDownloadSettingsSection()
    }
  }

  // MARK: - 5. Profiles and Devices

  @ViewBuilder
  private var profilesAndDevicesSections: some View {
    currentProfileSection
    if model.canManageMedia {
      userAccountsSection
    }
  }

  private var currentProfileSection: some View {
    AureliaSettingsSection(
      "Current Profile",
      symbol: "person.crop.circle",
      description: "Change your name, picture and PIN."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        if let user = model.profile?.user {
          HStack(spacing: 14) {
            AureliaProfileAvatar(user: user, size: 44)
            VStack(alignment: .leading, spacing: 2) {
              Text(user.shownName).font(.headline)
              Text("Role: \(AureliaStateLabels.userRole(user.role))").font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if model.profile?.isViewingSession == true {
              Button("Switch Profile") { Task { await model.switchWatchingProfile() } }
            }
          }
          Divider()
          if model.supportsProfilePersonalization, model.profile?.isViewingSession == true {
            OwnProfileEditor(user: user).id(
              "\(user.id)-\(user.profileRevision)-\(user.pictureRevision)")
            Divider()
          }
        }

        if model.profile?.isViewingSession == true {
          ChangeProfilePINView()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// Profiles and paired devices, with the same approval and deletion handling as before.
  private var userAccountsSection: some View {
    ServerManagementView(.people)
  }

  // MARK: - 6. Server

  @ViewBuilder
  /// Hosting, pairing, health, scrub previews, backups, network, jobs and diagnostics, shaped by
  /// where the server runs (in Aurelia on this Mac, another Mac or the Linux package).
  private var serverSections: some View {
    ServerManagementView()
  }

  // MARK: - 7. Updates

  @ViewBuilder
  private var updatesSections: some View {
    AureliaSettingsSection(
      "Mac App Updates",
      symbol: "macwindow.badge.plus",
      description:
        "App updates come directly from GitHub. No server connection or profile PIN is needed. Your library, settings, and sign-ins remain safe."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        LabeledContent(
          "Installed Version", value: "\(updater.currentVersion) (\(updater.currentBuild))")
        LabeledContent("Status", value: updateStatusText)

        if let locationIssue = updater.installLocationIssue {
          Text(locationIssue.message)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else if updater.state == .downloading || updater.state == .installing {
          AppUpdateProgressBar(updater: updater)
          if updater.state == .downloading {
            Button("Cancel Download") { updater.cancelInstall() }
              .accessibilityIdentifier("updates-cancel")
          }
        } else if case .available(let release) = updater.state {
          Button("Install \(release.version) and Restart") { updater.startInstall(release) }
            .buttonStyle(AureliaPrimaryActionButtonStyle())
            .accessibilityIdentifier("updates-install")
          if model.isLocalHost {
            Text(
              "Your server on this Mac will stop for about a minute during the update, so anyone watching will be interrupted."
            )
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }

        Toggle("Check for Updates Automatically", isOn: $automaticUpdateChecks)
          .accessibilityIdentifier("updates-automatic")

        Toggle("Beta Updates", isOn: $betaUpdates)
          .accessibilityIdentifier("updates-beta")
        Text(AppUpdateBetaOnly.explanation)
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Button("Check for Updates…") {
          Task { await updater.check(userInitiated: true) }
        }
        .disabled(updater.isBusy)
        .accessibilityIdentifier("updates-check")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }

    if model.canManageMedia, !model.requiresProfileSelection, let profile = model.profile {
      ServerUpdatesEditor(client: APIClient(profile: profile))
        .id(profile.sessionId)
    } else {
      AureliaSettingsSection("Server Updates", symbol: "arrow.down.circle") {
        Text("Connect to your server and unlock an administrator profile to manage its updates.")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var updateStatusText: String {
    switch updater.state {
    case .idle: updater.repository == nil ? "Release builds only" : "Not checked yet"
    case .checking: "Checking for updates…"
    case .upToDate: "Up to date"
    case .available(let release): "\(release.version) (\(release.build)) is available"
    case .downloading:
      "Downloading \(updater.installingRelease.map { "\($0.version) (\($0.build))" } ?? "update")…"
    case .installing: "Installing… Aurelia will reopen by itself."
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
              value: "\(user.username) · \(AureliaStateLabels.userRole(user.role))")
          }
          Divider()
          if model.operatingMode == .host {
            if profile.user?.role != .owner {
              LabeledContent(
                "Status", value: AureliaStateLabels.hostState(model.hostSnapshot.state))
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
            Button("Disconnect This Mac…", role: .destructive) {
              showingDisconnectConfirmation = true
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

// MARK: - Settings Policies & Labels

/// Deduplicates page-level server errors so Settings shows one visible banner at the top.
enum SettingsErrorBannerPolicy {
  static func topError(
    category: SettingsCategory,
    administrationError: String?,
    modelError: String?
  ) -> String? {
    guard category != .updates else { return nil }
    let admin = administrationError?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let admin, !admin.isEmpty { return admin }
    let general = modelError?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let general, !general.isEmpty { return general }
    return nil
  }

  static func shouldShowSectionError(
    _ sectionError: String?,
    pageAdministrationError: String?,
    pageModelError: String?
  ) -> Bool {
    guard let trimmed = sectionError?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else { return false }
    let admin = pageAdministrationError?.trimmingCharacters(in: .whitespacesAndNewlines)
    let general = pageModelError?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed != admin && trimmed != general
  }
}

/// Maps stored preference values onto the nearest picker option so menus never render blank.
enum SettingsChoiceNormalization {
  static let autoHideDelayChoices: [Double] = [2.0, 3.0, 5.0, 8.0]
  static let seekIntervalChoices: [Int] = [5, 10, 15, 20, 30, 45, 60]

  static func autoHideDelay(_ stored: Double) -> Double {
    autoHideDelayChoices.min { abs($0 - stored) < abs($1 - stored) } ?? 3.0
  }

  static func seekInterval(_ stored: Int) -> Int {
    seekIntervalChoices.min { abs($0 - stored) < abs($1 - stored) } ?? 15
  }
}

/// Human-readable labels for enum states (never raw `camelCase.capitalized` like "Setuprequired").
enum AureliaStateLabels {
  static func hostState(_ state: NativeHostState) -> String {
    switch state {
    case .starting: "Starting"
    case .setupRequired: "Setup Required"
    case .running: "Running"
    case .restarting: "Restarting"
    case .stopping: "Stopping"
    case .stopped: "Stopped"
    case .failed: "Failed"
    case .idle: "Idle"
    }
  }

  static func libraryAvailability(_ availability: LibraryAvailability) -> String {
    switch availability {
    case .available: "Available"
    case .unavailable: "Unavailable"
    case .error: "Access Error"
    case .unknown: "Unknown"
    }
  }

  static func userRole(_ role: UserRole) -> String {
    switch role {
    case .owner: "Owner"
    case .admin: "Administrator"
    case .user: "User"
    }
  }
}

// MARK: - Sidebar Customizer

struct SidebarCustomizerView: View {
  @AppStorage(GeneralPreferenceKeys.sidebarVisibilityRevision) private var visibilityRevision = 0
  @State private var items: [LibraryDestination] = SidebarPreferences.loadOrder()
  @State private var dragged: LibraryDestination?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      // The start screen is chosen once, in General › Interface & Display.
      AureliaSettingsSection(
        "Sidebar Items",
        symbol: "sidebar.left",
        description:
          "Choose which pages appear in the sidebar and in which order. Drag an item by its handle to move it, or switch it off to hide it."
      ) {
        VStack(spacing: 8) {
          ForEach(Array(items.enumerated()), id: \.element) { index, item in
            HStack(spacing: 12) {
              Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 24)
                .contentShape(Rectangle())
                .help("Drag to Move")
                .onDrag {
                  dragged = item
                  return NSItemProvider(object: item.rawValue as NSString)
                }
                .accessibilityHidden(true)
                .accessibilityIdentifier("sidebar-drag-\(item.rawValue)")

              Image(systemName: item.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 24)
                .foregroundStyle(isItemVisible(item) ? Color.accentColor : Color.secondary)

              Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isItemVisible(item) ? Color.primary : Color.secondary)

              Spacer()

              Toggle(
                "",
                isOn: Binding(
                  get: { isItemVisible(item) },
                  set: { newValue in
                    toggleItemVisibility(item, isVisible: newValue)
                  }
                )
              )
              .labelsHidden()
              .toggleStyle(.switch)
              .disabled(isItemVisible(item) && visibleCount <= 1)
              .accessibilityLabel("Show \(item.title) in Sidebar")
              .accessibilityIdentifier("sidebar-toggle-\(item.rawValue)")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(AureliaDesign.raisedSurface.opacity(isItemVisible(item) ? 1.0 : 0.5))
            .clipShape(
              RoundedRectangle(cornerRadius: AureliaDesign.smallRadius, style: .continuous)
            )
            .opacity(dragged == item ? 0.55 : 1)
            .onDrop(
              of: [.text],
              delegate: SidebarReorderDropDelegate(
                target: item, items: $items, dragged: $dragged, commit: saveOrder)
            )
            // Keyboard and VoiceOver users move items without dragging.
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Move Up") { moveItem(from: index, to: index - 1) }
            .accessibilityAction(named: "Move Down") { moveItem(from: index, to: index + 1) }
          }

          HStack {
            Spacer()
            Button("Reset Sidebar to Defaults") {
              SidebarPreferences.resetToDefaults()
              items = SidebarPreferences.loadOrder()
              visibilityRevision += 1
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
            .accessibilityIdentifier("sidebar-reset-defaults")
          }
        }
        // A row dropped between rows or below the list keeps the order it was moved to.
        .onDrop(of: [.text], isTargeted: nil) { _ in
          guard dragged != nil else { return false }
          dragged = nil
          saveOrder()
          return true
        }
      }
    }
    .onAppear {
      items = SidebarPreferences.loadOrder()
    }
  }

  private var visibleCount: Int {
    items.filter { SidebarPreferences.isVisible($0) }.count
  }

  private func isItemVisible(_ destination: LibraryDestination) -> Bool {
    SidebarPreferences.isVisible(destination)
  }

  private func toggleItemVisibility(_ destination: LibraryDestination, isVisible: Bool) {
    if !isVisible && visibleCount <= 1 {
      return
    }
    SidebarPreferences.setVisible(destination, isVisible: isVisible)
    visibilityRevision += 1
  }

  private func moveItem(from: Int, to: Int) {
    guard to >= 0 && to < items.count else { return }
    items.swapAt(from, to)
    saveOrder()
  }

  private func saveOrder() {
    SidebarPreferences.saveOrder(items)
    visibilityRevision += 1
  }
}

/// Reorders the sidebar list live while a row is dragged by its handle; the order is saved on drop.
struct SidebarReorderDropDelegate: DropDelegate {
  let target: LibraryDestination
  @Binding var items: [LibraryDestination]
  @Binding var dragged: LibraryDestination?
  let commit: () -> Void

  func dropEntered(info: DropInfo) {
    guard let dragged, dragged != target, let to = items.firstIndex(of: target) else { return }
    withAnimation(.easeInOut(duration: 0.15)) {
      items = SidebarReorder.moving(dragged, to: to, in: items)
    }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

  func performDrop(info: DropInfo) -> Bool {
    dragged = nil
    commit()
    return true
  }
}

enum SidebarReorder {
  /// The list with `item` moved to `index`, keeping every other item in order.
  static func moving<Item: Equatable>(_ item: Item, to index: Int, in items: [Item]) -> [Item] {
    guard let from = items.firstIndex(of: item), index >= 0, index < items.count, from != index
    else {
      return items
    }
    var result = items
    result.remove(at: from)
    result.insert(item, at: index)
    return result
  }
}
