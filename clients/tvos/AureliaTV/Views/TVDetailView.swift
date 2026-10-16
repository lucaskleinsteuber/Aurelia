import SwiftUI

struct TVDetailView: View {
  @EnvironmentObject private var model: TVAppModel
  let id: UUID
  let initial: TVCatalogItem
  @State private var detail: TVCatalogDetail?
  @State private var plan: TVPlaybackPlan?
  @State private var selectedSeason: Int?
  @State private var loading = true
  @State private var error: String?
  @State private var playing: TVCatalogItem?
  @State private var firstLoad = true
  @State private var requestID = UUID()
  @FocusState private var focused: Focus?
  private enum Focus: Hashable {
    case play, season
    case episode(UUID)
  }

  private var item: TVCatalogItem { detail?.item ?? initial }
  private var seasons: [TVSeason] { detail?.seasons ?? [] }
  private var season: TVSeason? { seasons.first { $0.number == selectedSeason } }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 46) {
        HStack(alignment: .top, spacing: 46) {
          TVArtworkView(
            artwork: item.poster, width: 640, symbol: item.kind == .series ? "tv" : "film"
          )
          .frame(width: 270, height: 405).clipShape(RoundedRectangle(cornerRadius: 18))
          VStack(alignment: .leading, spacing: 24) {
            Text(item.title).font(.system(size: 48, weight: .bold)).lineLimit(3)
            HStack(spacing: 22) {
              if let year = item.year { Text(String(year)) }
              if let runtime = detail?.metadata.runtimeMinutes { Text("\(runtime) min") }
              if let rating = detail?.metadata.contentRating { Text(rating) }
            }.font(.callout).foregroundStyle(.secondary)
            if !item.genres.isEmpty {
              Text(item.genres.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
            }
            if let overview = detail?.metadata.overview ?? item.overview {
              Text(overview).font(.system(size: 27)).lineLimit(6)
            }
            Button(action: playTarget) {
              Label(
                playLabel, systemImage: plan?.action == .resume ? "play.circle.fill" : "play.fill")
            }.buttonStyle(.borderedProminent)
              .disabled(loading || plan?.target?.isPlayable != true)
              .focused($focused, equals: .play)
            if let target = plan?.target, let unavailable = target.availabilityMessage {
              Text(unavailable).foregroundStyle(.secondary)
            } else if !loading, plan?.target == nil {
              Text("No playable media available.").foregroundStyle(.secondary)
            }
            if loading { ProgressView("Loading…") }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        if let error {
          TVErrorText(message: error)
          Button("Try Again") { Task { await load() } }
        }
        if item.kind == .series && !seasons.isEmpty {
          VStack(alignment: .leading, spacing: 28) {
            Picker(
              "Season",
              selection: Binding(
                get: { selectedSeason ?? seasons.first?.number ?? 1 },
                set: { selectedSeason = $0 }
              )
            ) {
              ForEach(seasons, id: \.number) { season in
                Text(season.number == 0 ? "Specials" : "Season \(season.number)").tag(season.number)
              }
            }.pickerStyle(.menu).focused($focused, equals: .season)
            ForEach(season?.episodes ?? [], id: \.item.id) { episode in
              Button {
                open(episode.item)
              } label: {
                HStack(spacing: 28) {
                  TVArtworkView(
                    artwork: episode.item.backdrop ?? episode.item.poster, width: 320,
                    symbol: "play.rectangle"
                  )
                  .frame(width: 230, height: 130).clipShape(RoundedRectangle(cornerRadius: 12))
                  VStack(alignment: .leading, spacing: 10) {
                    Text("\(episode.item.episodeLabel ?? "Episode") · \(episode.item.title)")
                      .font(.system(size: 30, weight: .semibold)).lineLimit(2)
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
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
              }.buttonStyle(.card).disabled(!episode.item.isPlayable)
                .focused($focused, equals: .episode(episode.item.id))
            }
          }.focusSection()
        }
      }.padding(64)
    }.background {
      ZStack {
        TVDesign.canvas
        TVArtworkView(artwork: item.backdrop, width: 1920).opacity(0.14)
      }.ignoresSafeArea()
    }
    .task(id: model.detailRefresh) { await load() }
    .onChange(of: model.session?.sessionId) { _, _ in playing = nil }
    .fullScreenCover(item: $playing, onDismiss: playerDismissed) { target in
      if let connection = model.connection, let session = model.session {
        TVPlayerView(
          connection: connection, session: session, mediaID: target.id,
          title: target.episodeLabel.map { "\(item.title) · \($0)" } ?? target.title,
          onClose: { playing = nil },
          onSessionFailure: { failure in
            guard model.session?.sessionId == session.sessionId else { return }
            model.handleSessionFailure(failure)
            playing = nil
          })
      }
    }
  }

  private func playerDismissed() {
    model.playerPresented = false
    Task {
      await load()
      focused = .play
    }
  }

  private var playLabel: String {
    let action: String
    switch plan?.action {
    case .resume: action = "Resume"
    case .playAgain: action = "Play Again"
    default: action = "Play"
    }
    return plan?.target?.episodeLabel.map { "\(action) \($0)" } ?? action
  }
  private func playTarget() { if let target = plan?.target { open(target) } }
  private func open(_ item: TVCatalogItem) {
    guard item.isPlayable, playing == nil else { return }
    model.playerPresented = true
    playing = item
  }

  private func load() async {
    guard let api = model.client else { return }
    let sessionID = model.session?.sessionId
    let request = UUID()
    requestID = request
    loading = true
    defer { if requestID == request, model.session?.sessionId == sessionID { loading = false } }
    do {
      async let loadedDetail = api.detail(id: id)
      async let loadedPlan = api.playbackPlan(mediaID: id)
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
          newPlan.target?.seasonNumber
          ?? newDetail.seasons.first(where: { $0.number > 0 })?.number
          ?? newDetail.seasons.first?.number
      }
      if firstLoad {
        focused = newPlan.target?.isPlayable == true ? .play : .season
        firstLoad = false
      }
    } catch {
      guard !Task.isCancelled, requestID == request, model.session?.sessionId == sessionID else {
        return
      }
      self.error = error.localizedDescription
      model.handleSessionFailure(error)
    }
  }
}
