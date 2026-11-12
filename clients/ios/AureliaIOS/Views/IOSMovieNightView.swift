import SwiftUI
import UIKit

/// Movie Night's colors: butter for yes, cinema-seat red for nope, and a paper ticket for the match.
private enum MovieNightPalette {
  static let yes = Color(red: 1, green: 0.79, blue: 0.24)
  static let nope = Color(red: 1, green: 0.30, blue: 0.35)
  static let paper = Color(red: 0.96, green: 0.92, blue: 0.83)
  static let stub = Color(red: 0.92, green: 0.86, blue: 0.72)
  static let ink = Color(red: 0.17, green: 0.11, blue: 0.07)
}

/// Movie Night in full screen: the lobby, the stack of posters to swipe, and the ticket for the
/// match. Closing leaves the night. `onPlay` plays the match the usual way.
struct IOSMovieNightView: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.dismiss) private var dismiss
  @StateObject private var session: IOSMovieNightSession
  let joining: IOSMovieNightSummary?
  let onPlay: (UUID) -> Void
  @State private var started = false

  init(api: any IOSMovieNightAPI, deviceName: String, joining: IOSMovieNightSummary?, onPlay: @escaping (UUID) -> Void) {
    _session = StateObject(wrappedValue: IOSMovieNightSession(api: api, deviceName: deviceName))
    self.joining = joining
    self.onPlay = onPlay
  }

  var body: some View {
    ZStack(alignment: .top) {
      IOSDesign.canvas.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          if let error = session.errorText {
            HStack {
              Text(error).font(.subheadline)
              Spacer()
              Button { session.errorText = nil } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .background(MovieNightPalette.nope.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
          }
          content
        }
        .padding(.horizontal, IOSDesign.margin)
        .padding(.top, 56)
        .padding(.bottom, 32)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
      }
      .scrollDisabled(session.screen == .swipe)
      HStack {
        Spacer()
        Button {
          Task {
            await session.leave()
            dismiss()
          }
        } label: {
          Image(systemName: "xmark").font(.headline)
        }
        .buttonStyle(IOSButtonStyle(kind: .icon))
        .accessibilityLabel("Leave Movie Night")
      }
      .padding(.horizontal, IOSDesign.margin)
      .padding(.top, 4)
    }
    .preferredColorScheme(.dark)
    .task {
      guard !started else { return }
      started = true
      if let joining { await session.join(joining) } else { await session.start() }
    }
    .onChange(of: session.screen) { _, screen in
      if screen == .match { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch session.screen {
    case .intro:
      if session.errorText == nil {
        ProgressView().frame(maxWidth: .infinity).padding(.top, 160)
      } else {
        Button("Try Again") {
          Task { if let joining { await session.join(joining) } else { await session.start() } }
        }
        .buttonStyle(IOSButtonStyle(kind: .primary))
      }
    case .lobby: lobby
    case .swipe: IOSMovieNightStack(session: session)
    case .waiting: waiting
    case .match, .noMatch: result
    }
  }

  private func heading(_ title: String, _ text: String?) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.largeTitle.weight(.heavy))
      if let text { Text(text).foregroundStyle(.secondary) }
    }
  }

  private func people(_ state: IOSMovieNightState, deckSize: Int = 0) -> some View {
    VStack(spacing: 0) {
      ForEach(state.members) { member in
        HStack(spacing: 12) {
          Text(String(member.name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
            .font(.headline)
            .frame(width: 36, height: 36)
            .background(IOSDesign.raised, in: Circle())
          VStack(alignment: .leading, spacing: 2) {
            Text(member.isYou ? "\(member.name) (you)" : member.name).font(.body.weight(.semibold))
            Text(
              [member.deviceName, member.isHost ? "started it" : nil, member.isVoting ? nil : "only watches"]
                .compactMap { $0 }.joined(separator: " · ")
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          if deckSize > 0 && member.isVoting {
            Text("\(member.swiped)/\(deckSize)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider() }
      }
    }
  }

  @ViewBuilder
  private var lobby: some View {
    if let state = session.state {
      let voters = state.voters.count
      heading(
        "Movie Night",
        voters == 0
          ? "Nobody is swiping yet. Open Aurelia on another phone and join this night."
          : "\(voters == 1 ? "1 person is" : "\(voters) people are") ready to swipe. Anyone else at home can join from Aurelia.")
      IOSMovieNightProgramCard(state: state, voters: voters) { program in
        Task { await session.settings(program) }
      } deal: {
        Task { await session.deal() }
      }
      people(state)
      Button(state.me?.isVoting == true ? "Just Watch on This Screen" : "Swipe Here Too") {
        Task { await session.setVoting(!(state.me?.isVoting ?? false)) }
      }
      .buttonStyle(IOSButtonStyle(kind: .secondary, fullWidth: true))
    }
  }

  @ViewBuilder
  private var waiting: some View {
    if let state = session.state {
      let slow = IOSMovieNightRules.slowpokes(state, deckSize: session.deck.count)
      heading(
        state.me?.isVoting == true ? "You're done." : "Swiping in progress",
        slow.isEmpty ? "Counting the votes…" : "Now we wait for the slowpokes.")
      people(state, deckSize: session.deck.count)
      if state.me?.isVoting != true {
        Button("Swipe Here Too") { Task { await session.setVoting(true) } }
          .buttonStyle(IOSButtonStyle(kind: .secondary, fullWidth: true))
      }
      Button("Deal New Cards") { Task { await session.deal() } }
        .buttonStyle(IOSButtonStyle(kind: .secondary, fullWidth: true))
    }
  }

  @ViewBuilder
  private var result: some View {
    if let state = session.state, let outcome = state.result {
      IOSMovieNightTicket(outcome: outcome, voters: state.voters.map(\.name))
      ForEach(outcome.awards, id: \.title) { award in
        VStack(alignment: .leading, spacing: 4) {
          Text(award.title).font(.subheadline.weight(.bold)).foregroundStyle(MovieNightPalette.yes)
          Text(award.line).font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(IOSDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
      if let card = outcome.card {
        Button {
          let id = card.mediaId
          Task {
            await session.leave()
            dismiss()
            onPlay(id)
          }
        } label: {
          Label("Play", systemImage: "play.fill")
        }
        .buttonStyle(IOSButtonStyle(kind: .primary, fullWidth: true))
      }
      if state.phase == "match" {
        Button("Keep Swiping") { Task { await session.keepSwiping() } }
          .buttonStyle(IOSButtonStyle(kind: .secondary, fullWidth: true))
      }
      Button("Deal New Cards") { Task { await session.deal() } }
        .buttonStyle(IOSButtonStyle(kind: .secondary, fullWidth: true))
    }
  }
}


/// The stack of posters: the top one follows the finger, tilts, and gets stamped.
private struct IOSMovieNightStack: View {
  @ObservedObject var session: IOSMovieNightSession
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var offset: CGSize = .zero
  @State private var flying = false

  var body: some View {
    let cards = Array(session.remaining.prefix(3))
    let total = session.deck.count
    VStack(spacing: 26) {
      GeometryReader { geometry in
        ZStack {
          ForEach(Array(cards.enumerated().reversed()), id: \.element.id) { index, card in
            IOSMovieNightCardView(card: card, like: index == 0 ? likeStrength : 0, nope: index == 0 ? nopeStrength : 0)
              .scaleEffect(index == 0 ? 1 : 1 - CGFloat(index) * 0.06)
              .offset(y: index == 0 ? 0 : CGFloat(index) * 24)
              .brightness(index == 0 ? 0 : -0.25 * Double(index))
              .offset(index == 0 ? offset : .zero)
              .rotationEffect(.degrees(index == 0 ? Double(offset.width / 16) : 0))
              .gesture(drag(width: geometry.size.width, card: card), isEnabled: index == 0)
              .allowsHitTesting(index == 0)
              .accessibilityHidden(index != 0)
          }
        }
      }
      .aspectRatio(2 / 3, contentMode: .fit)
      .frame(maxWidth: 380)
      .frame(maxWidth: .infinity)
      HStack(spacing: 28) {
        button(.nope, card: cards.first)
        VStack(spacing: 2) {
          Text("\(total - session.remaining.count + 1) of \(total)").font(.headline.monospacedDigit())
          let others = session.state?.voters.filter { !$0.isYou } ?? []
          if !others.isEmpty {
            Text(others.map { "\($0.name) \($0.swiped)" }.joined(separator: " · "))
              .font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        .frame(minWidth: 90)
        button(.like, card: cards.first)
      }
      Text("Swipe right if you'd watch it tonight, left if not.")
        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
  }

  private var likeStrength: Double { max(0, min(1, offset.width / IOSMovieNightRules.swipeDistance)) }
  private var nopeStrength: Double { max(0, min(1, -offset.width / IOSMovieNightRules.swipeDistance)) }

  private func drag(width: CGFloat, card: IOSMovieNightCard) -> some Gesture {
    DragGesture()
      .onChanged { value in
        guard !flying else { return }
        offset = CGSize(width: value.translation.width, height: value.translation.height * 0.25)
      }
      .onEnded { value in
        guard !flying else { return }
        if let choice = IOSMovieNightRules.choice(
          offset: value.translation.width, velocity: value.velocity.width, width: width)
        {
          fly(choice, card: card)
        } else {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { offset = .zero }
        }
      }
  }

  private func button(_ choice: IOSMovieNightChoice, card: IOSMovieNightCard?) -> some View {
    Button {
      if let card { fly(choice, card: card) }
    } label: {
      Image(systemName: choice == .like ? "heart.fill" : "xmark")
        .font(.system(size: 26, weight: .bold))
        .frame(width: 66, height: 66)
        .overlay(Circle().stroke(lineWidth: 2))
        .contentShape(Circle())
    }
    .foregroundStyle(choice == .like ? MovieNightPalette.yes : MovieNightPalette.nope)
    .accessibilityLabel(choice == .like ? "Yes" : "Nope")
    .disabled(card == nil || flying)
  }

  private func fly(_ choice: IOSMovieNightChoice, card: IOSMovieNightCard) {
    flying = true
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    let finish = {
      session.vote(card, like: choice == .like)
      offset = .zero
      flying = false
    }
    if reduceMotion { return finish() }
    withAnimation(.easeIn(duration: 0.22)) {
      offset = CGSize(width: choice == .like ? 640 : -640, height: 60)
    }
    Task {
      try? await Task.sleep(for: .milliseconds(230))
      var instant = Transaction()
      instant.disablesAnimations = true
      withTransaction(instant) { finish() }
    }
  }
}

private struct IOSMovieNightCardView: View {
  let card: IOSMovieNightCard
  let like: Double
  let nope: Double

  var body: some View {
    IOSArtworkView(artwork: card.poster ?? card.backdrop, width: 380)
      .overlay(alignment: .bottom) {
        VStack(alignment: .leading, spacing: 6) {
          Text(card.title).font(.title2.weight(.heavy)).lineLimit(2)
          if !card.meta.isEmpty { Text(card.meta).font(.caption).foregroundStyle(.secondary) }
          if let overview = card.overview {
            Text(overview).font(.footnote).foregroundStyle(.white.opacity(0.82)).lineLimit(3)
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
      .font(.system(size: 34, weight: .black))
      .padding(.horizontal, 12)
      .padding(.vertical, 2)
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(color, lineWidth: 4))
      .foregroundStyle(color)
      .rotationEffect(.degrees(angle))
      .padding(26)
      .accessibilityHidden(true)
  }
}

/// The match as a cinema ticket: poster and lines on paper, and a stub that admits the voters.
private struct IOSMovieNightTicket: View {
  let outcome: IOSMovieNightResult
  let voters: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        if let card = outcome.card {
          IOSArtworkView(artwork: card.poster ?? card.backdrop, width: 180)
            .frame(width: 128, height: 192)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        Text(outcome.headline).font(.system(size: 32, weight: .black))
        if let card = outcome.card {
          VStack(alignment: .leading, spacing: 2) {
            Text(card.title).font(.title3.weight(.bold))
            if !card.meta.isEmpty { Text(card.meta).font(.subheadline).opacity(0.62) }
          }
        }
        Text(outcome.line).font(.body)
      }
      .padding(20)
      if outcome.card != nil {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(outcome.isUnanimous ? "Admit \(voters.count)" : "\(outcome.likes) of \(outcome.voters) said yes")
            .font(.headline.weight(.black))
          Text(voters.joined(separator: ", ")).font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(MovieNightPalette.stub)
        .overlay(alignment: .top) { Perforation() }
      }
    }
    .foregroundStyle(MovieNightPalette.ink)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(MovieNightPalette.paper)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .shadow(color: .black.opacity(0.5), radius: 24, y: 16)
    .accessibilityElement(children: .combine)
  }

  /// The torn edge between ticket and stub.
  private struct Perforation: View {
    var body: some View {
      GeometryReader { geometry in
        HStack(spacing: 10) {
          ForEach(0..<Int(geometry.size.width / 24) + 1, id: \.self) { _ in
            Circle().fill(IOSDesign.canvas).frame(width: 14, height: 14)
          }
        }
        .offset(y: -7)
      }
      .frame(height: 7)
      .clipped()
      .accessibilityHidden(true)
    }
  }
}

/// "Tonight's program": the host picks the kind, genre, era and length right here and deals;
/// everyone else sees the choice and waits.
private struct IOSMovieNightProgramCard: View {
  let state: IOSMovieNightState
  let voters: Int
  let change: (IOSMovieNightProgram) -> Void
  let deal: () -> Void

  private var hosting: Bool { state.me?.isHost == true }
  private var program: IOSMovieNightProgram { IOSMovieNightProgram(state) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Tonight's program").font(.title3.weight(.bold))
        Text(hosting ? "You choose what gets dealt." : "\(state.host?.name ?? "The host") chooses what gets dealt.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      row("What", IOSMovieNightProgram.kinds, selected: program.kinds) { value in
        var next = program
        next.kinds = value
        change(next)
      }
      if !state.genreOptions.isEmpty {
        row("Genre", [("", "Any genre")] + state.genreOptions.map { ($0, $0) }, selected: program.genre ?? "") { value in
          var next = program
          next.genre = value.isEmpty ? nil : value
          change(next)
        }
      }
      if state.era != nil {
        row("When", IOSMovieNightProgram.eras, selected: program.era) { value in
          var next = program
          next.era = value
          change(next)
        }
      }
      if state.length != nil {
        row("Length", IOSMovieNightProgram.lengths, selected: program.length) { value in
          var next = program
          next.length = value
          change(next)
        }
      }
      Divider()
      Text(program.summary).font(.subheadline.weight(.semibold))
      if hosting {
        Button {
          deal()
        } label: {
          Label("Deal the Cards", systemImage: "play.fill")
        }
        .buttonStyle(IOSButtonStyle(kind: .primary, fullWidth: true))
        .disabled(voters == 0)
        .accessibilityIdentifier("movie-night-deal")
      } else {
        Text("Waiting for \(state.host?.name ?? "the host") to deal.").foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .background(IOSDesign.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Tonight's program")
  }

  private func row(
    _ label: String, _ options: [(String, String)], selected: String,
    choose: @escaping (String) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label.uppercased()).font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.secondary)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(options, id: \.0) { option in
            Button(option.1) { choose(option.0) }
              .font(.subheadline.weight(.semibold))
              .padding(.horizontal, 12).padding(.vertical, 7)
              .background(
                option.0 == selected ? Color.white : Color.white.opacity(0.1), in: Capsule())
              .foregroundStyle(option.0 == selected ? Color.black : Color.white)
              .disabled(!hosting)
              .accessibilityAddTraits(option.0 == selected ? .isSelected : [])
          }
        }
      }
    }
  }
}
