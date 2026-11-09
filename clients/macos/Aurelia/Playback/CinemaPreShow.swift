import AVFoundation
import Foundation

/// Aurelia's made-up cinema ads. Nothing is sold; they are a joke before the film.
enum CinemaAd: String, CaseIterable, Sendable {
  case iceCream, popcorn, phones

  /// The ads are timed as 15-second scripts and played slower, so there is time to read them.
  static let pace = 1.4
  /// Every ad runs this long, in seconds.
  static let duration: Double = 15 * pace
}

/// One part of cinema mode's pre-show, in the order of a cinema: ad, trailers, then the curtain.
enum CinemaAct: Equatable, Sendable {
  case ad(CinemaAd)
  case trailer(CinemaTrailer)
  /// "Feature Presentation": the curtain opens for the film.
  case feature(title: String)
}

enum CinemaPreShowPlan {
  /// The title stands on the closed curtain at least this long while the film starts behind it.
  static let curtainEarliestOpening: Double = 3.3
  /// A film that hasn't started by then gets the curtain opened anyway.
  static let curtainLongestWait: Double = 10
  /// From the curtain starting to open until the film is all there is.
  static let curtainOpeningSeconds: Double = 4
  /// A trailer whose picture hasn't moved by then is left out.
  static let trailerStartSeconds: Double = 15
  /// Even a long trailer ends here.
  static let trailerLongestSeconds: Double = 300
  static let lastAdKey = "AureliaCinemaLastAd"

  /// Whether a title may get a pre-show: not an episode or a download, with cinema mode on and
  /// no one watching along. The server then says whether it is a film.
  static func wanted(
    preferences: PlaybackPreferences, presentation: PlaybackPresentation,
    capabilities: Set<String>, watchingTogether: Bool
  ) -> Bool {
    preferences.cinemaMode && (preferences.cinemaAds || preferences.cinemaTrailers > 0)
      && presentation.offlineID == nil && presentation.trackScope == nil && !watchingTogether
      && capabilities.contains(ServerFeatureNames.cinemaTrailers)
  }

  /// Whether the film starts from its beginning; a film picked up in the middle gets no pre-show.
  /// Mirrors where the player starts.
  static func startsAtBeginning(
    intent: PlaybackStartIntent, progress: PlaybackProgressResponse,
    preferences: PlaybackPreferences
  ) -> Bool {
    let position = intent.position(
      progress: progress, automaticResume: preferences.automaticResume)
    return position == 0 || position < Int64(preferences.resumeThresholdSeconds) * 1_000
  }

  /// The ad, the trailers that aren't for the film itself, then the curtain.
  static func acts(ad: CinemaAd?, trailers: [CinemaTrailer], film: UUID, title: String)
    -> [CinemaAct]
  {
    var acts = ad.map { [CinemaAct.ad($0)] } ?? []
    acts += trailers.filter { $0.title.id != film && $0.trailer.parentId != film }
      .map(CinemaAct.trailer)
    if !acts.isEmpty { acts.append(.feature(title: title)) }
    return acts
  }

  /// The ads take turns, so the same one never runs twice in a row.
  static func ad(after last: String?) -> CinemaAd {
    let all = CinemaAd.allCases
    guard let index = all.firstIndex(where: { $0.rawValue == last }) else { return all[0] }
    return all[(index + 1) % all.count]
  }
}

/// Runs a pre-show before the film: the player shows it while `act` is set and starts the film
/// once `run()` returns. Return ends it at any time, → skips one part.
@MainActor
final class CinemaPreShow: ObservableObject {
  @Published private(set) var act: CinemaAct?
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

  let engine: VLCPlaybackEngine
  private let acts: [CinemaAct]
  private let profile: StoredServerProfile
  private let volume: Double
  private let sound = CinemaSound()
  private var finished = false
  private var actDone: CheckedContinuation<Void, Never>?
  private var actTimer: Task<Void, Never>?
  private var startCheck: Task<Void, Never>?

  init(acts: [CinemaAct], profile: StoredServerProfile, volume: Double) {
    self.acts = acts
    self.profile = profile
    self.volume = volume
    engine = VLCPlaybackEngine()
    engine.profileScope = profile.user?.id ?? profile.serverId
  }

  /// The pre-show for `presentation`, or nil when it gets none. Asks the server for at most a
  /// few seconds, so a slow answer never holds up the film.
  static func prepare(
    profile: StoredServerProfile, presentation: PlaybackPresentation,
    preferences: PlaybackPreferences, capabilities: Set<String>, watchingTogether: Bool,
    defaults: UserDefaults = .standard
  ) async -> CinemaPreShow? {
    let preferences = preferences.normalized
    guard
      CinemaPreShowPlan.wanted(
        preferences: preferences, presentation: presentation, capabilities: capabilities,
        watchingTogether: watchingTogether)
    else { return nil }
    let api = APIClient(profile: profile)
    let trailers = await withTaskGroup(of: [CinemaTrailer]?.self) { group in
      group.addTask {
        if presentation.startIntent == .resume {
          guard let progress = try? await api.playbackProgress(mediaId: presentation.mediaId),
            CinemaPreShowPlan.startsAtBeginning(
              intent: .resume, progress: progress, preferences: preferences)
          else { return nil }
        }
        return try? await api.cinemaTrailers(
          mediaId: presentation.mediaId, count: preferences.cinemaTrailers)
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
    var ad: CinemaAd?
    if preferences.cinemaAds {
      ad = CinemaPreShowPlan.ad(after: defaults.string(forKey: CinemaPreShowPlan.lastAdKey))
      defaults.set(ad?.rawValue, forKey: CinemaPreShowPlan.lastAdKey)
    }
    let acts = CinemaPreShowPlan.acts(
      ad: ad, trailers: trailers, film: presentation.mediaId, title: presentation.title)
    guard !acts.isEmpty else { return nil }
    return CinemaPreShow(acts: acts, profile: profile, volume: preferences.defaultVolume)
  }

  /// Plays every part; returns when the pre-show is over, skipped or the player closes.
  func run() async {
    await withTaskCancellationHandler {
      for act in acts {
        guard !finished, !Task.isCancelled else { break }
        self.act = act
        actStarted = Date()
        trailerPlaying = false
        actSkipped = false
        switch act {
        case .ad(let ad):
          sound.play(CinemaTunes.notes(for: ad), volume: volume)
          await waitForAct(seconds: CinemaAd.duration)
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

  /// The title on the closed curtain while the film starts behind it, then the curtain opens
  /// onto the playing film.
  private func feature() async {
    curtainOpensAt = nil
    sound.play(CinemaTunes.fanfareCall, volume: volume)
    onFeature?()
    await waitForAct(seconds: CinemaPreShowPlan.curtainEarliestOpening)
    guard !actSkipped, !finished else { return }
    if !filmShowing {
      waitingForFilm = true
      await waitForAct(
        seconds: CinemaPreShowPlan.curtainLongestWait - CinemaPreShowPlan.curtainEarliestOpening)
      waitingForFilm = false
      guard !actSkipped, !finished else { return }
    }
    curtainOpensAt = Date().timeIntervalSince(actStarted)
    sound.play(CinemaTunes.fanfareAnswer, volume: volume)
    await waitForAct(seconds: CinemaPreShowPlan.curtainOpeningSeconds)
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

  private func play(_ item: CinemaTrailer) async {
    let api = APIClient(profile: profile)
    guard let ticket = try? await api.createPlayback(mediaId: item.trailer.id) else { return }
    defer { Task { try? await api.revokePlayback(id: ticket.id) } }
    guard !finished,
      let source = try? api.streamURL(path: ticket.streamPath),
      let relay = try? LoopbackStreamRelay(
        sourceURL: source, publicKeyFingerprint: profile.publicKeyFingerprint,
        authorizationToken: profile.token)
    else { return }
    defer { relay.stop() }
    guard let local = try? await relay.start(), !finished else { return }
    engine.onEnded = { [weak self] in self?.endAct() }
    engine.onError = { [weak self] _ in self?.endAct() }
    engine.onUpdate = { [weak self] in
      guard let self, !self.trailerPlaying, self.engine.isPlaying,
        self.engine.currentTimeMilliseconds > 0
      else { return }
      self.trailerPlaying = true
    }
    engine.volume = volume
    engine.load(url: local)
    engine.play()
    startCheck = Task { [weak self] in
      try? await Task.sleep(for: .seconds(CinemaPreShowPlan.trailerStartSeconds))
      guard let self, !Task.isCancelled, !self.trailerPlaying else { return }
      self.endAct()
    }
    await waitForAct(seconds: CinemaPreShowPlan.trailerLongestSeconds)
    startCheck?.cancel()
    engine.onEnded = nil
    engine.onError = nil
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

/// A note of the ads' little tunes, made on this Mac; no sound files ship with Aurelia.
struct CinemaNote: Equatable, Sendable {
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

enum CinemaSynth {
  static let sampleRate = 44_100.0

  /// Mono samples of `notes`, never louder than 0.9.
  static func samples(_ notes: [CinemaNote]) -> [Float] {
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

  private static func release(_ voice: CinemaNote.Voice) -> Double {
    switch voice {
    case .bell: 1.2
    case .pluck: 0.5
    case .pop: 0.05
    case .buzz: 0.03
    case .brass: 0.35
    }
  }

  private static func sample(
    _ note: CinemaNote, time: Double, phase: Double, noise: inout Noise
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

/// Plays one tune at a time on the Mac's speakers.
@MainActor
final class CinemaSound {
  private var engine: AVAudioEngine?

  func play(_ notes: [CinemaNote], volume: Double) {
    stop()
    let samples = CinemaSynth.samples(notes)
    guard !samples.isEmpty,
      let format = AVAudioFormat(standardFormatWithSampleRate: CinemaSynth.sampleRate, channels: 1),
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

/// The ads' tunes, timed to the pictures in CinemaPreShowView.
enum CinemaTunes {

  private static func hertz(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

  private static func bells(_ notes: [(Double, Int)], length: Double = 0.4, level: Double = 0.4)
    -> [CinemaNote]
  {
    notes.map { CinemaNote(time: $0.0, frequency: hertz($0.1), length: length, voice: .bell, level: level) }
  }

  /// The ad's tune, its notes moved to where their pictures are in the slower ad.
  static func notes(for ad: CinemaAd) -> [CinemaNote] {
    scriptNotes(for: ad).map {
      CinemaNote(
        time: $0.time * CinemaAd.pace, frequency: $0.frequency, length: $0.length, voice: $0.voice,
        level: $0.level)
    }
  }

  private static func scriptNotes(for ad: CinemaAd) -> [CinemaNote] {
    switch ad {
    case .iceCream:
      // A bright jingle, a plop for every scoop, and a "ta-da" for the price.
      return bells([(0.3, 84), (0.45, 88), (0.6, 91), (0.75, 96)])
        + [2.0, 3.0, 4.0].map {
          CinemaNote(time: $0 + 0.55, frequency: 180, length: 0.04, voice: .pop, level: 0.5)
        }
        + bells([(5.2, 103)], length: 0.3, level: 0.25)
        + [(6.5, 60), (7.0, 67), (7.5, 64), (8.0, 67), (9.0, 65), (9.5, 69), (10.0, 67), (10.5, 72)]
        .map {
          CinemaNote(time: $0.0, frequency: hertz($0.1 - 12), length: 0.3, voice: .pluck, level: 0.35)
        }
        + bells([(11.0, 79), (11.15, 81), (11.3, 83), (11.5, 84), (11.5, 88), (11.5, 91)], level: 0.35)
    case .popcorn:
      var noise = CinemaSynth.Noise(seed: 0xC0FFEE)
      let pops = CinemaPopcorn.kernels.map {
        CinemaNote(
          time: $0.launch, frequency: 300 + 250 * (noise.next() + 1), length: 0.03, voice: .pop,
          level: 0.35)
      }
      return bells([(0.2, 79), (0.35, 84), (0.5, 88)], level: 0.35) + pops
        + [(11.0, 67), (11.25, 72), (11.5, 76), (11.75, 79)].map {
          CinemaNote(time: $0.0, frequency: hertz($0.1), length: 0.25, voice: .pluck, level: 0.4)
        }
    case .phones:
      let buzzes = CinemaPhones.notifications.flatMap { message in
        [0, 0.45].map {
          CinemaNote(time: message.time + $0, frequency: 150, length: 0.3, voice: .buzz, level: 0.3)
        }
      }
      return buzzes + [CinemaNote(time: 8.0, frequency: 90, length: 0.02, voice: .pop, level: 0.4)]
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
    -> [CinemaNote]
  {
    let last = notes[notes.count - 1]
    return notes.map {
      CinemaNote(
        time: start + $0.0, frequency: hertz($0.1 - 12), length: $0.2, voice: .brass, level: 0.4)
    }
      + chord.map {
        CinemaNote(
          time: start + last.0, frequency: hertz($0 - 12), length: last.2, voice: .brass,
          level: 0.2)
      }
  }
}

/// When the popcorn kernels go off and where they fly; shared by the picture and the sound.
enum CinemaPopcorn {
  struct Kernel: Sendable {
    let launch: Double
    /// Sideways and upward speed, in shares of the picture's height per second.
    let sideways: Double
    let upward: Double
    let spin: Double
  }

  static let kernels: [Kernel] = {
    var noise = CinemaSynth.Noise(seed: 0xB0B)
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
enum CinemaPhones {
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
