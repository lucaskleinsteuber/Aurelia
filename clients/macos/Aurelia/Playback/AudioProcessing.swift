import Foundation

enum AudioChangeResult: Equatable { case applied, reloadRequired, unavailable }

enum DialogueBoost: String, Codable, CaseIterable, Sendable {
  case off, standard, strong
  var title: String { rawValue.capitalized }
  var preamp: Float { self == .strong ? -5 : self == .standard ? -3 : 0 }

  /// Interpolate in log frequency so the curve follows VLC's actual reported bands.
  func gain(at frequency: Float) -> Float {
    guard self != .off, frequency.isFinite, frequency > 0 else { return 0 }
    let frequencies: [Float] = [60, 170, 310, 600, 1_000, 3_000, 6_000, 12_000, 14_000, 16_000]
    let gains: [Float] =
      self == .standard
      ? [-3, -2, -1, 0, 2, 3, 1, 0, -1, -2] : [-6, -4, -2, 0, 3, 5, 2, 0, -2, -3]
    if frequency <= frequencies[0] { return gains[0] }
    for index in 1..<frequencies.count where frequency <= frequencies[index] {
      let fraction =
        log(frequency / frequencies[index - 1]) / log(frequencies[index] / frequencies[index - 1])
      return gains[index - 1] + fraction * (gains[index] - gains[index - 1])
    }
    return gains[gains.count - 1]
  }
}

enum VolumeLeveling: String, Codable, CaseIterable, Sendable {
  case off, standard, sleep
  var title: String { rawValue.capitalized }
  var options: [String] {
    switch self {
    case .off: []
    case .standard:
      [
        "--compressor-rms-peak=0.2", "--compressor-attack=15", "--compressor-release=300",
        "--compressor-threshold=-24", "--compressor-ratio=4", "--compressor-knee=6",
        "--compressor-makeup-gain=12",
      ]
    case .sleep:
      [
        "--compressor-rms-peak=1", "--compressor-attack=1.5", "--compressor-release=650",
        "--compressor-threshold=-30", "--compressor-ratio=12", "--compressor-knee=6",
        "--compressor-makeup-gain=16",
      ]
    }
  }
}

/// One owner of the complete chain; neither option can erase the other filter.
struct AudioProcessing: Equatable, Sendable {
  var dialogue: DialogueBoost = .off
  var leveling: VolumeLeveling = .off
  var filters: [String] {
    (leveling == .off ? [] : ["compressor"]) + (dialogue == .off ? [] : ["equalizer"])
  }
  func missingFilters(in available: Set<String>) -> [String] {
    filters.filter { !available.contains($0) }
  }
}
