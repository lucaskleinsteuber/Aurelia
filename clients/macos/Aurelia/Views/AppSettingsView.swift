import AppKit
import SwiftUI

struct AppSettingsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var libraryToRemove: LibrarySummary?
  @State private var showingSwitchConfirmation = false
  @State private var pendingLocations: [StorageLocationDraft] = []
  @State private var showingCombineConfirmation = false
  @State private var isLoadingAdministration = false
  @State private var tmdbToken = ""
  @State private var showingReviewQueue = false
  @State private var showsAdvanced = false
  @State private var showingMediaManager = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text("Aurelia Settings").font(AureliaDesign.pageTitle)
        if let profile = model.profile {
          if profile.user?.role.canManageLibraries == true { storage }
          devices
          advanced(profile)
          if let error = model.errorMessage {
            Text(error).foregroundStyle(.orange)
          }
        } else if model.operatingMode != .host {
          ContentUnavailableView(
            "No Server Connected",
            systemImage: "network.slash",
            description: Text("Connect from the main window."))
        }
      }
      .padding(24)
    }
    .frame(width: 680, height: 680)
    .background(AureliaBackdrop())
    .task {
      isLoadingAdministration = true
      await model.reloadAdministration()
      isLoadingAdministration = false
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

  private var storage: some View {
    GroupBox("Storage") {
      VStack(alignment: .leading, spacing: 14) {
        Text("Aurelia recognizes movies and TV shows automatically in each location.")
          .font(.callout).foregroundStyle(.secondary)

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

        let unresolved = model.libraryDiscoveries.filter {
          $0.suggestedKind == nil && $0.decision == nil
        }
        if !unresolved.isEmpty {
          Divider()
          Text("Needs Your Help").font(.headline)
          Text("Aurelia did not guess these folders. Choose TV Show · Force Import for episode files without S01E01 names; their natural filename order becomes Season 1.")
            .font(.caption).foregroundStyle(.secondary)
          ForEach(unresolved) { discovery in
            DiscoveryDecisionCard(discovery: discovery)
          }
        }

        let recognized = model.libraryDiscoveries.filter {
          $0.suggestedKind != nil && $0.decision != .ignore
        }
        if !recognized.isEmpty {
          DisclosureGroup("Review Recognized Folders") {
            VStack(spacing: 8) {
              ForEach(recognized) { discovery in
                HStack {
                  Image(systemName: effectiveKind(discovery) == .movies ? "film" : "tv")
                  Text(discovery.detectedTitle).lineLimit(1)
                  Spacer()
                  Menu("Change") {
                    classificationButton("Movie", .movie, discovery)
                    classificationButton("TV Show · Force Import", .tvShows, discovery)
                    classificationButton("Ignore", .ignore, discovery)
                  }
                }
              }
            }
            .padding(.top, 8)
          }
        }

        let ignored = model.libraryDiscoveries.filter { $0.decision == .ignore }
        if !ignored.isEmpty {
          DisclosureGroup("Ignored Folders") {
            VStack(spacing: 8) {
              ForEach(ignored) { discovery in
                HStack {
                  Image(systemName: "eye.slash")
                  Text(discovery.detectedTitle).lineLimit(1)
                  Spacer()
                  Button("Review Again") {
                    Task { await model.reviewIgnoredDiscovery(discovery) }
                  }
                }
              }
            }
            .padding(.top, 8)
          }
        }

        Button("Manage Media…") { showingMediaManager = true }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("add-storage-locations")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
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
    GroupBox("Devices") {
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
          .buttonStyle(.borderedProminent)
        ForEach(model.sessions) { session in
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
      .padding(8)
    }
  }

  private func advanced(_ profile: StoredServerProfile) -> some View {
    CinemaMaterialCard {
      VStack(alignment: .leading, spacing: 10) {
        Button {
          showsAdvanced.toggle()
        } label: {
          HStack {
            Label("Advanced", systemImage: "gearshape.2")
              .font(.headline)
            Spacer()
            Image(systemName: "chevron.right")
              .foregroundStyle(.secondary)
              .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityIdentifier("settings-advanced")

        if showsAdvanced {
          Divider()
          LabeledContent("Server", value: profile.name)
          LabeledContent("Address", value: profile.baseURL.absoluteString)
          LabeledContent(
            "Fingerprint", value: FingerprintFormatter.display(profile.publicKeyFingerprint))
          if let user = profile.user {
            LabeledContent(
              "Signed In", value: "\(user.username) · \(user.role.rawValue.capitalized)")
          }
          if profile.user?.role.canManageLibraries == true {
            Divider()
            Text("Movie & TV Information").font(.headline)
            Text(
              "Add your own TMDB API Read Access Token to download English metadata and artwork. File paths are never sent."
            )
            .font(.caption).foregroundStyle(.secondary)
            if model.metadataProvider?.hasToken == true {
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
          if model.operatingMode == .host {
            LabeledContent("Status", value: model.hostSnapshot.state.rawValue.capitalized)
            Button("Restart Server") { Task { await model.restartNativeHost() } }
            Button("Switch to Another Server…", role: .destructive) {
              showingSwitchConfirmation = true
            }
          } else {
            Button("Disconnect This Mac", role: .destructive) {
              Task { await model.disconnect() }
            }
            .accessibilityIdentifier("disconnect-server")
          }
        }
      }
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
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
