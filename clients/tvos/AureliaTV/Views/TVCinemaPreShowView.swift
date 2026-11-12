import UIKit
import SwiftUI

/// Cinema mode's pre-show over the player: an ad, trailers and the curtain before the film.
/// Copied from the Mac app; Skip and Start Film take the remote's focus, Back leaves the player.
struct TVCinemaPreShowView: View {
  @ObservedObject var show: TVCinemaPreShow
  let reduceMotion: Bool
  @FocusState private var focused: Choice?

  private enum Choice: Hashable { case skip, start }

  var body: some View {
    ZStack {
      // Once the curtain opens, the film playing behind it shows through.
      if !isFeature || show.curtainOpensAt == nil { Color.black }
      switch show.act {
      case .ad(let ad):
        TimelineView(.animation) { context in
          TVCinemaAdScene(
            ad: ad, time: context.date.timeIntervalSince(show.actStarted), motion: !reduceMotion)
        }
        .id(ad.rawValue)
        .transition(.opacity)
      case .trailer(let trailer):
        TVCinemaTrailerScene(show: show, trailer: trailer)
          .id(trailer.trailer.id)
          .transition(.opacity)
      case .feature(let title):
        TimelineView(.animation) { context in
          TVCinemaCurtain(
            title: title, time: context.date.timeIntervalSince(show.actStarted),
            opensAt: show.curtainOpensAt, motion: !reduceMotion)
        }
        .transition(.opacity)
      case nil:
        EmptyView()
      }
      chrome
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: show.act)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("cinema-pre-show")
  }

  private var isFeature: Bool {
    if case .feature = show.act { true } else { false }
  }

  private var label: String? {
    switch show.act {
    case .ad: "Advertisement"
    case .trailer: "Trailer"
    default: nil
    }
  }

  private var chrome: some View {
    VStack {
      HStack {
        if let label {
          Text(label.uppercased())
            .font(.system(size: 20, weight: .semibold)).tracking(1.4)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.35), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
        }
        Spacer()
      }
      Spacer()
      HStack(spacing: 18) {
        Spacer()
        if !isFeature {
          Button {
            show.skip()
          } label: {
            Label("Skip", systemImage: "forward.end.fill")
          }
          .buttonStyle(TVButtonStyle()).focusEffectDisabled().focused($focused, equals: .skip)
          .accessibilityHint("Moves on to the next part")
          .accessibilityIdentifier("cinema-skip")
          Button {
            show.startFilm()
          } label: {
            Label("Start Film", systemImage: "play.fill")
          }
          .buttonStyle(TVButtonStyle()).focusEffectDisabled().focused($focused, equals: .start)
          .accessibilityHint("Leaves out the rest and starts the film")
          .accessibilityIdentifier("cinema-start-film")
        }
      }
      .focusSection()
    }
    .padding(.horizontal, 80).padding(.vertical, 60)
    .opacity(show.act == nil ? 0 : 1)
    .onAppear { focused = .skip }
  }
}

// MARK: Timing

/// 0 before `start`, 1 from `start + length` on, smooth in between.
private func ease(_ time: Double, _ start: Double, _ length: Double = 0.5) -> Double {
  let x = min(max((time - start) / length, 0), 1)
  return x * x * (3 - 2 * x)
}

/// Shown from `start` until `end`, fading in and out.
private func shown(_ time: Double, _ start: Double, _ end: Double, fade: Double = 0.45) -> Double {
  ease(time, start, fade) * (1 - ease(time, end, fade))
}

/// 0 at `start`, then landing on 1 with a few bounces.
private func bounce(_ time: Double, _ start: Double, _ length: Double = 0.75) -> Double {
  let x = min(max((time - start) / length, 0), 1)
  let n = 7.5625
  let d = 2.75
  if x < 1 / d { return n * x * x }
  if x < 2 / d {
    let y = x - 1.5 / d
    return n * y * y + 0.75
  }
  if x < 2.5 / d {
    let y = x - 2.25 / d
    return n * y * y + 0.9375
  }
  let y = x - 2.625 / d
  return n * y * y + 0.984375
}

/// Grows a little past 1 and settles, for badges that pop in.
private func pop(_ time: Double, _ start: Double, _ length: Double = 0.45) -> Double {
  let x = min(max((time - start) / length, 0), 1)
  let s = 2.2
  let y = x - 1
  return 1 + (s + 1) * y * y * y + s * y * y
}

// MARK: Ads

private struct TVCinemaAdScene: View {
  let ad: TVCinemaAd
  let time: Double
  let motion: Bool

  var body: some View {
    GeometryReader { geometry in
      let unit = min(geometry.size.width / 1.6, geometry.size.height) / 100
      Group {
        switch ad {
        case .iceCream: IceCreamAd(time: time, motion: motion, unit: unit)
        case .popcorn: PopcornAd(time: time, motion: motion, unit: unit)
        case .phones: PhonesAd(time: time, motion: motion, unit: unit)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      // Every ad ends on black, like the cut to the next reel.
      .overlay(Color.black.opacity(ease(time, TVCinemaAd.duration - 0.6, 0.6)))
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("An ad")
  }
}

private struct IceCreamAd: View {
  let time: Double
  /// Where the ad's script is: the words come at a pace you can read, the motion stays lively.
  private var t: Double { time / TVCinemaAd.pace }
  let motion: Bool
  let unit: CGFloat

  private let berry = Color(red: 0.55, green: 0.08, blue: 0.30)
  private let scoops: [(Color, Double)] = [
    (Color(red: 1, green: 0.45, blue: 0.58), 2.0),
    (Color(red: 1, green: 0.96, blue: 0.84), 3.0),
    (Color(red: 0.47, green: 0.29, blue: 0.17), 4.0),
  ]

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(red: 1, green: 0.68, blue: 0.77), Color(red: 1, green: 0.86, blue: 0.64)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
      TVCinemaSunburst(rays: 18)
        .fill(.white.opacity(0.17))
        .rotationEffect(.degrees(motion ? time * 5 : 0))
        .scaleEffect(2.4)
      HStack(alignment: .center, spacing: 10 * unit) {
        cone
        words.frame(width: 72 * unit, alignment: .leading)
      }
      VStack {
        Spacer()
        Text("*The foyer is your kitchen. Aurelia does not sell ice cream and never has.")
          .font(.system(size: 2.1 * unit, weight: .medium))
          .foregroundStyle(berry.opacity(0.7))
          .opacity(shown(t, 11.8, 20))
          .padding(.bottom, 5 * unit)
      }
    }
  }

  private var cone: some View {
    ZStack(alignment: .bottom) {
      ForEach(0..<5, id: \.self) { index in
        let angle = Double(index) * 72 + time * 40
        Image(systemName: "sparkle")
          .font(.system(size: 4 * unit))
          .foregroundStyle(.white)
          .scaleEffect(motion ? 0.6 + 0.4 * sin(time * 4 + Double(index)) : 0.8)
          .offset(
            x: cos(angle * .pi / 180) * 22 * unit,
            y: -60 * unit + sin(angle * .pi / 180) * 16 * unit)
          .opacity(shown(t, 5.2, 20))
      }
      TVCinemaCone()
        .fill(
          LinearGradient(
            colors: [Color(red: 0.88, green: 0.64, blue: 0.36), Color(red: 0.72, green: 0.47, blue: 0.24)],
            startPoint: .leading, endPoint: .trailing)
        )
        .overlay(TVCinemaWaffle(spacing: 4.5 * unit).stroke(.black.opacity(0.14), lineWidth: 0.5 * unit))
        .clipShape(TVCinemaCone())
        .frame(width: 25 * unit, height: 36 * unit)
        .offset(y: motion ? (1 - ease(t, 0.3, 0.9)) * 70 * unit : 0)
        .opacity(ease(t, 0.3, 0.4))
      ForEach(scoops.indices, id: \.self) { index in
        let (color, at) = scoops[index]
        Circle()
          .fill(color)
          .overlay(
            Circle().fill(.white.opacity(0.45)).frame(width: 7 * unit, height: 5 * unit)
              .offset(x: -6 * unit, y: -6 * unit)
          )
          .frame(width: 27 * unit, height: 27 * unit)
          .offset(
            y: -(30 * unit + CGFloat(index) * 16 * unit)
              - (motion ? (1 - bounce(t, at)) * 90 * unit : 0))
          .opacity(motion ? (t >= at ? 1 : 0) : ease(t, at, 0.3))
      }
      Circle()
        .fill(Color(red: 0.86, green: 0.05, blue: 0.14))
        .overlay(Circle().fill(.white.opacity(0.5)).frame(width: 2 * unit).offset(x: -1.5 * unit, y: -1.5 * unit))
        .frame(width: 8 * unit, height: 8 * unit)
        .offset(y: -82 * unit - (motion ? (1 - bounce(t, 5.0, 0.6)) * 60 * unit : 0))
        .opacity(motion ? (t >= 5 ? 1 : 0) : ease(t, 5, 0.3))
    }
    .frame(width: 34 * unit, height: 92 * unit, alignment: .bottom)
  }

  private var words: some View {
    ZStack(alignment: .leading) {
      VStack(alignment: .leading, spacing: 2 * unit) {
        Text("Feeling warm?")
          .font(.system(size: 8 * unit, weight: .bold, design: .rounded))
        Text("Ninety minutes is a long t.")
          .font(.system(size: 4.2 * unit, weight: .medium, design: .rounded))
          .opacity(ease(t, 2.2))
      }
      .foregroundStyle(berry)
      .opacity(shown(t, 0.8, 4.6))

      VStack(alignment: .leading, spacing: 2.5 * unit) {
        Text("Aurelia Ice")
          .font(.system(size: 14 * unit, weight: .black, design: .rounded))
          .foregroundStyle(.white)
          .shadow(color: berry.opacity(0.55), radius: 0, x: 0.8 * unit, y: 0.8 * unit)
          .scaleEffect(motion ? pop(t, 5.0) : 1, anchor: .leading)
        Text("Three scoops. Zero plot holes.")
          .font(.system(size: 4.6 * unit, weight: .semibold, design: .rounded))
          .opacity(ease(t, 6.3))
        Text("Now in the foyer.")
          .font(.system(size: 4.6 * unit, weight: .semibold, design: .rounded))
          .opacity(ease(t, 8.0))
      }
      .foregroundStyle(berry)
      .opacity(ease(t, 5.0, 0.3))
      .overlay(alignment: .topTrailing) {
        ZStack {
          TVCinemaSunburst(rays: 14, inner: 0.78).fill(Color(red: 1, green: 0.86, blue: 0.2))
          VStack(spacing: 0) {
            Text("ONLY").font(.system(size: 2.6 * unit, weight: .heavy, design: .rounded))
            Text("4.50!").font(.system(size: 5 * unit, weight: .black, design: .rounded))
          }
          .foregroundStyle(berry)
        }
        .frame(width: 20 * unit, height: 20 * unit)
        .rotationEffect(.degrees(-14))
        .scaleEffect(motion ? max(0, pop(t, 9.4)) : ease(t, 9.4, 0.3))
        .opacity(t >= 9.4 ? 1 : 0)
        .offset(x: 2 * unit, y: -16 * unit)
      }
    }
  }
}

private struct PopcornAd: View {
  let time: Double
  /// Where the ad's script is: the words come at a pace you can read, the motion stays lively.
  private var t: Double { time / TVCinemaAd.pace }
  let motion: Bool
  let unit: CGFloat

  private let gold = Color(red: 1, green: 0.82, blue: 0.32)
  private let kernel = Color(red: 1, green: 0.95, blue: 0.80)

  var body: some View {
    ZStack {
      RadialGradient(
        colors: [Color(red: 0.62, green: 0.05, blue: 0.10), Color(red: 0.22, green: 0, blue: 0.04)],
        center: .center, startRadius: 0, endRadius: 120 * unit)
      TVCinemaMarquee(time: motion ? time : 0, bulb: 1.6 * unit, color: gold)
      HStack(alignment: .center, spacing: 12 * unit) {
        bucket
        words.frame(width: 70 * unit, alignment: .leading)
      }
      VStack {
        Spacer()
        Text("*Rustling the bag in the dark is included at no extra cost.")
          .font(.system(size: 2.1 * unit, weight: .medium))
          .foregroundStyle(.white.opacity(0.6))
          .opacity(shown(t, 12, 20))
          .padding(.bottom, 6 * unit)
      }
    }
  }

  private var bucket: some View {
    let width = 36 * unit
    let height = 42 * unit
    let landed =
      motion
      ? TVCinemaPopcorn.kernels.filter { $0.launch * TVCinemaAd.pace + 0.7 < time }.count : 40
    return ZStack(alignment: .bottom) {
      // The heap grows as kernels land.
      ForEach(0..<min(landed, 34), id: \.self) { index in
        let row = index < 13 ? 0 : index < 23 ? 1 : index < 30 ? 2 : 3
        let inRow = [13, 10, 7, 4][row]
        let first = [0, 13, 23, 30][row]
        let x = (Double(index - first) - Double(inRow - 1) / 2) * 3 * Double(unit)
        TVCinemaKernel()
          .fill(kernel)
          .frame(width: 5 * unit, height: 4.4 * unit)
          .rotationEffect(.degrees(Double(index) * 47))
          .offset(x: x, y: -height + 1 * unit - CGFloat(row) * 2.8 * unit)
      }
      ZStack {
        HStack(spacing: 0) {
          ForEach(0..<7, id: \.self) { index in
            Rectangle().fill(index.isMultiple(of: 2) ? Color(red: 0.86, green: 0.07, blue: 0.13) : .white)
          }
        }
        Text("POPCORN")
          .font(.system(size: 4.4 * unit, weight: .black, design: .rounded))
          .foregroundStyle(Color(red: 0.86, green: 0.07, blue: 0.13))
          .padding(.horizontal, 2 * unit).padding(.vertical, 0.8 * unit)
          .background(.white, in: RoundedRectangle(cornerRadius: 1.2 * unit))
          .rotationEffect(.degrees(-6))
      }
      .frame(width: width, height: height)
      .clipShape(TVCinemaBucket())
      Canvas { context, size in
        guard motion else { return }
        for (index, flying) in TVCinemaPopcorn.kernels.enumerated() {
          let age = time - flying.launch * TVCinemaAd.pace
          guard age >= 0, age < 2.2 else { continue }
          let start = CGPoint(
            x: size.width / 2 + CGFloat((Double(index % 9) - 4) * 3) * unit,
            y: size.height - height)
          let rise = flying.upward * age - 1.1 * age * age
          let point = CGPoint(
            x: start.x + CGFloat(flying.sideways * age * 100) * unit,
            y: start.y - CGFloat(rise * 100) * unit)
          var piece = context
          piece.translateBy(x: point.x, y: point.y)
          piece.rotate(by: .radians(flying.spin * age))
          let rect = CGRect(x: -2.5 * unit, y: -2.2 * unit, width: 5 * unit, height: 4.4 * unit)
          piece.fill(TVCinemaKernel().path(in: rect), with: .color(kernel))
        }
      }
      .frame(width: 120 * unit, height: 100 * unit)
      .allowsHitTesting(false)
    }
    .frame(width: width, height: 70 * unit, alignment: .bottom)
    .offset(y: 8 * unit)
  }

  private var words: some View {
    VStack(alignment: .leading, spacing: 2.4 * unit) {
      Text("Aurelia Popcorn")
        .font(.system(size: 11 * unit, weight: .black, design: .rounded))
        .foregroundStyle(gold)
        .scaleEffect(motion ? pop(t, 0.6) : 1, anchor: .leading)
        .opacity(ease(t, 0.6, 0.3))
      Text("Louder than the film.")
        .font(.system(size: 5.6 * unit, weight: .bold, design: .rounded))
        .opacity(ease(t, 3.4))
      Text("Now with extra crunch for the quiet scenes.")
        .font(.system(size: 3.8 * unit, weight: .medium, design: .rounded))
        .opacity(ease(t, 6.0))
      Text("Crunch responsibly.")
        .font(.system(size: 4.2 * unit, weight: .heavy, design: .rounded))
        .foregroundStyle(Color(red: 0.4, green: 0, blue: 0.05))
        .padding(.horizontal, 3 * unit).padding(.vertical, 1.2 * unit)
        .background(gold, in: Capsule())
        .scaleEffect(motion ? max(0, pop(t, 10.6)) : 1, anchor: .leading)
        .opacity(t >= 10.6 ? 1 : 0)
        .padding(.top, 2 * unit)
    }
    .foregroundStyle(.white)
  }
}

private struct PhonesAd: View {
  let time: Double
  /// Where the ad's script is: the words come at a pace you can read, the motion stays lively.
  private var t: Double { time / TVCinemaAd.pace }
  let motion: Bool
  let unit: CGFloat

  private var off: Double { ease(t, TVCinemaPhones.silence, 0.25) }

  var body: some View {
    ZStack {
      Color(red: 0.03, green: 0.03, blue: 0.05)
      RadialGradient(
        colors: [Color(red: 0.25, green: 0.4, blue: 1).opacity(0.35 * (1 - off)), .clear],
        center: UnitPoint(x: 0.36, y: 0.5), startRadius: 0, endRadius: 60 * unit)
      seats
      Text("A MESSAGE FROM YOUR CINEMA")
        .font(.system(size: 2.6 * unit, weight: .semibold)).tracking(0.7 * unit)
        .foregroundStyle(.white.opacity(0.55))
        .opacity(shown(t, 0.3, 7.7))
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 10 * unit)
      HStack(alignment: .center, spacing: 12 * unit) {
        phone
        ZStack(alignment: .leading) {
          notifications.opacity(1 - off)
          thanks
        }
        .frame(width: 66 * unit, alignment: .leading)
      }
      .offset(y: -6 * unit)
    }
  }

  private var buzzing: Bool {
    t < TVCinemaPhones.silence
      && TVCinemaPhones.notifications.contains { t >= $0.time && t < $0.time + 0.8 }
  }

  private var phone: some View {
    RoundedRectangle(cornerRadius: 4.5 * unit)
      .fill(
        LinearGradient(
          colors: [Color(red: 0.3, green: 0.45, blue: 1), Color(red: 0.55, green: 0.25, blue: 0.9)],
          startPoint: .top, endPoint: .bottom)
      )
      .overlay(RoundedRectangle(cornerRadius: 4.5 * unit).fill(.black.opacity(off)))
      .overlay(
        RoundedRectangle(cornerRadius: 4.5 * unit)
          .strokeBorder(Color(white: 0.35), lineWidth: 1.2 * unit)
      )
      .overlay(alignment: .top) {
        Capsule().fill(.black).frame(width: 8 * unit, height: 2 * unit).padding(.top, 1.8 * unit)
      }
      .frame(width: 24 * unit, height: 48 * unit)
      .offset(x: motion && buzzing ? sin(time * 95) * 0.9 * unit : 0)
      .rotationEffect(.degrees(motion && buzzing ? sin(time * 70) * 1.5 : 0))
  }

  private var notifications: some View {
    VStack(alignment: .leading, spacing: 1.6 * unit) {
      ForEach(TVCinemaPhones.notifications.indices, id: \.self) { index in
        let message = TVCinemaPhones.notifications[index]
        let appear = ease(t, message.time, 0.3)
        VStack(alignment: .leading, spacing: 0.4 * unit) {
          Text(message.sender).font(.system(size: 2.6 * unit, weight: .bold))
          Text(message.text).font(.system(size: 2.6 * unit)).foregroundStyle(.white.opacity(0.8))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 2.4 * unit).padding(.vertical, 1.6 * unit)
        .frame(width: 52 * unit, alignment: .leading)
        .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 2.4 * unit))
        .opacity(appear)
        .offset(x: motion ? (1 - appear) * 10 * unit : 0)
      }
    }
  }

  private var thanks: some View {
    VStack(alignment: .leading, spacing: 2.4 * unit) {
      Text("Thank you.")
        .font(.system(size: 11 * unit, weight: .semibold, design: .serif))
        .opacity(ease(t, 8.5, 0.7))
      Text("Phones off. Yes, yours too.")
        .font(.system(size: 4.6 * unit, weight: .medium))
        .opacity(ease(t, 9.9))
      Text("The group chat will survive. Probably.")
        .font(.system(size: 3 * unit))
        .foregroundStyle(.white.opacity(0.55))
        .opacity(ease(t, 11.6))
    }
    .foregroundStyle(.white)
  }

  private var seats: some View {
    VStack {
      Spacer()
      HStack(spacing: 2 * unit) {
        ForEach(0..<11, id: \.self) { _ in
          UnevenRoundedRectangle(topLeadingRadius: 4 * unit, topTrailingRadius: 4 * unit)
            .fill(Color(red: 0.11, green: 0.10, blue: 0.13))
            .frame(width: 15 * unit, height: 16 * unit)
        }
      }
      .offset(y: 6 * unit)
    }
  }
}

// MARK: Trailer

private struct TVCinemaTrailerScene: View {
  @ObservedObject var show: TVCinemaPreShow
  let trailer: TVCinemaTrailer

  /// The title card stays at least this long, even when the trailer starts at once.
  private static let titleCardSeconds = 2.5

  private var year: String? { trailer.title.year.map(String.init) }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.25)) { context in
      let age = context.date.timeIntervalSince(show.actStarted)
      let card = !show.trailerPlaying || age < Self.titleCardSeconds
      ZStack(alignment: .bottomLeading) {
        TVCinemaVideoSurface(engine: show.engine)
        // Who the trailer is for, the whole time it runs, like a title on its detail page.
        LinearGradient(
          colors: [.black.opacity(0.65), .black.opacity(0.25), .clear],
          startPoint: .bottomLeading, endPoint: UnitPoint(x: 0.55, y: 0.45)
        )
        .allowsHitTesting(false)
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 7) {
            TVCinemaMark().frame(width: 26, height: 26)
            Text(["In Your Library", year].compactMap { $0 }.joined(separator: " · ").uppercased())
              .font(.system(size: 22, weight: .bold)).tracking(1.1)
              .foregroundStyle(.white.opacity(0.78))
          }
          Text(trailer.title.title)
            .font(.system(size: 60, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(2)
          if !trailer.title.genres.isEmpty {
            Text(trailer.title.genres.prefix(2).joined(separator: " · "))
              .font(.system(size: 26, weight: .semibold))
              .foregroundStyle(.white.opacity(0.75))
          }
        }
        .frame(maxWidth: 1000, alignment: .leading)
        .shadow(color: .black.opacity(0.5), radius: 10)
        .padding(.leading, 80).padding(.bottom, 70)
        .opacity(card ? 0 : 1)
        if card {
          TVCinemaComingUp(title: trailer.title.title, year: year)
            .transition(.opacity)
        }
      }
      .animation(.easeInOut(duration: 0.5), value: card)
    }
  }
}

/// The card before a trailer: what is coming up, in Aurelia's own type.
private struct TVCinemaComingUp: View {
  let title: String
  let year: String?

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [TVDesign.canvasTop, TVDesign.canvas, TVDesign.canvas], startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
      RadialGradient(
        colors: [TVCinemaBrand.echoTop.opacity(0.22), .clear], center: .center, startRadius: 0,
        endRadius: 520)
      VStack(spacing: 14) {
        TVCinemaMark().frame(width: 80, height: 80)
        Text("COMING UP")
          .font(.system(size: 24, weight: .bold)).tracking(1.6)
          .foregroundStyle(.white.opacity(0.7))
        Text(title)
          .font(.system(size: 76, weight: .bold))
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
          .lineLimit(2)
        if let year {
          Text(year).font(.system(size: 28, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
        }
      }
      .padding(.horizontal, 60)
    }
  }
}

/// Aurelia's colours: the white A and the blue-violet light echo behind it.
enum TVCinemaBrand {
  static let echoTop = Color(red: 0x8E / 255, green: 0xC5 / 255, blue: 1)
  static let echoBottom = Color(red: 0x5B / 255, green: 0x4F / 255, blue: 0xE0 / 255)
}

/// The A of Aurelia's icon with its light echo, drawn from the icon's own outline.
struct TVCinemaMark: View {
  var body: some View {
    ZStack {
      TVCinemaLetter(echo: true)
        .fill(
          LinearGradient(
            colors: [TVCinemaBrand.echoTop, TVCinemaBrand.echoBottom], startPoint: .top,
            endPoint: .bottom),
          style: FillStyle(eoFill: true))
      TVCinemaLetter(echo: false)
        .fill(
          LinearGradient(
            colors: [.white, Color(red: 0xE3 / 255, green: 0xE8 / 255, blue: 0xEE / 255)],
            startPoint: .top, endPoint: .bottom),
          style: FillStyle(eoFill: true))
    }
    .aspectRatio(1, contentMode: .fit)
    .accessibilityHidden(true)
  }
}

/// The A's outline, from the app icon (a 1024-unit square), cropped to the letter.
struct TVCinemaLetter: Shape {
  /// The light echo: the same A, 34 and 30 icon units to the lower right.
  let echo: Bool

  private static let outline = "M329.3 792.0 Q296.8 792.0 278.0 774.3 Q259.2 756.7 259.2 726.0 Q259.2 706.7 268.8 680.8 L402.9 312.8 Q417.9 271.2 443.8 251.6 Q469.6 232.0 510.0 232.0 Q552.8 232.0 579.0 251.1 Q605.2 270.2 620.7 312.7 L755.8 680.8 Q764.8 705.6 764.8 725.7 Q764.8 754.6 745.3 773.3 Q725.7 792.0 695.8 792.0 Q665.8 792.0 648.9 777.3 Q631.9 762.6 623.0 729.2 L604.5 669.2 L418.6 669.2 L400.1 727.2 Q390.3 761.7 373.7 776.9 Q357.1 792.0 329.3 792.0 Z M446.2 564.8 L574.3 564.8 L510.7 355.6 L507.9 355.6 Z"
  /// The letter and its echo in icon units, so together they fill the frame.
  private static let bounds = CGRect(x: 259.2, y: 232, width: 539.6, height: 590)

  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width / Self.bounds.width, rect.height / Self.bounds.height)
    let offset = CGPoint(
      x: rect.midX - Self.bounds.midX * scale, y: rect.midY - Self.bounds.midY * scale)
    func point(_ x: Double, _ y: Double) -> CGPoint {
      CGPoint(x: offset.x + (x + (echo ? 34 : 0)) * scale, y: offset.y + (y + (echo ? 30 : 0)) * scale)
    }
    var path = Path()
    var numbers: [Double] = []
    var command: Character = "M"
    func flush() {
      switch command {
      case "M" where numbers.count >= 2: path.move(to: point(numbers[0], numbers[1]))
      case "L" where numbers.count >= 2: path.addLine(to: point(numbers[0], numbers[1]))
      case "Q" where numbers.count >= 4:
        path.addQuadCurve(
          to: point(numbers[2], numbers[3]), control: point(numbers[0], numbers[1]))
      default: break
      }
      numbers = []
    }
    for token in Self.outline.split(separator: " ") {
      if let letter = token.first, letter.isLetter {
        flush()
        command = letter
        if letter == "Z" { path.closeSubpath() }
        let rest = token.dropFirst()
        if let value = Double(rest) { numbers.append(value) }
      } else if let value = Double(token) {
        numbers.append(value)
      }
    }
    flush()
    return path
  }
}

private struct TVCinemaVideoSurface: UIViewRepresentable {
  let engine: TVVideoEngine

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.backgroundColor = .black
    view.isUserInteractionEnabled = false
    engine.attach(to: view)
    return view
  }

  func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: Feature presentation

/// The curtain before the film: the house lights go down, a spotlight finds the title on the
/// velvet, then the curtain gathers to the sides, its hem swinging after, and the screen waits.
private struct TVCinemaCurtain: View {
  let title: String
  let time: Double
  /// When the curtain starts to open; nil while the film is still starting behind it.
  let opensAt: Double?
  let motion: Bool

  private var timing: TVCinemaCurtainTiming { TVCinemaCurtainTiming(opensAt: opensAt) }

  var body: some View {
    GeometryReader { geometry in
      let height = geometry.size.height
      let timing = timing
      let open = timing.open(time).top
      ZStack {
        Canvas { context, size in
          TVCinemaStage.drawBehind(&context, size: size, time: time, timing: timing)
        }
        Canvas { context, size in
          TVCinemaStage.drawDrapes(&context, size: size, time: time, timing: timing, motion: motion)
        }
        .opacity(motion ? 1 : 1 - open)
        Canvas { context, size in
          TVCinemaStage.drawLights(&context, size: size, time: time, timing: timing, motion: motion)
          TVCinemaStage.drawValance(&context, size: size)
        }
        titleCard(height: height)
          .frame(maxWidth: geometry.size.width * 0.8)
      }
      .frame(width: geometry.size.width, height: height)
      // The gathered curtain frames the film for a moment, then leaves it alone.
      .opacity(1 - timing.gone(time))
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Feature presentation: \(title)")
  }

  /// Aurelia presents: the A with its light echo, then the film's name in Aurelia's own type.
  private func titleCard(height: CGFloat) -> some View {
    VStack(spacing: height * 0.022) {
      ZStack {
        RadialGradient(
          colors: [TVCinemaBrand.echoBottom.opacity(0.45), .clear], center: .center, startRadius: 0,
          endRadius: height * 0.12)
          .frame(width: height * 0.3, height: height * 0.3)
        TVCinemaMark().frame(width: height * 0.085, height: height * 0.085)
      }
      .frame(height: height * 0.1)
      Text("AURELIA CINEMA PRESENTS")
        .font(.system(size: height * 0.021, weight: .bold))
        .tracking(height * 0.0045)
        .foregroundStyle(.white.opacity(0.78))
      Text(title)
        .font(.system(size: height * 0.075, weight: .bold))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.5)
    }
    .shadow(color: .black.opacity(0.75), radius: 16)
    .scaleEffect(motion ? 0.97 + 0.03 * ease(time, 0.9, 2.6) : 1)
    .opacity(shown(time, 0.9, timing.opening + 0.1, fade: 0.7))
  }
}

/// When the curtain moves, in seconds from its start.
struct TVCinemaCurtainTiming {
  /// When it starts to open; far away while the film is still starting behind it.
  let opening: Double

  init(opensAt: Double?) { opening = opensAt ?? 1_000_000 }

  /// How far the curtain is open at the top and at the hem, which follows a little later.
  func open(_ time: Double) -> (top: Double, hem: Double) {
    (ease(time, opening, 2.6), ease(time, opening + 0.1, 2.6))
  }

  /// The hem swinging out a little further and back as the curtain gathers.
  func sway(_ time: Double) -> Double {
    let since = time - opening - 0.1
    guard since > 0 else { return 0 }
    return 0.03 * sin(since * 2 * .pi * 0.75) * exp(-since * 1.1) * ease(since, 0, 0.6)
  }

  /// The house lights going down.
  func lightsDown(_ time: Double) -> Double { ease(time, 0.1, 1.2) }

  /// The dark over the curtain, lifting as it opens so the film isn't dimmed.
  func dimmed(_ time: Double) -> Double { lightsDown(time) * (1 - ease(time, opening, 1)) }

  /// The spotlight on the title, gone once the curtain opens.
  func spot(_ time: Double) -> Double { ease(time, 0.5, 0.8) * (1 - ease(time, opening + 0.2, 1)) }

  /// The black behind the curtain giving way to the film.
  func revealed(_ time: Double) -> Double { ease(time, opening + 0.3, 1.2) }

  /// The whole curtain fading off the playing film.
  func gone(_ time: Double) -> Double {
    ease(time, opening + TVCinemaPlan.curtainOpeningSeconds - 0.9, 0.8)
  }
}

/// The stage drawn with Core Graphics: screen, velvet, valance and light.
private enum TVCinemaStage {
  static let gold = Color(red: 0.95, green: 0.80, blue: 0.47)
  static let deepGold = Color(red: 0.76, green: 0.56, blue: 0.26)
  static let ivory = Color(red: 1, green: 0.96, blue: 0.86)
  static let folds = 11

  static func velvet(_ shade: Double) -> Color {
    Color(red: 0.62 * shade, green: 0.05 * shade, blue: 0.09 * shade)
  }

  static func floor(_ size: CGSize) -> CGFloat { size.height * 0.93 }

  /// The dark behind the closed curtain and the stage's edge, giving way to the film.
  static func drawBehind(
    _ context: inout GraphicsContext, size: CGSize, time: Double, timing: TVCinemaCurtainTiming
  ) {
    let dark = 1 - timing.revealed(time)
    guard dark > 0 else { return }
    context.opacity = dark
    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
    let floor = floor(size)
    context.fill(
      Path(CGRect(x: 0, y: floor, width: size.width, height: size.height - floor)),
      with: .linearGradient(
        Gradient(colors: [
          Color(red: 0.17, green: 0.09, blue: 0.05), Color(red: 0.05, green: 0.025, blue: 0.015),
        ]), startPoint: CGPoint(x: 0, y: floor), endPoint: CGPoint(x: 0, y: size.height)))
    context.fill(
      Path(CGRect(x: 0, y: floor, width: size.width, height: max(1.5, size.height * 0.003))),
      with: .color(deepGold.opacity(0.7)))
  }

  /// Both halves of the curtain, fold by fold, with a gold fringe on the hem.
  static func drawDrapes(
    _ context: inout GraphicsContext, size: CGSize, time: Double, timing: TVCinemaCurtainTiming,
    motion: Bool
  ) {
    let half = size.width / 2
    let floor = floor(size)
    let open = motion ? timing.open(time) : (top: 0, hem: 0)
    let sway = motion ? timing.sway(time) : 0
    let gathered = 0.12
    let topEdge = half * (1 - (1 - gathered) * open.top)
    let hemEdge = half * (1 - (1 - gathered) * min(1.04, open.hem + sway))
    // Gathered velvet folds deeper.
    let depth = 0.4 + 0.45 * open.top
    let stops: [Gradient.Stop] = [
      .init(color: velvet(1 - 0.8 * depth), location: 0),
      .init(color: velvet(0.85), location: 0.3),
      .init(color: velvet(1.25), location: 0.55),
      .init(color: velvet(0.8), location: 0.8),
      .init(color: velvet(1 - 0.8 * depth), location: 1),
    ]
    let fringe = size.height * 0.022
    for mirrored in [false, true] {
      func x(_ value: Double) -> Double { mirrored ? size.width - value : value }
      for fold in 0..<folds {
        let a = Double(fold) / Double(folds)
        let b = Double(fold + 1) / Double(folds)
        let overlap = 0.6
        let topLeft = x(topEdge * a - overlap)
        let topRight = x(topEdge * b + overlap)
        let hemLeft = x(hemEdge * a - overlap)
        let hemRight = x(hemEdge * b + overlap)
        var path = Path()
        path.move(to: CGPoint(x: topLeft, y: 0))
        path.addLine(to: CGPoint(x: topRight, y: 0))
        path.addLine(to: CGPoint(x: hemRight, y: floor))
        path.addQuadCurve(
          to: CGPoint(x: hemLeft, y: floor),
          control: CGPoint(x: (hemLeft + hemRight) / 2, y: floor + size.height * 0.01))
        path.closeSubpath()
        context.fill(
          path,
          with: .linearGradient(
            Gradient(stops: stops),
            startPoint: CGPoint(x: (topLeft + hemLeft) / 2, y: floor / 2),
            endPoint: CGPoint(x: (topRight + hemRight) / 2, y: floor / 2)))
      }
      // Shadow high under the valance and low near the floor.
      var outline = Path()
      outline.move(to: CGPoint(x: x(0), y: 0))
      outline.addLine(to: CGPoint(x: x(topEdge), y: 0))
      outline.addLine(to: CGPoint(x: x(hemEdge), y: floor))
      outline.addLine(to: CGPoint(x: x(0), y: floor))
      outline.closeSubpath()
      context.fill(
        outline,
        with: .linearGradient(
          Gradient(stops: [
            .init(color: .black.opacity(0.6), location: 0),
            .init(color: .clear, location: 0.3),
            .init(color: .clear, location: 0.7),
            .init(color: .black.opacity(0.3), location: 1),
          ]), startPoint: .zero, endPoint: CGPoint(x: 0, y: floor)))
      // The gold fringe, leaning with the swing.
      var threads = Path()
      let lean = sway * size.height * 0.25 * (mirrored ? -1 : 1)
      for position in stride(from: 0, through: hemEdge, by: 3.2) {
        threads.move(to: CGPoint(x: x(position), y: floor))
        threads.addLine(to: CGPoint(x: x(position) + lean, y: floor + fringe))
      }
      context.stroke(threads, with: .color(deepGold.opacity(0.85)), lineWidth: 1.2)
      var band = Path()
      band.move(to: CGPoint(x: x(0), y: floor))
      band.addLine(to: CGPoint(x: x(hemEdge), y: floor))
      context.stroke(band, with: .color(gold), lineWidth: max(2, size.height * 0.006))
    }
  }

  /// House lights fading on the walls, then a spotlight with dust in its beam.
  static func drawLights(
    _ context: inout GraphicsContext, size: CGSize, time: Double, timing: TVCinemaCurtainTiming,
    motion: Bool
  ) {
    let dimmed = timing.dimmed(time)
    context.fill(
      Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.3 * dimmed)))
    var light = context
    light.blendMode = .plusLighter
    for side in [0.05, 0.95] {
      let center = CGPoint(x: size.width * side, y: size.height * 0.42)
      let radius = size.height * 0.34
      light.fill(
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
        with: .radialGradient(
          Gradient(colors: [
            Color(red: 1, green: 0.7, blue: 0.35).opacity(0.38 * (1 - timing.lightsDown(time))), .clear,
          ]), center: center, startRadius: 0, endRadius: radius))
    }
    let spot = timing.spot(time)
    guard spot > 0 else { return }
    let center = CGPoint(x: size.width / 2, y: size.height * 0.48)
    let radius = size.height * 0.44
    light.fill(
      Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
      with: .radialGradient(
        Gradient(stops: [
          .init(color: Color(red: 1, green: 0.93, blue: 0.8).opacity(0.3 * spot), location: 0),
          .init(color: Color(red: 1, green: 0.85, blue: 0.65).opacity(0.12 * spot), location: 0.6),
          .init(color: .clear, location: 1),
        ]), center: center, startRadius: 0, endRadius: radius))
    guard motion else { return }
    for index in 0..<44 {
      let seed = Double(index)
      let a = fraction(sin(seed * 12.9898) * 43_758.5453)
      let b = fraction(sin(seed * 78.233) * 12_345.6789)
      let c = fraction(sin(seed * 39.425) * 24_634.6345)
      let point = CGPoint(
        x: center.x + (a - 0.5) * radius * 1.5 + sin(time * 0.5 + seed) * 6,
        y: size.height * (0.12 + 0.72 * fraction(b - time * 0.012 * (0.5 + c))))
      let distance = hypot(point.x - center.x, point.y - center.y) / radius
      guard distance < 1 else { continue }
      let glow = spot * (1 - distance) * (0.55 + 0.45 * sin(time * 1.7 + seed * 1.3))
      let dot = 0.8 + c * 1.8
      light.fill(
        Path(ellipseIn: CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)),
        with: .color(Color(red: 1, green: 0.92, blue: 0.78).opacity(0.7 * glow)))
    }
  }

  /// The valance across the top: velvet swags with folds, gold trim and tassels.
  static func drawValance(_ context: inout GraphicsContext, size: CGSize) {
    let depth = size.height * 0.11
    let swags = max(3, Int((size.width / size.height * 3).rounded()))
    let width = size.width / Double(swags)
    // Its shadow on the curtain.
    context.fill(
      Path(CGRect(x: 0, y: 0, width: size.width, height: depth * 1.5)),
      with: .linearGradient(
        Gradient(colors: [.black.opacity(0.5), .clear]), startPoint: CGPoint(x: 0, y: depth * 0.6),
        endPoint: CGPoint(x: 0, y: depth * 1.5)))
    context.fill(
      Path(CGRect(x: 0, y: 0, width: size.width, height: depth * 0.55)),
      with: .color(velvet(0.55)))
    let trim = max(2, size.height * 0.005)
    for swag in 0..<swags {
      let left = Double(swag) * width
      let right = left + width
      let middle = (left + right) / 2
      var path = Path()
      path.move(to: CGPoint(x: left, y: 0))
      path.addLine(to: CGPoint(x: right, y: 0))
      path.addLine(to: CGPoint(x: right, y: depth * 0.5))
      path.addQuadCurve(
        to: CGPoint(x: left, y: depth * 0.5), control: CGPoint(x: middle, y: depth * 1.5))
      path.closeSubpath()
      context.fill(
        path,
        with: .linearGradient(
          Gradient(stops: [
            .init(color: velvet(0.5), location: 0),
            .init(color: velvet(1.2), location: 0.7),
            .init(color: velvet(0.75), location: 1),
          ]), startPoint: .zero, endPoint: CGPoint(x: 0, y: depth)))
      for fold in 1...3 {
        let share = Double(fold) / 4
        var crease = Path()
        crease.move(to: CGPoint(x: left, y: depth * 0.5 * share))
        crease.addQuadCurve(
          to: CGPoint(x: right, y: depth * 0.5 * share),
          control: CGPoint(x: middle, y: depth * 1.5 * share))
        context.stroke(crease, with: .color(velvet(0.45).opacity(0.8)), lineWidth: 2)
        context.stroke(
          crease.offsetBy(dx: 0, dy: 2), with: .color(velvet(1.4).opacity(0.35)), lineWidth: 1)
      }
      var hem = Path()
      hem.move(to: CGPoint(x: left, y: depth * 0.5))
      hem.addQuadCurve(
        to: CGPoint(x: right, y: depth * 0.5), control: CGPoint(x: middle, y: depth * 1.5))
      context.stroke(hem, with: .color(gold), lineWidth: trim)
    }
    // A tassel where two swags meet.
    for join in 0...swags {
      let x = Double(join) * width
      var cord = Path()
      cord.move(to: CGPoint(x: x, y: depth * 0.45))
      cord.addLine(to: CGPoint(x: x, y: depth * 0.8))
      context.stroke(cord, with: .color(deepGold), lineWidth: max(1, trim * 0.5))
      let tassel = CGRect(x: x - depth * 0.06, y: depth * 0.78, width: depth * 0.12, height: depth * 0.3)
      context.fill(
        Path(roundedRect: tassel, cornerRadius: depth * 0.05),
        with: .linearGradient(
          Gradient(colors: [gold, deepGold]), startPoint: CGPoint(x: tassel.minX, y: 0),
          endPoint: CGPoint(x: tassel.maxX, y: 0)))
    }
  }

  private static func fraction(_ value: Double) -> Double { value - value.rounded(.down) }
}

// MARK: Shapes

private struct TVCinemaSunburst: Shape {
  let rays: Int
  var inner: Double = 0

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let radius = max(rect.width, rect.height) / 2
    let step = 2 * Double.pi / Double(rays)
    if inner > 0 {
      // A starburst badge.
      for index in 0..<(rays * 2) {
        let angle = Double(index) * step / 2
        let length = index.isMultiple(of: 2) ? radius : radius * inner
        let point = CGPoint(
          x: center.x + cos(angle) * length, y: center.y + sin(angle) * length)
        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
      }
      path.closeSubpath()
      return path
    }
    for index in 0..<rays {
      let angle = Double(index) * step
      path.move(to: center)
      path.addArc(
        center: center, radius: radius * 1.5, startAngle: .radians(angle),
        endAngle: .radians(angle + step / 2), clockwise: false)
      path.closeSubpath()
    }
    return path
  }
}

private struct TVCinemaCone: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

private struct TVCinemaWaffle: Shape {
  let spacing: CGFloat

  func path(in rect: CGRect) -> Path {
    var path = Path()
    var offset = -rect.height
    while offset < rect.width + rect.height {
      path.move(to: CGPoint(x: rect.minX + offset, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.maxY))
      path.move(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
      offset += spacing
    }
    return path
  }
}

private struct TVCinemaBucket: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let inset = rect.width * 0.14
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

/// A popped kernel: a little cloud of three puffs.
private struct TVCinemaKernel: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let w = rect.width
    let h = rect.height
    path.addEllipse(in: CGRect(x: rect.minX, y: rect.minY + h * 0.3, width: w * 0.55, height: h * 0.6))
    path.addEllipse(in: CGRect(x: rect.minX + w * 0.4, y: rect.minY + h * 0.25, width: w * 0.6, height: h * 0.65))
    path.addEllipse(in: CGRect(x: rect.minX + w * 0.2, y: rect.minY, width: w * 0.6, height: h * 0.6))
    return path
  }
}

/// The light bulbs around a cinema sign, chasing each other.
private struct TVCinemaMarquee: View {
  let time: Double
  let bulb: CGFloat
  let color: Color

  var body: some View {
    Canvas { context, size in
      let gap = bulb * 3
      let inset = bulb * 2.5
      var points: [CGPoint] = []
      var x = inset
      while x <= size.width - inset {
        points.append(CGPoint(x: x, y: inset))
        x += gap
      }
      var y = inset + gap
      while y <= size.height - inset {
        points.append(CGPoint(x: size.width - inset, y: y))
        y += gap
      }
      x = size.width - inset - gap
      while x >= inset {
        points.append(CGPoint(x: x, y: size.height - inset))
        x -= gap
      }
      y = size.height - inset - gap
      while y > inset {
        points.append(CGPoint(x: inset, y: y))
        y -= gap
      }
      let step = Int(time * 9)
      for (index, point) in points.enumerated() {
        let lit = (index + step) % 3 == 0
        let rect = CGRect(x: point.x - bulb / 2, y: point.y - bulb / 2, width: bulb, height: bulb)
        context.fill(Path(ellipseIn: rect), with: .color(color.opacity(lit ? 1 : 0.28)))
      }
    }
    .allowsHitTesting(false)
  }
}
