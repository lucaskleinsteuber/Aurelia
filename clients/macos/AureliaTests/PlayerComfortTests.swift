import Foundation
import Testing
import VLCKit

@testable import Aurelia

@MainActor
struct PlayerComfortTests {
  @Test func endTimeFollowsRemainingTimeAndRate() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)  // 08:00 UTC
    let utc = TimeZone(identifier: "UTC")!
    let english = Locale(identifier: "en_GB")
    let normal = PlaybackEndTime.text(
      position: 600_000, duration: 3_000_000, rate: 1, now: now, locale: english, timeZone: utc)
    #expect(normal == "Ends at 8:40", "\(normal ?? "nil")")
    // At double speed the remaining 40 minutes take 20.
    let fast = PlaybackEndTime.text(
      position: 600_000, duration: 3_000_000, rate: 2, now: now, locale: english, timeZone: utc)
    #expect(fast == "Ends at 8:20", "\(fast ?? "nil")")
    #expect(PlaybackEndTime.text(position: 0, duration: 0, rate: 1, now: now) == nil)
  }

  @Test func settingsSavedBeforeNightModeKeepTheirValues() throws {
    let saved = Data(
      """
      {"automaticResume":false,"defaultPlaybackRate":1.25,"defaultVolume":0.5,
      "controlsAutoHideDelay":5,"seekInterval":30,"preventSleepDuringPlayback":false,
      "automaticallyPlayNextEpisode":false}
      """.utf8)
    let value = try JSONDecoder().decode(PlaybackPreferences.self, from: saved)
    #expect(!value.automaticResume)
    #expect(value.defaultPlaybackRate == 1.25)
    #expect(value.seekInterval == 30)
    #expect(!value.automaticallyPlayNextEpisode)
    #expect(!value.nightMode)
    var changed = value
    changed.nightMode = true
    let roundTrip = try JSONDecoder().decode(
      PlaybackPreferences.self, from: JSONEncoder().encode(changed))
    #expect(roundTrip == changed)
  }

  @Test func trackChoicesAreRememberedPerSeries() throws {
    let suite = "PlayerComfortTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = PlaybackTrackPreferenceStore(defaults: defaults)
    let breakingBad = UUID()
    let topGear = UUID()
    let english = PlaybackTrackPreference(language: "en", title: "English")
    let german = PlaybackTrackPreference(language: "de", title: "Deutsch")
    let germanSubtitles = PlaybackTrackPreference(language: "de", title: "Deutsch")

    store.rememberAudio(english, scope: breakingBad)
    store.rememberSubtitle(germanSubtitles, scope: breakingBad)
    store.rememberAudio(german, scope: topGear)
    store.rememberSubtitle(nil, scope: topGear)

    #expect(store.audio(scope: breakingBad) == english)
    #expect(store.subtitle(scope: breakingBad) == germanSubtitles)
    #expect(store.audio(scope: topGear) == german)
    // Subtitles turned off in one series stay off there.
    #expect(store.subtitle(scope: topGear) == nil)
    // A series without its own choice, or a movie, uses the last choice made anywhere.
    #expect(store.audio(scope: UUID()) == german)
    #expect(store.audio(scope: nil) == german)

    store.forgetAll()
    #expect(store.audio(scope: breakingBad) == nil)
    #expect(store.subtitle(scope: breakingBad) == nil)
  }

  @Test func trackChoicesAreScopedPerProfile() throws {
    let suite = "PlayerComfortTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = PlaybackTrackPreferenceStore(defaults: defaults)
    let profileA = UUID()
    let profileB = UUID()
    let seriesID = UUID()

    let english = PlaybackTrackPreference(language: "en", title: "English")
    let german = PlaybackTrackPreference(language: "de", title: "Deutsch")
    let frenchSubs = PlaybackTrackPreference(language: "fr", title: "Français")

    // Profile A chooses German audio and French subtitles for seriesID
    store.rememberAudio(german, scope: seriesID, profileId: profileA)
    store.rememberSubtitle(frenchSubs, scope: seriesID, profileId: profileA)

    // Profile B chooses English audio and Off for subtitles for the same seriesID
    store.rememberAudio(english, scope: seriesID, profileId: profileB)
    store.rememberSubtitle(nil, scope: seriesID, profileId: profileB)

    // Profile A preserves its choices
    #expect(store.audio(scope: seriesID, profileId: profileA) == german)
    let subA = store.subtitleChoice(scope: seriesID, profileId: profileA)
    #expect(subA.chosen)
    #expect(subA.preference == frenchSubs)

    // Profile B preserves its choices independently
    #expect(store.audio(scope: seriesID, profileId: profileB) == english)
    let subB = store.subtitleChoice(scope: seriesID, profileId: profileB)
    #expect(subB.chosen)
    #expect(subB.preference == nil)

    // A third profile without choices reports unchosen
    let profileC = UUID()
    #expect(store.audio(scope: seriesID, profileId: profileC) == nil)
    let subC = store.subtitleChoice(scope: seriesID, profileId: profileC)
    #expect(!subC.chosen)
    #expect(subC.preference == nil)
  }

  /// Plays a synthetic loud-then-quiet tone into a file (nothing is audible) and compares how
  /// far apart the two parts end up with and without night mode.
  @Test(.timeLimit(.minutes(1))) func nightModeNarrowsTheGapBetweenLoudAndQuiet() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AureliaNightMode-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rate = 48_000
    let tone = { (amplitude: Float, seconds: Int) -> [Float] in
      (0..<(rate * seconds)).map { amplitude * sin(Float($0) * 2 * .pi * 440 / Float(rate)) }
    }
    let input = directory.appendingPathComponent("input.wav")
    try Self.writeWAV(tone(0.9, 2) + tone(0.02, 2), rate: rate, to: input)

    let plain = try await Self.gap(input: input, nightMode: false, directory: directory)
    let night = try await Self.gap(input: input, nightMode: true, directory: directory)
    // About 33 dB apart as recorded; night mode brings them about 15 dB closer.
    #expect(plain > 28)
    #expect(night < plain - 10, "plain \(plain) dB, night \(night) dB")
  }

  /// Loud part level minus quiet part level, in dB, as VLC outputs it.
  private static func gap(input: URL, nightMode: Bool, directory: URL) async throws -> Double {
    let output = directory.appendingPathComponent("output-\(nightMode).wav")
    let player = VLCPlaybackEngine.makePlayer(
      nightMode: nightMode, output: "afile",
      extraOptions: [
        "--no-video", "--aout=afile", "--audiofile-file=\(output.path)", "--audiofile-wav",
        "--audiofile-format=s16",
      ])
    player.media = VLCMedia(url: input)
    player.play()
    let started = Date()
    try await Task.sleep(for: .milliseconds(300))
    while player.isPlaying || player.state == .opening || player.state == .buffering,
      Date().timeIntervalSince(started) < 20
    {
      try await Task.sleep(for: .milliseconds(100))
    }
    player.stop()
    let samples = try readWAV(output)
    let channels = 2
    let frames = samples.count / channels
    func level(_ range: Range<Int>) -> Double {
      let values = range.flatMap { frame in (0..<channels).map { samples[frame * channels + $0] } }
      let mean = values.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, values.count))
      return 10 * log10(max(mean, 1e-12))
    }
    // Skip the compressor's attack and release around each change.
    let loud = level((frames / 10)..<(frames * 2 / 5))
    let quiet = level((frames * 13 / 20)..<(frames * 9 / 10))
    return loud - quiet
  }

  private static func readWAV(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    let bytes = [UInt8](data)
    var offset = 12
    while offset + 8 <= bytes.count {
      let id = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
      let size =
        Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8 | Int(bytes[offset + 6]) << 16
        | Int(bytes[offset + 7]) << 24
      if id == "data" {
        let end = min(bytes.count, offset + 8 + size)
        return stride(from: offset + 8, to: end - 1, by: 2).map {
          Float(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) / 32_768
        }
      }
      offset += 8 + size
    }
    throw CocoaError(.fileReadCorruptFile)
  }

  private static func writeWAV(_ samples: [Float], rate: Int, to url: URL) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    let byteCount = UInt32(samples.count * 4)
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36) + byteCount)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(2))
    append(UInt32(rate))
    append(UInt32(rate * 4))
    append(UInt16(4))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(byteCount)
    for sample in samples {
      let value = Int16(max(-1, min(1, sample)) * 32_767)
      append(value)
      append(value)
    }
    try data.write(to: url)
  }
}
