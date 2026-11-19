import SwiftUI

struct IOSDetailView: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  let id: UUID
  let initial: IOSCatalogItem
  var selectedEpisodeID: UUID? = nil
  @StateObject private var actions = IOSLibraryActions()
  private var margin: CGFloat { IOSDesign.margin(for: sizeClass) }
  /// The title to start on another player (Play On).
  @State private var playOn: IOSCatalogItem?
  /// Edit… for administrators.
  @State private var editing = false
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
  @State private var loadedRevision: UUID?
  @State private var failedHeaderArtwork: IOSArtwork?
  private var item: IOSCatalogItem { model.overlay(detail?.item ?? initial) }
  private var headerArtwork: IOSArtwork? { item.backdrop ?? item.poster }
  private var showsHeaderArtwork: Bool {
    guard let headerArtwork else { return false }
    return headerArtwork != failedHeaderArtwork
  }
  private var seasons: [IOSSeason] { detail?.seasons ?? [] }
  private var joinableParties: [IOSWatchPartySummary] {
    let ids = Set([item.id] + seasons.flatMap { $0.episodes.map(\.item.id) })
    return model.watchParties.filter { ids.contains($0.mediaId) }
  }
  private var season: IOSSeason? { seasons.first { $0.number == selectedSeason } }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        header
        if let error {
          VStack(alignment: .leading, spacing: 12) {
            IOSErrorText(message: error)
            Button("Try Again") { Task { await load() } }.buttonStyle(IOSButtonStyle())
          }.padding(.horizontal, margin)
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
    .ignoresSafeArea(edges: showsHeaderArtwork ? .top : [])
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .task(id: model.detailRefresh) {
      let revision = model.detailRefresh
      let automatic = loadedRevision != nil && loadedRevision != revision
      loadedRevision = revision
      await load(background: automatic)
    }
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
        "\(item.availabilityMessage ?? "This title can't be played right now.") Connect the drive on your server computer, then try again."
      )
    }
    .onChange(of: headerArtwork) { _, _ in failedHeaderArtwork = nil }
    .onChange(of: model.session?.sessionId) { _, _ in playing = nil }
    .onChange(of: model.remoteStopRequests) { _, _ in playing = nil }
    .fullScreenCover(
      item: $playing, onDismiss: playerDismissed,
      content: { request in
        // Everything the player needs travels with the request, so the cover never
        // reads a stale view state (such as Start Over) when it is created.
        let target = request.item
        if let connection = model.connection, let session = model.session {
          IOSPlayerView(makeController: {
            let controller = IOSPlaybackController(
              connection: connection, session: session, mediaID: target.id,
              title: target.episodeLabel.map { "\(item.title) · \($0)" } ?? target.title,
              outbox: model.environment.outbox,
              api: model.makeClient(connection: connection, session: session),
              runtime: model.environment.makePlaybackRuntime(),
              queue: request.queue,
              seriesID: target.kind == .episode ? target.parentId : nil,
              preferencesStore: model.environment.preferences,
              adaptiveStreaming: model.supportsAdaptiveStreaming,
              supportsSuggestions: model.supportsSuggestions,
              onClose: { playing = nil },
              onSessionFailure: { failure in
                guard model.session?.sessionId == session.sessionId else { return }
                model.handleSessionFailure(failure)
                playing = nil
              }, startOver: request.startOver)
            controller.nowPlayingArtwork = target.poster ?? item.poster
            return controller
          })
        }
      }
    )
    .sheet(isPresented: $editing, onDismiss: { Task { await load(background: true) } }) {
      IOSTitleEditorView(mediaID: item.id, title: item.title)
    }
    .sheet(item: $playOn) { target in
      IOSPlayOnView(
        mediaID: target.id,
        title: target.episodeLabel.map { "\(item.title) · \($0)" } ?? target.title)
    }
    .modifier(IOSLibraryActionPresentation(actions: actions))
    .onDisappear {
      launchTask?.cancel()
      launchTask = nil
      navigationID = UUID()
    }
  }

  /// Real artwork reaches the edges and fades into the canvas. Missing or failed artwork uses
  /// the same compact, readable title treatment as Home instead of reserving empty image space.
  private var header: some View {
    VStack(spacing: 0) {
      if showsHeaderArtwork, let artwork = headerArtwork {
        IOSArtworkView(
          artwork: artwork, width: 1280, symbol: nil,
          onUnavailable: {
            if headerArtwork == artwork { failedHeaderArtwork = artwork }
          }
        )
        .frame(maxWidth: .infinity)
        .frame(
          height: IOSLayoutMetrics.detailBackdropHeight(
            isRegularWidth: sizeClass == .regular, isCompactHeight: verticalSizeClass == .compact)
        )
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
      }
      VStack(alignment: showsHeaderArtwork ? .center : .leading, spacing: 16) {
        HStack(alignment: .top, spacing: 16) {
          if !showsHeaderArtwork, !dynamicTypeSize.isAccessibilitySize {
            Image(systemName: item.kind == .movie ? "film" : "tv")
              .font(.title2.weight(.light)).foregroundStyle(.secondary)
              .frame(width: 52, height: 64)
              .background(
                IOSDesign.surface,
                in: RoundedRectangle(cornerRadius: IOSDesign.cardRadius, style: .continuous)
              )
              .accessibilityHidden(true)
          }
          VStack(alignment: showsHeaderArtwork ? .center : .leading, spacing: 6) {
            Text(item.title).font(.title.weight(.bold))
              .multilineTextAlignment(showsHeaderArtwork ? .center : .leading)
              .fixedSize(horizontal: false, vertical: true)
            if !facts.isEmpty {
              Text(facts).font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(showsHeaderArtwork ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .frame(maxWidth: .infinity, alignment: showsHeaderArtwork ? .center : .leading)
        }
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
        if let target = plan?.target, let unavailable = target.availabilityMessage {
          Label(unavailable, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
        } else if !loading, plan?.target == nil {
          Text("No playable media available.").font(.footnote).foregroundStyle(.secondary)
        }
        if dynamicTypeSize.isAccessibilitySize {
          VStack(spacing: 10) {
            playButton
            HStack(spacing: 12) {
              secondaryHeaderActions
            }
          }
        } else {
          HStack(spacing: 10) {
            playButton
            secondaryHeaderActions
            if sizeClass == .regular && !showsHeaderArtwork {
              Spacer(minLength: 0)
            }
          }
        }
        // Parties others started for this title or one of its episodes.
        ForEach(joinableParties) { party in
          Button {
            Task { await model.joinWatchTogether(party) }
          } label: {
            Label("Watch Together with \(party.hostName)", systemImage: "person.2.fill")
          }
          .buttonStyle(IOSButtonStyle(kind: .secondary, fullWidth: true))
          .accessibilityIdentifier("detail-watch-together")
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
      .frame(
        maxWidth: IOSLayoutMetrics.readableContentMaxWidth,
        alignment: showsHeaderArtwork ? .center : .leading
      )
      .padding(.horizontal, margin)
      .padding(.top, showsHeaderArtwork ? -44 : 16)
      .frame(maxWidth: .infinity, alignment: showsHeaderArtwork ? .center : .leading)
    }
  }

  private var playButton: some View {
    let stretch = sizeClass != .regular || dynamicTypeSize.isAccessibilitySize
    return Button {
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
      .frame(minWidth: stretch ? nil : 200)
    }
    .buttonStyle(IOSButtonStyle(kind: .primary, fullWidth: stretch))
    .disabled(launching)
    .accessibilityIdentifier("detail-play")
  }

  @ViewBuilder
  private var secondaryHeaderActions: some View {
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
      // Movies only: a series continues with its episodes and has no Start Over.
      if item.kind == .movie, plan?.action == .resume, plan?.target?.isPlayable == true {
        Button("Start Over", systemImage: "arrow.counterclockwise") {
          playTarget(startOver: true)
        }
        .accessibilityIdentifier("detail-start-over")
      }
      if IOSAdminPermissions(
        role: model.session?.user.role, accessMode: model.session?.user.accessMode
      ).administrator {
        Button("Edit…", systemImage: "pencil") { editing = true }
          .accessibilityIdentifier("detail-edit")
      }
      if model.supportsRemotePlayback, let target = plan?.target, target.isPlayable {
        Button("Play On…", systemImage: "airplayvideo") {
          playOn = target
        }
        .accessibilityIdentifier("detail-play-on")
      }
      IOSMediaContextActions(item: item, actions: actions, includeFavorite: false)
      if item.kind == .series, let selectedSeason {
        let name = selectedSeason == 0 ? "Specials" : "Season \(selectedSeason)"
        if model.supportsCollections {
          Button("Add \(name) to Collection…", systemImage: "rectangle.stack.badge.plus") {
            actions.requestAddToCollection(
              item: item, seasonNumber: selectedSeason, title: "\(item.title) · \(name)")
          }
        }
        Button("Mark \(name) as Watched", systemImage: "checkmark.circle") {
          seasonWatch(true)
        }
        Button("Mark \(name) as Unwatched", systemImage: "circle", role: .destructive) {
          seasonWatch(false)
        }
        if let episodes = season?.episodes.map({ model.overlay($0.item) }),
          episodes.contains(where: IOSOfflineRules.canDownload)
        {
          Button("Download \(name)", systemImage: "arrow.down.circle") {
            model.download(episodes: episodes)
          }
          .accessibilityIdentifier("detail-download-season")
        }
      }
    } label: {
      Image(systemName: "ellipsis").font(.body.weight(.semibold))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(width: 48, height: 48)
        .background(reduceTransparency ? IOSDesign.surface : IOSDesign.raised, in: Circle())
        .overlay {
          if contrast == .increased || reduceTransparency {
            Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1)
          }
        }
        .contentShape(Circle())
    }
    .tint(.white)
    .accessibilityIdentifier("detail-more").accessibilityLabel("More")
  }

  /// "42 min left" for a title that has been started.
  private func remaining(_ target: IOSCatalogItem) -> String? {
    guard let progress = target.progress, progress.durationMilliseconds > 0 else { return nil }
    let minutes = Int(
      (Double(max(0, progress.durationMilliseconds - progress.positionMilliseconds)) / 60_000)
        .rounded(.up))
    return IOSLayoutMetrics.remainingTimeText(minutes: minutes)
  }

  /// The season picker above the season's episodes as a row of wide cards, as on the Mac.
  private var episodes: some View {
    VStack(alignment: .leading, spacing: 12) {
      let headerLayout =
        dynamicTypeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        : AnyLayout(HStackLayout(alignment: .center))
      headerLayout {
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
            if seasons.count >= 2 {
              Image(systemName: "chevron.down").font(.footnote.weight(.bold))
                .accessibilityHidden(true)
            }
          }
          .foregroundStyle(.white)
          .frame(minHeight: 44)
          .contentShape(Rectangle())
        }
        .disabled(seasons.count < 2)
        .accessibilityIdentifier("season-picker")
        .contextMenu {
          if let selectedSeason, model.supportsCollections {
            let name = selectedSeason == 0 ? "Specials" : "Season \(selectedSeason)"
            Button("Add \(name) to Collection…", systemImage: "rectangle.stack.badge.plus") {
              actions.requestAddToCollection(
                item: item, seasonNumber: selectedSeason, title: "\(item.title) · \(name)")
            }
          }
        }
        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
        if let count = season?.episodes.count {
          Text(IOSLayoutMetrics.countPhrase(count, singular: "episode", plural: "episodes"))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, margin)
      IOSShelf {
        ForEach(season?.episodes ?? [], id: \.item.id) { value in
          let episode = model.overlay(value.item)
          Button {
            launchTask?.cancel()
            launchTask = Task { await openEpisode(episode) }
          } label: {
            IOSWideCard(
              item: episode, eyebrow: episode.episodeNumber.map { "EPISODE \($0)" } ?? "EPISODE",
              highlighted: episode.id == plan?.target?.id)
          }
          .buttonStyle(IOSContentButtonStyle())
          .contextMenu { IOSMediaContextActions(item: episode, actions: actions) }
          .disabled(launching)
          .accessibilityIdentifier("detail-episode-\(episode.id)")
        }
      }
    }
  }

  /// Trailers and Extras as a row of wide cards like the episodes, as on the Mac; each one plays
  /// its supplement.
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
              IOSWideCard(
                item: value, eyebrow: supplement.category.uppercased(), highlighted: false)
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
            IOSPosterLabel(item: value)
              .frame(width: IOSDesign.posterWidth(for: sizeClass, typeSize: dynamicTypeSize))
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
                IOSPersonDetailView(
                  name: person.name,
                  personKey: person.id.hasPrefix("unidentified:") ? nil : person.id)
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

  /// The facts of the title in two columns; collapses to one column at accessibility sizes.
  private func about(_ detail: IOSCatalogDetail) -> some View {
    let fields = IOSDetailPresentation.information(detail)
    let columns =
      dynamicTypeSize.isAccessibilitySize
      ? [GridItem(.flexible(), alignment: .topLeading)]
      : [
        GridItem(.flexible(), alignment: .topLeading),
        GridItem(.flexible(), alignment: .topLeading),
      ]
    return VStack(alignment: .leading, spacing: 12) {
      if !fields.isEmpty { IOSSectionHeader(title: "Information") }
      LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
        ForEach(fields, id: \.title) { field in
          VStack(alignment: .leading, spacing: 2) {
            Text(field.title).font(.caption).foregroundStyle(.secondary)
            Text(field.value).font(.subheadline)
          }
          .accessibilityElement(children: .combine)
        }
      }
      .padding(.horizontal, margin)
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
  private func load(background: Bool = false) async {
    guard let client = model.client else { return }
    let api = background ? client.background : client
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

/// A wide card with the title over its picture, as on the Mac: an episode with its number, title,
/// description and year, or a trailer or extra with its kind. At accessibility text sizes the text
/// moves below the 16:9 image so nothing clips inside the fixed artwork height.
private struct IOSWideCard: View {
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let item: IOSCatalogItem
  let eyebrow: String
  let highlighted: Bool
  private var width: CGFloat { IOSDesign.wideCardWidth(for: sizeClass) }

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) {
          IOSArtworkView(
            artwork: item.backdrop ?? item.poster, width: 840, symbol: "play.rectangle"
          )
          .frame(width: width, height: width * 9 / 16)
          .overlay(alignment: .topTrailing) { IOSItemBadges(item: item).padding(6) }
          .overlay(alignment: .bottom) {
            if let fraction = item.progressFraction {
              IOSProgressBar(fraction: fraction).padding(.horizontal, 10).padding(.bottom, 10)
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: IOSDesign.cardRadius, style: .continuous))
          .opacity(item.isPlayable ? 1 : 0.6)
          VStack(alignment: .leading, spacing: 4) {
            Text(item.availabilityMessage ?? eyebrow).font(.caption2.weight(.bold)).tracking(0.6)
              .foregroundStyle(
                item.availabilityMessage != nil
                  ? Color.orange : highlighted ? Color.accentColor : .secondary)
            Text(item.title).font(.subheadline.weight(.bold)).foregroundStyle(.white)
            if let overview = item.overview, !overview.isEmpty {
              Text(overview).font(.caption).foregroundStyle(.secondary)
                .lineLimit(3).multilineTextAlignment(.leading)
            }
            if let year = item.year {
              Text(String(year)).font(.caption2).foregroundStyle(.secondary)
            }
          }
          .frame(width: width, alignment: .leading)
        }
      } else {
        ZStack(alignment: .bottomLeading) {
          IOSArtworkView(
            artwork: item.backdrop ?? item.poster, width: 840, symbol: "play.rectangle"
          )
          .frame(width: width, height: width * 9 / 16)
          .opacity(item.isPlayable ? 1 : 0.55)
          LinearGradient(
            colors: [.clear, .black.opacity(0.4), .black.opacity(0.88)], startPoint: .top,
            endPoint: .bottom)
          VStack(alignment: .leading, spacing: 3) {
            Text(item.availabilityMessage ?? eyebrow).font(.caption2.weight(.bold)).tracking(0.6)
              .foregroundStyle(
                item.availabilityMessage != nil
                  ? Color.orange : highlighted ? Color.accentColor : .white.opacity(0.85)
              )
              .lineLimit(1)
            Text(item.title).font(.subheadline.weight(.bold)).foregroundStyle(.white).lineLimit(1)
            if let overview = item.overview, !overview.isEmpty {
              Text(overview).font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                .multilineTextAlignment(.leading)
            }
            if let year = item.year {
              Text(String(year)).font(.caption2).foregroundStyle(.white.opacity(0.75))
            }
            if let fraction = item.progressFraction {
              IOSProgressBar(fraction: fraction).padding(.top, 4)
            }
          }
          .padding(12)
        }
        .frame(width: width, height: width * 9 / 16)
        .overlay(alignment: .topTrailing) { IOSItemBadges(item: item).padding(6) }
        .clipShape(RoundedRectangle(cornerRadius: IOSDesign.cardRadius, style: .continuous))
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(eyebrow), \(item.title)")
    .accessibilityValue(item.accessibilitySummary)
  }
}

/// A round portrait with the name and role below.
private struct IOSPersonLabel: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let person: IOSPersonCard
  var body: some View {
    VStack(spacing: 6) {
      IOSArtworkView(artwork: person.profile, width: 320, symbol: "person.fill")
        .frame(width: 76, height: 76).clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 0.5))
      Text(person.name).font(.caption.weight(.semibold))
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
        .multilineTextAlignment(.center)
      if let subtitle = person.subtitle {
        Text(subtitle).font(.caption2).foregroundStyle(.secondary)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
          .multilineTextAlignment(.center)
      }
    }
    .frame(width: dynamicTypeSize.isAccessibilitySize ? 148 : 88)
    .accessibilityElement(children: .combine)
  }
}

/// The full description and every information field.
private struct IOSAboutSheet: View {
  @Environment(\.horizontalSizeClass) private var sizeClass
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
            .accessibilityElement(children: .combine)
          }
        }
        .padding(IOSDesign.margin(for: sizeClass)).frame(maxWidth: .infinity, alignment: .leading)
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
