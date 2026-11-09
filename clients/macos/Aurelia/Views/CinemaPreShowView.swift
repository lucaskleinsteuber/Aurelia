import AppKit
import SwiftUI

/// Cinema mode's pre-show over the player: an ad, trailers and the curtain before the film.
struct CinemaPreShowView: View {
  @ObservedObject var show: CinemaPreShow
  let reduceMotion: Bool

  var body: some View {
    ZStack {
      Color.black
      switch show.act {
      case .ad(let ad):
        TimelineView(.animation) { context in
          CinemaAdScene(
            ad: ad, time: context.date.timeIntervalSince(show.actStarted), motion: !reduceMotion)
        }
        .id(ad.rawValue)
        .transition(.opacity)
      case .trailer(let trailer):
        CinemaTrailerScene(show: show, trailer: trailer)
          .id(trailer.trailer.id)
          .transition(.opacity)
      case .feature(let title):
        TimelineView(.animation) { context in
          CinemaCurtain(
            title: title, time: context.date.timeIntervalSince(show.actStarted),
            motion: !reduceMotion)
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
            .font(.system(size: 11, weight: .semibold)).tracking(1.4)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.35), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
        }
        Spacer()
      }
      Spacer()
      HStack(spacing: 10) {
        Spacer()
        CinemaChromeButton(title: "Skip", symbol: "forward.end.fill", key: "→") { show.skip() }
          .accessibilityIdentifier("cinema-skip")
        CinemaChromeButton(title: "Start Film", symbol: "play.fill", key: "⏎") {
          show.startFilm()
        }
        .accessibilityIdentifier("cinema-start-film")
      }
    }
    .padding(28)
    .opacity(show.act == nil ? 0 : 1)
  }
}

private struct CinemaChromeButton: View {
  let title: String
  let symbol: String
  let key: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        Image(systemName: symbol).font(.system(size: 11, weight: .bold))
        Text(title).font(.system(size: 13, weight: .semibold))
        Text(key).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 14).padding(.vertical, 8)
      .background(.black.opacity(hovering ? 0.6 : 0.4), in: Capsule())
      .overlay(Capsule().strokeBorder(.white.opacity(hovering ? 0.45 : 0.22)))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .focusable(false)
    .onHover { hovering = $0 }
    .accessibilityLabel(title)
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

private struct CinemaAdScene: View {
  let ad: CinemaAd
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
      .overlay(Color.black.opacity(ease(time, CinemaAd.duration - 0.6, 0.6)))
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("An ad")
  }
}

private struct IceCreamAd: View {
  let time: Double
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
      CinemaSunburst(rays: 18)
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
          .opacity(shown(time, 11.8, 20))
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
          .opacity(shown(time, 5.2, 20))
      }
      CinemaCone()
        .fill(
          LinearGradient(
            colors: [Color(red: 0.88, green: 0.64, blue: 0.36), Color(red: 0.72, green: 0.47, blue: 0.24)],
            startPoint: .leading, endPoint: .trailing)
        )
        .overlay(CinemaWaffle(spacing: 4.5 * unit).stroke(.black.opacity(0.14), lineWidth: 0.5 * unit))
        .clipShape(CinemaCone())
        .frame(width: 25 * unit, height: 36 * unit)
        .offset(y: motion ? (1 - ease(time, 0.3, 0.9)) * 70 * unit : 0)
        .opacity(ease(time, 0.3, 0.4))
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
              - (motion ? (1 - bounce(time, at)) * 90 * unit : 0))
          .opacity(motion ? (time >= at ? 1 : 0) : ease(time, at, 0.3))
      }
      Circle()
        .fill(Color(red: 0.86, green: 0.05, blue: 0.14))
        .overlay(Circle().fill(.white.opacity(0.5)).frame(width: 2 * unit).offset(x: -1.5 * unit, y: -1.5 * unit))
        .frame(width: 8 * unit, height: 8 * unit)
        .offset(y: -82 * unit - (motion ? (1 - bounce(time, 5.0, 0.6)) * 60 * unit : 0))
        .opacity(motion ? (time >= 5 ? 1 : 0) : ease(time, 5, 0.3))
    }
    .frame(width: 34 * unit, height: 92 * unit, alignment: .bottom)
  }

  private var words: some View {
    ZStack(alignment: .leading) {
      VStack(alignment: .leading, spacing: 2 * unit) {
        Text("Feeling warm?")
          .font(.system(size: 8 * unit, weight: .bold, design: .rounded))
        Text("Ninety minutes is a long time.")
          .font(.system(size: 4.2 * unit, weight: .medium, design: .rounded))
          .opacity(ease(time, 2.2))
      }
      .foregroundStyle(berry)
      .opacity(shown(time, 0.8, 4.6))

      VStack(alignment: .leading, spacing: 2.5 * unit) {
        Text("Aurelia Ice")
          .font(.system(size: 14 * unit, weight: .black, design: .rounded))
          .foregroundStyle(.white)
          .shadow(color: berry.opacity(0.55), radius: 0, x: 0.8 * unit, y: 0.8 * unit)
          .scaleEffect(motion ? pop(time, 5.0) : 1, anchor: .leading)
        Text("Three scoops. Zero plot holes.")
          .font(.system(size: 4.6 * unit, weight: .semibold, design: .rounded))
          .opacity(ease(time, 6.3))
        Text("Now in the foyer.")
          .font(.system(size: 4.6 * unit, weight: .semibold, design: .rounded))
          .opacity(ease(time, 8.0))
      }
      .foregroundStyle(berry)
      .opacity(ease(time, 5.0, 0.3))
      .overlay(alignment: .topTrailing) {
        ZStack {
          CinemaSunburst(rays: 14, inner: 0.78).fill(Color(red: 1, green: 0.86, blue: 0.2))
          VStack(spacing: 0) {
            Text("ONLY").font(.system(size: 2.6 * unit, weight: .heavy, design: .rounded))
            Text("4.50!").font(.system(size: 5 * unit, weight: .black, design: .rounded))
          }
          .foregroundStyle(berry)
        }
        .frame(width: 20 * unit, height: 20 * unit)
        .rotationEffect(.degrees(-14))
        .scaleEffect(motion ? max(0, pop(time, 9.4)) : ease(time, 9.4, 0.3))
        .opacity(time >= 9.4 ? 1 : 0)
        .offset(x: 2 * unit, y: -16 * unit)
      }
    }
  }
}

private struct PopcornAd: View {
  let time: Double
  let motion: Bool
  let unit: CGFloat

  private let gold = Color(red: 1, green: 0.82, blue: 0.32)
  private let kernel = Color(red: 1, green: 0.95, blue: 0.80)

  var body: some View {
    ZStack {
      RadialGradient(
        colors: [Color(red: 0.62, green: 0.05, blue: 0.10), Color(red: 0.22, green: 0, blue: 0.04)],
        center: .center, startRadius: 0, endRadius: 120 * unit)
      CinemaMarquee(time: motion ? time : 0, bulb: 1.6 * unit, color: gold)
      HStack(alignment: .center, spacing: 12 * unit) {
        bucket
        words.frame(width: 70 * unit, alignment: .leading)
      }
      VStack {
        Spacer()
        Text("*Rustling the bag in the dark is included at no extra cost.")
          .font(.system(size: 2.1 * unit, weight: .medium))
          .foregroundStyle(.white.opacity(0.6))
          .opacity(shown(time, 12, 20))
          .padding(.bottom, 6 * unit)
      }
    }
  }

  private var bucket: some View {
    let width = 36 * unit
    let height = 42 * unit
    let landed = motion ? CinemaPopcorn.kernels.filter { $0.launch + 0.7 < time }.count : 40
    return ZStack(alignment: .bottom) {
      // The heap grows as kernels land.
      ForEach(0..<min(landed, 34), id: \.self) { index in
        let row = index < 13 ? 0 : index < 23 ? 1 : index < 30 ? 2 : 3
        let inRow = [13, 10, 7, 4][row]
        let first = [0, 13, 23, 30][row]
        let x = (Double(index - first) - Double(inRow - 1) / 2) * 3 * Double(unit)
        CinemaKernel()
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
      .clipShape(CinemaBucket())
      Canvas { context, size in
        guard motion else { return }
        for (index, flying) in CinemaPopcorn.kernels.enumerated() {
          let age = time - flying.launch
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
          piece.fill(CinemaKernel().path(in: rect), with: .color(kernel))
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
        .scaleEffect(motion ? pop(time, 0.6) : 1, anchor: .leading)
        .opacity(ease(time, 0.6, 0.3))
      Text("Louder than the film.")
        .font(.system(size: 5.6 * unit, weight: .bold, design: .rounded))
        .opacity(ease(time, 3.4))
      Text("Now with extra crunch for the quiet scenes.")
        .font(.system(size: 3.8 * unit, weight: .medium, design: .rounded))
        .opacity(ease(time, 6.0))
      Text("Crunch responsibly.")
        .font(.system(size: 4.2 * unit, weight: .heavy, design: .rounded))
        .foregroundStyle(Color(red: 0.4, green: 0, blue: 0.05))
        .padding(.horizontal, 3 * unit).padding(.vertical, 1.2 * unit)
        .background(gold, in: Capsule())
        .scaleEffect(motion ? max(0, pop(time, 10.6)) : 1, anchor: .leading)
        .opacity(time >= 10.6 ? 1 : 0)
        .padding(.top, 2 * unit)
    }
    .foregroundStyle(.white)
  }
}

private struct PhonesAd: View {
  let time: Double
  let motion: Bool
  let unit: CGFloat

  private var off: Double { ease(time, CinemaPhones.silence, 0.25) }

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
        .opacity(shown(time, 0.3, 7.7))
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
    time < CinemaPhones.silence
      && CinemaPhones.notifications.contains { time >= $0.time && time < $0.time + 0.8 }
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
      ForEach(CinemaPhones.notifications.indices, id: \.self) { index in
        let message = CinemaPhones.notifications[index]
        let appear = ease(time, message.time, 0.3)
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
        .opacity(ease(time, 8.5, 0.7))
      Text("Phones off. Yes, yours too.")
        .font(.system(size: 4.6 * unit, weight: .medium))
        .opacity(ease(time, 9.9))
      Text("The group chat will survive. Probably.")
        .font(.system(size: 3 * unit))
        .foregroundStyle(.white.opacity(0.55))
        .opacity(ease(time, 11.6))
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

private struct CinemaTrailerScene: View {
  @ObservedObject var show: CinemaPreShow
  let trailer: CinemaTrailer

  var body: some View {
    ZStack(alignment: .topLeading) {
      CinemaVideoSurface(engine: show.engine)
      if !show.trailerPlaying {
        ZStack {
          Color.black
          VStack(spacing: 10) {
            Text("Coming up").font(.system(size: 13, weight: .semibold)).tracking(1.2)
              .foregroundStyle(.white.opacity(0.6))
            Text(trailer.title.title).font(.system(size: 30, weight: .semibold, design: .serif))
              .foregroundStyle(.white)
          }
        }
        .transition(.opacity)
      }
      TimelineView(.periodic(from: .now, by: 0.5)) { context in
        let age = context.date.timeIntervalSince(show.actStarted)
        VStack(alignment: .leading, spacing: 4) {
          Text("In your library").font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
          Text(
            [trailer.title.title, trailer.title.year.map(String.init)].compactMap { $0 }
              .joined(separator: " · ")
          )
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.6), radius: 8)
        .padding(.leading, 28).padding(.top, 70)
        .opacity(show.trailerPlaying && age < 9 ? 1 : 0)
        .animation(.easeInOut(duration: 0.6), value: show.trailerPlaying && age < 9)
      }
    }
    .animation(.easeInOut(duration: 0.4), value: show.trailerPlaying)
  }
}

private struct CinemaVideoSurface: NSViewRepresentable {
  let engine: VLCPlaybackEngine

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    engine.attach(to: view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: Feature presentation

private struct CinemaCurtain: View {
  let title: String
  let time: Double
  let motion: Bool

  private let gold = Color(red: 0.93, green: 0.78, blue: 0.45)

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let height = geometry.size.height
      let open = ease(time, 2.6, 2.6)
      ZStack {
        RadialGradient(
          colors: [gold.opacity(0.22), .clear], center: .center, startRadius: 0,
          endRadius: height * 0.6)
        HStack(spacing: 0) {
          CinemaVelvet()
            .frame(width: width / 2 + 2)
            .scaleEffect(x: motion ? 1 - 0.75 * open : 1, anchor: .leading)
          Spacer(minLength: 0)
          CinemaVelvet()
            .frame(width: width / 2 + 2)
            .scaleEffect(x: motion ? 1 - 0.75 * open : 1, anchor: .trailing)
        }
        .opacity(motion ? 1 : 1 - open)
        VStack {
          LinearGradient(
            colors: [Color(red: 0.32, green: 0.02, blue: 0.05), Color(red: 0.5, green: 0.04, blue: 0.08)],
            startPoint: .top, endPoint: .bottom
          )
          .frame(height: height * 0.11)
          .overlay(alignment: .bottom) { gold.frame(height: max(2, height * 0.006)) }
          Spacer()
        }
        VStack(spacing: height * 0.02) {
          Text("FEATURE PRESENTATION")
            .font(.system(size: height * 0.03, weight: .medium, design: .serif))
            .tracking(height * 0.008)
            .foregroundStyle(gold)
          Text(title)
            .font(.system(size: height * 0.065, weight: .semibold, design: .serif))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, width * 0.1)
        }
        .shadow(color: .black.opacity(0.7), radius: 12)
        .opacity(shown(time, 0.4, 2.8, fade: 0.7))
      }
      .frame(width: width, height: height)
      .overlay(Color.black.opacity(ease(time, CinemaPreShowPlan.featureSeconds - 0.9, 0.9)))
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Feature presentation: \(title)")
  }
}

private struct CinemaVelvet: View {
  var body: some View {
    HStack(spacing: 0) {
      ForEach(0..<7, id: \.self) { _ in
        LinearGradient(
          colors: [
            Color(red: 0.30, green: 0.01, blue: 0.04), Color(red: 0.62, green: 0.05, blue: 0.10),
            Color(red: 0.42, green: 0.02, blue: 0.06), Color(red: 0.30, green: 0.01, blue: 0.04),
          ],
          startPoint: .leading, endPoint: .trailing)
      }
    }
    .overlay(
      LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom))
  }
}

// MARK: Shapes

private struct CinemaSunburst: Shape {
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

private struct CinemaCone: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

private struct CinemaWaffle: Shape {
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

private struct CinemaBucket: Shape {
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
private struct CinemaKernel: Shape {
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
private struct CinemaMarquee: View {
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
