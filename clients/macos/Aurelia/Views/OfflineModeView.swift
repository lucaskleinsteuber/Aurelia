import AppKit
import SwiftUI

/// Aurelia without the server: the downloads on this Mac as a small library, and nothing that
/// needs the server (no settings, management, search or other profiles' titles).
struct OfflineModeView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Group {
      switch model.offlineMode {
      case .open(let session):
        OfflineLibraryView(session: session)
      case .choosingProfile, nil:
        OfflineProfileChooser()
      }
    }
    .accessibilityIdentifier("offline-mode")
  }
}

/// A small tag that says the app shows only what is on this Mac.
struct OfflineBadge: View {
  var body: some View {
    Label("Offline", systemImage: "wifi.slash")
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(.white.opacity(0.12), in: Capsule())
      .accessibilityLabel("Offline mode")
  }
}

// MARK: Profiles

/// Whose downloads to show. A PIN is checked on this Mac against the check value kept the last
/// time the profile opened with the server, so offline mode keeps profiles apart as before.
private struct OfflineProfileChooser: View {
  @EnvironmentObject private var model: AppModel
  @State private var choice: OfflineProfileCard?
  @State private var pin = ""
  @State private var error: String?
  @FocusState private var pinFocused: Bool

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: 30) {
          OfflineBadge()
          if let choice {
            unlock(choice)
          } else {
            VStack(spacing: 8) {
              Text("Watch Offline").font(.system(size: 40, weight: .bold)).tracking(-0.5)
              Text(
                "Aurelia stopped looking for the server. Choose whose downloads to show; they play from this Mac."
              )
              .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
              .frame(maxWidth: 460)
            }
            profiles
          }
          Button("Connect to Server") { Task { await model.leaveOfflineMode() } }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("offline-leave")
        }
        .padding(40)
        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
      }
      .scrollIndicators(.never)
    }
    .background { AureliaAmbientBackground() }
    .onExitCommand { if choice != nil { back() } }
  }

  private var profiles: some View {
    let choices = model.offlineProfileChoices
    return VStack(spacing: 18) {
      CenteredProfileLayout {
        ForEach(choices) { entry in
          Button {
            select(entry)
          } label: {
            VStack(spacing: 12) {
              AureliaProfileAvatar(
                id: entry.userId, name: entry.card?.name ?? "?", size: 112,
                pictureKey: entry.card?.pictureKey,
                pictureRevision: entry.card?.pictureRevision ?? 0
              )
              .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
              HStack(spacing: 5) {
                Text(entry.card?.name ?? "Profile").font(.headline).lineLimit(2)
                  .multilineTextAlignment(.center)
                if entry.card?.pinProtected == true {
                  Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                }
              }
              Text(downloadCount(entry.userId)).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: CenteredProfileLayout.entryWidth)
            .contentShape(Rectangle())
          }
          .buttonStyle(AureliaCardButtonStyle())
          .disabled(entry.card == nil)
          .opacity(entry.card == nil ? 0.5 : 1)
          .help(
            entry.card == nil
              ? "Open this profile once while the server answers to use its downloads offline."
              : "Show the downloads of \(entry.card?.name ?? "this profile")"
          )
          .accessibilityIdentifier("offline-profile-\(entry.userId.uuidString)")
        }
      }
      if choices.contains(where: { $0.card == nil }) {
        Text(
          "Dimmed profiles haven’t been opened on this Mac since the offline mode exists. Open them once while the server answers to use their downloads offline."
        )
        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        .frame(maxWidth: 460)
      }
    }
  }

  private func unlock(_ card: OfflineProfileCard) -> some View {
    VStack(spacing: 20) {
      Button(action: back) {
        AureliaProfileAvatar(
          id: card.userId, name: card.name, size: 112, pictureKey: card.pictureKey,
          pictureRevision: card.pictureRevision)
      }
      .buttonStyle(AureliaCardButtonStyle())
      .help("Choose another profile")
      VStack(spacing: 6) {
        Text(card.name).font(.title2.weight(.semibold))
        Text("Enter your PIN").font(.callout).foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        SecureField("PIN", text: $pin)
          .textFieldStyle(.plain).font(.system(size: 20, weight: .medium, design: .rounded))
          .multilineTextAlignment(.center)
          .focused($pinFocused)
          .onSubmit { submit(card) }
          .onChange(of: pin) { _, value in
            let digits = String(value.filter(\.isNumber).prefix(8))
            if digits != value { pin = digits }
          }
          .accessibilityLabel("Profile PIN")
          .accessibilityIdentifier("offline-profile-pin")
        Button {
          submit(card)
        } label: {
          Image(systemName: "arrow.right").font(.system(size: 15, weight: .bold))
            .foregroundStyle(pin.isEmpty ? Color.white.opacity(0.5) : Color.black)
            .frame(width: 36, height: 36)
            .background(Circle().fill(pin.isEmpty ? Color.white.opacity(0.12) : Color.white))
        }
        .buttonStyle(AureliaPressableButtonStyle())
        .disabled(pin.isEmpty)
        .accessibilityLabel("Open Profile")
      }
      .padding(.leading, 20).padding(.trailing, 8)
      .frame(width: 280, height: 52)
      .background(Capsule().fill(.ultraThinMaterial))
      .overlay { Capsule().strokeBorder(.white.opacity(0.16)) }
      TimelineView(.periodic(from: .now, by: 1)) { context in
        if let until = model.offlinePINLockedUntil, until > context.date {
          Text("Too many wrong PINs. Try again in \(Int(until.timeIntervalSince(context.date).rounded(.up))) s.")
            .font(.callout).foregroundStyle(.orange)
        } else if let error {
          Text(error).font(.callout).foregroundStyle(.orange)
        }
      }
      .frame(minHeight: 22)
    }
    .task(id: card.userId) {
      await Task.yield()
      pinFocused = true
    }
  }

  private func select(_ entry: OfflineProfileChoice) {
    guard let card = entry.card else { return }
    error = nil
    pin = ""
    if card.pinProtected {
      choice = card
    } else {
      model.openOfflineProfile(card, pin: "")
    }
  }

  private func submit(_ card: OfflineProfileCard) {
    guard !pin.isEmpty else { return }
    if !model.openOfflineProfile(card, pin: pin) {
      error = ProfilePIN.incorrect
      pin = ""
      pinFocused = true
    }
  }

  private func back() {
    choice = nil
    pin = ""
    error = nil
  }

  private func downloadCount(_ user: UUID) -> String {
    let count = OfflineDownloads.shared.titles.filter { $0.userId == user }.count
    return count == 1 ? "1 download" : "\(count) downloads"
  }

}

// MARK: Library

/// One profile's downloads, arranged like a small version of the library: a large picture of
/// the title to continue, Continue Watching, movies and each series with its episodes.
private struct OfflineLibraryView: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject private var downloads = OfflineDownloads.shared
  let session: OfflineSession
  @State private var detail: OfflineTitle?

  private var layout: OfflineLibraryLayout { OfflineLibraryLayout(model.offlineModeTitles) }

  var body: some View {
    let layout = layout
    ScrollView {
      VStack(alignment: .leading, spacing: AureliaDesign.sectionSpacing) {
        if let featured = layout.featured {
          OfflineHero(title: featured) { detail = featured }
        }
        VStack(alignment: .leading, spacing: AureliaDesign.sectionSpacing) {
          if layout.featured == nil {
            ContentUnavailableView(
              "No Downloads", systemImage: "arrow.down.circle",
              description: Text(
                "This profile has no downloads on this Mac. Connect to the server to download titles."
              )
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
          }
          if !layout.continueWatching.isEmpty {
            section("Continue Watching", count: layout.continueWatching.count) {
              rail(layout.continueWatching, title: "Continue Watching")
            }
          }
          if !layout.movies.isEmpty {
            section("Movies", count: layout.movies.count) {
              LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 154, maximum: 154), spacing: 20)],
                alignment: .leading, spacing: 24
              ) {
                ForEach(layout.movies) { title in
                  Button { detail = title } label: { OfflinePosterCard(title: title) }
                    .buttonStyle(AureliaCardButtonStyle())
                    .contextMenu { menu(title) }
                }
              }
            }
          }
          ForEach(layout.series) { series in
            section(series.title, count: series.episodes.count) {
              rail(series.episodes, title: series.title)
            }
          }
        }
        .padding(.horizontal, AureliaDesign.pagePadding)
        .padding(.bottom, AureliaDesign.pagePadding)
      }
    }
    .scrollIndicators(.never)
    .background(AureliaDesign.canvas)
    .overlay(alignment: .top) { topBar }
    .sheet(item: $detail) { title in
      OfflineTitleDetail(title: title).environmentObject(model)
    }
  }

  private var topBar: some View {
    HStack(spacing: 12) {
      OfflineBadge()
      Text("Only downloads on this Mac. Progress goes to the server when it answers again.")
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      Spacer(minLength: 12)
      Menu {
        if model.offlineProfileChoices.count > 1 {
          Button("Switch Profile", systemImage: "person.2") { model.chooseOtherOfflineProfile() }
        }
        Button("Connect to Server", systemImage: "arrow.clockwise") {
          Task { await model.leaveOfflineMode() }
        }
      } label: {
        HStack(spacing: 8) {
          AureliaProfileAvatar(
            id: session.userId, name: session.name, size: 26, pictureKey: session.pictureKey,
            pictureRevision: session.pictureRevision)
          Text(session.name).font(.callout.weight(.semibold))
        }
      }
      .menuStyle(.button)
      .buttonStyle(AureliaPressableButtonStyle())
      .fixedSize()
      .accessibilityIdentifier("offline-profile-menu")
      Button("Connect to Server") { Task { await model.leaveOfflineMode() } }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("offline-leave")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial, in: Capsule())
    .padding(.top, 12)
    .padding(.horizontal, 80)
  }

  private func section<Content: View>(
    _ title: String, count: Int, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      AureliaSectionHeading(title: title, count: count)
      content()
    }
  }

  private func rail(_ titles: [OfflineTitle], title: String) -> some View {
    AureliaHorizontalRail(cardWidth: 300, itemCount: titles.count, title: title) {
      ForEach(titles) { entry in
        Button { detail = entry } label: { OfflineLandscapeCard(title: entry) }
          .buttonStyle(AureliaCardButtonStyle())
          .contextMenu { menu(entry) }
      }
    }
  }

  @ViewBuilder private func menu(_ title: OfflineTitle) -> some View {
    Button(title.isInProgress ? "Resume" : "Play", systemImage: "play.fill") {
      model.playOffline(title)
    }
    Button("Details", systemImage: "info.circle") { detail = title }
  }
}

/// The large picture at the top: backdrop, title, description and Play.
private struct OfflineHero: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject private var downloads = OfflineDownloads.shared
  let title: OfflineTitle
  let showDetails: () -> Void

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      Group {
        if let image = downloads.artwork(title, backdrop: true)
          ?? downloads.artwork(title, series: true) ?? downloads.artwork(title)
        {
          Image(nsImage: image).resizable().scaledToFill()
        } else {
          MediaArtworkPlaceholder(symbol: title.isEpisode ? "tv" : "film", symbolSize: 64)
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: 460)
      .clipped()
      .overlay {
        LinearGradient(
          colors: [.clear, AureliaDesign.canvas.opacity(0.65), AureliaDesign.canvas],
          startPoint: .center, endPoint: .bottom)
      }
      .overlay {
        LinearGradient(
          colors: [AureliaDesign.canvas.opacity(0.75), .clear], startPoint: .leading,
          endPoint: .center)
      }
      VStack(alignment: .leading, spacing: 10) {
        Text(title.isInProgress ? "Continue Watching" : "Downloaded")
          .font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
        Text(title.isEpisode ? OfflineLibraryLayout.seriesName(title) : title.title)
          .font(AureliaDesign.heroTitle).lineLimit(2)
        Text(OfflineTitleText.meta(title)).font(.callout).foregroundStyle(.secondary)
        if let overview = title.overview, !overview.isEmpty {
          Text(overview).font(.callout).lineLimit(3).frame(maxWidth: 560, alignment: .leading)
        }
        HStack(spacing: 12) {
          Button {
            model.playOffline(title)
          } label: {
            Label(title.isInProgress ? "Resume" : "Play", systemImage: "play.fill")
          }
          .buttonStyle(AureliaPrimaryActionButtonStyle())
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("offline-hero-play")
          Button("Details", action: showDetails).buttonStyle(.bordered)
          if title.isInProgress {
            ProgressView(value: title.watchedShare).frame(width: 120).tint(.white)
          }
        }
        .padding(.top, 6)
      }
      .padding(.horizontal, AureliaDesign.pagePadding)
      .padding(.bottom, 24)
    }
  }
}

private struct OfflinePosterCard: View {
  @ObservedObject private var downloads = OfflineDownloads.shared
  let title: OfflineTitle
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      ZStack(alignment: .bottom) {
        if let image = downloads.artwork(title) {
          Image(nsImage: image).resizable().scaledToFill()
        } else {
          MediaArtworkPlaceholder(symbol: "film")
        }
        OfflineProgressBar(title: title)
      }
      .frame(width: 154, height: 231)
      .clipShape(RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous)
          .stroke(hovering ? .white.opacity(0.35) : AureliaDesign.hairline, lineWidth: 1)
      }
      Text(title.title).font(.headline).lineLimit(1).frame(width: 154, alignment: .leading)
      Text(title.year.map(String.init) ?? "Movie").font(.caption).foregroundStyle(.secondary)
        .frame(width: 154, alignment: .leading)
    }
    .scaleEffect(hovering ? 1.035 : 1)
    .animation(.spring(response: 0.3, dampingFraction: 0.78), value: hovering)
    .onHover { hovering = $0 }
  }
}

private struct OfflineLandscapeCard: View {
  @ObservedObject private var downloads = OfflineDownloads.shared
  let title: OfflineTitle
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ZStack(alignment: .bottom) {
        if let image = downloads.artwork(title, backdrop: true)
          ?? downloads.artwork(title, series: true) ?? downloads.artwork(title)
        {
          Image(nsImage: image).resizable().scaledToFill()
        } else {
          MediaArtworkPlaceholder(symbol: title.isEpisode ? "tv" : "film")
        }
        OfflineProgressBar(title: title)
      }
      .frame(width: 300, height: 169)
      .clipShape(RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous)
          .stroke(hovering ? .white.opacity(0.35) : AureliaDesign.hairline, lineWidth: 1)
      }
      if let label = title.episodeLabel {
        Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      }
      Text(title.title).font(.headline).lineLimit(1).frame(width: 300, alignment: .leading)
    }
    .scaleEffect(hovering ? 1.03 : 1)
    .animation(.spring(response: 0.3, dampingFraction: 0.78), value: hovering)
    .onHover { hovering = $0 }
  }
}

private struct OfflineProgressBar: View {
  let title: OfflineTitle

  var body: some View {
    if title.isInProgress {
      GeometryReader { geometry in
        VStack {
          Spacer()
          Capsule().fill(.black.opacity(0.42)).frame(height: 4)
            .overlay(alignment: .leading) {
              Capsule().fill(.white).frame(width: geometry.size.width * title.watchedShare)
            }
            .padding(8)
        }
      }
    } else if title.isCompleted {
      HStack {
        Spacer()
        VStack {
          Image(systemName: "checkmark.circle.fill").font(.caption.weight(.bold))
            .padding(8).background(.black.opacity(0.44), in: Circle()).padding(8)
            .accessibilityLabel("Watched")
          Spacer()
        }
      }
    }
  }
}

/// A download's details: backdrop, description, Play and Remove.
private struct OfflineTitleDetail: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var downloads = OfflineDownloads.shared
  let title: OfflineTitle
  @State private var confirmingRemoval = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack(alignment: .bottomLeading) {
        Group {
          if let image = downloads.artwork(title, backdrop: true)
            ?? downloads.artwork(title, series: true)
          {
            Image(nsImage: image).resizable().scaledToFill()
          } else {
            MediaArtworkPlaceholder(symbol: title.isEpisode ? "tv" : "film", symbolSize: 54)
          }
        }
        .frame(width: 620, height: 300)
        .clipped()
        .overlay {
          LinearGradient(
            colors: [.clear, AureliaDesign.canvas], startPoint: .center, endPoint: .bottom)
        }
        VStack(alignment: .leading, spacing: 4) {
          if title.isEpisode {
            Text(OfflineLibraryLayout.seriesName(title)).font(.headline)
              .foregroundStyle(.secondary)
          }
          Text(title.title).font(.title.bold()).lineLimit(2)
        }
        .padding(24)
      }
      VStack(alignment: .leading, spacing: 14) {
        Text(OfflineTitleText.meta(title)).font(.callout).foregroundStyle(.secondary)
        if let overview = title.overview, !overview.isEmpty {
          ScrollView { Text(overview).frame(maxWidth: .infinity, alignment: .leading) }
            .frame(maxHeight: 140)
        }
        if let genres = title.genres, !genres.isEmpty {
          Text(genres.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
        }
        HStack(spacing: 12) {
          Button {
            dismiss()
            model.playOffline(title)
          } label: {
            Label(title.isInProgress ? "Resume" : "Play", systemImage: "play.fill")
          }
          .buttonStyle(AureliaPrimaryActionButtonStyle())
          .keyboardShortcut(.defaultAction)
          Button("Remove Download", role: .destructive) { confirmingRemoval = true }
          Spacer()
          Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
      }
      .padding(24)
    }
    .frame(width: 620)
    .background(AureliaDesign.canvas)
    .confirmationDialog("Remove \(title.title)?", isPresented: $confirmingRemoval) {
      Button("Remove Download", role: .destructive) {
        downloads.remove(title.id)
        dismiss()
      }
    } message: {
      Text("The copy on this Mac is deleted. The title stays on the server.")
    }
  }
}

enum OfflineTitleText {
  /// "2019 · S1 E3 · 1.2 GB · 40 % watched" for a download.
  static func meta(_ title: OfflineTitle) -> String {
    var parts: [String] = []
    if let label = title.episodeLabel { parts.append(label) }
    if let year = title.year { parts.append(String(year)) }
    if title.durationMilliseconds > 0 {
      let minutes = Int(title.durationMilliseconds / 60_000)
      parts.append(minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min")
    }
    parts.append(ByteCountFormatter.string(fromByteCount: title.bytes, countStyle: .file))
    if title.isCompleted {
      parts.append("Watched")
    } else if title.isInProgress {
      parts.append("\(Int(title.watchedShare * 100)) % watched")
    }
    if title.progressDirty { parts.append("Progress not yet on the server") }
    return parts.joined(separator: " · ")
  }
}
