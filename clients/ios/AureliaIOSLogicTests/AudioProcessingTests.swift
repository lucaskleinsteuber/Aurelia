import Foundation
import Testing

struct AudioProcessingTests {
  @Test func legacyNightModeMigratesWithoutChangingOtherSettings() throws {
    let before = IOSPlaybackPreferences.defaultValue
    var dictionary =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(before)) as! [String: Any]
    dictionary.removeValue(forKey: "dialogueBoost")
    dictionary.removeValue(forKey: "volumeLeveling")
    dictionary["nightMode"] = true
    var value = try JSONDecoder().decode(
      IOSPlaybackPreferences.self, from: JSONSerialization.data(withJSONObject: dictionary))
    #expect(value.volumeLeveling == .standard)
    #expect(value.dialogueBoost == .off)
    #expect(value.defaultPlaybackRate == before.defaultPlaybackRate)
    value.dialogueBoost = .strong
    value.volumeLeveling = .sleep
    let saved = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(IOSPlaybackPreferences.self, from: saved) == value)
    dictionary["nightMode"] = false
    #expect(
      try JSONDecoder().decode(
        IOSPlaybackPreferences.self, from: JSONSerialization.data(withJSONObject: dictionary)
      ).volumeLeveling == .off)
    dictionary["nightMode"] = true
    dictionary["volumeLeveling"] = "off"
    #expect(
      try JSONDecoder().decode(
        IOSPlaybackPreferences.self, from: JSONSerialization.data(withJSONObject: dictionary)
      ).volumeLeveling == .off)
  }

  @Test func speechCurvesUseFrequencyAndLeaveHeadroom() {
    for mode in DialogueBoost.allCases {
      #expect(mode.gain(at: .nan) == 0)
      #expect(mode.gain(at: -1) == 0)
      for frequency: Float in [
        60, 170, 310, 600, 1_000, 1_500, 2_500, 3_000, 6_000, 12_000, 16_000,
      ] {
        #expect(mode.gain(at: frequency) + mode.preamp <= 0.001)
      }
    }
    #expect(DialogueBoost.standard.gain(at: 1_000) == 2)
    #expect(DialogueBoost.strong.gain(at: 3_000) == 5)
    #expect(DialogueBoost.strong.gain(at: 60) == -6)
    #expect(DialogueBoost.strong.gain(at: 16_000) == -3)
    #expect(DialogueBoost.standard.gain(at: 2_000) > 2)
    #expect(DialogueBoost.standard.gain(at: 2_000) < 3)
  }

  @Test func compressorProfilesAndCombinedFilterRequirements() {
    #expect(VolumeLeveling.off.options.isEmpty)
    #expect(VolumeLeveling.standard.options.contains("--compressor-threshold=-24"))
    #expect(VolumeLeveling.standard.options.contains("--compressor-ratio=4"))
    #expect(
      VolumeLeveling.sleep.options == [
        "--compressor-rms-peak=1", "--compressor-attack=1.5", "--compressor-release=650",
        "--compressor-threshold=-30", "--compressor-ratio=12", "--compressor-knee=6",
        "--compressor-makeup-gain=16",
      ])
    for dialogue in DialogueBoost.allCases {
      for leveling in VolumeLeveling.allCases {
        let processing = AudioProcessing(dialogue: dialogue, leveling: leveling)
        #expect(processing.filters.contains("compressor") == (leveling != .off))
        #expect(processing.filters.contains("equalizer") == (dialogue != .off))
        #expect(processing.missingFilters(in: ["compressor", "equalizer"]).isEmpty)
      }
    }
    #expect(
      AudioProcessing(dialogue: .strong, leveling: .sleep).missingFilters(in: ["compressor"]) == [
        "equalizer"
      ])
  }
}
