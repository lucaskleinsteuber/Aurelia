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
        VStack(alignment: .leading, spacing: 42) {
          HStack(alignment: .top, spacing: 42) {
            TVArtworkView(
              artwork: item.poster, width: 640, symbol: item.kind == .series ? "tv" : "film"
            )
            .frame(width: 270, height: 405).clipShape(RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 22) {
              Text(item.title).font(.system(size: 48, weight: .bold)).lineLimit(3)
              HStack(spacing: 22) {
                if let year = item.year { Text(String(year)) }
                if let runtime = detail?.metadata.runtimeMinutes { Text("\(runtime) min") }
                if let rating = detail?.metadata.contentRating { Text(rating) }
              }.font(.callout).foregroundStyle(.secondary)
              if !item.genres.isEmpty {
                Text(item.genres.joined(separator: " · ")).font(.callout).foregroundStyle(
                  .secondary)
              }
              if let overview = detail?.metadata.overview ?? item.overview {
                Text(overview).font(.system(size: 27)).lineLimit(6)
              }
              HStack(spacing: 22) {
                Button(action: playTarget) {
                  Label(playLabel, systemImage: "play.fill")
                }.buttonStyle(TVButtonStyle()).focusEffectDisabled()
                  .disabled(loading || launching || plan?.target?.isPlayable != true)
                  .focused($focused, equals: .play).id(Focus.play)
                  .accessibilityIdentifier("detail-play")
                  .onMoveCommand { direction in
                    if direction == .down, !seasons.isEmpty { requestFocus(.season) }
                  }
                Menu {
                  TVMediaContextActions(item: item, actions: actions)
                } label: {
                  Label("More", systemImage: "ellipsis")
                }
                .buttonStyle(TVButtonStyle()).focusEffectDisabled()
                .accessibilityIdentifier("detail-more").disabled(actions.busy)
              }.focusSection()
              if let target = plan?.target, let unavailable = target.availabilityMessage {
                Text(unavailable).foregroundStyle(.secondary)
              } else if !loading, plan?.target == nil {
                Text("No playable media available.").foregroundStyle(.secondary)
              }
              if loading { ProgressView("Loading…").accessibilityIdentifier("detail-loading") }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.focusSection().id("detail-top")
          if let error {
            TVErrorText(message: error)
            Button("Try Again") { Task { await load() } }.buttonStyle(TVButtonStyle())
          }
          if item.kind == .series && !seasons.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
              HStack(spacing: 22) {
                Button(selectedSeason == 0 ? "Specials" : "Season \(selectedSeason ?? 1)") {
                  choosingSeason = true
                }
                .buttonStyle(TVButtonStyle()).focusEffectDisabled()
                .focused($focused, equals: .season).id(Focus.season)
                .accessibilityIdentifier("detail-season")
                .onMoveCommand { direction in
                  if direction == .up, plan?.target?.isPlayable == true { requestFocus(.play) }
                  if direction == .down,
                    let first = season?.episodes.first(where: { $0.item.isPlayable })
                  {
                    requestFocus(.episode(first.item.id))
                  }
                }
                Menu("Season Options") {
                  Button("Mark Season as Watched") { seasonWatch(true) }
                  Button("Mark Season as Unwatched", role: .destructive) { seasonWatch(false) }
                }.buttonStyle(TVButtonStyle()).accessibilityIdentifier("detail-season-options")
                  .disabled(actions.busy)
              }.focusSection()
              ForEach(season?.episodes ?? [], id: \.item.id) { value in
                let episode = TVEpisode(
                  item: model.overlay(value.item), seasonNumber: value.seasonNumber,
                  episodeNumber: value.episodeNumber)
                Button {
                  launchTask?.cancel()
                  launchTask = Task { await openEpisode(episode.item) }
                } label: {
                  HStack(spacing: 24) {
                    TVArtworkView(
                      artwork: episode.item.backdrop ?? episode.item.poster,
                      width: 320, symbol: "play.rectangle"
                    )
                    .frame(width: 230, height: 130).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 10) {
                      Text("\(episode.item.episodeLabel ?? "Episode") · \(episode.item.title)")
                        .font(.system(size: 28, weight: .semibold)).lineLimit(2)
                      if let overview = episode.item.overview {
                        Text(overview).font(.system(size: 24)).lineLimit(2).foregroundStyle(
                          .secondary)
                      }
                      if let message = episode.item.availabilityMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                      }
                      if let progress = episode.item.progress, progress.durationMilliseconds > 0,
                        !progress.isCompleted
                      {
                        ProgressView(
                          value: min(
                            1,
                            Double(progress.positionMilliseconds)
                              / Double(progress.durationMilliseconds))
                        )
                        .frame(maxWidth: 500)
                      }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if episode.item.watchState == "completed"
                      || episode.item.progress?.isCompleted == true
                    {
                      Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                    }
                  }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(TVButtonStyle(kind: .row)).focusEffectDisabled()
                  .contextMenu { TVMediaContextActions(item: episode.item, actions: actions) }
                  .disabled(!episode.item.isPlayable || launching).focused(
                    $focused, equals: .episode(episode.item.id)
                  )
                  .onMoveCommand { direction in
                    if direction == .up,
                      episode.item.id
                        == season?.episodes.first(where: { $0.item.isPlayable })?.item.id
                    {
                      requestFocus(.season)
                    }
                  }
                  .id(Focus.episode(episode.item.id)).accessibilityIdentifier(
                    "detail-episode-\(episode.item.id)")
              }
            }.focusSection()
          }
        }.padding(64)
      }
      .background {
        ZStack {
          TVDesign.canvas
          if let backdrop = item.backdrop {
            TVArtworkView(artwork: backdrop, width: 1920).opacity(0.14)
          }
        }.ignoresSafeArea()
      }
      .task(id: model.detailRefresh) { await load() }
      .task(id: focusRequest?.id) {
        guard let request = focusRequest, playing == nil else { return }
        await Task.yield()
        proxy.scrollTo(
          request.target == .play ? AnyHashable("detail-top") : AnyHashable(request.target),
          anchor: request.target == .play ? .top : .center)
        await Task.yield()
        guard !Task.isCancelled, !loading, playing == nil, focusRequest?.id == request.id else {
          return
        }
        focused = request.target
      }
      .confirmationDialog("Season", isPresented: $choosingSeason, titleVisibility: .visible) {
        ForEach(seasons, id: \.number) { value in
          Button(value.number == 0 ? "Specials" : "Season \(value.number)") {
            selectedSeason = value.number
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
