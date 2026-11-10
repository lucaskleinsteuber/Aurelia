import SwiftUI

/// Opens Movie Night: a new night, or the one to join.
struct MovieNightLaunch: Identifiable, Equatable {
  let id = UUID()
  let joining: MovieNightSummary?
}

/// Movie Night's colors: butter for yes, cinema-seat red for nope, and a paper ticket for the match.
enum MovieNightPalette {
  static let yes = Color(red: 1, green: 0.79, blue: 0.24)
  static let nope = Color(red: 1, green: 0.30, blue: 0.35)
  static let paper = Color(red: 0.96, green: 0.92, blue: 0.83)
  static let stub = Color(red: 0.92, green: 0.86, blue: 0.72)
  static let ink = Color(red: 0.17, green: 0.11, blue: 0.07)
}

/// A line on Home: start a Movie Night, or join the one someone else started.
struct MovieNightHomeStrip: View {
  @EnvironmentObject private var model: AppModel
  @State private var nights: [MovieNightSummary] = []

  var body: some View {
    let open = nights.first
    Button {
      model.movieNightLaunch = MovieNightLaunch(joining: open)
    } label: {
      HStack(spacing: 16) {
        ZStack {
          RoundedRectangle(cornerRadius: 5).fill(MovieNightPalette.nope)
            .frame(width: 22, height: 32).rotationEffect(.degrees(-12)).offset(x: -10)
          RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.14)).frame(width: 22, height: 32)
          RoundedRectangle(cornerRadius: 5).fill(MovieNightPalette.yes)
            .frame(width: 22, height: 32).rotationEffect(.degrees(12)).offset(x: 10)
        }
        .frame(width: 46, height: 40)
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(open.map { "\($0.hostName)'s Movie Night is on" } ?? "Can't decide what to watch?")
            .font(.headline)
          Text(open == nil ? "Start a Movie Night and let everyone swipe on their phone." : "Join and start swiping.")
            .font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right").foregroundStyle(.secondary)
      }
      .padding(14)
      .background(AureliaDesign.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .padding(.horizontal, AureliaDesign.pagePadding)
    .accessibilityIdentifier("home-movie-night")
    .task {
      while !Task.isCancelled {
        nights = await model.movieNights()
        try? await Task.sleep(for: .seconds(15))
      }
    }
  }
}

/// Movie Night in a sheet over the library: the lobby, the stack of posters to swipe with the
/// trackpad, the arrow keys or the buttons, and the ticket for the match. Closing leaves the night.
struct MovieNightSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @StateObject private var session: MovieNightSession
  let joining: MovieNightSummary?
  @State private var started = false

  init(api: any MovieNightAPI, joining: MovieNightSummary?) {
    _session = StateObject(
      wrappedValue: MovieNightSession(api: api, deviceName: Host.current().localizedName ?? "Mac"))
    self.joining = joining
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Movie Night").font(.headline)
        Spacer()
        Button("Leave") {
          Task {
            await session.leave()
            dismiss()
          }
        }
        .keyboardShortcut(.cancelAction)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 14)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          if let error = session.errorText {
            HStack {
              Text(error)
              Spacer()
              Button { session.errorText = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss")
            }
            .padding(12)
            .background(MovieNightPalette.nope.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
          }
          content
        }
        .padding(28)
      }
    }
    .frame(width: 620, height: 780)
    .background(AureliaDesign.canvas)
    .task {
      guard !started else { return }
      started = true
      if let joining { await session.join(joining) } else { await session.start() }
    }
    .onDisappear { Task { await session.leave() } }
  }

  @ViewBuilder
  private var content: some View {
    switch session.screen {
    case .intro:
      if session.errorText == nil {
        ProgressView().frame(maxWidth: .infinity).padding(.top, 200)
      } else {
        Button("Try Again") {
          Task { if let joining { await session.join(joining) } else { await session.start() } }
        }
        .buttonStyle(AureliaPrimaryActionButtonStyle())
      }
    case .lobby: lobby
    case .swipe: MovieNightStack(session: session)
    case .waiting: waiting
    case .match, .noMatch: result
    }
  }

  private func heading(_ title: String, _ text: String?) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.system(size: 34, weight: .heavy))
      if let text { Text(text).font(.title3).foregroundStyle(.secondary) }
    }
  }

  private func people(_ state: MovieNightState, deckSize: Int = 0) -> some View {
    VStack(spacing: 0) {
      ForEach(state.members) { member in
        HStack(spacing: 12) {
          Text(String(member.name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
            .font(.headline)
            .frame(width: 34, height: 34)
            .background(.white.opacity(0.12), in: Circle())
          VStack(alignment: .leading, spacing: 2) {
            Text(member.isYou ? "\(member.name) (you)" : member.name).fontWeight(.semibold)
            Text(
              [member.deviceName, member.isHost ? "started it" : nil, member.isVoting ? nil : "only watches"]
                .compactMap { $0 }.joined(separator: " · ")
            )
            .font(.callout).foregroundStyle(.secondary)
          }
          Spacer()
          if deckSize > 0 && member.isVoting {
            Text("\(member.swiped)/\(deckSize)").monospacedDigit().foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Divider() }
      }
    }
  }

  @ViewBuilder
  private var lobby: some View {
    if let state = session.state {
      let voters = state.voters.count
      heading(
        "Who's in?",
        voters == 0
          ? "Nobody is swiping yet. Open Aurelia on a phone and join this night."
          : "\(voters == 1 ? "1 person is" : "\(voters) people are") ready to swipe. Anyone else at home can join from Aurelia on their phone, in a browser or on the Apple TV.")
      people(state)
      if state.me?.isHost == true {
        Picker("Deal", selection: Binding(
          get: { state.kinds },
          set: { kinds in Task { await session.settings(kinds: kinds, genre: state.genre) } })
        ) {
          Text("Movies").tag("movies")
          Text("Movies and Shows").tag("all")
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
        if !state.genreOptions.isEmpty {
          Picker("Genre", selection: Binding(
            get: { state.genre ?? "" },
            set: { genre in Task { await session.settings(kinds: state.kinds, genre: genre.isEmpty ? nil : genre) } })
          ) {
            Text("Any Genre").tag("")
            ForEach(state.genreOptions, id: \.self) { Text($0).tag($0) }
          }
          .frame(maxWidth: 320)
        }
      }
      HStack(spacing: 12) {
        if state.me?.isHost == true {
          Button("Deal the Cards") { Task { await session.deal() } }
            .buttonStyle(AureliaPrimaryActionButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(voters == 0)
        } else {
          Text("Waiting for \(state.host?.name ?? "the host") to deal.").foregroundStyle(.secondary)
        }
        Button(state.me?.isVoting == true ? "Just Watch on This Mac" : "Swipe Here Too") {
          Task { await session.setVoting(!(state.me?.isVoting ?? false)) }
        }
      }
    }
  }

  @ViewBuilder
  private var waiting: some View {
    if let state = session.state {
      let slow = MovieNightRules.slowpokes(state, deckSize: session.deck.count)
      heading(
        state.me?.isVoting == true ? "You're done." : "Swiping in progress",
        slow.isEmpty ? "Counting the votes…" : "Now we wait for the slowpokes.")
      people(state, deckSize: session.deck.count)
      HStack(spacing: 12) {
        if state.me?.isVoting != true {
          Button("Swipe Here Too") { Task { await session.setVoting(true) } }
        }
        Button("Deal New Cards") { Task { await session.deal() } }
      }
    }
  }

  @ViewBuilder
  private var result: some View {
    if let state = session.state, let outcome = state.result {
      MovieNightTicket(outcome: outcome, voters: state.voters.map(\.name))
      ForEach(outcome.awards, id: \.title) { award in
        VStack(alignment: .leading, spacing: 4) {
          Text(award.title).fontWeight(.bold).foregroundStyle(MovieNightPalette.yes)
          Text(award.line)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AureliaDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
      HStack(spacing: 12) {
        if let card = outcome.card {
          Button {
            let id = card.mediaId
            Task {
              await session.leave()
              model.playMovieNightMatch(id)
            }
          } label: {
            Label("Play", systemImage: "play.fill")
          }
          .buttonStyle(AureliaPrimaryActionButtonStyle())
          .keyboardShortcut(.defaultAction)
        }
        if state.phase == "match" {
          Button("Keep Swiping") { Task { await session.keepSwiping() } }
        }
        Button("Deal New Cards") { Task { await session.deal() } }
      }
    }
  }
}

/// The stack of posters: the top one follows the trackpad, tilts, and gets stamped.
private struct MovieNightStack: View {
  @ObservedObject var session: MovieNightSession
  @Environment(\.aureliaReduceMotion) private var reduceMotion
  @State private var offset: CGSize = .zero
  @State private var flying = false
  @FocusState private var focused: Bool

  var body: some View {
    let cards = Array(session.remaining.prefix(3))
    let total = session.deck.count
    VStack(spacing: 24) {
      ZStack {
        ForEach(Array(cards.enumerated().reversed()), id: \.element.id) { index, card in
          MovieNightCardView(card: card, like: index == 0 ? strength(1) : 0, nope: index == 0 ? strength(-1) : 0)
            .frame(width: 340, height: 510)
            .scaleEffect(index == 0 ? 1 : 1 - CGFloat(index) * 0.06)
            .offset(y: index == 0 ? 0 : CGFloat(index) * 24)
            .brightness(index == 0 ? 0 : -0.25 * Double(index))
            .offset(index == 0 ? offset : .zero)
            .rotationEffect(.degrees(index == 0 ? Double(offset.width / 16) : 0))
            .gesture(drag(card), isEnabled: index == 0)
            .allowsHitTesting(index == 0)
            .accessibilityHidden(index != 0)
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: 560)
      HStack(spacing: 28) {
        button(.nope, card: cards.first)
        VStack(spacing: 2) {
          Text("\(total - session.remaining.count + 1) of \(total)").font(.headline.monospacedDigit())
          let others = session.state?.voters.filter { !$0.isYou } ?? []
          if !others.isEmpty {
            Text(others.map { "\($0.name) \($0.swiped)" }.joined(separator: " · "))
              .font(.callout).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        .frame(minWidth: 110)
        button(.like, card: cards.first)
      }
      .frame(maxWidth: .infinity)
      Text("Drag right if you'd watch it tonight, left if not. The arrow keys work too.")
        .font(.callout).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    .onAppear { focused = true }
    .onKeyPress(.rightArrow) {
      if let card = cards.first { fly(.like, card: card) }
      return .handled
    }
    .onKeyPress(.leftArrow) {
      if let card = cards.first { fly(.nope, card: card) }
      return .handled
    }
  }

  private func strength(_ direction: Double) -> Double {
    max(0, min(1, direction * offset.width / MovieNightRules.swipeDistance))
  }

  private func drag(_ card: MovieNightCard) -> some Gesture {
    DragGesture()
      .onChanged { value in
        guard !flying else { return }
        offset = CGSize(width: value.translation.width, height: value.translation.height * 0.25)
      }
      .onEnded { value in
        guard !flying else { return }
        if let choice = MovieNightRules.choice(
          offset: value.translation.width, velocity: value.velocity.width, width: 340)
        {
          fly(choice, card: card)
        } else {
          withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7)) { offset = .zero }
        }
      }
  }

  private func button(_ choice: MovieNightChoice, card: MovieNightCard?) -> some View {
    Button {
      if let card { fly(choice, card: card) }
    } label: {
      Image(systemName: choice == .like ? "heart.fill" : "xmark")
        .font(.system(size: 24, weight: .bold))
        .frame(width: 60, height: 60)
        .overlay(Circle().stroke(lineWidth: 2))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(choice == .like ? MovieNightPalette.yes : MovieNightPalette.nope)
    .accessibilityLabel(choice == .like ? "Yes" : "Nope")
    .disabled(card == nil || flying)
  }

  private func fly(_ choice: MovieNightChoice, card: MovieNightCard) {
    guard !flying else { return }
    flying = true
    let finish = {
      session.vote(card, like: choice == .like)
      offset = .zero
      flying = false
    }
    if reduceMotion { return finish() }
    withAnimation(.easeIn(duration: 0.22)) {
      offset = CGSize(width: choice == .like ? 700 : -700, height: 60)
    }
    Task {
      try? await Task.sleep(for: .milliseconds(230))
      var instant = Transaction()
      instant.disablesAnimations = true
      withTransaction(instant) { finish() }
    }
  }
}

private struct MovieNightCardView: View {
  let card: MovieNightCard
  let like: Double
  let nope: Double

  var body: some View {
    AuthenticatedArtwork(artwork: card.poster ?? card.backdrop, symbol: "film")
      .overlay(alignment: .bottom) {
        VStack(alignment: .leading, spacing: 6) {
          Text(card.title).font(.title2.weight(.heavy)).lineLimit(2)
          if !card.meta.isEmpty { Text(card.meta).font(.callout).foregroundStyle(.secondary) }
          if let overview = card.overview {
            Text(overview).font(.callout).foregroundStyle(.white.opacity(0.82)).lineLimit(3)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .padding(.top, 60)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .center))
      }
      .overlay(alignment: .topLeading) { stamp("Yes!", color: MovieNightPalette.yes, angle: -14).opacity(like) }
      .overlay(alignment: .topTrailing) { stamp("Nope", color: MovieNightPalette.nope, angle: 14).opacity(nope) }
      .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
      .shadow(color: .black.opacity(0.45), radius: 20, y: 14)
      .accessibilityElement(children: .combine)
  }

  private func stamp(_ text: String, color: Color, angle: Double) -> some View {
    Text(text)
      .font(.system(size: 32, weight: .black))
      .padding(.horizontal, 12)
      .padding(.vertical, 2)
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(color, lineWidth: 4))
      .foregroundStyle(color)
      .rotationEffect(.degrees(angle))
      .padding(24)
      .accessibilityHidden(true)
  }
}

/// The match as a cinema ticket: poster and lines on paper, and a stub that admits the voters.
private struct MovieNightTicket: View {
  let outcome: MovieNightResult
  let voters: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 20) {
        if let card = outcome.card {
          AuthenticatedArtwork(artwork: card.poster ?? card.backdrop, symbol: "film")
            .frame(width: 128, height: 192)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        VStack(alignment: .leading, spacing: 10) {
          Text(outcome.headline).font(.system(size: 32, weight: .black))
          if let card = outcome.card {
            Text(card.title).font(.title2.weight(.bold))
            if !card.meta.isEmpty { Text(card.meta).opacity(0.62) }
          }
          Text(outcome.line).font(.title3)
        }
      }
      .padding(22)
      if outcome.card != nil {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(outcome.isUnanimous ? "Admit \(voters.count)" : "\(outcome.likes) of \(outcome.voters) said yes")
            .font(.headline.weight(.black))
          Text(voters.joined(separator: ", "))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(MovieNightPalette.stub)
      }
    }
    .foregroundStyle(MovieNightPalette.ink)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(MovieNightPalette.paper)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .shadow(color: .black.opacity(0.5), radius: 24, y: 16)
    .accessibilityElement(children: .combine)
  }
}
