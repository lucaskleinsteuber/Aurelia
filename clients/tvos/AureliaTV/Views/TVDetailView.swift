import SwiftUI

struct TVDetailView: View {
  @EnvironmentObject private var model: TVAppModel
  let id: UUID
  let initial: TVCatalogItem
  var selectedEpisodeID: UUID? = nil
  @StateObject private var actions = TVLibraryActions()
  @State private var playingQueue: [TVCatalogItem] = []
  @State private var launching = false
  @State private var launchTask: Task<Void, Never>?
  @State private var navigationID = UUID()
  @State private var detail: TVCatalogDetail?
  @State private var plan: TVPlaybackPlan?
  @State private var selectedSeason: Int?
  @State private var loading = true
  @State private var error: String?
  @State private var playing: TVCatalogItem?
  @State private var firstLoad = true
  @State private var requestID = UUID()
  @State private var focusRequest: FocusRequest?
  @State private var launchOrigin: Focus = .play
  @State private var choosingSeason = false
  @State private var shelfAnchor: Focus?
  @FocusState private var focused: Focus?

  private enum Focus: Hashable {
    case play, season
    case episode(UUID)
  }
  private struct FocusRequest {
    let id = UUID()
    let target: Focus
  }
  private var item: TVCatalogItem { model.overlay(detail?.item ?? initial) }
  private var seasons: [TVSeason] { detail?.seasons ?? [] }
  private var season: TVSeason? { seasons.first { $0.number == selectedSeason } }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 46) {
          hero.id("detail-top")
          if let error {
            VStack(alignment: .leading, spacing: 18) {
              TVErrorText(message: error)
              Button("Try Again") { Task { await load() } }.buttonStyle(TVButtonStyle())
            }.padding(.horizontal, TVDesign.pagePadding)
          }
          if item.kind == .series && !seasons.isEmpty { episodes }
        }.padding(.bottom, 80)
      }
      .ignoresSafeArea(edges: .top)
      .background(TVDesign.canvas.ignoresSafeArea())
      .task(id: model.detailRefresh) { await load() }
      .task(id: focusRequest?.id) {
        guard let request = focusRequest, playing == nil else { return }
        await Task.yield()
        if case .episode = request.target { shelfAnchor = request.target }
        proxy.scrollTo(
          request.target == .play ? AnyHashable("detail-top") : AnyHashable("detail-episodes"),
          anchor: .top)
        await Task.yield()
        guard !Task.isCancelled, !loading, playing == nil, focusRequest?.id == request.id else {
          return
        }
        focused = request.target
        // Applied once; a later background refresh must not pull focus back here.
        focusRequest = nil
      }
      .confirmationDialog("Season", isPresented: $choosingSeason, titleVisibility: .visible) {
        ForEach(seasons, id: \.number) { value in
          Button(value.number == 0 ? "Specials" : "Season \(value.number)") {
            selectedSeason = value.number
            shelfAnchor = value.episodes.first.map { .episode($0.item.id) }
          }.accessibilityIdentifier("season-option-\(value.number)")
        }
        Button("Cancel", role: .cancel) {}
      }
      .onChange(of: choosingSeason) { _, showing in if !showing { requestFocus(.season) } }
      .onChange(of: model.session?.sessionId) { _, _ in
        playing = nil
        focusRequest = nil
      }
      .fullScreenCover(
        item: $playing, onDismiss: playerDismissed,
        content: { target in
          if let connection = model.connection, let session = model.session {
            TVPlayerView(makeController: {
              TVPlaybackController(
                connection: connection, session: session, mediaID: target.id,
                title: target.episodeLabel.map { "\(item.title) · \($0)" } ?? target.title,
                outbox: model.environment.outbox,
                api: model.makeClient(connection: connection, session: session),
                runtime: model.environment.makePlaybackRuntime(),
                queue: playingQueue, preferencesStore: model.environment.preferences,
                onClose: { playing = nil },
                onSessionFailure: { failure in
                  guard model.session?.sessionId == session.sessionId else { return }
                  model.handleSessionFailure(failure)
                  playing = nil
                })
            })
          }
        })
    }
    .modifier(TVLibraryActionPresentation(actions: actions))
    .onDisappear {
      launchTask?.cancel()
      launchTask = nil
      navigationID = UUID()
    }
  }

  /// Full-bleed artwork with the title block and one compact action row.
  private var hero: some View {
    ZStack(alignment: .bottomLeading) {
      TVHeroBackdrop(artwork: item.backdrop ?? item.poster)
      VStack(alignment: .leading, spacing: 18) {
        TVEyebrow(text: eyebrow)
        Text(item.title).font(.system(size: 72, weight: .bold)).tracking(-0.8).lineLimit(2)
        if !item.genres.isEmpty {
          Text(item.genres.joined(separator: " · ")).font(.system(size: 24, weight: .semibold))
        }
        if let overview = detail?.metadata.overview ?? item.overview {
          Text(overview).font(.system(size: 26)).lineLimit(4)
            .frame(maxWidth: 1100, alignment: .leading).foregroundStyle(.white.opacity(0.88))
        }
        if let target = plan?.target, let unavailable = target.availabilityMessage {
          Label(unavailable, systemImage: "exclamationmark.triangle.fill").font(
            .system(size: 22, weight: .semibold)
          ).foregroundStyle(.orange)
        } else if !loading, plan?.target == nil {
          Text("No playable media available.").foregroundStyle(.secondary)
        }
        HStack(spacing: 26) {
          Button(action: playTarget) {
            Label(playLabel, systemImage: "play.fill")
          }.buttonStyle(TVButtonStyle(kind: .primary))
            .disabled(loading || launching || plan?.target?.isPlayable != true)
            .focused($focused, equals: .play).accessibilityIdentifier("detail-play")
          if item.kind == .movie || item.kind == .series {
            Button {
              Task { await actions.favorite(item, model: model) }
            } label: {
              Image(systemName: item.isFavorite ? "star.fill" : "star")
            }.buttonStyle(TVButtonStyle(kind: .icon))
              .accessibilityIdentifier("detail-favorite")
              .accessibilityLabel(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")
          }
          Menu {
            TVMediaContextActions(item: item, actions: actions, includeFavorite: false)
            if item.kind == .series, let selectedSeason {
              let name = selectedSeason == 0 ? "Specials" : "Season \(selectedSeason)"
              Button("Mark \(name) as Watched") { seasonWatch(true) }
              Button("Mark \(name) as Unwatched", role: .destructive) { seasonWatch(false) }
            }
          } label: {
            Image(systemName: "ellipsis")
          }.buttonStyle(TVButtonStyle(kind: .icon))
            .accessibilityIdentifier("detail-more").accessibilityLabel("More")
          if loading { ProgressView().accessibilityIdentifier("detail-loading") }
        }.padding(.top, 14).focusSection()
      }.padding(.horizontal, TVDesign.pagePadding).padding(.bottom, 40)
    }.frame(maxWidth: .infinity, minHeight: 820, alignment: .bottomLeading)
  }

  /// Season selection above a horizontal shelf that opens at the target episode.
  private var episodes: some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack(alignment: .firstTextBaseline, spacing: 22) {
        Button {
          choosingSeason = true
        } label: {
          Label(
            selectedSeason == 0 ? "Specials" : "Season \(selectedSeason ?? 1)",
            systemImage: "chevron.down"
          )
          .labelStyle(TVTrailingIconLabelStyle())
        }
        .buttonStyle(TVButtonStyle()).focused($focused, equals: .season)
        .accessibilityIdentifier("detail-season")
        .accessibilityLabel(selectedSeason == 0 ? "Specials" : "Season \(selectedSeason ?? 1)")
        if let count = season?.episodes.count {
          Text(count == 1 ? "1 episode" : "\(count) episodes").font(
            .system(size: 22, weight: .semibold)
          )
          .foregroundStyle(.tertiary)
        }
      }.padding(.horizontal, TVDesign.pagePadding).focusSection()
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: 44) {
          ForEach(season?.episodes ?? [], id: \.item.id) { value in
            let episode = model.overlay(value.item)
            Button {
              launchTask?.cancel()
              launchTask = Task { await openEpisode(episode) }
            } label: {
              TVEpisodeCard(item: episode)
            }.buttonStyle(.borderless)
              .contextMenu { TVMediaContextActions(item: episode, actions: actions) }
              .disabled(!episode.isPlayable || launching)
              .focused($focused, equals: .episode(episode.id))
              .id(Focus.episode(episode.id))
              .accessibilityIdentifier("detail-episode-\(episode.id)")
          }
        }.scrollTargetLayout().padding(.horizontal, TVDesign.pagePadding).padding(.vertical, 16)
      }.scrollIndicators(.hidden).scrollClipDisabled()
        .scrollPosition(id: $shelfAnchor, anchor: .leading)
        // Entering the shelf from above starts at the resume or first episode.
        .defaultFocus($focused, shelfEntry, priority: .userInitiated).focusSection()
    }.id("detail-episodes")
  }

  private var shelfEntry: Focus? {
    let episodes = season?.episodes.map(\.item) ?? []
    let target =
      episodes.first { $0.id == plan?.target?.id && $0.isPlayable }
      ?? episodes.first { $0.isPlayable }
    return target.map { .episode($0.id) }
  }

  private var eyebrow: String {
    [
      item.kindLabel, item.year.map(String.init),
      detail?.metadata.runtimeMinutes.map { "\($0) min" }, detail?.metadata.contentRating,
    ].compactMap { $0 }.joined(separator: " · ")
  }

  private func requestFocus(_ target: Focus) { focusRequest = FocusRequest(target: target) }
  private func playerDismissed() {
    model.playerPresented = false
    Task {
      await load()
      if case .episode(let id) = launchOrigin,
        !seasons.flatMap(\.episodes).contains(where: { $0.item.id == id && $0.item.isPlayable })
      {
        requestFocus(.season)
      } else {
        requestFocus(launchOrigin)
      }
    }
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
  private func playTarget() {
    if let target = plan?.target { open(target, queue: plan?.queue ?? [], origin: .play) }
  }
  private func openEpisode(_ episode: TVCatalogItem) async {
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
      open(target, queue: selected.queue, origin: .episode(episode.id))
    } catch {
      guard !Task.isCancelled, model.session?.sessionId == sessionID else { return }
      self.error = error.localizedDescription
      model.handleSessionFailure(error)
    }
  }
  private func open(_ item: TVCatalogItem, queue: [TVCatalogItem], origin: Focus) {
    guard item.isPlayable, playing == nil else { return }
    playingQueue = queue
    launchOrigin = origin
    focusRequest = nil
    model.playerPresented = true
    playing = item
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
        shelfAnchor = (newPlan.target?.kind == .episode ? newPlan.target?.id : nil).map {
          .episode($0)
        }
      }
      loading = false
      if let focusRequest, playing == nil { requestFocus(focusRequest.target) }
      if firstLoad {
        if newPlan.target?.isPlayable == true {
          requestFocus(.play)
        } else if !newDetail.seasons.isEmpty {
          requestFocus(.season)
        }
        firstLoad = false
      }
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

/// Episode thumbnail with the title, progress and badges below the artwork.
private struct TVEpisodeCard: View {
  let item: TVCatalogItem
  private let width: CGFloat = 420
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      TVArtworkView(artwork: item.backdrop ?? item.poster, width: 800, symbol: "play.rectangle")
        .frame(width: width, height: width * 9 / 16)
        .overlay(alignment: .topTrailing) { TVItemBadges(item: item).padding(10) }
        .overlay(alignment: .bottom) {
          if let fraction = item.progressFraction {
            TVProgressBar(fraction: fraction).padding(.horizontal, 14).padding(.bottom, 14)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: TVDesign.cardRadius, style: .continuous))
        .hoverEffect(.highlight)
      Text("\(item.episodeLabel ?? "Episode") · \(item.title)").font(
        .system(size: 23, weight: .semibold)
      )
      .lineLimit(2)
      if let message = item.availabilityMessage {
        Text(message).font(.system(size: 19, weight: .semibold)).foregroundStyle(.orange)
      } else if let overview = item.overview {
        Text(overview).font(.system(size: 19)).foregroundStyle(.secondary).lineLimit(2)
      }
    }.frame(width: width, alignment: .leading).opacity(item.isPlayable ? 1 : 0.55)
  }
}

/// Places a label's icon after its title, as in a pop-up button.
private struct TVTrailingIconLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 12) {
      configuration.title
      configuration.icon.font(.system(size: 18, weight: .bold))
    }
  }
}
