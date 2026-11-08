import SwiftUI
import UIKit

/// Downloads in Settings: titles kept on this device to watch without the server, and the ones
/// loading now.
struct IOSDownloadsView: View {
  @EnvironmentObject private var model: IOSAppModel
  @ObservedObject private var store: IOSOfflineStore
  @State private var playing: IOSOfflineTitle?

  init(store: IOSOfflineStore) { self.store = store }

  private var profile: IOSOfflineSession? { model.currentOfflineSession }
  private var titles: [IOSOfflineTitle] {
    profile.map { store.titles(serverID: $0.serverID, profileID: $0.profileID) } ?? []
  }
  private var loading: [IOSOfflinePending] {
    profile.map { store.pending(serverID: $0.serverID, profileID: $0.profileID) } ?? []
  }

  var body: some View {
    List {
      Section {
        LabeledContent("Used on This \(IOSDesign.deviceName)") {
          Text(store.totalBytes.formatted(.byteCount(style: .file)))
        }
        LabeledContent("Free") {
          Text(store.availableBytes.formatted(.byteCount(style: .file)))
        }
      } footer: {
        Text(
          "Downloaded titles play when the server is asleep or out of reach, for example on a train. Progress goes back to the server when it answers again."
        )
      }
      if let error = store.errorMessage {
        Section {
          Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
      }
      if !loading.isEmpty || !store.preparing.isEmpty {
        Section("Downloading") {
          ForEach(loading) { entry in
            IOSPendingDownloadRow(entry: entry, store: store)
          }
          if !store.preparing.isEmpty {
            HStack(spacing: 10) {
              ProgressView()
              Text("Preparing…").foregroundStyle(.secondary)
            }
          }
        }
      }
      if titles.isEmpty && loading.isEmpty && store.preparing.isEmpty {
        Section {
          ContentUnavailableView(
            "No Downloads", systemImage: "arrow.down.circle",
            description: Text(
              "Choose Download in a movie’s or episode’s menu to keep it on this \(IOSDesign.deviceName)."
            )
          )
          .accessibilityIdentifier("downloads-empty")
        }
      } else {
        IOSOfflineSections(titles: titles, store: store) { playing = $0 }
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle("Downloads")
    .accessibilityIdentifier("downloads-page")
    .iosOfflinePlayer(title: $playing, profile: profile, onClosed: model.offlinePlayerClosed)
  }
}

/// The offline mode: Aurelia without the server, showing only the downloads on this device.
struct IOSOfflineModeView: View {
  @EnvironmentObject private var model: IOSAppModel
  @ObservedObject private var store: IOSOfflineStore
  @State private var asking: IOSOfflineProfileCard?
  @State private var pin = ""
  @State private var rejected = false
  @State private var playing: IOSOfflineTitle?

  init(store: IOSOfflineStore) { self.store = store }

  var body: some View {
    NavigationStack {
      Group {
        if case .open(let profile) = model.offlineMode {
          List {
            IOSOfflineSections(
              titles: store.titles(serverID: profile.serverID, profileID: profile.profileID),
              store: store
            ) { playing = $0 }
          }
          .scrollContentBackground(.hidden)
          .navigationTitle("Downloads")
          .toolbar {
            ToolbarItem(placement: .topBarLeading) {
              Button("Profiles") { model.chooseOfflineProfile() }
            }
          }
          .iosOfflinePlayer(title: $playing, profile: profile, onClosed: {})
        } else {
          profiles
        }
      }
      .background(IOSDesign.canvas.ignoresSafeArea())
      .safeAreaInset(edge: .bottom) {
        Button("Connect to the Server") { model.leaveOfflineMode() }
          .buttonStyle(IOSButtonStyle(kind: .secondary, fullWidth: true))
          .padding(.horizontal, IOSDesign.margin).padding(.bottom, 8)
          .accessibilityIdentifier("offline-leave")
      }
    }
    .accessibilityIdentifier("offline-mode")
  }

  private var profiles: some View {
    let cards = model.connection.map { store.offlineProfiles(serverID: $0.serverID) } ?? []
    return VStack(spacing: 24) {
      Spacer()
      Image(systemName: "arrow.down.circle").font(.system(size: 44, weight: .medium))
        .foregroundStyle(.secondary)
      VStack(spacing: 8) {
        Text("Watch Downloads").font(.title.bold())
        Text("Choose whose downloads to watch. Everything plays from this \(IOSDesign.deviceName).")
          .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }
      .frame(maxWidth: 420)
      if cards.isEmpty {
        Text(
          "Open your profile once while the server answers, then its downloads open here too."
        )
        .font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        .frame(maxWidth: 420)
      }
      HStack(spacing: 24) {
        ForEach(cards) { card in
          Button {
            if card.pinProtected {
              pin = ""
              asking = card
            } else {
              _ = model.openOffline(card, pin: "")
            }
          } label: {
            VStack(spacing: 8) {
              IOSProfilePicture(
                id: card.profileID, name: card.name, size: 72, pictureKey: card.pictureKey,
                pictureRevision: card.pictureRevision)
              Text(card.name).font(.subheadline.weight(.semibold)).lineLimit(1)
              if card.pinProtected {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
              }
            }
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("offline-profile-\(card.profileID)")
        }
      }
      Spacer()
    }
    .padding(IOSDesign.margin)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .alert(
      asking.map { "PIN for \($0.name)" } ?? "PIN",
      isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })
    ) {
      SecureField("PIN", text: $pin).keyboardType(.numberPad)
      Button("Open") {
        if let card = asking, !model.openOffline(card, pin: pin) { rejected = true }
        asking = nil
      }
      Button("Cancel", role: .cancel) { asking = nil }
    }
    .alert(IOSProfilePIN.incorrect, isPresented: $rejected) {
      Button("OK") {}
    }
  }
}

/// A profile's downloads: Continue Watching, movies and series with their episodes.
private struct IOSOfflineSections: View {
  let titles: [IOSOfflineTitle]
  @ObservedObject var store: IOSOfflineStore
  let play: (IOSOfflineTitle) -> Void

  var body: some View {
    let layout = IOSOfflineLayout(titles)
    if !layout.continueWatching.isEmpty {
      Section("Continue Watching") {
        ForEach(layout.continueWatching) { row($0, series: true) }
      }
    }
    if !layout.movies.isEmpty {
      Section("Movies") {
        ForEach(layout.movies) { row($0) }
          .onDelete { offsets in offsets.map { layout.movies[$0].id }.forEach(store.remove) }
      }
    }
    ForEach(layout.series) { series in
      Section(series.title) {
        ForEach(series.episodes) { row($0) }
          .onDelete { offsets in offsets.map { series.episodes[$0].id }.forEach(store.remove) }
      }
    }
  }

  private func row(_ title: IOSOfflineTitle, series: Bool = false) -> some View {
    Button {
      play(title)
    } label: {
      HStack(spacing: 12) {
        IOSOfflinePicture(
          url: store.pictureURL(title, series: series && title.isEpisode)
            ?? store.pictureURL(title))
        VStack(alignment: .leading, spacing: 4) {
          Text(series && title.isEpisode ? title.playerTitle : episodeName(title))
            .font(.body.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
          Text(details(title)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          if title.isInProgress {
            IOSProgressBar(fraction: title.watchedShare).frame(width: 80)
          }
        }
        Spacer(minLength: 0)
        Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white.opacity(0.85))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button("Remove Download", systemImage: "trash", role: .destructive) {
        store.remove(title.id)
      }
    }
    .accessibilityIdentifier("offline-title-\(title.id)")
  }

  private func episodeName(_ title: IOSOfflineTitle) -> String {
    guard let label = title.episodeLabel else { return title.title }
    return "\(label) · \(title.title)"
  }

  private func details(_ title: IOSOfflineTitle) -> String {
    var parts: [String] = []
    if !title.isEpisode, let year = title.year { parts.append(String(year)) }
    parts.append(title.bytes.formatted(.byteCount(style: .file)))
    if title.isCompleted { parts.append("Watched") }
    if title.progressDirty { parts.append("Progress not yet on the server") }
    return parts.joined(separator: " · ")
  }
}

private struct IOSPendingDownloadRow: View {
  @EnvironmentObject private var model: IOSAppModel
  let entry: IOSOfflinePending
  @ObservedObject var store: IOSOfflineStore

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(entry.title.subtitle.map { "\(entry.title.title) · \($0)" } ?? entry.title.title)
          .font(.body.weight(.semibold)).lineLimit(1)
        Spacer()
        if entry.state == .downloading {
          Text("\(Int(entry.share * 100)) %").monospacedDigit().foregroundStyle(.secondary)
        }
      }
      if entry.state == .downloading {
        ProgressView(value: entry.share)
        Text(
          "\(entry.receivedBytes.formatted(.byteCount(style: .file))) of \(entry.title.bytes.formatted(.byteCount(style: .file)))"
        )
        .font(.caption).foregroundStyle(.secondary)
      } else if entry.state == .waiting {
        Text("Starts when the download before it is done").font(.caption).foregroundStyle(.secondary)
      } else {
        Label(entry.message ?? "The download stopped.", systemImage: "exclamationmark.circle")
          .font(.caption).foregroundStyle(.orange)
        Button("Try Again") { model.retryDownload(entry.id) }.font(.subheadline.weight(.semibold))
      }
    }
    .padding(.vertical, 2)
    .swipeActions {
      Button("Cancel", role: .destructive) { store.cancel(entry.id) }
    }
  }
}

/// A download's poster from this device, or a placeholder.
private struct IOSOfflinePicture: View {
  let url: URL?

  var body: some View {
    Group {
      if let url, let image = UIImage(contentsOfFile: url.path) {
        Image(uiImage: image).resizable().scaledToFill()
      } else {
        ZStack {
          IOSDesign.raised
          Image(systemName: "film").foregroundStyle(.secondary)
        }
      }
    }
    .frame(width: 52, height: 78)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .accessibilityHidden(true)
  }
}

/// Download, its progress, Try Again or Remove Download for one movie or episode.
struct IOSDownloadMenuItems: View {
  @EnvironmentObject private var model: IOSAppModel
  @ObservedObject private var store: IOSOfflineStore
  let item: IOSCatalogItem

  init(item: IOSCatalogItem, store: IOSOfflineStore) {
    self.item = item
    self.store = store
  }

  var body: some View {
    if item.kind == .movie || item.kind == .episode {
      if let entry = store.pending(item.id) {
        if entry.state == .failed {
          Button("Try Download Again", systemImage: "arrow.clockwise") {
            model.retryDownload(item.id)
          }
        }
        Button(
          entry.state == .downloading
            ? "Cancel Download (\(Int(entry.share * 100)) %)"
            : entry.state == .waiting ? "Cancel Waiting Download" : "Cancel Download",
          systemImage: "xmark.circle"
        ) { store.cancel(item.id) }
      } else if store.preparing.contains(item.id) {
        Button("Preparing Download…", systemImage: "arrow.down.circle") {}.disabled(true)
      } else if store.title(item.id) != nil {
        Button("Remove Download", systemImage: "trash", role: .destructive) {
          store.remove(item.id)
        }
      } else {
        Button("Download", systemImage: "arrow.down.circle") { model.download(item) }
          .disabled(!IOSOfflineRules.canDownload(item))
      }
    }
  }
}

extension View {
  /// Plays a download full screen with the normal player.
  func iosOfflinePlayer(
    title: Binding<IOSOfflineTitle?>, profile: IOSOfflineSession?,
    onClosed: @escaping @MainActor () -> Void
  ) -> some View {
    modifier(IOSOfflinePlayerModifier(title: title, profile: profile, onClosed: onClosed))
  }
}

private struct IOSOfflinePlayerModifier: ViewModifier {
  @EnvironmentObject private var model: IOSAppModel
  @Binding var title: IOSOfflineTitle?
  let profile: IOSOfflineSession?
  let onClosed: @MainActor () -> Void

  func body(content: Content) -> some View {
    content.fullScreenCover(item: $title, onDismiss: onClosed) { title in
      if let profile, let connection = model.connection {
        IOSPlayerView(makeController: {
          model.offlinePlayback(title: title, profile: profile, connection: connection)
            .controller(
              title: title, connection: connection, preferences: model.environment.preferences,
              onClose: { self.title = nil })
        })
      }
    }
  }
}
