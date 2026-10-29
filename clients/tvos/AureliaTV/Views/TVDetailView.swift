import SwiftUI

struct TVDetailView: View {
  @EnvironmentObject private var model: TVAppModel
  let id: UUID
  let initial: TVCatalogItem
  var selectedEpisodeID: UUID? = nil
  @StateObject private var actions = TVLibraryActions()
  @State private var launching = false
  @State private var launchTask: Task<Void, Never>?
  @State private var navigationID = UUID()
  @State private var detail: TVCatalogDetail?
  @State private var plan: TVPlaybackPlan?
  @State private var selectedSeason: Int?
  @State private var loading = true
  @State private var error: String?
  @State private var playing: TVDetailPlayback?
  @State private var requestID = UUID()
  @State private var focusRequest: FocusRequest?
  @State private var launchOrigin: Focus = .play
  @State private var shelfAnchor: Focus?
  @State private var unavailable: TVCatalogItem?
  @State private var showingAbout = false
  @FocusState private var focused: Focus?

  private enum Focus: Hashable {
    case play
    case season(Int)
    case episode(UUID)
    case supplement(UUID)
    case person(String)
    case about
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
      .defaultFocus($focused, .play)
      .onChange(of: focused) { _, value in
        // Moving across the season bar switches the shelf at once, like the TV app.
        if case .season(let number) = value, number != selectedSeason { selectSeason(number) }
      }
      .sheet(isPresented: $showingAbout) {
        if let detail { TVAboutSheet(detail: detail) }
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
      .onChange(of: model.session?.sessionId) { _, _ in
        playing = nil
        focusRequest = nil
      }
      .fullScreenCover(
        item: $playing, onDismiss: playerDismissed,
        content: { request in
          // Everything the player needs travels with the request, so the cover never
          // reads a stale view state (such as Start Over) when it is created.
          let target = request.item
          if let connection = model.connection, let session = model.session {
            TVPlayerView(makeController: {
              TVPlaybackController(
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
          Button {
            playTarget()
          } label: {
            Label(playLabel, systemImage: "play.fill")
          }.buttonStyle(TVButtonStyle(kind: .primary))
            // Always focusable: loading never moves focus later, and an unavailable
            // target is explained when pressed instead of leaving a gap.
            .disabled(launching)
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
            if plan?.action == .resume, plan?.target?.isPlayable == true {
              Button("Start Over", systemImage: "arrow.counterclockwise") {
                playTarget(startOver: true)
              }
            }
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
      ScrollView(.horizontal) {
        HStack(alignment: .center, spacing: 16) {
          ForEach(seasons, id: \.number) { value in
            Button {
              selectSeason(value.number)
            } label: {
              Text(seasonName(value.number))
            }
            .buttonStyle(TVSeasonChipStyle(selected: value.number == selectedSeason))
            .focused($focused, equals: .season(value.number))
            // The one explicit route: up from the season bar always returns to Play.
            .onMoveCommand { if $0 == .up { focused = .play } }
            .accessibilityIdentifier("season-option-\(value.number)")
            .accessibilityAddTraits(value.number == selectedSeason ? .isSelected : [])
          }
          if let count = season?.episodes.count {
            Text(count == 1 ? "1 episode" : "\(count) episodes").font(
              .system(size: 22, weight: .semibold)
            )
            .foregroundStyle(.tertiary).padding(.leading, 12)
          }
        }.padding(.horizontal, TVDesign.pagePadding).padding(.vertical, 10)
      }.scrollIndicators(.hidden).scrollClipDisabled()
        .defaultFocus($focused, .season(selectedSeason ?? 1), priority: .userInitiated)
        .focusSection()
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
              .disabled(launching)
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

  /// Trailers and Extras as landscape shelves; each card plays its supplement.
  @ViewBuilder
  private func supplementRails(_ supplements: [TVSupplement], prefix: String) -> some View {
    ForEach(TVDetailPresentation.supplementGroups(supplements), id: \.title) { group in
      VStack(alignment: .leading, spacing: 24) {
        TVSectionHeader(title: prefix + group.title, count: group.items.count)
          .padding(.horizontal, TVDesign.pagePadding)
        ScrollView(.horizontal) {
          LazyHStack(alignment: .top, spacing: 44) {
            ForEach(group.items, id: \.item.id) { supplement in
              let value = model.overlay(supplement.item)
              Button {
                playSupplement(value)
              } label: {
                TVSupplementCard(item: value, category: supplement.category)
              }.buttonStyle(.borderless).disabled(launching)
                .focused($focused, equals: .supplement(value.id))
                .accessibilityIdentifier("supplement-\(value.id)")
            }
          }.padding(.horizontal, TVDesign.pagePadding).padding(.vertical, 16)
        }.scrollIndicators(.hidden).scrollClipDisabled()
          // Moving into a shelf from above or below starts at its first card.
          .defaultFocus(
            $focused, group.items.first.map { .supplement($0.item.id) }, priority: .userInitiated
          )
          .focusSection()
      }
    }
  }

  @ViewBuilder
  private func franchiseRail(_ franchise: TVCollection) -> some View {
    VStack(alignment: .leading, spacing: 24) {
      TVSectionHeader(title: "Part of the \(franchise.name)", count: franchise.items.count)
        .padding(.horizontal, TVDesign.pagePadding)
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: 44) {
          ForEach(franchise.items, id: \.id) { film in
            let value = model.overlay(film)
            NavigationLink {
              TVDetailView(id: value.detailID, initial: value)
            } label: {
              TVPosterLabel(item: value).frame(width: TVDesign.posterWidth)
            }
            .buttonStyle(.borderless)
          }
        }
        .padding(.horizontal, TVDesign.pagePadding)
        .padding(.vertical, 16)
      }
      .scrollIndicators(.hidden)
      .scrollClipDisabled()
      .focusSection()
    }
  }

  @ViewBuilder
  private func castAndCrew(_ credits: [TVCredit]) -> some View {
    let people = TVDetailPresentation.people(credits)
    if !people.isEmpty {
      VStack(alignment: .leading, spacing: 24) {
        TVSectionHeader(title: "Cast & Crew", count: people.count)
          .padding(.horizontal, TVDesign.pagePadding)
        ScrollView(.horizontal) {
          LazyHStack(alignment: .top, spacing: 40) {
            ForEach(people) { person in
              if model.supportsWatchlist {
                NavigationLink {
                  TVPersonDetailView(name: person.name)
                } label: {
                  TVPersonLabel(person: person)
                }.buttonStyle(TVPortraitButtonStyle())
                  .focused($focused, equals: .person(person.id))
                  .accessibilityIdentifier("person-\(person.id)")
              } else {
                Button {
                } label: {
                  TVPersonLabel(person: person)
                }.buttonStyle(TVPortraitButtonStyle())
                  .focused($focused, equals: .person(person.id))
                  .accessibilityIdentifier("person-\(person.id)")
              }
            }
          }.padding(.horizontal, TVDesign.pagePadding).padding(.vertical, 16)
        }.scrollIndicators(.hidden).scrollClipDisabled()
          .defaultFocus($focused, people.first.map { .person($0.id) }, priority: .userInitiated)
          .focusSection()
      }.accessibilityIdentifier("cast-and-crew")
    }
  }

  /// A focusable About card keeps the bottom of the page reachable with the remote;
  /// selecting it shows the full text and every information field.
  private func about(_ detail: TVCatalogDetail) -> some View {
    let fields = TVDetailPresentation.information(detail)
    return VStack(alignment: .leading, spacing: 24) {
      TVSectionHeader(title: "About")
      Button {
        showingAbout = true
      } label: {
        HStack(alignment: .top, spacing: 60) {
          VStack(alignment: .leading, spacing: 12) {
            Text(detail.metadata.title).font(.system(size: 28, weight: .bold))
            Text(detail.metadata.overview ?? detail.item.overview ?? "No description available.")
              .font(.system(size: 22)).lineLimit(4).multilineTextAlignment(.leading)
          }.frame(maxWidth: 860, alignment: .leading)
          VStack(alignment: .leading, spacing: 14) {
            ForEach(fields.prefix(4), id: \.title) { field in
              VStack(alignment: .leading, spacing: 2) {
                Text(field.title.uppercased()).font(.system(size: 16, weight: .bold)).tracking(1.2)
                  .opacity(0.6)
                Text(field.value).font(.system(size: 22, weight: .semibold)).lineLimit(1)
              }
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
      }.buttonStyle(TVButtonStyle(kind: .row)).focused($focused, equals: .about)
        .accessibilityIdentifier("detail-about")
    }.padding(.horizontal, TVDesign.pagePadding).focusSection()
  }

  private var shelfEntry: Focus? {
    let episodes = season?.episodes.map(\.item) ?? []
    let target = episodes.first { $0.id == plan?.target?.id } ?? episodes.first
    return target.map { .episode($0.id) }
  }

  private var eyebrow: String {
    [
      item.kindLabel, item.year.map(String.init),
      detail?.metadata.runtimeMinutes.map { "\($0) min" }, detail?.metadata.contentRating,
    ].compactMap { $0 }.joined(separator: " · ")
  }

  private func requestFocus(_ target: Focus) { focusRequest = FocusRequest(target: target) }
  private func seasonName(_ number: Int) -> String { number == 0 ? "Specials" : "Season \(number)" }
  private func selectSeason(_ number: Int) {
    selectedSeason = number
    let episodes = seasons.first { $0.number == number }?.episodes.map(\.item) ?? []
    let start = episodes.first { $0.id == plan?.target?.id } ?? episodes.first
    shelfAnchor = start.map { .episode($0.id) }
  }
  private func playerDismissed() {
    model.playerPresented = false
    Task {
      await load()
      if case .episode(let id) = launchOrigin,
        !seasons.flatMap(\.episodes).contains(where: { $0.item.id == id && $0.item.isPlayable })
      {
        requestFocus(.season(selectedSeason ?? 1))
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
  private func playSupplement(_ supplement: TVCatalogItem) {
    guard supplement.isPlayable else {
      unavailable = supplement
      return
    }
    open(supplement, queue: [], origin: .supplement(supplement.id))
  }
  private func playTarget(startOver: Bool = false) {
    if let target = plan?.target {
      guard target.isPlayable else {
        unavailable = target
        return
      }
      open(target, queue: plan?.queue ?? [], origin: .play, startOver: startOver)
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
        open(target, queue: selected.queue, origin: .play, startOver: startOver)
      } catch {
        guard !Task.isCancelled, model.session?.sessionId == sessionID else { return }
        self.error = error.localizedDescription
        model.handleSessionFailure(error)
      }
    }
  }
  private func openEpisode(_ episode: TVCatalogItem) async {
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
      open(target, queue: selected.queue, origin: .episode(episode.id))
    } catch {
      guard !Task.isCancelled, model.session?.sessionId == sessionID else { return }
      self.error = error.localizedDescription
      model.handleSessionFailure(error)
    }
  }
  private func open(
    _ item: TVCatalogItem, queue: [TVCatalogItem], origin: Focus, startOver: Bool = false
  ) {
    guard item.isPlayable, playing == nil else { return }
    launchOrigin = origin
    focusRequest = nil
    model.playerPresented = true
    playing = TVDetailPlayback(item: item, queue: queue, startOver: startOver)
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
      TVArtworkView(artwork: item.backdrop ?? item.poster, width: 1280, symbol: "play.rectangle")
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

/// Season bar chip: the current season stays highlighted, focus turns it white.
private struct TVSeasonChipStyle: ButtonStyle {
  let selected: Bool
  @Environment(\.isFocused) private var focused
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 24, weight: selected || focused ? .bold : .semibold))
      .padding(.horizontal, 26).frame(minHeight: 58)
      .foregroundStyle(focused ? Color.black : .white.opacity(selected ? 1 : 0.7))
      .background(
        Capsule().fill(focused ? Color.white : .white.opacity(selected ? 0.24 : 0.08))
      )
      .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 14, y: 8)
      .scaleEffect(configuration.isPressed ? 0.97 : focused ? 1.06 : 1)
      .animation(.easeOut(duration: 0.12), value: focused)
  }
}

/// Landscape card for trailers and extras with a play glyph over the artwork.
private struct TVSupplementCard: View {
  let item: TVCatalogItem
  let category: String
  private let width: CGFloat = 420
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ZStack {
        TVArtworkView(artwork: item.backdrop ?? item.poster, width: 1280, symbol: "film.stack")
        Image(systemName: "play.fill").font(.system(size: 26, weight: .bold))
          .frame(width: 64, height: 64).background(.ultraThinMaterial, in: Circle())
      }
      .frame(width: width, height: width * 9 / 16)
      .overlay(alignment: .topTrailing) { TVItemBadges(item: item).padding(10) }
      .overlay(alignment: .bottom) {
        if let fraction = item.progressFraction {
          TVProgressBar(fraction: fraction).padding(.horizontal, 14).padding(.bottom, 14)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: TVDesign.cardRadius, style: .continuous))
      .hoverEffect(.highlight)
      TVEyebrow(text: category, size: 16)
      Text(item.title).font(.system(size: 23, weight: .semibold)).lineLimit(2)
      if let message = item.availabilityMessage {
        Text(message).font(.system(size: 19, weight: .semibold)).foregroundStyle(.orange)
      }
    }.frame(width: width, alignment: .leading).opacity(item.isPlayable ? 1 : 0.55)
  }
}

/// Round portrait with name and role. The surrounding button makes the row
/// browsable and grows on focus instead of showing a rectangular platter.
private struct TVPersonLabel: View {
  let person: TVPersonCard
  var body: some View {
    VStack(spacing: 14) {
      TVArtworkView(artwork: person.profile, width: 320, symbol: "person.fill")
        .frame(width: 150, height: 150).clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 1))
      Text(person.name).font(.system(size: 22, weight: .semibold)).lineLimit(1)
      if let subtitle = person.subtitle {
        Text(subtitle).font(.system(size: 18)).foregroundStyle(.secondary).lineLimit(2)
          .multilineTextAlignment(.center)
      }
    }.frame(width: 190)
  }
}

private struct TVPortraitButtonStyle: ButtonStyle {
  @Environment(\.isFocused) private var focused
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(focused ? 1 : 0.8)
      .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 20, y: 12)
      .scaleEffect(focused ? 1.1 : 1)
      .animation(.easeOut(duration: 0.14), value: focused)
  }
}

/// Full description and all information fields, as on the Mac detail page.
private struct TVAboutSheet: View {
  let detail: TVCatalogDetail
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 34) {
        Text(detail.metadata.title).font(.system(size: 52, weight: .bold))
        if let original = detail.metadata.originalTitle, original != detail.metadata.title {
          Text(original).font(.system(size: 24)).foregroundStyle(.secondary)
        }
        Text(detail.metadata.overview ?? detail.item.overview ?? "No description available.")
          .font(.system(size: 26)).frame(maxWidth: 1200, alignment: .leading)
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
          alignment: .leading, spacing: 30
        ) {
          ForEach(TVDetailPresentation.information(detail), id: \.title) { field in
            VStack(alignment: .leading, spacing: 6) {
              Text(field.title.uppercased()).font(.system(size: 18, weight: .bold)).tracking(1.2)
                .foregroundStyle(.secondary)
              Text(field.value).font(.system(size: 24, weight: .semibold))
            }
          }
        }
        Button("Done") { dismiss() }.buttonStyle(TVButtonStyle(kind: .primary))
          .accessibilityIdentifier("about-done")
      }.padding(80).frame(maxWidth: .infinity, alignment: .leading)
    }.background(TVDesign.canvas.ignoresSafeArea())
  }
}

private struct TVDetailPlayback: Identifiable {
  let item: TVCatalogItem
  let queue: [TVCatalogItem]
  let startOver: Bool
  var id: UUID { item.id }
}
