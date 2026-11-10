import SwiftUI

/// Movie Night's colors: butter for yes, cinema-seat red for nope, and a paper ticket for the match.
private enum MovieNightPalette {
  static let yes = Color(red: 1, green: 0.79, blue: 0.24)
  static let nope = Color(red: 1, green: 0.30, blue: 0.35)
  static let paper = Color(red: 0.96, green: 0.92, blue: 0.83)
  static let stub = Color(red: 0.92, green: 0.86, blue: 0.72)
  static let ink = Color(red: 0.17, green: 0.11, blue: 0.07)
}

/// Movie Night on the big screen. The Apple TV starts as the lobby: it shows who is in, how far
/// everyone has swiped and, at the end, the match with Play already in focus. It can also swipe
/// with the remote. Leaving the screen leaves the night.
struct TVMovieNightView: View {
  @EnvironmentObject private var model: TVAppModel
  @Environment(\.dismiss) private var dismiss
  @StateObject private var session: TVMovieNightSession
  let joining: TVMovieNightSummary?
  let onPlay: (UUID) -> Void
  @State private var started = false
  @FocusState private var playFocused: Bool

  init(api: any TVMovieNightAPI, deviceName: String, joining: TVMovieNightSummary?, onPlay: @escaping (UUID) -> Void) {
    _session = StateObject(wrappedValue: TVMovieNightSession(api: api, deviceName: deviceName))
    self.joining = joining
    self.onPlay = onPlay
  }

  var body: some View {
    ZStack {
      TVDesign.canvas.ignoresSafeArea()
      if let card = session.state?.result?.card, session.screen == .match || session.screen == .noMatch {
        TVArtworkView(artwork: card.backdrop ?? card.poster, width: 1920, symbol: nil)
          .blur(radius: 30).opacity(0.35).ignoresSafeArea()
      }
      VStack(alignment: .leading, spacing: 36) {
        if let error = session.errorText {
          Text(error).font(.system(size: 26, weight: .semibold)).foregroundStyle(MovieNightPalette.nope)
        }
        content
      }
      .padding(.horizontal, TVDesign.pagePadding)
      .padding(.vertical, 60)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .task {
      guard !started else { return }
      started = true
      // The Apple TV is the screen everyone looks at; the phones swipe.
      if let joining { await session.join(joining, voting: false) } else { await session.start(voting: false) }
    }
    .onChange(of: session.screen) { _, screen in
      if screen == .match || screen == .noMatch { playFocused = true }
    }
    .onDisappear { Task { await session.leave() } }
  }

  @ViewBuilder
  private var content: some View {
    switch session.screen {
    case .intro:
      if session.errorText == nil {
        ProgressView().frame(maxWidth: .infinity).padding(.top, 300)
      } else {
        Button("Try Again") {
          Task { if let joining { await session.join(joining, voting: false) } else { await session.start(voting: false) } }
        }
        .buttonStyle(TVButtonStyle(kind: .primary))
      }
    case .lobby: lobby
    case .swipe: swipe
    case .waiting: waiting
    case .match, .noMatch: result
    }
  }

  private func title(_ text: String, _ detail: String?) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(text).font(.system(size: 76, weight: .heavy))
      if let detail { Text(detail).font(.system(size: 30)).foregroundStyle(.secondary).frame(maxWidth: 1100, alignment: .leading) }
    }
  }

  private func people(_ state: TVMovieNightState, deckSize: Int = 0) -> some View {
    HStack(alignment: .top, spacing: 40) {
      ForEach(state.members) { member in
        VStack(spacing: 12) {
          Text(String(member.name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
            .font(.system(size: 54, weight: .bold))
            .frame(width: 120, height: 120)
            .background(member.isVoting ? Color.white.opacity(0.14) : Color.white.opacity(0.06), in: Circle())
            .overlay {
              if deckSize > 0 && member.isVoting {
                Circle().trim(from: 0, to: CGFloat(member.swiped) / CGFloat(max(1, deckSize)))
                  .stroke(MovieNightPalette.yes, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                  .rotationEffect(.degrees(-90))
              }
            }
          Text(member.name).font(.system(size: 26, weight: .semibold)).lineLimit(1)
          Text(deckSize > 0 && member.isVoting ? "\(member.swiped) of \(deckSize)" : member.isVoting ? member.deviceName : "the screen")
            .font(.system(size: 20)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 180)
        .accessibilityElement(children: .combine)
      }
    }
  }

  @ViewBuilder
  private var lobby: some View {
    if let state = session.state {
      let voters = state.voters.count
      title(
        "Movie Night",
        voters == 0
          ? "Grab your phones: open Aurelia and join \(state.host?.name ?? "this")'s Movie Night. Everyone swipes, nobody sees who said no."
          : "\(voters == 1 ? "1 person is" : "\(voters) people are") in. Anyone else can still join from Aurelia on their phone.")
      people(state)
      if state.me?.isHost == true {
        HStack(spacing: 20) {
          chip("Movies", selected: state.kinds != "all") { Task { await session.settings(kinds: "movies", genre: state.genre) } }
          chip("Movies and Shows", selected: state.kinds == "all") { Task { await session.settings(kinds: "all", genre: state.genre) } }
        }
        .focusSection()
        if !state.genreOptions.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
              chip("Any Genre", selected: state.genre == nil) { Task { await session.settings(kinds: state.kinds, genre: nil) } }
              ForEach(state.genreOptions, id: \.self) { genre in
                chip(genre, selected: state.genre == genre) { Task { await session.settings(kinds: state.kinds, genre: genre) } }
              }
            }
            .padding(.vertical, 20)
          }
          .scrollClipDisabled()
          .focusSection()
        }
      }
      HStack(spacing: 24) {
        if state.me?.isHost == true {
          Button("Deal the Cards") { Task { await session.deal() } }
            .buttonStyle(TVButtonStyle(kind: .primary))
            .disabled(voters == 0)
        } else {
          Text("Waiting for \(state.host?.name ?? "the host") to deal.").font(.system(size: 26)).foregroundStyle(.secondary)
        }
        Button(state.me?.isVoting == true ? "Just Watch" : "Swipe with the Remote") {
          Task { await session.setVoting(!(state.me?.isVoting ?? false)) }
        }
        .buttonStyle(TVButtonStyle())
      }
      .focusSection()
    }
  }

  private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(label, systemImage: selected ? "checkmark" : "circle").labelStyle(.titleAndIcon)
    }
    .buttonStyle(TVButtonStyle())
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  /// Swiping with the remote: the poster, and Nope or Yes.
  @ViewBuilder
  private var swipe: some View {
    if let card = session.remaining.first {
      HStack(alignment: .top, spacing: 60) {
        TVArtworkView(artwork: card.poster ?? card.backdrop, width: 500)
          .frame(width: 420, height: 630)
          .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
          .shadow(color: .black.opacity(0.5), radius: 30, y: 20)
        VStack(alignment: .leading, spacing: 20) {
          Text("\(session.deck.count - session.remaining.count + 1) of \(session.deck.count)")
            .font(.system(size: 24, weight: .semibold)).foregroundStyle(.secondary)
          Text(card.title).font(.system(size: 56, weight: .heavy)).lineLimit(2)
          if !card.meta.isEmpty { Text(card.meta).font(.system(size: 26)).foregroundStyle(.secondary) }
          if let overview = card.overview { Text(overview).font(.system(size: 26)).lineLimit(5) }
          Spacer()
          HStack(spacing: 30) {
            Button { session.vote(card, like: false) } label: { Label("Nope", systemImage: "xmark") }
              .buttonStyle(TVButtonStyle())
            Button { session.vote(card, like: true) } label: { Label("Yes", systemImage: "heart.fill") }
              .buttonStyle(TVButtonStyle(kind: .primary))
          }
          .focusSection()
        }
      }
    }
  }

  @ViewBuilder
  private var waiting: some View {
    if let state = session.state {
      let slow = TVMovieNightRules.slowpokes(state, deckSize: session.deck.count)
      title(
        "Swiping in progress",
        slow.isEmpty ? "Counting the votes…" : "The match shows up here the moment everyone agrees.")
      people(state, deckSize: session.deck.count)
      HStack(spacing: 24) {
        if state.me?.isVoting != true {
          Button("Swipe with the Remote") { Task { await session.setVoting(true) } }.buttonStyle(TVButtonStyle())
        }
        Button("Deal New Cards") { Task { await session.deal() } }.buttonStyle(TVButtonStyle())
      }
      .focusSection()
    }
  }

  @ViewBuilder
  private var result: some View {
    if let state = session.state, let outcome = state.result {
      HStack(alignment: .top, spacing: 60) {
        ticket(outcome, voters: state.voters.map(\.name))
        VStack(alignment: .leading, spacing: 24) {
          ForEach(outcome.awards, id: \.title) { award in
            VStack(alignment: .leading, spacing: 6) {
              Text(award.title).font(.system(size: 24, weight: .bold)).foregroundStyle(MovieNightPalette.yes)
              Text(award.line).font(.system(size: 26))
            }
          }
          Spacer()
          VStack(alignment: .leading, spacing: 20) {
            if let card = outcome.card {
              Button {
                let id = card.mediaId
                dismiss()
                onPlay(id)
              } label: {
                Label("Play", systemImage: "play.fill")
              }
              .buttonStyle(TVButtonStyle(kind: .primary))
              .focused($playFocused)
            }
            HStack(spacing: 20) {
              if state.phase == "match" {
                Button("Keep Swiping") { Task { await session.keepSwiping() } }.buttonStyle(TVButtonStyle())
              }
              Button("Deal New Cards") { Task { await session.deal() } }.buttonStyle(TVButtonStyle())
            }
          }
          .focusSection()
        }
      }
    }
  }

  /// The match as a cinema ticket: poster and lines on paper, and a stub that admits the voters.
  private func ticket(_ outcome: TVMovieNightResult, voters: [String]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 30) {
        if let card = outcome.card {
          TVArtworkView(artwork: card.poster ?? card.backdrop, width: 320)
            .frame(width: 240, height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        VStack(alignment: .leading, spacing: 16) {
          Text(outcome.headline).font(.system(size: 60, weight: .black))
          if let card = outcome.card {
            Text(card.title).font(.system(size: 38, weight: .bold)).lineLimit(2)
            if !card.meta.isEmpty { Text(card.meta).font(.system(size: 24)).opacity(0.62) }
          }
          Text(outcome.line).font(.system(size: 28))
        }
      }
      .padding(36)
      if outcome.card != nil {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
          Text(outcome.isUnanimous ? "Admit \(voters.count)" : "\(outcome.likes) of \(outcome.voters) said yes")
            .font(.system(size: 30, weight: .black))
          Text(voters.joined(separator: ", ")).font(.system(size: 26))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 36)
        .padding(.vertical, 22)
        .background(MovieNightPalette.stub)
      }
    }
    .foregroundStyle(MovieNightPalette.ink)
    .frame(width: 1000, alignment: .leading)
    .background(MovieNightPalette.paper)
    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
    .accessibilityElement(children: .combine)
  }
}
