import AVFoundation
import Foundation

/// Cinema mode's pre-show before a film, copied from the Mac app: the player shows it while `act`
/// is set and starts the film behind the curtain. Select on Start Film ends it at any time, Skip
/// moves on one part. Trailers play through their own decoder and relay, which stop with them.
@MainActor
final class TVCinemaPreShow: ObservableObject {
  @Published private(set) var act: TVCinemaAct?
  /// When the current part began; the ads animate from it.
  @Published private(set) var actStarted = Date()
  /// The trailer's picture is moving.
  @Published private(set) var trailerPlaying = false
  /// Seconds into the curtain at which it starts to open, once the film is playing behind it.
  @Published private(set) var curtainOpensAt: Double?

  /// Starts the film behind the curtain, so the curtain opens onto it.
  var onFeature: (() -> Void)?
  private var filmShowing = false
  private var waitingForFilm = false
  private var actSkipped = false

  let engine = TVVideoEngine()
  private let acts: [TVCinemaAct]
  private let api: TVAPIClient
  private let fingerprint: String
  private let token: String
  private let sound = TVCinemaSound()
  private var finished = false
  private var actDone: CheckedContinuation<Void, Never>?
  private var actTimer: Task<Void, Never>?
  private var startCheck: Task<Void, Never>?

  init(acts: [TVCinemaAct], api: TVAPIClient, fingerprint: String, token: String) {
    self.acts = acts
    self.api = api
    self.fingerprint = fingerprint
    self.token = token
  }

  /// The pre-show before `film`, or nil when it gets none. Asks the server for at most a few
  /// seconds, so a slow answer never holds up the film.
  static func prepare(
    api: TVAPIClient, film: UUID, title: String, preferences: TVPlaybackPreferences,
    startOver: Bool, fingerprint: String, token: String, defaults: UserDefaults = .standard
  ) async -> TVCinemaPreShow? {
    let preferences = preferences.normalized
    let trailers = await withTaskGroup(of: [TVCinemaTrailer]?.self) { group in
      group.addTask {
        let progress = startOver ? nil : try? await api.progress(mediaID: film)
        guard
          TVCinemaPlan.startsAtBeginning(
            startOver: startOver, progress: progress,
            automaticResume: preferences.automaticResume)
        else { return nil }
        // A film without trailers still gets the ad; an error means no pre-show at all.
        guard preferences.cinemaTrailers > 0 else { return [] }
        return try? await api.cinemaTrailers(mediaID: film, count: preferences.cinemaTrailers)
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(5))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
    guard let trailers, !Task.isCancelled else { return nil }
    var ad: TVCinemaAd?
    if preferences.cinemaAds {
      ad = TVCinemaPlan.ad(after: defaults.string(forKey: TVCinemaPlan.lastAdKey))
      defaults.set(ad?.rawValue, forKey: TVCinemaPlan.lastAdKey)
    }
    let acts = TVCinemaPlan.acts(ad: ad, trailers: trailers, film: film, title: title)
    guard !acts.isEmpty else { return nil }
    return TVCinemaPreShow(acts: acts, api: api, fingerprint: fingerprint, token: token)
  }

  /// Plays every part; returns when the pre-show is over, skipped or the player closes.
  func run() async {
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try? AVAudioSession.sharedInstance().setActive(true)
    await withTaskCancellationHandler {
      for act in acts {
        guard !finished, !Task.isCancelled else { break }
        self.act = act
        actStarted = Date()
        trailerPlaying = false
        actSkipped = false
        switch act {
        case .ad(let ad):
          sound.play(TVCinemaTunes.notes(for: ad), volume: 1)
          await waitForAct(seconds: TVCinemaAd.duration)
        case .trailer(let trailer):
          sound.stop()
          await play(trailer)
        case .feature:
          await feature()
        }
      }
      sound.stop()
      act = nil
    } onCancel: {
      Task { @MainActor [weak self] in self?.stop() }
    }
  }

  /// On to the next part.
  func skip() {
    actSkipped = true
    endAct()
  }

  /// The film's picture is moving behind the curtain.
  func filmStarted() {
    filmShowing = true
    if waitingForFilm { endAct() }
  }

  private func feature() async {
    curtainOpensAt = nil
    sound.play(TVCinemaTunes.fanfareCall, volume: 1)
    onFeature?()
    await waitForAct(seconds: TVCinemaPlan.curtainEarliestOpening)
    guard !actSkipped, !finished else { return }
    if !filmShowing {
      waitingForFilm = true
      await waitForAct(
        seconds: TVCinemaPlan.curtainLongestWait - TVCinemaPlan.curtainEarliestOpening)
      waitingForFilm = false
      guard !actSkipped, !finished else { return }
    }
    curtainOpensAt = Date().timeIntervalSince(actStarted)
    sound.play(TVCinemaTunes.fanfareAnswer, volume: 1)
    await waitForAct(seconds: TVCinemaPlan.curtainOpeningSeconds)
  }

  /// Straight to the film.
  func startFilm() {
    finished = true
    actSkipped = true
    endAct()
  }

  /// The player closed.
  func stop() {
    finished = true
    endAct()
    engine.stop()
    sound.stop()
  }

  private func play(_ item: TVCinemaTrailer) async {
    let api = api
    guard let ticket = try? await api.createTicket(mediaID: item.trailer.id) else { return }
    defer { Task { try? await api.revokeTicket(id: ticket.id) } }
    guard !finished, let source = try? api.validatedStreamURL(path: ticket.streamPath),
      let relay = try? TVStreamRelay(
        sourceURL: source, publicKeyFingerprint: fingerprint, authorizationToken: token)
    else { return }
    defer { relay.stop() }
    guard let local = try? await relay.start(), !finished else { return }
    engine.onTerminal = { [weak self] _ in self?.endAct() }
    engine.onUpdate = { [weak self] in
      guard let self, !self.trailerPlaying, self.engine.isPlaying, self.engine.position > 0
      else { return }
      self.trailerPlaying = true
    }
    engine.load(url: local, resumeAt: 0)
    startCheck = Task { [weak self] in
      try? await Task.sleep(for: .seconds(TVCinemaPlan.trailerStartSeconds))
      guard let self, !Task.isCancelled, !self.trailerPlaying else { return }
      self.endAct()
    }
    await waitForAct(seconds: TVCinemaPlan.trailerLongestSeconds)
    startCheck?.cancel()
    engine.onTerminal = nil
    engine.onUpdate = nil
    engine.stop()
  }

  private func waitForAct(seconds: Double) async {
    guard !finished else { return }
    await withCheckedContinuation { continuation in
      actDone = continuation
      actTimer = Task { [weak self] in
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled else { return }
        self?.endAct()
      }
    }
  }

  private func endAct() {
    actTimer?.cancel()
    actTimer = nil
    let done = actDone
    actDone = nil
    done?.resume()
  }
}

// MARK: Sound

/// A note of the ads' little tunes, made on the device; no sound files ship with Aurelia.
struct TVCinemaNote: Equatable, Sendable {
  enum Voice: Sendable {
    /// Glockenspiel.
    case bell
    /// A plucked string.
    case pluck
    /// Popcorn going off.
    case pop
    /// A phone buzzing on a table.
    case buzz
    /// Brass for the fanfare.
    case brass
  }

  let time: Double
  let frequency: Double
  let length: Double
  let voice: Voice
  var level: Double = 0.5
}

enum TVCinemaSynth {
  static let sampleRate = 44_100.0

  /// Mono samples of `notes`, never louder than 0.9.
  static func samples(_ notes: [TVCinemaNote]) -> [Float] {
    let end = notes.map { $0.time + $0.length + release($0.voice) }.max() ?? 0
    var output = [Float](repeating: 0, count: Int(end * sampleRate) + 1)
    var noise = Noise(seed: 0x5EED)
    for note in notes {
      let start = Int(note.time * sampleRate)
      let count = Int((note.length + release(note.voice)) * sampleRate)
      var phase = 0.0
      for index in 0..<count where start + index < output.count {
        let time = Double(index) / sampleRate
        var frequency = note.frequency
        if note.voice == .pop { frequency *= 1 + 2.5 * exp(-time * 60) }
        if note.voice == .brass { frequency *= 1 + 0.004 * sin(2 * .pi * 5.5 * time) }
        phase += 2 * .pi * frequency / sampleRate
        let value = sample(note, time: time, phase: phase, noise: &noise)
        output[start + index] += Float(note.level * value)
      }
    }
    let peak = output.map(abs).max() ?? 0
    if peak > 0.9 {
      let scale = 0.9 / peak
      for index in output.indices { output[index] *= scale }
    }
    return output
  }

  private static func release(_ voice: TVCinemaNote.Voice) -> Double {
    switch voice {
    case .bell: 1.2
    case .pluck: 0.5
    case .pop: 0.05
    case .buzz: 0.03
    case .brass: 0.35
    }
  }

  private static func sample(
    _ note: TVCinemaNote, time: Double, phase: Double, noise: inout Noise
  ) -> Double {
    let attack = min(1, time / 0.006)
    switch note.voice {
    case .bell:
      return attack
        * (sin(phase) * exp(-time * 2.6) + 0.35 * sin(phase * 2.76) * exp(-time * 6)
          + 0.15 * sin(phase * 5.4) * exp(-time * 11))
    case .pluck:
      return attack * exp(-time * 7)
        * (sin(phase) + 0.45 * sin(phase * 2) + 0.2 * sin(phase * 3))
    case .pop:
      return exp(-time * 70) * (0.7 * noise.next() + 0.6 * sin(phase))
    case .buzz:
      let shape = tanh(3 * sin(phase)) * (0.6 + 0.4 * sin(2 * .pi * 28 * time))
      let fade = time < note.length ? 1 : max(0, 1 - (time - note.length) / 0.03)
      return min(1, time / 0.02) * fade * shape
    case .brass:
      let swell = min(1, time / 0.07)
      let fade = time < note.length ? 1 : max(0, 1 - (time - note.length) / 0.35)
      var value = 0.0
      for harmonic in 1...6 {
        value += sin(phase * Double(harmonic)) / Double(harmonic) * (harmonic > 3 ? swell : 1)
      }
      return swell * fade * value * 0.6
    }
  }

  /// A fixed noise, so every showing sounds the same.
  struct Noise {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Double(state >> 11) / Double(1 << 53) * 2 - 1
    }
  }
}

/// Plays one tune at a time on the Apple TV.
@MainActor
final class TVCinemaSound {
  private var engine: AVAudioEngine?

  func play(_ notes: [TVCinemaNote], volume: Double) {
    stop()
    let samples = TVCinemaSynth.samples(notes)
    guard !samples.isEmpty,
      let format = AVAudioFormat(standardFormatWithSampleRate: TVCinemaSynth.sampleRate, channels: 1),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let channel = buffer.floatChannelData?[0]
    else { return }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      channel.update(from: source.baseAddress!, count: samples.count)
    }
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    engine.mainMixerNode.outputVolume = Float(min(max(volume, 0), 1) * 0.6)
    do { try engine.start() } catch { return }
    player.scheduleBuffer(buffer)
    player.play()
    self.engine = engine
  }

  func stop() {
    engine?.stop()
    engine = nil
  }
}

/// The ads' tunes, timed to the pictures in TVCinemaPreShowView.
enum TVCinemaTunes {

  private static func hertz(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

  private static func bells(_ notes: [(Double, Int)], length: Double = 0.4, level: Double = 0.4)
    -> [TVCinemaNote]
  {
    notes.map { TVCinemaNote(time: $0.0, frequency: hertz($0.1), length: length, voice: .bell, level: level) }
  }

  /// The ad's tune, its notes moved to where their pictures are in the slower ad.
  static func notes(for ad: TVCinemaAd) -> [TVCinemaNote] {
    scriptNotes(for: ad).map {
      TVCinemaNote(
        time: $0.time * TVCinemaAd.pace, frequency: $0.frequency, length: $0.length, voice: $0.voice,
        level: $0.level)
    }
  }

  private static func scriptNotes(for ad: TVCinemaAd) -> [TVCinemaNote] {
    switch ad {
    case .iceCream:
      // A bright jingle, a plop for every scoop, and a "ta-da" for the price.
      return bells([(0.3, 84), (0.45, 88), (0.6, 91), (0.75, 96)])
        + [2.0, 3.0, 4.0].map {
          TVCinemaNote(time: $0 + 0.55, frequency: 180, length: 0.04, voice: .pop, level: 0.5)
        }
        + bells([(5.2, 103)], length: 0.3, level: 0.25)
        + [(6.5, 60), (7.0, 67), (7.5, 64), (8.0, 67), (9.0, 65), (9.5, 69), (10.0, 67), (10.5, 72)]
        .map {
          TVCinemaNote(time: $0.0, frequency: hertz($0.1 - 12), length: 0.3, voice: .pluck, level: 0.35)
        }
        + bells([(11.0, 79), (11.15, 81), (11.3, 83), (11.5, 84), (11.5, 88), (11.5, 91)], level: 0.35)
    case .popcorn:
      var noise = TVCinemaSynth.Noise(seed: 0xC0FFEE)
      let pops = TVCinemaPopcorn.kernels.map {
        TVCinemaNote(
          time: $0.launch, frequency: 300 + 250 * (noise.next() + 1), length: 0.03, voice: .pop,
          level: 0.35)
      }
      return bells([(0.2, 79), (0.35, 84), (0.5, 88)], level: 0.35) + pops
        + [(11.0, 67), (11.25, 72), (11.5, 76), (11.75, 79)].map {
          TVCinemaNote(time: $0.0, frequency: hertz($0.1), length: 0.25, voice: .pluck, level: 0.4)
        }
    case .phones:
      let buzzes = TVCinemaPhones.notifications.flatMap { message in
        [0, 0.45].map {
          TVCinemaNote(time: message.time + $0, frequency: 150, length: 0.3, voice: .buzz, level: 0.3)
        }
      }
      return buzzes + [TVCinemaNote(time: 8.0, frequency: 90, length: 0.02, voice: .pop, level: 0.4)]
        + bells([(8.7, 84), (9.0, 79), (9.3, 76), (9.8, 72)], length: 0.6, level: 0.3)
    }
  }

  /// A call as the title appears on the curtain.
  static let fanfareCall = phrase(
    at: 0.8, [(0.0, 67, 0.22), (0.28, 72, 0.22), (0.56, 76, 0.22), (0.84, 79, 1.6)],
    chord: [60, 64, 67])

  /// The answer as the curtain opens onto the film.
  static let fanfareAnswer = phrase(
    at: 0, [(0.0, 72, 0.2), (0.24, 76, 0.2), (0.48, 79, 0.2), (0.72, 84, 2.0)],
    chord: [64, 67, 72])

  private static func phrase(at start: Double, _ notes: [(Double, Int, Double)], chord: [Int])
    -> [TVCinemaNote]
  {
    let last = notes[notes.count - 1]
    return notes.map {
      TVCinemaNote(
        time: start + $0.0, frequency: hertz($0.1 - 12), length: $0.2, voice: .brass, level: 0.4)
    }
      + chord.map {
        TVCinemaNote(
          time: start + last.0, frequency: hertz($0 - 12), length: last.2, voice: .brass,
          level: 0.2)
      }
  }
}

/// When the popcorn kernels go off and where they fly; shared by the picture and the sound.
enum TVCinemaPopcorn {
  struct Kernel: Sendable {
    let launch: Double
    /// Sideways and upward speed, in shares of the picture's height per second.
    let sideways: Double
    let upward: Double
    let spin: Double
  }

  static let kernels: [Kernel] = {
    var noise = TVCinemaSynth.Noise(seed: 0xB0B)
    var time = 1.6
    var kernels: [Kernel] = []
    while time < 10 {
      kernels.append(
        Kernel(
          launch: time, sideways: noise.next() * 0.22, upward: 0.75 + 0.35 * (noise.next() + 1) / 2,
          spin: noise.next() * 6))
      // Slow at first, then going off all at once, as in a pan.
      time += max(0.07, 0.55 - (time - 1.6) * 0.09) * (0.6 + 0.4 * (noise.next() + 1) / 2)
    }
    return kernels
  }()
}

/// The messages that light up the phone in the phone ad.
enum TVCinemaPhones {
  struct Notification: Sendable {
    let time: Double
    let sender: String
    let text: String
  }

  static let notifications: [Notification] = [
    Notification(time: 1.2, sender: "Mum", text: "Are you watching something? Call me after"),
    Notification(time: 2.9, sender: "Pizza", text: "Your driver is 2 minutes away"),
    Notification(time: 4.4, sender: "Group Chat (148)", text: "did anyone see what happened"),
    Notification(time: 5.6, sender: "Photos", text: "You have a new memory: Tuesday"),
    Notification(time: 6.6, sender: "Calendar", text: "Watch the film · now"),
  ]

  /// When the phone switches itself off.
  static let silence: Double = 8
}
