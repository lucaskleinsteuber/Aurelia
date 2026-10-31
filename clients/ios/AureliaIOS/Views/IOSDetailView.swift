import SwiftUI

struct IOSDetailView: View {
  @EnvironmentObject private var model: IOSAppModel
  let id: UUID
  let initial: IOSCatalogItem
  var selectedEpisodeID: UUID? = nil
  @StateObject private var actions = IOSLibraryActions()
  @State private var launching = false
  @State private var launchTask: Task<Void, Never>?
  @State private var navigationID = UUID()
  @State private var detail: IOSCatalogDetail?
  @State private var plan: IOSPlaybackPlan?
  @State private var selectedSeason: Int?
  @State private var loading = true
  @State private var error: String?
  @State private var playing: IOSDetailPlayback?
  @State private var requestID = UUID()
  @State private var unavailable: IOSCatalogItem?
  @State private var showingAbout = false
  private var item: IOSCatalogItem { model.overlay(detail?.item ?? initial) }
  private var seasons: [IOSSeason] { detail?.seasons ?? [] }
  private var season: IOSSeason? { seasons.first { $0.number == selectedSeason } }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        header
        if let error {
          VStack(alignment: .leading, spacing: 12) {
            IOSErrorText(message: error)
            Button("Try Again") { Task { await load() } }.buttonStyle(IOSButtonStyle())
          }.padding(.horizontal, IOSDesign.margin)
        }
        if item.kind == .series && !seasons.isEmpty {
          episodes
          if let season, !season.supplements.isEmpty {
            supplementRails(season.supplements, prefix: "\(seasonName(season.number)) ")
          }
        }
        if let detail {
          if let franchise = detail.franchise, !franchise.items.isEmpty {
            franchiseRail(franchise)
          }
          supplementRails(detail.supplements, prefix: "")
          castAndCrew(detail.metadata.credits ?? [])
          about(detail)
        }
      }.padding(.bottom, 32)
    }
    .ignoresSafeArea(edges: .top)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .task(id: model.detailRefresh) { await load() }
    .sheet(isPresented: $showingAbout) {
      if let detail { IOSAboutSheet(detail: detail) }
    }
    .alert(
      "Not Available",
      isPresented: Binding(get: { unavailable != nil }, set: { if !$0 { unavailable = nil } }),
      presenting: unavailable
    ) { _ in
      Button("OK") { unavailable = nil }
    } message: { item in
      Text(
        "\(item.availabilityMessage ?? "This title can't be played right now.") Connect the drive on your Mac, then try again."
      )
    }
    .onChange(of: model.session?.sessionId) { _, _ in playing = nil }
    .fullScreenCover(
      item: $playing, onDismiss: playerDismissed,
      content: { request in
        // Everything the player needs travels with the request, so the cover never
        // reads a stale view state (such as Start Over) when it is created.
        let target = request.item
        if let connection = model.connection, let session = model.session {
          IOSPlayerView(makeController: {
            IOSPlaybackController(
              connection: connection, session: session, mediaID: target.id,
              title: target.episodeLabel.map { "\(item.title) · \($0)" } ?? target.title,
              outbox: model.environment.outbox,
              api: model.makeClient(connection: connection, session: session),
              runtime: model.environment.makePlaybackRuntime(),
              queue: request.queue,
              seriesID: target.kind == .episode ? target.parentId : nil,
              preferencesStore: model.environment.preferences,
              onClose: { playing = nil },
              onSessionFailure: { failure in
                guard model.session?.sessionId == session.sessionId else { return }
                model.handleSessionFailure(failure)
                playing = nil
              }, startOver: request.startOver)
          })
        }
      }
    )
    .modifier(IOSLibraryActionPresentation(actions: actions))
    .onDisappear {
      launchTask?.cancel()
      launchTask = nil
      navigationID = UUID()
    }
  }

  /// The artwork to the screen edges fading into the canvas, the title and facts below it on
  /// the canvas (bright artwork never sits behind text), then Play with round actions beside it.
  private var header: some View {
    VStack(spacing: 0) {
      IOSArtworkView(artwork: item.backdrop ?? item.poster, width: 1280, symbol: nil)
        .frame(maxWidth: .infinity).frame(height: IOSDesign.isPad ? 460 : 330)
        .clipped()
        .overlay {
          LinearGradient(
            stops: [
              .init(color: .black.opacity(0.4), location: 0),
              .init(color: .clear, location: 0.24),
              .init(color: .clear, location: 0.5),
              .init(color: IOSDesign.canvas.opacity(0.85), location: 0.86),
              .init(color: IOSDesign.canvas, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .accessibilityHidden(true)
      VStack(spacing: 16) {
        VStack(spacing: 6) {
          Text(item.title).font(.title.weight(.bold))
            .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
          if !facts.isEmpty {
            Text(facts).font(.footnote).foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
        if let target = plan?.target, let unavailable = target.availabilityMessage {
          Label(unavailable, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
        } else if !loading, plan?.target == nil {
          Text("No playable media available.").font(.footnote).foregroundStyle(.secondary)
        }
        HStack(spacing: 10) {
          Button {
            playTarget()
          } label: {
            HStack(spacing: 8) {
              if launching || (loading && plan == nil) {
                ProgressView().tint(.black)
              } else {
                Image(systemName: "play.fill")
              }
              Text(playLabel)
            }
          }
          .buttonStyle(IOSButtonStyle(kind: .primary, fullWidth: true))
          .disabled(launching)
          .accessibilityIdentifier("detail-play")
          if item.kind == .movie || item.kind == .series {
            Button {
              Task { await actions.favorite(item, model: model) }
            } label: {
              Image(systemName: item.isFavorite ? "star.fill" : "star")
            }
            .buttonStyle(IOSButtonStyle(kind: .icon))
            .accessibilityIdentifier("detail-favorite")
            .accessibilityLabel(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")
          }
          Menu {
            if plan?.action == .resume, plan?.target?.isPlayable == true {
              Button("Start Over", systemImage: "arrow.counterclockwise") {
                playTarget(startOver: true)
              }
              .accessibilityIdentifier("detail-start-over")
            }
            IOSMediaContextActions(item: item, actions: actions, includeFavorite: false)
            if item.kind == .series, let selectedSeason {
              let name = selectedSeason == 0 ? "Specials" : "Season \(selectedSeason)"
              Button("Mark \(name) as Watched", systemImage: "checkmark.circle") {
                seasonWatch(true)
              }
              Button("Mark \(name) as Unwatched", systemImage: "circle", role: .destructive) {
                seasonWatch(false)
              }
            }
          } label: {
            Image(systemName: "ellipsis").font(.body.weight(.semibold))
              .frame(width: 48, height: 48)
              .background(IOSDesign.raised, in: Circle())
              .contentShape(Circle())
          }
          .tint(.white)
          .accessibilityIdentifier("detail-more").accessibilityLabel("More")
        }
        if let target = plan?.target, let fraction = target.progressFraction {
          HStack(spacing: 10) {
            IOSProgressBar(fraction: fraction).frame(width: 72)
            if let left = remaining(target) {
              Text(left).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Spacer()
          }
          .accessibilityElement(children: .combine)
        }
        if let overview = detail?.metadata.overview ?? item.overview {
          Button {
            showingAbout = true
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(overview).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                .lineLimit(3).multilineTextAlignment(.leading)
              Text("More").font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(IOSContentButtonStyle()).disabled(detail == nil)
          .accessibilityHint("Shows the full description")
        }
      }
      .padding(.horizontal, IOSDesign.margin)
      .padding(.top, -44)
    }
  }

  /// "42 min left" for a title that has been started.
  private func remaining(_ target: IOSCatalogItem) -> String? {
    guard let progress = target.progress, progress.durationMilliseconds > 0 else { return nil }
    let minutes = Int(
      (Double(max(0, progress.durationMilliseconds - progress.positionMilliseconds)) / 60_000)
        .rounded(.up))
    guard minutes > 0 else { return nil }
    return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min left" : "\(minutes) min left"
  }

  /// The season picker above the season's episodes as a list, like the Apple TV app on iPhone.
  private var episodes: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Menu {
          Picker(
            "Season",
            selection: Binding(get: { selectedSeason ?? 1 }, set: { selectSeason($0) })
          ) {
            ForEach(seasons, id: \.number) { value in
              Text(seasonName(value.number)).tag(value.number)
            }
          }
        } label: {
          HStack(spacing: 6) {
            Text(seasonName(selectedSeason ?? 1)).font(.title3.weight(.bold))
            Image(systemName: "chevron.down").font(.footnote.weight(.bold))
          }.foregroundStyle(.white)
        }
        .disabled(seasons.count < 2)
        .accessibilityIdentifier("season-picker")
        Spacer()
        if let count = season?.episodes.count {
          Text(count == 1 ? "1 episode" : "\(count) episodes").font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, IOSDesign.margin)
      LazyVStack(spacing: 0) {
        ForEach(season?.episodes ?? [], id: \.item.id) { value in
          let episode = model.overlay(value.item)
          Button {
            launchTask?.cancel()
            launchTask = Task { await openEpisode(episode) }
          } label: {
            IOSEpisodeRow(item: episode, isNext: episode.id == plan?.target?.id)
          }
          .buttonStyle(IOSContentButtonStyle())
          .contextMenu { IOSMediaContextActions(item: episode, actions: actions) }
          .disabled(launching)
          .accessibilityIdentifier("detail-episode-\(episode.id)")
          if episode.id != season?.episodes.last?.item.id {
            Divider().overlay(.white.opacity(0.08)).padding(.leading, IOSDesign.margin)
          }
        }
      }
    }
  }

  /// Trailers and Extras as wide shelves; each card plays its supplement.
  @ViewBuilder
  private func supplementRails(_ supplements: [IOSSupplement], prefix: String) -> some View {
    ForEach(IOSDetailPresentation.supplementGroups(supplements), id: \.title) { group in
      VStack(alignment: .leading, spacing: 10) {
        IOSSectionHeader(title: prefix + group.title, count: group.items.count)
        IOSShelf {
          ForEach(group.items, id: \.item.id) { supplement in
            let value = model.overlay(supplement.item)
            Button {
              playSupplement(value)
            } label: {
              IOSSupplementCard(item: value, category: supplement.category)
            }.buttonStyle(IOSContentButtonStyle()).disabled(launching)
              .accessibilityIdentifier("supplement-\(value.id)")
          }
        }
      }
    }
  }

  private func franchiseRail(_ franchise: IOSCollection) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      IOSSectionHeader(title: "Part of the \(franchise.name)", count: franchise.items.count)
      IOSShelf {
        ForEach(franchise.items, id: \.id) { film in
          let value = model.overlay(film)
          NavigationLink {
            IOSDetailView(id: value.detailID, initial: value)
          } label: {
            IOSPosterLabel(item: value).frame(width: IOSDesign.posterWidth)
          }
          .buttonStyle(IOSContentButtonStyle())
        }
      }
    }
  }

  @ViewBuilder
  private func castAndCrew(_ credits: [IOSCredit]) -> some View {
    let people = IOSDetailPresentation.people(credits)
    if !people.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        IOSSectionHeader(title: "Cast & Crew", count: people.count)
        IOSShelf {
          ForEach(people) { person in
            if model.supportsWatchlist {
              NavigationLink {
                IOSPersonDetailView(name: person.name)
              } label: {
                IOSPersonLabel(person: person)
              }.buttonStyle(IOSContentButtonStyle())
                .accessibilityIdentifier("person-\(person.id)")
            } else {
              IOSPersonLabel(person: person).accessibilityIdentifier("person-\(person.id)")
            }
          }
        }
      }.accessibilityIdentifier("cast-and-crew")
    }
  }

  /// The facts of the title in two columns; the full text opens from the description above.
  private func about(_ detail: IOSCatalogDetail) -> some View {
    let fields = IOSDetailPresentation.information(detail)
    return VStack(alignment: .leading, spacing: 12) {
      IOSSectionHeader(title: "Information")
      LazyVGrid(
        columns: [
          GridItem(.flexible(), alignment: .topLeading),
          GridItem(.flexible(), alignment: .topLeading),
        ],
        alignment: .leading, spacing: 14
      ) {
        ForEach(fields, id: \.title) { field in
          VStack(alignment: .leading, spacing: 2) {
            Text(field.title).font(.caption).foregroundStyle(.secondary)
            Text(field.value).font(.subheadline)
          }
        }
      }
      .padding(.horizontal, IOSDesign.margin)
      .accessibilityIdentifier("detail-about")
    }
  }

  /// "TV Show · 2008 · Drama, Crime · 16", the facts under the title.
  private var facts: String {
    [
      item.kindLabel, item.year.map(String.init),
      detail?.metadata.runtimeMinutes.map { "\($0) min" },
      item.genres.isEmpty ? nil : item.genres.prefix(2).joined(separator: ", "),
      detail?.metadata.contentRating,
    ].compactMap { $0 }.joined(separator: " · ")
  }

  private func seasonName(_ number: Int) -> String { number == 0 ? "Specials" : "Season \(number)" }
  private func selectSeason(_ number: Int) { selectedSeason = number }
  private func playerDismissed() {
    model.playerPresented = false
    Task { await load() }
  }
  private var playLabel: String {
    let action: String
    let resumeEnabled =
      model.connection.flatMap { connection in
        model.session.map {
          model.environment.preferences.preferences(
            serverID: connection.serverID, profileID: $0.user.id
          ).automaticResume
        }
      } ?? true
    switch plan?.action {
    case .resume: action = resumeEnabled ? "Resume" : "Play"
    case .playAgain: action = "Play Again"
    default: action = "Play"
    }
    return plan?.target?.episodeLabel.map { "\(action) \($0)" } ?? action
  }
  private func seasonWatch(_ watched: Bool) {
    guard let selectedSeason else { return }
    Task {
      await actions.watch(
        item, scope: .season, season: selectedSeason, watched: watched, model: model)
    }
  }
  private func playSupplement(_ supplement: IOSCatalogItem) {
    guard supplement.isPlayable else {
      unavailable = supplement
      return
    }
    open(supplement, queue: [])
  }
  private func playTarget(startOver: Bool = false) {
    if let target = plan?.target {
      guard target.isPlayable else {
        unavailable = target
        return
      }
      open(target, queue: plan?.queue ?? [], startOver: startOver)
      return
    }
    guard !launching, playing == nil, let api = model.client else { return }
    launching = true
    let sessionID = model.session?.sessionId
    let navigation = navigationID
    Task {
      defer { launching = false }
      do {
        let selected = try await api.playbackPlan(mediaID: selectedEpisodeID ?? id)
        guard !Task.isCancelled, navigationID == navigation, model.session?.sessionId == sessionID,
          let target = selected.target
        else { return }
        plan = selected
        guard target.isPlayable else {
          unavailable = target
          return
        }
        open(target, queue: selected.queue, startOver: startOver)
      } catch {
        guard !Task.isCancelled, model.session?.sessionId == sessionID else { return }
        self.error = error.localizedDescription
        model.handleSessionFailure(error)
      }
    }
  }
  private func openEpisode(_ episode: IOSCatalogItem) async {
    guard episode.isPlayable else {
      unavailable = episode
      return
    }
    guard !launching, playing == nil, let api = model.client else { return }
    launching = true
    let sessionID = model.session?.sessionId
    let navigation = navigationID
    defer { launching = false }
    do {
      let selected = try await api.playbackPlan(mediaID: episode.id)
      guard !Task.isCancelled, navigationID == navigation, model.session?.sessionId == sessionID,
        let target = selected.target, target.id == episode.id
      else { return }
      open(target, queue: selected.queue)
    } catch {
      guard !Task.isCancelled, model.session?.sessionId == sessionID else { return }
      self.error = error.localizedDescription
      model.handleSessionFailure(error)
    }
  }
  private func open(_ item: IOSCatalogItem, queue: [IOSCatalogItem], startOver: Bool = false) {
    guard item.isPlayable, playing == nil else { return }
    model.playerPresented = true
    playing = IOSDetailPlayback(item: item, queue: queue, startOver: startOver)
  }
  private func load() async {
    guard let api = model.client else { return }
    let sessionID = model.session?.sessionId
    let request = UUID()
    requestID = request
    loading = detail == nil
    do {
      async let loadedDetail = api.detail(id: id)
      async let loadedPlan = api.playbackPlan(mediaID: selectedEpisodeID ?? id)
      let (newDetail, newPlan) = try await (loadedDetail, loadedPlan)
      guard !Task.isCancelled, requestID == request, model.session?.sessionId == sessionID else {
        return
      }
      detail = newDetail
      plan = newPlan
      error = nil
      model.updateSummary(newDetail.item)
      if selectedSeason == nil
        || !newDetail.seasons.contains(where: { $0.number == selectedSeason })
      {
        selectedSeason =
          newPlan.target?.seasonNumber ?? newDetail.seasons.first(where: { $0.number > 0 })?.number
          ?? newDetail.seasons.first?.number
      }
      loading = false
    } catch {
      guard !Task.isCancelled, requestID == request, model.session?.sessionId == sessionID else {
        return
      }
      loading = false
      self.error = error.localizedDescription
      model.handleSessionFailure(error)
    }
  }
}

/// One episode as a list row: its still with progress, number and title, and a short summary.
private struct IOSEpisodeRow: View {
  let item: IOSCatalogItem
  let isNext: Bool
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      IOSArtworkView(artwork: item.backdrop ?? item.poster, width: 320, symbol: "play.rectangle")
        .frame(width: IOSDesign.isPad ? 200 : 136, height: (IOSDesign.isPad ? 200 : 136) * 9 / 16)
        .overlay(alignment: .bottom) {
          if let fraction = item.progressFraction {
            IOSProgressBar(fraction: fraction).padding(.horizontal, 6).padding(.bottom, 6)
          }
        }
        .overlay(alignment: .topTrailing) { IOSItemBadges(item: item).padding(4) }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      VStack(alignment: .leading, spacing: 3) {
        Text(item.episodeLabel ?? "Episode").font(.caption.weight(.semibold))
          .foregroundStyle(isNext ? Color.accentColor : .secondary)
        Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
          .multilineTextAlignment(.leading)
        if let message = item.availabilityMessage {
          Text(message).font(.caption.weight(.semibold)).foregroundStyle(.orange).lineLimit(2)
        } else if let overview = item.overview {
          Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            .multilineTextAlignment(.leading)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, IOSDesign.margin).padding(.vertical, 10)
    .contentShape(Rectangle())
    .opacity(item.isPlayable ? 1 : 0.55)
  }
}

/// A wide card for trailers and extras with a play glyph over the artwork.
private struct IOSSupplementCard: View {
  let item: IOSCatalogItem
  let category: String
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ZStack {
        IOSArtworkView(artwork: item.backdrop ?? item.poster, width: 640, symbol: "film.stack")
        Image(systemName: "play.fill").font(.callout.weight(.bold))
          .frame(width: 36, height: 36).background(.ultraThinMaterial, in: Circle())
      }
      .frame(
        width: IOSDesign.landscapeWidth * 0.85, height: IOSDesign.landscapeWidth * 0.85 * 9 / 16
      )
      .overlay(alignment: .topTrailing) { IOSItemBadges(item: item).padding(5) }
      .clipShape(RoundedRectangle(cornerRadius: IOSDesign.cardRadius, style: .continuous))
      Text(item.title).font(.footnote.weight(.semibold)).lineLimit(1)
      Text(item.availabilityMessage ?? category).font(.caption)
        .foregroundStyle(item.availabilityMessage == nil ? Color.secondary : Color.orange)
        .lineLimit(1)
    }
    .frame(width: IOSDesign.landscapeWidth * 0.85, alignment: .leading)
    .opacity(item.isPlayable ? 1 : 0.55)
  }
}

/// A round portrait with the name and role below.
private struct IOSPersonLabel: View {
  let person: IOSPersonCard
  var body: some View {
    VStack(spacing: 6) {
      IOSArtworkView(artwork: person.profile, width: 320, symbol: "person.fill")
        .frame(width: 76, height: 76).clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 0.5))
      Text(person.name).font(.caption.weight(.semibold)).lineLimit(1)
      if let subtitle = person.subtitle {
        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
          .multilineTextAlignment(.center)
      }
    }.frame(width: 88)
  }
}

/// The full description and every information field.
private struct IOSAboutSheet: View {
  let detail: IOSCatalogDetail
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if let original = detail.metadata.originalTitle, original != detail.metadata.title {
            Text(original).font(.subheadline).foregroundStyle(.secondary)
          }
          Text(detail.metadata.overview ?? detail.item.overview ?? "No description available.")
            .font(.body)
          Divider()
          ForEach(IOSDetailPresentation.information(detail), id: \.title) { field in
            VStack(alignment: .leading, spacing: 2) {
              Text(field.title).font(.caption).foregroundStyle(.secondary)
              Text(field.value).font(.subheadline)
            }
          }
        }
        .padding(IOSDesign.margin).frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationTitle(detail.metadata.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.accessibilityIdentifier("about-done")
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

private struct IOSDetailPlayback: Identifiable {
  let item: IOSCatalogItem
  let queue: [IOSCatalogItem]
  let startOver: Bool
  var id: UUID { item.id }
}
